import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../../core/theme/app_theme.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/media_upload_queue.dart';
import '../../core/services/memory_query_service.dart';
import '../../core/services/tag_service.dart';
import '../../core/services/video_service.dart';
import '../tags/share_tag_sheet.dart';
import 'widgets/memory_polaroid.dart';

/// Tous les souvenirs visibles, filtrables par tag. Remplace le « journal »
/// d'un carnet : il n'y a plus qu'une seule collection de souvenirs, et les
/// tags en sont les rayons.
class MemoriesListScreen extends StatefulWidget {
  /// Tag pré-sélectionné (arrivée depuis une puce de tag du dashboard).
  final String? initialTagId;
  const MemoriesListScreen({super.key, this.initialTagId});

  @override
  State<MemoriesListScreen> createState() => _MemoriesListScreenState();
}

class _MemoriesListScreenState extends State<MemoriesListScreen> {
  String? _tagId;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  List<TagModel> _tags = [];
  StreamSubscription? _tagsSub;

  @override
  void initState() {
    super.initState();
    _tagId = widget.initialTagId;
    _tagsSub = TagService.streamMine().listen((tags) {
      if (mounted) setState(() => _tags = tags);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tagsSub?.cancel();
    super.dispose();
  }

  TagModel? get _currentTag {
    for (final t in _tags) {
      if (t.id == _tagId) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tag = _currentTag;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: Text(
          tag?.label ?? 'Mes souvenirs',
          style: const TextStyle(
            fontFamily: 'Fraunces',
            fontWeight: FontWeight.w600,
            color: AppColors.textDark,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textDark),
          onPressed: () => context.go('/home'),
        ),
        actions: [
          // Un tag « enfant » garde sa courbe de croissance.
          if (tag != null && tag.isChild)
            IconButton(
              icon: const Icon(Icons.show_chart, color: AppColors.textDark),
              tooltip: 'Croissance',
              onPressed: () => context.push('/growth/${tag.id}'),
            ),
          if (tag != null)
            IconButton(
              icon: const Icon(Icons.ios_share, color: AppColors.textDark),
              tooltip: 'Partager ce tag',
              onPressed: () => showShareTagSheet(context, tag),
            ),
        ],
      ),
      body: Column(
        children: [
          const _UploadStatusBanner(),
          Expanded(child: _buildMemoriesStream()),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(
            '/memory/new${_tagId != null ? '?tag=$_tagId' : ''}'),
        backgroundColor: AppColors.sage,
        foregroundColor: AppColors.white,
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
        shape: const StadiumBorder(),
      ),
    );
  }

  Widget _buildMemoriesStream() {
    return StreamBuilder<List<MemoryModel>>(
        stream: MemoryQueryService.visible(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!;
          final tagFiltered = _tagId == null
              ? all
              : all.where((m) => m.tagIds.contains(_tagId)).toList();
          final filtered = _applySearch(tagFiltered);

          return Column(
            children: [
              _buildSearchBar(),
              if (_tags.isNotEmpty) _buildTagChips(),
              if (tagFiltered.length >= 10)
                _BookCta(count: tagFiltered.length, tagId: _tagId),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyState(
                        hasSearch: _searchQuery.trim().isNotEmpty,
                        onClear: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                            _tagId = null;
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
                          return MemoryPolaroid(
                            memory: m,
                            cat: _safeCat(m.type),
                            tilt: (i % 2 == 0) ? -0.02 : 0.02,
                            onTap: () => context.push('/memory/${m.id}/edit'),
                            onLongPress: () => _confirmDeleteMemory(context, m),
                          );
                        },
                      ),
              ),
            ],
          );
        });
  }

  Widget _buildTagChips() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _FilterChip(
            label: 'Tous',
            selected: _tagId == null,
            onTap: () => setState(() => _tagId = null),
          ),
          ..._tags.map((t) => _FilterChip(
                label: t.label,
                selected: _tagId == t.id,
                onTap: () =>
                    setState(() => _tagId = _tagId == t.id ? null : t.id),
              )),
        ],
      ),
    );
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
        audioKey: memory.audioKey,
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
  final String? tagId;
  const _BookCta({required this.count, this.tagId});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context
          .push('/book/select${tagId != null ? '?tag=$tagId' : ''}'),
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
