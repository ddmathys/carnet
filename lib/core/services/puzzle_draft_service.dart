import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/puzzle_draft.dart';

/// Brouillons de puzzles (collection `puzzleDrafts`) — même principe que
/// [BookDraftService] : le puzzle en cours survit à la fermeture de l'app et
/// se reprend depuis le dashboard.
class PuzzleDraftService {
  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('puzzleDrafts');

  static String newId() => _col.doc().id;

  static Future<void> save(PuzzleDraft draft) =>
      _col.doc(draft.id).set(draft.toMap());

  static Future<PuzzleDraft?> get(String id) async {
    final doc = await _col.doc(id).get();
    return doc.exists ? PuzzleDraft.fromDoc(doc) : null;
  }

  static Future<void> delete(String id) => _col.doc(id).delete();

  static Future<void> markOrdered(String id) =>
      _col.doc(id).update({'status': 'ordered'});

  /// Puzzles en cours (non commandés), plus récent d'abord. Filtre sur
  /// `userId` seul (règles Firestore) ; statut et tri côté client, sans index
  /// composite — même convention que BookDraftService.
  static Stream<List<PuzzleDraft>> streamMine() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('userId', isEqualTo: uid).snapshots().map((snap) => snap
        .docs
        .map(PuzzleDraft.fromDoc)
        .where((d) => d.status == 'draft' && d.photoUrl.isNotEmpty)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
  }
}
