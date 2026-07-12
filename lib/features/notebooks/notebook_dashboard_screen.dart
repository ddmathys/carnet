import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/notebook_model.dart';
import '../../core/models/memory_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/constants/notebook_types.dart';
import '../../core/services/user_service.dart';
import '../memories/widgets/memory_polaroid.dart';
import '../memories/widgets/import_media_cta.dart';
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

    return PopScope(
      canPop: false,
      // Touche « retour » du téléphone → revenir à la liste des carnets,
      // plutôt que de quitter / dépiler vers un écran inattendu.
      onPopInvoked: (didPop) {
        if (!didPop) context.go('/home');
      },
      child: Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        slivers: [
          _buildHeader(context),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // Même bouton d'ajout que le dashboard (importer des médias →
                // créer un souvenir), à la place de l'ancien FAB.
                const SizedBox(height: 16),
                ImportMediaCta(
                  padding: EdgeInsets.zero,
                  onTap: () => context
                      .push('/notebook/${notebook.id}/add-memory?import=1'),
                ),
                // CTA livre — génère un livre imprimé (le minimum d'impression
                // de 29 pages est rappelé sur la carte).
                if (total > 0) ...[
                  const SizedBox(height: 16),
                  _BookCta(count: total, notebookId: notebook.id),
                ],
                const SizedBox(height: 16),
                _buildSharedWith(context),
                const SizedBox(height: 20),
                if (memories.isNotEmpty) ...[
                  _MemoryTimeline(notebook: notebook, memories: memories),
                  const SizedBox(height: 20),
                ],
                // Accès courbe de croissance (enfant / carnet « Moi »).
                if (_showGrowth) ...[
                  _GrowthShortcut(notebook: notebook),
                  const SizedBox(height: 24),
                ],
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
                  // Derniers souvenirs en polaroïdes (rangée horizontale).
                  SizedBox(
                    height: 210,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: memories.take(3).length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (_, i) {
                        final m = memories[i];
                        return SizedBox(
                          width: 145,
                          child: MemoryPolaroid(
                            memory: m,
                            cat: _safeCat(m.type),
                            tilt: (i % 2 == 0) ? -0.02 : 0.02,
                            onTap: () => context.push(
                                '/notebook/${notebook.id}/edit-memory/${m.id}'),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // Carnets avec suivi de croissance (enfant / poids) → bouton courbe.
  bool get _showGrowth =>
      notebook.type == 'enfant' ||
      getNotebookTypeById(notebook.type).hasWeightTracking;

  MilestoneCategory? _safeCat(String type) {
    try {
      return getMilestoneCategoryById(type);
    } catch (_) {
      return null;
    }
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
            border: Border.all(color: AppColors.border, width: 0.5),
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
          border: Border.all(color: AppColors.border, width: 0.5),
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
        // Le livre en haut à droite (comme sur le dashboard).
        IconButton(
          icon: const Icon(Icons.menu_book_outlined, color: Colors.white),
          tooltip: 'Le livre',
          onPressed: () => context.push('/notebook/${notebook.id}/books'),
        ),
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
                    '$count souvenir${count > 1 ? 's' : ''} capturé${count > 1 ? 's' : ''}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDark,
                      fontSize: 15,
                    ),
                  ),
                  const Text(
                    'Attention : un livre fait au minimum 29 pages',
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

/// Ligne du temps horizontale : une ligne continue, des bulles alternées
/// au-dessus / au-dessous (photo du souvenir ou icône + date), défilable.
/// 1er tap sur une bulle = aperçu (bulle agrandie + carte titre/date/photo) ;
/// 2e tap sur la même bulle (ou tap sur la carte) = page « Modifier ».
class _MemoryTimeline extends StatefulWidget {
  final NotebookModel notebook;
  final List<MemoryModel> memories;
  const _MemoryTimeline({required this.notebook, required this.memories});

  @override
  State<_MemoryTimeline> createState() => _MemoryTimelineState();
}

class _MemoryTimelineState extends State<_MemoryTimeline> {
  String? _selectedId;

  void _onTap(MemoryModel m) {
    if (_selectedId == m.id) {
      // 2e clic sur la bulle déjà ouverte → page Modifier le souvenir.
      context.push('/notebook/${widget.notebook.id}/edit-memory/${m.id}');
    } else {
      setState(() => _selectedId = m.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ordre chronologique : le plus ancien à gauche, le plus récent à droite.
    final items = [...widget.memories]..sort((a, b) => a.date.compareTo(b.date));
    MemoryModel? selected;
    if (_selectedId != null) {
      for (final m in items) {
        if (m.id == _selectedId) {
          selected = m;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ligne du temps',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Touche un souvenir pour l\'aperçu, touche à nouveau pour le modifier.',
          style: TextStyle(fontSize: 12, color: AppColors.textMedium),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 184,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            itemBuilder: (_, i) => _TimelineBubble(
              memory: items[i],
              above: i.isEven,
              selected: items[i].id == _selectedId,
              onTap: () => _onTap(items[i]),
            ),
          ),
        ),
        if (selected != null)
          _TimelineDetailCard(
            memory: selected,
            onTap: () => context.push(
                '/notebook/${widget.notebook.id}/edit-memory/${selected!.id}'),
          ),
      ],
    );
  }
}

class _TimelineBubble extends StatelessWidget {
  final MemoryModel memory;
  final bool above;
  final bool selected;
  final VoidCallback onTap;
  const _TimelineBubble({
    required this.memory,
    required this.above,
    required this.selected,
    required this.onTap,
  });

  // Photo du souvenir (vignette de bulle), si disponible.
  String? get _photo {
    if (memory.photoUrl != null && memory.photoUrl!.isNotEmpty) {
      return memory.photoUrl;
    }
    if (memory.mediaUrls.isNotEmpty) return memory.mediaUrls.first;
    return null;
  }

  // Icône du type quand il n'y a pas de photo — jamais le livre : on remplace
  // l'emoji « anecdote » (📖) et les types inconnus par une étoile « souvenir ».
  String get _emoji {
    try {
      final e = getMilestoneCategoryById(memory.type).emoji;
      return e == '📖' ? '✨' : e;
    } catch (_) {
      return '✨';
    }
  }

  static const _line = AppColors.border;

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('d MMM', 'fr').format(memory.date);

    final bubble = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: above
            ? [_dateChip(dateLabel), const SizedBox(height: 4), _circle()]
            : [_circle(), const SizedBox(height: 4), _dateChip(dateLabel)],
      ),
    );

    const zone = 76.0;
    return SizedBox(
      width: 82,
      child: Column(
        children: [
          SizedBox(
            height: zone,
            child: above
                ? Align(alignment: Alignment.bottomCenter, child: bubble)
                : null,
          ),
          // Ligne continue + tige + nœud.
          SizedBox(
            height: 24,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 11,
                  child: Container(height: 2, color: _line),
                ),
                Align(
                  alignment:
                      above ? Alignment.topCenter : Alignment.bottomCenter,
                  child: Container(width: 2, height: 12, color: _line),
                ),
                Align(
                  alignment: Alignment.center,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.sage,
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: zone,
            child: !above
                ? Align(alignment: Alignment.topCenter, child: bubble)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _circle() {
    final size = selected ? 58.0 : 46.0;
    final photo = _photo;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.sage.withOpacity(0.12),
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? AppColors.sage : AppColors.sage.withOpacity(0.5),
          width: selected ? 2.5 : 1.5,
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: photo != null
          ? CachedNetworkImage(
              imageUrl: photo,
              fit: BoxFit.cover,
              placeholder: (_, __) =>
                  Container(color: AppColors.sage.withOpacity(0.12)),
              errorWidget: (_, __, ___) => Center(
                  child: Text(_emoji, style: TextStyle(fontSize: size * 0.45))),
            )
          : Center(
              child: Text(_emoji, style: TextStyle(fontSize: size * 0.45))),
    );
  }

  Widget _dateChip(String label) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 10,
        color: selected ? AppColors.sage : AppColors.textMedium,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Carte d'aperçu du souvenir sélectionné dans la ligne du temps : photo (si
/// présente), titre, date. Taper → page « Modifier le souvenir ».
class _TimelineDetailCard extends StatelessWidget {
  final MemoryModel memory;
  final VoidCallback onTap;
  const _TimelineDetailCard({required this.memory, required this.onTap});

  String? get _photo {
    if (memory.photoUrl != null && memory.photoUrl!.isNotEmpty) {
      return memory.photoUrl;
    }
    if (memory.mediaUrls.isNotEmpty) return memory.mediaUrls.first;
    return null;
  }

  String get _typeLabel {
    try {
      return getMilestoneCategoryById(memory.type).label;
    } catch (_) {
      return 'Souvenir';
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final title = (memory.title != null && memory.title!.isNotEmpty)
        ? memory.title!
        : _typeLabel;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.sage.withOpacity(0.4), width: 1),
          ),
          clipBehavior: Clip.hardEdge,
          child: Row(
            children: [
              if (photo != null)
                CachedNetworkImage(
                  imageUrl: photo,
                  width: 76,
                  height: 76,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      Container(width: 76, height: 76, color: AppColors.background),
                  errorWidget: (_, __, ___) => Container(
                    width: 76,
                    height: 76,
                    color: AppColors.background,
                    child: const Icon(Icons.image_outlined,
                        color: AppColors.softGray),
                  ),
                )
              else
                Container(
                  width: 76,
                  height: 76,
                  color: AppColors.sage.withOpacity(0.10),
                  child: const Icon(Icons.auto_awesome,
                      color: AppColors.sage, size: 26),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'PlayfairDisplay',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textDark,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        DateFormat('d MMMM yyyy', 'fr').format(memory.date),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textMedium),
                      ),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Row(
                  children: [
                    Text('Modifier',
                        style: TextStyle(
                            color: AppColors.sage,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    Icon(Icons.chevron_right, color: AppColors.sage, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Accès rapide à la courbe de croissance (enfant → courbes OMS ; carnet
// « Moi » → suivi de poids). Le journal a été retiré (doublon de « Voir tout »)
// et le livre est passé en haut à droite.
class _GrowthShortcut extends StatelessWidget {
  final NotebookModel notebook;
  const _GrowthShortcut({required this.notebook});

  @override
  Widget build(BuildContext context) {
    final isChild = notebook.type == 'enfant';
    return GestureDetector(
      onTap: () => context.push('/notebook/${notebook.id}/growth'),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border, width: 0.5),
        ),
        child: Row(
          children: [
            Text(isChild ? '📊' : '📈', style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isChild ? 'Courbes de croissance' : 'Suivi du poids',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textDark,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.softGray, size: 20),
          ],
        ),
      ),
    );
  }
}
