import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/memory_model.dart';

/// Lecture des souvenirs visibles par l'utilisateur.
///
/// Firestore ne sait pas faire un OR entre deux champs : les souvenirs qu'on
/// possède (`userId`) et ceux qu'on nous a partagés via un tag (`sharedWith`)
/// viennent donc de deux requêtes, fusionnées ici par id.
class MemoryQueryService {
  static Stream<List<MemoryModel>> visible() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);

    final col = FirebaseFirestore.instance.collection('memories');
    final controller = StreamController<List<MemoryModel>>();
    final byId = <String, MemoryModel>{};
    final subs = <StreamSubscription>[];

    void emit(QuerySnapshot<Map<String, dynamic>> snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.removed) {
          byId.remove(change.doc.id);
        } else {
          byId[change.doc.id] = MemoryModel.fromFirestore(change.doc);
        }
      }
      final all = byId.values.toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (!controller.isClosed) controller.add(all);
    }

    controller.onListen = () {
      subs.add(col.where('userId', isEqualTo: uid).snapshots().listen(emit));
      subs.add(
          col.where('sharedWith', arrayContains: uid).snapshots().listen(emit));
    };
    controller.onCancel = () async {
      for (final s in subs) {
        await s.cancel();
      }
      await controller.close();
    };
    return controller.stream;
  }

  /// Souvenirs portant [tagId] (filtrage côté client — le volume par
  /// utilisateur reste modeste, et ça évite un index composite).
  static Stream<List<MemoryModel>> visibleWithTag(String? tagId) {
    if (tagId == null || tagId.isEmpty) return visible();
    return visible()
        .map((all) => all.where((m) => m.tagIds.contains(tagId)).toList());
  }
}
