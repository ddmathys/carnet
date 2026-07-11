import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/media_upload_queue.dart';
import '../../core/services/video_service.dart';

class MemoriesListScreen extends StatefulWidget {
  final String notebookId;
  final String? initialFilter;
  const MemoriesListScreen({super.key, required this.notebookId, this.initialFilter});

  @override
  State<MemoriesListScreen> createState() => _MemoriesListScreenState();
}

class _MemoriesListScreenState extends State<MemoriesListScreen> {
  String? _filterType;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _filterType = widget.initialFilter;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Journal',
          style: TextStyle(
            fontFamily: 'PlayfairDisplay',
            fontWeight: FontWeight.bold,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () =>
              context.go('/notebook/${widget.notebookId}/dashboard'),
        ),
      ),
      body: Column(
        children: [
          const _UploadStatusBanner(),
          Expanded(child: _buildMemoriesStream()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            context.push('/notebook/${widget.notebookId}/add-memory'),
        backgroundColor: AppColors.sage,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
        shape: const StadiumBorder(),
      ),
    );
  }

  Widget _buildMemoriesStream() {
    return StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', isEqualTo: widget.notebookId)
            .snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!.docs
              .map((d) => MemoryModel.fromFirestore(d))
              .toList()
            ..sort((a, b) => b.date.compareTo(a.date));

          final typeFiltered = _filterType == null
              ? all
              : all.where((m) => m.type == _filterType).toList();

          final filtered = _applySearch(typeFiltered);

          final types = all.map((m) => m.type).toSet().toList();

          return Column(
            children: [
              _buildSearchBar(),
              if (types.isNotEmpty) _buildFilterChips(types),
              if (all.length >= 10)
                _BookCta(count: all.length, notebookId: widget.notebookId),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyState(
                        hasSearch: _searchQuery.trim().isNotEmpty,
                        onClear: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _filterType = null;
                          });
                        },
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 20,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.66,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final m = filtered[i];
                          return _MemoryPolaroid(
                            memory: m,
                            cat: _safeCat(m.type),
                            tilt: (i % 2 == 0) ? -0.02 : 0.02,
                            onTap: () => context.push(
                                '/notebook/${widget.notebookId}/edit-memory/${m.id}'),
                            onLongPress: () => _confirmDeleteMemory(context, m),
                          );
                        },
                      ),
              ),
            ],
          );
        });
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _searchQuery = v),
        style: const TextStyle(fontSize: 14, color: AppColors.textDark),
        decoration: InputDecoration(
          hintText: 'Lieu (3 lettres min.) ou date…',
          hintStyle: const TextStyle(fontSize: 13, color: AppColors.softGray),
          prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.softGray),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18, color: AppColors.softGray),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: AppColors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: AppColors.sage, width: 1.5),
          ),
        ),
      ),
    );
  }

  // Strip accents and lowercase — "Genève" → "geneve", "île" → "ile"
  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[àáâãä]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôõö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll('ç', 'c')
      .replaceAll('ñ', 'n')
      .replaceAll('æ', 'ae')
      .replaceAll('œ', 'oe');

  List<MemoryModel> _applySearch(List<MemoryModel> memories) {
    final q = _norm(_searchQuery.trim());
    if (q.isEmpty) return memories;

    return memories.where((m) {
      if (_matchesDate(m, q)) return true;
      if (q.length >= 3) {
        if (_norm(m.location ?? '').contains(q)) return true;
      }
      return false;
    }).toList();
  }

  bool _matchesDate(MemoryModel m, String normalizedQ) {
    try {
      final d = m.date;
      final checks = [
        DateFormat('dd/MM/yyyy').format(d),
        DateFormat('dd/MM').format(d),
        DateFormat('MM/yyyy').format(d),
        DateFormat('yyyy').format(d),
        _norm(DateFormat('MMMM', 'fr').format(d)),
        _norm(DateFormat('MMMM yyyy', 'fr').format(d)),
      ];
      return checks.any((f) => f.contains(normalizedQ));
    } catch (_) {
      return false;
    }
  }

  Widget _buildFilterChips(List<String> types) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _FilterChip(
            label: 'Tous',
            selected: _filterType == null,
            onTap: () => setState(() => _filterType = null),
          ),
          ...types.map((t) {
            final cat = _safeCat(t);
            return _FilterChip(
              label: '${cat?.emoji ?? ''} ${cat?.label ?? t}',
              selected: _filterType == t,
              onTap: () => setState(
                  () => _filterType = _filterType == t ? null : t),
            );
          }),
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

  Future<void> _deleteMemory(MemoryModel memory) async {
    await PhotoService.deleteMemory(memory.id, memory.photoUrl, memory.mediaUrls,
        audioUrl: memory.audioUrl,
        videoKeys: memory.videoKeys,
        mediaKeys: memory.mediaKeys);
  }

  Future<void> _confirmDeleteMemory(
      BuildContext context, MemoryModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Supprimer ce souvenir ?',
            style: TextStyle(
                fontFamily: 'PlayfairDisplay',
                fontWeight: FontWeight.bold,
                color: AppColors.textDark)),
        content: const Text('Cette action est définitive.',
            style: TextStyle(color: AppColors.textMedium, height: 1.5)),
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
    if (ok == true) await _deleteMemory(m);
  }
}

/// Bannière discrète reflétant la file d'upload en arrière-plan :
/// « Envoi en cours… » avec un petit spinner pendant que les photos/mémos
/// partent, ou une bannière d'erreur avec « Réessayer » si un envoi a échoué.
/// Disparaît une fois tout terminé (la photo apparaît seule via le flux live).
class _UploadStatusBanner extends StatelessWidget {
  const _UploadStatusBanner();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: MediaUploadQueue.instance,
      builder: (context, _) {
        final q = MediaUploadQueue.instance;
        if (q.pending > 0) {
          final n = q.pending;
          return _strip(
            color: AppColors.sage.withOpacity(0.12),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.sage),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    n == 1
                        ? 'Envoi du souvenir en cours…'
                        : 'Envoi de $n souvenirs en cours…',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textMedium),
                  ),
                ),
              ],
            ),
          );
        }
        if (q.failed.isNotEmpty) {
          final n = q.failed.length;
          return _strip(
            color: AppColors.error.withOpacity(0.10),
            child: Row(
              children: [
                const Icon(Icons.cloud_off_outlined,
                    size: 16, color: AppColors.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    n == 1
                        ? 'Échec de l\'envoi des médias'
                        : 'Échec de l\'envoi de $n souvenirs',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.error),
                  ),
                ),
                TextButton(
                  onPressed: q.retryFailed,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Réessayer',
                      style: TextStyle(
                          color: AppColors.error,
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5)),
                ),
              ],
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _strip({required Color color, required Widget child}) => Container(
        width: double.infinity,
        color: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: child,
      );
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.sage : AppColors.white,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(
            color: selected ? AppColors.sage : AppColors.border,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.white : AppColors.textMedium,
          ),
        ),
      ),
    );
  }
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
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.amber.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Text('📖', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$count souvenirs — Générer le livre',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.amber,
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.amber, size: 18),
          ],
        ),
      ),
    );
  }
}

// Carte "polaroid" d'un souvenir (grille terracotta).
class _MemoryPolaroid extends StatelessWidget {
  final MemoryModel memory;
  final MilestoneCategory? cat;
  final double tilt;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _MemoryPolaroid({
    required this.memory,
    required this.cat,
    required this.tilt,
    required this.onTap,
    required this.onLongPress,
  });

  Widget _miniIcon(String e) => Container(
        width: 22,
        height: 22,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45), shape: BoxShape.circle),
        child: Text(e, style: const TextStyle(fontSize: 10)),
      );

  @override
  Widget build(BuildContext context) {
    final photoCount = memory.mediaKeys.isNotEmpty
        ? memory.mediaKeys.length
        : (memory.mediaUrls.isNotEmpty
            ? memory.mediaUrls.length
            : (memory.photoUrl != null && memory.photoUrl!.isNotEmpty ? 1 : 0));
    final hasPhoto = photoCount > 0;
    final title = (memory.title?.trim().isNotEmpty ?? false)
        ? memory.title!.trim()
        : (memory.rawContent.trim().isNotEmpty
            ? memory.rawContent.trim()
            : 'Souvenir');
    String date;
    try {
      date = DateFormat('d MMM', 'fr').format(memory.date).toUpperCase();
    } catch (_) {
      date = '';
    }
    final loc = memory.location?.trim() ?? '';
    final sub = loc.isNotEmpty ? '$date · ${loc.toUpperCase()}' : date;
    final hasVideo = memory.videoKeys.isNotEmpty;
    final hasAudio = memory.audioUrl != null && memory.audioUrl!.isNotEmpty;

    return Transform.rotate(
      angle: tilt,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 16,
                  offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (hasPhoto)
                        FutureBuilder<List<String>>(
                          future: PhotoService.resolvePhotoUrls(memory),
                          builder: (_, snap) {
                            final url = (snap.data?.isNotEmpty ?? false)
                                ? snap.data!.first
                                : null;
                            if (url == null) {
                              return Container(color: AppColors.sageTint);
                            }
                            return CachedNetworkImage(
                              imageUrl: url,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: AppColors.sageTint),
                              errorWidget: (_, __, ___) =>
                                  Container(color: AppColors.sageTint),
                            );
                          },
                        )
                      else
                        Container(
                          color: AppColors.sageTint,
                          alignment: Alignment.center,
                          child: Text(cat?.emoji ?? '📝',
                              style: const TextStyle(fontSize: 34)),
                        ),
                      if (cat != null)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Transform.rotate(
                            angle: -0.04,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.95),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(cat!.emoji,
                                      style: const TextStyle(fontSize: 11)),
                                  const SizedBox(width: 4),
                                  Text(cat!.label,
                                      style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textDark)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (hasVideo || hasAudio)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Row(
                            children: [
                              if (hasVideo) _miniIcon('🎬'),
                              if (hasAudio) ...[
                                const SizedBox(width: 4),
                                _miniIcon('🎙'),
                              ],
                            ],
                          ),
                        ),
                      if (hasPhoto)
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Text('$photoCount 📷',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontFamily: 'Fraunces',
                      fontStyle: FontStyle.italic,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textDark)),
              const SizedBox(height: 3),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 10,
                      letterSpacing: 0.5,
                      color: AppColors.textMedium)),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryTile extends StatelessWidget {
  final MemoryModel memory;
  final String notebookId;
  final VoidCallback onDelete;

  const _MemoryTile(
      {required this.memory,
      required this.notebookId,
      required this.onDelete});

  String get _typeLabel {
    try {
      final cat = getMilestoneCategoryById(memory.type);
      return '${cat.emoji} ${cat.label}';
    } catch (_) {
      return memory.type;
    }
  }

  List<String> get _allPhotos {
    final seen = <String>{};
    final result = <String>[];
    void add(String? url) {
      if (url != null && url.isNotEmpty && seen.add(url)) result.add(url);
    }
    add(memory.photoUrl);
    for (final u in memory.mediaUrls) { add(u); }
    return result;
  }

  /// Médias du souvenir dans l'ordre d'affichage : photos d'abord, puis vidéos.
  List<_MediaItem> get _allMedia => [
        for (final url in _allPhotos) _MediaItem.photo(url),
        for (final key in memory.videoKeys) _MediaItem.video(key),
      ];

  void _openMedia(BuildContext context, int index) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) => _MediaViewer(
            items: _allMedia, initialIndex: index, memoryId: memory.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = _allPhotos;
    final videoCount = memory.videoKeys.length;
    return Dismissible(
      key: Key(memory.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.error.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete_outline, color: AppColors.error),
      ),
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Supprimer ce souvenir ?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuler')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.error,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 10)),
              child: const Text('Supprimer'),
            ),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: GestureDetector(
        onTap: () => context
            .push('/notebook/$notebookId/edit-memory/${memory.id}'),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Vignette média — photos et/ou vidéos, tap = visualiseur plein écran
              if (photos.isNotEmpty)
                GestureDetector(
                  onTap: () => _openMedia(context, 0),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        child: CachedNetworkImage(
                          imageUrl: photos.first,
                          width: double.infinity,
                          height: 160,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => Container(
                            height: 160,
                            color: AppColors.background,
                            child: const Center(
                                child: CircularProgressIndicator(strokeWidth: 2)),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            height: 160,
                            color: AppColors.background,
                            child: const Center(
                                child: Icon(Icons.broken_image_outlined,
                                    color: AppColors.softGray)),
                          ),
                        ),
                      ),
                      if (photos.length > 1)
                        Positioned(
                          bottom: 8,
                          right: 8,
                          child: _MediaCountBadge(
                            icon: Icons.photo_library_outlined,
                            count: photos.length,
                          ),
                        ),
                      if (videoCount > 0)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _MediaCountBadge(
                            icon: Icons.play_circle_outline,
                            count: videoCount,
                          ),
                        ),
                    ],
                  ),
                )
              // Souvenir sans photo mais avec vidéo(s) : placeholder lisible
              else if (videoCount > 0)
                GestureDetector(
                  onTap: () => _openMedia(context, 0),
                  child: ClipRRect(
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(12)),
                    child: Container(
                      height: 160,
                      width: double.infinity,
                      color: const Color(0xFF2D2D2D),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.play_circle_outline,
                              color: Colors.white, size: 44),
                          const SizedBox(height: 6),
                          Text(
                            videoCount > 1
                                ? '$videoCount vidéos'
                                : '1 vidéo',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(14),
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
                                fontSize: 14,
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
                                const Icon(Icons.place_outlined, size: 12, color: AppColors.softGray),
                                const SizedBox(width: 3),
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
                            const SizedBox(height: 4),
                          ],
                          Text(
                            memory.rawContent,
                            style: const TextStyle(
                                color: AppColors.textDark,
                                fontSize: 14,
                                height: 1.4),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      DateFormat('d MMM\nyyyy', 'fr').format(memory.date),
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMedium,
                          height: 1.4),
                    ),
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

/// Un média d'un souvenir : photo (URL directe) ou vidéo (clé R2 à résoudre).
class _MediaItem {
  final bool isVideo;
  final String? photoUrl;
  final String? videoKey;
  const _MediaItem.photo(this.photoUrl)
      : isVideo = false,
        videoKey = null;
  const _MediaItem.video(this.videoKey)
      : isVideo = true,
        photoUrl = null;
}

/// Petite pastille « icône + nombre » (compteur photos ou vidéos sur la vignette).
class _MediaCountBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  const _MediaCountBadge({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text('$count',
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Visualiseur plein écran : photos (zoom) et vidéos (lecture inline) dans une
/// même galerie balayable. Les URLs vidéo sont reconstruites depuis les clés R2.
class _MediaViewer extends StatefulWidget {
  final List<_MediaItem> items;
  final int initialIndex;
  final String memoryId;
  const _MediaViewer(
      {required this.items,
      required this.initialIndex,
      required this.memoryId});

  @override
  State<_MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<_MediaViewer> {
  late final PageController _page;
  late int _current;
  // clé R2 → URL signée de lecture (absente = non autorisé / non résolu).
  Map<String, String> _videoUrls = {};
  bool _resolvingVideos = false;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _page = PageController(initialPage: widget.initialIndex);
    _resolveVideos();
  }

  Future<void> _resolveVideos() async {
    final hasVideo = widget.items.any((m) => m.isVideo && m.videoKey != null);
    if (!hasVideo) return;
    setState(() => _resolvingVideos = true);
    final urls = await VideoService.playbackUrls(widget.memoryId);
    if (!mounted) return;
    setState(() {
      _videoUrls = urls;
      _resolvingVideos = false;
    });
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Widget _buildPhoto(String url) => InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (_, __) => const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
            errorWidget: (_, __, ___) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 64,
            ),
          ),
        ),
      );

  Widget _buildVideo(_MediaItem item, bool active) {
    if (_resolvingVideos && !_videoUrls.containsKey(item.videoKey)) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    final url = _videoUrls[item.videoKey];
    if (url == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.white54, size: 56),
            SizedBox(height: 12),
            Text('Vidéo indisponible',
                style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
    return _VideoPage(url: url, active: active);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _page,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (_, i) {
              final item = widget.items[i];
              return item.isVideo
                  ? _buildVideo(item, _current == i)
                  : _buildPhoto(item.photoUrl!);
            },
          ),
          // Close button
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ),
          // Page dots (only if multiple media)
          if (widget.items.length > 1)
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.items.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: _current == i ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: _current == i ? Colors.white : Colors.white38,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lecteur vidéo inline (une page du visualiseur). Se met en pause dès qu'on
/// balaie vers un autre média (`active` passe à false).
class _VideoPage extends StatefulWidget {
  final String url;
  final bool active;
  const _VideoPage({required this.url, required this.active});

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() {
        _controller = c;
        _ready = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    // Pause automatique quand on quitte cette page du carrousel.
    if (old.active && !widget.active) _controller?.pause();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() => c.value.isPlaying ? c.pause() : c.play());
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return const Center(
        child: Icon(Icons.error_outline, color: Colors.white54, size: 56),
      );
    }
    final c = _controller;
    if (!_ready || c == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    final playing = c.value.isPlaying;
    return GestureDetector(
      onTap: _togglePlay,
      child: Center(
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(c),
              Align(
                alignment: Alignment.bottomCenter,
                child: VideoProgressIndicator(c, allowScrubbing: true),
              ),
              // Icône play visible à l'arrêt (tap n'importe où pour (re)lancer).
              if (!playing)
                Container(
                  decoration: const BoxDecoration(
                    color: Colors.black38,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(8),
                  child: const Icon(Icons.play_arrow,
                      color: Colors.white, size: 48),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasSearch;
  final VoidCallback onClear;
  const _EmptyState({required this.hasSearch, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔍', style: TextStyle(fontSize: 36)),
          const SizedBox(height: 12),
          Text(
            hasSearch
                ? 'Aucun souvenir trouvé.'
                : 'Aucun souvenir dans ce filtre.',
            style: const TextStyle(color: AppColors.textMedium),
          ),
          if (hasSearch) ...[
            const SizedBox(height: 4),
            const Text(
              'Essaie un lieu (3 lettres min.) ou une date\nex : Paris · 06/2025 · juin',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.softGray),
            ),
          ],
          const SizedBox(height: 12),
          TextButton(
            onPressed: onClear,
            child: const Text('Effacer la recherche',
                style: TextStyle(color: AppColors.sage)),
          ),
        ],
      ),
    );
  }
}
