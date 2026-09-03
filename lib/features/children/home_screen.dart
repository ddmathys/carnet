import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
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
import '../../core/services/tag_service.dart';
import '../memories/widgets/memory_polaroid.dart';
import '../memories/widgets/import_media_cta.dart';
import '../memories/widgets/delete_memory.dart';
import '../tags/tag_picker_sheet.dart';
import '../tags/share_tag_sheet.dart';
import '../tags/shared_tags_sheet.dart';

/// Dashboard : importer un média (le geste principal), les derniers souvenirs,
/// les tags qui les organisent, les livres déjà faits — et, tout en bas, la
/// création d'un nouveau livre.
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
  List<TagModel> _sharedTags = [];
  List<MemoryModel> _recentMemories = [];

  /// Filtre courant : les libellés de tags cochés dans le sélecteur.
  final Set<String> _filterLabels = {};

  StreamSubscription? _myTagsSub;
  StreamSubscription? _sharedTagsSub;
  StreamSubscription? _mineSub;
  StreamSubscription? _sharedMemSub;

  // Les souvenirs arrivent par deux flux (les miens, ceux qu'on m'a partagés) :
  // chaque flux garde SON lot, et on les fusionne à l'affichage. Garder un seul
  // sac commun faisait qu'un souvenir supprimé restait à l'écran — le flux ne
  // sait dire « il n'est plus là » qu'en cessant de l'énumérer.
  Map<String, MemoryModel> _mineById = {};
  Map<String, MemoryModel> _sharedById = {};

  Map<String, MemoryModel> get _memoriesById => {..._sharedById, ..._mineById};

  // Raccourci direct vers /growth/:tagId — sans ça, la courbe de croissance
  // n'était atteignable qu'en filtrant "Mes souvenirs" sur UN SEUL tag
  // enfant pour faire apparaître une icône dans l'appbar (très peu
  // découvrable, cause fréquente de "je ne trouve pas où saisir la taille").
  List<TagModel> get _childTags =>
      [..._myTags, ..._sharedTags].where((t) => t.isChild).toList();

  @override
  void initState() {
    super.initState();
    _setupStreams();
    _loadQuota();
  }

  @override
  void dispose() {
    _myTagsSub?.cancel();
    _sharedTagsSub?.cancel();
    _mineSub?.cancel();
    _sharedMemSub?.cancel();
    super.dispose();
  }

  void _setupStreams() {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    _myTagsSub = TagService.streamMine().listen((tags) {
      if (mounted) setState(() => _myTags = tags);
    });
    _sharedTagsSub = TagService.streamSharedWithMe().listen((tags) {
      if (mounted) setState(() => _sharedTags = tags);
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
    if (mounted) setState(_applyFilter);
  }

  /// Les 6 derniers souvenirs — filtrés si des tags sont cochés.
  ///
  /// Triés par DATE D'AJOUT (createdAt), pas par la date du souvenir : un
  /// souvenir tout juste importé (ex. une vieille photo d'enfance) doit
  /// apparaître en premier ici, même si sa date le placerait ailleurs dans
  /// le carnet chronologique (`/memories`, qui lui reste trié par `date`).
  void _applyFilter() {
    final selected = _selectedTags;
    final all = _memoriesById.values
        .where((m) => memoryMatchesTags(m, selected))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _recentMemories = all.take(6).toList();
  }

  List<TagModel> get _allTags => [..._myTags, ..._sharedTags];

  List<TagModel> get _selectedTags =>
      [for (final t in _allTags) if (_filterLabels.contains(t.label)) t];

  Future<void> _openFilter() async {
    final result = await showTagPickerSheet(
      context,
      tags: _allTags,
      initialLabels: _filterLabels,
    );
    if (result == null || !mounted) return;
    setState(() {
      _filterLabels
        ..clear()
        ..addAll(result);
      _applyFilter();
    });
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
    );
  }

  Widget _buildBody(BuildContext context) {
    final hasMemories = _memoriesById.isNotEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _TopBar(
            initial: _initial,
            onProfile: () => context.push('/profile'),
            onSpace: () => _showMonEspace(context),
            onShared: () => _showSharedTagsSheet(context),
          ),
        ),
        const SliverToBoxAdapter(child: _ActivityBanner()),

        SliverToBoxAdapter(child: _HeroGreeting(greeting: _greeting)),

        if (!hasMemories) ...[
          // Pas encore de souvenir : le geste principal reste visible tout de
          // suite, avant l'état vide qui explique quoi faire.
          SliverToBoxAdapter(
            child: ImportMediaCta(
                onTap: () => context.push('/memory/new?import=1')),
          ),
          const SliverToBoxAdapter(child: _EmptyState()),
        ] else ...[
          // 1) Le geste principal (importer) au-dessus du titre de la
          // section, puis le filtre par tags (date / lieu / événement), puis
          // les souvenirs.
          SliverToBoxAdapter(
            child: ImportMediaCta(
                onTap: () => context.push('/memory/new?import=1')),
          ),
          _sectionHeader(
            _filterLabels.isEmpty
                ? 'Mes derniers souvenirs'
                : 'Souvenirs filtrés',
            'Tout voir',
            onAction: () => context.push('/memories'),
          ),
          SliverToBoxAdapter(child: _filterBar(context)),
          SliverToBoxAdapter(child: _recentMemoriesGrid(context)),
        ],

        // 3b) Courbe de croissance — un raccourci direct par tag enfant.
        if (_childTags.isNotEmpty) ...[
          _sectionHeader('Croissance', ''),
          SliverToBoxAdapter(child: _growthShortcuts(context)),
        ],

        // 4) Les livres déjà faits (PDF générés et livres commandés) — la
        // section entière (titre compris) ne s'affiche que s'il y en a.
        SliverToBoxAdapter(child: _booksSection(context)),

        // 4b) Les tirages commandés (posters) — même principe, section à part
        // puisque ce sont deux produits distincts (voir OrderModel.isPoster).
        SliverToBoxAdapter(child: _postersSection(context)),

        // 5) Créer un livre — tout en bas, l'aboutissement.
        SliverToBoxAdapter(
          child: _CreateBookCta(onTap: () => context.push('/book/select')),
        ),
        // 6) Créer un poster — juste en dessous, même geste d'aboutissement.
        SliverToBoxAdapter(
          child: _CreatePosterCta(onTap: () => context.push('/poster/select')),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  /// Barre de filtre : un bouton qui ouvre le sélecteur (Date / Lieu /
  /// Événement, multi-sélection), et le rappel des tags cochés.
  Widget _filterBar(BuildContext context) {
    final selected = _filterLabels.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _openFilter,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: _filterLabels.isEmpty
                        ? AppColors.surface
                        : AppColors.sageDark,
                    borderRadius: BorderRadius.circular(50),
                    border: Border.all(
                      color: _filterLabels.isEmpty
                          ? AppColors.border
                          : AppColors.sageDark,
                      width: _filterLabels.isEmpty ? 0.5 : 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune,
                          size: 16,
                          color: _filterLabels.isEmpty
                              ? AppColors.textMedium
                              : Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        _filterLabels.isEmpty
                            ? 'Filtrer par tag'
                            : '${_filterLabels.length} tag${_filterLabels.length > 1 ? 's' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _filterLabels.isEmpty
                              ? AppColors.textMedium
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_filterLabels.isNotEmpty) ...[
                // Les tags cochés se partagent d'un seul lien — un pour tous.
                IconButton(
                  onPressed: () => showShareTagSheet(context, _selectedTags),
                  icon: const Icon(Icons.ios_share,
                      size: 18, color: AppColors.sageDark),
                  tooltip: _selectedTags.length == 1
                      ? 'Partager ce tag'
                      : 'Partager ces ${_selectedTags.length} tags',
                  constraints:
                      const BoxConstraints(minWidth: 38, minHeight: 38),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _filterLabels.clear();
                    _applyFilter();
                  }),
                  child: const Text('Effacer',
                      style:
                          TextStyle(color: AppColors.textMedium, fontSize: 13)),
                ),
              ],
            ],
          ),
          if (selected.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final label in selected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.sageTint,
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.sageDark,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Les 6 derniers souvenirs (du filtre courant), en polaroïdes — le tout
  /// premier (le plus récemment ajouté) est mis en avant en grand plutôt que
  /// noyé dans la grille, pour que "je viens d'importer quelque chose" se
  /// voie vraiment sans avoir à chercher.
  Widget _recentMemoriesGrid(BuildContext context) {
    if (_recentMemories.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(22, 14, 22, 10),
        child: Text(
          'Aucun souvenir avec ces tags.',
          style: TextStyle(color: AppColors.textMedium, fontSize: 13),
        ),
      );
    }
    final featured = _recentMemories.first;
    final rest = _recentMemories.skip(1).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Column(
        children: [
          SizedBox(
            height: 230,
            child: Stack(
              children: [
                Positioned.fill(
                  child: MemoryPolaroid(
                    memory: featured,
                    cat: _safeCat(featured.type),
                    tilt: 0,
                    onTap: () => context.push('/memory/${featured.id}'),
                    onDelete: () => _deleteMemory(featured),
                  ),
                ),
                Positioned(
                  top: 14,
                  right: 14,
                  child: Transform.rotate(
                    angle: 0.05,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.sageDark,
                        borderRadius: BorderRadius.circular(99),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Text(
                        '🆕 Dernier ajouté',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 18),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 18,
                crossAxisSpacing: 14,
                childAspectRatio: 0.66,
              ),
              itemCount: rest.length,
              itemBuilder: (_, i) {
                final m = rest[i];
                return MemoryPolaroid(
                  memory: m,
                  cat: _safeCat(m.type),
                  tilt: (i % 2 == 0) ? -0.02 : 0.02,
                  onTap: () => context.push('/memory/${m.id}'),
                  onDelete: () => _deleteMemory(m),
                );
              },
            ),
          ],
        ],
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
      _applyFilter();
    });
    _loadQuota(); // les quotas viennent de baisser
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Souvenir supprimé.')),
    );
  }

  /// Section « Mes livres » (titre + étagère) : PDF générés et livres
  /// commandés, du plus récent au plus ancien. Regroupe aussi juste sous le
  /// titre le bandeau « commande(s) en cours » — avant, il flottait tout en
  /// haut du dashboard, sans lien visuel avec les livres/tirages qu'il
  /// concerne (demande explicite : consolider au même endroit, 03.09.26).
  /// N'affiche RIEN (pas même le titre) s'il n'y a ni livre ni commande en
  /// cours — mais le titre reste affiché pour une commande en cours même
  /// sans livre encore listé (ex. tirage seul, ou livre pas encore généré).
  Widget _booksSection(BuildContext context) {
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
            final activeOrders = (orderSnap.data ?? const <OrderModel>[])
                .where((o) => !_activeOrderDoneStatuses.contains(o.status))
                .toList();
            if (books.isEmpty && activeOrders.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeaderInline('Mes livres', 'Tout voir',
                    onAction: () => context.push('/books')),
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
                        // lieu du livre tapé — incohérent avec _PosterCard,
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
              ],
            );
          },
        );
      },
    );
  }

  /// Section « Mes tirages » (titre + étagère) : posters commandés, du plus
  /// récent au plus ancien. N'affiche RIEN tant qu'il n'y a aucun tirage.
  Widget _postersSection(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<List<OrderModel>>(
      stream: OrderService.userOrdersStream(uid),
      builder: (context, snap) {
        final posters = (snap.data ?? const <OrderModel>[])
            .where((o) => o.isPoster)
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        if (posters.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeaderInline('Mes tirages', 'Tout voir',
                onAction: () => context.push('/orders')),
            SizedBox(
              height: 176,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
                itemCount: posters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, i) => _PosterCard(
                  order: posters[i],
                  onTap: () => context.push('/orders/${posters[i].id}'),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Même habillage que `_sectionHeader`, mais en widget simple (pas un
  /// sliver) : ces deux sections vivent DANS un SliverToBoxAdapter, pour
  /// pouvoir s'effacer entièrement (titre compris) le temps que le flux
  /// Firestore réponde ou si la liste est vide.
  Widget _sectionHeaderInline(String title, String trailing,
          {VoidCallback? onAction}) =>
      Padding(
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
      );

  Widget _growthShortcuts(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
      child: Column(
        children: [
          for (final tag in _childTags)
            GestureDetector(
              onTap: () => context.push('/growth/${tag.id}'),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.border, width: 0.5),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.show_chart, color: AppColors.sage),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Courbe de croissance · ${tag.label}',
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textDark)),
                    ),
                    const Icon(Icons.chevron_right,
                        color: AppColors.softGray, size: 20),
                  ],
                ),
              ),
            ),
        ],
      ),
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

// ── Barre du haut : logo + jauge d'espace + avatar ───────────────────────────

class _TopBar extends StatelessWidget {
  final String initial;
  final VoidCallback onProfile;
  final VoidCallback onSpace;
  final VoidCallback onShared;
  const _TopBar({
    required this.initial,
    required this.onProfile,
    required this.onSpace,
    required this.onShared,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 18, 2),
        child: Row(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('carnet',
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontStyle: FontStyle.italic,
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                      height: 1,
                    )),
                SizedBox(width: 1),
                Text('.',
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontStyle: FontStyle.italic,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.sageDark,
                      height: 1,
                    )),
              ],
            ),
            const Spacer(),
            GestureDetector(
              onTap: onShared,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                    color: AppColors.sageTint, shape: BoxShape.circle),
                child: const Icon(Icons.people_alt_outlined,
                    size: 17, color: AppColors.sageDark),
              ),
            ),
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onSpace,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                    color: AppColors.sageTint, shape: BoxShape.circle),
                child: const Icon(Icons.folder_outlined,
                    size: 18, color: AppColors.sageDark),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: onProfile,
              child: Container(
                width: 38,
                height: 38,
                decoration: const BoxDecoration(
                    color: AppColors.sageDark, shape: BoxShape.circle),
                child: Center(
                  child: Text(initial,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroGreeting extends StatelessWidget {
  final String greeting;
  const _HeroGreeting({required this.greeting});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting,
              style: const TextStyle(
                fontFamily: 'Fraunces',
                fontSize: 28,
                fontWeight: FontWeight.w500,
                color: AppColors.textDark,
                height: 1.1,
              )),
          const SizedBox(height: 4),
          const Text('Chaque souvenir mérite d\'être conservé.',
              style: TextStyle(fontSize: 14, color: AppColors.textMedium)),
        ],
      ),
    );
  }
}

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

// ── Tirage (carte de l'étagère « Mes tirages ») ──────────────────────────────

class _PosterCard extends StatelessWidget {
  final OrderModel order;
  final VoidCallback onTap;
  const _PosterCard({required this.order, required this.onTap});

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
                    color: const Color(0xFF1F3D2B).withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: _PosterThumb(
                photoKey: order.posterPhotoKey,
                photoUrl: order.posterPhotoUrl,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        order.posterSize ?? 'Tirage',
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
/// tirage, cf. `_CreatePosterCta`) plutôt que brun (livre) quand pas de photo.
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

// « Créer un livre » : le bandeau d'aboutissement, en bas du dashboard.
class _CreateBookCta extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateBookCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 16, 22, 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6B4A32), Color(0xFF8A6242)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3C2814).withOpacity(0.28),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const _StackedPagesMark(),
              const SizedBox(width: 18),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Créer un livre',
                        style: TextStyle(
                          fontFamily: 'Fraunces',
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        )),
                    SizedBox(height: 3),
                    Text('Choisis un tag ou tes souvenirs un par un.',
                        style: TextStyle(fontSize: 12.5, color: Colors.white70)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

// « Créer un poster » : même bandeau que _CreateBookCta, couleurs distinctes
// (vert sauge plutôt que brun) pour bien différencier les deux produits.
class _CreatePosterCta extends StatelessWidget {
  final VoidCallback onTap;
  const _CreatePosterCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 4),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF3A6648), Color(0xFF5C8A6E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1F3D2B).withOpacity(0.28),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 54,
                height: 54,
                child: Icon(Icons.image_outlined, color: Colors.white, size: 30),
              ),
              const SizedBox(width: 18),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Créer un tirage',
                        style: TextStyle(
                          fontFamily: 'Fraunces',
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        )),
                    SizedBox(height: 3),
                    Text('Une ou plusieurs photos, prêtes à accrocher.',
                        style: TextStyle(fontSize: 12.5, color: Colors.white70)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
  }
}

/// Petite pile de pages en éventail — remplace l'icône livre générique par un
/// motif dessiné à la main (silhouettes superposées, légèrement pivotées).
class _StackedPagesMark extends StatelessWidget {
  const _StackedPagesMark();

  @override
  Widget build(BuildContext context) {
    Widget page(double angle, double opacity, double size) => Transform.rotate(
          angle: angle,
          child: Container(
            width: size,
            height: size * 0.78,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(opacity),
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        );
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(
        alignment: Alignment.center,
        children: [
          page(-0.22, 0.16, 40),
          page(0.14, 0.22, 40),
          Container(
            width: 40,
            height: 31,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.95),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                    width: 24, height: 2.4,
                    color: const Color(0xFF6B4A32).withOpacity(0.35)),
                const SizedBox(height: 4),
                Container(
                    width: 17, height: 2.4,
                    color: const Color(0xFF6B4A32).withOpacity(0.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
/// ajout et suppression pouvant se combiner) — une carte par activité non
/// encore validée, tout en haut du dashboard. Chaque destinataire (l'auteur
/// du geste compris) valide de son côté ; ça n'affecte personne d'autre.
class _ActivityBanner extends StatelessWidget {
  const _ActivityBanner();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MemoryActivityModel>>(
      stream: MemoryActivityService.streamPending(),
      builder: (context, snap) {
        final activities = snap.data ?? const <MemoryActivityModel>[];
        if (activities.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Column(
            children: [
              for (final a in activities)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _ActivityCard(activity: a),
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
                  Text(_relativeTime,
                      style: const TextStyle(
                          fontSize: 11.5, color: AppColors.textMedium)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => MemoryActivityService.markSeen(activity.id),
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.check_circle_outline,
                    color: AppColors.sageDark, size: 20),
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

/// Carte « N commande(s) en cours », affichée sous le titre « Mes livres »
/// (voir `_booksSection`) — regroupée là plutôt qu'en bandeau flottant tout
/// en haut du dashboard, pour rester au même endroit que ce qu'elle concerne.
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
