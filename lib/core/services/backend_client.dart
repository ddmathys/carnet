import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

/// Client HTTP vers le backend Bloom (Vercel).
/// Toutes les requêtes sont authentifiées avec le token Firebase de
/// l'utilisateur courant — le backend détient les clés API tierces.
class BackendClient {
  static Future<Map<String, dynamic>?> postJson(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    // getIdToken() peut rafraîchir le token via le réseau : sans timeout, un
    // refresh qui pend bloque l'appel indéfiniment (spinner infini, sans
    // erreur). On le borne comme le reste.
    final token = await user.getIdToken().timeout(timeout);

    final response = await http
        .post(
          Uri.parse('${AppConfig.backendUrl}$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      // ignore: avoid_print
      print('[backend] $path → ${response.statusCode} ${response.body}');
      return null;
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}
