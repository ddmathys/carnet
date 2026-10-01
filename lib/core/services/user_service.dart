import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  static final _db = FirebaseFirestore.instance;

  /// Appelé à chaque connexion pour tenir le profil à jour.
  ///
  /// Ne résout plus d'« invitations par e-mail en attente » : ce chemin a été
  /// retiré le 01.10.26 avec la porte `invitedEmails` des règles Firestore.
  /// Il accordait un accès sur la seule base d'une adresse jamais vérifiée,
  /// et plus rien n'alimentait la liste depuis la bascule vers les tags — le
  /// partage passe par un lien d'invitation (`TagService.createInviteLink`).
  static Future<void> onLogin() async {
    await saveProfile();
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

}
