import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/order_model.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/quota_service.dart';
import '../../core/services/order_service.dart';

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
    final totalMemories = _memCounts.isNotEmpty
        ? _memCounts.values.fold<int>(0, (s, c) => s + c)
        : [...allOwn, ...allShared].fold<int>(0, (s, n) => s + n.memoriesCount);
    final isEmpty = allOwn.isEmpty && allShared.isEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _HeroHeader(
            greeting: _greeting,
            notebookCount: allOwn.length + allShared.length,
            memoryCount: totalMemories,
            quota: _quota,
            videoQuota: _videoQuota,
            audioQuota: _audioQuota,
            tier: _tier,
            onProfile: () => context.push('/profile'),
            onSubscription: () => context.push('/subscription'),
          ),
        ),

        // ── Commandes en cours ───────────────────────────────────────
        _ActiveOrdersBanner(uid: FirebaseAuth.instance.currentUser?.uid ?? ''),

        if (isEmpty)
          const SliverFillRemaining(child: _EmptyState())
        else ...[
          // ── Mes carnets ──────────────────────────────────────────────
          if (allOwn.isNotEmpty) ...[
            _sectionHeader('Mes carnets', '${allOwn.length} carnet${allOwn.length > 1 ? 's' : ''}'),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _NotebookCard(
                      notebook: allOwn[i],
                      isOwner: true,
                      memoryCount: _memCounts[allOwn[i].id]),
                  childCount: allOwn.length,
                ),
              ),
            ),
          ],

          // ── Partagés avec moi ────────────────────────────────────────
          if (allShared.isNotEmpty) ...[
            _sectionHeader('Partagés avec moi', '${allShared.length}'),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _NotebookCard(
                      notebook: allShared[i],
                      isOwner: false,
                      memoryCount: _memCounts[allShared[i].id]),
                  childCount: allShared.length,
                ),
              ),
            ),
          ] else
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ],
    );
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
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _buildBody(context),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Secondary FAB: create book
          FloatingActionButton.extended(
            heroTag: 'book',
            onPressed: () => context.push('/book/select'),
            backgroundColor: AppColors.earth,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.menu_book_outlined, size: 20),
            label: const Text('Créer un livre',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            shape: const StadiumBorder(),
          ),
          const SizedBox(height: 10),
          // Primary FAB: new notebook
          FloatingActionButton.extended(
            heroTag: 'notebook',
            onPressed: () => context.push('/notebook/create/template'),
            icon: const Icon(Icons.add),
            label: const Text('Nouveau carnet'),
            shape: const StadiumBorder(),
          ),
        ],
      ),
    );
  }
}

// ── Hero header ──────────────────────────────────────────────────────────────

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
