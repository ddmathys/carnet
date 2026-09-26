import 'dart:async';
import 'dart:math' show Random;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/models/generated_book_model.dart';
import '../../core/models/memory_activity_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/memory_activity_service.dart';
import '../books/pdf_viewer_screen.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/puzzle_pricing.dart';
import '../../core/services/tag_service.dart';
import '../memories/widgets/memory_polaroid.dart';
import '../memories/widgets/delete_memory.dart';
import '../shared/upload_status_banner.dart';
import '../tags/people_strip.dart';
import '../tags/shared_tags_sheet.dart';

/// Dashboard : une photo « héro » tirée au sort en haut (voir
/// _maybePickHero), les personnes, les derniers souvenirs, et le module
/// « Souvenirs imprimés » (livres/tirages/puzzles). Importer un média (le
/// geste principal) reste à portée via le bouton flottant du Scaffold.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  QuotaStatus? _quota;
  QuotaStatus? _videoQuota;
  QuotaStatus? _audioQuota;

  List<TagModel> _myTags = [];
  List<MemoryModel> _recentMemories = [];

  // Photo « héro » en haut du dashboard : tirée au sort une seule fois par
  // ouverture d'app (pas à chaque souvenir ajouté, ni à chaque rebuild —
  // sinon elle changerait sous les yeux) parmi les derniers souvenirs
  // photo — pour que le dashboard ne montre pas toujours la même image à
  // chaque connexion (retour de David 22.09.26 : "une autre image en mode
  // variable"). `_heroPicked` reste faux tant qu'aucun souvenir avec photo
  // n'est encore arrivé (ex. juste après la connexion) : le prochain lot
  // Firestore retentera automatiquement.
  MemoryModel? _heroMemory;
  bool _heroPicked = false;

  StreamSubscription? _myTagsSub;
  StreamSubscription? _mineSub;
  StreamSubscription? _sharedMemSub;

  // Les souvenirs arrivent par deux flux (les miens, ceux qu'on m'a partagés) :
  // chaque flux garde SON lot, et on les fusionne à l'affichage. Garder un seul
  // sac commun faisait qu'un souvenir supprimé restait à l'écran — le flux ne
  // sait dire « il n'est plus là » qu'en cessant de l'énumérer.
  Map<String, MemoryModel> _mineById = {};
  Map<String, MemoryModel> _sharedById = {};

  Map<String, MemoryModel> get _memoriesById => {..._sharedById, ..._mineById};

  @override
  void initState() {
    super.initState();
    _setupStreams();
    _loadQuota();
  }

  @override
  void dispose() {
    _myTagsSub?.cancel();
    _mineSub?.cancel();
    _sharedMemSub?.cancel();
    super.dispose();
  }

  void _setupStreams() {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    _myTagsSub = TagService.streamMine().listen((tags) {
      if (mounted) setState(() => _myTags = tags);
    });

    final memories = FirebaseFirestore.instance.collection('memories');
    _mineSub = memories.where('userId', isEqualTo: uid).snapshots().listen(
        (snap) => _onMemories(snap, mine: true));
    _sharedMemSub = memories
        .where('sharedWith', arrayContains: uid)
        .snapshots()
        .listen((snap) => _onMemories(snap, mine: false));
  }

  void _onMemories(QuerySnapshot<Map<String, dynamic>> snap,
      {required bool mine}) {
    final lot = {
      for (final d in snap.docs) d.id: MemoryModel.fromFirestore(d),
    };
    if (mine) {
      _mineById = lot;
    } else {
      _sharedById = lot;
    }
    if (mounted) {
      setState(() {
        _refreshRecentMemories();
        _maybePickHero();
      });
    }
  }

  bool _hasDisplayPhoto(MemoryModel m) =>
      m.mediaKeys.isNotEmpty ||
      m.mediaUrls.isNotEmpty ||
      (m.photoUrl?.isNotEmpty ?? false);

  /// Tire une photo au hasard parmi les 12 souvenirs-photo les plus récents
  /// — une seule fois par ouverture d'écran (voir _heroPicked).
  void _maybePickHero() {
    if (_heroPicked) return;
    final pool = _memoriesById.values
        .where((m) => m.type != 'taille_poids')
        .where(_hasDisplayPhoto)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (pool.isEmpty) return;
    final candidates = pool.take(12).toList();
    _heroMemory = candidates[Random().nextInt(candidates.length)];
    _heroPicked = true;
  }

  /// Les 3 derniers souvenirs ajoutés, en rangée horizontale — pas de filtre
  /// ici, c'est le raccourci "vient d'arriver" du dashboard (le filtre par
  /// tag complet vit sur `/memories`).
  ///
  /// Triés par DATE D'AJOUT (createdAt), pas par la date du souvenir : un
  /// souvenir tout juste importé (ex. une vieille photo d'enfance) doit
  /// apparaître en premier ici, même si sa date le placerait ailleurs dans
  /// le carnet chronologique (`/memories`, qui lui reste trié par `date`).
  void _refreshRecentMemories() {
    final all = _memoriesById.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _recentMemories = all.take(3).toList();
  }

  Future<void> _loadQuota() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final results = await Future.wait([
        QuotaService.checkQuota(uid),
        QuotaService.checkVideoQuota(uid),
        QuotaService.checkAudioQuota(uid),
      ]).timeout(const Duration(seconds: 20));
      if (mounted) {
        setState(() {
          _quota = results[0];
          _videoQuota = results[1];
          _audioQuota = results[2];
        });
      }
    } catch (_) {
      // Une lecture qui pend/échoue laissait le bloc quota chargeant à
      // l'infini, sans message — les widgets quota gèrent déjà une valeur
      // null comme "pas de barre affichée" plutôt qu'un spinner bloquant,
      // donc ne rien faire ici suffit à sortir proprement de l'état chargeant.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildBody(context),
      // Remplace l'ancien bandeau "Ajoute un souvenir" (ImportMediaCta),
      // toujours à portée de main sans occuper une section entière — refonte
      // dashboard du 22.09.26 (David : maquette "D", bouton flottant).
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/memory/new?import=1'),
        backgroundColor: AppColors.sageDark,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_a_photo_outlined),
        label: const Text('Souvenir',
            style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final hasMemories = _memoriesById.isNotEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _heroSection(context)),
        // La bande des personnes chevauche le bas de la photo héro (voir
        // Positioned bottom négatif dans _heroSection) : cet espace
        // compense pour que la section suivante ne remonte pas dessous.
        const SliverToBoxAdapter(child: SizedBox(height: 34)),

        const SliverToBoxAdapter(child: UploadStatusBanner()),
        const SliverToBoxAdapter(child: _ActivityBanner()),

        if (!hasMemories)
          const SliverToBoxAdapter(child: _EmptyState())
        else ...[
          _sectionHeader(
            'Souvenirs récents',
            'Tout voir',
            onAction: () => context.push('/memories'),
          ),
          SliverToBoxAdapter(child: _recentMemoriesGrid(context)),
        ],

        // Livres + tirages + puzzles, groupés sous UN seul module au lieu de
        // deux sections + un gros bandeau empilés — refonte dashboard du
        // 22.09.26 ("je trouve les sections mal réparties").
        SliverToBoxAdapter(child: _printedSection(context)),

        // Espace pour que le bouton flottant ne recouvre pas le bas du
        // contenu au scroll.
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  /// Photo « héro » plein cadre en haut du dashboard (voir _maybePickHero) :
  /// logo + accès rapides en surimpression, légende (salutation + le
  /// souvenir mis en avant) en bas, personnes en chevauchement sur le bord
  /// inférieur. Sans souvenir-photo disponible (nouveau compte, ou premiers
  /// souvenirs encore sans image) : dégradé de marque à la place, salutation
  /// seule — jamais d'espace vide ni d'erreur.
  Widget _heroSection(BuildContext context) {
    const fallbackGradient = BoxDecoration(
      gradient: LinearGradient(
        colors: [Color(0xFF6B4A32), Color(0xFF8A6242)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    );
    final hero = _heroMemory;

    return SizedBox(
      height: 300,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          if (hero != null)
            FutureBuilder<List<String>>(
              future: PhotoService.resolvePhotoUrls(hero),
              builder: (context, snap) {
                final urls = snap.data ?? const [];
                if (urls.isEmpty) return const DecoratedBox(decoration: fallbackGradient);
                return CachedNetworkImage(
                  imageUrl: urls.first,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => const DecoratedBox(decoration: fallbackGradient),
                  errorWidget: (_, __, ___) => const DecoratedBox(decoration: fallbackGradient),
                );
              },
            )
          else
            const DecoratedBox(decoration: fallbackGradient),

          // Voile : lisible en haut (icônes + légende, maintenant regroupées
          // là — voir plus bas) ; un peu de voile en bas aussi pour que les
          // pastilles restent nettes quelle que soit la photo.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.6),
                  Colors.black.withOpacity(0.05),
                  Colors.black.withOpacity(0.05),
                  Colors.black.withOpacity(0.55),
                ],
                stops: const [0, 0.42, 0.7, 1],
              ),
            ),
          ),

          // En-tête ET légende regroupés en haut à gauche (David 22.09.26 :
          // "les pastilles cachent la description" — la légende vivait en
          // bas, sous les pastilles qui chevauchent la photo. Les deux
          // blocs ne se disputent plus le même espace.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('carnet',
                            style: TextStyle(
                              fontFamily: 'Fraunces',
                              fontStyle: FontStyle.italic,
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              height: 1,
                            )),
                        const Text('.',
                            style: TextStyle(
                              fontFamily: 'Fraunces',
                              fontStyle: FontStyle.italic,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: AppColors.sageDark,
                              height: 1,
                            )),
                        const Spacer(),
                        _heroIconButton(Icons.map_outlined, 'Chronologie',
                            () => context.push('/chronology')),
                        const SizedBox(width: 8),
                        _heroIconButton(Icons.people_alt_outlined,
                            'Partagé avec moi', () => _showSharedTagsSheet(context)),
                        const SizedBox(width: 8),
                        _heroIconButton(Icons.folder_outlined, 'Mon espace',
                            () => _showMonEspace(context)),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: () => context.push('/profile'),
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: const BoxDecoration(
                                color: AppColors.sageDark, shape: BoxShape.circle),
                            child: Center(
                              child: Text(_initial,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(_greeting,
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3)),
                    if (hero != null) ...[
                      const SizedBox(height: 3),
                      Text(_heroTitle(hero),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                      Text(DateFormat('d MMMM', 'fr').format(hero.date),
                          style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                    ],
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: -30,
            child: const PeopleStrip(),
          ),
        ],
      ),
    );
  }

  // Même traitement que la pastille profil (fond plein AppColors.sageDark,
  // pas juste un voile blanc translucide) — David 22.09.26 : "les autres je
  // les vois pas bien" — le voile translucide se fondait dans les photos
  // claires, contrairement à la pastille profil déjà pleine couleur.
  Widget _heroIconButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        label: label,
        button: true,
        child: Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(
              color: AppColors.sageDark, shape: BoxShape.circle),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }

  String _heroTitle(MemoryModel m) {
    if ((m.title?.trim().isNotEmpty ?? false)) return m.title!.trim();
    final words = m.rawContent.trim().split(RegExp(r'\s+')).take(6).join(' ');
    return words.isNotEmpty ? words : 'Souvenir';
  }

  /// Les 3 derniers souvenirs ajoutés (gauche = le plus récent), en rangée
  /// scrollable — 2 cartes visibles à l'écran, la 3ᵉ à un tap-scroll (David
  /// 22.09.26 : 3 côte à côte dans une Row les rendait trop petites pour
  /// être lisibles ; le scroll horizontal laisse chaque carte respirer).
  Widget _recentMemoriesGrid(BuildContext context) {
    if (_recentMemories.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(22, 14, 22, 10),
        child: Text(
          'Aucun souvenir pour l\'instant.',
          style: TextStyle(color: AppColors.textMedium, fontSize: 13),
        ),
      );
    }
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
        itemCount: _recentMemories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) => SizedBox(
          width: 168,
          height: 168,
          child: MemoryPolaroid(
            memory: _recentMemories[i],
            cat: _safeCat(_recentMemories[i].type),
            tilt: 0,
            onTap: () => context.push('/memory/${_recentMemories[i].id}'),
            onDelete: () => _deleteMemory(_recentMemories[i]),
          ),
        ),
      ),
    );
  }

  /// Suppression définitive (souvenir + tous ses médias), après confirmation.
  Future<void> _deleteMemory(MemoryModel m) async {
    final deleted = await confirmAndDeleteMemory(context, m);
    if (!deleted || !mounted) return;
    setState(() {
      _mineById.remove(m.id);
      _sharedById.remove(m.id);
      _refreshRecentMemories();
    });
    _loadQuota(); // les quotas viennent de baisser
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Souvenir supprimé.')),
    );
  }

  /// « Souvenirs imprimés » : livres ET tirages/puzzles commandés, groupés
  /// sous UN seul titre + un bouton "+ Créer" (remplace les anciennes
  /// sections "Mes livres" / "Mes tirages" empilées + le gros bandeau
  /// "Créer un souvenir imprimé" tout en bas — refonte dashboard du
  /// 22.09.26, "les sections sont mal réparties"). Deux étagères
  /// horizontales distinctes sous ce même titre (livres, puis tirages —
  /// posters ET puzzles désormais réunis, `o.isPoster || o.isPuzzle` :
  /// avant cette refonte les puzzles n'apparaissaient nulle part sur le
  /// dashboard, oubliés lors de l'ajout du produit puzzle). Le bandeau
  /// « commande(s) en cours » couvre les trois types (déjà générique, basé
  /// sur le statut, pas le type de produit). N'affiche RIEN (pas même le
  /// titre) s'il n'y a ni livre, ni tirage/puzzle, ni commande en cours.
  Widget _printedSection(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return StreamBuilder<List<GeneratedBookModel>>(
      stream: BookHistoryService.streamForUser(),
      builder: (context, bookSnap) {
        final books = bookSnap.data ?? const <GeneratedBookModel>[];
        return StreamBuilder<List<OrderModel>>(
          stream: uid == null
              ? const Stream<List<OrderModel>>.empty()
              : OrderService.userOrdersStream(uid),
          builder: (context, orderSnap) {
            final orders = orderSnap.data ?? const <OrderModel>[];
            final activeOrders = orders
                .where((o) => !_activeOrderDoneStatuses.contains(o.status))
                .toList();
            final prints = orders.where((o) => o.isPoster || o.isPuzzle).toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

            if (books.isEmpty && prints.isEmpty && activeOrders.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Souvenirs imprimés',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMedium,
                              letterSpacing: 1.2)),
                      GestureDetector(
                        onTap: () => context.push('/product/new'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                              color: AppColors.sageDark,
                              borderRadius: BorderRadius.circular(20)),
                          child: const Text('+ Créer',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
                if (activeOrders.isNotEmpty)
                  _ActiveOrdersCard(orders: activeOrders),
                if (books.isNotEmpty)
                  SizedBox(
                    height: 176,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
                      itemCount: books.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (_, i) => _BookCard(
                        book: books[i],
                        // Avant : renvoyait toujours vers la LISTE (/books) au
                        // lieu du livre tapé — incohérent avec _PrintOrderCard,
                        // qui lui ouvre bien SA commande. Même geste que
                        // book_history_screen.dart::_open (trouvé à l'audit
                        // UX du 03.09.26).
                        onTap: () =>
                            Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => PdfViewerScreen(
                              title: books[i].title, url: books[i].pdfUrl),
                        )),
                      ),
                    ),
                  ),
                if (prints.isNotEmpty)
                  SizedBox(
                    height: 176,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
                      itemCount: prints.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (_, i) => _PrintOrderCard(
                        order: prints[i],
                        onTap: () => context.push('/orders/${prints[i].id}'),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  MilestoneCategory? _safeCat(String type) {
    try {
      return getMilestoneCategoryById(type);
    } catch (_) {
      return null;
    }
  }

  String get _initial {
    final e = FirebaseAuth.instance.currentUser?.email ?? '';
    return e.isNotEmpty ? e[0].toUpperCase() : '·';
  }

  /// Tags à moi effectivement partagés (au moins un collaborateur) — les
  /// seuls que je peux gérer (voir TagModel.isOwner, même règle que le
  /// backend pour créer un lien d'invitation).
  void _showSharedTagsSheet(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final ownedAll = _myTags.where((t) => t.isOwner(uid)).toList();
    final owned =
        ownedAll.where((t) => t.sharedWith.isNotEmpty).toList();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => SharedTagsSheet(tags: owned, ownedTags: ownedAll),
    );
  }

  void _showMonEspace(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _MonEspaceSheet(
        quota: _quota,
        videoQuota: _videoQuota,
        audioQuota: _audioQuota,
      ),
    );
  }

  SliverToBoxAdapter _sectionHeader(String title, String trailing,
          {VoidCallback? onAction}) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMedium,
                      letterSpacing: 1.2)),
              GestureDetector(
                onTap: onAction,
                child: Text(trailing,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            onAction != null ? FontWeight.w600 : FontWeight.w400,
                        color: onAction != null
                            ? AppColors.sageDark
                            : AppColors.textMedium)),
              ),
            ],
          ),
        ),
      );

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Bonjour';
    if (h < 18) return 'Bon après-midi';
    return 'Bonsoir';
  }
}

// _TopBar et _HeroGreeting ont fusionné dans _HomeScreenState._heroSection
// (refonte dashboard 22.09.26 : logo, accès rapides et salutation en
// surimpression de la photo héro plutôt qu'en bandeaux séparés).

// ── Livre (carte de l'étagère « Mes livres ») ────────────────────────────────

class _BookCard extends StatelessWidget {
  final GeneratedBookModel book;
  final VoidCallback onTap;
  const _BookCard({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 118,
              height: 132,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3C2814).withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: _CoverThumb(
                photoKey: book.coverPhotoKey,
                photoUrl: book.coverPhotoUrl,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        book.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Fraunces',
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          shadows: [
                            Shadow(color: Colors.black45, blurRadius: 4),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.28),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          book.isPrinted ? 'commandé' : 'PDF',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${book.memoriesCount} souvenir${book.memoriesCount > 1 ? 's' : ''}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fond d'une carte étagère (livre ou tirage) : la photo de couverture en
/// plein cadre + un voile sombre en bas (le texte posé dessus reste lisible
/// quelle que soit la photo) ; à défaut de photo, le dégradé brun de marque —
/// jamais de blanc nu, c'est justement ce qu'on corrige.
///
/// [photoKey] (clé R2, prioritaire) est résolu en URL signée à l'affichage —
/// jamais stockée telle quelle (elle expirerait après 1h, voir
/// generated_book_model.dart). [photoUrl] reste pour les photos Firebase
/// héritées (URL permanente, utilisée directement).
class _CoverThumb extends StatelessWidget {
  final String? photoKey;
  final String? photoUrl;
  final Widget child;
  const _CoverThumb(
      {required this.photoKey, required this.photoUrl, required this.child});

  static const _fallback = BoxDecoration(
    gradient: LinearGradient(
      colors: [Color(0xFF6B4A32), Color(0xFF8A6242)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (photoKey != null && photoKey!.isNotEmpty) {
      return FutureBuilder<Map<String, String>>(
        future: PhotoService.signOwnPhotoKeys([photoKey!]),
        builder: (context, snap) {
          final url = snap.data?[photoKey];
          return url != null
              ? _withPhoto(url)
              : Container(decoration: _fallback, child: child);
        },
      );
    }
    if (photoUrl != null && photoUrl!.isNotEmpty) return _withPhoto(photoUrl!);
    return Container(decoration: _fallback, child: child);
  }

  Widget _withPhoto(String url) => Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, __) => const ColoredBox(color: Color(0xFF6B4A32)),
            errorWidget: (_, __, ___) => const DecoratedBox(decoration: _fallback),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.black.withOpacity(0.05), Colors.black.withOpacity(0.55)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          child,
        ],
      );
}

// ── Tirage ou puzzle (carte de l'étagère du module « Souvenirs imprimés »,
// posters ET puzzles désormais réunis — voir _printedSection) ──────────────

class _PrintOrderCard extends StatelessWidget {
  final OrderModel order;
  final VoidCallback onTap;
  const _PrintOrderCard({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isPuzzle = order.isPuzzle;
    final photoKey = isPuzzle ? order.puzzlePhotoKey : order.posterPhotoKey;
    final photoUrl = isPuzzle ? order.puzzlePhotoUrl : order.posterPhotoUrl;
    final label = isPuzzle
        ? (order.puzzleSize != null
            ? 'Puzzle ${PuzzlePricing.label(order.puzzleSize!)}'
            : 'Puzzle')
        : (order.posterSize ?? 'Tirage');
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 118,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 118,
              height: 132,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1F3D2B).withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: _PosterThumb(
                photoKey: photoKey,
                photoUrl: photoUrl,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Fraunces',
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                          shadows: [
                            Shadow(color: Colors.black45, blurRadius: 4),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.28),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          order.statusLabel,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${order.memoryCount} souvenir${order.memoryCount > 1 ? 's' : ''}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Même principe que `_CoverThumb`, dégradé vert sauge (couleur du produit
/// tirage) plutôt que brun (livre) quand pas de photo.
/// Même remarque sur [photoKey] (résolu à l'affichage, jamais stocké en URL
/// signée) vs [photoUrl] (photo Firebase héritée, permanente).
class _PosterThumb extends StatelessWidget {
  final String? photoKey;
  final String? photoUrl;
  final Widget child;
  const _PosterThumb(
      {required this.photoKey, required this.photoUrl, required this.child});

  static const _fallback = BoxDecoration(
    gradient: LinearGradient(
      colors: [Color(0xFF3A6648), Color(0xFF5C8A6E)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (photoKey != null && photoKey!.isNotEmpty) {
      return FutureBuilder<Map<String, String>>(
        future: PhotoService.signOwnPhotoKeys([photoKey!]),
        builder: (context, snap) {
          final url = snap.data?[photoKey];
          return url != null
              ? _withPhoto(url)
              : Container(decoration: _fallback, child: child);
        },
      );
    }
    if (photoUrl != null && photoUrl!.isNotEmpty) return _withPhoto(photoUrl!);
    return Container(decoration: _fallback, child: child);
  }

  Widget _withPhoto(String url) => Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, __) => const ColoredBox(color: Color(0xFF3A6648)),
            errorWidget: (_, __, ___) => const DecoratedBox(decoration: _fallback),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.black.withOpacity(0.05), Colors.black.withOpacity(0.55)],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          child,
        ],
      );
}

// _CreateBookCta (bandeau plein largeur) et _StackedPagesMark ont disparu
// avec la refonte du 22.09.26 : "Créer un souvenir imprimé" est maintenant
// le bouton "+ Créer" du module _printedSection.

// ── Feuille « Mon espace » ───────────────────────────────────────────────────

class _MonEspaceSheet extends StatelessWidget {
  final QuotaStatus? quota;
  final QuotaStatus? videoQuota;
  final QuotaStatus? audioQuota;
  const _MonEspaceSheet({
    required this.quota,
    required this.videoQuota,
    required this.audioQuota,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: AppColors.softGray,
                    borderRadius: BorderRadius.circular(99)),
              ),
            ),
            const Text('Mon espace',
                style: TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 16),
            _GaugeRow(label: '🖼 Photos', quota: quota),
            _GaugeRow(label: '🎬 Vidéos', quota: videoQuota),
            _GaugeRow(label: '🎙 Vocaux', quota: audioQuota),
          ],
        ),
      ),
    );
  }
}

/// Ligne d'usage simple — juste un compte, sans dénominateur ni barre : il n'y
/// a plus de palier à approcher, la limite n'a aucun intérêt pour l'utilisateur.
class _GaugeRow extends StatelessWidget {
  final String label;
  final QuotaStatus? quota;
  const _GaugeRow({required this.label, required this.quota});

  @override
  Widget build(BuildContext context) {
    final count = quota?.current ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.textDark,
                  fontWeight: FontWeight.w500)),
          Text('$count',
              style: const TextStyle(
                  fontWeight: FontWeight.w600, color: AppColors.textDark)),
        ],
      ),
    );
  }
}

// ── Écran vide ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                gradient: RadialGradient(colors: [
                  AppColors.sage.withOpacity(0.18),
                  AppColors.sage.withOpacity(0.04),
                ]),
                shape: BoxShape.circle,
              ),
              child:
                  const Center(child: Text('📸', style: TextStyle(fontSize: 40))),
            ),
            const SizedBox(height: 22),
            const Text(
              'Ton premier souvenir t\'attend',
              style: TextStyle(
                fontFamily: 'Fraunces',
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: AppColors.textDark,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'Importe des photos ou des vidéos :\nl\'année et le lieu deviennent tes premiers tags.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.textMedium, height: 1.6, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Fil d'activité (souvenirs partagés) ──────────────────────────────────────

/// "Karin a ajouté 3 photos à « Vacances »" (ou "a supprimé 2 photos de",
/// ajout et suppression pouvant se combiner), tout en haut du dashboard.
/// Seule la plus récente est affichée : les autres restent repliées derrière
/// « Voir les N autres » — sans ça, les activités non validées s'empilaient
/// et poussaient tout le dashboard vers le bas. Chaque destinataire (l'auteur
/// du geste compris) valide de son côté ; ça n'affecte personne d'autre.
class _ActivityBanner extends StatefulWidget {
  const _ActivityBanner();

  @override
  State<_ActivityBanner> createState() => _ActivityBannerState();
}

class _ActivityBannerState extends State<_ActivityBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MemoryActivityModel>>(
      stream: MemoryActivityService.streamPending(),
      builder: (context, snap) {
        final activities = snap.data ?? const <MemoryActivityModel>[];
        if (activities.isEmpty) return const SizedBox.shrink();
        final others = activities.length - 1;
        final visible = _expanded ? activities : activities.take(1);
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 6),
                child: Text(
                  activities.length == 1
                      ? 'NOUVEAUTÉ SUR VOS SOUVENIRS PARTAGÉS'
                      : '${activities.length} NOUVEAUTÉS SUR VOS SOUVENIRS PARTAGÉS',
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 10.5,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMedium),
                ),
              ),
              for (final a in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ActivityCard(activity: a),
                ),
              if (others > 0)
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 18),
                      label: Text(_expanded
                          ? 'Réduire'
                          : 'Voir ${others == 1 ? "l'autre nouveauté" : 'les $others autres'}'),
                      style: TextButton.styleFrom(
                          foregroundColor: AppColors.sageDark,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          visualDensity: VisualDensity.compact),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => MemoryActivityService.markAllSeen(
                          activities.map((a) => a.id)),
                      style: TextButton.styleFrom(
                          foregroundColor: AppColors.textMedium,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          visualDensity: VisualDensity.compact),
                      child: const Text('Tout marquer comme vu'),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ActivityCard extends StatelessWidget {
  final MemoryActivityModel activity;
  const _ActivityCard({required this.activity});

  String get _addedLabel {
    final parts = <String>[];
    if (activity.photosAdded > 0) {
      parts.add(
          '${activity.photosAdded} photo${activity.photosAdded > 1 ? 's' : ''}');
    }
    if (activity.videosAdded > 0) {
      parts.add(
          '${activity.videosAdded} vidéo${activity.videosAdded > 1 ? 's' : ''}');
    }
    return parts.join(' et ');
  }

  String get _removedLabel {
    final parts = <String>[];
    if (activity.photosRemoved > 0) {
      parts.add(
          '${activity.photosRemoved} photo${activity.photosRemoved > 1 ? 's' : ''}');
    }
    if (activity.videosRemoved > 0) {
      parts.add(
          '${activity.videosRemoved} vidéo${activity.videosRemoved > 1 ? 's' : ''}');
    }
    return parts.join(' et ');
  }

  String get _title =>
      activity.memoryTitle.isNotEmpty ? activity.memoryTitle : 'un souvenir';

  /// Verbe + médias + préposition avant le titre — varie selon que
  /// l'activité est un ajout, une suppression, ou (rare, mais possible en
  /// éditant) les deux à la fois dans la même sauvegarde.
  String get _actionText {
    final added = _addedLabel;
    final removed = _removedLabel;
    if (activity.isCreated) return 'a créé un souvenir avec $added à';
    if (added.isNotEmpty && removed.isNotEmpty) {
      return 'a ajouté $added et supprimé $removed sur';
    }
    if (removed.isNotEmpty) return 'a supprimé $removed de';
    return 'a ajouté $added à';
  }

  String get _relativeTime {
    final diff = DateTime.now().difference(activity.createdAt);
    if (diff.inMinutes < 1) return 'à l\'instant';
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    return 'il y a ${diff.inDays} j';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/memory/${activity.memoryId}'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.sageTint,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.sage.withOpacity(0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Icon(Icons.notifications_active_outlined,
                  color: AppColors.sageDark, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textDark, height: 1.4),
                      children: [
                        TextSpan(
                            text: activity.actorLabel,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: ' $_actionText « '),
                        TextSpan(
                            text: _title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const TextSpan(text: ' »'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text('$_relativeTime · touche pour voir le souvenir',
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textMedium)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Bouton texte explicite : l'ancienne icône ✓ seule n'était pas
            // comprise comme « valider », donc rien n'était jamais validé.
            TextButton.icon(
              onPressed: () => MemoryActivityService.markSeen(activity.id),
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Vu'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: AppColors.sageDark,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 34),
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bannière commandes en cours ──────────────────────────────────────────────

// 'archived' = le client a confirmé avoir reçu son colis (voir
// order_tracking_screen.dart, bouton "J'ai bien reçu ma commande") — sans ça,
// une commande 'shipped' restait "en cours" indéfiniment, même reçue.
const _activeOrderDoneStatuses = {'paid', 'archived'};

/// Carte « N commande(s) en cours », affichée sous le titre « Souvenirs
/// imprimés » (voir `_printedSection`) — regroupée là plutôt qu'en bandeau
/// flottant tout en haut du dashboard, pour rester au même endroit que ce
/// qu'elle concerne.
class _ActiveOrdersCard extends StatelessWidget {
  final List<OrderModel> orders;
  const _ActiveOrdersCard({required this.orders});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/orders'),
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.amber.withOpacity(0.35), width: 1),
        ),
        child: Row(
          children: [
            const Text('📦', style: TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${orders.length} commande${orders.length > 1 ? 's' : ''} en cours',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: AppColors.textDark,
                    ),
                  ),
                  Text(
                    orders.first.statusLabel,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textMedium),
                  ),
                ],
              ),
            ),
            const Text('Voir →',
                style: TextStyle(
                    color: AppColors.amber,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
