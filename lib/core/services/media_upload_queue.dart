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
  final List<String> existingPhotoUrls; // anciennes photos Firebase conservées
  final List<String> removedPhotoUrls;
  // Photos R2 (clés) : conservées à l'édition / à supprimer.
  final List<String> existingPhotoKeys;
  final List<String> removedPhotoKeys;
  final String? localAudioPath;
  final String? existingAudioUrl;
  final String? existingAudioKey; // mémo vocal R2 conservé (édition)
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
    this.existingPhotoKeys = const [],
    this.removedPhotoKeys = const [],
    required this.localAudioPath,
    required this.existingAudioUrl,
    this.existingAudioKey,
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
  String? _lastError;

  // Progression du clip vidéo en cours d'envoi (le plus lourd des médias) :
  // fraction 0..1, index du clip et nombre total à envoyer. Alimente la barre
  // de progression de la bannière.
  double _videoProgress = 0;
  int _videoIndex = 0;
  int _videoTotal = 0;
  int _lastNotifiedPct = -1;

  /// Nombre d'uploads encore en cours.
  int get pending => _pending;

  /// Fraction envoyée du clip vidéo en cours (0..1), ou null si aucun clip.
  double? get videoProgress => _videoTotal > 0 ? _videoProgress : null;

  /// Clip vidéo en cours (1-based) et nombre total à envoyer dans le lot.
  int get videoIndex => _videoIndex;
  int get videoTotal => _videoTotal;

  /// Travaux qui ont échoué (réseau coupé, etc.) et qu'on peut relancer.
  List<MediaUploadJob> get failed => List.unmodifiable(_failed);

  /// Cause du dernier échec, à montrer dans la bannière — un média qui ne part
  /// pas doit le dire, jamais disparaître en silence.
  String? get lastError => _lastError;

  void enqueue(MediaUploadJob job) {
    _pending++;
    notifyListeners();
    _run(job);
  }

  /// Comme [enqueue], mais attend la fin de l'envoi et dit si tout est
  /// parti (`true`) ou si au moins un média a échoué (`false`) — utilisé par
  /// l'écran de création pour garder le bouton "Enregistrer" indisponible
  /// tant que les photos/vidéos ne sont pas réellement envoyées, plutôt que
  /// de naviguer en supposant que ça a marché.
  Future<bool> runAndWait(MediaUploadJob job) {
    _pending++;
    notifyListeners();
    return _run(job);
  }

  /// Relance tous les travaux échoués.
  void retryFailed() {
    final jobs = List<MediaUploadJob>.of(_failed);
    _failed.clear();
    _lastError = null;
    notifyListeners();
    for (final j in jobs) {
      enqueue(j);
    }
  }

  Future<bool> _run(MediaUploadJob job) async {
    try {
      // Compression + upload des photos (vers R2, clés), un par un plutôt que
      // via PhotoService.uploadMultiplePhotosToR2 : on a besoin de savoir
      // PRÉCISÉMENT quel fichier a échoué (index aligné sur job.localPhotos)
      // pour pouvoir le remettre en file — un échec silencieux ici est
      // exactement le bug qui faisait disparaître des photos sans prévenir.
      final photoFuture = Future.wait(job.localPhotos.map(
        (f) => PhotoService.uploadMemoryPhotoToR2(
          photo: f,
          notebookId: job.notebookId,
        ),
      ));
      // Audio → R2 (clé). Nouveau mémo → upload ; sinon rien à uploader.
      final Future<String?> audioFuture = job.localAudioPath != null
          ? AudioService.uploadMemoryAudioToR2(
              audio: File(job.localAudioPath!),
              notebookId: job.notebookId,
            )
          : Future<String?>.value(null);

      // Suppression des médias retirés/remplacés (en parallèle des uploads).
      final deletions = <Future<void>>[
        ...job.removedPhotoUrls.map(PhotoService.deletePhotoByUrl),
        ...job.removedPhotoKeys.map(PhotoService.deletePhotoByKey),
        ...job.removedVideoKeys.map(VideoService.deleteVideoByKey),
      ];
      // Ancien mémo remplacé/retiré → on le supprime (URL Firebase OU clé R2).
      if (job.localAudioPath != null || job.audioRemoved) {
        if (job.existingAudioUrl != null) {
          deletions.add(AudioService.deleteAudioByUrl(job.existingAudioUrl));
        }
        if (job.existingAudioKey != null) {
          deletions.add(AudioService.deleteAudioByKey(job.existingAudioKey));
        }
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
      if (job.localVideoPaths.isNotEmpty) {
        _videoTotal = job.localVideoPaths.length;
      }
      for (var i = 0; i < job.localVideoPaths.length; i++) {
        _videoIndex = i + 1;
        _videoProgress = 0;
        _lastNotifiedPct = -1;
        notifyListeners();
        final r = await VideoService.uploadMemoryVideo(
          video: File(job.localVideoPaths[i]),
          notebookId: job.notebookId,
          onProgress: (sent, total) {
            if (total <= 0) return;
            _videoProgress = sent / total;
            // On ne rafraîchit qu'au changement de pourcent entier : sinon des
            // milliers de notifications pour un gros fichier.
            final pct = (_videoProgress * 100).floor();
            if (pct != _lastNotifiedPct) {
              _lastNotifiedPct = pct;
              notifyListeners();
            }
          },
        );
        final localDur =
            i < job.localVideoDurations.length ? job.localVideoDurations[i] : null;
        if (r == null) {
          // Upload échoué → on garde le chemin pour un réessai (sans doublon).
          failedVideoPaths.add(job.localVideoPaths[i]);
          failedVideoDurations.add(localDur);
          _lastError = VideoService.lastFailureReason ?? 'Échec de l\'envoi';
          continue;
        }
        videoKeys.add(r.key);
        final dur = r.durationMs ?? localDur;
        if (dur != null) videoDurationsMs.add(dur);
      }
      // Fin des vidéos de ce lot → on efface la progression (la bannière repasse
      // en indéterminé le temps de finir photos/mémo/écriture).
      _videoTotal = 0;
      _videoIndex = 0;
      _videoProgress = 0;
      notifyListeners();

      // Résultats alignés sur job.localPhotos : null = échec de CE fichier
      // précis (au lieu d'être simplement absent de la liste, comme avant).
      final photoResults = await photoFuture;
      final newKeys = photoResults.whereType<String>().toList();
      final failedPhotos = <File>[
        for (var i = 0; i < job.localPhotos.length; i++)
          if (photoResults[i] == null) job.localPhotos[i]
      ];
      if (failedPhotos.isNotEmpty) {
        _lastError = 'Échec de l\'envoi de ${failedPhotos.length} photo(s)';
      }

      final uploadedAudioKey = await audioFuture;
      // Le nouveau mémo a échoué → on garde l'ancien tel quel (ne PAS l'effacer
      // juste parce que le remplaçant n'est pas arrivé) et on remet le chemin
      // local en file pour réessai.
      final audioFailed = job.localAudioPath != null && uploadedAudioKey == null;
      if (audioFailed) _lastError = 'Échec de l\'envoi du mémo vocal';
      await Future.wait(deletions);

      // Audio final : nouveau (R2) ; sinon conservé (clé R2 ou ancienne URL) ;
      // sinon rien (retiré).
      final keepOldAudio =
          audioFailed || (job.localAudioPath == null && !job.audioRemoved);
      final finalAudioKey = (job.localAudioPath != null && !audioFailed)
          ? uploadedAudioKey
          : (keepOldAudio ? job.existingAudioKey : null);
      final finalAudioUrl = keepOldAudio ? job.existingAudioUrl : null;
      final hasAudio = finalAudioKey != null || finalAudioUrl != null;

      // Photos R2 : clés conservées + nouvelles. Les anciennes photos Firebase
      // (mediaUrls) sont préservées telles quelles → souvenir potentiellement
      // mixte, fusionné à l'affichage par PhotoService.resolvePhotoUrls.
      final allKeys = [...job.existingPhotoKeys, ...newKeys];
      final legacyUrls = job.existingPhotoUrls;
      await FirebaseFirestore.instance
          .collection('memories')
          .doc(job.memoryId)
          .update({
        'mediaKeys': allKeys,
        'mediaUrls': legacyUrls,
        'photoUrl': legacyUrls.isNotEmpty ? legacyUrls.first : null,
        'audioUrl': finalAudioUrl,
        'audioKey': finalAudioKey,
        'audioDurationMs': hasAudio ? job.audioDurationMs : null,
        'videoKeys': videoKeys,
        'videoDurationsMs': videoDurationsMs,
        // Miroir hérité (compat anciens lecteurs / page /watch d'origine).
        'videoKey': videoKeys.isNotEmpty ? videoKeys.first : null,
        'videoDurationMs':
            videoDurationsMs.isNotEmpty ? videoDurationsMs.first : null,
      });

      // Les URLs signées du souvenir ont changé (photos/mémo ajoutés ou retirés)
      // → on jette le cache, sinon l'écran continuerait d'afficher l'ancien lot.
      PhotoService.invalidateSignedCache(job.memoryId);
      AudioService.invalidateSignedCache(job.memoryId);

      // Échec partiel (photo, mémo et/ou vidéo) → on signale (bannière
      // « Réessayer ») en remettant en file UNIQUEMENT ce qui manque. Les
      // médias déjà sauvegardés (photos, audio, vidéos réussies) sont
      // préservés tels quels.
      final ok = failedPhotos.isEmpty && !audioFailed && failedVideoPaths.isEmpty;
      if (!ok) {
        _failed.add(MediaUploadJob(
          memoryId: job.memoryId,
          notebookId: job.notebookId,
          localPhotos: failedPhotos,
          existingPhotoUrls: legacyUrls,
          removedPhotoUrls: const [],
          existingPhotoKeys: allKeys,
          localAudioPath: audioFailed ? job.localAudioPath : null,
          existingAudioUrl: finalAudioUrl,
          existingAudioKey: finalAudioKey,
          audioRemoved: false,
          audioDurationMs: job.audioDurationMs,
          localVideoPaths: failedVideoPaths,
          localVideoDurations: failedVideoDurations,
          existingVideoKeys: videoKeys,
          existingVideoDurations: videoDurationsMs,
          removedVideoKeys: const [],
        ));
      }
      return ok;
    } catch (e) {
      debugPrint('MediaUploadQueue: échec upload souvenir ${job.memoryId} — $e');
      _lastError = VideoService.lastFailureReason ?? 'Envoi interrompu';
      _failed.add(job);
      return false;
    } finally {
      _pending--;
      notifyListeners();
    }
  }
}
