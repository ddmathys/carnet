import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/constants/milestone_types.dart';
import '../../core/models/memory_model.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/photo_service.dart';
import '../../core/services/video_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/media_fullscreen_viewer.dart';
import 'widgets/delete_memory.dart';

/// Vue LECTURE d'un souvenir : ce qu'on voit en tapant sur un polaroïd. La
/// méta (titre, date, lieu, description, tags) est compacte en haut ; les
/// médias — la raison d'être du souvenir — dominent en bas. « Modifier » ouvre
/// le formulaire d'édition. Avant, taper un souvenir ouvrait directement ce
/// formulaire : on ne pouvait pas juste le REGARDER.
class MemoryDetailScreen extends StatefulWidget {
  final String memoryId;
  const MemoryDetailScreen({super.key, required this.memoryId});

  @override
  State<MemoryDetailScreen> createState() => _MemoryDetailScreenState();
}

/// Un média affiché : photo (URL directe) ou vidéo (URL R2 signée, avec durée).
class _Media {
  final bool isVideo;
  final String? url; // null = vidéo non résolue (accès refusé / hors ligne)
  final int? durationMs;
  const _Media({required this.isVideo, this.url, this.durationMs});
}

class _MemoryDetailScreenState extends State<MemoryDetailScreen> {
  MemoryModel? _memory;
  List<_Media> _media = [];
  bool _loadingMedia = true;
  String? _audioUrl;
  bool _descExpanded = false;

  // Clé du dernier souvenir pour lequel on a résolu les médias : évite de
  // re-signer les URLs à chaque tick du flux Firestore (ex. un like distant).
  String _resolvedFor = '';

  final AudioPlayer _audio = AudioPlayer();
  bool _audioPlaying = false;
  StreamSubscription? _audioStateSub;

  @override
  void initState() {
    super.initState();
    _audioStateSub = _audio.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _audioPlaying = s == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _audioStateSub?.cancel();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _resolveMedia(MemoryModel m) async {
    // Signature clé du contenu média : si rien n'a changé, on ne re-signe pas.
    final sig = [
      ...m.mediaKeys,
      ...m.mediaUrls,
      m.photoUrl ?? '',
      ...m.videoKeys,
      m.audioKey ?? '',
      m.audioUrl ?? '',
    ].join('|');
    if (sig == _resolvedFor) return;
    _resolvedFor = sig;
    setState(() => _loadingMedia = true);

    // Photos (double-lecture R2/Firebase) puis vidéos (URLs signées membre only).
    final photos = await PhotoService.resolvePhotoUrls(m);
    final Map<String, String> videoUrls = m.videoKeys.isNotEmpty
        ? await VideoService.playbackUrls(m.id)
        : const {};

    final items = <_Media>[
      for (final u in photos) _Media(isVideo: false, url: u),
      for (var i = 0; i < m.videoKeys.length; i++)
        _Media(
          isVideo: true,
          url: videoUrls[m.videoKeys[i]],
          durationMs:
              i < m.videoDurationsMs.length ? m.videoDurationsMs[i] : null,
        ),
    ];

    // Mémo vocal : R2 (clé → URL signée) ou ancienne URL Firebase.
    String? audio;
    if (m.audioKey != null && m.audioKey!.isNotEmpty) {
      audio = await AudioService.signedAudioUrl(m.id);
    } else if (m.audioUrl != null && m.audioUrl!.isNotEmpty) {
      audio = m.audioUrl;
    }

    if (!mounted) return;
    setState(() {
      _media = items;
      _audioUrl = audio;
      _loadingMedia = false;
    });
  }

  Future<void> _toggleAudio() async {
    if (_audioUrl == null) return;
    if (_audioPlaying) {
      await _audio.pause();
    } else {
      await _audio.play(UrlSource(_audioUrl!));
    }
  }

  void _openViewer(int index) {
    final items = [
      for (final m in _media)
        m.isVideo
            ? FullscreenMedia.videoUrl(m.url)
            : FullscreenMedia.photoUrl(m.url!),
    ];
    if (items.isEmpty) return;
    MediaFullscreenViewer.open(context, items: items, initialIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('memories')
            .doc(widget.memoryId)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasData && !snap.data!.exists) {
            // Supprimé (depuis un autre écran / appareil) → on ressort.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) context.go('/home');
            });
            return const SizedBox.shrink();
          }
          if (!snap.hasData) {
            return const SafeArea(
                child: Center(child: CircularProgressIndicator()));
          }
          final m = MemoryModel.fromFirestore(snap.data!);
          _memory = m;
          // Résolution des médias hors du build (async).
          WidgetsBinding.instance.addPostFrameCallback((_) => _resolveMedia(m));

          return SafeArea(
            bottom: false,
            child: Column(
              children: [
                _appBar(m),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _meta(m),
                        const Divider(
                            height: 1, thickness: 1, color: AppColors.border,
                            indent: 22, endIndent: 22),
                        _mediaSection(),
                        if (_audioUrl != null) _voiceCard(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── App bar ────────────────────────────────────────────────────────────────

  Widget _appBar(MemoryModel m) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          _RoundIcon(
            icon: Icons.arrow_back_ios_new,
            onTap: () => context.canPop() ? context.pop() : context.go('/home'),
          ),
          const Spacer(),
          const Text('SOUVENIR',
              style: TextStyle(
                fontFamily: 'Outfit',
                fontWeight: FontWeight.w600,
                fontSize: 12,
                letterSpacing: 1.4,
                color: AppColors.textMedium,
              )),
          const Spacer(),
          _RoundIcon(
            icon: Icons.delete_outline,
            onTap: () async {
              final deleted = await confirmAndDeleteMemory(context, m);
              if (deleted && mounted) context.go('/home');
            },
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => context.push('/memory/${m.id}/edit'),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppColors.sageDark,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_outlined, color: Colors.white, size: 16),
                  SizedBox(width: 6),
                  Text('Modifier',
                      style: TextStyle(
                        fontFamily: 'Outfit',
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Méta ─────────────────────────────────────────────────────────────────

  Widget _meta(MemoryModel m) {
    final cat = _safeCat(m.type);
    final title = (m.title?.trim().isNotEmpty ?? false)
        ? m.title!.trim()
        : (cat?.label ?? 'Souvenir');
    final desc = m.rawContent.trim();
    final loc = m.location?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cat != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${cat.emoji}  ${cat.label.toUpperCase()}',
                  style: const TextStyle(
                    fontFamily: 'Outfit',
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    color: AppColors.sage,
                  )),
            ),
          Text(title,
              style: const TextStyle(
                fontFamily: 'Fraunces',
                fontWeight: FontWeight.w500,
                fontSize: 29,
                height: 1.1,
                color: AppColors.textDark,
              )),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(_dateLabel(m),
                  style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textMedium)),
              if (loc.isNotEmpty) ...[
                Container(
                  width: 3,
                  height: 3,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                      color: AppColors.sageLight, shape: BoxShape.circle),
                ),
                Flexible(
                  child: Text('📍 $loc',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textMedium)),
                ),
              ],
            ],
          ),
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              desc,
              maxLines: _descExpanded ? null : 2,
              overflow:
                  _descExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14.5, height: 1.55, color: Color(0xFF5B534C)),
            ),
            if (desc.length > 90)
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_descExpanded ? 'voir moins' : 'voir plus',
                      style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.sage)),
                ),
              ),
          ],
          if (m.tagLabels.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in m.tagLabels)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.sageTint,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(t,
                        style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontWeight: FontWeight.w600,
                            fontSize: 12.5,
                            color: AppColors.sage)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Médias ─────────────────────────────────────────────────────────────────

  Widget _mediaSection() {
    if (_loadingMedia) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_media.isEmpty) return const SizedBox(height: 8);

    final hero = _media.first;
    final rest = _media.skip(1).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                const Text('📸  Photos & vidéos',
                    style: TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.textDark)),
                const SizedBox(width: 8),
                Text('· ${_media.length}',
                    style: const TextStyle(
                        fontFamily: 'Outfit',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.textMedium)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _MediaTile(
            media: hero,
            aspectRatio: 4 / 3,
            radius: 20,
            onTap: () => _openViewer(0),
          ),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1,
              ),
              itemCount: rest.length,
              itemBuilder: (_, i) => _MediaTile(
                media: rest[i],
                aspectRatio: 1,
                radius: 18,
                onTap: () => _openViewer(i + 1),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Mémo vocal ─────────────────────────────────────────────────────────────

  Widget _voiceCard() {
    final dur = _memory?.audioDurationMs;
    return Container(
      margin: const EdgeInsets.fromLTRB(22, 20, 22, 8),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.white,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _toggleAudio,
            child: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                  color: AppColors.sageDark, shape: BoxShape.circle),
              child: Icon(_audioPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white, size: 22),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Container(
              height: 26,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: const LinearGradient(
                  colors: [AppColors.sageLight, AppColors.sageTint],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(_fmtDuration(dur),
              style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppColors.textMedium)),
        ],
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  MilestoneCategory? _safeCat(String type) {
    try {
      final c = getMilestoneCategoryById(type);
      // Pas de kicker pour « anecdote » (type par défaut, peu parlant) ni pour
      // un type inconnu (getMilestoneCategoryById retombe sur la dernière
      // catégorie — son id ne correspondrait alors pas au type demandé).
      if (c.id != type || c.id == 'anecdote') return null;
      return c;
    } catch (_) {
      return null;
    }
  }

  String _dateLabel(MemoryModel m) {
    if (m.dateLabel != null && m.dateLabel!.trim().isNotEmpty) {
      return m.dateLabel!.trim();
    }
    try {
      return DateFormat('d MMM yyyy', 'fr').format(m.date);
    } catch (_) {
      return DateFormat('d MMM yyyy').format(m.date);
    }
  }

  String _fmtDuration(int? ms) {
    if (ms == null || ms <= 0) return '';
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// Rond de 42px de l'app bar (retour / supprimer).
class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.03),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, size: 18, color: AppColors.textDark),
      ),
    );
  }
}

/// Une tuile média : photo ou vidéo (voile + ▶ + durée). Ouvre le plein écran.
class _MediaTile extends StatelessWidget {
  final _Media media;
  final double aspectRatio;
  final double radius;
  final VoidCallback onTap;
  const _MediaTile({
    required this.media,
    required this.aspectRatio,
    required this.radius,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (media.url != null && !media.isVideo)
                CachedNetworkImage(
                  imageUrl: media.url!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) =>
                      Container(color: AppColors.sageTint),
                  errorWidget: (_, __, ___) =>
                      Container(color: AppColors.sageTint),
                )
              else if (media.url != null && media.isVideo)
                CachedNetworkImage(
                  // Vignette : première image de la vidéo servie par R2. À défaut
                  // d'un thumbnail dédié, un fond neutre sous le voile ▶.
                  imageUrl: media.url!,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.black12),
                  errorWidget: (_, __, ___) => Container(color: Colors.black26),
                )
              else
                Container(color: AppColors.sageTint),
              if (media.isVideo) ...[
                Container(color: Colors.black.withOpacity(0.28)),
                const Center(
                  child: Icon(Icons.play_arrow, color: Colors.white, size: 30),
                ),
                if (_dur.isNotEmpty)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(_dur,
                          style: const TextStyle(
                              fontFamily: 'Outfit',
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              color: Colors.white)),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String get _dur {
    final ms = media.durationMs;
    if (ms == null || ms <= 0) return '';
    final s = (ms / 1000).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
