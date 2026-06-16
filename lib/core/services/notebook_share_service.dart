import 'backend_client.dart';

/// Invitations à un carnet par lien (deep link).
class NotebookShareService {
  /// Crée un lien d'invitation partageable pour un carnet. Renvoie le lien de
  /// jonction, le lien de téléchargement de l'app et le titre, ou null.
  static Future<({String url, String downloadUrl, String title})?>
      createInviteLink(String notebookId) async {
    final data = await BackendClient.postJson(
      '/api/notebook/invite',
      {'notebookId': notebookId},
      timeout: const Duration(seconds: 20),
    );
    final url = data?['url'] as String?;
    if (url == null) return null;
    return (
      url: url,
      downloadUrl: (data?['downloadUrl'] as String?) ??
          'https://dmathys.dev/download/carnet.apk',
      title: (data?['notebookTitle'] as String?) ?? 'Carnet',
    );
  }

  /// Rejoint un carnet via le token d'un lien d'invitation. Renvoie l'id + le
  /// titre du carnet rejoint, ou null si l'invitation est invalide/expirée.
  static Future<({String notebookId, String title})?> joinByToken(
      String token) async {
    final data = await BackendClient.postJson(
      '/api/notebook/join',
      {'token': token},
      timeout: const Duration(seconds: 20),
    );
    if (data != null && data['ok'] == true && data['notebookId'] != null) {
      return (
        notebookId: data['notebookId'] as String,
        title: (data['title'] as String?) ?? 'Carnet',
      );
    }
    return null;
  }
}
