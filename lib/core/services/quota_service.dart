import 'dart:math' show min;
import 'package:cloud_firestore/cloud_firestore.dart';

/// Pas d'abonnement dans l'app : les limites ci-dessous sont larges et
/// s'appliquent à tout le monde. Seule l'impression d'un livre est payante
/// (voir `book_pricing.dart` / `order_service.dart`).
class QuotaService {
  static const int photoLimit = 15000;
  static const int photoHardLimit = 15000;

  // Vidéos souvenir : 150 clips de 10 min max chacun.
  // Estimation stockage : 150 clips × jusqu'à 10 min (~90 Mo) ≈ 13,5 Go max
  // par utilisateur.
  static const int videoLimit = 150;
  static const int videoDurationSec = 600; // 10 min
  // Pas de plafond propre par souvenir : borné par le quota global ci-dessus.
  static const int maxVideosPerMemory = videoLimit;

  static Future<int> getMaxVideosPerMemory(String userId) async =>
      maxVideosPerMemory;

  static const int audioLimit = 150;

  static Future<int> getPhotoLimit(String userId) async => photoLimit;

  // Count total photos across all notebooks of a user.
  static Future<int> countUserPhotos(String userId) async {
    try {
      final notebooksSnap = await FirebaseFirestore.instance
          .collection('notebooks')
          .where('userId', isEqualTo: userId)
          .get();

      if (notebooksSnap.docs.isEmpty) return 0;

      final notebookIds = notebooksSnap.docs.map((d) => d.id).toList();
      int count = 0;

      for (int i = 0; i < notebookIds.length; i += 10) {
        final batch = notebookIds.sublist(i, min(i + 10, notebookIds.length));
        final memoriesSnap = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', whereIn: batch)
            .get();

        for (final doc in memoriesSnap.docs) {
          final data = doc.data();
          // Photos R2 (mediaKeys) + anciennes photos Firebase (mediaUrls) — les
          // deux comptent. Sans mediaKeys, le compteur affichait 0 depuis la
          // bascule R2 (les photos ne sont plus dans mediaUrls).
          final keys = List<String>.from(data['mediaKeys'] ?? []);
          final urls = List<String>.from(data['mediaUrls'] ?? []);
          if (keys.isNotEmpty || urls.isNotEmpty) {
            count += keys.length + urls.length;
          } else if ((data['photoUrl'] as String?)?.isNotEmpty == true) {
            count++;
          }
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  // Returns true if user can still add a photo.
  static Future<QuotaStatus> checkQuota(String userId) async {
    final limit = await getPhotoLimit(userId);
    final count = await countUserPhotos(userId);
    return QuotaStatus(current: count, limit: limit);
  }

  static Future<int> getHardPhotoLimit(String userId) async => photoHardLimit;

  /// Peut-on ajouter [adding] photo(s) ? Bloque à la limite réelle.
  static Future<({bool allowed, int current, int limit})> canAddPhotos(
    String userId, {
    int adding = 1,
  }) async {
    final hardLimit = await getHardPhotoLimit(userId);
    final count = await countUserPhotos(userId);
    return (allowed: count + adding <= hardLimit, current: count, limit: hardLimit);
  }

  static Future<int> getVideoLimit(String userId) async => videoLimit;

  /// Durée max par clip (secondes). Le plafond évite des fichiers énormes qui
  /// échouent à l'upload (l'app charge tout le fichier en mémoire, cf.
  /// VideoService).
  static Future<int> getVideoDurationLimitSec(String userId) async =>
      videoDurationSec;

  // Compte le nombre TOTAL de vidéos (chaque souvenir peut en porter plusieurs)
  // sur tous les carnets de l'utilisateur.
  static Future<int> countUserVideos(String userId) async {
    try {
      final notebooksSnap = await FirebaseFirestore.instance
          .collection('notebooks')
          .where('userId', isEqualTo: userId)
          .get();

      if (notebooksSnap.docs.isEmpty) return 0;

      final notebookIds = notebooksSnap.docs.map((d) => d.id).toList();
      int count = 0;

      for (int i = 0; i < notebookIds.length; i += 10) {
        final batch = notebookIds.sublist(i, min(i + 10, notebookIds.length));
        final memoriesSnap = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', whereIn: batch)
            .get();

        for (final doc in memoriesSnap.docs) {
          final data = doc.data();
          final keys = data['videoKeys'] as List<dynamic>?;
          if (keys != null && keys.isNotEmpty) {
            count += keys.length;
          } else if ((data['videoKey'] as String?)?.isNotEmpty == true) {
            count++; // ancien format mono-vidéo
          }
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Peut-on ajouter [adding] vidéo(s) ?
  static Future<({bool allowed, int current, int limit})> canAddVideos(
    String userId, {
    int adding = 1,
  }) async {
    final limit = await getVideoLimit(userId);
    final count = await countUserVideos(userId);
    return (allowed: count + adding <= limit, current: count, limit: limit);
  }

  // Compteur d'avancement vidéo (pour l'accueil), même forme que les photos.
  static Future<QuotaStatus> checkVideoQuota(String userId) async {
    final limit = await getVideoLimit(userId);
    final count = await countUserVideos(userId);
    return QuotaStatus(current: count, limit: limit);
  }

  static Future<int> getAudioLimit(String userId) async => audioLimit;

  // Compte les mémos vocaux (souvenirs avec un audioUrl) sur tous les carnets.
  static Future<int> countUserAudios(String userId) async {
    try {
      final notebooksSnap = await FirebaseFirestore.instance
          .collection('notebooks')
          .where('userId', isEqualTo: userId)
          .get();
      if (notebooksSnap.docs.isEmpty) return 0;

      final notebookIds = notebooksSnap.docs.map((d) => d.id).toList();
      int count = 0;
      for (int i = 0; i < notebookIds.length; i += 10) {
        final batch = notebookIds.sublist(i, min(i + 10, notebookIds.length));
        final memoriesSnap = await FirebaseFirestore.instance
            .collection('memories')
            .where('notebookId', whereIn: batch)
            .get();
        for (final doc in memoriesSnap.docs) {
          final data = doc.data();
          // Mémo vocal R2 (audioKey) OU ancien Firebase (audioUrl). Sans la clé,
          // le compteur restait à 0 depuis la bascule R2.
          if ((data['audioKey'] as String?)?.isNotEmpty == true ||
              (data['audioUrl'] as String?)?.isNotEmpty == true) {
            count++;
          }
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  static Future<QuotaStatus> checkAudioQuota(String userId) async {
    final limit = await getAudioLimit(userId);
    final count = await countUserAudios(userId);
    return QuotaStatus(current: count, limit: limit);
  }

  /// Peut-on ajouter un mémo vocal ?
  static Future<({bool allowed, int current, int limit})> canAddAudios(
    String userId, {
    int adding = 1,
  }) async {
    final limit = await getAudioLimit(userId);
    final count = await countUserAudios(userId);
    return (allowed: count + adding <= limit, current: count, limit: limit);
  }
}

class QuotaStatus {
  final int current;
  final int limit;
  const QuotaStatus({required this.current, required this.limit});

  bool get canAdd => current < limit;
  double get ratio => limit == 0 ? 1.0 : (current / limit).clamp(0.0, 1.0);
  int get remaining => (limit - current).clamp(0, limit);
  bool get nearLimit => ratio >= 0.85;
  bool get isAtLimit => current >= limit;
}
