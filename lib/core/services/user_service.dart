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
