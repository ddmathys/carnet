import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Résultat de l'upload d'un PDF de livre : la clé R2 (stockée en base) et
/// l'URL STABLE à donner à l'imprimeur.
class PdfUploadResult {
  final String key;
  final String url;
  const PdfUploadResult({required this.key, required this.url});
}

/// PDF des livres sur Cloudflare R2 (comme les photos, vidéos et mémos).
///
/// Le bucket est privé : l'URL renvoyée n'est pas une URL R2 mais une URL du
/// backend, permanente et signée, qui redirige vers une URL R2 fraîche à chaque
/// accès. C'est la seule forme qui convienne à Gelato, dont l'impression peut
/// survenir bien après la commande — une URL signée aurait expiré.
class PdfService {
  /// Envoie le PDF sur R2. Retourne sa clé + son URL stable, ou null si échec.
  static Future<PdfUploadResult?> uploadBookPdf(Uint8List bytes) async {
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return null;
      final signRes = await http
          .post(
            Uri.parse('${AppConfig.backendUrl}/api/video/book-upload-url'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(const {}),
          )
          .timeout(const Duration(seconds: 30));
      if (signRes.statusCode != 200) {
        debugPrint('PdfService: book-upload-url ${signRes.statusCode}');
        return null;
      }
      final data = jsonDecode(signRes.body) as Map<String, dynamic>;
      final uploadUrl = data['uploadUrl'] as String?;
      final key = data['key'] as String?;
      final url = data['url'] as String?;
      final contentType =
          (data['contentType'] as String?) ?? 'application/pdf';
      if (uploadUrl == null || key == null || url == null) return null;

      final putRes = await http
          .put(Uri.parse(uploadUrl),
              headers: {'Content-Type': contentType}, body: bytes)
          .timeout(const Duration(minutes: 10));
      if (putRes.statusCode != 200 && putRes.statusCode != 201) {
        debugPrint('PdfService: PUT R2 ${putRes.statusCode}');
        return null;
      }
      return PdfUploadResult(key: key, url: url);
    } catch (e) {
      debugPrint('PdfService: upload error — $e');
      return null;
    }
  }

  /// Retrouve la clé R2 depuis une URL stable (`…/book-pdf?key=…&sig=…`).
  /// null pour une ancienne URL Firebase — il n'y a alors rien à supprimer sur R2.
  static String? keyFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final key = Uri.parse(url).queryParameters['key'];
      return (key != null && key.startsWith('books/')) ? key : null;
    } catch (_) {
      return null;
    }
  }

  /// Supprime un PDF de R2 (ignore les erreurs : l'entrée d'historique, elle,
  /// est déjà partie).
  static Future<void> deleteBookPdf(String? keyOrUrl) async {
    final key = (keyOrUrl != null && keyOrUrl.startsWith('books/'))
        ? keyOrUrl
        : keyFromUrl(keyOrUrl);
    if (key == null) return;
    try {
      final token = await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/api/video/book-delete'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'key': key}),
      );
    } catch (_) {}
  }
}
