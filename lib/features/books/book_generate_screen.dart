import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:printing/printing.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/pdf_service.dart';
import 'pdf_viewer_screen.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/tag_service.dart';

/// Génération d'un livre à partir d'une sélection de SOUVENIRS (plus d'un
/// carnet) : ils viennent d'un tag, d'un choix manuel, ou des deux.
class BookGenerateScreen extends StatefulWidget {
  /// Les souvenirs retenus, choisis à l'écran précédent.
  final List<String> memoryIds;

  /// Tag d'origine, s'il y en a un : il donne le titre et la couleur par défaut
  /// de la couverture (et, pour un tag enfant, la courbe de croissance).
  final String? tagId;

  /// Démarre directement sur les options d'achat (format + adresse), en sautant
  /// l'étape couverture/aperçu. Utilisé depuis « Mes livres » → Commander.
  final bool startAtOrder;

  /// Si renseigné, cet écran ne crée PAS une nouvelle commande : il régénère
  /// le PDF pour CETTE commande (refusée par Gelato) et le renvoie
  /// directement en production. Voir _placeOrder et _loadEditOrderDefaults.
  final String? editOrderId;

  const BookGenerateScreen({
    super.key,
    this.memoryIds = const [],
    this.tagId,
    this.startAtOrder = false,
    this.editOrderId,
  });

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
  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;
  bool _showPreview = false;
  String _coverType = 'soft'; // 'soft' ou 'hard'
  bool _generating = false;
  double _progress = 0.0;
  int _msgIndex = 0;
  Timer? _progressTimer;
  Map<String, String> _locationComments = {};
  Set<String> _selectedMemoryIds = {};
  String? _coverPhotoUrl;
  // Si vrai, la photo de couverture n'est pas répétée dans les pages du livre.
  bool _excludeCoverPhotoFromBook = false;
  // URLs de photos résolues par souvenir (R2 signé + Firebase). Sans ça, le
  // sélecteur de couverture était vide pour les souvenirs passés sur R2 (il ne
  // lisait que les URLs Firebase).
  final Map<String, List<String>> _photoUrlsByMemory = {};

  // Aperçu WYSIWYG : on génère les MÊMES octets PDF que le téléchargement et on
  // affiche chaque page rastérisée → aucune différence possible avec le rendu
  // final / l'impression Gelato.
  Uint8List? _previewPdfBytes;
  int _previewPageCount = 0;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _subtitleCtrl;

  /// Sous-titre du livre (facultatif), imprimé sous le titre en couverture.
  String? get _bookSubtitle =>
      _subtitleCtrl.text.trim().isNotEmpty ? _subtitleCtrl.text.trim() : null;

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
  // sur les pages réellement imprimées (bourrage Gelato pair, 28–200 —
  // cf. BookPricing.printablePages).
  int get _pages => _previewPageCount > 0
      ? _previewPageCount
      : BookPricing.estimatePages(_selectedMemories);

  // Renvoi après refus Gelato avec un nombre de pages exact exigé (ex.
  // « exactly 37 page(s) », cf. OrderModel.gelatoRequiredPageCount) — pré-
  // rempli depuis la commande refusée, ajustable si besoin (on peut vouloir
  // plus de pages blanches que le strict minimum demandé).
  int? _forcedPageCount;

  int get _printedPages => (_forcedPageCount != null && _forcedPageCount! > _pages)
      ? _forcedPageCount!
      : BookPricing.printablePages(_pages);
  double _priceFor(String coverType) =>
      BookPricing.price(coverType: coverType, pages: _printedPages);
  String _priceLabel(String coverType) =>
      BookPricing.format(_priceFor(coverType));

  // Gelato refuse au-delà de 200 pages (plafond de
  // BookPdfService._gelatoValidPageCount). Contrairement au minimum (comblé
  // par des pages blanches), on ne peut pas combler silencieusement un
  // dépassement sans tronquer du contenu réel — d'où le blocage plutôt qu'un
  // simple avertissement (cf. rejets de commande passés : le nombre de pages
  // annoncé à Gelato ne correspondait plus au PDF réellement envoyé).
  bool get _exceedsGelatoLimit => _pages > 200;
  // Pages blanches ajoutées en fin de livre pour atteindre le minimum
  // imprimeur (28, pair), ou le nombre exact exigé par Gelato lors d'un
  // renvoi (_forcedPageCount) — 0 si le livre dépasse déjà cette cible, ou
  // s'il dépasse la limite haute (auquel cas aucun bourrage n'est appliqué).
  int get _blankPagesAdded =>
      _exceedsGelatoLimit ? 0 : (_printedPages - _pages);

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
        final words =
            m.rawContent.trim().split(RegExp(r'\s+')).take(4).join(' ');
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
    if (mounted) setState(() => _loadError = null);
    const t = Duration(seconds: 20);
    try {
      // Les souvenirs retenus à l'écran de sélection, dans l'ordre chronologique.
      final visible = await MemoryQueryService.visible().first.timeout(t);
      if (!mounted) return;
      final wanted = widget.memoryIds.toSet();
      final allMemories = visible
          .where((m) => wanted.isEmpty || wanted.contains(m.id))
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

      if (allMemories.isEmpty) {
        setState(() => _loadError = 'Aucun souvenir à mettre dans ce livre.');
        return;
      }

      // Le PDF est écrit pour un « carnet » : sans carnet, on lui en fabrique un
      // à partir du tag d'origine (titre, couleur, date de naissance) ou, à
      // défaut, un carnet générique.
      final tag = widget.tagId != null
          ? await TagService.byId(widget.tagId!).timeout(t)
          : null;
      if (!mounted) return;
      final nb = tag?.asNotebook() ??
          NotebookModel(
            id: '',
            userId: FirebaseAuth.instance.currentUser?.uid ?? '',
            type: 'libre',
            title: 'Mes souvenirs',
            coverColor: '#C4714B',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );

      // Photo de couverture par défaut : la première photo trouvée parmi les
      // souvenirs (ordre chronologique). L'utilisateur peut en changer ensuite.
      String? defaultCover;
      for (final m in allMemories) {
        if (m.mediaUrls.isNotEmpty) {
          defaultCover = m.mediaUrls.first;
          break;
        }
        if (m.photoUrl != null && m.photoUrl!.isNotEmpty) {
          defaultCover = m.photoUrl;
          break;
        }
      }
      setState(() {
        _notebook = nb;
        _memories = allMemories;
        _selectedMemoryIds = allMemories.map((m) => m.id).toSet();
        _coverPhotoUrl = defaultCover;
        _loadError = null;
        // Commande depuis « Mes livres » : on saute directement aux options
        // d'achat.
        if (widget.startAtOrder || widget.editOrderId != null) {
          _step = 1;
          _coverType = 'soft';
        }
      });
      // Initialise les champs éditables : le titre = ce qui s'affiche par
      // défaut sur la couverture (ex. « Léa & Nala »), pour que le champ soit
      // cohérent avec l'aperçu et directement modifiable.
      _titleCtrl.text = _defaultCoverTitle(nb);
      // Résout les URLs de photos (R2 signé + Firebase) pour peupler le
      // sélecteur de couverture, y compris pour les souvenirs sur R2.
      _resolvePhotos(allMemories);
      // Admin : pré-remplit l'adresse de livraison (étape 2) avec celle de la
      // dernière commande, pour ne plus jamais avoir à la ressaisir.
      if (_isAdmin) _loadLastAddress();
      // Renvoi après refus : pré-remplit adresse/titre/couverture avec ceux
      // de la commande refusée (inchangés, seul le PDF est régénéré) — sans
      // ça l'utilisateur devrait ressaisir son adresse pour rien.
      if (widget.editOrderId != null) _loadEditOrderDefaults();
    } catch (e) {
      // Sans ça, une lecture qui pend/échoue laissait un spinner plein écran
      // infini, sans message — la cause des « le spinner tourne ».
      if (!mounted) return;
      setState(
          () => _loadError = 'Chargement impossible. Vérifie ta connexion.');
    }
  }

  // Pré-remplit l'adresse de livraison avec celle de la dernière commande de
  // l'utilisateur (admin), pour ne plus avoir à la ressaisir à chaque livre
  // commandé.
  Future<void> _loadLastAddress() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final orders = await OrderService.userOrdersStream(user.uid)
          .first
          .timeout(const Duration(seconds: 10));
      if (orders.isEmpty || !mounted) return;
      final last = orders.first; // le plus récent (stream déjà trié)
      setState(() {
        _firstNameCtrl.text = last.firstName;
        _lastNameCtrl.text = last.lastName;
        _streetCtrl.text = last.street;
        _cityCtrl.text = last.city;
        _npaCtrl.text = last.npa;
        _countryCtrl.text = last.country;
      });
    } catch (_) {
      // Pas grave : l'adresse sera juste à saisir à la main.
    }
  }

  // Pré-remplit adresse/titre/couverture avec ceux de la commande qu'on est
  // en train de corriger (widget.editOrderId) — seul le PDF change, tout le
  // reste (facturé, adressé) doit rester identique.
  Future<void> _loadEditOrderDefaults() async {
    try {
      final order = await OrderService.getOrder(widget.editOrderId!)
          .timeout(const Duration(seconds: 10));
      if (order == null || !mounted) return;
      setState(() {
        _coverType = order.coverType;
        _firstNameCtrl.text = order.firstName;
        _lastNameCtrl.text = order.lastName;
        _streetCtrl.text = order.street;
        _cityCtrl.text = order.city;
        _npaCtrl.text = order.npa;
        _countryCtrl.text = order.country;
        _forcedPageCount = order.gelatoRequiredPageCount;
      });
      _titleCtrl.text = order.bookTitle;
    } catch (_) {
      // Pas grave : les champs restent à saisir à la main.
    }
  }

  // ── Generation ─────────────────────────────────────────────────────────────

  // Génère le PDF d'aperçu — mêmes octets que le téléchargement (sans bourrage
  // de pages blanches), pour un aperçu strictement identique au rendu final.
  Future<({Uint8List bytes, int pageCount})> _buildPreviewPdf() {
    final coverColor = _notebook!.coverColor.isNotEmpty
        ? Color(int.parse('FF${_notebook!.coverColor.replaceAll('#', '')}',
            radix: 16))
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
      customSubtitle: _bookSubtitle,
      backendUrl: AppConfig.backendUrl,
    ).timeout(const Duration(seconds: 180));
  }

  Future<void> _generate() async {
    if (_selectedMemories.isEmpty) {
      _showSnack('Sélectionne au moins un souvenir avant de créer le livre.');
      return;
    }
    if (_notebook == null) return;

    setState(() {
      _generating = true;
      _progress = 0.0;
      _msgIndex = 0;
    });
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
  // Depuis l'écran d'aperçu (déjà généré, WYSIWYG) : pas besoin de régénérer,
  // on réutilise directement les octets déjà rendus.
  Future<void> _downloadPreviewPdf() async {
    if (_previewPdfBytes == null || _notebook == null) return;
    final customTitle =
        _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null;
    final bookTitle = customTitle ?? _notebook!.title;
    await _finishDownload(_previewPdfBytes!, bookTitle);
  }

  // 2. Sauvegarde silencieuse côté admin + historique (sans bloquer).
  // 3. On OUVRE le PDF dans l'app (visualiseur plein écran) : on le lit tout
  //    de suite, sans passer par la feuille de partage. Le partage et
  //    l'impression restent accessibles depuis la barre du visualiseur.
  Future<void> _finishDownload(Uint8List pdfBytes, String bookTitle) async {
    _uploadPdfToStorage(
      pdfBytes: pdfBytes,
      bookTitle: bookTitle,
      subtitle: _bookSubtitle,
      coverType: _coverType,
      notebookId: widget.tagId ?? '',
      memoriesCount: _selectedMemories.length,
    );

    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PdfViewerScreen(title: bookTitle, bytes: pdfBytes),
    ));
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
      final uploaded =
          await PdfService.uploadBookPdf(Uint8List.fromList(pdfBytes));
      if (uploaded == null) return;
      await BookHistoryService.recordBook(
        notebookId: notebookId,
        title: bookTitle,
        subtitle: subtitle,
        format: 'digital',
        coverType: coverType,
        pdfUrl: uploaded.url,
        storagePath: uploaded.key,
        memoriesCount: memoriesCount,
      );
    } catch (_) {
      // Silencieux — le partage a déjà eu lieu
    }
  }

  Future<void> _placeOrder() async {
    // Garde-fou : au cas où l'étape précédente serait contournée, on bloque
    // ici aussi — un livre trop long envoyé à Gelato avec un pageCount
    // tronqué a déjà causé des rejets de commande (nombre de pages annoncé ≠
    // PDF réellement généré).
    if (_exceedsGelatoLimit) {
      _showSnack(
          'Ce livre dépasse 200 pages — retire des souvenirs avant de commander.');
      return;
    }
    final isEdit = widget.editOrderId != null;
    // Le renvoi direct (orderType: order, via OrderService.retryGelatoOrder)
    // n'est accepté par Gelato QUE pour un nombre de pages PAIR (confirmé le
    // 30.07.26 — un envoi impair est rejeté SYNCHRONE, jamais accepté).
    // Impossible donc de renvoyer directement quand le refus exige un compte
    // impair : il faut un nouveau brouillon confirmé à la main dans le
    // dashboard Gelato (console admin → « Envoyer à Gelato »).
    if (isEdit && (_forcedPageCount?.isOdd ?? false)) {
      _showSnack(
          'Ce nombre de pages est impair : Gelato refuse toujours un renvoi '
          'direct dans ce cas. Passe par la console admin pour créer un '
          'nouveau brouillon à confirmer dans le dashboard Gelato.');
      return;
    }
    if (!isEdit && !(_addressKey.currentState?.validate() ?? false)) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _notebook == null) return;

    setState(() {
      _ordering = true;
      _orderMessage = 'Génération du livre…';
    });
    try {
      final price = _priceFor(_coverType);
      final bookTitle = _titleCtrl.text.trim().isNotEmpty
          ? _titleCtrl.text.trim()
          : _notebook!.title;
      final customTitle =
          _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null;

      // 1. Générer le PDF en premier
      final coverColor = Color(int.parse(
          'FF${_notebook!.coverColor.replaceAll('#', '')}',
          radix: 16));
      final gen = await BookPdfService.generateForNotebook(
        notebook: _notebook!,
        coverColor: coverColor,
        memories: _selectedMemories,
        locationComments: _locationComments,
        coverPhotoUrl: _coverPhotoUrl,
        excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
        customTitle: customTitle,
        customSubtitle: _bookSubtitle,
        backendUrl: AppConfig.backendUrl,
        padForPrint: true, // pages valides Gelato (pair, ≥28)
        coverType: _coverType, // largeur exacte de couverture wraparound
        forcedPageCount: _forcedPageCount,
      );
      final pdfBytes = gen.bytes;
      final pageCount = gen.pageCount;

      if (!mounted) return;
      setState(() => _orderMessage = 'Envoi du PDF…');

      // 2. Uploader le PDF sur R2. L'URL renvoyée est STABLE (backend → R2
      // signé) : c'est celle que suivra l'imprimeur, même des semaines plus tard.
      final uploaded = await PdfService.uploadBookPdf(pdfBytes);
      if (uploaded == null) {
        throw Exception('Envoi du PDF impossible — réessaie dans un instant.');
      }
      final pdfUrl = uploaded.url;

      if (!mounted) return;

      // Renvoi après refus : on ne crée PAS de nouvelle commande — le PDF
      // régénéré est renvoyé directement en production pour LA MÊME commande.
      // Le backend revérifie lui-même le plafond de 3 tentatives et l'écart
      // de pages (±3) ; ses messages d'erreur sont affichés tels quels.
      if (isEdit) {
        setState(() => _orderMessage = 'Renvoi à l\'impression…');
        await OrderService.retryGelatoOrder(
          widget.editOrderId!,
          pdfUrl: pdfUrl,
          pageCount: pageCount,
        );
        if (!mounted) return;
        context.go('/orders/${widget.editOrderId}');
        return;
      }

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
        notebookId: widget.tagId ?? '',
        memoryCount: _selectedMemories.length,
        pageCount: pageCount,
        pdfUrl: pdfUrl,
      );
      final orderId = await OrderService.createOrder(order);

      // 4. Historique des livres (imprimé)
      await BookHistoryService.recordBook(
        notebookId: widget.tagId ?? '',
        title: bookTitle,
        subtitle: _bookSubtitle,
        format: 'printed',
        coverType: _coverType,
        pdfUrl: pdfUrl,
        storagePath: uploaded.key,
        memoriesCount: _selectedMemories.length,
        orderId: orderId,
      );

      if (!mounted) return;
      context.go('/order-confirmation/$orderId');
    } catch (e) {
      _showSnack(e.toString().replaceFirst('Exception: ', ''));
      if (mounted)
        setState(() {
          _ordering = false;
          _orderMessage = '';
        });
    }
  }

  String get _orderButtonLabel => widget.editOrderId != null
      ? 'Renvoyer à l\'impression'
      : 'Commander · ${_priceLabel(_coverType)}';

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
            onPressed: () => context.go('/home'),
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
          setState(() {
            _showPreview = false;
            _step = 0;
          });
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
                setState(() {
                  _showPreview = false;
                  _step = 0;
                });
              } else if (_step > 0) {
                setState(() => _step--);
              } else {
                context.go('/home');
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
      fillColor: AppColors.surface,
      prefixIcon:
          icon != null ? Icon(icon, size: 18, color: AppColors.sage) : null,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border(AppColors.border, 0.5),
      enabledBorder: border(AppColors.border, 0.5),
      focusedBorder: border(AppColors.sage, 1.5),
    );
  }

  Widget _buildPreviewStep() {
    final coverColor = Color(
        int.parse('FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16));

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
            ),
          ),
          const SizedBox(height: 20),

          // ── Souvenirs inclus + action, EN HAUT (pas besoin de scroller) ──
          GestureDetector(
            onTap: _openMemorySelection,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.border, width: 0.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.checklist_outlined,
                      size: 18, color: AppColors.sage),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _selectedMemoryIds.length == _memories.length
                          ? 'Tous les souvenirs inclus (${_memories.length})'
                          : '${_selectedMemoryIds.length} souvenir${_selectedMemoryIds.length != 1 ? 's' : ''} sur ${_memories.length} inclus',
                      style: const TextStyle(
                          color: AppColors.textDark, fontSize: 13),
                    ),
                  ),
                  const Text('Modifier',
                      style: TextStyle(
                          color: AppColors.sage,
                          fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right,
                      color: AppColors.sage, size: 18),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Action principale : génère l'aperçu du livre (d'où le nom).
          if (_generating) ...[
            _ProgressBar(progress: _progress),
            const SizedBox(height: 12),
            Text(
              _loadingMessages[_msgIndex],
              style: const TextStyle(
                  color: AppColors.textMedium,
                  fontSize: 13,
                  fontStyle: FontStyle.italic),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _selectedMemories.isEmpty ? null : _generate,
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('Aperçu du livre'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  disabledBackgroundColor: AppColors.background,
                  disabledForegroundColor: AppColors.softGray,
                ),
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

          const SizedBox(height: 24),

          // ── Personnalise ton livre (titre éditable) ────────────────────
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
            style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 14,
              fontStyle: FontStyle.italic,
              color: AppColors.textMedium,
            ),
            decoration: _bookFieldDecoration(
              label: 'Sous-titre (facultatif)',
              hint: 'Ex : Été 2026, nos aventures',
              icon: Icons.subtitles_outlined,
            ),
            onChanged: (_) => setState(() {}),
          ),

          // ── Photo preview ──────────────────────────────────────────────
          _buildPhotoPreview(),
        ],
      ),
    );
  }

  // ── Step 1: Format selection ───────────────────────────────────────────────

  /// Résout les photos de chaque souvenir (R2 signé + Firebase) pour le
  /// sélecteur de couverture. Une fois prêt, on choisit une couverture par
  /// défaut si l'utilisateur n'en a pas déjà une.
  Future<void> _resolvePhotos(List<MemoryModel> memories) async {
    for (final m in memories) {
      try {
        final urls = await PhotoService.resolvePhotoUrls(m);
        if (urls.isNotEmpty) _photoUrlsByMemory[m.id] = urls;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _coverPhotoUrl ??= _allPhotoUrls.isNotEmpty ? _allPhotoUrls.first : null;
    });
  }

  // Toutes les URLs de photos des souvenirs sélectionnés (couverture au choix).
  // Utilise les URLs résolues (R2/Firebase) ; repli sync sur mediaUrls/photoUrl.
  List<String> get _allPhotoUrls {
    final urls = <String>[];
    for (final m in _selectedMemories) {
      final resolved = _photoUrlsByMemory[m.id];
      if (resolved != null && resolved.isNotEmpty) {
        urls.addAll(resolved);
      } else if (m.mediaUrls.isNotEmpty) {
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
      printedPages: _printedPages,
      priceSoft: _priceLabel('soft'),
      priceHard: _priceLabel('hard'),
      exceedsLimit: _exceedsGelatoLimit,
      onDownload: _downloadPreviewPdf,
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
                          width: 70,
                          height: 70,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            width: 70,
                            height: 70,
                            color: AppColors.background,
                            child: const Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            width: 70,
                            height: 70,
                            color: AppColors.background,
                            child: const Icon(Icons.broken_image_outlined,
                                color: AppColors.softGray, size: 20),
                          ),
                        ),
                      ),
                      if (isSelected)
                        Positioned(
                          right: 3,
                          top: 3,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: AppColors.sage,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.check,
                                color: Colors.white, size: 12),
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
                      style: TextStyle(color: AppColors.textDark, fontSize: 13),
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

  // Contrôle du nombre de pages avant impression : évite les rejets Gelato en
  // montrant, AVANT la commande, si des pages blanches seront ajoutées ou si
  // le livre dépasse la limite de l'imprimeur (auquel cas la commande est
  // bloquée plutôt que d'envoyer un PDF dont le nombre de pages réel ne
  // correspondrait plus à celui annoncé à Gelato).
  Widget _buildPageCountNotice() {
    if (_exceedsGelatoLimit) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.red.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ce livre dépasse la limite de notre imprimeur',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.red),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Ton livre fait $_pages pages. Le format imprimé accepte au '
              'maximum 200 pages chez notre imprimeur. Retire des souvenirs '
              'pour pouvoir commander (le PDF digital reste possible sans '
              'limite).',
              style: const TextStyle(fontSize: 12, color: AppColors.textMedium),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openMemorySelection,
              icon: const Icon(Icons.checklist_outlined,
                  size: 16, color: Colors.red),
              label: const Text('Retirer des souvenirs',
                  style: TextStyle(color: Colors.red, fontSize: 13)),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: Size.zero),
            ),
          ],
        ),
      );
    }
    if (_forcedPageCount != null) {
      final plural = _blankPagesAdded > 1 ? 's' : '';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: AppColors.amber),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Notre imprimeur a refusé la mise en page précédente et '
                    'exige un nombre de pages précis pour ce livre.',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('Nombre de pages à envoyer :',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMedium)),
                const Spacer(),
                _pageStepperButton(
                  icon: Icons.remove,
                  onTap: _forcedPageCount! > _pages
                      ? () => setState(() => _forcedPageCount = _forcedPageCount! - 1)
                      : null,
                ),
                SizedBox(
                  width: 36,
                  child: Text('$_forcedPageCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDark)),
                ),
                _pageStepperButton(
                  icon: Icons.add,
                  onTap: () =>
                      setState(() => _forcedPageCount = _forcedPageCount! + 1),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _blankPagesAdded > 0
                  ? 'Ton livre fait $_pages pages : $_blankPagesAdded '
                      'page$plural blanche$plural seront ajoutées à la fin '
                      'pour atteindre ce total.'
                  : 'Ton livre a déjà assez de pages pour ce total.',
              style: const TextStyle(fontSize: 12, color: AppColors.textMedium),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _openMemorySelection,
              icon: const Icon(Icons.add_photo_alternate_outlined,
                  size: 16, color: AppColors.amber),
              label: const Text('Ajouter des souvenirs à la place',
                  style: TextStyle(color: AppColors.amber, fontSize: 13)),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: Size.zero),
            ),
          ],
        ),
      );
    }
    if (_blankPagesAdded > 0) {
      final plural = _blankPagesAdded > 1 ? 's' : '';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 16, color: AppColors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ton livre fait $_pages pages. Notre imprimeur exige un '
                    'minimum de 28 pages (nombre pair) : $_blankPagesAdded '
                    'page$plural blanche$plural seront ajoutées à la fin.',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMedium),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _openMemorySelection,
              icon: const Icon(Icons.add_photo_alternate_outlined,
                  size: 16, color: AppColors.amber),
              label: const Text('Ajouter des souvenirs à la place',
                  style: TextStyle(color: AppColors.amber, fontSize: 13)),
              style: TextButton.styleFrom(
                  padding: EdgeInsets.zero, minimumSize: Size.zero),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sage.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.sage.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: AppColors.sage),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$_pages pages · prêt pour l\'impression, aucune page blanche ajoutée.',
              style: const TextStyle(fontSize: 12, color: AppColors.textMedium),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageStepperButton({required IconData icon, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(icon,
            size: 15,
            color: onTap == null ? AppColors.softGray : AppColors.textDark),
      ),
    );
  }

  Widget _buildFormatStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Quelle couverture ?',
            style: TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Le PDF se télécharge depuis l\'aperçu — ici, choisis le livre imprimé.',
            style: TextStyle(color: AppColors.textMedium, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Opacity(
            opacity: _exceedsGelatoLimit ? 0.45 : 1.0,
            child: _FormatCard(
              emoji: '📗',
              title: 'Couverture souple',
              subtitle: 'Livre 21×28 cm · 5–7 jours',
              price: _priceLabel('soft'),
              priceSub: '$_printedPages pages',
              priceColor: AppColors.amber,
              selected: _coverType == 'soft',
              onTap: _exceedsGelatoLimit
                  ? () => _showSnack(
                      'Retire des souvenirs pour repasser sous 200 pages avant de choisir ce format.')
                  : () => setState(() => _coverType = 'soft'),
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: _exceedsGelatoLimit ? 0.45 : 1.0,
            child: _FormatCard(
              emoji: '📕',
              title: 'Couverture rigide',
              subtitle: 'Livre 21×28 cm · couverture cartonnée',
              price: _priceLabel('hard'),
              priceSub: '$_printedPages pages',
              priceColor: AppColors.amber,
              selected: _coverType == 'hard',
              onTap: _exceedsGelatoLimit
                  ? () => _showSnack(
                      'Retire des souvenirs pour repasser sous 200 pages avant de choisir ce format.')
                  : () => setState(() => _coverType = 'hard'),
            ),
          ),
          const SizedBox(height: 12),
          // Bouton info : grille tarifaire selon le nombre de pages.
          Center(
            child: TextButton.icon(
              onPressed: _showPricingTable,
              icon: const Icon(Icons.info_outline,
                  size: 16, color: AppColors.textMedium),
              label: const Text(
                'Comment le prix est calculé ?',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildPageCountNotice(),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _exceedsGelatoLimit
                ? null
                : () => setState(() => _step = 2),
            child: Text('Continuer · ${_priceLabel(_coverType)}'),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              '🔒  Paiement sécurisé',
              style: TextStyle(color: AppColors.textMedium, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 2: Commande ──────────────────────────────────────────────────────

  Widget _buildOrderStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Récapitulatif commande',
            style: TextStyle(
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
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border, width: 0.5),
            ),
            child: Column(
              children: [
                _OrderRow(label: 'Carnet', value: _notebook!.title),
                const Divider(height: 24, color: AppColors.border),
                _OrderRow(
                    label: 'Souvenirs',
                    value: '${_selectedMemories.length} souvenirs'),
                const Divider(height: 24, color: AppColors.border),
                _OrderRow(
                    label: 'Format',
                    value: _coverType == 'hard'
                        ? 'Couverture rigide'
                        : 'Couverture souple'),
                const Divider(height: 24, color: AppColors.border),
                _OrderRow(label: 'Pages', value: '$_printedPages pages'),
                const Divider(height: 24, color: AppColors.border),
                _OrderRow(
                  label: 'Total',
                  value: _priceLabel(_coverType),
                  bold: true,
                  valueColor: AppColors.amber,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Formulaire adresse
          Form(
              key: _addressKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Adresse de livraison',
                      style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child: _AddressField(_firstNameCtrl, 'Prénom',
                            required: true)),
                    const SizedBox(width: 10),
                    Expanded(
                        child: _AddressField(_lastNameCtrl, 'Nom',
                            required: true)),
                  ]),
                  const SizedBox(height: 10),
                  _AddressField(_streetCtrl, 'Rue et numéro', required: true),
                  const SizedBox(height: 10),
                  Row(children: [
                    SizedBox(
                        width: 100,
                        child: _AddressField(_npaCtrl, 'NPA',
                            required: true,
                            keyboardType: TextInputType.number)),
                    const SizedBox(width: 10),
                    Expanded(
                        child:
                            _AddressField(_cityCtrl, 'Ville', required: true)),
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
                      child: Text(_orderButtonLabel),
                    ),
                ],
              )),

          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _step = 1),
              child: const Text(
                '← Changer le format',
                style: TextStyle(color: AppColors.textMedium, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Vrai dès qu'un souvenir a été modifié (mise en page ou photos ajoutées)
  // pendant que la sheet « Souvenirs à inclure » était ouverte — sert à
  // régénérer l'aperçu automatiquement à la fermeture, sans que l'utilisateur
  // ait à retaper « Aperçu du livre » lui-même.
  bool _memoriesChangedInSheet = false;

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
        onMemoryUpdated: _applyMemoryLayoutUpdate,
      ),
    );
    if (_memoriesChangedInSheet) {
      _memoriesChangedInSheet = false;
      await _generate();
    }
  }

  // Patche l'état local après un réglage de mise en page (densité / photos en
  // grand) ou un ajout de photos sauvegardé sur un souvenir — pas de refetch,
  // le prochain « Générer l'aperçu » (déclenché automatiquement à la
  // fermeture de la sheet, voir _openMemorySelection) utilise directement la
  // version à jour.
  void _applyMemoryLayoutUpdate(MemoryModel updated) {
    _memoriesChangedInSheet = true;
    setState(() {
      final i = _memories.indexWhere((m) => m.id == updated.id);
      if (i != -1) _memories[i] = updated;
    });
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
      backgroundColor: AppColors.surface,
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
                  width: 36,
                  height: 4,
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
              const Text(
                'Prix tout compris : impression + livraison en Suisse + TVA. '
                'Il dépend de la couverture (souple / rigide) et du nombre de '
                'pages. Les livres imprimés font 28 pages minimum.',
                style: TextStyle(
                    color: AppColors.textMedium, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              // En-tête du tableau
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Expanded(
                        flex: 2,
                        child: Text('Pages',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                    Expanded(
                        flex: 3,
                        child: Text('Souple',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                    Expanded(
                        flex: 3,
                        child: Text('Rigide',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: AppColors.textDark))),
                  ],
                ),
              ),
              for (final p in rows)
                Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
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
                            fontWeight:
                                p == mine ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(
                              BookPricing.price(coverType: 'soft', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          BookPricing.format(
                              BookPricing.price(coverType: 'hard', pages: p)),
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textMedium),
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

  const _BookCoverPreview({
    required this.notebook,
    required this.coverColor,
    required this.title,
    this.coverPhotoUrl,
    this.yearRange = '',
    this.highlights = const [],
  });

  @override
  Widget build(BuildContext context) {
    final titleText = title;

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
              top: 10,
              right: 12,
              child: Text(
                'carnet',
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.white.withOpacity(0.85),
                  fontStyle: FontStyle.italic,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            // Cover content
            if (coverPhotoUrl != null)
              // Photo version : bandeau bas compact, 2 colonnes (titre à gauche,
              // liste des souvenirs à droite) — laisse plus de place à la photo.
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
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
                                fontFamily: 'PlayfairDisplay',
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2D2416),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 3),
                            Container(width: 16, height: 1, color: coverColor),
                            const SizedBox(height: 3),
                            Text(
                              yearRange.isNotEmpty
                                  ? yearRange
                                  : '${DateTime.now().year}',
                              style: const TextStyle(
                                  fontSize: 6.5,
                                  color: Color(0xFF8C8C8C),
                                  letterSpacing: 1.5),
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
                        fontFamily: 'PlayfairDisplay',
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Container(
                      width: 30,
                      height: 1,
                      color: Colors.white.withOpacity(0.6)),
                  const SizedBox(height: 7),
                  Text(
                    yearRange.isNotEmpty ? yearRange : '${DateTime.now().year}',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withOpacity(0.8),
                        letterSpacing: 2),
                  ),
                  if (highlights.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                        width: 32,
                        height: 0.5,
                        color: Colors.white.withOpacity(0.4)),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        highlights.take(3).map((h) => '· $h').join('  '),
                        style: TextStyle(
                            fontSize: 7,
                            color: Colors.white.withOpacity(0.75),
                            fontStyle: FontStyle.italic),
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
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.sage),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${(progress * 100).round()}%',
          style: const TextStyle(color: AppColors.textMedium, fontSize: 12),
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
          color: selected ? AppColors.sage.withOpacity(0.12) : AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.border,
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
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
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
          style: const TextStyle(color: AppColors.textMedium, fontSize: 14),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? AppColors.textDark,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
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
  // Infos pages/prix affichées en lecture seule sur cet écran (mêmes valeurs
  // que l'étape format juste après — juste visibles plus tôt, sans y aller).
  final int printedPages;
  final String priceSoft;
  final String priceHard;
  final bool exceedsLimit;
  final VoidCallback onDownload;
  final VoidCallback onChooseFormat;

  const _PdfPreviewViewer({
    required this.pdfBytes,
    required this.pageCount,
    required this.printedPages,
    required this.priceSoft,
    required this.priceHard,
    required this.exceedsLimit,
    required this.onDownload,
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
        // Pages / prix estimé — mêmes valeurs qu'à l'étape format, visibles
        // ici sans avoir à y aller.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: widget.exceedsLimit
              ? const Text(
                  'Ce livre dépasse 200 pages : retire des souvenirs pour '
                  'pouvoir l\'imprimer.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.amber, fontSize: 12.5),
                )
              : Text(
                  '${widget.printedPages} pages imprimées · Souple '
                  '${widget.priceSoft} · Rigide ${widget.priceHard}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMedium, fontSize: 12.5),
                ),
        ),
        // CTA
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          child: Column(
            children: [
              OutlinedButton.icon(
                onPressed: widget.onDownload,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Télécharger le PDF'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: widget.onChooseFormat,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Choisir le format →'),
              ),
            ],
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
  final ValueChanged<MemoryModel> onMemoryUpdated;

  const _MemorySelectionSheet({
    required this.memories,
    required this.selectedIds,
    required this.onChanged,
    required this.onMemoryUpdated,
  });

  @override
  State<_MemorySelectionSheet> createState() => _MemorySelectionSheetState();
}

class _MemorySelectionSheetState extends State<_MemorySelectionSheet> {
  late Set<String> _local;
  // Souvenirs patchés localement après ajout de photos (mediaKeys à jour) —
  // widget.memories n'est reçu qu'une fois à l'ouverture de la sheet, donc on
  // superpose ces versions pour que le compteur/bouton "Mise en page" reflètent
  // les ajouts sans devoir fermer/rouvrir la sheet.
  final Map<String, MemoryModel> _patched = {};
  final Set<String> _uploadingIds = {};

  @override
  void initState() {
    super.initState();
    _local = Set.from(widget.selectedIds);
  }

  MemoryModel _memoryAt(int i) {
    final m = widget.memories[i];
    return _patched[m.id] ?? m;
  }

  Future<void> _addPhotosTo(MemoryModel m) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.perm_media_outlined,
                  color: AppColors.sage),
              title: const Text('Choisir dans la galerie'),
              subtitle: const Text('Plusieurs photos à la fois'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading:
                  const Icon(Icons.add_a_photo_outlined, color: AppColors.sage),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    List<XFile> picked;
    try {
      if (source == ImageSource.gallery) {
        picked = await picker.pickMultiImage(imageQuality: 80, maxWidth: 1920);
      } else {
        final shot = await picker.pickImage(
            source: ImageSource.camera, imageQuality: 80, maxWidth: 1920);
        picked = shot != null ? [shot] : const [];
      }
    } catch (_) {
      if (mounted) _showSnack('Impossible d\'accéder à la photo');
      return;
    }
    if (picked.isEmpty || !mounted) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final q = await QuotaService.canAddPhotos(uid, adding: picked.length);
      if (!q.allowed) {
        if (mounted) {
          _showSnack(
              'Limite de ${q.limit} photos atteinte — retire des photos avant d\'en ajouter.');
        }
        return;
      }
    }

    setState(() => _uploadingIds.add(m.id));
    try {
      final files = picked.map((x) => File(x.path)).toList();
      final newKeys = await PhotoService.uploadMultiplePhotosToR2(
        photos: files,
        notebookId: m.notebookId,
      );
      if (newKeys.length < files.length && mounted) {
        _showSnack(
            '${files.length - newKeys.length} photo(s) n\'ont pas pu être envoyées.');
      }
      if (newKeys.isEmpty) return;

      final allKeys = [...m.mediaKeys, ...newKeys];
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(m.id)
          .update({'mediaKeys': allKeys});
      PhotoService.invalidateSignedCache(m.id);

      final updated = m.copyWith(mediaKeys: allKeys);
      if (mounted) setState(() => _patched[m.id] = updated);
      widget.onMemoryUpdated(updated);
    } catch (e) {
      if (mounted) _showSnack('Échec de l\'envoi : $e');
    } finally {
      if (mounted) setState(() => _uploadingIds.remove(m.id));
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
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
      final m = widget.memories
          .firstWhere((m) => m.id == id, orElse: () => widget.memories.first);
      if (m.mediaKeys.isNotEmpty || m.mediaUrls.isNotEmpty) {
        n += m.mediaKeys.length + m.mediaUrls.length;
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
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
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
                    style: TextButton.styleFrom(
                        padding: EdgeInsets.zero, minimumSize: Size.zero),
                    onPressed: () => setState(() {
                      if (_local.length == widget.memories.length) {
                        _local.clear();
                      } else {
                        _local = widget.memories.map((m) => m.id).toSet();
                      }
                    }),
                    child: Text(
                      _local.length == widget.memories.length
                          ? 'Tout décocher'
                          : 'Tout cocher',
                      style:
                          const TextStyle(color: AppColors.sage, fontSize: 13),
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
                  final m = _memoryAt(i);
                  final selected = _local.contains(m.id);
                  final uploading = _uploadingIds.contains(m.id);
                  final hasR2OrLegacyMedia =
                      m.mediaKeys.isNotEmpty || m.mediaUrls.isNotEmpty;
                  final hasPhotos = hasR2OrLegacyMedia ||
                      (m.photoUrl != null && m.photoUrl!.isNotEmpty);
                  final photoCount = hasR2OrLegacyMedia
                      ? m.mediaKeys.length + m.mediaUrls.length
                      : (hasPhotos ? 1 : 0);
                  final preview = m.rawContent.length > 65
                      ? '${m.rawContent.substring(0, 65)}…'
                      : m.rawContent;

                  return InkWell(
                    onTap: () => setState(() {
                      selected ? _local.remove(m.id) : _local.add(m.id);
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Checkbox
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color:
                                  selected ? AppColors.sage : AppColors.surface,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: selected
                                    ? AppColors.sage
                                    : const Color(0xFFCCC8BE),
                                width: 1.5,
                              ),
                            ),
                            child: selected
                                ? const Icon(Icons.check,
                                    size: 14, color: Colors.white)
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
                                        color: selected
                                            ? AppColors.sage
                                            : AppColors.textMedium,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        _typeLabel(m.type),
                                        style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.textMedium),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  preview,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: selected
                                        ? AppColors.textDark
                                        : AppColors.textMedium,
                                    height: 1.4,
                                  ),
                                ),
                                if (hasPhotos) ...[
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Icon(Icons.photo_outlined,
                                          size: 12,
                                          color:
                                              AppColors.sage.withOpacity(0.8)),
                                      const SizedBox(width: 3),
                                      Text(
                                        '$photoCount photo${photoCount > 1 ? 's' : ''}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppColors.sage
                                                .withOpacity(0.8)),
                                      ),
                                    ],
                                  ),
                                ],
                                if (selected) ...[
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: uploading
                                        ? null
                                        : () => _addPhotosTo(m),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.background,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                        border: Border.all(
                                            color: AppColors.sage
                                                .withOpacity(0.4)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (uploading)
                                            const SizedBox(
                                                width: 12,
                                                height: 12,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 1.5))
                                          else
                                            const Icon(Icons.add_photo_alternate_outlined,
                                                size: 13,
                                                color: AppColors.sage),
                                          const SizedBox(width: 4),
                                          Text(
                                            uploading
                                                ? 'Envoi en cours…'
                                                : 'Ajouter des photos',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.sage
                                                    .withOpacity(0.9)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (selected && hasPhotos) ...[
                                  const SizedBox(height: 6),
                                  GestureDetector(
                                    onTap: () async {
                                      final updated = await showModalBottomSheet<
                                          MemoryModel>(
                                        context: context,
                                        isScrollControlled: true,
                                        backgroundColor: Colors.transparent,
                                        builder: (_) =>
                                            _MemoryLayoutSheet(memory: m),
                                      );
                                      if (updated != null) {
                                        widget.onMemoryUpdated(updated);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.sageTint,
                                        borderRadius:
                                            BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.tune,
                                              size: 13, color: AppColors.sage),
                                          const SizedBox(width: 4),
                                          Text(
                                            'Mise en page · densité, photos en grand',
                                            style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.sage
                                                    .withOpacity(0.9)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Choisis jusqu\'à 3 photos à imprimer en '
                                    'grand (pleine page)',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: AppColors.textMedium
                                            .withOpacity(0.85)),
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
              padding: EdgeInsets.fromLTRB(
                  20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: Column(
                children: [
                  Text(
                    '${_local.length} souvenir${_local.length != 1 ? 's' : ''} · $_photoCount photo${_photoCount != 1 ? 's' : ''}',
                    style: const TextStyle(
                        color: AppColors.textMedium, fontSize: 13),
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
                      child: Text(
                          'Confirmer (${_local.length}/${widget.memories.length})'),
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

/// Réglages de mise en page pour UN souvenir : densité verticale/horizontale
/// (2 ou 4 photos/page) et jusqu'à 3 photos "en grand" (pleine page dans le
/// livre). Sauvegarde directe sur Firestore ; renvoie le MemoryModel à jour
/// (via `Navigator.pop`) pour que l'appelant patche son état local.
class _MemoryLayoutSheet extends StatefulWidget {
  final MemoryModel memory;
  const _MemoryLayoutSheet({required this.memory});

  @override
  State<_MemoryLayoutSheet> createState() => _MemoryLayoutSheetState();
}

class _MemoryLayoutSheetState extends State<_MemoryLayoutSheet> {
  late int _vDensity = widget.memory.bookVerticalDensity;
  late int _hDensity = widget.memory.bookHorizontalDensity;
  final Set<String> _featured = {};
  Map<String, String>? _thumbs; // rawId -> URL affichable
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _featured.addAll(widget.memory.bookFeaturedMedia);
    _loadThumbs();
  }

  // Miroir de PhotoService.resolvePhotoUrls (R2 signées d'abord, puis legacy)
  // mais en conservant l'identifiant STABLE (clé ou URL) comme clé de map —
  // c'est cet identifiant qui est stocké dans bookFeaturedMedia et comparé
  // côté génération PDF (book_pdf_service.dart::rawMediaIdsOf).
  Future<void> _loadThumbs() async {
    final m = widget.memory;
    final map = <String, String>{};
    if (m.mediaKeys.isNotEmpty) {
      map.addAll(await PhotoService.signedUrlsForMemory(m.id));
    }
    for (final u in m.mediaUrls) {
      map[u] = u;
    }
    if (map.isEmpty && m.photoUrl != null && m.photoUrl!.isNotEmpty) {
      map[m.photoUrl!] = m.photoUrl!;
    }
    if (mounted) setState(() => _thumbs = map);
  }

  void _toggleFeatured(String rawId) {
    setState(() {
      if (_featured.contains(rawId)) {
        _featured.remove(rawId);
      } else if (_featured.length < 3) {
        _featured.add(rawId);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Maximum 3 photos en grand par souvenir.'),
        ));
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final updated = widget.memory.copyWith(
      bookVerticalDensity: _vDensity,
      bookHorizontalDensity: _hDensity,
      bookFeaturedMedia: _featured.toList(),
    );
    try {
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(widget.memory.id)
          .update({
        'bookVerticalDensity': _vDensity,
        'bookHorizontalDensity': _hDensity,
        'bookFeaturedMedia': _featured.toList(),
      });
      if (mounted) Navigator.pop(context, updated);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Échec de la sauvegarde — réessaie.'),
        ));
      }
    }
  }

  Widget _densityChoice(
      String label, int value, ValueChanged<int> onChanged) {
    Widget pill(int v) {
      final sel = value == v;
      return GestureDetector(
        onTap: () => onChanged(v),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: sel ? AppColors.sage : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: sel ? AppColors.sage : const Color(0xFFCCC8BE)),
          ),
          child: Text('$v / page',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: sel ? Colors.white : AppColors.textMedium,
              )),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark)),
        const SizedBox(height: 8),
        Row(children: [pill(2), const SizedBox(width: 10), pill(4)]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mise en page du souvenir',
                  style: TextStyle(
                    fontFamily: 'PlayfairDisplay',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                controller: ctrl,
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  _densityChoice('Photos verticales', _vDensity,
                      (v) => setState(() => _vDensity = v)),
                  const SizedBox(height: 18),
                  _densityChoice('Photos horizontales', _hDensity,
                      (v) => setState(() => _hDensity = v)),
                  const SizedBox(height: 22),
                  Text(
                    'Photos en grand (${_featured.length}/3)',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Touche jusqu\'à 3 photos pour qu\'elles occupent une page entière dans le livre.',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.textMedium),
                  ),
                  const SizedBox(height: 10),
                  if (_thumbs == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_thumbs!.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('Aucune photo sur ce souvenir.',
                          style: TextStyle(color: AppColors.textMedium)),
                    )
                  else
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                      children: [
                        for (final entry in _thumbs!.entries)
                          GestureDetector(
                            onTap: () => _toggleFeatured(entry.key),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: CachedNetworkImage(
                                    imageUrl: entry.value,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                if (_featured.contains(entry.key))
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                          color: AppColors.sage, width: 3),
                                      color:
                                          AppColors.sage.withOpacity(0.15),
                                    ),
                                    child: const Align(
                                      alignment: Alignment.topRight,
                                      child: Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(Icons.star,
                                            color: AppColors.sage, size: 18),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFEEEBE3)),
            Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 12, 20, 12 + MediaQuery.of(context).padding.bottom),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Enregistrement…' : 'Enregistrer'),
                ),
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
          labelStyle:
              const TextStyle(fontSize: 13, color: AppColors.textMedium),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense: true,
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null
            : null,
      );
}
