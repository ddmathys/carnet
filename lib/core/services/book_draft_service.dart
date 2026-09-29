import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/book_draft.dart';

/// Brouillons de livres (collection `bookDrafts`) — sauvegarde automatique de
/// l'éditeur d'aperçu, voir BookDraft.
class BookDraftService {
  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('bookDrafts');

  /// Nouvel identifiant de brouillon (le document n'est écrit qu'au 1er save).
  static String newId() => _col.doc().id;

  static Future<void> save(BookDraft draft) =>
      _col.doc(draft.id).set(draft.toMap());

  static Future<BookDraft?> get(String id) async {
    final doc = await _col.doc(id).get();
    return doc.exists ? BookDraft.fromDoc(doc) : null;
  }

  static Future<void> delete(String id) => _col.doc(id).delete();

  static Future<void> markOrdered(String id) =>
      _col.doc(id).update({'status': 'ordered'});

  /// Brouillons en cours (non commandés), plus récent d'abord. Filtre sur
  /// `userId` seul (règles Firestore) ; statut et tri côté client, sans index
  /// composite — même convention que BookHistoryService.
  static Stream<List<BookDraft>> streamMine() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('userId', isEqualTo: uid).snapshots().map((snap) => snap
        .docs
        .map(BookDraft.fromDoc)
        .where((d) => d.status == 'draft')
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
  }
}
