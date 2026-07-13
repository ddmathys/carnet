import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/generated_book_model.dart';

/// Historique des livres générés (PDF). Collection Firestore `generatedBooks`.
class BookHistoryService {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('generatedBooks');

  /// Flux des livres d'un carnet. On filtre par `userId` (et non `notebookId`)
  /// car les règles Firestore autorisent la lecture sur `userId == auth.uid` :
  /// une requête de liste qui ne contraint pas ce champ serait REFUSÉE par
  /// Firestore (et le flux émettrait une erreur → spinner infini).
  /// Le filtrage `notebookId` et le tri `createdAt` desc se font côté client
  /// (évite aussi un index composite).
  /// Tous les livres de l'utilisateur — l'unité d'affichage n'est plus le
  /// carnet : « Mes livres » est global (PDF générés + livres commandés).
  static Stream<List<GeneratedBookModel>> streamForUser() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('userId', isEqualTo: uid).snapshots().map((snap) {
      final books = snap.docs
          .map((d) => GeneratedBookModel.fromFirestore(d))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return books;
    });
  }

  static Stream<List<GeneratedBookModel>> streamForNotebook(String notebookId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('userId', isEqualTo: uid).snapshots().map((snap) {
      final books = snap.docs
          .map((d) => GeneratedBookModel.fromFirestore(d))
          .where((b) => b.notebookId == notebookId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return books;
    });
  }

  /// Enregistre un livre généré. Silencieux en cas d'échec (ne bloque pas le
  /// partage/la commande qui ont déjà eu lieu).
  static Future<void> recordBook({
    required String notebookId,
    required String title,
    String? subtitle,
    required String format, // 'digital' | 'printed'
    required String coverType,
    required String pdfUrl,
    required String storagePath,
    required int memoriesCount,
    String? orderId,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await _col.add({
        'userId': uid,
        'notebookId': notebookId,
        'title': title,
        'subtitle': subtitle,
        'format': format,
        'coverType': coverType,
        'pdfUrl': pdfUrl,
        'storagePath': storagePath,
        'memoriesCount': memoriesCount,
        'createdAt': FieldValue.serverTimestamp(),
        'orderId': orderId,
      });
    } catch (_) {
      // ignore — l'entrée d'historique est best-effort
    }
  }

  /// Supprime l'entrée d'historique + le fichier PDF du Storage.
  /// (Pour un imprimé, la commande Firestore reste intacte.)
  static Future<void> deleteBook(GeneratedBookModel book) async {
    await _col.doc(book.id).delete();
    if (book.storagePath.isNotEmpty) {
      try {
        await FirebaseStorage.instance.ref(book.storagePath).delete();
      } catch (_) {
        // déjà supprimé / chemin invalide — on ignore
      }
    }
  }
}
