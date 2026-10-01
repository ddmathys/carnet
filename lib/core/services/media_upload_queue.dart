import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'draft_media_uploader.dart';
import 'photo_service.dart';
import 'audio_service.dart';
import 'video_service.dart';
import 'video_upload_lane.dart';

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
  // Envoi déjà démarré à la SÉLECTION (voir DraftMediaUploader), pas encore
  // fini au moment de `_save()` — parallèle à `localPhotos`/`localVideoPaths`
  // (même index, `null` = pas de ticket, upload frais comme avant). On
  // ATTEND ce même envoi plutôt que d'en lancer un second sur le même
  // fichier : sinon, un gros lot (ex. 19 vidéos) qui n'a pas fini pendant le
  // remplissage du formulaire verrait tout son travail jeté et relancé de
  // zéro dès qu'on appuie sur « Enregistrer ».
  final List<DraftUploadTicket?> photoTickets;
  final List<DraftUploadTicket?> videoTickets;

  /// Forme persistable du travail (voir MediaUploadQueue._persist).
  ///
  /// On ne garde que des CHEMINS : les `File` se reconstruisent, les
  /// `DraftUploadTicket` non — ils n'ont de sens que dans le processus qui les
  /// a créés. Un job restauré repart donc d'un envoi frais, exactement comme
  /// le repli déjà prévu quand un ticket a échoué.
  Map<String, dynamic> toJson() => {
        'memoryId': memoryId,
        'notebookId': notebookId,
        'localPhotos': [for (final f in localPhotos) f.path],
        'existingPhotoUrls': existingPhotoUrls,
        'removedPhotoUrls': removedPhotoUrls,
        'existingPhotoKeys': existingPhotoKeys,
        'removedPhotoKeys': removedPhotoKeys,
        'localAudioPath': localAudioPath,
        'existingAudioUrl': existingAudioUrl,
        'existingAudioKey': existingAudioKey,
        'audioRemoved': audioRemoved,
        'audioDurationMs': audioDurationMs,
        'localVideoPaths': localVideoPaths,
        'localVideoDurations': localVideoDurations,
        'existingVideoKeys': existingVideoKeys,
        'existingVideoDurations': existingVideoDurations,
        'removedVideoKeys': removedVideoKeys,
      };

  static MediaUploadJob fromJson(Map<String, dynamic> j) {
    List<String> strs(Object? v) => [
          for (final e in (v as List<dynamic>? ?? const []))
            if (e is String) e,
        ];
    return MediaUploadJob(
      memoryId: (j['memoryId'] as String?) ?? '',
      notebookId: (j['notebookId'] as String?) ?? '',
      localPhotos: [for (final p in strs(j['localPhotos'])) File(p)],
      existingPhotoUrls: strs(j['existingPhotoUrls']),
      removedPhotoUrls: strs(j['removedPhotoUrls']),
      existingPhotoKeys: strs(j['existingPhotoKeys']),
      removedPhotoKeys: strs(j['removedPhotoKeys']),
      localAudioPath: j['localAudioPath'] as String?,
      existingAudioUrl: j['existingAudioUrl'] as String?,
      existingAudioKey: j['existingAudioKey'] as String?,
      audioRemoved: j['audioRemoved'] == true,
      audioDurationMs: (j['audioDurationMs'] as num?)?.toInt(),
      localVideoPaths: strs(j['localVideoPaths']),
      localVideoDurations: [
        for (final e in (j['localVideoDurations'] as List<dynamic>? ?? const []))
          (e as num?)?.toInt(),
      ],
      existingVideoKeys: strs(j['existingVideoKeys']),
      existingVideoDurations: [
        for (final e in (j['existingVideoDurations'] as List<dynamic>? ?? const []))
          if (e is num) e.toInt(),
      ],
      removedVideoKeys: strs(j['removedVideoKeys']),
    );
  }

  /// Reste-t-il quelque chose à faire, et les fichiers locaux sont-ils encore
  /// là ? Un job restauré dont les fichiers ont disparu du cache de l'appareil
  /// n'est plus rattrapable.
  bool get hasLocalWork =>
      localPhotos.isNotEmpty ||
      localVideoPaths.isNotEmpty ||
      localAudioPath != null;

  /// Le même job, réduit aux fichiers qui existent encore sur l'appareil.
  MediaUploadJob prunedToExistingFiles() => MediaUploadJob(
        memoryId: memoryId,
        notebookId: notebookId,
        localPhotos: [for (final f in localPhotos) if (f.existsSync()) f],
        existingPhotoUrls: existingPhotoUrls,
        removedPhotoUrls: removedPhotoUrls,
        existingPhotoKeys: existingPhotoKeys,
        removedPhotoKeys: removedPhotoKeys,
        localAudioPath: (localAudioPath != null &&
                File(localAudioPath!).existsSync())
            ? localAudioPath
            : null,
        existingAudioUrl: existingAudioUrl,
        existingAudioKey: existingAudioKey,
        audioRemoved: audioRemoved,
        audioDurationMs: audioDurationMs,
        localVideoPaths: [
          for (final p in localVideoPaths) if (File(p).existsSync()) p
        ],
        localVideoDurations: [
          for (var i = 0; i < localVideoPaths.length; i++)
            if (File(localVideoPaths[i]).existsSync())
              (i < localVideoDurations.length ? localVideoDurations[i] : null),
        ],
        existingVideoKeys: existingVideoKeys,
        existingVideoDurations: existingVideoDurations,
        removedVideoKeys: removedVideoKeys,
      );

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
    this.photoTickets = const [],
    this.videoTickets = const [],
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
  /// Travaux en cours d'envoi, pour pouvoir les PERSISTER : avant, la file ne
  /// vivait qu'en mémoire — l'app tuée pendant un envoi (Android qui récupère
  /// la RAM sur une grosse vidéo, c'est le cas courant), le souvenir restait
  /// en base sans ses médias et il ne restait aucune trace du travail à faire
  /// (audit du 01.10.26).
  final List<MediaUploadJob> _inFlight = [];
  String? _lastError;

  /// Souvenirs dont les médias ne sont PLUS rattrapables : le travail avait
  /// bien été noté, mais les fichiers d'origine ont disparu du cache de
  /// l'appareil entre-temps. On le dit au lieu de l'effacer en silence.
  int _lostJobs = 0;

  // Progression du clip vidéo en cours d'envoi (le plus lourd des médias) :
  // fraction 0..1, index du clip et nombre total à envoyer. Alimente la barre
  // de progression de la bannière.
  double _videoProgress = 0;
  int _videoIndex = 0;
  int _videoTotal = 0;
  int _lastNotifiedPct = -1;

  // Progression des photos du lot en cours : nombre envoyé / total. Le PUT R2
  // ne fournit pas la progression octet-par-octet (contrairement à la vidéo),
  // on suit donc l'avancement au nombre de photos terminées.
  int _photoDone = 0;
  int _photoTotal = 0;

  /// Nombre d'uploads encore en cours.
  int get pending => _pending;

  /// Fraction envoyée du clip vidéo en cours (0..1), ou null si aucun clip.
  double? get videoProgress => _videoTotal > 0 ? _videoProgress : null;

  /// Clip vidéo en cours (1-based) et nombre total à envoyer dans le lot.
  int get videoIndex => _videoIndex;
  int get videoTotal => _videoTotal;

  /// Fraction des photos envoyées (0..1), ou null si aucune photo dans le lot.
  double? get photoProgress =>
      _photoTotal > 0 ? _photoDone / _photoTotal : null;

  /// Photos envoyées et nombre total à envoyer dans le lot.
  int get photoDone => _photoDone;
  int get photoTotal => _photoTotal;

  /// Travaux qui ont échoué (réseau coupé, etc.) et qu'on peut relancer.
  List<MediaUploadJob> get failed => List.unmodifiable(_failed);

  /// Cause du dernier échec, à montrer dans la bannière — un média qui ne part
  /// pas doit le dire, jamais disparaître en silence.
  String? get lastError => _lastError;

  /// Nombre de souvenirs dont les médias sont définitivement perdus (fichiers
  /// locaux disparus). Remis à zéro par [acknowledgeLost].
  int get lostJobs => _lostJobs;

  void acknowledgeLost() {
    if (_lostJobs == 0) return;
    _lostJobs = 0;
    notifyListeners();
  }

  void enqueue(MediaUploadJob job) {
    _pending++;
    _inFlight.add(job);
    _persist();
    notifyListeners();
    _run(job).whenComplete(() {
      _inFlight.remove(job);
      _persist();
    });
  }

  // ── Persistance ───────────────────────────────────────────────────────────

  static const _prefsKey = 'mediaUploadQueue.pending.v1';

  /// Écrit l'état de la file (en cours + échecs) sur le disque. Appelé à
  /// chaque changement : c'est ce qui permet de reprendre après une fermeture
  /// brutale de l'application.
  Future<void> _persist() async {
    try {
      final jobs = [..._inFlight, ..._failed];
      final prefs = await SharedPreferences.getInstance();
      if (jobs.isEmpty) {
        await prefs.remove(_prefsKey);
        return;
      }
      await prefs.setString(
        _prefsKey,
        jsonEncode([for (final j in jobs) j.toJson()]),
      );
    } catch (e) {
      // La persistance est un filet, pas le chemin critique : un échec ici ne
      // doit jamais empêcher l'envoi en cours.
      debugPrint('MediaUploadQueue: persistance impossible — $e');
    }
  }

  /// Reprend les envois notés avant la dernière fermeture de l'app. À appeler
  /// une fois l'utilisateur connecté (les uploads ont besoin de son jeton) —
  /// voir SplashScreen.
  Future<void> restorePending() async {
    if (_restored) return;
    _restored = true;
    List<MediaUploadJob> saved;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      saved = [
        for (final e in decoded)
          if (e is Map<String, dynamic>) MediaUploadJob.fromJson(e),
      ];
      // On libère tout de suite : les jobs repris sont re-persistés par
      // `enqueue`, et un JSON illisible ne doit pas rester coincé là.
      await prefs.remove(_prefsKey);
    } catch (e) {
      debugPrint('MediaUploadQueue: reprise impossible — $e');
      return;
    }

    var lost = 0;
    for (final job in saved) {
      if (job.memoryId.isEmpty) continue;
      final pruned = job.prunedToExistingFiles();
      if (!pruned.hasLocalWork) {
        // Les fichiers n'existent plus : rien à renvoyer. On le compte pour
        // pouvoir le DIRE (bannière), au lieu de perdre l'information.
        if (job.hasLocalWork) lost++;
        continue;
      }
      enqueue(pruned);
    }
    if (lost > 0) {
      _lostJobs += lost;
      _lastError =
          'Des médias n ont pas pu être envoyés : les fichiers ne sont plus '
          'sur l appareil. Rouvre le souvenir et rajoute-les.';
      notifyListeners();
    }
  }

  bool _restored = false;

  /// Relance tous les travaux échoués.
  void retryFailed() {
    final jobs = List<MediaUploadJob>.of(_failed);
    _failed.clear();
    _lastError = null;
    _lostJobs = 0;
    _persist();
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
      // On suit au passage le nombre de photos terminées pour la barre de
      // progression (le PUT R2 ne donne pas l'octet-par-octet). Future.wait
      // préserve l'ordre des résultats, l'alignement sur l'index reste bon.
      if (job.localPhotos.isNotEmpty) {
        _photoTotal = job.localPhotos.length;
        _photoDone = 0;
        notifyListeners();
      }
      final photoFuture = Future.wait(List.generate(job.localPhotos.length,
          (i) async {
        // Envoi déjà démarré à la sélection, pas encore fini : on ATTEND ce
        // même envoi au lieu d'en lancer un second sur le même fichier.
        final ticket =
            i < job.photoTickets.length ? job.photoTickets[i] : null;
        if (ticket != null) {
          await ticket.settled;
          if (ticket.key != null) {
            _photoDone++;
            notifyListeners();
            return ticket.key;
          }
          // Ticket en échec (ou annulé sans clé) → repli sur un envoi frais,
          // comme si aucun pré-envoi n'avait été tenté.
        }
        final key = await PhotoService.uploadMemoryPhotoToR2(
          photo: job.localPhotos[i],
          notebookId: job.notebookId,
        );
        _photoDone++;
        notifyListeners();
        return key;
      }));
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

        String? key;
        int? durationMs;
        final ticket =
            i < job.videoTickets.length ? job.videoTickets[i] : null;
        if (ticket != null) {
          // Envoi déjà démarré à la sélection (voir DraftMediaUploader), pas
          // encore fini : on ATTEND ce même envoi — sur le rail partagé
          // VideoUploadLane, il est peut-être même déjà en train de tourner
          // — au lieu d'en lancer un second en double sur le même fichier
          // (double compression/upload gâchés pour rien). On relaie sa
          // progression déjà en cours sur la bannière, pour ne pas la montrer
          // bloquée à 0 % pendant qu'on attend.
          void relay() {
            _videoProgress = ticket.progress;
            final pct = (_videoProgress * 100).floor();
            if (pct != _lastNotifiedPct) {
              _lastNotifiedPct = pct;
              notifyListeners();
            }
          }

          ticket.addListener(relay);
          relay();
          await ticket.settled;
          ticket.removeListener(relay);
          if (ticket.key != null) {
            key = ticket.key;
            durationMs = ticket.durationMs;
          }
          // Ticket en échec (ou annulé sans clé) → repli sur un envoi frais
          // ci-dessous, comme si aucun pré-envoi n'avait été tenté.
        }

        if (key == null) {
          _videoProgress = 0;
          notifyListeners();
          // Rail partagé avec `DraftMediaUploader` (upload dès la sélection,
          // avant même la sauvegarde) : garantit qu'un seul clip compresse à
          // la fois app-wide, pas seulement au sein de CETTE file.
          final r = await VideoUploadLane.instance.run(() =>
              VideoService.uploadMemoryVideo(
                video: File(job.localVideoPaths[i]),
                notebookId: job.notebookId,
                onProgress: (sent, total) {
                  if (total <= 0) return;
                  _videoProgress = sent / total;
                  // On ne rafraîchit qu'au changement de pourcent entier :
                  // sinon des milliers de notifications pour un gros fichier.
                  final pct = (_videoProgress * 100).floor();
                  if (pct != _lastNotifiedPct) {
                    _lastNotifiedPct = pct;
                    notifyListeners();
                  }
                },
              ));
          if (r != null) {
            key = r.key;
            durationMs = r.durationMs;
          }
        }

        final localDur =
            i < job.localVideoDurations.length ? job.localVideoDurations[i] : null;
        if (key == null) {
          // Upload échoué → on garde le chemin pour un réessai (sans doublon).
          failedVideoPaths.add(job.localVideoPaths[i]);
          failedVideoDurations.add(localDur);
          _lastError = VideoService.lastFailureReason ?? 'Échec de l\'envoi';
          continue;
        }
        videoKeys.add(key);
        final dur = durationMs ?? localDur;
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
      // Photos du lot terminées → on efface la progression (la bannière repasse
      // en indéterminé le temps de finir mémo/écriture Firestore).
      _photoTotal = 0;
      _photoDone = 0;
      notifyListeners();


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
        _persist();
      }
      return ok;
    } catch (e) {
      debugPrint('MediaUploadQueue: échec upload souvenir ${job.memoryId} — $e');
      _lastError = VideoService.lastFailureReason ?? 'Envoi interrompu';
      _failed.add(job);
      _persist();
      return false;
    } finally {
      // Envoi terminé (ou échoué) → on efface toute progression résiduelle.
      _videoTotal = 0;
      _videoIndex = 0;
      _videoProgress = 0;
      _photoTotal = 0;
      _photoDone = 0;
      _pending--;
      notifyListeners();
    }
  }
}
