import 'dart:convert';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

class AudioService {
  static final _storage = FirebaseStorage.instance;

  // Plus d'upload vers Firebase Storage : les mémos vocaux partent sur R2.
  // Ne reste que la suppression des anciens, le temps que la migration passe.

  /// Delete a voice memo by its download URL. Silently ignores errors.
  static Future<void> deleteAudioByUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    try {
      await _storage.refFromURL(url).delete();
    } catch (_) {}
  }

  // ── R2 : bucket privé + URLs signées temporaires (comme photos/vidéos) ───

  /// Upload un mémo vocal vers R2 via URL PUT signée. Retourne la CLÉ d'objet
  /// (à stocker dans `audioKey`), ou null en cas d'échec.
  static Future<String?> uploadMemoryAudioToR2({
    required File audio,
    required String notebookId,
  }) async {
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return null;
    final signRes = await http.post(
      Uri.parse('${AppConfig.backendUrl}/api/video/audio-upload-url'),
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
    final contentType = (data['contentType'] as String?) ?? 'audio/mp4';
    if (uploadUrl == null || key == null) return null;
    final bytes = await audio.readAsBytes();
    final putRes = await http.put(Uri.parse(uploadUrl),
        headers: {'Content-Type': contentType}, body: bytes);
    if (putRes.statusCode != 200 && putRes.statusCode != 201) return null;
    return key;
  }

  static final Map<String, String?> _signedCache = {};

  /// URL signée du mémo vocal R2 d'un souvenir (via `audio-play`, membre only).
  /// null si pas d'audio R2. Mise en cache (URLs valables ~1 h).
  static Future<String?> signedAudioUrl(String memoryId) async {
    if (_signedCache.containsKey(memoryId)) return _signedCache[memoryId];
    final token = await FirebaseAuth.instance.currentUser?.getIdToken();
    if (token == null) return null;
    try {
      final res = await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/audio-play'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'memoryId': memoryId}),
      );
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final url = data['url'] as String?;
      _signedCache[memoryId] = url;
      return url;
    } catch (_) {
      return null;
    }
  }

  static void invalidateSignedCache(String memoryId) =>
      _signedCache.remove(memoryId);

  /// Supprime un mémo vocal R2 par sa clé (ignore les erreurs).
  static Future<void> deleteAudioByKey(String? key) async {
    if (key == null || key.isEmpty) return;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/audio-delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'key': key}),
      );
    } catch (_) {}
  }
}
