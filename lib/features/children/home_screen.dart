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
  String _tier = 'free';

  List<TagModel> _myTags = [];
  List<TagModel> _sharedTags = [];
  List<MemoryModel> _recentMemories = [];
  Map<String, int> _memoriesPerTag = {};

  StreamSubscription? _myTagsSub;
  StreamSubscription? _sharedTagsSub;
  StreamSubscription? _mineSub;
  StreamSubscription? _sharedMemSub;

  // Les souvenirs arrivent par deux flux (les miens, ceux qu'on m'a partagés) :
  // on les fusionne par id avant d'afficher.
  final Map<String, MemoryModel> _memoriesById = {};

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
    _mineSub = memories
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((snap) => _mergeMemories(snap));
    _sharedMemSub = memories
        .where('sharedWith', arrayContains: uid)
        .snapshots()
        .listen((snap) => _mergeMemories(snap));
  }

  void _mergeMemories(QuerySnapshot<Map<String, dynamic>> snap) {
    for (final d in snap.docs) {
      _memoriesById[d.id] = MemoryModel.fromFirestore(d);
    }
    final all = _memoriesById.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final counts = <String, int>{};
    for (final m in all) {
      for (final id in m.tagIds) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    if (mounted) {
      setState(() {
        _recentMemories = all.take(3).toList();
        _memoriesPerTag = counts;
      });
    }
  }

  Future<void> _loadQuota() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final tier = await QuotaService.getSubscriptionTier(uid);
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
        _tier = tier;
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
    final allTags = [..._myTags, ..._sharedTags];
    final hasMemories = _memoriesById.isNotEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _TopBar(
            initial: _initial,
            maxUsage: _maxUsageRatio,
            warn: _nearAnyLimit,
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
          // 2) Les derniers souvenirs.
          _sectionHeader('Mes derniers souvenirs', 'Tout voir',
              onAction: () => context.push('/memories')),
          SliverToBoxAdapter(child: _recentMemoriesRail(context)),

          // 3) Les tags — l'organisation des souvenirs.
          if (allTags.isNotEmpty) ...[
            _sectionHeader('Mes tags', '${allTags.length}'),
            SliverToBoxAdapter(child: _tagsWrap(context, allTags)),
          ],
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

  Widget _recentMemoriesRail(BuildContext context) {
    return SizedBox(
      height: 210,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 8),
        itemCount: _recentMemories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) {
          final m = _recentMemories[i];
          return SizedBox(
            width: 145,
            child: MemoryPolaroid(
              memory: m,
              cat: _safeCat(m.type),
              tilt: (i % 2 == 0) ? -0.02 : 0.02,
              onTap: () => context.push('/memory/${m.id}/edit'),
            ),
          );
        },
      ),
    );
  }

  Widget _tagsWrap(BuildContext context, List<TagModel> tags) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in tags)
            GestureDetector(
              onTap: () => context.push('/memories?tag=${t.id}'),
              child: _TagPill(
                tag: t,
                count: _memoriesPerTag[t.id] ?? 0,
                shared: t.isShared || !t.isOwner(_uid),
              ),
            ),
        ],
      ),
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

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  double get _maxUsageRatio {
    final rs = [
      _quota?.ratio ?? 0,
      _videoQuota?.ratio ?? 0,
      _audioQuota?.ratio ?? 0,
    ];
    return rs.fold<double>(0, (m, r) => r > m ? r : m);
  }

  bool get _nearAnyLimit =>
      (_quota?.nearLimit ?? false) ||
      (_videoQuota?.nearLimit ?? false) ||
      (_audioQuota?.nearLimit ?? false);

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
        tier: _tier,
        quota: _quota,
        videoQuota: _videoQuota,
        audioQuota: _audioQuota,
        onUpsell: () {
          Navigator.pop(context);
          context.push('/subscription');
        },
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
  final double maxUsage;
  final bool warn;
  final VoidCallback onProfile;
  final VoidCallback onSpace;
  const _TopBar({
    required this.initial,
    required this.maxUsage,
    required this.warn,
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
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.sageDark,
                borderRadius: BorderRadius.circular(11),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sageDark.withOpacity(0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(Icons.auto_stories_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Carnet',
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 25,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                      height: 1,
                    )),
                SizedBox(width: 2),
                Text('.',
                    style: TextStyle(
                      fontFamily: 'Fraunces',
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      color: AppColors.sageDark,
                      height: 1,
                    )),
              ],
            ),
            const Spacer(),
            _SpaceGauge(ratio: maxUsage, warn: warn, onTap: onSpace),
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

class _SpaceGauge extends StatelessWidget {
  final double ratio;
  final bool warn;
  final VoidCallback onTap;
  const _SpaceGauge(
      {required this.ratio, required this.warn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                  color: AppColors.sageTint, shape: BoxShape.circle),
            ),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: ratio.clamp(0.02, 1.0),
                strokeWidth: 3,
                backgroundColor: AppColors.sage.withOpacity(0.22),
                valueColor: AlwaysStoppedAnimation(
                    warn ? AppColors.amber : AppColors.sage),
              ),
            ),
            if (warn)
              Positioned(
                top: 1,
                right: 1,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: AppColors.amber,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.background, width: 2),
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

// ── Tag ──────────────────────────────────────────────────────────────────────

class _TagPill extends StatelessWidget {
  final TagModel tag;
  final int count;
  final bool shared;
  const _TagPill(
      {required this.tag, required this.count, required this.shared});

  Color get _color {
    try {
      return Color(int.parse('FF${tag.color.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return AppColors.sage;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      decoration: BoxDecoration(
        color: _color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(50),
        border: Border.all(color: _color.withOpacity(0.45), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tag.isChild) ...[
            const Text('👶', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 5),
          ],
          Text(tag.label,
              style: TextStyle(
                  color: _color,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600)),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Text('$count',
                style: TextStyle(
                    color: _color.withOpacity(0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ],
          if (shared) ...[
            const SizedBox(width: 5),
            Icon(Icons.people_outline, size: 13, color: _color.withOpacity(0.8)),
          ],
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
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.menu_book_rounded,
                    color: Colors.white, size: 28),
              ),
              const SizedBox(width: 16),
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

// ── Feuille « Mon espace » ───────────────────────────────────────────────────

class _MonEspaceSheet extends StatelessWidget {
  final String tier;
  final QuotaStatus? quota;
  final QuotaStatus? videoQuota;
  final QuotaStatus? audioQuota;
  final VoidCallback onUpsell;
  const _MonEspaceSheet({
    required this.tier,
    required this.quota,
    required this.videoQuota,
    required this.audioQuota,
    required this.onUpsell,
  });

  @override
  Widget build(BuildContext context) {
    final premium = tier == 'premium';
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Mon espace',
                    style: TextStyle(
                        fontFamily: 'Fraunces',
                        fontSize: 21,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDark)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                      color: AppColors.sageDark,
                      borderRadius: BorderRadius.circular(99)),
                  child: Text(premium ? '✦ Premium' : 'Gratuit',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _GaugeRow(label: '🖼 Photos', quota: quota),
            _GaugeRow(label: '🎬 Vidéos', quota: videoQuota),
            _GaugeRow(label: '🎙 Vocaux', quota: audioQuota),
            if (!premium) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                    color: AppColors.sageTint,
                    borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Passe à l\'illimité',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textDark)),
                          SizedBox(height: 2),
                          Text('Médias sans limite + livres −20 %',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.textMedium)),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      onPressed: onUpsell,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.sageDark,
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(99)),
                      ),
                      child:
                          const Text('Découvrir', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GaugeRow extends StatelessWidget {
  final String label;
  final QuotaStatus? quota;
  const _GaugeRow({required this.label, required this.quota});

  @override
  Widget build(BuildContext context) {
    final q = quota;
    final ratio = q?.ratio ?? 0;
    final warn = q?.nearLimit ?? false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 13.5,
                      color: AppColors.textDark,
                      fontWeight: FontWeight.w500)),
              Text.rich(TextSpan(children: [
                TextSpan(
                    text: '${q?.current ?? 0}',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: warn ? AppColors.amber : AppColors.textDark)),
                TextSpan(
                    text: ' / ${q?.limit ?? 0}',
                    style: const TextStyle(color: AppColors.textMedium)),
              ])),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: AppColors.softGray.withOpacity(0.28),
              valueColor: AlwaysStoppedAnimation(
                  warn ? AppColors.amber : AppColors.sageDark),
            ),
          ),
          if (warn)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                '⚠ Plus que ${q?.remaining ?? 0} avant la limite',
                style: const TextStyle(fontSize: 11.5, color: AppColors.amber),
              ),
            ),
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
