import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/memory_activity_model.dart';

/// Fil d'activité "quelqu'un a ajouté des photos/vidéos" sur les souvenirs
/// partagés — chaque destinataire (propriétaire + collaborateurs, l'auteur du
/// geste compris) doit "valider" (fermer) la notification de son côté.
class MemoryActivityService {
  static final _col = FirebaseFirestore.instance.collection('memoryActivities');

  /// Enregistre une activité. `recipients` doit déjà inclure l'auteur — voir
  /// l'appelant (memory_create_screen.dart::_save) pour le calcul exact.
  /// Best-effort : ne bloque jamais la sauvegarde du souvenir lui-même si ça
  /// échoue (même philosophie que BookHistoryService.recordBook).
  static Future<void> record({
    required String memoryId,
    required String memoryTitle,
    required String kind,
    required int photosAdded,
    required int videosAdded,
    required List<String> recipients,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || recipients.length < 2) return;
    final label = (user.displayName?.isNotEmpty ?? false)
        ? user.displayName!
        : (user.email ?? 'Quelqu\'un');
    try {
      await _col.add({
        'memoryId': memoryId,
        'memoryTitle': memoryTitle,
        'kind': kind,
        'actorUid': user.uid,
        'actorLabel': label,
        'photosAdded': photosAdded,
        'videosAdded': videosAdded,
        'recipients': recipients,
        'seenBy': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Best-effort — le souvenir est déjà enregistré, une activité manquée
      // n'est pas une raison de faire échouer la sauvegarde.
    }
  }

  /// Activités non encore validées par moi, tous souvenirs confondus.
  /// Pas de `orderBy` dans la requête (même raison qu'ailleurs dans ce
  /// projet : `where(arrayContains) + orderBy` exige un index composite
  /// jamais déclaré ici) — tri fait côté client.
  static Stream<List<MemoryActivityModel>> streamPending() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(const []);
    return _col
        .where('recipients', arrayContains: uid)
        .limit(100)
        .snapshots()
        .map((snap) {
      final all = snap.docs.map(MemoryActivityModel.fromFirestore).toList();
      final pending = all.where((a) => !a.seenBy.contains(uid)).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return pending;
    });
  }

  /// Marque l'activité comme validée POUR MOI seulement.
  static Future<void> markSeen(String activityId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _col.doc(activityId).update({
      'seenBy': FieldValue.arrayUnion([uid]),
    });
  }
}
