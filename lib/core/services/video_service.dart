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

  static Future<VideoUploadResult?> uploadMemoryVideo({
    required File video,
    required String notebookId,
  }) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return null;

    // 1. Compression 720p. En cas d'échec, on uploade le fichier original.
    File toUpload = video;
    int? durationMs;
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

    // 2. URL d'upload signée par le backend.
    final signRes = await http.post(
      Uri.parse('${AppConfig.backendUrl}/api/video/upload-url'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'notebookId': notebookId}),
    );
    if (signRes.statusCode != 200) {
      debugPrint('VideoService: upload-url ${signRes.statusCode} ${signRes.body}');
      return null;
    }
    final data = jsonDecode(signRes.body) as Map<String, dynamic>;
    final uploadUrl = data['uploadUrl'] as String?;
    final key = data['key'] as String?;
    final contentType = (data['contentType'] as String?) ?? 'video/mp4';
    if (uploadUrl == null || key == null) return null;

    // 3. PUT direct vers R2. Le Content-Type doit correspondre à la signature.
    final bytes = await toUpload.readAsBytes();
    final putRes = await http.put(
      Uri.parse(uploadUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );
    if (putRes.statusCode != 200 && putRes.statusCode != 201) {
      debugPrint('VideoService: PUT R2 ${putRes.statusCode}');
      return null;
    }

    return VideoUploadResult(key: key, durationMs: durationMs);
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
