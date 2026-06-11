import 'package:flutter/foundation.dart';
import 'backend_client.dart';

/// Envoi d'emails via le backend Bloom (qui détient la clé Resend).
class ResendService {
  ResendService();

  /// Envoie l'email d'invitation à un carnet partagé.
  /// Le backend vérifie que l'appelant est bien le propriétaire du carnet
  /// et construit l'email lui-même.
  Future<bool> sendNotebookInvitation({
    required String notebookId,
    required String toEmail,
  }) async {
    try {
      final data = await BackendClient.postJson(
        '/api/email/share',
        {'notebookId': notebookId, 'toEmail': toEmail},
        timeout: const Duration(seconds: 20),
      );
      return data?['ok'] == true;
    } catch (e) {
      debugPrint('[email/share] ERROR: $e');
      return false;
    }
  }
}
