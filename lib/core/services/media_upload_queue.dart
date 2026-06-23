import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'photo_service.dart';
import 'audio_service.dart';
import 'video_service.dart';

/// Un travail d'upload de médias pour un souvenir déjà écrit en base.
/// Immuable : peut être re-déclenché tel quel en cas d'échec (retry).
class MediaUploadJob {
  final String memoryId;
  final String notebookId;
  final List<File> localPhotos;
  final List<String> existingPhotoUrls;
  final List<String> removedPhotoUrls;
  final String? localAudioPath;
  final String? existingAudioUrl;
  final bool audioRemoved;
  final int? audioDurationMs;
  // Vidéos (multi). `existing*` = clips conservés, `removed*` = clips à supprimer
  // de R2, `local*` = nouveaux clips à compresser + uploader.
  final List<String> localVideoPaths;
  final List<int?> localVideoDurations;
  final List<String> existingVideoKeys;
  final List<int> existingVideoDurations;
  final List<String> removedVideoKeys;

  const MediaUploadJob({
    required this.memoryId,
    required this.notebookId,
    required this.localPhotos,
    required this.existingPhotoUrls,
    required this.removedPhotoUrls,
    required this.localAudioPath,
    required this.existingAudioUrl,
    required this.audioRemoved,
    required this.audioDurationMs,
    this.localVideoPaths = const [],
    this.localVideoDurations = const [],
    this.existingVideoKeys = const [],
    this.existingVideoDurations = const [],
    this.removedVideoKeys = const [],
  });
}

/// File d'upload « façon WhatsApp » : le souvenir (texte) est écrit en base et
/// affiché immédiatement ; photos et mémo vocal partent en arrière-plan, puis le
/// document Firestore est complété avec leurs URLs. Comme la liste écoute le
/// flux Firestore en temps réel, les photos apparaissent toutes seules une fois
/// l'upload terminé — aucun rafraîchissement manuel nécessaire.
///
/// Singleton (survit à la destruction de l'écran de création). Expose un
/// [ChangeNotifier] pour qu'une bannière discrète suive l'avancement.
class MediaUploadQueue extends ChangeNotifier {
  MediaUploadQueue._();
  static final MediaUploadQueue instance = MediaUploadQueue._();

  int _pending = 0;
  final List<MediaUploadJob> _failed = [];

  /// Nombre d'uploads encore en cours.
  int get pending => _pending;

  /// Travaux qui ont échoué (réseau coupé, etc.) et qu'on peut relancer.
  List<MediaUploadJob> get failed => List.unmodifiable(_failed);

  void enqueue(MediaUploadJob job) {
    _pending++;
    notifyListeners();
    _run(job);
  }

  /// Relance tous les travaux échoués.
  void retryFailed() {
    final jobs = List<MediaUploadJob>.of(_failed);
    _failed.clear();
    notifyListeners();
    for (final j in jobs) {
      enqueue(j);
    }
  }

  Future<void> _run(MediaUploadJob job) async {
    try {
      // Compression + upload des photos ET du mémo vocal en parallèle.
      final photoFuture = PhotoService.uploadMultiplePhotos(
        photos: job.localPhotos,
        notebookId: job.notebookId,
      );
      final Future<String?> audioFuture = job.localAudioPath != null
          ? AudioService.uploadMemoryAudio(
              audio: File(job.localAudioPath!),
              notebookId: job.notebookId,
            )
          : Future<String?>.value(
              job.audioRemoved ? null : job.existingAudioUrl);

      // Suppression des médias retirés/remplacés (en parallèle des uploads).
      final deletions = <Future<void>>[
        ...job.removedPhotoUrls.map(PhotoService.deletePhotoByUrl),
        ...job.removedVideoKeys.map(VideoService.deleteVideoByKey),
      ];
      if (job.existingAudioUrl != null &&
          (job.localAudioPath != null || job.audioRemoved)) {
        deletions.add(AudioService.deleteAudioByUrl(job.existingAudioUrl));
      }

      // Upload des nouvelles vidéos SÉQUENTIELLEMENT. `video_compress` ne gère
      // qu'UNE session de compression globale à la fois : compresser plusieurs
      // vidéos en parallèle fait échouer toutes les compressions concurrentes
      // (les clips ne seraient alors pas sauvegardés). Les photos et l'audio,
      // eux, continuent leur upload en parallèle pendant ce temps.
      // Clés vidéo finales : conservées + nouvelles (uploads réussis), durées
      // alignées. On retient les clips échoués pour les remettre en file ensuite.
      final videoKeys = <String>[...job.existingVideoKeys];
      final videoDurationsMs = <int>[...job.existingVideoDurations];
      final failedVideoPaths = <String>[];
      final failedVideoDurations = <int?>[];
      for (var i = 0; i < job.localVideoPaths.length; i++) {
        final r = await VideoService.uploadMemoryVideo(
          video: File(job.localVideoPaths[i]),
          notebookId: job.notebookId,
        );
        final localDur =
            i < job.localVideoDurations.length ? job.localVideoDurations[i] : null;
        if (r == null) {
          // Upload échoué → on garde le chemin pour un réessai (sans doublon).
          failedVideoPaths.add(job.localVideoPaths[i]);
          failedVideoDurations.add(localDur);
          continue;
        }
        videoKeys.add(r.key);
        final dur = r.durationMs ?? localDur;
        if (dur != null) videoDurationsMs.add(dur);
      }

      final newUrls = await photoFuture;
      final audioUrl = await audioFuture;
      await Future.wait(deletions);

      final allUrls = [...job.existingPhotoUrls, ...newUrls];
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(job.memoryId)
          .update({
        'mediaUrls': allUrls,
        'photoUrl': allUrls.isNotEmpty ? allUrls.first : null,
        'audioUrl': audioUrl,
        'audioDurationMs': audioUrl != null ? job.audioDurationMs : null,
        'videoKeys': videoKeys,
        'videoDurationsMs': videoDurationsMs,
        // Miroir hérité (compat anciens lecteurs / page /watch d'origine).
        'videoKey': videoKeys.isNotEmpty ? videoKeys.first : null,
        'videoDurationMs':
            videoDurationsMs.isNotEmpty ? videoDurationsMs.first : null,
      });

      // Échec partiel d'upload vidéo → on signale (bannière « Réessayer ») en
      // remettant en file UNIQUEMENT les clips manquants. Les médias déjà
      // sauvegardés (photos, audio, vidéos réussies) sont préservés tels quels.
      if (failedVideoPaths.isNotEmpty) {
        _failed.add(MediaUploadJob(
          memoryId: job.memoryId,
          notebookId: job.notebookId,
          localPhotos: const [],
          existingPhotoUrls: allUrls,
          removedPhotoUrls: const [],
          localAudioPath: null,
          existingAudioUrl: audioUrl,
          audioRemoved: false,
          audioDurationMs: job.audioDurationMs,
          localVideoPaths: failedVideoPaths,
          localVideoDurations: failedVideoDurations,
          existingVideoKeys: videoKeys,
          existingVideoDurations: videoDurationsMs,
          removedVideoKeys: const [],
        ));
      }
    } catch (e) {
      debugPrint('MediaUploadQueue: échec upload souvenir ${job.memoryId} — $e');
      _failed.add(job);
    } finally {
      _pending--;
      notifyListeners();
    }
  }
}
