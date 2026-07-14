import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../models/memory_model.dart';
import 'audio_service.dart';
import 'video_service.dart';

class PhotoService {
  static final _storage = FirebaseStorage.instance;
  static final _firestore = FirebaseFirestore.instance;

  // Compression cible : ~2048 px sur le grand côté, qualité 85. Une photo de
  // téléphone (4000 px, ~5 Mo) tombe à ~2048 px / ~400–700 Ko — assez pour une
  // impression demi-page à 300 DPI, et 5–10× plus rapide à uploader.
  static const int _maxDimension = 2048;
  static const int _jpegQuality = 85;

  // Plus AUCUN upload vers Firebase Storage : tout part sur R2 (bucket privé,
  // URLs signées courtes). Firebase Storage n'est plus lu que le temps que la
  // migration ait fini de rapatrier les anciens médias, et supprimé derrière.

  /// Compress to JPEG. Returns null on failure so the caller can fall back to
  /// uploading the original untouched.
  static Future<Uint8List?> _compress(File photo) async {
    try {
      return await FlutterImageCompress.compressWithFile(
        photo.absolute.path,
        minWidth: _maxDimension,
        minHeight: _maxDimension,
        quality: _jpegQuality,
        format: CompressFormat.jpeg,
      );
    } catch (_) {
      return null;
    }
  }

  // ── R2 : bucket privé + URLs signées temporaires (comme les vidéos) ──────

  /// Upload une photo vers R2 via une URL PUT signée par le backend. Retourne
  /// la CLÉ d'objet (à stocker dans `mediaKeys`), ou null en cas d'échec.
  static Future<String?> uploadMemoryPhotoToR2({
    required File photo,
    required String notebookId,
  }) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return null;
    final signRes = await http.post(
      Uri.parse('${AppConfig.backendUrl}/api/video/photo-upload-url'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'notebookId': notebookId}),
    );
    if (signRes.statusCode != 200) return null;
    final data = jsonDecode(signRes.body) as Map<String, dynamic>;
    final uploadUrl = data['uploadUrl'] as String?;
    final key = data['key'] as String?;
    final contentType = (data['contentType'] as String?) ?? 'image/jpeg';
    if (uploadUrl == null || key == null) return null;
    final bytes = await _compress(photo) ?? await photo.readAsBytes();
    final putRes = await http.put(Uri.parse(uploadUrl),
        headers: {'Content-Type': contentType}, body: bytes);
    if (putRes.statusCode != 200 && putRes.statusCode != 201) return null;
    return key;
  }

  /// Upload plusieurs photos vers R2 (parallèle). Retourne les clés réussies.
  static Future<List<String>> uploadMultiplePhotosToR2({
    required List<File> photos,
    required String notebookId,
  }) async {
    final results = await Future.wait(photos
        .map((f) => uploadMemoryPhotoToR2(photo: f, notebookId: notebookId)));
    return results.whereType<String>().toList();
  }

  // Cache d'URLs signées par souvenir (évite un aller-retour à chaque affichage
  // dans la même session ; les URLs sont valables ~1 h).
  static final Map<String, List<String>> _signedCache = {};

  /// URLs affichables des photos d'un souvenir (DOUBLE-LECTURE) :
  ///  - `mediaKeys` (R2) → URLs GET signées via le backend (membre uniquement) ;
  ///  - sinon `mediaUrls` (Firebase), puis `photoUrl` (ancien format).
  static Future<List<String>> resolvePhotoUrls(MemoryModel m) async {
    if (m.mediaKeys.isEmpty) {
      if (m.mediaUrls.isNotEmpty) return m.mediaUrls;
      return (m.photoUrl != null && m.photoUrl!.isNotEmpty)
          ? [m.photoUrl!]
          : const [];
    }
    final cached = _signedCache[m.id];
    if (cached != null) return cached;
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return const [];
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/photo-play'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'memoryId': m.id}),
      );
      if (res.statusCode != 200) {
        // Repli : si la signature échoue mais qu'il reste d'anciennes URLs.
        return m.mediaUrls;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final signed = (data['urls'] as List<dynamic>).cast<String>();
      // Souvenir mixte (édité) : clés R2 signées PUIS anciennes URLs Firebase.
      final merged = <String>[...signed, ...m.mediaUrls];
      _signedCache[m.id] = merged;
      return merged;
    } catch (_) {
      return m.mediaUrls;
    }
  }

  /// À appeler après édition d'un souvenir pour forcer une nouvelle signature.
  static void invalidateSignedCache(String memoryId) =>
      _signedCache.remove(memoryId);

  /// Map clé→URL signée des photos R2 d'un souvenir (via photo-play, membre
  /// uniquement). Sert l'écran d'édition (afficher les photos existantes tout
  /// en conservant leurs clés).
  static Future<Map<String, String>> signedUrlsForMemory(
      String memoryId) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return const {};
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/photo-play'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'memoryId': memoryId}),
      );
      if (res.statusCode != 200) return const {};
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final ks = (data['keys'] as List<dynamic>).cast<String>();
      final us = (data['urls'] as List<dynamic>).cast<String>();
      return {
        for (var i = 0; i < ks.length && i < us.length; i++) ks[i]: us[i]
      };
    } catch (_) {
      return const {};
    }
  }

  /// Signe par lot des clés R2 appartenant à l'appelant (livre / couverture).
  static Future<Map<String, String>> signOwnPhotoKeys(
      List<String> keys) async {
    if (keys.isEmpty) return const {};
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return const {};
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/photo-sign'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'keys': keys}),
      );
      if (res.statusCode != 200) return const {};
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final ks = (data['keys'] as List<dynamic>).cast<String>();
      final us = (data['urls'] as List<dynamic>).cast<String>();
      return {
        for (var i = 0; i < ks.length && i < us.length; i++) ks[i]: us[i]
      };
    } catch (_) {
      return const {};
    }
  }

  /// Supprime une photo R2 par sa clé via le backend (ignore les erreurs).
  static Future<void> deletePhotoByKey(String? key) async {
    if (key == null || key.isEmpty) return;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/photo-delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'key': key}),
      );
    } catch (_) {}
  }

  /// Delete a photo by its download URL. Silently ignores errors
  /// (already deleted, wrong URL, etc.).
  static Future<void> deletePhotoByUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }

  /// Delete all photos attached to memories in a notebook,
  /// then delete the memories and the notebook itself.
  static Future<void> deleteNotebookCascade(String notebookId) async {
    final memories = await _firestore
        .collection('memories')
        .where('notebookId', isEqualTo: notebookId)
        .get();

    // Delete all photos + voice memos from Storage
    final mediaFutures = memories.docs.expand((doc) {
      final data = doc.data();
      final urls = <String?>[
        data['photoUrl'] as String?,
        ...List<String>.from(data['mediaUrls'] as List<dynamic>? ?? []),
      ];
      final videoKeys = List<String>.from(
          data['videoKeys'] as List<dynamic>? ??
              [if (data['videoKey'] != null) data['videoKey']]);
      final photoKeys =
          List<String>.from(data['mediaKeys'] as List<dynamic>? ?? []);
      return <Future<void>>[
        ...urls.map(deletePhotoByUrl),
        ...photoKeys.map(deletePhotoByKey),
        AudioService.deleteAudioByUrl(data['audioUrl'] as String?),
        AudioService.deleteAudioByKey(data['audioKey'] as String?),
        VideoService.deleteVideosByKeys(videoKeys),
      ];
    });
    await Future.wait(mediaFutures);

    // Delete memories from Firestore in batches
    const batchSize = 400;
    for (var i = 0; i < memories.docs.length; i += batchSize) {
      final batch = _firestore.batch();
      for (final doc in memories.docs.skip(i).take(batchSize)) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }

    // Delete notebook
    await _firestore.collection('notebooks').doc(notebookId).delete();
  }

  /// Delete a memory and ALL its photos (photoUrl + mediaUrls) + voice memo.
  static Future<void> deleteMemory(
      String memoryId, String? photoUrl, List<String> mediaUrls,
      {String? audioUrl,
      String? audioKey,
      List<String> videoKeys = const [],
      List<String> mediaKeys = const []}) async {
    final allUrls = {
      if (photoUrl != null && photoUrl.isNotEmpty) photoUrl,
      ...mediaUrls,
    };
    await Future.wait([
      ...allUrls.map(deletePhotoByUrl),
      ...mediaKeys.map(deletePhotoByKey),
      AudioService.deleteAudioByUrl(audioUrl),
      AudioService.deleteAudioByKey(audioKey),
      VideoService.deleteVideosByKeys(videoKeys),
      _firestore.collection('memories').doc(memoryId).delete(),
    ]);
  }
}
