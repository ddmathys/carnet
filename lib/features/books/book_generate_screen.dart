import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/config/app_config.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/services/backend_client.dart';
import '../../core/services/book_pdf_service.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/book_pricing.dart';
import '../../core/services/pdf_service.dart';
import 'pdf_viewer_screen.dart';
import 'pdf_preview_viewer.dart';
import 'memory_selection_sheet.dart';
import 'book_generate_widgets.dart';
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
  // Tous les tags visibles (miens + partagés) — sert uniquement à retrouver
  // les tags enfant pour grouper les mesures taille/poids par enfant, voir
  // _growthGroups. Chargé une fois avec le reste (_loadData).
  List<TagModel> _allTags = [];
  String? _loadError; // message si le chargement initial échoue

  // ── State ──────────────────────────────────────────────────────────────────
  int _step = 0; // 0=cover+create, 1=format, 2=order
  bool get _isAdmin =>
      FirebaseAuth.instance.currentUser?.email == AppConfig.adminEmail;
  bool _showPreview = false;
  String _coverType = 'soft'; // 'soft', 'hard' ou 'layflat'
  // Chapitre croissance (courbe OMS) : un par enfant ayant ≥2 mesures dans
  // la sélection (voir _growthGroups), coché par défaut, décochable
  // individuellement — id de tag enfant présent ici = exclu du livre.
  final Set<String> _excludedGrowthChildIds = {};
  bool _generating = false;
  double _progress = 0.0;
  int _msgIndex = 0;
  Timer? _progressTimer;
  Map<String, String> _locationComments = {};
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

  // Aperçu WYSIWYG : on génère les MÊMES octets PDF que le téléchargement et on
  // affiche chaque page rastérisée → aucune différence possible avec le rendu
  // final / l'impression.
  Uint8List? _previewPdfBytes;
  int _previewPageCount = 0;
  int _previewPhotoCount = 0;

  late final TextEditingController _titleCtrl;

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

  // Applique la suggestion en pré-remplissant bookFeaturedMedia du souvenir
  // choisi — seulement si ce souvenir n'a ENCORE aucune photo "en grand"
  // définie, pour ne jamais écraser un réglage déjà fait par l'utilisateur
  // (ici ou dans un livre précédent). Best-effort, silencieux en cas d'échec.
  Future<void> _applyMilestoneSuggestions() async {
    for (final s in _milestoneSuggestions) {
      if (s.memory.bookFeaturedMedia.isNotEmpty) continue;
      try {
        final updated = s.memory.copyWith(bookFeaturedMedia: [s.rawId]);
        await FirebaseFirestore.instance
            .collection('memories')
            .doc(s.memory.id)
            .update({'bookFeaturedMedia': [s.rawId]});
        if (mounted) _applyMemoryLayoutUpdate(updated);
      } catch (_) {
        // Pas grave : l'utilisateur peut toujours choisir manuellement via
        // le réglage de mise en page du souvenir.
      }
    }
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
      // Tags enfant, pour grouper les mesures taille/poids par enfant
      // (chapitre croissance — voir _growthGroups). Best-effort : un échec
      // ici prive juste le livre du chapitre croissance, rien de bloquant.
      final tags = await TagService.visibleTags().timeout(t, onTimeout: () => const []);
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
        _allTags = tags;
        _selectedMemoryIds = allMemories.map((m) => m.id).toSet();
        _coverPhotoUrl = defaultCover;
        _loadError = null;
        // Commande depuis « Mes livres », ou renvoi admin après erreur : on
        // saute directement aux options d'achat.
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
      // Photos "1 an"/"2 ans" : suggestion auto (silencieuse, non bloquante).
      _applyMilestoneSuggestions();
      // Admin : pré-remplit l'adresse de livraison (étape 2) avec celle de la
      // dernière commande, pour ne plus jamais avoir à la ressaisir.
      if (_isAdmin) _loadLastAddress();
      // Renvoi après erreur : pré-remplit adresse/titre/couverture avec ceux
      // de la commande à corriger (inchangés, seul le PDF est régénéré).
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
      });
      _titleCtrl.text = order.bookTitle;
    } catch (_) {
      // Pas grave : les champs restent à saisir à la main.
    }
  }

  // ── Generation ─────────────────────────────────────────────────────────────

  // Génère le PDF d'aperçu — mêmes octets que le téléchargement (sans bourrage
  // de pages blanches), pour un aperçu strictement identique au rendu final.
  Future<({Uint8List bytes, int pageCount, int photoCount})>
      _buildPreviewPdf() async {
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
      locationComments: _locationComments,
      coverPhotoUrl: _coverPhotoUrl,
      excludeCoverPhotoFromBook: _excludeCoverPhotoFromBook,
      backCoverPhotoUrl: _backCoverPhotoUrl,
      customTitle:
          _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null,
      backendUrl: AppConfig.backendUrl,
      coverVideosQrUrl: coverQrUrl,
      growthChildren: _includedGrowthChildren,
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
      // Combien de photos on s'attend à voir dans le livre, calculé AVANT
      // toute tentative de téléchargement — sert de référence pour détecter
      // un échec de téléchargement massif (voir garde-fou ci-dessous).
      final expectedPhotos = _allPhotoUrls.length;
      final gen = await _buildPreviewPdf();
      if (!mounted) return;
      _progressTimer?.cancel();
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
        _previewPdfBytes = gen.bytes;
        _previewPageCount = gen.pageCount;
        _previewPhotoCount = gen.photoCount;
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
        coverPhotoUrl: _coverPhotoUrl,
      );
    } catch (_) {
      // Silencieux — le partage a déjà eu lieu
    }
  }

  Future<void> _placeOrder() async {
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
        backCoverPhotoUrl: _backCoverPhotoUrl,
        customTitle: customTitle,
        backendUrl: AppConfig.backendUrl,
        coverVideosQrUrl: await _coverVideosQrUrl(),
        padForPrint: true, // pages valides imprimeur (pair, ≥24)
        coverType: _coverType, // largeur exacte de couverture wraparound
        growthChildren: _includedGrowthChildren,
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
        format: 'printed',
        coverType: _coverType,
        pdfUrl: pdfUrl,
        storagePath: uploaded.key,
        memoriesCount: _selectedMemories.length,
        orderId: orderId,
        coverPhotoUrl: _coverPhotoUrl,
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
            child: BookCoverPreview(
              notebook: _notebook!,
              coverColor: coverColor,
              coverPhotoUrl: _coverPhotoUrl,
              yearRange: _yearRange,
              highlights: _coverHighlights,
              hasVideos: _videoMemories.isNotEmpty,
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
                      _memorySelectionSummary,
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
          if (_milestoneSuggestions.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final s in _milestoneSuggestions)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: _photoUrlsByMemory[s.memory.id]?.isNotEmpty ==
                                true
                            ? CachedNetworkImage(
                                imageUrl: _photoUrlsByMemory[s.memory.id]!.first,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    Container(color: AppColors.softGray),
                              )
                            : Container(color: AppColors.softGray),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Photo « ${s.label} » mise en avant',
                          style: const TextStyle(
                              color: AppColors.textDark, fontSize: 13)),
                    ),
                    TextButton(
                      onPressed: () async {
                        final updated = await showModalBottomSheet<MemoryModel>(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => MemoryLayoutSheet(memory: s.memory),
                        );
                        if (updated != null) _applyMemoryLayoutUpdate(updated);
                      },
                      child: const Text('Changer'),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 14),

          // Action principale : génère l'aperçu du livre (d'où le nom).
          if (_generating) ...[
            ProgressBar(progress: _progress),
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
        _photoStrip(
          urls: allUrls,
          selectedUrl: _coverPhotoUrl,
          onTapUrl: (url) => setState(() {
            _coverPhotoUrl = _coverPhotoUrl == url ? null : url;
          }),
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

        // ── Photo de dos (4ᵉ de couverture, optionnelle) ──────────────────
        // Sans choix ici, le dos reste un aplat de la couleur du livre —
        // jamais blanc, mais pas obligé de porter une photo non plus.
        const SizedBox(height: 18),
        Row(
          children: [
            const Icon(Icons.crop_portrait_outlined,
                size: 16, color: AppColors.textMedium),
            const SizedBox(width: 6),
            const Text(
              'Photo au dos du livre (facultatif)',
              style: TextStyle(
                  color: AppColors.textMedium,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _photoStrip(
          urls: allUrls,
          selectedUrl: _backCoverPhotoUrl,
          onTapUrl: (url) => setState(() {
            _backCoverPhotoUrl = _backCoverPhotoUrl == url ? null : url;
          }),
        ),
        if (_backCoverPhotoUrl != null) ...[
          const SizedBox(height: 6),
          Text(
            'Photo de dos sélectionnée · Tape à nouveau pour annuler',
            style: TextStyle(
                color: AppColors.sage.withOpacity(0.8),
                fontSize: 11,
                fontStyle: FontStyle.italic),
          ),
        ],
      ],
    );
  }

  /// Bandeau horizontal de vignettes photo, avec coche sur celle sélectionnée
  /// — partagé entre le sélecteur de couverture et celui du dos.
  Widget _photoStrip({
    required List<String> urls,
    required String? selectedUrl,
    required ValueChanged<String> onTapUrl,
  }) {
    return SizedBox(
      height: 78,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        itemBuilder: (_, i) {
          final url = urls[i];
          final isSelected = selectedUrl == url;
          return GestureDetector(
            onTap: () => onTapUrl(url),
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
                            child: CircularProgressIndicator(strokeWidth: 2)),
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
                    'minimum de ${BookPricing.printablePages(_coverType, 0)} '
                    'pages (nombre pair) : $_blankPagesAdded '
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

