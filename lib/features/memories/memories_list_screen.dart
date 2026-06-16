import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/media_upload_queue.dart';

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
                    : ListView.builder(
                        padding:
                            const EdgeInsets.fromLTRB(16, 8, 16, 100),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _MemoryTile(
                          memory: filtered[i],
                          notebookId: widget.notebookId,
                          onDelete: () => _deleteMemory(filtered[i]),
                        ),
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
            borderSide: const BorderSide(color: Color(0xFFDDD8CC), width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(50),
            borderSide: const BorderSide(color: Color(0xFFDDD8CC), width: 0.5),
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
        audioUrl: memory.audioUrl);
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
            color: selected ? AppColors.sage : const Color(0xFFDDD8CC),
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

  void _openPhotos(BuildContext context, int index) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        pageBuilder: (_, __, ___) =>
            _PhotoViewer(urls: _allPhotos, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = _allPhotos;
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
            border: Border.all(color: const Color(0xFFDDD8CC), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Photo thumbnail — tappable to open full-screen viewer
              if (photos.isNotEmpty)
                GestureDetector(
                  onTap: () => _openPhotos(context, 0),
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
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.photo_library_outlined,
                                    size: 12, color: Colors.white),
                                const SizedBox(width: 4),
                                Text(
                                  '${photos.length}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
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

class _PhotoViewer extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  const _PhotoViewer({required this.urls, required this.initialIndex});

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _page;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _page = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _page,
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: widget.urls[i],
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
            ),
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
          // Page dots (only if multiple photos)
          if (widget.urls.length > 1)
            Positioned(
              bottom: 28,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.urls.length,
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
