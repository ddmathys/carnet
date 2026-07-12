import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/order_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/order_service.dart';
import '../library/book_shelf.dart';
import '../memories/widgets/memory_polaroid.dart';
import '../memories/widgets/import_media_cta.dart';

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
  List<NotebookModel> _ownNotebooks = [];
  List<NotebookModel> _sharedNotebooks = [];
  // Nombre réel de souvenirs par carnet (le champ notebook.memoriesCount n'est
  // jamais incrémenté → on compte en direct via une requête d'agrégation).
  Map<String, int> _memCounts = {};
  // 3 souvenirs les plus récents (tous carnets confondus) pour le dashboard.
  List<MemoryModel> _recentMemories = [];
  StreamSubscription? _ownSub;
  StreamSubscription? _sharedSub;

  @override
  void initState() {
    super.initState();
    _setupStreams();
    _loadQuota();
  }

  @override
  void dispose() {
    _ownSub?.cancel();
    _sharedSub?.cancel();
    super.dispose();
  }

  void _setupStreams() {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    _ownSub = FirebaseFirestore.instance
        .collection('notebooks')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _ownNotebooks = snap.docs
            .map((d) => NotebookModel.fromFirestore(d))
            .toList()
          ..sort((a, b) => (b.lastMemoryAt ?? b.createdAt)
              .compareTo(a.lastMemoryAt ?? a.createdAt));
      });
      _refreshMemCounts();
      _refreshRecentMemories();
    });

    _sharedSub = FirebaseFirestore.instance
        .collection('notebooks')
        .where('sharedWith', arrayContains: uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _sharedNotebooks = snap.docs
            .map((d) => NotebookModel.fromFirestore(d))
            .toList()
          ..sort((a, b) => (b.lastMemoryAt ?? b.createdAt)
              .compareTo(a.lastMemoryAt ?? a.createdAt));
      });
      _refreshMemCounts();
      _refreshRecentMemories();
    });
  }

  // Compte les souvenirs de chaque carnet (agrégation côté serveur — ne lit pas
  // les documents). Rafraîchi à chaque changement de la liste des carnets.
  Future<void> _refreshMemCounts() async {
    final ids = <String>{
      ..._ownNotebooks.map((n) => n.id),
      ..._sharedNotebooks.map((n) => n.id),
    };
    final counts = <String, int>{};
    await Future.wait(ids.map((id) async {
      try {
        final agg = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', isEqualTo: id)
            .count()
            .get();
        counts[id] = agg.count ?? 0;
      } catch (_) {}
    }));
    if (mounted) setState(() => _memCounts = counts);
  }

  // Les 3 souvenirs les plus récents, tous carnets confondus. Les souvenirs
  // sont indexés par `notebookId` (pas `userId`) → on interroge par lots de 10
  // (limite `whereIn`), on fusionne et on trie côté client. Rafraîchi quand la
  // liste des carnets change (un nouveau souvenir met à jour son carnet).
  Future<void> _refreshRecentMemories() async {
    final ids = <String>{
      ..._ownNotebooks.map((n) => n.id),
      ..._sharedNotebooks.map((n) => n.id),
    }.toList();
    if (ids.isEmpty) {
      if (mounted) setState(() => _recentMemories = []);
      return;
    }
    final all = <MemoryModel>[];
    for (var i = 0; i < ids.length; i += 10) {
      final batch = ids.sublist(i, i + 10 > ids.length ? ids.length : i + 10);
      try {
        final snap = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', whereIn: batch)
            .get();
        all.addAll(snap.docs.map((d) => MemoryModel.fromFirestore(d)));
      } catch (_) {}
    }
    all.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() => _recentMemories = all.take(3).toList());
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

  Widget _buildBody(BuildContext context) {
    final allOwn = _ownNotebooks;
    final allShared = _sharedNotebooks;
    final isEmpty = allOwn.isEmpty && allShared.isEmpty;

    return CustomScrollView(
      slivers: [
        // 1) Logo
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

        // 2) Le livre → page « créer un livre »
        SliverToBoxAdapter(
          child: _CreateBookCta(onTap: () => context.push('/book/select')),
        ),

        // 3) Importer des médias (créer un souvenir)
        SliverToBoxAdapter(
          child: ImportMediaCta(onTap: () => _startCreateMemory(context)),
        ),

        // ── Commandes en cours ───────────────────────────────────────
        _ActiveOrdersBanner(uid: FirebaseAuth.instance.currentUser?.uid ?? ''),

        // 4) Mes derniers souvenirs (3, format polaroïde)
        if (_recentMemories.isNotEmpty) ...[
          _sectionHeader('Mes derniers souvenirs', ''),
          SliverToBoxAdapter(child: _recentMemoriesRail(context)),
        ],

        // 5) Mes carnets (même format) + bouton « + » à la fin
        if (isEmpty)
          const SliverToBoxAdapter(child: _EmptyState())
        else ...[
          if (allOwn.isNotEmpty) ...[
            _sectionHeader('Mes carnets',
                '${allOwn.length} carnet${allOwn.length > 1 ? 's' : ''}'),
            SliverToBoxAdapter(
              child: _carnetRail(context, allOwn, true,
                  onAdd: () => context.push('/notebook/create/template')),
            ),
          ],
          if (allShared.isNotEmpty) ...[
            _sectionHeader('Partagés avec moi', '${allShared.length}'),
            SliverToBoxAdapter(child: _carnetRail(context, allShared, false)),
          ],
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }

  // Rangée horizontale des 3 derniers souvenirs (format polaroïde partagé).
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
              onTap: () => context
                  .push('/notebook/${m.notebookId}/edit-memory/${m.id}'),
            ),
          );
        },
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

  // Carnets en livres sur une étagère (les uns après les autres).
  Widget _carnetRail(
      BuildContext context, List<NotebookModel> list, bool owner,
      {VoidCallback? onAdd}) {
    return BookShelfRail(
      books: [for (final n in list) _notebookBook(context, n, owner)],
      onAdd: onAdd,
    );
  }

  ShelfBook _notebookBook(
      BuildContext context, NotebookModel n, bool owner) {
    // Tous les carnets au même format (même hauteur / largeur).
    const h = 176.0;
    Color color;
    try {
      color =
          Color(int.parse('FF${n.coverColor.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      color = AppColors.sage;
    }
    return ShelfBook(
      coverUrl: n.coverPhotoUrl,
      coverColor: color,
      emoji: n.emoji,
      title: n.title,
      kind: n.subtitle,
      width: 104,
      height: h,
      tilt: 0.42,
      flag: owner ? null : 'partagé',
      onTap: () => context.go('/notebook/${n.id}/dashboard'),
      onLongPress: owner ? () => _confirmDeleteNotebook(context, n) : null,
    );
  }

  // ── Jauge d'espace (compteur discret dans le header) ───────────────────
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

  // Flux « importer des médias » : choisir le carnet cible → écran de création
  // qui ouvre directement la galerie (?import=1), puis l'utilisateur finalise
  // le formulaire (titre, description facultative, date, lieu).
  Future<void> _startCreateMemory(BuildContext context) async {
    final books = _ownNotebooks;
    if (books.isEmpty) {
      context.push('/notebook/create/template');
      return;
    }
    if (books.length == 1) {
      context.push('/notebook/${books.first.id}/add-memory?import=1');
      return;
    }
    final chosen = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _PickNotebookSheet(notebooks: books),
    );
    if (chosen != null && context.mounted) {
      context.push('/notebook/$chosen/add-memory?import=1');
    }
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

  Future<void> _confirmDeleteNotebook(
      BuildContext context, NotebookModel n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Supprimer ce carnet ?',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        content: Text(
            'Le carnet "${n.title}" et tous ses souvenirs seront supprimés.',
            style: const TextStyle(color: AppColors.textMedium, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok == true) {
      await PhotoService.deleteNotebookCascade(n.id);
    }
  }

  SliverToBoxAdapter _sectionHeader(String title, String count) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700,
                  color: AppColors.textMedium, letterSpacing: 1.2)),
              Text(count, style: const TextStyle(fontSize: 12, color: AppColors.textMedium)),
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

  @override
  Widget build(BuildContext context) {
    // Plus de FAB : le livre et la création de carnet ont leurs propres entrées
    // dans le corps du dashboard (bouton livre en haut, « + » sur l'étagère).
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildBody(context),
    );
  }
}

// ── Hero header ──────────────────────────────────────────────────────────────

// ── Barre du haut : logo + jauge d'espace + avatar ─────────────────────────
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
            // Logo repensé (terracotta) : badge plein + mot « Carnet » sur une
            // ligne, dans la police serif de la nouvelle identité.
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

// Anneau circulaire discret : usage max parmi photos/vidéos/vocaux.
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

// « Le livre » : bandeau cliquable menant à la page de création de livre.
class _CreateBookCta extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateBookCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 4),
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
                    Text('Transforme tes souvenirs en livre imprimé.',
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

// Carte carnet façon vignette (maquette terracotta).
class _CarnetCard extends StatelessWidget {
  final NotebookModel notebook;
  final int? count;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _CarnetCard({
    required this.notebook,
    required this.count,
    required this.onTap,
    this.onLongPress,
  });

  Color get _cover {
    try {
      return Color(
          int.parse('FF${notebook.coverColor.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return AppColors.sage;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = count ?? notebook.memoriesCount;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 142,
                width: 140,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (notebook.coverPhotoUrl != null &&
                        notebook.coverPhotoUrl!.isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: notebook.coverPhotoUrl!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _plain(),
                        errorWidget: (_, __, ___) => _plain(),
                      )
                    else
                      _plain(),
                    Positioned(
                      top: 9,
                      right: 9,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text('🖼 $c',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textDark)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(notebook.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 1),
            Text(notebook.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textMedium)),
          ],
        ),
      ),
    );
  }

  Widget _plain() => Container(
        color: _cover,
        alignment: Alignment.center,
        child: Text(notebook.emoji, style: const TextStyle(fontSize: 40)),
      );
}

class _NewCarnetCard extends StatelessWidget {
  final VoidCallback onTap;
  const _NewCarnetCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 130,
        height: 150,
        decoration: BoxDecoration(
          color: AppColors.cream,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.sage.withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 3)),
                ],
              ),
              child: const Icon(Icons.add, color: AppColors.sage, size: 22),
            ),
            const SizedBox(height: 9),
            const Text('Nouveau carnet',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.sage)),
          ],
        ),
      ),
    );
  }
}

// Sélecteur de carnet quand on crée un souvenir depuis l'accueil.
class _PickNotebookSheet extends StatelessWidget {
  final List<NotebookModel> notebooks;
  const _PickNotebookSheet({required this.notebooks});

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
            const Text('Dans quel carnet ?',
                style: TextStyle(
                    fontFamily: 'Fraunces',
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textDark)),
            const SizedBox(height: 4),
            const Text('Choisis où ranger ce souvenir.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textMedium)),
            const SizedBox(height: 14),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: notebooks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  final n = notebooks[i];
                  Color color;
                  try {
                    color = Color(int.parse(
                        'FF${n.coverColor.replaceAll('#', '')}',
                        radix: 16));
                  } catch (_) {
                    color = AppColors.sage;
                  }
                  return GestureDetector(
                    onTap: () => Navigator.pop(context, n.id),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border:
                            Border.all(color: AppColors.border, width: 0.5),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                                color: color,
                                borderRadius: BorderRadius.circular(11)),
                            child: Text(n.emoji,
                                style: const TextStyle(fontSize: 20)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(n.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textDark)),
                                Text(n.subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textMedium)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: AppColors.sage, size: 20),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Feuille « Mon espace » : compteurs discrets + alerte ciblée.
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
                                  fontSize: 12,
                                  color: AppColors.textMedium)),
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
                      child: const Text('Découvrir',
                          style: TextStyle(fontSize: 13)),
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

class _HeroHeader extends StatelessWidget {
  final String greeting;
  final int notebookCount;
  final int memoryCount;
  final QuotaStatus? quota;
  final QuotaStatus? videoQuota;
  final QuotaStatus? audioQuota;
  final String tier;
  final VoidCallback onProfile;
  final VoidCallback onSubscription;

  const _HeroHeader({
    required this.greeting,
    required this.notebookCount,
    required this.memoryCount,
    required this.quota,
    required this.videoQuota,
    required this.audioQuota,
    required this.tier,
    required this.onProfile,
    required this.onSubscription,
  });

  // Message d'alerte pour la 1re ressource proche de sa limite (photos →
  // vidéos → vocaux), ou null si tout va bien.
  String? _firstQuotaAlert() {
    final candidates = <(String, QuotaStatus?)>[
      ('photos', quota),
      ('vidéos', videoQuota),
      ('vocaux', audioQuota),
    ];
    for (final (label, q) in candidates) {
      if (q != null && q.nearLimit) {
        return q.isAtLimit
            ? 'Limite $label atteinte — Passer à Premium →'
            : '${q.remaining} $label restant${q.remaining > 1 ? 's' : ''} — Passer à Premium →';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Gradient wraps all content so the quota alert is never clipped
    return Container(
      decoration: const BoxDecoration(gradient: AppColors.heroGradient),
      child: Stack(
        children: [
          // Decorative circles (Positioned so they don't affect Stack size)
          Positioned(
            top: -60, right: -60,
            child: Container(
              width: 220, height: 220,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(0.07), width: 1.5),
              ),
            ),
          ),
          Positioned(
            top: -20, right: -20,
            child: Container(
              width: 130, height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.05),
              ),
            ),
          ),
          // Content determines the height of the whole widget
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top bar
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$greeting 👋',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.75),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Mes carnets',
                              style: TextStyle(
                                fontFamily: 'PlayfairDisplay',
                                fontSize: 30,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                height: 1.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: onProfile,
                        child: Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white.withOpacity(0.3)),
                          ),
                          child: const Icon(Icons.person_outline, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Stats chips
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _HeroChip(
                        icon: Icons.book_outlined,
                        label: '$notebookCount carnet${notebookCount != 1 ? 's' : ''}',
                      ),
                      _HeroChip(
                        icon: Icons.auto_stories_outlined,
                        label: '$memoryCount souvenir${memoryCount != 1 ? 's' : ''}',
                      ),
                      // Quotas affichés pour TOUS les paliers (premium inclus)
                      // pour que l'utilisateur voie toujours sa consommation.
                      if (quota != null)
                          GestureDetector(
                            onTap: onSubscription,
                            child: _HeroChip(
                              icon: Icons.photo_outlined,
                              label: '${quota!.current}/${quota!.limit} photos',
                              warn: quota!.nearLimit,
                            ),
                          ),
                        if (videoQuota != null)
                          GestureDetector(
                            onTap: onSubscription,
                            child: _HeroChip(
                              icon: Icons.videocam_outlined,
                              label:
                                  '${videoQuota!.current}/${videoQuota!.limit} vidéos',
                              warn: videoQuota!.nearLimit,
                            ),
                          ),
                        if (audioQuota != null)
                          GestureDetector(
                            onTap: onSubscription,
                            child: _HeroChip(
                              icon: Icons.mic_none_outlined,
                              label:
                                  '${audioQuota!.current}/${audioQuota!.limit} vocaux',
                              warn: audioQuota!.nearLimit,
                            ),
                          ),
                    ],
                  ),
                  // Alerte premium — pour la 1re ressource proche de sa limite.
                  if (tier == 'free') ...[
                    Builder(builder: (_) {
                      final alert = _firstQuotaAlert();
                      if (alert == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: GestureDetector(
                          onTap: onSubscription,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: Colors.white.withOpacity(0.25)),
                            ),
                            child: Row(children: [
                              const Icon(Icons.warning_amber_outlined,
                                  color: Colors.white, size: 14),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  alert,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      );
                    }),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool warn;
  const _HeroChip({required this.icon, required this.label, this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: warn
            ? Colors.orange.withOpacity(0.25)
            : Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: warn
              ? Colors.orange.withOpacity(0.5)
              : Colors.white.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white.withOpacity(0.9)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.9),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

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
              width: 90, height: 90,
              decoration: BoxDecoration(
                gradient: RadialGradient(colors: [
                  AppColors.sage.withOpacity(0.18),
                  AppColors.sage.withOpacity(0.04),
                ]),
                shape: BoxShape.circle,
              ),
              child: const Center(child: Text('📔', style: TextStyle(fontSize: 40))),
            ),
            const SizedBox(height: 22),
            const Text(
              'Ton premier carnet t\'attend',
              style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.textDark,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text(
              'Voyage, famille, enfant, grossesse…\nchaque histoire mérite d\'être racontée.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMedium, height: 1.6, fontSize: 14),
            ),
            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: () => context.push('/notebook/create/template'),
              child: const Text('Créer un carnet'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Notebook card ─────────────────────────────────────────────────────────────

class _NotebookCard extends StatelessWidget {
  final NotebookModel notebook;
  final bool isOwner;
  final int? memoryCount; // compte réel (null = pas encore chargé)
  const _NotebookCard(
      {required this.notebook, this.isOwner = true, this.memoryCount});

  Color get _cover {
    try {
      return Color(int.parse('FF${notebook.coverColor.replaceAll('#', '')}', radix: 16));
    } catch (_) { return AppColors.sage; }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Supprimer ce carnet ?',
          style: TextStyle(fontFamily: 'PlayfairDisplay', fontWeight: FontWeight.bold, color: AppColors.textDark)),
        content: Text('Le carnet "${notebook.title}" et tous ses souvenirs seront supprimés.',
          style: const TextStyle(color: AppColors.textMedium, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error, minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
            child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await PhotoService.deleteNotebookCascade(notebook.id);
  }

  String _lastActivity() {
    final last = notebook.lastMemoryAt;
    if (last == null) return 'Aucun souvenir';
    final days = DateTime.now().difference(last).inDays;
    if (days == 0) return "Aujourd'hui";
    if (days == 1) return 'Hier';
    if (days < 7) return 'Il y a $days jours';
    if (days < 30) return 'Il y a ${(days / 7).round()} sem.';
    if (days < 365) return 'Il y a ${(days / 30).round()} mois';
    return 'Il y a ${(days / 365).round()} an(s)';
  }

  String _typeLabel(String type) => switch (type) {
    'enfant' => 'Carnet enfant',
    'voyage' => 'Carnet voyage',
    'famille' => 'Gazette familiale',
    'grossesse' => 'Journal de grossesse',
    'scolaire' => 'Années scolaires',
    _ => 'Carnet',
  };

  @override
  Widget build(BuildContext context) {
    final color = _cover;
    return GestureDetector(
      onTap: () => context.go('/notebook/${notebook.id}/dashboard'),
      onLongPress: () => _confirmDelete(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10, offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            // Cover strip
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16), bottomLeft: Radius.circular(16)),
              child: notebook.coverPhotoUrl != null
                  ? CachedNetworkImage(
                      imageUrl: notebook.coverPhotoUrl!,
                      width: 85, height: 95, fit: BoxFit.cover,
                      placeholder: (_, __) => _Strip(color: color, emoji: notebook.emoji),
                      errorWidget: (_, __, ___) => _Strip(color: color, emoji: notebook.emoji),
                    )
                  : _Strip(color: color, emoji: notebook.emoji),
            ),
            const SizedBox(width: 14),
            // Info
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(notebook.title,
                          style: const TextStyle(
                            fontFamily: 'PlayfairDisplay', fontSize: 16,
                            fontWeight: FontWeight.bold, color: AppColors.textDark)),
                      ),
                      // Shared badge
                      if (!isOwner)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.sage.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.people_outline, size: 10, color: AppColors.sage),
                            SizedBox(width: 3),
                            Text('Partagé', style: TextStyle(fontSize: 10, color: AppColors.sage, fontWeight: FontWeight.w600)),
                          ]),
                        )
                      else if (notebook.isShared)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.sage.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.people_outline, size: 10, color: AppColors.sage),
                            const SizedBox(width: 3),
                            Text(
                              '${notebook.sharedWith.length + notebook.invitedEmails.length}',
                              style: const TextStyle(fontSize: 10, color: AppColors.sage, fontWeight: FontWeight.w600),
                            ),
                          ]),
                        ),
                    ]),
                    const SizedBox(height: 3),
                    Text(_typeLabel(notebook.type),
                      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(children: [
                      Icon(Icons.auto_stories_outlined, size: 13, color: AppColors.textMedium),
                      const SizedBox(width: 4),
                      Text('${memoryCount ?? notebook.memoriesCount} souvenir${(memoryCount ?? notebook.memoriesCount) != 1 ? 's' : ''}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textMedium)),
                      const SizedBox(width: 12),
                      Icon(Icons.access_time_outlined, size: 13, color: AppColors.textMedium),
                      const SizedBox(width: 4),
                      Text(_lastActivity(),
                        style: const TextStyle(fontSize: 12, color: AppColors.textMedium)),
                    ]),
                  ],
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.softGray, size: 20),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  final Color color;
  final String emoji;
  const _Strip({required this.color, required this.emoji});
  @override
  Widget build(BuildContext context) => Container(
    width: 85, height: 95,
    color: color.withOpacity(0.18),
    child: Center(child: Text(emoji, style: const TextStyle(fontSize: 38))),
  );
}

// ── Bannière commandes en cours ───────────────────────────────────────────────

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
                          '${active.length} commande${active.length > 1 ? 's' : ''} en cours',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: AppColors.textDark,
                          ),
                        ),
                        Text(
                          active.first.statusLabel,
                          style: const TextStyle(fontSize: 12, color: AppColors.textMedium),
                        ),
                      ],
                    ),
                  ),
                  const Text('Voir →',
                    style: TextStyle(color: AppColors.amber, fontWeight: FontWeight.w700, fontSize: 13)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
