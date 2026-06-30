import 'dart:math' show min;
import 'package:cloud_firestore/cloud_firestore.dart';

class QuotaService {
  static const int freePhotoLimit = 300; // affiché à l'utilisateur
  // Blocage réel (marge de tolérance au-dessus de la limite affichée) : on
  // n'empêche l'ajout qu'à partir de 350, mais l'UI annonce 300.
  static const int freePhotoHardLimit = 350;
  static const int premiumPhotoLimit = 15000;
  static const double premiumPriceChf = 29.0;

  // Vidéos souvenir. La durée par clip est plafonnée à 120 s à la capture
  // (cf. memory_create_screen) — c'est le principal levier de coût de stockage.
  // Le nombre de vidéos est le palier gratuit/premium (plafond au NOMBRE de
  // clips, pas à la durée cumulée).
  // Estimation stockage (clip 2 min ~ 25 Mo) : gratuit 30 ≈ 0,75 Go ;
  // premium 150 ≈ 3,75 Go par utilisateur.
  static const int freeVideoLimit = 30;
  static const int premiumVideoLimit = 150;
  static const int maxVideoDurationSec = 120;
  // Nombre max de vidéos attachées à UN même souvenir (en plus du quota global
  // ci-dessus). Garde la page du livre lisible et maîtrise le coût de stockage.
  static const int maxVideosPerMemory = 3;

  // Mémos vocaux (un par souvenir). Même logique de palier gratuit/premium.
  static const int freeAudioLimit = 15;
  static const int premiumAudioLimit = 150;

  // Check subscription tier from users/{uid} document.
  static Future<String> getSubscriptionTier(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(userId).get();
      return (doc.data()?['subscriptionTier'] as String?) ?? 'free';
    } catch (_) {
      return 'free';
    }
  }

  static Future<bool> isPremium(String userId) async {
    return (await getSubscriptionTier(userId)) == 'premium';
  }

  static Future<int> getPhotoLimit(String userId) async {
    return await isPremium(userId) ? premiumPhotoLimit : freePhotoLimit;
  }

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
          final mediaUrls = List<String>.from(data['mediaUrls'] ?? []);
          if (mediaUrls.isNotEmpty) {
            count += mediaUrls.length;
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

  // Limite de blocage réelle (≠ limite affichée pour le gratuit).
  static Future<int> getHardPhotoLimit(String userId) async {
    return await isPremium(userId) ? premiumPhotoLimit : freePhotoHardLimit;
  }

  /// Peut-on ajouter [adding] photo(s) ? Bloque à la limite réelle (350 free /
  /// 10000 premium). Renvoie aussi le compte courant pour l'écran d'upgrade.
  static Future<({bool allowed, int current, int limit})> canAddPhotos(
    String userId, {
    int adding = 1,
  }) async {
    final hardLimit = await getHardPhotoLimit(userId);
    final count = await countUserPhotos(userId);
    return (allowed: count + adding <= hardLimit, current: count, limit: hardLimit);
  }

  static Future<int> getVideoLimit(String userId) async {
    return await isPremium(userId) ? premiumVideoLimit : freeVideoLimit;
  }

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

  /// Peut-on ajouter [adding] vidéo(s) ? (15 free / 150 premium).
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

  static Future<int> getAudioLimit(String userId) async {
    return await isPremium(userId) ? premiumAudioLimit : freeAudioLimit;
  }

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
          if ((doc.data()['audioUrl'] as String?)?.isNotEmpty == true) count++;
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

  /// Peut-on ajouter un mémo vocal ? (15 free / 150 premium).
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
