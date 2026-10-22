import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/book_draft.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/backend_client.dart';
import '../../core/services/book_draft_service.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/photo_focus_service.dart';
import '../../core/services/analytics_service.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/pdf_service.dart';
import 'pdf_viewer_screen.dart';
import 'pdf_preview_viewer.dart';
import 'memory_selection_sheet.dart';
import 'book_photos_step.dart';
import 'photo_edit_screen.dart';
import '../memories/widgets/growth_chart_card.dart';
import 'book_generate_widgets.dart';
import 'book_steps.dart';
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
  /// le PDF pour CETTE commande (refusée par l'imprimeur) et la renvoie.
  /// Admin uniquement — le backend (`/api/prodigi/order`) refuse de toute
  /// façon l'appel pour un non-admin. Voir _placeOrder et
  /// _loadEditOrderDefaults.
  final String? editOrderId;

  /// true pour un livre ajouté via "+ Ajouter un autre livre à cette
  /// commande" depuis une commande déjà en cours (voir _buildOrderStep du
  /// parent) : mêmes étapes couverture/format, mais l'étape finale génère
  /// juste le PDF et renvoie le résultat au parent (`Navigator.pop`) au lieu
  /// de demander une adresse et créer une commande. Jamais combiné avec
  /// `editOrderId`.
  final bool queueMode;

  /// Reprise d'un brouillon (BookDraft) : souvenirs, titre, couverture,
  /// photos retirées et textes posés sur les photos sont restaurés, puis
  /// l'aperçu (éditeur) s'ouvre directement. `memoryIds`/`tagId` ignorés.
  final String? draftId;

  /// Parcours « Offrir ce livre » : l'option cadeau est cochée d'emblée
  /// (adresse du destinataire + mot imprimé en première page).
  final bool gift;

  const BookGenerateScreen({
    super.key,
    this.memoryIds = const [],
    this.tagId,
    this.startAtOrder = false,
    this.editOrderId,
    this.queueMode = false,
    this.draftId,
    this.gift = false,
  });

  @override
  State<BookGenerateScreen> createState() => _BookGenerateScreenState();
}

/// Un livre configuré et généré via `queueMode`, en attente d'être inclus
/// dans la commande du parent — voir _BookGenerateScreenState._addAnotherBook.
class _QueuedBook {
  final String bookTitle;
  final String coverType;
  final double price;
  final int pageCount;
  final String pdfUrl;
  // Pour BookHistoryService.recordBook (voir _placeOrder) — pas transmis à
  // Prodigi/Stripe, seulement `toMap()` l'est.
  final String storagePath;
  final int memoryCount;
  final String notebookId;
  final String? coverPhotoKey;
  final String? coverPhotoUrl;

  const _QueuedBook({
    required this.bookTitle,
    required this.coverType,
    required this.price,
    required this.pageCount,
    required this.pdfUrl,
    required this.storagePath,
    required this.memoryCount,
    required this.notebookId,
    this.coverPhotoKey,
    this.coverPhotoUrl,
  });

  Map<String, dynamic> toMap() => {
        'bookTitle': bookTitle,
        'coverType': coverType,
        'price': price,
        'pageCount': pageCount,
        'pdfUrl': pdfUrl,
      };
}

class _BookGenerateScreenState extends State<BookGenerateScreen>
    with TickerProviderStateMixin {
  // ── Data ───────────────────────────────────────────────────────────────────
  NotebookModel? _notebook;
  List<MemoryModel> _memories = [];
  // Tous les tags visibles (miens + partagés) — sert uniquement à retrouver
  // les tags enfant pour grouper les mesures taille/poids par enfant, voir
  // _growthGroups. Chargé une fois avec le reste (_loadData).
  List<TagModel> _allTags = [];
  String? _loadError; // message si le chargement initial échoue

  // ── State ──────────────────────────────────────────────────────────────────
  // Étape courante du parcours (indices globaux de BookStep : l'étape
  // « Souvenirs » est l'écran précédent, MemorySelectScreen).
  int _step = BookStep.photos;
  // Étape la plus avancée déjà atteinte : ses puces sont touchables.
  int _maxStep = BookStep.photos;
  // Première étape de CET écran : « Photos », ou « Format » quand on arrive
  // pour commander un livre déjà prêt (startAtOrder / editOrderId).
  int _firstStep = BookStep.photos;
  // Étape « Photos » : photos des souvenirs choisis (chargées une fois par
  // sélection, voir _ensurePhotoGroups) et options déjà validées.
  List<BookPhotoGroup>? _photoGroups;
  String? _photoGroupsKey;
  final Set<BookPhotoOption> _validatedPhotoOptions = {};
  // Dédicace activée à l'étape « Titre & dédicace » (facultative).
  bool _dedicationOn = false;
  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;

  // ── Aperçu préparé à l'avance ─────────────────────────────────────────────
  // À chaque étape validée, le PDF est généré en arrière-plan (_prefetch) :
  // quand on arrive à l'aperçu, il est souvent déjà prêt. `_previewSig` est
  // l'empreinte du contenu de l'aperçu affiché (_pdfSignature) — différente
  // de l'empreinte actuelle = aperçu périmé.
  Future<void>? _prefetchFuture;
  String? _prefetchSig;
  String? _previewSig;
  bool _prefetching = false;
  int _prefetchRun = 0;
  int _qualityWarningCount = 0;
  // Aperçu déjà annoncé (mesure + avertissement qualité) : une seule fois
  // par contenu, pas à chaque retour sur l'étape.
  String? _announcedSig;
  String _coverType = 'soft'; // 'soft', 'hard' ou 'layflat'
  // Chapitre croissance (courbe OMS) : un par enfant ayant ≥2 mesures dans
  // la sélection (voir _growthGroups), coché par défaut, décochable
  // individuellement — id de tag enfant présent ici = exclu du livre.
  final Set<String> _excludedGrowthChildIds = {};
  bool _generating = false;
  double _progress = 0.0;
  int _msgIndex = 0;
  Timer? _progressTimer;
  // ── Éditeur d'aperçu + brouillon (sauvegarde auto) ────────────────────────
  // Propres à CE livre : photos retirées et textes posés sur les photos, par
  // identifiant stable (rawMediaIdsOf). Le brouillon est créé à la 1ʳᵉ
  // génération de l'aperçu, puis réécrit à chaque retouche.
  String? _draftId;
  BookDraft? _pendingDraft; // brouillon à réappliquer une fois chargé
  String? _tagId; // widget.tagId, ou celui du brouillon repris
  List<String> _requestedIds = const [];
  final Set<String> _excludedPhotoIds = {};
  final Map<String, BookPhotoText> _photoTexts = {};
  // Octets des photos déjà téléchargées (URL → octets) : une retouche ne
  // retélécharge pas tout le livre (cf. BookPdfService.generateForNotebook).
  final Map<String, Uint8List> _photoCache = {};
  List<BookPhotoSlot> _slots = const [];
  bool _updatingPreview = false;
  int _previewSeq = 0;
  Timer? _draftSaveTimer;
  // Empreinte du dernier état sauvegardé (ou de l'état initial) : on n'écrit
  // que si quelque chose a VRAIMENT changé, et le brouillon n'est créé qu'au
  // premier vrai changement — ouvrir l'écran ne crée rien.
  String? _lastSavedSig;
  // Brouillon repris : bandeau récapitulatif sur l'écran de départ.
  BookDraft? _resumedDraft;
  // Réglages proposés pour le prochain texte : les derniers choisis (un livre
  // écrit d'une seule main a presque toujours la même police et la même
  // taille d'un bout à l'autre).
  String _lastTextColor = '#2D2416';
  String _lastTextFont = BookPhotoText.fontSerif;
  double _lastTextScale = 1;

  bool get _draftsEnabled => !widget.queueMode && widget.editOrderId == null;

  /// Toute modification d'état (sélection, titre, couverture, textes, photos
  /// retirées, aperçu…) programme une sauvegarde du brouillon ; elle n'écrit
  /// que si l'empreinte a changé (voir _saveDraftIfChanged).
  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleDraftSave();
  }
  Set<String> _selectedMemoryIds = {};
  String? _coverPhotoUrl;
  // Photo du DOS (4ᵉ de couverture, optionnelle) — même sélecteur que la
  // couverture. Sans elle, le dos reste un aplat de couleur (jamais blanc).
  String? _backCoverPhotoUrl;
  // Si vrai, la photo de couverture n'est pas répétée dans les pages du livre.
  bool _excludeCoverPhotoFromBook = false;
  // URLs de photos résolues par souvenir (R2 signé + Firebase). Sans ça, le
  // sélecteur de couverture était vide pour les souvenirs passés sur R2 (il ne
  // lisait que les URLs Firebase).
  final Map<String, List<String>> _photoUrlsByMemory = {};
  // URL (signée, R2) → clé R2 d'origine — permet de retrouver la clé de la
  // couverture choisie pour l'historique (voir BookHistoryService.recordBook
  // : on y stocke la CLÉ, jamais l'URL signée qui expire après 1h). Absent
  // pour une photo Firebase héritée (l'URL elle-même est alors permanente).
  final Map<String, String> _keyByUrl = {};

  // Aperçu WYSIWYG : on génère les MÊMES octets PDF que le téléchargement et on
  // affiche chaque page rastérisée → aucune différence possible avec le rendu
  // final / l'impression.
  Uint8List? _previewPdfBytes;
  int _previewPageCount = 0;
  int _previewPhotoCount = 0;

  late final TextEditingController _titleCtrl;

  // Mot imprimé seul sur la page qui suit la couverture (BookPdfService,
  // `dedication`). Facultatif, mais mis en avant quand le livre est offert.
  late final TextEditingController _dedicationCtrl;

  // Livre offert : l'adresse saisie est celle du destinataire, et elle ne
  // sert pas à pré-remplir les commandes suivantes (_loadLastAddress).
  late bool _isGift;

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

  // Livres supplémentaires déjà configurés et générés (PDF prêt, uploadé),
  // en attente d'être inclus dans la même commande que celui de cet écran —
  // voir OrderModel.additionalBooks / _addAnotherBook. Toujours vide en
  // queueMode (un livre en file ne porte pas lui-même d'autres livres).
  final List<_QueuedBook> _extraBooks = [];
  double get _totalPrice =>
      _priceFor(_coverType) + _extraBooks.fold(0.0, (sum, b) => sum + b.price);

  late AnimationController _coverAnim;
  late Animation<double> _coverScale;

  static const _loadingMessages = [
    // Le cadrage passe en premier (voir _ensureFocus) : c'est ce qui occupe
    // les premières secondes quand des photos n'ont jamais été analysées.
    'Je choisis le cadrage des photos…',
    'Je mets en page tes souvenirs…',
    'Je prépare les photos…',
    'Le livre prend forme…',
    'Presque prêt…',
  ];

  // Photos « en grand » de CE livre (22.10.26) : au départ celles réglées
  // sur les souvenirs (`bookFeaturedMedia`), ensuite propres au livre — les
  // changer ici ne touche plus les souvenirs, comme le retrait d'une photo.
  // null tant que les souvenirs ne sont pas chargés.
  Set<String>? _featuredPhotoIds;

  /// Le souvenir tel que CE livre le met en page (photos en grand du livre).
  MemoryModel _withBookFeatured(MemoryModel m) {
    final f = _featuredPhotoIds;
    if (f == null) return m;
    return m.copyWith(
        bookFeaturedMedia: rawMediaIdsOf(m).where(f.contains).toList());
  }

  List<MemoryModel> get _selectedMemories => _memories
      .where((m) => _selectedMemoryIds.contains(m.id))
      .map(_withBookFeatured)
      .toList();

  void _toggleFeaturedPhoto(String id) => setState(() {
        final f = _featuredPhotoIds ??= {};
        if (!f.remove(id)) f.add(id);
      });

  // ── QR de couverture ───────────────────────────────────────────────────────
  // Un seul code sur la couverture, qui rassemble les vidéos de TOUS les
  // souvenirs du livre. Cible : le « reel » public créé côté backend AVANT la
  // génération, puisque le QR doit déjà être imprimé dans le PDF.

  /// Souvenirs du livre qui ont au moins une vidéo. `videoKeys` seulement
  /// (pas d'ancienne URL Firebase) : même convention que le backend, pour que
  /// ce que promet le QR soit toujours ce que le reel peut servir.
  List<MemoryModel> get _videoMemories =>
      _selectedMemories.where((m) => m.videoKeys.isNotEmpty).toList();

  /// Dernière URL de QR obtenue, et la sélection qui l'a produite : l'aperçu
  /// est régénéré à chaque retouche, inutile de rappeler le backend tant que
  /// les souvenirs en vidéo n'ont pas changé.
  String? _coverQrUrl;
  String? _coverQrKey;

  /// URL du QR de couverture, ou null s'il n'y a aucune vidéo dans le livre
  /// (on n'imprime pas un code qui ne mène nulle part). Lève si le backend ne
  /// répond pas : mieux vaut un aperçu en erreur qu'une couverture qui perd
  /// silencieusement son QR juste avant une commande.
  Future<String?> _coverVideosQrUrl() async {
    final ids = _videoMemories.map((m) => m.id).toList()..sort();
    if (ids.isEmpty) return null;
    final key = ids.join(',');
    if (_coverQrUrl != null && _coverQrKey == key) return _coverQrUrl;
    final res = await BackendClient.postJson(
      '/api/video/book-reel-create',
      {'memoryIds': ids},
      timeout: const Duration(seconds: 30),
    );
    final reelId = res?['reelId'] as String?;
    if (reelId == null) {
      throw Exception(
          'Impossible de préparer les vidéos liées à la couverture.');
    }
    _coverQrKey = key;
    _coverQrUrl = '${AppConfig.backendUrl}/reel?o=$reelId';
    return _coverQrUrl;
  }

  // Mesures taille/poids de la sélection, groupées par enfant (identifié via
  // le tagId présent dans `tagIds` de la mesure — cf. growth_screen.dart, qui
  // pose toujours ce tag en premier à la création). Un groupe n'apparaît
  // que dès 2 mesures — même seuil que BookPdfService.generateForNotebook.
  // Permet plusieurs enfants dans un même livre (ex. "Mes souvenirs" sans
  // filtre de tag), chacun avec sa propre carte et sa propre page.
  List<({TagModel child, List<MemoryModel> measures})> get _growthGroups {
    final childTags = _allTags.where((t) => t.isChild).toList();
    final byChildId = <String, List<MemoryModel>>{};
    for (final m in _selectedMemories) {
      if (m.type != 'taille_poids') continue;
      if (m.heightCm == null && m.weightKg == null) continue;
      final childId = m.tagIds.firstWhere(
        (id) => childTags.any((c) => c.id == id),
        orElse: () => '',
      );
      if (childId.isEmpty) continue;
      byChildId.putIfAbsent(childId, () => []).add(m);
    }
    return [
      for (final entry in byChildId.entries)
        if (entry.value.length >= 2)
          (
            child: childTags.firstWhere((c) => c.id == entry.key),
            measures: entry.value,
          ),
    ];
  }

  List<TagModel> get _includedGrowthChildren => [
        for (final g in _growthGroups)
          if (!_excludedGrowthChildIds.contains(g.child.id)) g.child,
      ];

  // Texte du bandeau "Souvenirs inclus" — les mesures taille/poids ne sont
  // jamais comptées comme des souvenirs (voir _MemorySelectionSheet), les
  // chapitres croissance inclus sont mentionnés à part, par enfant.
  String get _memorySelectionSummary {
    final total = _memories.where((m) => m.type != 'taille_poids').length;
    final selected =
        _selectedMemories.where((m) => m.type != 'taille_poids').length;
    final base = selected == total
        ? 'Tous les souvenirs inclus ($total)'
        : '$selected souvenir${selected != 1 ? 's' : ''} sur $total inclus';
    final included = _includedGrowthChildren;
    if (included.isEmpty) return base;
    final names = included.map((t) => t.label).join(', ');
    return '$base + courbe de croissance ($names)';
  }

  // Photo la plus proche de chaque anniversaire (±30j), pour les mettre en
  // avant en pleine page (bookFeaturedMedia) sans repasser par un template
  // PDF dédié — voir _applyMilestoneSuggestions.
  List<({String label, MemoryModel memory, String rawId})>
      get _milestoneSuggestions {
    final birth = _notebook?.birthdate;
    if (birth == null || _notebook?.type != 'enfant') return const [];
    final anniversaries = {
      '1 an': birth.add(const Duration(days: 365)),
      '2 ans': birth.add(const Duration(days: 730)),
    };
    final result = <({String label, MemoryModel memory, String rawId})>[];
    for (final entry in anniversaries.entries) {
      MemoryModel? best;
      String? bestRawId;
      int? bestDiff;
      for (final m in _selectedMemories) {
        final rawIds = rawMediaIdsOf(m);
        if (rawIds.isEmpty) continue;
        final diff = m.date.difference(entry.value).inDays.abs();
        if (diff > 30) continue;
        if (bestDiff == null || diff < bestDiff) {
          bestDiff = diff;
          best = m;
          bestRawId = rawIds.first;
        }
      }
      if (best != null && bestRawId != null) {
        result.add((label: entry.key, memory: best, rawId: bestRawId));
      }
    }
    return result;
  }

  // Applique la suggestion en mettant la photo en grand DANS CE LIVRE —
  // seulement si ce souvenir n'a encore aucune photo en grand, pour ne
  // jamais écraser un choix déjà fait.
  void _applyMilestoneSuggestions() {
    final f = _featuredPhotoIds;
    if (f == null) return;
    final add = [
      for (final s in _milestoneSuggestions)
        if (!rawMediaIdsOf(s.memory).any(f.contains)) s.rawId,
    ];
    if (add.isNotEmpty) setState(() => f.addAll(add));
  }

  // Nombre de pages : on privilégie le VRAI compte de l'aperçu (déjà généré
  // avant l'étape format) ; sinon estimation. Pour l'imprimé, le prix se base
  // sur les pages réellement imprimées (bourrage pair, 24–300 —
  // cf. BookPricing.printablePages).
  int get _pages => _previewPageCount > 0
      ? _previewPageCount
      : BookPricing.estimatePages(_selectedMemories);

  int get _printedPages => _printedPagesFor(_coverType);
  // Le nombre de pages réellement imprimé dépend du format (souple ≥20,
  // rigide ≥24, tous deux arrondis pair) — calculer séparément pour chaque
  // couverture, pas seulement celle actuellement sélectionnée à l'écran
  // (sinon le prix affiché pour l'AUTRE format se basait sur le mauvais
  // nombre de pages, ex. 22 pages "souple" réutilisé tel quel pour le rigide
  // qui en exige 24 minimum).
  int _printedPagesFor(String coverType) =>
      BookPricing.printablePages(coverType, _pages);
  double _priceFor(String coverType) => BookPricing.price(
      coverType: coverType, pages: _printedPagesFor(coverType));
  String _priceLabel(String coverType) =>
      BookPricing.format(_priceFor(coverType));

  // Notre imprimeur refuse au-delà de 300 pages (plafond de
  // BookPdfService._validPageCount). Contrairement au minimum (comblé par des
  // pages blanches), on ne peut pas combler silencieusement un dépassement
  // sans tronquer du contenu réel — d'où le blocage plutôt qu'un simple
  // avertissement.
  bool get _exceedsPageLimit => _pages > 300;
  // Le layflat a une borne produit bien plus basse (122 pages) que soft/hard
  // (300) — un livre qui passe pour ces deux-là peut dépasser layflat seul.
  bool get _exceedsLayflatLimit => _pages > BookPricing.maxPages('layflat');
  // Pages blanches ajoutées en fin de livre pour atteindre le minimum
  // imprimeur (24, pair) — 0 si le livre dépasse déjà cette cible, ou s'il
  // dépasse la limite haute (auquel cas aucun bourrage n'est appliqué).
  int get _blankPagesAdded =>
      _exceedsPageLimit ? 0 : (_printedPages - _pages);

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
    _dedicationCtrl = TextEditingController();
    _isGift = widget.gift;
    _dedicationOn = widget.gift;
    _tagId = widget.tagId;
    _requestedIds = widget.memoryIds;
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
    _dedicationCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _streetCtrl.dispose();
    _cityCtrl.dispose();
    _npaCtrl.dispose();
    _countryCtrl.dispose();
    _coverAnim.dispose();
    _progressTimer?.cancel();
    // Retouche encore en attente d'écriture : on la sauve tout de suite.
    if (_draftSaveTimer?.isActive ?? false) _saveDraftIfChanged();
    _draftSaveTimer?.cancel();
    super.dispose();
  }

  // ── Load ───────────────────────────────────────────────────────────────────

  Future<void> _loadData() async {
    if (mounted) setState(() => _loadError = null);
    const t = Duration(seconds: 20);
    try {
      // Reprise d'un brouillon : il fournit la sélection d'origine.
      if (widget.draftId != null && _draftId == null) {
        final draft =
            await BookDraftService.get(widget.draftId!).timeout(t);
        if (!mounted) return;
        if (draft == null) {
          setState(() => _loadError = 'Ce brouillon n\'existe plus.');
          return;
        }
        _draftId = draft.id;
        _tagId = draft.tagId;
        _requestedIds = draft.requestedIds;
        _pendingDraft = draft;
      }
      // Les souvenirs retenus à l'écran de sélection, dans l'ordre chronologique.
      final visible = await MemoryQueryService.visible().first.timeout(t);
      // Tags enfant, pour grouper les mesures taille/poids par enfant
      // (chapitre croissance — voir _growthGroups). Best-effort : un échec
      // ici prive juste le livre du chapitre croissance, rien de bloquant.
      final tags = await TagService.visibleTags().timeout(t, onTimeout: () => const []);
      if (!mounted) return;
      // Cartes « Courbe de croissance » cochées dans /memories (ids
      // `growth:<tagId enfant>`, voir growth_chart_card.dart) : pas des
      // documents — on les remplace par les mesures de l'enfant.
      final growthChildIds = {
        for (final id in _requestedIds)
          if (id.startsWith(growthSelectionPrefix))
            id.substring(growthSelectionPrefix.length),
      };
      final wanted = _requestedIds
          .where((id) => !id.startsWith(growthSelectionPrefix))
          .toSet();
      final allMemories = visible
          .where((m) =>
              (wanted.isEmpty && growthChildIds.isEmpty) ||
              wanted.contains(m.id))
          .toList();
      if (growthChildIds.isNotEmpty) {
        // Courbe limitée à la période du livre (1er → dernier souvenir
        // choisi) : un livre « 2 premières années » montre 0-2 ans, pas les
        // mesures prises après. Sans souvenir (courbe seule) ou avec moins de
        // 2 mesures dans la période, on garde toutes les mesures de l'enfant
        // plutôt que de faire disparaître la courbe.
        final dated = allMemories.where((m) => m.type != 'taille_poids');
        DateTime? from, to;
        for (final m in dated) {
          if (from == null || m.date.isBefore(from)) from = m.date;
          if (to == null || m.date.isAfter(to)) to = m.date;
        }
        final already = allMemories.map((m) => m.id).toSet();
        for (final childId in growthChildIds) {
          final measures = visible
              .where((m) =>
                  m.type == 'taille_poids' &&
                  (m.heightCm != null || m.weightKg != null) &&
                  m.tagIds.contains(childId) &&
                  !already.contains(m.id))
              .toList();
          var inPeriod = measures;
          if (from != null && to != null) {
            final start = DateTime(from.year, from.month, from.day);
            final end = DateTime(to.year, to.month, to.day + 1);
            inPeriod = measures
                .where((m) =>
                    !m.date.isBefore(start) && m.date.isBefore(end))
                .toList();
          }
          allMemories.addAll(inPeriod.length >= 2 ? inPeriod : measures);
        }
      }
      allMemories.sort((a, b) => a.date.compareTo(b.date));

      if (allMemories.isEmpty) {
        setState(() => _loadError = 'Aucun souvenir à mettre dans ce livre.');
        return;
      }

      // Le PDF est écrit pour un « carnet » : sans carnet, on lui en fabrique un
      // à partir du tag d'origine (titre, couleur, date de naissance) ou, à
      // défaut, un carnet générique.
      final tag = _tagId != null
          ? await TagService.byId(_tagId!).timeout(t)
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
        _allTags = tags;
        _selectedMemoryIds = allMemories.map((m) => m.id).toSet();
        _featuredPhotoIds = {
          for (final m in allMemories) ...m.bookFeaturedMedia,
        };
        _coverPhotoUrl = defaultCover;
        _loadError = null;
        // Commande depuis « Mes livres », ou renvoi admin après erreur : on
        // saute directement aux options d'achat.
        if (widget.startAtOrder || widget.editOrderId != null) {
          _step = BookStep.format;
          _maxStep = BookStep.format;
          _firstStep = BookStep.format;
          _coverType = 'soft';
        }
      });
      // Initialise les champs éditables : le titre = ce qui s'affiche par
      // défaut sur la couverture (ex. « Léa & Nala »), pour que le champ soit
      // cohérent avec l'aperçu et directement modifiable.
      _titleCtrl.text = _defaultCoverTitle(nb);
      // Résout les URLs de photos (R2 signé + Firebase) pour peupler le
      // sélecteur de couverture, y compris pour les souvenirs sur R2.
      final resolving = _resolvePhotos(allMemories);
      // Photos "1 an"/"2 ans" : suggestion auto (silencieuse, non bloquante).
      _applyMilestoneSuggestions();
      // Admin : pré-remplit l'adresse de livraison (étape 2) avec celle de la
      // dernière commande, pour ne plus jamais avoir à la ressaisir.
      if (_isAdmin) _loadLastAddress();
      // Renvoi après erreur : pré-remplit adresse/titre/couverture avec ceux
      // de la commande à corriger (inchangés, seul le PDF est régénéré).
      if (widget.editOrderId != null) _loadEditOrderDefaults();
      final draft = _pendingDraft;
      if (draft != null) {
        _pendingDraft = null;
        await _applyDraft(draft, allMemories, resolving);
        // Brouillon repris : tout le parcours est déjà accessible.
        if (mounted) setState(() => _maxStep = BookStep.preview);
        _prefetch();
      } else if (_draftsEnabled) {
        // Le brouillon naît dès l'entrée dans le parcours (21.10.26) : les
        // souvenirs choisis à l'étape 1 sont déjà à l'abri. Empreinte vide =
        // « rien d'écrit encore » → la prochaine sauvegarde crée le doc.
        _lastSavedSig = '';
        _scheduleDraftSave();
        resolving.then((_) {
          if (!mounted) return;
          _scheduleDraftSave();
          // Photos résolues (couverture comprise) : on prépare l'aperçu
          // pendant que l'utilisateur choisit ses photos en grand.
          _prefetch();
        });
      } else {
        _lastSavedSig = _draftSignature();
        resolving.then((_) {
          if (mounted && _step < BookStep.format) _prefetch();
        });
      }
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
      // Une commande offerte porte l'adresse de quelqu'un d'autre : on prend
      // la dernière commande pour soi (le stream est déjà trié).
      final own = orders.where((o) => !o.isGift);
      if (own.isEmpty || !mounted || _isGift) return;
      final last = own.first;
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
      });
      _titleCtrl.text = order.bookTitle;
    } catch (_) {
      // Pas grave : les champs restent à saisir à la main.
    }
  }

  // ── Generation ─────────────────────────────────────────────────────────────

  /// Identifiant STABLE d'une photo à partir de son URL : la clé R2, ou l'URL
  /// elle-même pour une photo Firebase héritée (qui, elle, est permanente).
  /// Même convention que `rawMediaIdsOf`.
  String? _stableIdOf(String? url) {
    if (url == null || url.isEmpty) return null;
    return _keyByUrl[url] ?? url;
  }

  /// Calcule sur le téléphone le point de recadrage des photos du livre (les
  /// visages à garder quand la photo est rognée pour remplir sa case — toutes
  /// le sont). Les photos téléchargées pour l'analyse restent dans
  /// `_photoCache` : le PDF ne les retélécharge pas.
  ///
  /// Une photo n'est analysée QU'UNE fois : le point est stocké sur le
  /// souvenir. En cas d'échec (hors ligne, photo illisible), on ne bloque
  /// rien : le moteur retombe sur son cadrage par défaut.
  Future<void> _ensureFocus() async {
    final ids = <String>{};
    for (final m in _selectedMemories) {
      for (final id in rawMediaIdsOf(m)) {
        if (id.isNotEmpty && !_excludedPhotoIds.contains(id)) ids.add(id);
      }
    }
    // La couverture et le dos comptent, même si l'éditeur les a retirés des
    // pages intérieures.
    for (final id in [
      _stableIdOf(_coverPhotoUrl),
      _stableIdOf(_backCoverPhotoUrl)
    ]) {
      if (id != null) ids.add(id);
    }
    if (ids.isEmpty) return;

    try {
      final focus =
          await PhotoFocusService.ensure(_selectedMemories,
              onlyIds: ids, bytesCache: _photoCache);
      if (!mounted) return;
      // `_selectedMemories` est un getter dérivé de `_memories` : c'est là
      // qu'on recopie les points pour que le moteur les voie.
      _memories = PhotoFocusService.applied(_memories, focus);
    } catch (_) {
      // Cadrage par défaut : un livre part toujours.
    }
  }

  // Génère le PDF d'aperçu — mêmes octets que le téléchargement (sans bourrage
  // de pages blanches), pour un aperçu strictement identique au rendu final.
  Future<BookPdfResult> _buildPreviewPdf() async {
    final coverColor = _notebook!.coverColor.isNotEmpty
        ? Color(int.parse('FF${_notebook!.coverColor.replaceAll('#', '')}',
            radix: 16))
        : AppColors.sage;
    // L'aperçu porte le VRAI QR (mêmes octets que le PDF téléchargé/partagé) :
    // un aperçu avec un code mort serait partagé tel quel.
    final coverQrUrl = await _coverVideosQrUrl();
    return BookPdfService.generateForNotebook(
      notebook: _notebook!,
      coverColor: coverColor,
      memories: _selectedMemories,
      excludedPhotoIds: _excludedPhotoIds,
      photoTexts: _photoTexts,
      photoCache: _photoCache,
      coverPhotoUrl: _coverPhotoUrl,
      excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
      backCoverPhotoUrl: _backCoverPhotoUrl,
      customTitle:
          _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null,
      backendUrl: AppConfig.backendUrl,
      coverVideosQrUrl: coverQrUrl,
      growthChildren: _includedGrowthChildren,
      coverPhotoId: _stableIdOf(_coverPhotoUrl),
      backCoverPhotoId: _stableIdOf(_backCoverPhotoUrl),
      dedication: _dedicationCtrl.text,
    ).timeout(const Duration(seconds: 180));
  }

  /// Empreinte de tout ce qui change le PDF : si elle n'a pas bougé depuis le
  /// dernier aperçu, inutile de le régénérer.
  String _pdfSignature() => jsonEncode({
        ..._contentMap(),
        'layout': {
          for (final m in _selectedMemories)
            m.id: [
              m.bookFeaturedMedia,
              m.bookVerticalDensity,
              m.bookHorizontalDensity,
            ],
        },
      });

  /// Recopie un PDF généré dans l'état de l'aperçu (à appeler dans setState).
  void _applyPreviewResult(BookPdfResult gen, String sig) {
    _previewPdfBytes = gen.bytes;
    _previewPageCount = gen.pageCount;
    _previewPhotoCount = gen.photoCount;
    _slots = gen.slots;
    _qualityWarningCount = gen.qualityWarnings.length;
    _previewSig = sig;
  }

  /// Prépare l'aperçu en arrière-plan, sans rien afficher : cadrage des
  /// photos, téléchargement, mise en page. Appelé à chaque étape validée ;
  /// ne fait rien si l'aperçu du contenu actuel est déjà prêt ou en cours.
  void _prefetch() {
    if (_notebook == null || _selectedMemories.isEmpty) return;
    final sig = _pdfSignature();
    if (sig == _previewSig || sig == _prefetchSig) return;
    _prefetchSig = sig;
    final seq = ++_previewSeq;
    final run = ++_prefetchRun;
    final expectedPhotos = _allPhotoUrls.length - _excludedPhotoIds.length;
    if (mounted) setState(() => _prefetching = true);
    _prefetchFuture = () async {
      try {
        await _ensureFocus();
        final gen = await _buildPreviewPdf();
        if (!mounted || seq != _previewSeq) return;
        // Échec massif de téléchargement : on n'en fait pas un aperçu —
        // l'étape Aperçu relancera une génération qui, elle, prévient.
        if (expectedPhotos > 0 && gen.photoCount < expectedPhotos * 0.5) {
          return;
        }
        setState(() => _applyPreviewResult(gen, sig));
      } catch (_) {
        // Silencieux : l'étape Aperçu réessaiera et affichera l'erreur.
      } finally {
        if (_prefetchSig == sig) _prefetchSig = null;
        if (mounted && run == _prefetchRun) {
          setState(() => _prefetching = false);
        }
      }
    }();
  }

  /// Ouvre l'étape Aperçu : instantané si l'aperçu préparé est à jour, sinon
  /// génération (avec progression).
  Future<void> _goToPreview() async {
    if (_selectedMemories.isEmpty) {
      _showSnack('Sélectionne au moins un souvenir avant de créer le livre.');
      return;
    }
    _goTo(BookStep.preview);
    await _generate();
    if (!mounted || _step != BookStep.preview) return;
    final sig = _previewSig;
    if (sig == null || sig == _announcedSig) return;
    _announcedSig = sig;
    // Mesure : l'aperçu s'affiche POUR DE BON. C'est la première vraie
    // marque d'intention d'achat de l'entonnoir.
    AnalyticsService.logBookPreviewOpened(
      pageCount: _previewPageCount,
      photoCount: _previewPhotoCount,
      memoryCount: _selectedMemories.length,
    );
    // Prévient AVANT l'achat plutôt que de laisser découvrir une photo
    // floue à réception — jamais bloquant.
    final n = _qualityWarningCount;
    if (n > 0) {
      _showSnack(
        n == 1
            ? '1 photo risque d\'être floue à l\'impression (résolution trop faible pour sa taille dans le livre).'
            : '$n photos risquent d\'être floues à l\'impression (résolution trop faible pour leur taille dans le livre).',
      );
    }
  }

  void _goTo(int step) {
    setState(() {
      _step = step;
      if (step > _maxStep) _maxStep = step;
    });
  }

  /// Génère l'aperçu du contenu actuel, avec l'écran de progression — sauf
  /// s'il est déjà prêt (rien à faire) ou en préparation (on l'attend).
  Future<void> _generate() async {
    if (_selectedMemories.isEmpty) {
      _showSnack('Sélectionne au moins un souvenir avant de créer le livre.');
      return;
    }
    if (_notebook == null) return;
    final sig = _pdfSignature();
    if (_previewSig == sig && _previewPdfBytes != null) return;

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
      // Déjà en préparation en arrière-plan pour ce même contenu : on
      // l'attend plutôt que de tout refaire.
      final pending = _prefetchFuture;
      if (_prefetchSig == sig && pending != null) {
        await pending;
        if (!mounted) return;
        if (_previewSig == sig) {
          _progressTimer?.cancel();
          setState(() {
            _progress = 1.0;
            _generating = false;
          });
          return;
        }
      }
      final seq = ++_previewSeq;
      // Combien de photos on s'attend à voir dans le livre, calculé AVANT
      // toute tentative de téléchargement — sert de référence pour détecter
      // un échec de téléchargement massif (voir garde-fou ci-dessous).
      final expectedPhotos = _allPhotoUrls.length - _excludedPhotoIds.length;
      // Avant de rendre quoi que ce soit : le point de recadrage de chaque
      // photo, pour que l'aperçu montre le VRAI cadrage imprimé.
      await _ensureFocus();
      final gen = await _buildPreviewPdf();
      if (!mounted) return;
      _progressTimer?.cancel();
      if (seq != _previewSeq) {
        // Une génération plus récente a pris le relais.
        setState(() => _generating = false);
        return;
      }
      // L'aperçu tolère silencieusement les photos manquantes (une par une,
      // c'est voulu), mais un échec massif (réseau coupé, throttle R2…) ne
      // doit jamais se présenter comme un livre généré avec succès — sans ce
      // garde-fou, on affichait déjà « 0 photos » comme un aperçu normal.
      if (expectedPhotos > 0 && gen.photoCount < expectedPhotos * 0.5) {
        setState(() => _generating = false);
        _showSnack(
          'Échec du téléchargement des photos (${gen.photoCount}/$expectedPhotos) — '
          'vérifie ta connexion et réessaie.',
        );
        return;
      }
      setState(() {
        _applyPreviewResult(gen, sig);
        _progress = 1.0;
        _generating = false;
      });
      // Mesure et avertissement qualité : voir _goToPreview.
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
      coverType: _coverType,
      notebookId: _tagId ?? '',
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
        format: 'digital',
        coverType: coverType,
        pdfUrl: uploaded.url,
        storagePath: uploaded.key,
        memoriesCount: memoriesCount,
        coverPhotoKey: _coverPhotoUrl != null ? _keyByUrl[_coverPhotoUrl] : null,
        coverPhotoUrl:
            _coverPhotoUrl != null && !_keyByUrl.containsKey(_coverPhotoUrl!)
                ? _coverPhotoUrl
                : null,
      );
    } catch (_) {
      // Silencieux — le partage a déjà eu lieu
    }
  }

  Future<void> _placeOrder() async {
    // Garde de ré-entrance : le bouton disparaît dès `_ordering`, mais un
    // double-tap dans la même frame appelle encore deux fois cette méthode
    // via la closure `onPressed` capturée au build précédent — sans ce
    // court-circuit, ça crée deux commandes identiques.
    if (_ordering) return;
    // Garde-fou : au cas où l'étape précédente serait contournée, on bloque
    // ici aussi — un livre trop long envoyé à l'impression avec un pageCount
    // tronqué causerait un nombre de pages annoncé différent du PDF
    // réellement généré.
    if (_exceedsPageLimit) {
      _showSnack(
          'Ce livre dépasse 300 pages — retire des souvenirs avant de commander.');
      return;
    }
    final isEdit = widget.editOrderId != null;
    // Pas d'adresse en queueMode : ce livre rejoint une commande dont
    // l'adresse est saisie sur l'écran racine (voir _buildOrderStep).
    if (!isEdit &&
        !widget.queueMode &&
        !(_addressKey.currentState?.validate() ?? false)) {
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _notebook == null) return;

    setState(() {
      _ordering = true;
      _orderMessage = 'Génération du livre…';
    });
    try {
      // Pas de `price` local ici : un livre mis en file est un article
      // SUPPLÉMENTAIRE de la commande, donc tarifé port déduit
      // (BookPricing.priceAdditional, plus bas) ; la commande racine, elle,
      // passe par `_totalPrice`.
      final bookTitle = _titleCtrl.text.trim().isNotEmpty
          ? _titleCtrl.text.trim()
          : _notebook!.title;
      final customTitle =
          _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null;

      // 1. Générer le PDF en premier. Le recadrage est déjà connu si l'aperçu
      // est passé par là ; sinon (commande lancée directement depuis « Mes
      // livres »), on l'analyse ici — et une photo déjà analysée ne l'est pas
      // une seconde fois.
      await _ensureFocus();
      final coverColor = Color(int.parse(
          'FF${_notebook!.coverColor.replaceAll('#', '')}',
          radix: 16));
      final gen = await BookPdfService.generateForNotebook(
        notebook: _notebook!,
        coverColor: coverColor,
        memories: _selectedMemories,
        excludedPhotoIds: _excludedPhotoIds,
        photoTexts: _photoTexts,
        photoCache: _photoCache,
        coverPhotoUrl: _coverPhotoUrl,
        excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
        backCoverPhotoUrl: _backCoverPhotoUrl,
        customTitle: customTitle,
        backendUrl: AppConfig.backendUrl,
        coverVideosQrUrl: await _coverVideosQrUrl(),
        padForPrint: true, // pages valides imprimeur (pair, ≥24)
        coverType: _coverType, // largeur exacte de couverture wraparound
        growthChildren: _includedGrowthChildren,
        coverPhotoId: _stableIdOf(_coverPhotoUrl),
        backCoverPhotoId: _stableIdOf(_backCoverPhotoUrl),
        dedication: _dedicationCtrl.text,
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

      if (widget.queueMode) {
        Navigator.pop(
          context,
          _QueuedBook(
            bookTitle: bookTitle,
            coverType: _coverType,
            // Prix d'un article SUPPLÉMENTAIRE : port déduit. Prodigi ne
            // facture la livraison qu'une fois par commande groupée — la
            // compter sur chaque article surfacturait le client (audit du
            // 01.10.26). Le backend recalcule à l'identique.
            price: BookPricing.priceAdditional(
                coverType: _coverType, pages: _printedPagesFor(_coverType)),
            pageCount: pageCount,
            pdfUrl: pdfUrl,
            storagePath: uploaded.key,
            memoryCount: _selectedMemories.length,
            notebookId: _tagId ?? '',
            coverPhotoKey:
                _coverPhotoUrl != null ? _keyByUrl[_coverPhotoUrl] : null,
            coverPhotoUrl: _coverPhotoUrl != null &&
                    !_keyByUrl.containsKey(_coverPhotoUrl!)
                ? _coverPhotoUrl
                : null,
          ),
        );
        return;
      }

      // Renvoi après erreur : on ne crée PAS de nouvelle commande — le PDF
      // régénéré est renvoyé pour LA MÊME commande. Le backend revérifie
      // lui-même le plafond de 3 tentatives ; ses messages d'erreur sont
      // affichés tels quels.
      if (isEdit) {
        setState(() => _orderMessage = 'Renvoi à l\'impression…');
        await OrderService.sendToPrint(
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
        price: _totalPrice,
        firstName: _firstNameCtrl.text.trim(),
        lastName: _lastNameCtrl.text.trim(),
        street: _streetCtrl.text.trim(),
        city: _cityCtrl.text.trim(),
        npa: _npaCtrl.text.trim(),
        country: _countryCtrl.text.trim(),
        status: 'received',
        createdAt: DateTime.now(),
        notebookId: _tagId ?? '',
        memoryCount: _selectedMemories.length,
        pageCount: pageCount,
        pdfUrl: pdfUrl,
        isGift: _isGift,
        additionalBooks: _extraBooks.isEmpty
            ? null
            : _extraBooks.map((b) => b.toMap()).toList(),
      );
      final orderId = await OrderService.createOrder(order);

      // 4. Historique des livres (imprimé) — le principal, puis chaque livre
      // groupé (même commande, même livraison, voir OrderModel.additionalBooks).
      await BookHistoryService.recordBook(
        notebookId: _tagId ?? '',
        title: bookTitle,
        format: 'printed',
        coverType: _coverType,
        pdfUrl: pdfUrl,
        storagePath: uploaded.key,
        memoriesCount: _selectedMemories.length,
        orderId: orderId,
        coverPhotoKey: _coverPhotoUrl != null ? _keyByUrl[_coverPhotoUrl] : null,
        coverPhotoUrl:
            _coverPhotoUrl != null && !_keyByUrl.containsKey(_coverPhotoUrl!)
                ? _coverPhotoUrl
                : null,
      );
      for (final extra in _extraBooks) {
        await BookHistoryService.recordBook(
          notebookId: extra.notebookId,
          title: extra.bookTitle,
          format: 'printed',
          coverType: extra.coverType,
          pdfUrl: extra.pdfUrl,
          storagePath: extra.storagePath,
          memoriesCount: extra.memoryCount,
          orderId: orderId,
          coverPhotoKey: extra.coverPhotoKey,
          coverPhotoUrl: extra.coverPhotoUrl,
        );
      }

      if (_draftId != null) {
        BookDraftService.markOrdered(_draftId!).catchError((_) {});
      }

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
      : 'Commander · ${BookPricing.format(_totalPrice)}';

  /// Ouvre un aller-retour complet (choix des souvenirs, couverture, format)
  /// qui renvoie un livre prêt (PDF déjà généré et uploadé) plutôt que de
  /// créer une commande — voir BookGenerateScreen en `queueMode`. Ajouté au
  /// panier local (`_extraBooks`), inclus dans la commande unique au moment
  /// de "Commander" (voir _placeOrder).
  Future<void> _addAnotherBook() async {
    final ids = await context.push<List<String>>('/memories?select=1');
    if (ids == null || ids.isEmpty || !mounted) return;
    final book = await context
        .push<_QueuedBook>('/book/new?memories=${ids.join(',')}&queue=1');
    if (book != null && mounted) setState(() => _extraBooks.add(book));
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
      canPop: _step == _firstStep,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _stepBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background,
          elevation: 0,
          title: Text(
            widget.gift ? 'Offrir un livre' : 'Créer un livre',
            style: const TextStyle(
              fontFamily: 'PlayfairDisplay',
              fontWeight: FontWeight.bold,
              color: AppColors.textDark,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
            onPressed: () {
              if (_step > _firstStep) {
                _stepBack();
              } else if (context.canPop()) {
                context.pop();
              } else {
                context.go('/home');
              }
            },
          ),
          actions: [
            if (_draftId != null && _draftsEnabled)
              IconButton(
                tooltip: 'Supprimer le brouillon',
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.textMedium),
                onPressed: _deleteDraft,
              ),
          ],
        ),
        body: Column(
          children: [
            BookStepHeader(
              index: _step,
              maxReachable: _maxStep,
              onTapStep: _ordering ? null : _onTapStep,
              status: _headerStatus,
              statusBusy: _prefetching && _step < BookStep.preview,
            ),
            Expanded(
              child: switch (_step) {
                BookStep.photos => _buildPhotosStep(),
                BookStep.title => _buildTitleStep(),
                BookStep.comments => _buildCommentsStep(),
                BookStep.preview => _buildPreviewStepView(),
                BookStep.format => _buildFormatStep(),
                _ => _buildOrderStep(),
              },
            ),
            if (_step < BookStep.preview) _buildStepActions(),
          ],
        ),
      ),
    );
  }

  // ── Navigation entre étapes ────────────────────────────────────────────────

  void _stepBack() {
    if (_step <= _firstStep) return;
    _goTo(_step - 1);
  }

  /// Puce touchée dans l'en-tête : « Souvenirs » rouvre la sélection sur
  /// place, « Aperçu » passe par _goToPreview (génération si besoin).
  void _onTapStep(int step) {
    if (step == BookStep.memories) {
      _openMemorySelection();
    } else if (step == BookStep.preview) {
      _goToPreview();
    } else if (step >= _firstStep) {
      _goTo(step);
    }
  }

  /// Étape validée : on avance, et l'aperçu prend de l'avance en arrière-plan.
  void _stepNext() {
    if (_step == BookStep.comments) {
      _goToPreview();
      return;
    }
    _goTo(_step + 1);
    _prefetch();
  }

  String? get _headerStatus {
    if (!_draftsEnabled) return null;
    final ready = _previewSig != null && _previewSig == _pdfSignature();
    if (_step < BookStep.preview) {
      if (_prefetching) return 'Aperçu en préparation…';
      if (ready) {
        return _draftId != null
            ? 'Brouillon enregistré · aperçu prêt'
            : 'Aperçu prêt';
      }
    }
    return _draftId != null ? 'Brouillon enregistré automatiquement' : null;
  }

  /// Barre fixe en bas des étapes de composition : « Continuer » valide
  /// l'étape. Pas d'aperçu avant l'étape Aperçu (22.10.26) : il se prépare
  /// en arrière-plan.
  Widget _buildStepActions() {
    // Étapes facultatives (Photos, Commentaires) : tant que rien n'y est
    // fait, le bouton dit clairement qu'on peut passer.
    final label = switch (_step) {
      BookStep.photos => _validatedPhotoOptions.isEmpty
          ? 'Passer cette étape · titre et dédicace'
          : 'Continuer · titre et dédicace',
      BookStep.title => 'Continuer · commentaires',
      _ => _photoTexts.isEmpty
          ? 'Passer cette étape · voir l\'aperçu'
          : 'Voir l\'aperçu du livre',
    };
    final empty = _selectedMemories.isEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
        child: ElevatedButton(
          onPressed: empty ? null : _stepNext,
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
          ),
          child: Text(label, textAlign: TextAlign.center),
        ),
      ),
    );
  }

  /// Bandeau « souvenirs inclus » — rouvre la sélection sans quitter le
  /// parcours.
  Widget _selectionSummaryCard() {
    return GestureDetector(
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
                _memorySelectionSummary,
                style: const TextStyle(color: AppColors.textDark, fontSize: 13),
              ),
            ),
            const Text('Modifier',
                style: TextStyle(
                    color: AppColors.sage,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
            const Icon(Icons.chevron_right, color: AppColors.sage, size: 18),
          ],
        ),
      ),
    );
  }

  /// Titre d'étape + phrase d'explication, en tête de chaque étape.
  Widget _stepIntro(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        const SizedBox(height: 6),
        Text(body,
            style: const TextStyle(
                fontSize: 13.5, color: AppColors.textMedium, height: 1.4)),
      ],
    );
  }

  // ── Étape 2 : photos (en grand, à retirer, couverture) ─────────────────────

  /// Charge, une fois par sélection de souvenirs, les photos qu'affichent
  /// les étapes Photos et Commentaires.
  void _ensurePhotoGroups() {
    final key = (_selectedMemoryIds.toList()..sort()).join(',');
    if (_photoGroupsKey == key) return;
    _photoGroupsKey = key;
    _photoGroups = null;
    loadBookPhotoGroups(_selectedMemories).then((groups) {
      if (!mounted || _photoGroupsKey != key) return;
      setState(() => _photoGroups = groups);
    });
  }

  /// Groupes chargés, avec la version À JOUR de chaque souvenir (les photos
  /// en grand changent pendant le parcours).
  List<BookPhotoGroup> get _currentPhotoGroups => [
        for (final g in _photoGroups ?? const <BookPhotoGroup>[])
          BookPhotoGroup(
              _memories.firstWhere((m) => m.id == g.memory.id,
                  orElse: () => g.memory),
              g.photos),
      ];

  int get _featuredCount {
    var n = 0;
    for (final m in _selectedMemories) {
      n += m.bookFeaturedMedia
          .where((id) => !_excludedPhotoIds.contains(id))
          .length;
    }
    return n;
  }

  /// URL d'affichage d'une photo à partir de son identifiant stable — celle
  /// déjà résolue par _resolvePhotos quand on la connaît.
  String? _urlOfPhotoId(String? id) {
    if (id == null) return null;
    for (final e in _keyByUrl.entries) {
      if (e.value == id) return e.key;
    }
    return _allPhotoUrls.contains(id) ? id : null;
  }

  /// Couverture (ou dos) choisie dans l'option Couverture, par identifiant.
  /// Photo pas encore résolue ici : on garde l'URL de l'écran de choix et on
  /// retient sa clé, pour que le brouillon et la commande stockent la clé.
  void _setCoverPhoto(String? id, String? url, {required bool back}) {
    String? resolved;
    if (id != null) {
      resolved = _urlOfPhotoId(id);
      if (resolved == null && url != null) {
        resolved = url;
        if (url != id) _keyByUrl[url] = id;
      }
    }
    setState(() {
      if (back) {
        _backCoverPhotoUrl = resolved;
      } else {
        _coverPhotoUrl = resolved;
      }
    });
  }

  BookPhotoChoices get _photoChoices => BookPhotoChoices(
        excluded: () => _excludedPhotoIds,
        featured: () => _featuredPhotoIds ?? const <String>{},
        onToggleFeatured: _toggleFeaturedPhoto,
        onToggleExcluded: (id) => setState(() {
          if (!_excludedPhotoIds.remove(id)) _excludedPhotoIds.add(id);
        }),
        coverId: () => _stableIdOf(_coverPhotoUrl),
        backCoverId: () => _stableIdOf(_backCoverPhotoUrl),
        onSetCover: (id, url) => _setCoverPhoto(id, url, back: false),
        onSetBackCover: (id, url) => _setCoverPhoto(id, url, back: true),
        excludeCoverFromBook: () => _excludeCoverPhotoFromBook,
        onExcludeCoverFromBook: (v) =>
            setState(() => _excludeCoverPhotoFromBook = v),
      );

  /// Ouvre une option en plein écran ; « Valider » la coche sur l'étape.
  Future<void> _openPhotoOption(BookPhotoOption option) async {
    final groups = _currentPhotoGroups;
    if (groups.isEmpty) return;
    final ok = await BookPhotoPickScreen.open(context,
        option: option, groups: groups, choices: _photoChoices);
    if (!mounted) return;
    setState(() {
      if (ok) _validatedPhotoOptions.add(option);
    });
    _prefetch();
  }

  Widget _buildPhotosStep() {
    _ensurePhotoGroups();
    final groups = _photoGroups;
    final featured = _featuredCount;
    final removed = _excludedPhotoIds.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
      children: [
        if (_resumedDraft != null) _resumedDraftBanner(),
        _stepIntro(
            'Les photos',
            'Trois choix, dans l\'ordre que tu veux : touche une option, '
                'fais ta sélection, puis valide. Tout est facultatif.'),
        const SizedBox(height: 12),
        _selectionSummaryCard(),
        for (final s in _milestoneSuggestions)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                const Icon(Icons.cake_outlined,
                    size: 18, color: AppColors.sage),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Photo « ${s.label} » déjà mise en grand',
                      style: const TextStyle(
                          color: AppColors.textDark, fontSize: 13)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 18),
        if (groups == null)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (groups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text('Aucune photo dans les souvenirs choisis.',
                  style: TextStyle(color: AppColors.textMedium)),
            ),
          )
        else ...[
          _photoOptionCard(
            option: BookPhotoOption.remove,
            number: 1,
            icon: Icons.remove_circle_outline,
            title: 'Photos à retirer',
            subtitle: removed == 0
                ? 'Celles que tu ne veux pas dans le livre'
                : removed == 1
                    ? '1 photo retirée'
                    : '$removed photos retirées',
          ),
          _photoOptionCard(
            option: BookPhotoOption.featured,
            number: 2,
            icon: Icons.star_rounded,
            title: 'Photos en grand',
            subtitle: featured == 0
                ? 'Une page entière pour tes préférées'
                : '$featured photo${featured > 1 ? 's' : ''} en pleine page',
          ),
          _photoOptionCard(
            option: BookPhotoOption.cover,
            number: 3,
            icon: Icons.auto_stories_outlined,
            title: 'Couverture',
            subtitle: _coverPhotoUrl == null
                ? 'Choisis la photo de couverture'
                : _backCoverPhotoUrl != null
                    ? 'Couverture et dos choisis'
                    : 'Photo de couverture choisie',
            thumbUrl: _coverPhotoUrl,
          ),
        ],
      ],
    );
  }

  Widget _photoOptionCard({
    required BookPhotoOption option,
    required int number,
    required IconData icon,
    required String title,
    required String subtitle,
    String? thumbUrl,
  }) {
    final done = _validatedPhotoOptions.contains(option);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openPhotoOption(option),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: done ? AppColors.sage : AppColors.border,
                  width: done ? 1.5 : 0.5),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child: thumbUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: CachedNetworkImage(
                            imageUrl: thumbUrl,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) =>
                                Icon(icon, color: AppColors.sage),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: AppColors.sageTint,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: AppColors.sageDark),
                        ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$number · $title',
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textDark)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12.5, color: AppColors.textMedium)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                done
                    ? const Icon(Icons.check_circle, color: AppColors.sage)
                    : const Icon(Icons.chevron_right,
                        color: AppColors.textMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Étape 3 : titre et dédicace ────────────────────────────────────────────

  Widget _buildTitleStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepIntro(
              'Titre et dédicace',
              _isGift
                  ? 'Le titre s\'imprime sur la couverture. Ton mot, seul sur '
                      'la première page, accompagnera le cadeau.'
                  : 'Le titre s\'imprime sur la couverture. Une dédicace, si '
                      'tu le souhaites, occupe seule la première page.'),
          const SizedBox(height: 18),
          Center(
            child: ScaleTransition(
              scale: _coverScale,
              child: _coverPreview(scale: 0.8),
            ),
          ),
          const SizedBox(height: 18),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppColors.sage,
            value: _dedicationOn,
            onChanged: (v) => setState(() {
              _dedicationOn = v;
              // Désactivée = rien d'imprimé : le texte part avec.
              if (!v) _dedicationCtrl.clear();
            }),
            title: Text(
              _isGift
                  ? 'Ajouter un mot en première page'
                  : 'Ajouter une dédicace',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark),
            ),
            subtitle: const Text('Imprimée seule, juste après la couverture',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMedium)),
          ),
          if (_dedicationOn) ...[
            const SizedBox(height: 6),
            TextField(
              controller: _dedicationCtrl,
              autofocus: _dedicationCtrl.text.isEmpty,
              textAlign: TextAlign.center,
              textCapitalization: TextCapitalization.sentences,
              minLines: 3,
              maxLines: 6,
              maxLength: 280,
              style: const TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 15,
                color: AppColors.textDark,
              ),
              decoration: _bookFieldDecoration(
                label: _isGift
                    ? 'Ton mot, imprimé en première page'
                    : 'Ta dédicace',
                icon: Icons.favorite_border,
              ).copyWith(
                hintText: 'Pour Mamie Jeanne, avec tout notre amour',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ],
      ),
    );
  }

  // ── Étape 4 : commentaires ─────────────────────────────────────────────────

  Widget _buildCommentsStep() {
    _ensurePhotoGroups();
    final n = _photoTexts.length;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stepIntro(
                    'Les commentaires',
                    'Un prénom, une date, une anecdote : écris-le directement '
                        'sur la photo, il sera imprimé dans le livre.'),
                const SizedBox(height: 12),
                _commentsHowTo(),
                const SizedBox(height: 10),
                Text(
                  n == 0
                      ? 'Facultatif — touche une photo pour commencer.'
                      : '$n commentaire${n > 1 ? 's' : ''} · enregistré'
                          '${n > 1 ? 's' : ''} dans ton brouillon',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textMedium),
                ),
              ],
            ),
          ),
        ),
        if (_photoGroups == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else
          BookCommentsGrid(
            groups: _currentPhotoGroups,
            excluded: _excludedPhotoIds,
            texts: _photoTexts,
            onEdit: _editPhotoFromGrid,
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Mode d'emploi de l'éditeur de commentaires, en quatre gestes.
  Widget _commentsHowTo() {
    Widget line(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: AppColors.sageDark),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textDark, height: 1.35)),
              ),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        children: [
          line(Icons.touch_app_outlined, 'Touche une photo pour l\'ouvrir.'),
          line(Icons.edit_outlined,
              'Écris ton texte, puis choisis la police, la taille et la couleur.'),
          line(Icons.open_with,
              'Déplace l\'encadré au doigt, là où il ne cache rien d\'important.'),
          line(Icons.menu_book_outlined,
              'L\'aperçu, juste après, montre le rendu exact — tu pourras '
                  'encore y retoucher un texte.'),
        ],
      ),
    );
  }

  /// Photo touchée dans la grille des commentaires : même éditeur que dans
  /// l'aperçu, sur la case du livre si l'aperçu préparé la connaît déjà.
  Future<void> _editPhotoFromGrid(
      String memoryId, String id, String url) async {
    final slot =
        _slots.where((s) => s.rawId == id && s.bytes != null).firstOrNull ??
            await _standaloneSlot(memoryId, id, url);
    if (!mounted) return;
    if (slot == null) {
      _showSnack('Photo indisponible pour l\'instant — vérifie ta connexion.');
      return;
    }
    await _onPhotoTap(slot);
  }

  /// Case « hors livre » pour l'éditeur, quand l'aperçu préparé n'a pas
  /// encore cette photo : la photo entière, à la largeur d'une demi-page. La
  /// position du texte est relative (x/y 0..1) : l'aperçu la reporte ensuite
  /// dans la vraie case.
  Future<BookPhotoSlot?> _standaloneSlot(
      String memoryId, String id, String url) async {
    try {
      var bytes = _photoCache[url];
      if (bytes == null) {
        final res = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return null;
        bytes = res.bodyBytes;
      }
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      final w = frame.image.width, h = frame.image.height;
      frame.image.dispose();
      if (w == 0 || h == 0) return null;
      const cellW = 297.6; // demi-largeur d'une page A4, en points
      return BookPhotoSlot(
        pageIndex: -1,
        memoryId: memoryId,
        rawId: id,
        bytes: bytes,
        isPortrait: h > w,
        widthPt: cellW,
        heightPt: cellW * h / w,
        left: 0,
        top: 0,
        width: 0,
        height: 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Couverture dessinée en direct (titre et photo choisis).
  Widget _coverPreview({required double scale}) {
    final coverColor = Color(
        int.parse('FF${_notebook!.coverColor.replaceAll('#', '')}', radix: 16));
    final cover = BookCoverPreview(
      notebook: _notebook!,
      coverColor: coverColor,
      coverPhotoUrl: _coverPhotoUrl,
      yearRange: _yearRange,
      highlights: _coverHighlights,
      hasVideos: _videoMemories.isNotEmpty,
      title: _titleCtrl.text.trim().isEmpty
          ? _defaultCoverTitle(_notebook!)
          : _titleCtrl.text.trim(),
    );
    return scale == 1 ? cover : Transform.scale(scale: scale, child: cover);
  }

  // ── Étape 5 : aperçu et commentaires ───────────────────────────────────────

  Widget _buildPreviewStepView() {
    if (_generating || (_previewPdfBytes == null && _prefetching)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ProgressBar(progress: _generating ? _progress : 0.5),
              const SizedBox(height: 12),
              Text(
                _loadingMessages[_msgIndex],
                style: const TextStyle(
                    color: AppColors.textMedium,
                    fontSize: 13,
                    fontStyle: FontStyle.italic),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (_previewPdfBytes == null) {
      return Center(
        child: ElevatedButton.icon(
          onPressed: _goToPreview,
          icon: const Icon(Icons.refresh),
          label: const Text('Générer l\'aperçu'),
        ),
      );
    }
    return _buildBookPreview();
  }


  // ── Étapes ─────────────────────────────────────────────────────────────────

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

  // ── Step 1: Format selection ───────────────────────────────────────────────

  /// Résout les photos de chaque souvenir (R2 signé + Firebase) pour le
  /// sélecteur de couverture. Une fois prêt, on choisit une couverture par
  /// défaut si l'utilisateur n'en a pas déjà une.
  Future<void> _resolvePhotos(List<MemoryModel> memories) async {
    for (final m in memories) {
      try {
        if (m.mediaKeys.isNotEmpty) {
          // key→url (photo-play) plutôt que resolvePhotoUrls : on a besoin de
          // la clé pour l'historique, pas juste de l'URL d'affichage.
          final keyToUrl = await PhotoService.signedUrlsForMemory(m.id);
          if (keyToUrl.isNotEmpty) {
            _photoUrlsByMemory[m.id] = keyToUrl.values.toList();
            for (final e in keyToUrl.entries) {
              _keyByUrl[e.value] = e.key;
            }
          }
        } else if (m.mediaUrls.isNotEmpty) {
          _photoUrlsByMemory[m.id] = m.mediaUrls; // Firebase, permanent
        } else if (m.photoUrl != null && m.photoUrl!.isNotEmpty) {
          _photoUrlsByMemory[m.id] = [m.photoUrl!];
        }
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
    return PdfPreviewViewer(
      pdfBytes: _previewPdfBytes!,
      pageCount: _previewPageCount,
      photoCount: _previewPhotoCount,
      pagesSoft: _printedPagesFor('soft'),
      pagesHard: _printedPagesFor('hard'),
      priceSoft: _priceLabel('soft'),
      priceHard: _priceLabel('hard'),
      exceedsLimit: _exceedsPageLimit,
      onDownload: _downloadPreviewPdf,
      onChooseFormat: () => _goTo(BookStep.format),
      slots: _slots,
      commentCount: _photoTexts.length,
      onPhotoTap: _onPhotoTap,
      updating: _updatingPreview,
      removedCount: _excludedPhotoIds.length,
      onRestoreRemoved: () {
        setState(() => _excludedPhotoIds.clear());
        _refreshPreview();
      },
    );
  }

  // ── Éditeur d'aperçu ──────────────────────────────────────────────────────

  /// Photo touchée dans l'aperçu (ou dans la grille des commentaires) :
  /// texte, retrait ou mise en grand, puis régénération du PDF (en
  /// arrière-plan, l'ancien reste affiché).
  Future<void> _onPhotoTap(BookPhotoSlot slot) async {
    final id = slot.rawId;
    if (id == null) {
      _showSnack('Cette photo ne peut pas être modifiée depuis l\'aperçu.');
      return;
    }
    final featured = _featuredPhotoIds?.contains(id) ?? false;
    final res = await PhotoEditScreen.open(context,
        slot: slot,
        defaultColor: _lastTextColor,
        defaultFont: _lastTextFont,
        defaultScale: _lastTextScale,
        initial: _photoTexts[id],
        featured: featured);
    if (res == null || !mounted) return;
    switch (res) {
      case PhotoTextSaved(:final text):
        setState(() {
          if (text == null) {
            _photoTexts.remove(id);
          } else {
            _photoTexts[id] = text;
            _lastTextColor = text.color;
            _lastTextFont = text.font;
            _lastTextScale = text.scale;
          }
        });
        _showSnack(text == null
            ? 'Commentaire retiré.'
            : 'Commentaire enregistré dans ton brouillon ✓');
      case PhotoRemoved():
        setState(() => _excludedPhotoIds.add(id));
      case PhotoFeaturedToggled():
        // Propre à CE livre (22.10.26) : le souvenir n'est pas touché.
        _toggleFeaturedPhoto(id);
    }
    // Sur l'aperçu : mis à jour sous les yeux. À l'étape Commentaires : il
    // se prépare en arrière-plan.
    if (_step == BookStep.preview) {
      await _refreshPreview();
    } else {
      _prefetch();
    }
  }

  /// Régénère l'aperçu après une retouche, sans l'écran de progression : le
  /// PDF précédent reste affiché jusqu'au nouveau. Seule la DERNIÈRE retouche
  /// demandée s'affiche si plusieurs se chevauchent.
  Future<void> _refreshPreview() async {
    final seq = ++_previewSeq;
    final sig = _pdfSignature();
    setState(() => _updatingPreview = true);
    try {
      final gen = await _buildPreviewPdf();
      if (!mounted || seq != _previewSeq) return;
      setState(() {
        _applyPreviewResult(gen, sig);
        _updatingPreview = false;
      });
    } catch (e) {
      if (!mounted || seq != _previewSeq) return;
      setState(() => _updatingPreview = false);
      _showSnack('Mise à jour de l\'aperçu impossible : $e');
    }
  }

  // ── Brouillon ─────────────────────────────────────────────────────────────

  void _scheduleDraftSave() {
    // Pas avant la fin du chargement (baseline posée), ni hors brouillon.
    if (!_draftsEnabled || _lastSavedSig == null) return;
    _draftSaveTimer?.cancel();
    _draftSaveTimer =
        Timer(const Duration(milliseconds: 800), _saveDraftIfChanged);
  }

  String? _photoIdOf(String? url) =>
      url == null ? null : (_keyByUrl[url] ?? url);

  /// Empreinte de tout ce que le brouillon garde — deux états identiques
  /// donnent la même chaîne (ensembles triés).
  String _draftSignature() => jsonEncode({
        ..._contentMap(),
        'pages': _previewPageCount,
      });

  /// Ce que l'utilisateur a composé (sans le nombre de pages, qui est un
  /// RÉSULTAT de la génération) — base des deux empreintes.
  Map<String, Object?> _contentMap() => {
        'sel': (_selectedMemoryIds.toList()..sort()),
        'title': _titleCtrl.text.trim(),
        'dedication': _dedicationCtrl.text.trim(),
        'cover': _photoIdOf(_coverPhotoUrl),
        'back': _photoIdOf(_backCoverPhotoUrl),
        'exCover': _excludeCoverPhotoFromBook,
        'growth': (_excludedGrowthChildIds.toList()..sort()),
        'ex': (_excludedPhotoIds.toList()..sort()),
        'feat': ((_featuredPhotoIds ?? const <String>{}).toList()..sort()),
        'texts': [
          for (final k in (_photoTexts.keys.toList()..sort()))
            _photoTexts[k]!.toMap(k),
        ],
      };

  /// Écrit le brouillon s'il a changé depuis la dernière écriture — et le
  /// crée au premier vrai changement. Silencieux : un échec ne gêne jamais
  /// l'édition, la prochaine modification réessaiera. Les photos de
  /// couverture sont stockées par CLÉ R2 quand on la connaît — une URL
  /// signée expire après 1 h.
  Future<void> _saveDraftIfChanged() async {
    _draftSaveTimer?.cancel();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || !_draftsEnabled || _lastSavedSig == null) return;
    final sig = _draftSignature();
    if (sig == _lastSavedSig) return;
    final id = _draftId ??= BookDraftService.newId();
    final idOf = _photoIdOf;
    try {
      await BookDraftService.save(BookDraft(
        id: id,
        userId: uid,
        tagId: _tagId,
        requestedIds: _requestedIds,
        selectedMemoryIds: _selectedMemoryIds.toList(),
        title: _titleCtrl.text.trim(),
        dedication: _dedicationCtrl.text.trim(),
        coverPhotoId: idOf(_coverPhotoUrl),
        backCoverPhotoId: idOf(_backCoverPhotoUrl),
        excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
        excludedGrowthChildIds: _excludedGrowthChildIds.toList(),
        excludedPhotoIds: _excludedPhotoIds.toList(),
        featuredPhotoIds: _featuredPhotoIds?.toList(),
        photoTexts: Map.of(_photoTexts),
        pageCount: _previewPageCount,
        updatedAt: DateTime.now(),
      ));
      _lastSavedSig = sig;
    } catch (_) {}
  }

  /// Supprime le brouillon (depuis l'écran du livre) et quitte : rester ici
  /// le recréerait à la prochaine modification.
  Future<void> _deleteDraft() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Supprimer ce brouillon ?'),
        content: const Text(
            'Les textes et retouches de ce livre seront perdus. Les souvenirs '
            'et leurs photos ne sont pas touchés.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || _draftId == null) return;
    _draftSaveTimer?.cancel();
    _lastSavedSig = null; // plus aucune sauvegarde depuis cet écran
    try {
      await BookDraftService.delete(_draftId!);
    } catch (e) {
      _showSnack('Suppression impossible : $e');
      return;
    }
    if (!mounted) return;
    context.go('/home');
  }

  /// Réapplique un brouillon repris, sur l'écran de départ (« Générer le
  /// livre ») : tout est restauré, l'aperçu s'ouvre quand on le demande.
  Future<void> _applyDraft(BookDraft draft, List<MemoryModel> loaded,
      Future<void> resolving) async {
    final loadedIds = loaded.map((m) => m.id).toSet();
    final selected =
        draft.selectedMemoryIds.where(loadedIds.contains).toSet();
    setState(() {
      if (selected.isNotEmpty) _selectedMemoryIds = selected;
      _excludeCoverPhotoFromBook = draft.excludeCoverPhotoFromBook;
      _excludedGrowthChildIds
        ..clear()
        ..addAll(draft.excludedGrowthChildIds);
      _excludedPhotoIds
        ..clear()
        ..addAll(draft.excludedPhotoIds);
      if (draft.featuredPhotoIds != null) {
        _featuredPhotoIds = {...draft.featuredPhotoIds!};
      }
      _photoTexts
        ..clear()
        ..addAll(draft.photoTexts);
      if (draft.photoTexts.isNotEmpty) {
        final last = draft.photoTexts.values.last;
        _lastTextColor = last.color;
        _lastTextFont = last.font;
        _lastTextScale = last.scale;
      }
      _resumedDraft = draft;
    });
    if (draft.title.isNotEmpty) _titleCtrl.text = draft.title;
    if (draft.dedication.isNotEmpty) {
      _dedicationCtrl.text = draft.dedication;
      _dedicationOn = true;
    }
    // Couverture : clé R2 → URL signée, connue une fois les photos résolues.
    await resolving;
    if (!mounted) return;
    final urlOf = _urlOfPhotoId;
    setState(() {
      final cover = urlOf(draft.coverPhotoId);
      if (cover != null) _coverPhotoUrl = cover;
      _backCoverPhotoUrl = urlOf(draft.backCoverPhotoId);
      _previewPageCount = draft.pageCount;
    });
    // État restauré = état sauvegardé : rien à réécrire tant qu'on n'y
    // touche pas.
    _lastSavedSig = _draftSignature();
  }

  /// Bandeau « brouillon repris » en haut de l'écran de départ.
  Widget _resumedDraftBanner() {
    final d = _resumedDraft!;
    final parts = [
      if (d.photoTexts.isNotEmpty)
        '${d.photoTexts.length} texte${d.photoTexts.length > 1 ? 's' : ''}',
      if (d.excludedPhotoIds.isNotEmpty)
        '${d.excludedPhotoIds.length} photo${d.excludedPhotoIds.length > 1 ? 's' : ''} retirée${d.excludedPhotoIds.length > 1 ? 's' : ''}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.sageDark, width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.history_edu, color: AppColors.sageDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              parts.isEmpty
                  ? 'Brouillon repris — tout est sauvegardé automatiquement.'
                  : 'Brouillon repris : ${parts.join(', ')}. Tout est sauvegardé automatiquement.',
              style: const TextStyle(color: AppColors.textDark, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // Contrôle du nombre de pages avant impression : montre, AVANT la commande,
  // si des pages blanches seront ajoutées ou si le livre dépasse la limite de
  // l'imprimeur (auquel cas la commande est bloquée plutôt que d'envoyer un
  // PDF dont le nombre de pages réel ne correspondrait plus à celui annoncé).
  Widget _buildPageCountNotice() {
    if (_exceedsPageLimit) {
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
              'maximum 300 pages chez notre imprimeur. Retire des souvenirs '
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
    if (_blankPagesAdded > 0) {
      // Juste informatif : le bourrage en pages blanches résout déjà le
      // minimum imprimeur tout seul, rien à décider ici. Le bouton "Ajouter
      // des souvenirs à la place" qui vivait dans ce bloc forçait un choix
      // sur un problème déjà réglé — retiré (retour de David le 22.09.26,
      // "trop compliqué quand il manque des pages"). Ajouter des souvenirs
      // reste possible via le bloc "Modifier" en haut de l'écran, pas besoin
      // d'un second chemin ici.
      final plural = _blankPagesAdded > 1 ? 's' : '';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 16, color: AppColors.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Ton livre fait $_pages pages. Notre imprimeur exige un '
                'minimum de ${BookPricing.printablePages(_coverType, 0)} '
                'pages (nombre pair) : $_blankPagesAdded '
                'page$plural blanche$plural seront ajoutées à la fin.',
                style: const TextStyle(fontSize: 12, color: AppColors.textMedium),
              ),
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
            opacity: _exceedsPageLimit ? 0.45 : 1.0,
            child: FormatCard(
              emoji: '📗',
              title: 'Couverture souple',
              subtitle: 'Livre 21×28 cm · 5–7 jours',
              price: _priceLabel('soft'),
              priceSub: '${_printedPagesFor('soft')} pages',
              priceColor: AppColors.amber,
              selected: _coverType == 'soft',
              onTap: _exceedsPageLimit
                  ? () => _showSnack(
                      'Retire des souvenirs pour repasser sous 200 pages avant de choisir ce format.')
                  : () => setState(() => _coverType = 'soft'),
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: _exceedsPageLimit ? 0.45 : 1.0,
            child: FormatCard(
              emoji: '📕',
              title: 'Couverture rigide',
              subtitle: 'Livre 21×28 cm · couverture cartonnée',
              price: _priceLabel('hard'),
              priceSub: '${_printedPagesFor('hard')} pages',
              priceColor: AppColors.amber,
              selected: _coverType == 'hard',
              onTap: _exceedsPageLimit
                  ? () => _showSnack(
                      'Retire des souvenirs pour repasser sous 200 pages avant de choisir ce format.')
                  : () => setState(() => _coverType = 'hard'),
            ),
          ),
          const SizedBox(height: 12),
          Opacity(
            opacity: (_exceedsPageLimit || _exceedsLayflatLimit) ? 0.45 : 1.0,
            child: FormatCard(
              emoji: '📘',
              title: 'Layflat',
              subtitle: 'Livre A4 · pages qui s\'ouvrent bien à plat',
              price: _priceLabel('layflat'),
              priceSub: '${_printedPagesFor('layflat')} pages',
              priceColor: AppColors.amber,
              selected: _coverType == 'layflat',
              onTap: _exceedsPageLimit
                  ? () => _showSnack(
                      'Retire des souvenirs pour repasser sous 200 pages avant de choisir ce format.')
                  : _exceedsLayflatLimit
                      ? () => _showSnack(
                          'Le layflat est limité à ${BookPricing.maxPages('layflat')} pages — retire des souvenirs ou choisis souple/rigide.')
                      : () => setState(() => _coverType = 'layflat'),
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
            onPressed: (_exceedsPageLimit ||
                    (_coverType == 'layflat' && _exceedsLayflatLimit))
                ? null
                : () => _goTo(BookStep.order),
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

  /// « C'est un cadeau » : le colis part directement chez le destinataire.
  /// Cocher vide l'adresse pré-remplie (la sienne) ; décocher la remet.
  Widget _buildGiftToggle() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🎁', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('C\'est un cadeau',
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
              ),
              Switch(
                value: _isGift,
                onChanged: _ordering
                    ? null
                    : (v) {
                        setState(() => _isGift = v);
                        if (v) {
                          for (final c in [
                            _firstNameCtrl,
                            _lastNameCtrl,
                            _streetCtrl,
                            _cityCtrl,
                            _npaCtrl,
                          ]) {
                            c.clear();
                          }
                        } else {
                          _loadLastAddress();
                        }
                      },
              ),
            ],
          ),
          if (_isGift)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 8),
              child: Text(
                _dedicationCtrl.text.trim().isEmpty
                    ? 'Le livre part directement chez la personne. Astuce : '
                        'reviens à l\'étape « Titre & dédicace » pour ajouter '
                        'un mot en première page.'
                    : 'Le livre part directement chez la personne, avec ton '
                        'mot en première page.',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textMedium, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOrderStep() {
    // Le panier (autres livres + bouton "en ajouter un") n'a de sens que pour
    // la commande racine — ni en queueMode (un livre en file d'attente ne
    // porte pas lui-même d'autres livres), ni en édition (renvoi d'un livre
    // déjà commandé, un seul article).
    final showCart = !widget.queueMode && widget.editOrderId == null;
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
                OrderRow(label: 'Carnet', value: _notebook!.title),
                const Divider(height: 24, color: AppColors.border),
                OrderRow(
                    label: 'Souvenirs',
                    value: '${_selectedMemories.length} souvenirs'),
                const Divider(height: 24, color: AppColors.border),
                OrderRow(
                    label: 'Format',
                    value: _coverType == 'hard'
                        ? 'Couverture rigide'
                        : 'Couverture souple'),
                const Divider(height: 24, color: AppColors.border),
                OrderRow(label: 'Pages', value: '$_printedPages pages'),
                const Divider(height: 24, color: AppColors.border),
                OrderRow(
                  label: 'Prix',
                  value: _priceLabel(_coverType),
                  bold: true,
                  valueColor: AppColors.amber,
                ),
              ],
            ),
          ),
          if (showCart) ...[
            for (final book in _extraBooks)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _bookSummaryTile(book),
              ),
            const SizedBox(height: 10),
            Center(
              child: TextButton.icon(
                onPressed: _ordering ? null : _addAnotherBook,
                icon: const Icon(Icons.add_circle_outline,
                    size: 18, color: AppColors.sageDark),
                label: const Text('Ajouter un autre livre à cette commande',
                    style: TextStyle(color: AppColors.sageDark, fontSize: 13)),
              ),
            ),
            if (_extraBooks.isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Total · 1 seule livraison',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDark)),
                    Text(BookPricing.format(_totalPrice),
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: AppColors.textDark)),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 28),

          if (widget.queueMode)
            if (_ordering) ...[
              const LinearProgressIndicator(
                backgroundColor: Color(0xFFEEEBE3),
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.sage),
              ),
              const SizedBox(height: 10),
              Text(_orderMessage,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMedium, fontSize: 13, fontStyle: FontStyle.italic)),
            ] else
              ElevatedButton(
                onPressed: _placeOrder,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.amber, foregroundColor: AppColors.onAccent),
                child: const Text('Ajouter à la commande'),
              )
          else
            // Formulaire adresse
            Form(
                key: _addressKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.editOrderId == null) ...[
                      _buildGiftToggle(),
                      const SizedBox(height: 16),
                    ],
                    Text(
                        _isGift
                            ? 'Adresse du destinataire'
                            : 'Adresse de livraison',
                        style: const TextStyle(
                            fontFamily: 'PlayfairDisplay',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textDark)),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: AddressField(_firstNameCtrl, 'Prénom',
                              required: true)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: AddressField(_lastNameCtrl, 'Nom',
                              required: true)),
                    ]),
                    const SizedBox(height: 10),
                    AddressField(_streetCtrl, 'Rue et numéro', required: true),
                    const SizedBox(height: 10),
                    Row(children: [
                      SizedBox(
                          width: 100,
                          child: AddressField(_npaCtrl, 'NPA',
                              required: true,
                              keyboardType: TextInputType.number)),
                      const SizedBox(width: 10),
                      Expanded(
                          child:
                              AddressField(_cityCtrl, 'Ville', required: true)),
                    ]),
                    const SizedBox(height: 10),
                    AddressField(_countryCtrl, 'Pays', required: true),
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
                          foregroundColor: AppColors.onAccent,
                        ),
                        child: Text(_orderButtonLabel),
                      ),
                  ],
                )),

          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: () => _goTo(BookStep.format),
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

  Widget _bookSummaryTile(_QueuedBook book) {
    final coverLabel = book.coverType == 'hard'
        ? 'Rigide'
        : book.coverType == 'layflat'
            ? 'Layflat'
            : 'Souple';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sageTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined, color: AppColors.sageDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${book.bookTitle} · $coverLabel · ${book.pageCount} pages',
              style: const TextStyle(fontSize: 13.5, color: AppColors.textDark),
            ),
          ),
          Text(BookPricing.format(book.price),
              style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textDark)),
          GestureDetector(
            onTap: () => setState(() => _extraBooks.remove(book)),
            child: const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.close, size: 18, color: AppColors.textMedium),
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
    final growthBefore = Set<String>.from(_excludedGrowthChildIds);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MemorySelectionSheet(
        memories: _memories,
        selectedIds: _selectedMemoryIds,
        growthGroups: _growthGroups,
        excludedGrowthChildIds: _excludedGrowthChildIds,
        onGrowthChildrenChanged: (excluded) => setState(() {
          _excludedGrowthChildIds
            ..clear()
            ..addAll(excluded);
        }),
        onChanged: (ids) => setState(() {
          _selectedMemoryIds = ids;
          // Reset cover photo(s) if they no longer belong to selected memories
          if (_coverPhotoUrl != null || _backCoverPhotoUrl != null) {
            final allUrls = _allPhotoUrls;
            if (!allUrls.contains(_coverPhotoUrl)) _coverPhotoUrl = null;
            if (!allUrls.contains(_backCoverPhotoUrl)) _backCoverPhotoUrl = null;
          }
        }),
        onMemoryUpdated: _applyMemoryLayoutUpdate,
      ),
    );
    final growthChanged = growthBefore.length != _excludedGrowthChildIds.length ||
        !growthBefore.containsAll(_excludedGrowthChildIds);
    if (_memoriesChangedInSheet || growthChanged) {
      _memoriesChangedInSheet = false;
    }
    // Sur l'aperçu : on le met à jour sous les yeux. Ailleurs : on le
    // prépare en arrière-plan pour l'étape Aperçu.
    if (_step == BookStep.preview) {
      if (_pdfSignature() != _previewSig) await _refreshPreview();
    } else {
      _prefetch();
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
      if (i == -1) return;
      // Photos en grand changées dans la feuille du souvenir : le livre
      // reprend ce nouveau choix pour ce souvenir.
      final before = _memories[i].bookFeaturedMedia;
      final f = _featuredPhotoIds;
      if (f != null &&
          (before.length != updated.bookFeaturedMedia.length ||
              !before.every(updated.bookFeaturedMedia.contains))) {
        f
          ..removeAll(rawMediaIdsOf(updated))
          ..removeAll(before)
          ..addAll(updated.bookFeaturedMedia);
      }
      _memories[i] = updated;
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

