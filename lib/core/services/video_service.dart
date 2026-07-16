import 'dart:convert';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:video_compress/video_compress.dart';
import '../config/app_config.dart';

/// Résultat d'un upload vidéo : la clé d'objet R2 (stockée dans Firestore) et
/// la durée détectée.
class VideoUploadResult {
  final String key;
  final int? durationMs;
  const VideoUploadResult({required this.key, this.durationMs});
}

/// Le fichier commence-t-il par une signature de conteneur vidéo ?
/// Dernier recours quand ni le type MIME ni l'extension ne tranchent : le
/// sélecteur Android renvoie parfois un fichier de cache au nom neutre, et une
/// vidéo prise pour une photo partirait en JPEG sur R2 — donc perdue.
Future<bool> fileLooksLikeVideo(File file) async {
  try {
    final head = await file.openRead(0, 12).fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    if (head.length < 12) return false;
    // ISO-BMFF (mp4, mov, 3gp, m4v) : « ftyp » en octets 4-7.
    if (head[4] == 0x66 &&
        head[5] == 0x74 &&
        head[6] == 0x79 &&
        head[7] == 0x70) {
      return true;
    }
    // Matroska / WebM : 1A 45 DF A3.
    if (head[0] == 0x1A &&
        head[1] == 0x45 &&
        head[2] == 0xDF &&
        head[3] == 0xA3) {
      return true;
    }
    // AVI : « RIFF » … « AVI  ».
    if (head[0] == 0x52 &&
        head[1] == 0x49 &&
        head[2] == 0x46 &&
        head[3] == 0x46 &&
        head[8] == 0x41 &&
        head[9] == 0x56 &&
        head[10] == 0x49) {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Upload de vidéos souvenir vers Cloudflare R2 (egress gratuit).
///
/// Flux (la clé secrète R2 reste sur le backend) :
///  1. compression 720p sur l'appareil (≈ ÷5 de la taille) ;
///  2. le backend signe une URL PUT temporaire (`/api/video/upload-url`) ;
///  3. l'app PUT directement le fichier sur R2 (ne transite pas par Vercel).
/// On ne stocke que la CLÉ d'objet.
///
/// Lecture : le bucket R2 est PRIVÉ. Pour visionner, l'app demande au backend
/// (`/api/video/play`) des URLs GET signées à durée courte — délivrées
/// uniquement si l'utilisateur est membre du carnet (cf. backend lib/access.ts).
class VideoService {
  /// Demande au backend les URLs de lecture signées pour les vidéos d'un
  /// souvenir. Retourne une map `cléR2 → URL signée` (vide si accès refusé ou
  /// erreur réseau). Seul l'appelant membre du carnet obtient des URLs.
  static Future<Map<String, String>> playbackUrls(String memoryId) async {
    if (memoryId.isEmpty) return const {};
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return const {};
    try {
      final res = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/video/play'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'memoryId': memoryId}),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        debugPrint('VideoService: play ${res.statusCode} ${res.body}');
        return const {};
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final keys = (data['keys'] as List<dynamic>).cast<String>();
      final urls = (data['urls'] as List<dynamic>).cast<String>();
      return {
        for (var i = 0; i < keys.length && i < urls.length; i++)
          keys[i]: urls[i]
      };
    } catch (e) {
      debugPrint('VideoService: play error — $e');
      return const {};
    }
  }

  /// Durée détectée d'une vidéo locale (ms), avant compression. Best-effort.
  static Future<int?> probeDurationMs(File video) async {
    try {
      final info = await VideoCompress.getMediaInfo(video.path);
      return info.duration?.round();
    } catch (_) {
      return null;
    }
  }

  /// Raison du dernier échec d'upload (affichée dans la bannière « Réessayer »).
  /// Sans elle, un clip qui ne part pas disparaît sans un mot.
  static String? lastFailureReason;

  /// PUT en FLUX vers R2 : le fichier est lu par morceaux depuis le disque. Une
  /// vidéo de plusieurs centaines de Mo chargée d'un bloc en mémoire faisait
  /// tomber l'app sur les téléphones modestes — et le clip était perdu sans
  /// message.
  static Future<int> _putFile(Uri url, File file, String contentType) async {
    final client = http.Client();
    try {
      final length = await file.length();
      final req = http.StreamedRequest('PUT', url)
        ..headers['Content-Type'] = contentType
        ..contentLength = length;
      file.openRead().listen(
            req.sink.add,
            onError: req.sink.addError,
            onDone: req.sink.close,
            cancelOnError: true,
          );
      // Timeout proportionnel à la taille : une vidéo de 800 Mo sur un réseau
      // mobile lent prend bien plus que 15 min. On laisse ~1 min par 15 Mo,
      // planché à 15 min et plafonné à 45 min pour ne pas pendre indéfiniment.
      final mb = length / (1024 * 1024);
      final minutes = (mb / 15).ceil().clamp(15, 45);
      final res =
          await client.send(req).timeout(Duration(minutes: minutes));
      await res.stream.drain<void>();
      return res.statusCode;
    } finally {
      client.close();
    }
  }

  static Future<VideoUploadResult?> uploadMemoryVideo({
    required File video,
    required String notebookId,
  }) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) {
      lastFailureReason = 'Session expirée';
      return null;
    }

    // 1. Compression 720p — MAIS pas au-dessus d'un certain poids. Le compresseur
    // natif (video_compress) charge/décode la vidéo et fait planter l'app sur les
    // très gros fichiers (une vidéo de 800 Mo saturait la mémoire → crash). Au
    // delà du seuil, on saute la compression et on envoie l'original tel quel :
    // l'upload est en flux (mémoire bornée), donc l'envoi, lui, ne plante pas.
    const int skipCompressionAbove = 180 * 1024 * 1024; // 180 Mo
    File toUpload = video;
    int? durationMs;
    int sizeBytes = 0;
    try {
      sizeBytes = await video.length();
    } catch (_) {}
    if (sizeBytes > 0 && sizeBytes <= skipCompressionAbove) {
      try {
        final info = await VideoCompress.compressVideo(
          video.path,
          quality: VideoQuality.Res1280x720Quality,
          deleteOrigin: false,
          includeAudio: true,
        );
        if (info != null && info.path != null) {
          toUpload = File(info.path!);
          durationMs = info.duration?.round();
        }
      } catch (e) {
        debugPrint('VideoService: compression échouée, upload original — $e');
      }
    } else {
      debugPrint(
          'VideoService: vidéo volumineuse (${(sizeBytes / (1024 * 1024)).round()} Mo) → envoi sans compression');
    }

    // 2. URL d'upload signée par le backend.
    try {
      final signRes = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/video/upload-url'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'notebookId': notebookId}),
          )
          .timeout(const Duration(seconds: 30));
      if (signRes.statusCode != 200) {
        debugPrint(
            'VideoService: upload-url ${signRes.statusCode} ${signRes.body}');
        lastFailureReason = 'Serveur indisponible (${signRes.statusCode})';
        return null;
      }
      final data = jsonDecode(signRes.body) as Map<String, dynamic>;
      final uploadUrl = data['uploadUrl'] as String?;
      final key = data['key'] as String?;
      final contentType = (data['contentType'] as String?) ?? 'video/mp4';
      if (uploadUrl == null || key == null) {
        lastFailureReason = 'Réponse du serveur incomplète';
        return null;
      }

      // 3. PUT direct vers R2. Le Content-Type doit correspondre à la signature.
      final status = await _putFile(Uri.parse(uploadUrl), toUpload, contentType);
      if (status != 200 && status != 201) {
        debugPrint('VideoService: PUT R2 $status');
        lastFailureReason = 'Envoi refusé par le stockage ($status)';
        return null;
      }

      lastFailureReason = null;
      return VideoUploadResult(key: key, durationMs: durationMs);
    } catch (e) {
      debugPrint('VideoService: upload error — $e');
      lastFailureReason = 'Connexion interrompue';
      return null;
    }
  }

  /// Supprime plusieurs vidéos R2 (en parallèle). Ignore les erreurs.
  static Future<void> deleteVideosByKeys(Iterable<String> keys) async {
    await Future.wait(keys.map(deleteVideoByKey));
  }

  /// Supprime une vidéo R2 via le backend. Ignore les erreurs silencieusement.
  static Future<void> deleteVideoByKey(String? key) async {
    if (key == null || key.isEmpty) return;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'key': key}),
      );
    } catch (_) {}
  }
}
