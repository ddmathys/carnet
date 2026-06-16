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
import '../../core/models/book_settings.dart';
import '../../core/services/deepseek_service.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/order_service.dart';
import '../story/book_settings_sheet.dart';

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
  BookSettings _settings = const BookSettings();
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
    'J\'analyse les lieux…',
    'Je prépare les descriptions…',
    'Le livre prend forme…',
    'Presque prêt…',
  ];

  final _deepseek = DeepSeekService();

  List<MemoryModel> get _selectedMemories =>
      _memories.where((m) => _selectedMemoryIds.contains(m.id)).toList();

  // Nombre de pages estimé + prix (aligné sur les pages) pour les écrans.
  int get _estimatedPages => BookPricing.estimatePages(_selectedMemories);
  double _priceFor(String coverType) =>
      BookPricing.price(coverType: coverType, pages: _estimatedPages);
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
      if (result.length >= 5) break;
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

  Future<void> _generate() async {
    if (_selectedMemories.isEmpty) {
      _showSnack('Sélectionne au moins un souvenir avant de créer le livre.');
      return;
    }

    // If no AI needed, go directly to preview
    if (!_settings.locationComments) {
      setState(() => _showPreview = true);
      return;
    }

    // Generate location comments for memories that have a location
    final memoriesWithLocation = _selectedMemories
        .where((m) => m.location != null && m.location!.trim().isNotEmpty)
        .toList();

    if (memoriesWithLocation.isEmpty) {
      setState(() => _showPreview = true);
      return;
    }

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

    try {
      // Garde-fou : quoi qu'il arrive en aval, la barre aboutit. Sans
      // commentaires de lieux, on passe quand même à l'aperçu.
      final comments = await _deepseek
          .generateLocationComments(
            memories: memoriesWithLocation,
            tone: _settings.tone,
          )
          .timeout(const Duration(seconds: 45),
              onTimeout: () => <String, String>{});
      _progressTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _locationComments = comments;
        _progress = 1.0;
        _generating = false;
        _showPreview = true;
      });
    } catch (_) {
      _progressTimer?.cancel();
      if (!mounted) return;
      // Non-fatal: proceed to preview even without location comments
      setState(() { _generating = false; _showPreview = true; });
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
          actions: [
            if (_step == 0 && !_generating && !_showPreview)
              IconButton(
                icon: const Icon(Icons.tune_outlined, color: AppColors.textDark),
                tooltip: 'Paramètres',
                onPressed: _openSettings,
              ),
          ],
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
              label: Text(_settings.locationComments ? 'Créer le livre avec lieux' : 'Créer le livre'),
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
    final coverColor = Color(int.parse(
        'FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16));

    // Build page data: cover + photo pages (no AI chapters)
    final pages = <_PreviewPage>[];

    // Cover
    pages.add(_PreviewPage.cover(
      emoji: _notebook!.emoji,
      title: _notebook!.type == 'enfant' && _notebook!.companionName != null
          ? '${_notebook!.title} & ${_notebook!.companionName}'
          : _notebook!.title,
      year: _yearRange,
      color: coverColor,
      coverPhotoUrl: _coverPhotoUrl,
      highlights: _coverHighlights,
    ));

    // Photo pages (mirrors smart PDF layout: odd → 3-photo page)
    final photoEntries = <_PreviewPhotoEntry>[];
    final shownMemIds = <String>{};
    for (final m in _selectedMemories) {
      final urls = m.mediaUrls.isNotEmpty
          ? m.mediaUrls
          : (m.photoUrl != null && m.photoUrl!.isNotEmpty ? [m.photoUrl!] : <String>[]);
      for (final url in urls) {
        final showCaption = shownMemIds.add(m.id);
        final caption = showCaption ? m.rawContent : null;
        final date = m.dateLabel ??
            '${m.date.day.toString().padLeft(2, '0')}/${m.date.month.toString().padLeft(2, '0')}/${m.date.year}';
        photoEntries.add(_PreviewPhotoEntry(url: url, caption: caption, date: date));
      }
    }
    for (int pi = 0; pi < photoEntries.length; pi += 2) {
      pages.add(_PreviewPage.photos(
        entry1: photoEntries[pi],
        entry2: pi + 1 < photoEntries.length ? photoEntries[pi + 1] : null,
      ));
    }

    // Text-only memories (no photos)
    for (final m in _selectedMemories) {
      final urls = m.mediaUrls.isNotEmpty
          ? m.mediaUrls
          : (m.photoUrl != null && m.photoUrl!.isNotEmpty ? [m.photoUrl!] : <String>[]);
      if (urls.isEmpty && m.type != 'taille_poids') {
        final date = m.dateLabel ??
            '${m.date.day.toString().padLeft(2, '0')}/${m.date.month.toString().padLeft(2, '0')}/${m.date.year}';
        pages.add(_PreviewPage.textOnly(
          date: date,
          title: m.title?.isNotEmpty == true ? m.title : null,
          content: m.rawContent,
          location: m.location?.isNotEmpty == true ? m.location : null,
        ));
      }
    }

    return _BookPageViewer(
      pages: pages,
      coverColor: coverColor,
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
            priceColor: AppColors.sage,
            selected: _selectedFormat == 'digital',
            onTap: () => setState(() => _selectedFormat = 'digital'),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            emoji: '📗',
            title: 'Couverture souple',
            subtitle: 'Livre 21×28 cm · ~$_estimatedPages pages · 5–7 jours',
            price: _priceLabel('soft'),
            priceColor: AppColors.amber,
            selected: _selectedFormat == 'printed' && _coverType == 'soft',
            onTap: () => setState(() { _selectedFormat = 'printed'; _coverType = 'soft'; }),
          ),
          const SizedBox(height: 12),
          _FormatCard(
            emoji: '📕',
            title: 'Couverture rigide',
            subtitle: 'Livre 21×28 cm · couverture cartonnée · ~$_estimatedPages pages',
            price: _priceLabel('hard'),
            priceColor: AppColors.amber,
            selected: _selectedFormat == 'printed' && _coverType == 'hard',
            onTap: () => setState(() { _selectedFormat = 'printed'; _coverType = 'hard'; }),
          ),
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
                    value: '~$_estimatedPages pages'),
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

  Future<void> _openSettings() async {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => BookSettingsSheet(
        initial: _settings,
        onApply: (updated, regenerate) {
          setState(() => _settings = updated);
          if (regenerate) _generate();
        },
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
              // Photo version: title box at bottom
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.white.withOpacity(0.94),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        titleText,
                        style: const TextStyle(
                          fontFamily: 'PlayfairDisplay', fontSize: 13,
                          fontWeight: FontWeight.bold, color: Color(0xFF2D2416),
                        ),
                      ),
                      if (hasSubtitle) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                              fontSize: 8.5, color: Color(0xFF6B6B6B)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Container(width: 18, height: 1, color: coverColor),
                      const SizedBox(height: 4),
                      Text(
                        yearRange.isNotEmpty ? yearRange : '${DateTime.now().year}',
                        style: const TextStyle(fontSize: 8, color: Color(0xFF8C8C8C), letterSpacing: 2),
                      ),
                      if (highlights.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          highlights.take(3).map((h) => '· $h').join('  '),
                          style: const TextStyle(fontSize: 7, color: Color(0xFF8C8C8C), fontStyle: FontStyle.italic),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
  final Color priceColor;
  final bool selected;
  final VoidCallback onTap;

  const _FormatCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.price,
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
            Text(
              price,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: priceColor,
              ),
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

// ── Preview data models ───────────────────────────────────────────────────────

enum _PageType { cover, chapter, photos, textOnly }

class _PreviewPhotoEntry {
  final String url;
  final String? caption; // null = not first occurrence of this memory
  final String date;
  const _PreviewPhotoEntry({required this.url, this.caption, required this.date});
}

class _PreviewPage {
  final _PageType type;
  // cover
  final String? emoji;
  final String? title;
  final String? year;
  final Color? color;
  final String? coverPhotoUrl;
  final List<String> highlights;
  // chapter (kept for type completeness but unused)
  final String? chapterTitle;
  final String? body;
  // photos (up to 3)
  final _PreviewPhotoEntry? entry1;
  final _PreviewPhotoEntry? entry2;
  final _PreviewPhotoEntry? entry3;
  // textOnly
  final String? textDate;
  final String? textTitle;
  final String? textContent;
  final String? textLocation;

  const _PreviewPage._({
    required this.type,
    this.emoji, this.title, this.year, this.color, this.coverPhotoUrl,
    this.highlights = const [],
    this.chapterTitle, this.body,
    this.entry1, this.entry2, this.entry3,
    this.textDate, this.textTitle, this.textContent, this.textLocation,
  });

  factory _PreviewPage.cover({
    required String emoji, required String title,
    required String year, required Color color,
    String? coverPhotoUrl,
    List<String> highlights = const [],
  }) => _PreviewPage._(type: _PageType.cover,
      emoji: emoji, title: title, year: year, color: color,
      coverPhotoUrl: coverPhotoUrl, highlights: highlights);

  factory _PreviewPage.chapter({required String title, required String body}) =>
      _PreviewPage._(type: _PageType.chapter, chapterTitle: title, body: body);

  factory _PreviewPage.photos({
    required _PreviewPhotoEntry entry1,
    _PreviewPhotoEntry? entry2,
    _PreviewPhotoEntry? entry3,
  }) => _PreviewPage._(type: _PageType.photos, entry1: entry1, entry2: entry2, entry3: entry3);

  factory _PreviewPage.textOnly({
    required String date,
    String? title,
    required String content,
    String? location,
  }) => _PreviewPage._(
    type: _PageType.textOnly,
    textDate: date,
    textTitle: title,
    textContent: content,
    textLocation: location,
  );
}

// ── Book page viewer widget ───────────────────────────────────────────────────

class _BookPageViewer extends StatefulWidget {
  final List<_PreviewPage> pages;
  final Color coverColor;
  final VoidCallback onChooseFormat;

  const _BookPageViewer({
    required this.pages,
    required this.coverColor,
    required this.onChooseFormat,
  });

  @override
  State<_BookPageViewer> createState() => _BookPageViewerState();
}

class _BookPageViewerState extends State<_BookPageViewer> {
  late final PageController _ctrl;
  int _current = 0;

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
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Page counter
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '${_current + 1} / ${widget.pages.length}',
            style: const TextStyle(color: AppColors.textMedium, fontSize: 13),
          ),
        ),
        // PageView
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: PageView.builder(
              controller: _ctrl,
              itemCount: widget.pages.length,
              itemBuilder: (_, i) => _buildPage(widget.pages[i]),
            ),
          ),
        ),
        // Dot indicators
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.pages.length.clamp(0, 20),
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

  Widget _buildPage(_PreviewPage page) {
    return Container(
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
      child: switch (page.type) {
        _PageType.cover => _buildCoverPage(page),
        _PageType.chapter => _buildChapterPage(page),
        _PageType.photos => _buildPhotosPage(page),
        _PageType.textOnly => _buildTextOnlyPage(page),
      },
    );
  }

  Widget _buildCoverPage(_PreviewPage p) {
    final hasPhoto = p.coverPhotoUrl != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Background: photo or solid color
        if (hasPhoto)
          SizedBox.expand(
            child: CachedNetworkImage(
              imageUrl: p.coverPhotoUrl!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              placeholder: (_, __) => Container(color: p.color),
              errorWidget: (_, __, ___) => Container(color: p.color),
            ),
          )
        else
          Container(color: p.color),
        // Overlay
        if (hasPhoto)
          Container(color: Colors.black.withOpacity(0.28)),
        // "folio" top-right
        Positioned(
          top: 12, right: 14,
          child: Text(
            'folio',
            style: TextStyle(
              fontSize: 11, color: Colors.white.withOpacity(0.9),
              fontStyle: FontStyle.italic, letterSpacing: 1.5,
            ),
          ),
        ),
        // Content
        if (hasPhoto)
          // Photo: title box at bottom
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              color: Colors.white.withOpacity(0.95),
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.title ?? '',
                    style: const TextStyle(
                      fontFamily: 'PlayfairDisplay', fontSize: 18,
                      fontWeight: FontWeight.bold, color: Color(0xFF2D2416),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(width: 22, height: 1.5, color: p.color),
                  const SizedBox(height: 6),
                  Text(
                    'LIVRE DE SOUVENIRS  ·  ${p.year}',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF8C8C8C), letterSpacing: 1.5),
                  ),
                  if (p.highlights.isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(
                      p.highlights.take(3).map((h) => '· $h').join('  '),
                      style: const TextStyle(fontSize: 9, color: Color(0xFF8C8C8C), fontStyle: FontStyle.italic),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          )
        else
          // Solid color: centered
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(p.emoji ?? '📔', style: const TextStyle(fontSize: 54)),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    p.title ?? '',
                    style: const TextStyle(
                      fontFamily: 'PlayfairDisplay', fontSize: 20,
                      fontWeight: FontWeight.bold, color: Colors.white, height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 14),
                Container(width: 36, height: 1.5, color: Colors.white54),
                const SizedBox(height: 10),
                Text(
                  p.year ?? '',
                  style: const TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2),
                ),
                if (p.highlights.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(width: 30, height: 0.5, color: Colors.white38),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      p.highlights.take(3).map((h) => '· $h').join('  '),
                      style: const TextStyle(color: Colors.white70, fontSize: 9, fontStyle: FontStyle.italic),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildChapterPage(_PreviewPage p) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((p.chapterTitle ?? '').isNotEmpty) ...[
            Text(
              p.chapterTitle!,
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 32, height: 2,
              decoration: BoxDecoration(
                color: AppColors.sage,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            p.body ?? '',
            style: const TextStyle(
              color: AppColors.textDark,
              fontSize: 13,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotosPage(_PreviewPage p) {
    final entries = [p.entry1, p.entry2, p.entry3].whereType<_PreviewPhotoEntry>().toList();
    return _PreviewPhotoPage(entries: entries);
  }

  Widget _buildTextOnlyPage(_PreviewPage p) {
    return Container(
      color: const Color(0xFFF9F6EE),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.textDate != null)
            Text(
              p.textDate!,
              style: TextStyle(
                fontSize: 11,
                color: widget.coverColor,
                fontStyle: FontStyle.italic,
                letterSpacing: 0.5,
              ),
            ),
          const SizedBox(height: 8),
          if (p.textTitle != null && p.textTitle!.isNotEmpty) ...[
            Text(
              p.textTitle!,
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2D2416),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Container(
            width: 28, height: 1.5,
            color: widget.coverColor,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Text(
              p.textContent ?? '',
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF2D2416),
                height: 1.7,
              ),
            ),
          ),
          if (p.textLocation != null && p.textLocation!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.place_outlined, size: 11, color: widget.coverColor),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    p.textLocation!,
                    style: TextStyle(
                      fontSize: 10,
                      color: widget.coverColor,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Preview photo page (orientation-aware layout) ─────────────────────────────

class _PreviewPhotoPage extends StatefulWidget {
  final List<_PreviewPhotoEntry> entries;
  const _PreviewPhotoPage({required this.entries});

  @override
  State<_PreviewPhotoPage> createState() => _PreviewPhotoPageState();
}

class _PreviewPhotoPageState extends State<_PreviewPhotoPage> {
  final Map<String, bool> _portraitMap = {};
  final Map<String, ImageStreamListener> _listeners = {};

  @override
  void initState() {
    super.initState();
    for (final e in widget.entries) {
      _detectOrientation(e.url);
    }
  }

  void _detectOrientation(String url) {
    final provider = NetworkImage(url);
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (mounted) {
        setState(() => _portraitMap[url] = info.image.height > info.image.width);
      }
      stream.removeListener(listener);
      _listeners.remove(url);
    }, onError: (_, __) {
      stream.removeListener(listener);
      _listeners.remove(url);
    });
    _listeners[url] = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    for (final entry in _listeners.entries) {
      NetworkImage(entry.key).resolve(ImageConfiguration.empty).removeListener(entry.value);
    }
    super.dispose();
  }

  bool _isPortrait(String url) => _portraitMap[url] ?? true;

  Widget _photoBlock(_PreviewPhotoEntry entry, {bool compact = false}) {
    final maxChars = compact ? 60 : 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: double.infinity,
              color: const Color(0xFFF9F6EE),
              child: CachedNetworkImage(
                imageUrl: entry.url,
                fit: BoxFit.contain,
                width: double.infinity,
                placeholder: (_, __) => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                errorWidget: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: AppColors.softGray),
              ),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(entry.date,
          style: const TextStyle(fontSize: 9, color: AppColors.sage, fontStyle: FontStyle.italic)),
        if (entry.caption != null)
          Text(
            entry.caption!.length > maxChars ? '${entry.caption!.substring(0, maxChars)}…' : entry.caption!,
            style: const TextStyle(color: AppColors.textDark, fontSize: 10, height: 1.3),
            maxLines: 2, overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entries;
    if (e.isEmpty) return const SizedBox.shrink();

    // Single photo
    if (e.length == 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(children: [Expanded(child: _photoBlock(e[0]))]),
      );
    }

    // 2 photos: side by side if both portrait, stacked if landscape
    final sideBySide = _isPortrait(e[0].url) && _isPortrait(e[1].url);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: sideBySide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _photoBlock(e[0], compact: true)),
                const SizedBox(width: 6),
                const VerticalDivider(width: 1, color: Color(0xFFEEEEEE)),
                const SizedBox(width: 6),
                Expanded(child: _photoBlock(e[1], compact: true)),
              ],
            )
          : Column(
              children: [
                Expanded(child: _photoBlock(e[0])),
                const SizedBox(height: 8),
                const Divider(height: 1, color: Color(0xFFEEEEEE)),
                const SizedBox(height: 8),
                Expanded(child: _photoBlock(e[1])),
              ],
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
