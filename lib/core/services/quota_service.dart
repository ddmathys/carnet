import 'dart:math' show min;
import 'package:cloud_firestore/cloud_firestore.dart';

class QuotaService {
  static const int freePhotoLimit = 300;
  static const int premiumPhotoLimit = 10000;
  static const double premiumPriceChf = 29.0;

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
