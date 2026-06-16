import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/generated_book_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/book_history_service.dart';
import '../../core/services/user_service.dart';
import 'share_notebook_sheet.dart';

class NotebookDashboardScreen extends StatelessWidget {
  final String notebookId;
  const NotebookDashboardScreen({super.key, required this.notebookId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('notebooks')
          .doc(notebookId)
          .snapshots(),
      builder: (context, nbSnap) {
        if (!nbSnap.hasData) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        if (!nbSnap.data!.exists) {
          return const Scaffold(
              body: Center(child: Text('Carnet introuvable.')));
        }
        final notebook = NotebookModel.fromFirestore(nbSnap.data!);

        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('memories')
              .where('notebookId', isEqualTo: notebookId)
              .snapshots(),
          builder: (context, memSnap) {
            final memories = <MemoryModel>[];
            if (memSnap.hasData) {
              memories.addAll(memSnap.data!.docs
                  .map((d) => MemoryModel.fromFirestore(d)));
              memories.sort((a, b) => b.date.compareTo(a.date));
            }
            return _DashboardBody(
                notebook: notebook, memories: memories);
          },
        );
      },
    );
  }
}

class _DashboardBody extends StatefulWidget {
  final NotebookModel notebook;
  final List<MemoryModel> memories;

  const _DashboardBody({required this.notebook, required this.memories});

  @override
  State<_DashboardBody> createState() => _DashboardBodyState();
}

class _DashboardBodyState extends State<_DashboardBody> {
  NotebookModel get notebook => widget.notebook;
  List<MemoryModel> get memories => widget.memories;

  // Initiales des collaborateurs (sharedWith) pour l'aperçu « Partagé avec ».
  List<String> _collabInitials = [];

  @override
  void initState() {
    super.initState();
    _loadCollabs();
  }

  @override
  void didUpdateWidget(covariant _DashboardBody old) {
    super.didUpdateWidget(old);
    // Recharge si la liste de partage a changé (quelqu'un a rejoint/été retiré).
    if (old.notebook.sharedWith.join(',') != notebook.sharedWith.join(',')) {
      _loadCollabs();
    }
  }

  Future<void> _loadCollabs() async {
    final uids = notebook.sharedWith;
    if (uids.isEmpty) {
      if (mounted) setState(() => _collabInitials = []);
      return;
    }
    final initials = await Future.wait(uids.map((uid) async {
      final data = await UserService.getUserInfo(uid);
      final label = (data?['displayName'] as String?)?.trim().isNotEmpty == true
          ? data!['displayName'] as String
          : (data?['email'] as String? ?? '?');
      return label.isNotEmpty ? label[0].toUpperCase() : '?';
    }));
    if (mounted) setState(() => _collabInitials = initials);
  }

  Color get _cover {
    try {
      return Color(int.parse(
          'FF${notebook.coverColor.replaceAll('#', '')}', radix: 16));
    } catch (_) {
      return AppColors.sage;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = memories.length;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildHeader(context),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Book CTA or progress
                if (total >= 10) ...[
                  const SizedBox(height: 16),
                  _BookCta(count: total, notebookId: notebook.id),
                ] else if (total > 0) ...[
                  const SizedBox(height: 16),
                  _BookProgressCta(count: total),
                ],
                const SizedBox(height: 16),
                _buildSharedWith(context),
                const SizedBox(height: 20),
                _StatsGrid(notebook: notebook, memories: memories),
                const SizedBox(height: 20),
                _ShortcutsRow(notebook: notebook),
                const SizedBox(height: 24),
                if (memories.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Derniers souvenirs',
                        style: TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                        ),
                      ),
                      TextButton(
                        onPressed: () => context
                            .push('/notebook/${notebook.id}/memories'),
                        child: const Text('Voir tout →',
                            style: TextStyle(
                                color: AppColors.sage, fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...memories
                      .take(3)
                      .map((m) => _MemoryPreviewTile(memory: m, notebookId: notebook.id)),
                ],
              ]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            context.push('/notebook/${notebook.id}/add-memory'),
        backgroundColor: AppColors.sage,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nouveau souvenir'),
        shape: const StadiumBorder(),
      ),
    );
  }

  // Ligne « Partagé avec · avatars +N » (tap → gestion). Si personne, propose
  // de partager. Les invitations en attente sont comptées à part.
  Widget _buildSharedWith(BuildContext context) {
    final shared = notebook.sharedWith.length;
    final pending = notebook.invitedEmails.length;

    if (shared == 0 && pending == 0) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showShareSheet(context),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
          ),
          child: Row(
            children: [
              const Icon(Icons.person_add_outlined, size: 18, color: AppColors.sage),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Partager ce carnet',
                    style: TextStyle(fontSize: 13, color: AppColors.textDark)),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.softGray),
            ],
          ),
        ),
      );
    }

    // Avatars (jusqu'à 4) + débordement
    const maxAvatars = 4;
    final shown = _collabInitials.take(maxAvatars).toList();
    final overflow = shared - shown.length;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showShareSheet(context),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
        ),
        child: Row(
          children: [
            if (shown.isNotEmpty)
              SizedBox(
                width: 24.0 + (shown.length - 1) * 16 + (overflow > 0 ? 16 : 0),
                height: 28,
                child: Stack(
                  children: [
                    for (int i = 0; i < shown.length; i++)
                      Positioned(left: i * 16.0, child: _Avatar(shown[i])),
                    if (overflow > 0)
                      Positioned(
                          left: shown.length * 16.0,
                          child: _Avatar('+$overflow', muted: true)),
                  ],
                ),
              )
            else
              const Icon(Icons.people_outline, size: 18, color: AppColors.sage),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _sharedLabel(shared, pending),
                style: const TextStyle(fontSize: 13, color: AppColors.textDark),
              ),
            ),
            const Text('Gérer',
                style: TextStyle(color: AppColors.sage, fontSize: 12, fontWeight: FontWeight.w600)),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.softGray),
          ],
        ),
      ),
    );
  }

  String _sharedLabel(int shared, int pending) {
    final parts = <String>[];
    if (shared > 0) parts.add('$shared personne${shared > 1 ? 's' : ''}');
    if (pending > 0) parts.add('$pending en attente');
    return 'Partagé avec ${parts.join(' · ')}';
  }

  void _showShareSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ShareNotebookSheet(notebook: notebook),
    );
  }

  void _showNotebookMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: AppColors.softGray.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: AppColors.sage),
              title: const Text('Modifier le carnet'),
              onTap: () {
                Navigator.pop(context);
                context.push('/notebook/${notebook.id}/edit');
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // Darken a color for gradient start
  Color _darkenColor(Color c, [double factor = 0.40]) => Color.fromRGBO(
    (c.red * (1 - factor)).round().clamp(0, 255),
    (c.green * (1 - factor)).round().clamp(0, 255),
    (c.blue * (1 - factor)).round().clamp(0, 255),
    1,
  );

  SliverAppBar _buildHeader(BuildContext context) {
    final coverDark = _darkenColor(_cover);
    final screenWidth = MediaQuery.of(context).size.width;
    final expandedHeight = screenWidth < 360 ? 200.0 : 220.0;
    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      backgroundColor: AppColors.sageDark,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => context.go('/home'),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.person_add_outlined, color: Colors.white),
          tooltip: 'Partager',
          onPressed: () => _showShareSheet(context),
        ),
        IconButton(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          onPressed: () => _showNotebookMenu(context),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          children: [
            // Gradient using notebook cover color
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [coverDark, _cover],
                ),
              ),
            ),
            // Decorative circles
            Positioned(
              top: -50, right: -50,
              child: Container(
                width: 200, height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.08), width: 1.5),
                ),
              ),
            ),
            Positioned(
              top: -20, right: -20,
              child: Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
            // Content
            Positioned(
              bottom: 20, left: 20, right: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Emoji / cover photo
                  if (notebook.coverPhotoUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: CachedNetworkImage(
                        imageUrl: notebook.coverPhotoUrl!,
                        width: 88, height: 88, fit: BoxFit.cover,
                        placeholder: (_, __) => _EmojiBox(color: _cover, emoji: notebook.emoji),
                        errorWidget: (_, __, ___) => _EmojiBox(color: _cover, emoji: notebook.emoji),
                      ),
                    )
                  else
                    _EmojiBox(color: _cover, emoji: notebook.emoji),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          notebook.title,
                          style: const TextStyle(
                            fontFamily: 'PlayfairDisplay',
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          notebook.subtitle,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ], // Column.children
                    ), // Column
                  ), // Expanded
                ], // Row.children
              ), // Row
            ), // Positioned (content)
          ], // Stack.children
        ), // Stack
      ), // FlexibleSpaceBar
    ); // SliverAppBar
  }

  // Helper for emoji box in dashboard header
}

class _Avatar extends StatelessWidget {
  final String label;
  final bool muted;
  const _Avatar(this.label, {this.muted = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(
        color: muted ? AppColors.background : AppColors.sage,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.white, width: 1.5),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            color: muted ? AppColors.textMedium : AppColors.white,
            fontSize: muted ? 10 : 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

class _EmojiBox extends StatelessWidget {
  final Color color;
  final String emoji;
  const _EmojiBox({required this.color, required this.emoji});
  @override
  Widget build(BuildContext context) => Container(
    width: 88, height: 88,
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.18),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
    ),
    child: Center(child: Text(emoji, style: const TextStyle(fontSize: 44))),
  );
}

class _BookCta extends StatelessWidget {
  final int count;
  final String notebookId;
  const _BookCta({required this.count, required this.notebookId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.push('/notebook/$notebookId/book'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.1),
          borderRadius: BorderRadius.circular(14),
          border:
              Border.all(color: AppColors.amber.withOpacity(0.4), width: 1),
        ),
        child: Row(
          children: [
            const Text('📖', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$count souvenirs capturés',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark,
                      fontSize: 15,
                    ),
                  ),
                  const Text(
                    'Ton livre est prêt à être généré',
                    style: TextStyle(
                        color: AppColors.textMedium, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Text(
              'Générer →',
              style: TextStyle(
                color: AppColors.amber,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookProgressCta extends StatelessWidget {
  final int count;
  const _BookProgressCta({required this.count});

  @override
  Widget build(BuildContext context) {
    final remaining = 10 - count;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.sage.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.sage.withOpacity(0.25), width: 1),
      ),
      child: Row(
        children: [
          const Text('📖', style: TextStyle(fontSize: 28)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count / 10 souvenirs',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDark,
                    fontSize: 15,
                  ),
                ),
                Text(
                  'Encore $remaining souvenir${remaining > 1 ? 's' : ''} pour créer ton livre',
                  style: const TextStyle(color: AppColors.textMedium, fontSize: 12),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: count / 10.0,
                    minHeight: 5,
                    backgroundColor: AppColors.softGray.withOpacity(0.3),
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.sage),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final NotebookModel notebook;
  final List<MemoryModel> memories;
  const _StatsGrid({required this.notebook, required this.memories});

  @override
  Widget build(BuildContext context) {
    final stats = _buildStats();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.6,
      ),
      itemCount: stats.length,
      itemBuilder: (_, i) {
        final s = stats[i];
        // La stat « Livres générés » est branchée sur le vrai compte.
        if (s.label == 'Livres générés') {
          return StreamBuilder<List<GeneratedBookModel>>(
            stream: BookHistoryService.streamForNotebook(notebook.id),
            builder: (_, snap) => _StatCard(
              stat: _Stat(s.label, '${snap.data?.length ?? 0}', s.emoji),
            ),
          );
        }
        return _StatCard(stat: s);
      },
    );
  }

  List<_Stat> _buildStats() {
    final total = memories.length;
    final lastDate = memories.isEmpty ? null : memories.first.date;
    final lastLabel = lastDate == null
        ? '—'
        : DateFormat('d MMM', 'fr').format(lastDate);

    switch (notebook.type) {
      case 'enfant':
        final measurements = memories
            .where((m) => m.type == 'taille_poids')
            .length;
        final anecdotes =
            memories.where((m) => m.type == 'anecdote').length;
        return [
          _Stat('Total', '$total', '📝'),
          _Stat('Mesures', '$measurements', '📏'),
          _Stat('Anecdotes', '$anecdotes', '💬'),
          _Stat('Dernière saisie', lastLabel, '🕒'),
        ];
      case 'voyage':
        final withPhoto =
            memories.where((m) => m.photoUrl != null).length;
        return [
          _Stat('Total', '$total', '📝'),
          _Stat('Photos', '$withPhoto', '📷'),
          _Stat('Dernière saisie', lastLabel, '🕒'),
          _Stat('Destination', notebook.destination ?? '—', '🌍'),
        ];
      case 'famille':
        return [
          _Stat('Total', '$total', '📝'),
          _Stat('Cette semaine',
              '${memories.where((m) => DateTime.now().difference(m.date).inDays < 7).length}',
              '📅'),
          _Stat('Dernière saisie', lastLabel, '🕒'),
          _Stat('Livres générés', '0', '📖'),
        ];
      default:
        return [
          _Stat('Total', '$total', '📝'),
          _Stat('Cette semaine',
              '${memories.where((m) => DateTime.now().difference(m.date).inDays < 7).length}',
              '📅'),
          _Stat('Dernière saisie', lastLabel, '🕒'),
          _Stat('Livres générés', '0', '📖'),
        ];
    }
  }
}

class _Stat {
  final String label;
  final String value;
  final String emoji;
  const _Stat(this.label, this.value, this.emoji);
}

class _StatCard extends StatelessWidget {
  final _Stat stat;
  const _StatCard({required this.stat});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(stat.emoji, style: const TextStyle(fontSize: 20)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stat.value,
                style: const TextStyle(
                  fontFamily: 'PlayfairDisplay',
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                stat.label,
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textMedium),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShortcutsRow extends StatelessWidget {
  final NotebookModel notebook;
  const _ShortcutsRow({required this.notebook});

  @override
  Widget build(BuildContext context) {
    final showGrowth = notebook.type == 'enfant';
    return Row(
      children: [
        _ShortcutBtn(
          emoji: '📔',
          label: 'Journal',
          onTap: () => context.push('/notebook/${notebook.id}/memories'),
        ),
        const SizedBox(width: 10),
        _ShortcutBtn(
          emoji: showGrowth ? '📊' : '📈',
          label: showGrowth ? 'Courbes' : 'Stats',
          onTap: showGrowth
              ? () => context.push('/notebook/${notebook.id}/growth')
              : null,
        ),
        const SizedBox(width: 10),
        _ShortcutBtn(
          emoji: '📖',
          label: 'Livre',
          onTap: () => context.push('/notebook/${notebook.id}/books'),
        ),
      ],
    );
  }
}

class _ShortcutBtn extends StatelessWidget {
  final String emoji;
  final String label;
  final VoidCallback? onTap;

  const _ShortcutBtn(
      {required this.emoji, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: active ? AppColors.white : AppColors.white.withOpacity(0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji,
                  style: TextStyle(
                      fontSize: 22,
                      color: active ? null : Colors.grey.shade400)),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? AppColors.textDark : Colors.grey.shade400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryPreviewTile extends StatelessWidget {
  final MemoryModel memory;
  final String notebookId;
  const _MemoryPreviewTile({required this.memory, required this.notebookId});

  String get _typeLabel {
    try {
      final cat = getMilestoneCategoryById(memory.type);
      return '${cat.emoji} ${cat.label}';
    } catch (_) {
      return memory.type;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = memory.photoUrl != null && memory.photoUrl!.isNotEmpty;
    return GestureDetector(
      onTap: () => context.push('/notebook/$notebookId/memories?filter=${memory.type}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (hasPhoto)
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
                child: CachedNetworkImage(
                  imageUrl: memory.photoUrl!,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                      width: 64, height: 64, color: AppColors.background),
                  errorWidget: (_, __, ___) => Container(
                      width: 64,
                      height: 64,
                      color: AppColors.background,
                      child: const Icon(Icons.broken_image_outlined,
                          color: AppColors.softGray, size: 20)),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _typeLabel,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.sage,
                            ),
                          ),
                          const SizedBox(height: 4),
                          if (memory.title != null && memory.title!.isNotEmpty) ...[
                            Text(
                              memory.title!,
                              style: const TextStyle(
                                fontFamily: 'PlayfairDisplay',
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textDark,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                          ],
                          if (memory.location != null && memory.location!.isNotEmpty) ...[
                            Row(
                              children: [
                                const Icon(Icons.place_outlined, size: 11, color: AppColors.softGray),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Text(
                                    memory.location!,
                                    style: const TextStyle(fontSize: 11, color: AppColors.softGray),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                          ],
                          Text(
                            memory.rawContent,
                            style: const TextStyle(
                                color: AppColors.textDark,
                                fontSize: 13,
                                height: 1.4),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      DateFormat('d MMM', 'fr').format(memory.date),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textMedium),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
