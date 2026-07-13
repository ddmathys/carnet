import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// L'« espace » : le carnet unique et invisible de chaque utilisateur.
///
/// Les carnets ont disparu de l'interface (remplacés par les tags), mais la
/// collection `notebooks` reste le porteur technique des souvenirs : les règles
/// Firestore historiques, le contrôle d'accès aux médias R2 et les clés de
/// stockage (`photos/{uid}/{notebookId}/…`) en dépendent. Chaque souvenir est
/// donc rattaché à l'espace de son créateur ; l'organisation, elle, se fait
/// entièrement par tags.
class SpaceService {
  static final _db = FirebaseFirestore.instance;
  static final Map<String, String> _cache = {}; // uid → notebookId

  /// Id de l'espace de l'utilisateur courant (le crée au besoin). Réutilise le
  /// carnet le plus ancien s'il en existe déjà — après migration, c'est celui
  /// qui porte tous les souvenirs.
  static Future<String?> ensureSpaceId() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final cached = _cache[uid];
    if (cached != null) return cached;

    final snap =
        await _db.collection('notebooks').where('userId', isEqualTo: uid).get();
    if (snap.docs.isNotEmpty) {
      final docs = snap.docs.toList()
        ..sort((a, b) {
          final ta = a.data()['createdAt'] as Timestamp?;
          final tb = b.data()['createdAt'] as Timestamp?;
          if (ta == null || tb == null) return 0;
          return ta.compareTo(tb);
        });
      final id = docs.first.id;
      _cache[uid] = id;
      return id;
    }

    final ref = _db.collection('notebooks').doc();
    await ref.set({
      'userId': uid,
      'type': 'libre',
      'title': 'Mon espace',
      'coverColor': '#C4714B',
      'memoriesCount': 0,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'sharedWith': <String>[],
      'invitedEmails': <String>[],
    });
    _cache[uid] = ref.id;
    return ref.id;
  }

  static void clearCache() => _cache.clear();
}
