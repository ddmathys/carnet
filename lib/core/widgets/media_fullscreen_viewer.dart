import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Source d'un média à afficher en plein écran. Gère indifféremment les fichiers
/// locaux (pas encore uploadés) et les médias distants (URL publique). Une vidéo
/// distante non résolue (clé R2 sans URL) est représentée par [videoUrl] avec
/// [url] = null → affichée comme « indisponible ».
class FullscreenMedia {
  final bool isVideo;
  final bool isLocal;
  final String? path; // fichier local
  final String? url; // média distant

  const FullscreenMedia._({
    required this.isVideo,
    required this.isLocal,
    this.path,
    this.url,
  });

  factory FullscreenMedia.photoFile(File f) =>
      FullscreenMedia._(isVideo: false, isLocal: true, path: f.path);
  factory FullscreenMedia.photoUrl(String url) =>
      FullscreenMedia._(isVideo: false, isLocal: false, url: url);
  factory FullscreenMedia.videoFile(String path) =>
      FullscreenMedia._(isVideo: true, isLocal: true, path: path);
  factory FullscreenMedia.videoUrl(String? url) =>
      FullscreenMedia._(isVideo: true, isLocal: false, url: url);
}

/// Galerie plein écran balayable : photos (zoom pincé) et vidéos (lecture inline
/// avec pause auto au changement de page). Réutilisable depuis n'importe quel
/// écran — supporte fichiers locaux et URLs distantes.
class MediaFullscreenViewer extends StatefulWidget {
  final List<FullscreenMedia> items;
  final int initialIndex;
  const MediaFullscreenViewer({
    super.key,
    required this.items,
    this.initialIndex = 0,
  });

  /// Ouvre la galerie en plein écran (route modale).
  static Future<void> open(
    BuildContext context, {
    required List<FullscreenMedia> items,
    int initialIndex = 0,
  }) {
    if (items.isEmpty) return Future.value();
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            MediaFullscreenViewer(items: items, initialIndex: initialIndex),
      ),
    );
  }

  @override
  State<MediaFullscreenViewer> createState() => _MediaFullscreenViewerState();
}

class _MediaFullscreenViewerState extends State<MediaFullscreenViewer> {
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

  Widget _buildPhoto(FullscreenMedia m) => InteractiveViewer(
        minScale: 1,
        maxScale: 4,
        child: Center(
          child: m.isLocal
              ? Image.file(File(m.path!), fit: BoxFit.contain)
              : Image.network(
                  m.url!,
                  fit: BoxFit.contain,
                  loadingBuilder: (_, child, p) => p == null
                      ? child
                      : const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)),
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 64),
                ),
        ),
      );

  Widget _buildVideo(FullscreenMedia m, bool active) {
    if (!m.isLocal && m.url == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.white54, size: 56),
            SizedBox(height: 12),
            Text('Vidéo indisponible', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
    return _FsVideoPage(
      key: ValueKey(m.isLocal ? m.path : m.url),
      isLocal: m.isLocal,
      source: m.isLocal ? m.path! : m.url!,
      active: active,
    );
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
              final m = widget.items[i];
              return m.isVideo
                  ? _buildVideo(m, _current == i)
                  : _buildPhoto(m);
            },
          ),
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

/// Lecteur vidéo inline (une page de la galerie). Gère fichier local ou URL.
/// Se met en pause dès qu'on balaie vers un autre média ([active] → false).
class _FsVideoPage extends StatefulWidget {
  final bool isLocal;
  final String source;
  final bool active;
  const _FsVideoPage({
    super.key,
    required this.isLocal,
    required this.source,
    required this.active,
  });

  @override
  State<_FsVideoPage> createState() => _FsVideoPageState();
}

class _FsVideoPageState extends State<_FsVideoPage> {
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
      final c = widget.isLocal
          ? VideoPlayerController.file(File(widget.source))
          : VideoPlayerController.networkUrl(Uri.parse(widget.source));
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
      c.play();
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void didUpdateWidget(_FsVideoPage old) {
    super.didUpdateWidget(old);
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
