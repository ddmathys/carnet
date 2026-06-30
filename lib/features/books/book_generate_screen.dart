import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/order_service.dart';

class BookGenerateScreen extends StatefulWidget {
  /// Single notebook mode: pass [notebookId]
  /// Multi-notebook mode: pass [notebookIds] (notebookId is ignored when notebookIds is non-empty)
  final String notebookId;
  final List<String> notebookIds;

  const BookGenerateScreen({
    super.key,
    this.notebookId = '',
    this.notebookIds = const [],
  });

  List<String> get _ids =>
      notebookIds.isNotEmpty ? notebookIds : [notebookId];

  @override
  State<BookGenerateScreen> createState() => _BookGenerateScreenState();
}

class _BookGenerateScreenState extends State<BookGenerateScreen>
    with TickerProviderStateMixin {
  // ── Data ───────────────────────────────────────────────────────────────────
  NotebookModel? _notebook;
  List<MemoryModel> _memories = [];
  String? _loadError; // message si le chargement initial échoue

  // ── State ──────────────────────────────────────────────────────────────────
  int _step = 0; // 0=cover+create, 1=format, 2=order
  bool _showPreview = false;
  String _selectedFormat = 'digital';
  String _coverType = 'soft'; // 'soft' ou 'hard'
  bool _generating = false;
  bool _exporting = false;
  double _progress = 0.0;
  int _msgIndex = 0;
  Timer? _progressTimer;
  Map<String, String> _locationComments = {};
  Set<String> _selectedMemoryIds = {};
  String? _coverPhotoUrl;
  // Si vrai, la photo de couverture n'est pas répétée dans les pages du livre.
  bool _excludeCoverPhotoFromBook = false;

  // Aperçu WYSIWYG : on génère les MÊMES octets PDF que le téléchargement et on
  // affiche chaque page rastérisée → aucune différence possible avec le rendu
  // final / l'impression Gelato.
  Uint8List? _previewPdfBytes;
  int _previewPageCount = 0;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _subtitleCtrl;

  // ── Adresse livraison ──────────────────────────────────────────────────────
  final _addressKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _streetCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _npaCtrl;
  late final TextEditingController _countryCtrl;
  bool _ordering = false;
  String _orderMessage = '';

  late AnimationController _coverAnim;
  late Animation<double> _coverScale;

  static const _loadingMessages = [
    'Je mets en page tes souvenirs…',
    'Je prépare les photos…',
    'Le livre prend forme…',
    'Presque prêt…',
  ];

  List<MemoryModel> get _selectedMemories =>
      _memories.where((m) => _selectedMemoryIds.contains(m.id)).toList();

  // Nombre de pages : on privilégie le VRAI compte de l'aperçu (déjà généré
  // avant l'étape format) ; sinon estimation. Pour l'imprimé, le prix se base
  // sur les pages réellement imprimées (bourrage Gelato pair / ≥28).
  int get _pages => _previewPageCount > 0
      ? _previewPageCount
      : BookPricing.estimatePages(_selectedMemories);
  int get _printedPages => BookPricing.printablePages(_pages);
  double _priceFor(String coverType) =>
      BookPricing.price(coverType: coverType, pages: _printedPages);
  String _priceLabel(String coverType) => BookPricing.format(_priceFor(coverType));

  String get _yearRange {
    if (_selectedMemories.isEmpty) return '${DateTime.now().year}';
    final years = _selectedMemories.map((m) => m.date.year).toSet();
    final minY = years.reduce((a, b) => a < b ? a : b);
    final maxY = years.reduce((a, b) => a > b ? a : b);
    return minY == maxY ? '$minY' : '$minY — $maxY';
  }

  List<String> get _coverHighlights {
    final result = <String>[];
    for (final m in _selectedMemories) {
      if (m.type == 'taille_poids') continue;
      final t = m.title?.trim();
      if (t != null && t.isNotEmpty) {
        result.add(t);
      } else {
        final words = m.rawContent.trim().split(RegExp(r'\s+')).take(4).join(' ');
        if (words.isNotEmpty) result.add(words);
      }
      if (result.length >= 15) break;
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _subtitleCtrl = TextEditingController();
    _firstNameCtrl = TextEditingController();
    _lastNameCtrl = TextEditingController();
    _streetCtrl = TextEditingController();
    _cityCtrl = TextEditingController();
    _npaCtrl = TextEditingController();
    _countryCtrl = TextEditingController(text: 'Suisse');
    _coverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _coverScale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _coverAnim, curve: Curves.elasticOut),
    );
    _coverAnim.forward();
    _loadData();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _subtitleCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _streetCtrl.dispose();
    _cityCtrl.dispose();
    _npaCtrl.dispose();
    _countryCtrl.dispose();
    _coverAnim.dispose();
    _progressTimer?.cancel();
    super.dispose();
  }

  // ── Load ───────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    final ids = widget._ids;
    if (mounted) setState(() => _loadError = null);
    const t = Duration(seconds: 20);
    try {
      // Load primary notebook (first in list)
      final nbDoc = await FirebaseFirestore.instance
          .collection('notebooks')
          .doc(ids.first)
          .get()
          .timeout(t);
      if (!mounted) return;
      if (!nbDoc.exists) {
        setState(() => _loadError = 'Carnet introuvable.');
        return;
      }

      // Load memories from ALL notebooks
      final allMemories = <MemoryModel>[];
      for (final id in ids) {
        final memSnap = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', isEqualTo: id)
            .get()
            .timeout(t);
        allMemories
            .addAll(memSnap.docs.map((d) => MemoryModel.fromFirestore(d)));
      }
      allMemories.sort((a, b) => a.date.compareTo(b.date));

      if (!mounted) return;
      final nb = NotebookModel.fromFirestore(nbDoc);
      setState(() {
        _notebook = nb;
        _memories = allMemories;
        _selectedMemoryIds = allMemories.map((m) => m.id).toSet();
        _loadError = null;
      });
      // Initialise les champs éditables : le titre = ce qui s'affiche par
      // défaut sur la couverture (ex. « Léa & Nala »), pour que le champ soit
      // cohérent avec l'aperçu et directement modifiable.
      _titleCtrl.text = _defaultCoverTitle(nb);
      _subtitleCtrl.text = nb.subtitle;
    } catch (e) {
      // Sans ça, une lecture qui pend/échoue laissait un spinner plein écran
      // infini, sans message — la cause des « le spinner tourne ».
      if (!mounted) return;
      setState(() => _loadError = 'Chargement impossible. Vérifie ta connexion.');
    }
  }

  // ── Generation ─────────────────────────────────────────────────────────────

  // Génère le PDF d'aperçu — mêmes octets que le téléchargement (sans bourrage
  // de pages blanches), pour un aperçu strictement identique au rendu final.
  Future<({Uint8List bytes, int pageCount})> _buildPreviewPdf() {
    final coverColor = _notebook!.coverColor.isNotEmpty
        ? Color(int.parse(
            'FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16))
        : AppColors.sage;
    return BookPdfService.generateForNotebook(
      notebook: _notebook!,
      coverColor: coverColor,
      memories: _selectedMemories,
      locationComments: _locationComments,
      coverPhotoUrl: _coverPhotoUrl,
      excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
      customTitle:
          _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null,
      customSubtitle:
          _subtitleCtrl.text.trim().isNotEmpty ? _subtitleCtrl.text.trim() : null,
      backendUrl: AppConfig.backendUrl,
    ).timeout(const Duration(seconds: 60));
  }

  Future<void> _generate() async {
    if (_selectedMemories.isEmpty) {
      _showSnack('Sélectionne au moins un souvenir avant de créer le livre.');
      return;
    }
    if (_notebook == null) return;

    setState(() { _generating = true; _progress = 0.0; _msgIndex = 0; });
    _progressTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      setState(() {
        _progress = (_progress + 0.06).clamp(0.0, 0.92);
        if (_progress > (_msgIndex + 1) * 0.25) {
          _msgIndex = (_msgIndex + 1).clamp(0, _loadingMessages.length - 1);
        }
      });
    });

    // Génère le vrai PDF → aperçu WYSIWYG (rastérisé page par page).
    try {
      final gen = await _buildPreviewPdf();
      if (!mounted) return;
      _progressTimer?.cancel();
      setState(() {
        _previewPdfBytes = gen.bytes;
        _previewPageCount = gen.pageCount;
        _progress = 1.0;
        _generating = false;
        _showPreview = true;
      });
    } catch (e) {
      _progressTimer?.cancel();
      if (!mounted) return;
      setState(() => _generating = false);
      _showSnack('Aperçu impossible : $e');
    }
  }

  // ── PDF export ─────────────────────────────────────────────────────────────

  Future<void> _downloadPdf() async {
    if (_notebook == null) return;
    setState(() => _exporting = true);

    final customTitle = _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null;
    final customSubtitle = _subtitleCtrl.text.trim().isNotEmpty ? _subtitleCtrl.text.trim() : null;
    final bookTitle = customTitle ?? _notebook!.title;

    // 1. Génération des octets du PDF (étape lourde mais bornée). Le spinner
    //    ne couvre QUE cette étape.
    Uint8List? pdfBytes;
    try {
      final coverColor = _notebook!.coverColor.isNotEmpty
          ? Color(int.parse(
              'FF${_notebook!.coverColor.replaceAll('#', '')}',
              radix: 16))
          : AppColors.sage;

      final gen = await BookPdfService.generateForNotebook(
        notebook: _notebook!,
        coverColor: coverColor,
        memories: _selectedMemories,
        locationComments: _locationComments,
        coverPhotoUrl: _coverPhotoUrl,
        excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
        customTitle: customTitle,
        customSubtitle: customSubtitle,
        backendUrl: AppConfig.backendUrl,
      ).timeout(const Duration(seconds: 60));
      pdfBytes = gen.bytes;
    } catch (e) {
      pdfBytes = null;
      if (mounted) _showSnack('Erreur génération PDF : $e');
    } finally {
      // On arrête le spinner dès que le PDF est prêt (ou a échoué) — surtout
      // PAS après le partage : la feuille de partage système est une étape
      // interactive qui ne doit jamais bloquer l'indicateur.
      if (mounted) setState(() => _exporting = false);
    }
    if (pdfBytes == null) return;

    // 2. Sauvegarde silencieuse côté admin + historique (sans bloquer).
    _uploadPdfToStorage(
      pdfBytes: pdfBytes,
      bookTitle: bookTitle,
      subtitle: customSubtitle,
      coverType: _coverType,
      notebookId: widget.notebookId,
      memoriesCount: _selectedMemories.length,
    );

    // 3. Partage — hors spinner. Si la feuille de partage ne s'ouvre pas, on
    //    le signale au lieu de tourner dans le vide.
    try {
      await Printing.sharePdf(
        bytes: pdfBytes,
        filename: '${bookTitle.replaceAll(' ', '_')}.pdf',
      );
    } catch (e) {
      if (mounted) _showSnack('Partage impossible : $e');
    }
  }

  // Upload silencieux dans Storage (l'admin peut récupérer tous les PDFs) +
  // enregistrement dans l'historique des livres du carnet.
  Future<void> _uploadPdfToStorage({
    required List<int> pdfBytes,
    required String bookTitle,
    String? subtitle,
    required String coverType,
    required String notebookId,
    required int memoriesCount,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final safeTitle = _safeFilename(bookTitle);
      final ts = DateTime.now().millisecondsSinceEpoch;
      // digital_{timestamp} pour différencier des commandes print
      final storageRef = FirebaseStorage.instance
          .ref('pdfs/${user.uid}/digital_${ts}_$safeTitle.pdf');
      await storageRef.putData(
        Uint8List.fromList(pdfBytes),
        SettableMetadata(
          contentType: 'application/pdf',
          customMetadata: {
            'coverType': coverType,
            'notebookId': notebookId,
            'bookTitle': bookTitle,
            'type': 'digital',
          },
        ),
      );
      final url = await storageRef.getDownloadURL();
      await BookHistoryService.recordBook(
        notebookId: notebookId,
        title: bookTitle,
        subtitle: subtitle,
        format: 'digital',
        coverType: coverType,
        pdfUrl: url,
        storagePath: storageRef.fullPath,
        memoriesCount: memoriesCount,
      );
    } catch (_) {
      // Silencieux — le partage a déjà eu lieu
    }
  }

  static String _safeFilename(String title) => title
      .replaceAll(RegExp(r'[àáâãäå]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôõö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  Future<void> _placeOrder() async {
    if (!(_addressKey.currentState?.validate() ?? false)) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _notebook == null) return;

    setState(() { _ordering = true; _orderMessage = 'Génération du livre…'; });
    try {
      final price = _priceFor(_coverType);
      final bookTitle = _titleCtrl.text.trim().isNotEmpty
          ? _titleCtrl.text.trim()
          : _notebook!.title;
      final customTitle = _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null;
      final customSubtitle = _subtitleCtrl.text.trim().isNotEmpty ? _subtitleCtrl.text.trim() : null;

      // 1. Générer le PDF en premier
      final coverColor = Color(int.parse(
          'FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16));
      final gen = await BookPdfService.generateForNotebook(
        notebook: _notebook!,
        coverColor: coverColor,
        memories: _selectedMemories,
        locationComments: _locationComments,
        coverPhotoUrl: _coverPhotoUrl,
        excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
        customTitle: customTitle,
        customSubtitle: customSubtitle,
        backendUrl: AppConfig.backendUrl,
        padForPrint: true, // pages valides Gelato (pair, ≥28)
      );
      final pdfBytes = gen.bytes;
      final pageCount = gen.pageCount;

      if (!mounted) return;
      setState(() => _orderMessage = 'Envoi du PDF…');

      // 2. Uploader le PDF (chemin temporaire avec userId + timestamp)
      final ts = DateTime.now().millisecondsSinceEpoch;
      final safeTitle = _safeFilename(bookTitle);
      final storageRef = FirebaseStorage.instance
          .ref('orders/${user.uid}/${ts}_$safeTitle.pdf');
      await storageRef.putData(
        pdfBytes,
        SettableMetadata(
          contentType: 'application/pdf',
          customMetadata: {'bookTitle': bookTitle, 'coverType': _coverType},
        ),
      );
      final pdfUrl = await storageRef.getDownloadURL();

      if (!mounted) return;
      setState(() => _orderMessage = 'Création de la commande…');

      // 3. Créer la commande avec pdfUrl déjà renseigné
      final order = OrderModel(
        id: '',
        userId: user.uid,
        userEmail: user.email ?? '',
        bookTitle: bookTitle,
        coverType: _coverType,
        price: price,
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        street: _streetCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        npa: _npaCtrl.text.trim(),
        country: _countryCtrl.text.trim(),
        status: 'received',
        createdAt: DateTime.now(),
        notebookId: widget.notebookId,
        memoryCount: _selectedMemories.length,
        pageCount: pageCount,
        pdfUrl: pdfUrl,
      );
      final orderId = await OrderService.createOrder(order);

      // 4. Historique des livres (imprimé)
      await BookHistoryService.recordBook(
        notebookId: widget.notebookId,
        title: bookTitle,
        subtitle: customSubtitle,
        format: 'printed',
        coverType: _coverType,
        pdfUrl: pdfUrl,
        storagePath: storageRef.fullPath,
        memoriesCount: _selectedMemories.length,
        orderId: orderId,
      );

      if (!mounted) return;
      context.go('/order-confirmation/$orderId');
    } catch (e) {
      _showSnack('Erreur : $e');
      if (mounted) setState(() { _ordering = false; _orderMessage = ''; });
    }
  }

  void _showSnack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_notebook == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
            onPressed: () =>
                context.go('/notebook/${widget.notebookId}/dashboard'),
          ),
        ),
        body: Center(
          child: _loadError == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined,
                          color: AppColors.softGray, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textMedium),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _loadData,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }

    return PopScope(
      canPop: !_showPreview && _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showPreview) {
          setState(() { _showPreview = false; _step = 0; });
        } else if (_step > 0) {
          setState(() => _step--);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: const Text(
            'Générer le livre',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
            onPressed: () {
              if (_showPreview) {
                setState(() { _showPreview = false; _step = 0; });
              } else if (_step > 0) {
                setState(() => _step--);
              } else {
                context.go('/notebook/${widget.notebookId}/dashboard');
              }
            },
          ),
          actions: const [],
        ),
        body: _showPreview
            ? _buildBookPreview()
            : switch (_step) {
                0 => _buildPreviewStep(),
                1 => _buildFormatStep(),
                _ => _buildOrderStep(),
              },
      ),
    );
  }

  // ── Step 0: Cover preview + generation ────────────────────────────────────

  // Titre par défaut affiché sur la couverture (avant édition).
  String _defaultCoverTitle(NotebookModel nb) =>
      nb.type == 'enfant' && nb.companionName != null
          ? '${nb.title} & ${nb.companionName}'
          : nb.title;

  InputDecoration _bookFieldDecoration({
    required String label,
    String? hint,
    IconData? icon,
  }) {
    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c, width: w),
        );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: AppColors.white,
      prefixIcon: icon != null
          ? Icon(icon, size: 18, color: AppColors.sage)
          : null,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(const Color(0xFFDDD8CC), 0.5),
      enabledBorder: border(const Color(0xFFDDD8CC), 0.5),
      focusedBorder: border(AppColors.sage, 1.5),
    );
  }

  Widget _buildPreviewStep() {
    final coverColor = Color(int.parse(
        'FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        children: [
          // Animated book cover
          ScaleTransition(
            scale: _coverScale,
            child: _BookCoverPreview(
              notebook: _notebook!,
              coverColor: coverColor,
              coverPhotoUrl: _coverPhotoUrl,
              yearRange: _yearRange,
              highlights: _coverHighlights,
              // Aperçu WYSIWYG : piloté en direct par les champs éditables.
              title: _titleCtrl.text.trim().isEmpty
                  ? _defaultCoverTitle(_notebook!)
                  : _titleCtrl.text.trim(),
              subtitle: _subtitleCtrl.text.trim(),
            ),
          ),
          const SizedBox(height: 24),

          // ── Personnalise ton livre (titre + sous-titre éditables) ──────
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '✏️ Personnalise ton livre',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textMedium,
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _titleCtrl,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
            decoration: _bookFieldDecoration(
              label: 'Titre du livre',
              icon: Icons.edit_outlined,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _subtitleCtrl,
            textAlign: TextAlign.center,
            textCapitalization: TextCapitalization.sentences,
            minLines: 1,
            maxLines: 2,
            style: const TextStyle(fontSize: 13, color: AppColors.textMedium),
            decoration: _bookFieldDecoration(
              label: 'Sous-titre (sur la couverture)',
              hint: 'Ex. Nos aventures 2025',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Text(
            _selectedMemoryIds.length == _memories.length
                ? '${_memories.length} souvenir${_memories.length != 1 ? 's' : ''} · ${DateTime.now().year}'
                : '${_selectedMemoryIds.length}/${_memories.length} souvenirs sélectionnés',
            style: const TextStyle(color: AppColors.textMedium, fontSize: 12),
            textAlign: TextAlign.center,
          ),

          // ── Memory selection ───────────────────────────────────────────
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _openMemorySelection,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.checklist_outlined, size: 18, color: AppColors.sage),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _selectedMemoryIds.length == _memories.length
                          ? 'Tous les souvenirs inclus'
                          : '${_selectedMemoryIds.length} souvenir${_selectedMemoryIds.length != 1 ? 's' : ''} sur ${_memories.length} inclus',
                      style: const TextStyle(color: AppColors.textDark, fontSize: 13),
                    ),
                  ),
                  const Text('Modifier', style: TextStyle(color: AppColors.sage, fontSize: 13, fontWeight: FontWeight.w500)),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right, color: AppColors.sage, size: 18),
                ],
              ),
            ),
          ),

          // ── Photo preview ──────────────────────────────────────────────
          _buildPhotoPreview(),

          const SizedBox(height: 24),

          // Create book / loading indicator
          if (_generating) ...[
            _ProgressBar(progress: _progress),
            const SizedBox(height: 12),
            Text(
              _loadingMessages[_msgIndex],
              style: const TextStyle(
                  color: AppColors.textMedium, fontSize: 13, fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            ElevatedButton.icon(
              onPressed: _selectedMemories.isEmpty ? null : _generate,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('Créer le livre'),
              style: ElevatedButton.styleFrom(
                disabledBackgroundColor: AppColors.background,
                disabledForegroundColor: AppColors.softGray,
              ),
            ),
            if (_selectedMemories.isEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Sélectionne au moins un souvenir.',
                style: TextStyle(color: AppColors.textMedium, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Step 1: Format selection ───────────────────────────────────────────────

  // Collect all photo URLs from selected memories (mediaUrls first, fallback to photoUrl)
  List<String> get _allPhotoUrls {
    final urls = <String>[];
    for (final m in _selectedMemories) {
      if (m.mediaUrls.isNotEmpty) {
        urls.addAll(m.mediaUrls);
      } else if (m.photoUrl != null && m.photoUrl!.isNotEmpty) {
        urls.add(m.photoUrl!);
      }
    }
    return urls;
  }

  // ── Book preview (swipeable pages) ────────────────────────────────────────

  Widget _buildBookPreview() {
    if (_previewPdfBytes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return _PdfPreviewViewer(
      pdfBytes: _previewPdfBytes!,
      pageCount: _previewPageCount,
      onChooseFormat: () => setState(() {
        _showPreview = false;
        _step = 1;
      }),
    );
  }

  Widget _buildPhotoPreview() {
    final allUrls = _allPhotoUrls;
    if (allUrls.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(Icons.photo_library_outlined,
                size: 16, color: AppColors.textMedium),
            const SizedBox(width: 6),
            Text(
              '${allUrls.length} photo${allUrls.length > 1 ? 's' : ''} · Tape pour choisir la couverture',
              style: const TextStyle(
                  color: AppColors.textMedium,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 78,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: allUrls.length,
            itemBuilder: (_, i) {
              final url = allUrls[i];
              final isSelected = _coverPhotoUrl == url;
              return GestureDetector(
                onTap: () => setState(() {
                  _coverPhotoUrl = isSelected ? null : url;
                }),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: isSelected
                        ? Border.all(color: AppColors.sage, width: 2.5)
                        : null,
                  ),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(isSelected ? 6 : 8),
                        child: CachedNetworkImage(
                          imageUrl: url,
                          width: 70, height: 70,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            width: 70, height: 70,
                            color: AppColors.background,
                            child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            width: 70, height: 70,
                            color: AppColors.background,
                            child: const Icon(Icons.broken_image_outlined,
                                color: AppColors.softGray, size: 20),
                          ),
                        ),
                      ),
                      if (isSelected)
                        Positioned(
                          right: 3, top: 3,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: AppColors.sage,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.check, color: Colors.white, size: 12),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (_coverPhotoUrl != null) ...[
          const SizedBox(height: 6),
          Text(
            'Photo de couverture sélectionnée · Tape à nouveau pour annuler',
            style: TextStyle(
                color: AppColors.sage.withOpacity(0.8),
                fontSize: 11,
                fontStyle: FontStyle.italic),
          ),
          // Option : ne pas répéter la photo de couverture dans les pages.
          InkWell(
            onTap: () => setState(
                () => _excludeCoverPhotoFromBook = !_excludeCoverPhotoFromBook),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _excludeCoverPhotoFromBook
                        ? Icons.check_box
                        : Icons.check_box_outline_blank,
                    size: 18,
                    color: AppColors.sage,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Ne pas répéter cette photo dans le livre',
                      style:
                          TextStyle(color: AppColors.textDark, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFormatStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quel format ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Choisis comment tu veux recevoir ton livre.',
            style: TextStyle(color: AppColors.textMedium, fontSize: 14),
          ),
          const SizedBox(height: 24),
          _FormatCard(
            emoji: '📱',
            title: 'PDF Digital',
            subtitle: 'Télécharge et imprime toi-même',
            price: 'Gratuit',
            priceSub: '$_pages pages',
            priceColor: AppColors.sage,
            selected: _selectedFormat == 'digital',
            onTap: () => setState(() => _selectedFormat = 'digital'),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            emoji: '📗',
            title: 'Couverture souple',
            subtitle: 'Livre 21×28 cm · 5–7 jours',
            price: _priceLabel('soft'),
            priceSub: '$_printedPages pages',
            priceColor: AppColors.amber,
            selected: _selectedFormat == 'printed' && _coverType == 'soft',
            onTap: () => setState(() { _selectedFormat = 'printed'; _coverType = 'soft'; }),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            emoji: '📕',
            title: 'Couverture rigide',
            subtitle: 'Livre 21×28 cm · couverture cartonnée',
            price: _priceLabel('hard'),
            priceSub: '$_printedPages pages',
            priceColor: AppColors.amber,
            selected: _selectedFormat == 'printed' && _coverType == 'hard',
            onTap: () => setState(() { _selectedFormat = 'printed'; _coverType = 'hard'; }),
          ),
          const SizedBox(height: 12),
          // Bouton info : grille tarifaire selon le nombre de pages.
          Center(
            child: TextButton.icon(
              onPressed: _showPricingTable,
              icon: const Icon(Icons.info_outline, size: 16, color: AppColors.textMedium),
              label: const Text(
                'Comment le prix est calculé ?',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13),
              ),
            ),
          ),
          if (_selectedFormat == 'printed') ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.amber.withOpacity(0.3)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: AppColors.amber),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Les livres imprimés font 28 pages minimum. Si ton livre est '
                      'plus court, des pages blanches sont ajoutées à la fin.',
                      style: TextStyle(fontSize: 12, color: AppColors.textMedium),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => setState(() => _step = 2),
            child: Text(_selectedFormat == 'digital'
                ? 'Continuer'
                : 'Continuer · ${_priceLabel(_coverType)}'),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              '🔒  Paiement sécurisé',
              style:
                  TextStyle(color: AppColors.textMedium, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2: Download or Order ──────────────────────────────────────────────

  Widget _buildOrderStep() {
    final isDigital = _selectedFormat == 'digital';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isDigital ? 'Ton PDF est prêt' : 'Récapitulatif commande',
            style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 20),

          // Order summary card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
            ),
            child: Column(
              children: [
                _OrderRow(
                    label: 'Carnet', value: _notebook!.title),
                const Divider(height: 24, color: Color(0xFFDDD8CC)),
                _OrderRow(
                    label: 'Souvenirs',
                    value: '${_selectedMemories.length} souvenirs'),
                const Divider(height: 24, color: Color(0xFFDDD8CC)),
                _OrderRow(
                    label: 'Format',
                    value: switch (_selectedFormat) {
                      'digital' => 'PDF Digital',
                      'printed' => _coverType == 'hard' ? 'Couverture rigide' : 'Couverture souple',
                      _ => 'PDF Digital',
                    }),
                if (!isDigital) ...[
                  const Divider(height: 24, color: Color(0xFFDDD8CC)),
                  _OrderRow(
                    label: 'Pages',
                    value: '$_printedPages pages'),
                  const Divider(height: 24, color: Color(0xFFDDD8CC)),
                  _OrderRow(
                    label: 'Total',
                    value: _priceLabel(_coverType),
                    bold: true,
                    valueColor: AppColors.amber,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 28),

          if (isDigital) ...[
            _exporting
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton.icon(
                    onPressed: _downloadPdf,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Télécharger le PDF'),
                  ),
          ] else ...[
            // Formulaire adresse
            Form(
              key: _addressKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Adresse de livraison',
                    style: TextStyle(fontFamily: 'PlayfairDisplay', fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textDark)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _AddressField(_firstNameCtrl, 'Prénom', required: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _AddressField(_lastNameCtrl, 'Nom', required: true)),
                  ]),
                  const SizedBox(height: 10),
                  _AddressField(_streetCtrl, 'Rue et numéro', required: true),
                  const SizedBox(height: 10),
                  Row(children: [
                    SizedBox(width: 100, child: _AddressField(_npaCtrl, 'NPA', required: true, keyboardType: TextInputType.number)),
                    const SizedBox(width: 10),
                    Expanded(child: _AddressField(_cityCtrl, 'Ville', required: true)),
                  ]),
                  const SizedBox(height: 10),
                  _AddressField(_countryCtrl, 'Pays', required: true),
                  const SizedBox(height: 20),
                  if (_ordering) ...[
                    const LinearProgressIndicator(
                      backgroundColor: Color(0xFFEEEBE3),
                      valueColor: AlwaysStoppedAnimation<Color>(AppColors.sage),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _orderMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.textMedium,
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ] else
                    ElevatedButton(
                      onPressed: _placeOrder,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.amber,
                        foregroundColor: Colors.white,
                      ),
                      child: Text('Commander · ${_priceLabel(_coverType)}'),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _step = 1),
              child: const Text(
                '← Changer le format',
                style:
                    TextStyle(color: AppColors.textMedium, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMemorySelection() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemorySelectionSheet(
        memories: _memories,
        selectedIds: _selectedMemoryIds,
        onChanged: (ids) => setState(() {
          _selectedMemoryIds = ids;
          // Reset cover photo if it no longer belongs to selected memories
          if (_coverPhotoUrl != null) {
            final allUrls = _allPhotoUrls;
            if (!allUrls.contains(_coverPhotoUrl)) _coverPhotoUrl = null;
          }
        }),
      ),
    );
  }

  // Feuille d'information : grille tarifaire selon le nombre de pages.
  Future<void> _showPricingTable() async {
    // Exemples de paliers (pages imprimées) — le prix de TON livre est mis en
    // évidence si son nombre de pages tombe dans la liste.
    const samples = [28, 40, 60, 80, 100, 150, 200];
    final mine = _printedPages;
    final rows = {...samples, mine}.toList()..sort();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.softGray.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Comment le prix est calculé',
                style: TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Prix de base ${BookPricing.format(BookPricing.softBase)} '
                '(souple) / ${BookPricing.format(BookPricing.hardBase)} '
                '(rigide) jusqu\'à ${BookPricing.includedPages} pages, puis '
                '+${BookPricing.format(BookPricing.perExtraPage)} par page. '
                'Les livres imprimés font 28 pages minimum.',
                style: const TextStyle(color: AppColors.textMedium, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              // En-tête du tableau
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Expanded(flex: 2, child: Text('Pages', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark))),
                    Expanded(flex: 3, child: Text('Souple', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark))),
                    Expanded(flex: 3, child: Text('Rigide', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: AppColors.textDark))),
                  ],
                ),
              ),
              for (final p in rows)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
                  decoration: BoxDecoration(
                    color: p == mine ? AppColors.sage.withOpacity(0.10) : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          p == mine ? '$p · ton livre' : '$p',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textDark,
                            fontWeight: p == mine ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(BookPricing.price(coverType: 'soft', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(BookPricing.price(coverType: 'hard', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                '🔒  Paiement sécurisé.',
                style: TextStyle(color: AppColors.softGray, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Book cover preview ────────────────────────────────────────────────────────

class _BookCoverPreview extends StatelessWidget {
  final NotebookModel notebook;
  final Color coverColor;
  final String? coverPhotoUrl;
  final String yearRange;
  final List<String> highlights;
  final String title;
  final String? subtitle;

  const _BookCoverPreview({
    required this.notebook,
    required this.coverColor,
    required this.title,
    this.subtitle,
    this.coverPhotoUrl,
    this.yearRange = '',
    this.highlights = const [],
  });

  @override
  Widget build(BuildContext context) {
    final titleText = title;
    final hasSubtitle = subtitle != null && subtitle!.trim().isNotEmpty;

    return Center(
      child: Container(
        width: 180,
        height: 240,
        decoration: BoxDecoration(
          color: coverColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: coverColor.withOpacity(0.4),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Cover photo background
            if (coverPhotoUrl != null)
              CachedNetworkImage(
                imageUrl: coverPhotoUrl!,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: coverColor),
                errorWidget: (_, __, ___) => Container(color: coverColor),
              ),
            // Semi-transparent overlay when photo is set
            if (coverPhotoUrl != null)
              Container(color: Colors.black.withOpacity(0.38)),
            // "folio" top-right
            Positioned(
              top: 10, right: 12,
              child: Text(
                'carnet',
                style: TextStyle(
                  fontSize: 9, color: Colors.white.withOpacity(0.85),
                  fontStyle: FontStyle.italic, letterSpacing: 1.5,
                ),
              ),
            ),
            // Cover content
            if (coverPhotoUrl != null)
              // Photo version : bandeau bas compact, 2 colonnes (titre à gauche,
              // liste des souvenirs à droite) — laisse plus de place à la photo.
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.white.withOpacity(0.94),
                  padding: const EdgeInsets.fromLTRB(10, 7, 10, 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              titleText,
                              style: const TextStyle(
                                fontFamily: 'PlayfairDisplay', fontSize: 11,
                                fontWeight: FontWeight.bold, color: Color(0xFF2D2416),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (hasSubtitle) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitle!,
                                style: const TextStyle(
                                    fontSize: 7.5, color: Color(0xFF6B6B6B)),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 3),
                            Container(width: 16, height: 1, color: coverColor),
                            const SizedBox(height: 3),
                            Text(
                              yearRange.isNotEmpty ? yearRange : '${DateTime.now().year}',
                              style: const TextStyle(fontSize: 6.5, color: Color(0xFF8C8C8C), letterSpacing: 1.5),
                            ),
                          ],
                        ),
                      ),
                      if (highlights.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: highlights
                                .take(15)
                                .map((h) => Text(
                                      '· $h',
                                      style: const TextStyle(
                                          fontSize: 5.5,
                                          color: Color(0xFF8C8C8C),
                                          height: 1.3),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                    ))
                                .toList(),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              )
            else
              // Solid color version: centered
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(notebook.emoji, style: const TextStyle(fontSize: 48)),
                  const SizedBox(height: 14),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      titleText,
                      style: const TextStyle(
                        fontFamily: 'PlayfairDisplay', fontSize: 14,
                        fontWeight: FontWeight.bold, color: Colors.white, height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (hasSubtitle) ...[
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                            fontSize: 9, color: Colors.white.withOpacity(0.85)),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(width: 30, height: 1, color: Colors.white.withOpacity(0.6)),
                  const SizedBox(height: 7),
                  Text(
                    yearRange.isNotEmpty ? yearRange : '${DateTime.now().year}',
                    style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.8), letterSpacing: 2),
                  ),
                  if (highlights.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(width: 32, height: 0.5, color: Colors.white.withOpacity(0.4)),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        highlights.take(3).map((h) => '· $h').join('  '),
                        style: TextStyle(fontSize: 7, color: Colors.white.withOpacity(0.75), fontStyle: FontStyle.italic),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

// ── Progress bar ──────────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  final double progress;
  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: AppColors.background,
            valueColor:
                const AlwaysStoppedAnimation<Color>(AppColors.sage),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${(progress * 100).round()}%',
          style: const TextStyle(
              color: AppColors.textMedium, fontSize: 12),
        ),
      ],
    );
  }
}

// ── Format card ───────────────────────────────────────────────────────────────

class _FormatCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final String price;
  final String? priceSub; // ex. « 28 pages » sous le prix
  final Color priceColor;
  final bool selected;
  final VoidCallback onTap;

  const _FormatCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.price,
    this.priceSub,
    required this.priceColor,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sage.withOpacity(0.06)
              : AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color:
                selected ? AppColors.sage : const Color(0xFFDDD8CC),
            width: selected ? 2 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.textDark,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        color: AppColors.textMedium, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  price,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: priceColor,
                  ),
                ),
                if (priceSub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    priceSub!,
                    style: const TextStyle(
                        color: AppColors.textMedium, fontSize: 11),
                  ),
                ],
              ],
            ),
            const SizedBox(width: 8),
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: selected ? AppColors.sage : AppColors.softGray,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Order row ─────────────────────────────────────────────────────────────────

class _OrderRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;

  const _OrderRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
              color: AppColors.textMedium, fontSize: 14),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppColors.textDark,
            fontWeight:
                bold ? FontWeight.w700 : FontWeight.w500,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

// ── PDF preview viewer — affiche les pages du VRAI PDF (rastérisées) ──────────
// L'aperçu est strictement identique au fichier téléchargé / envoyé à Gelato :
// on génère les mêmes octets PDF puis on rastérise chaque page à la demande.

class _PdfPreviewViewer extends StatefulWidget {
  final Uint8List pdfBytes;
  final int pageCount;
  final VoidCallback onChooseFormat;

  const _PdfPreviewViewer({
    required this.pdfBytes,
    required this.pageCount,
    required this.onChooseFormat,
  });

  @override
  State<_PdfPreviewViewer> createState() => _PdfPreviewViewerState();
}

class _PdfPreviewViewerState extends State<_PdfPreviewViewer> {
  late final PageController _ctrl;
  int _current = 0;

  // Cache des pages déjà rastérisées (index → PNG).
  final Map<int, Uint8List> _cache = {};
  final Map<int, Future<Uint8List>> _inflight = {};

  // Format du document Gelato (218 × 288 mm) → ratio des cartes de page.
  static const double _pageAspect = 218 / 288;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
    _ctrl.addListener(() {
      final p = _ctrl.page?.round() ?? 0;
      if (p != _current && mounted) setState(() => _current = p);
    });
  }

  @override
  void didUpdateWidget(covariant _PdfPreviewViewer old) {
    super.didUpdateWidget(old);
    // Nouveau PDF (sélection/titre modifiés) → on jette le cache.
    if (!identical(old.pdfBytes, widget.pdfBytes)) {
      _cache.clear();
      _inflight.clear();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // Rastérise une page (résolution adaptée à un écran de téléphone) et garde le
  // résultat en cache. Les appels concurrents sur la même page sont fusionnés.
  Future<Uint8List> _rasterPage(int index) {
    final cached = _cache[index];
    if (cached != null) return Future.value(cached);
    return _inflight[index] ??= () async {
      final raster = await Printing.raster(
        widget.pdfBytes,
        pages: [index],
        dpi: 140,
      ).first;
      final png = await raster.toPng();
      if (mounted) _cache[index] = png;
      _inflight.remove(index);
      return png;
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Page counter
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '${_current + 1} / ${widget.pageCount}',
            style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
          ),
        ),
        // PageView
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: PageView.builder(
              controller: _ctrl,
              itemCount: widget.pageCount,
              itemBuilder: (_, i) => _PdfPageCard(
                aspect: _pageAspect,
                future: _rasterPage(i),
              ),
            ),
          ),
        ),
        // Dot indicators
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.pageCount.clamp(0, 20),
              (i) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: i == _current ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: i == _current
                      ? AppColors.sage
                      : AppColors.softGray.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
        // CTA
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          child: ElevatedButton(
            onPressed: widget.onChooseFormat,
            child: const Text('Choisir le format →'),
          ),
        ),
      ],
    );
  }
}

// Une page du PDF rastérisée, dans une carte blanche au ratio du document.
class _PdfPageCard extends StatelessWidget {
  final double aspect;
  final Future<Uint8List> future;

  const _PdfPageCard({required this.aspect, required this.future});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.hardEdge,
        child: AspectRatio(
          aspectRatio: aspect,
          child: FutureBuilder<Uint8List>(
            future: future,
            builder: (_, snap) {
              if (snap.hasData) {
                return Image.memory(snap.data!, fit: BoxFit.cover);
              }
              if (snap.hasError) {
                return const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: AppColors.softGray, size: 28),
                );
              }
              return const Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Memory selection bottom sheet ─────────────────────────────────────────────

class _MemorySelectionSheet extends StatefulWidget {
  final List<MemoryModel> memories;
  final Set<String> selectedIds;
  final ValueChanged<Set<String>> onChanged;

  const _MemorySelectionSheet({
    required this.memories,
    required this.selectedIds,
    required this.onChanged,
  });

  @override
  State<_MemorySelectionSheet> createState() => _MemorySelectionSheetState();
}

class _MemorySelectionSheetState extends State<_MemorySelectionSheet> {
  late Set<String> _local;

  @override
  void initState() {
    super.initState();
    _local = Set.from(widget.selectedIds);
  }

  String _formatDate(MemoryModel m) {
    if (m.dateLabel != null) return m.dateLabel!;
    final d = m.date;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _typeLabel(String type) => switch (type) {
    'anecdote' => 'Anecdote',
    'growth' => 'Croissance',
    'event' => 'Événement',
    'milestone' => 'Étape',
    'travel' => 'Voyage',
    'health' => 'Santé',
    _ => type,
  };

  int get _photoCount {
    int n = 0;
    for (final id in _local) {
      final m = widget.memories.firstWhere((m) => m.id == id, orElse: () => widget.memories.first);
      if (m.mediaUrls.isNotEmpty) {
        n += m.mediaUrls.length;
      } else if (m.photoUrl != null && m.photoUrl!.isNotEmpty) {
        n++;
      }
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      maxChildSize: 0.96,
      minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Row(
                children: [
                  const Text(
                    'Souvenirs à inclure',
                    style: TextStyle(
                      fontFamily: 'PlayfairDisplay',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                    onPressed: () => setState(() {
                      if (_local.length == widget.memories.length) {
                        _local.clear();
                      } else {
                        _local = widget.memories.map((m) => m.id).toSet();
                      }
                    }),
                    child: Text(
                      _local.length == widget.memories.length ? 'Tout décocher' : 'Tout cocher',
                      style: const TextStyle(color: AppColors.sage, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            // Memory list
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemCount: widget.memories.length,
                itemBuilder: (_, i) {
                  final m = widget.memories[i];
                  final selected = _local.contains(m.id);
                  final hasPhotos = m.mediaUrls.isNotEmpty ||
                      (m.photoUrl != null && m.photoUrl!.isNotEmpty);
                  final photoCount = m.mediaUrls.isNotEmpty ? m.mediaUrls.length : (hasPhotos ? 1 : 0);
                  final preview = m.rawContent.length > 65
                      ? '${m.rawContent.substring(0, 65)}…'
                      : m.rawContent;

                  return InkWell(
                    onTap: () => setState(() {
                      selected ? _local.remove(m.id) : _local.add(m.id);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Checkbox
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 22, height: 22,
                            decoration: BoxDecoration(
                              color: selected ? AppColors.sage : AppColors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected ? AppColors.sage : const Color(0xFFCCC8BE),
                                width: 1.5,
                              ),
                            ),
                            child: selected
                                ? const Icon(Icons.check, size: 14, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          // Content
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      _formatDate(m),
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: selected ? AppColors.sage : AppColors.textMedium,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _typeLabel(m.type),
                                        style: const TextStyle(fontSize: 10, color: AppColors.textMedium),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  preview,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: selected ? AppColors.textDark : AppColors.textMedium,
                                    height: 1.4,
                                  ),
                                ),
                                if (hasPhotos) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.photo_outlined, size: 12, color: AppColors.sage.withOpacity(0.8)),
                                      const SizedBox(width: 3),
                                      Text(
                                        '$photoCount photo${photoCount > 1 ? 's' : ''}',
                                        style: TextStyle(fontSize: 11, color: AppColors.sage.withOpacity(0.8)),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            // Confirm button
            Padding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: Column(
                children: [
                  Text(
                    '${_local.length} souvenir${_local.length != 1 ? 's' : ''} · $_photoCount photo${_photoCount != 1 ? 's' : ''}',
                    style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _local.isEmpty
                          ? null
                          : () {
                              widget.onChanged(Set.from(_local));
                              Navigator.pop(context);
                            },
                      child: Text('Confirmer (${_local.length}/${widget.memories.length})'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _AddressField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool required;
  final TextInputType keyboardType;
  const _AddressField(this.controller, this.label,
      {this.required = false, this.keyboardType = TextInputType.text});

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    keyboardType: keyboardType,
    style: const TextStyle(fontSize: 14, color: AppColors.textDark),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 13, color: AppColors.textMedium),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      isDense: true,
    ),
    validator: required
        ? (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null
        : null,
  );
}
