import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  static final _db = FirebaseFirestore.instance;

  // Call on every login to keep profile fresh and resolve pending invites.
  static Future<void> onLogin() async {
    await Future.wait([saveProfile(), resolvePendingInvites()]);
  }

  // Write/update the current user's profile document.
  static Future<void> saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await _db.collection('users').doc(user.uid).set({
      'email': user.email?.toLowerCase() ?? '',
      'displayName': user.displayName ?? '',
      'photoUrl': user.photoURL ?? '',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Find a user UID by email address. Returns null if not found.
  static Future<String?> findUidByEmail(String email) async {
    final snap = await _db
        .collection('users')
        .where('email', isEqualTo: email.toLowerCase().trim())
        .limit(1)
        .get();
    return snap.docs.isEmpty ? null : snap.docs.first.id;
  }

  // Get user info map from Firestore.
  static Future<Map<String, dynamic>?> getUserInfo(String uid) async {
    final doc = await _db.collection('users').doc(uid).get();
    return doc.data();
  }

  // Get display info (email + name) for multiple UIDs.
  static Future<Map<String, _UserInfo>> resolveUsers(List<String> uids) async {
    final result = <String, _UserInfo>{};
    await Future.wait(uids.map((uid) async {
      final data = await getUserInfo(uid);
      result[uid] = _UserInfo(
        email: data?['email'] as String? ?? uid,
        displayName: data?['displayName'] as String? ?? '',
      );
    }));
    return result;
  }

  // ── Admin ───────────────────────────────────────────────────────────────

  /// Flux de tous les utilisateurs (console admin). Demandes Premium d'abord,
  /// puis tri par e-mail. Les règles autorisent la lecture aux connectés.
  static Stream<List<AppUser>> allUsersStream() => _db
      .collection('users')
      .snapshots()
      .map((s) => s.docs.map((d) => AppUser.fromDoc(d.id, d.data())).toList()
        ..sort((a, b) {
          if (a.premiumRequested != b.premiumRequested) {
            return a.premiumRequested ? -1 : 1; // demandes en haut
          }
          return a.email.compareTo(b.email);
        }));

  /// Active/retire Premium (admin only — autorisé par firestore.rules isAdmin).
  /// Le passage à premium efface le drapeau de demande. Les compteurs de quota
  /// s'ajustent automatiquement car les limites suivent `subscriptionTier`.
  static Future<void> setSubscriptionTier(String uid, String tier) async {
    await _db.collection('users').doc(uid).set({
      'subscriptionTier': tier,
      if (tier == 'premium') 'premiumRequested': false,
      'tierUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // When a user logs in, grant them access to notebooks they were invited to.
  static Future<void> resolvePendingInvites() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || (user.email ?? '').isEmpty) return;
    final email = user.email!.toLowerCase();

    final snap = await _db
        .collection('notebooks')
        .where('invitedEmails', arrayContains: email)
        .get();

    for (final doc in snap.docs) {
      await doc.reference.update({
        'sharedWith': FieldValue.arrayUnion([user.uid]),
        'invitedEmails': FieldValue.arrayRemove([email]),
      });
    }
  }
}

class _UserInfo {
  final String email;
  final String displayName;
  const _UserInfo({required this.email, required this.displayName});
  String get label => displayName.isNotEmpty ? '$displayName ($email)' : email;
}

/// Utilisateur tel que vu par la console admin.
class AppUser {
  final String uid;
  final String email;
  final String displayName;
  final String tier; // 'free' | 'premium'
  final bool premiumRequested;

  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.tier,
    required this.premiumRequested,
  });

  bool get isPremium => tier == 'premium';

  factory AppUser.fromDoc(String uid, Map<String, dynamic> d) => AppUser(
        uid: uid,
        email: (d['email'] as String?) ?? uid,
        displayName: (d['displayName'] as String?) ?? '',
        tier: (d['subscriptionTier'] as String?) ?? 'free',
        premiumRequested: d['premiumRequested'] == true,
      );
}
