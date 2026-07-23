import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/models/generated_book_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/tag_service.dart';
import '../memories/widgets/memory_polaroid.dart';
import '../memories/widgets/import_media_cta.dart';
import '../memories/widgets/delete_memory.dart';
import '../tags/tag_picker_sheet.dart';
import '../tags/share_tag_sheet.dart';

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
  void _applyFilter() {
    final selected = _selectedTags;
    final all = _memoriesById.values
        .where((m) => memoryMatchesTags(m, selected))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
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
    final results = await Future.wait([
      QuotaService.checkQuota(uid),
      QuotaService.checkVideoQuota(uid),
      QuotaService.checkAudioQuota(uid),
    ]);
    if (mounted) {
      setState(() {
        _quota = results[0];
        _videoQuota = results[1];
        _audioQuota = results[2];
      });
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
          ),
        ),
        SliverToBoxAdapter(child: _HeroGreeting(greeting: _greeting)),

        // 1) Le geste principal : importer des médias → nouveau souvenir.
        SliverToBoxAdapter(
          child: ImportMediaCta(
              onTap: () => context.push('/memory/new?import=1')),
        ),

        _ActiveOrdersBanner(uid: FirebaseAuth.instance.currentUser?.uid ?? ''),

        if (!hasMemories)
          const SliverToBoxAdapter(child: _EmptyState())
        else ...[
          // 2) Le filtre par tags (date / lieu / événement), puis les souvenirs.
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

        // 4) Les livres déjà faits (PDF générés et livres commandés).
        _sectionHeader('Mes livres', 'Tout voir',
            onAction: () => context.push('/books')),
        SliverToBoxAdapter(child: _booksRail(context)),

        // 5) Créer un livre — tout en bas, l'aboutissement.
        SliverToBoxAdapter(
          child: _CreateBookCta(onTap: () => context.push('/book/select')),
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

  /// Les 6 derniers souvenirs (du filtre courant), en polaroïdes.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 18,
          crossAxisSpacing: 14,
          childAspectRatio: 0.66,
        ),
        itemCount: _recentMemories.length,
        itemBuilder: (_, i) {
          final m = _recentMemories[i];
          return MemoryPolaroid(
            memory: m,
            cat: _safeCat(m.type),
            tilt: (i % 2 == 0) ? -0.02 : 0.02,
            onTap: () => context.push('/memory/${m.id}'),
            onDelete: () => _deleteMemory(m),
          );
        },
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

  /// Rangée « Mes livres » : PDF générés et livres commandés, du plus récent au
  /// plus ancien. Vide → une invitation discrète à en créer un.
  Widget _booksRail(BuildContext context) {
    return StreamBuilder<List<GeneratedBookModel>>(
      stream: BookHistoryService.streamForUser(),
      builder: (context, snap) {
        final books = snap.data ?? const <GeneratedBookModel>[];
        if (books.isEmpty) {
          return const Padding(
            padding: EdgeInsets.fromLTRB(22, 2, 22, 6),
            child: Text(
              'Aucun livre pour l\'instant — compose-en un depuis tes tags.',
              style: TextStyle(color: AppColors.textMedium, fontSize: 13),
            ),
          );
        }
        return SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (_, i) => _BookCard(
              book: books[i],
              onTap: () => context.push('/books'),
            ),
          ),
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
  const _TopBar({
    required this.initial,
    required this.onProfile,
    required this.onSpace,
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$greeting 👋',
                    style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 28,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textDark,
                      height: 1.1,
                    )),
                const SizedBox(height: 4),
                const Text('Chaque souvenir mérite d\'être conservé.',
                    style:
                        TextStyle(fontSize: 14, color: AppColors.textMedium)),
              ],
            ),
          ),
          const Text('📖', style: TextStyle(fontSize: 40)),
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
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6B4A32), Color(0xFF8A6242)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF3C2814).withOpacity(0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
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
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
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

// ── Bannière commandes en cours ──────────────────────────────────────────────

class _ActiveOrdersBanner extends StatelessWidget {
  final String uid;
  const _ActiveOrdersBanner({required this.uid});

  static const _doneStatuses = {'paid'};

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: StreamBuilder<List<OrderModel>>(
        stream: OrderService.userOrdersStream(uid),
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final active = snap.data!
              .where((o) => !_doneStatuses.contains(o.status))
              .toList();
          if (active.isEmpty) return const SizedBox.shrink();

          return GestureDetector(
            onTap: () => context.push('/orders'),
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.amber.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border:
                    Border.all(color: AppColors.amber.withOpacity(0.35), width: 1),
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
                          '${active.length} commande${active.length > 1 ? 's' : ''} en cours',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.textDark,
                          ),
                        ),
                        Text(
                          active.first.statusLabel,
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
        },
      ),
    );
  }
}
