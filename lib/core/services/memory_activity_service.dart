import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/memory_activity_model.dart';

/// Fil d'activité "photos/vidéos ajoutées à un souvenir" — s'applique aussi
/// bien à un souvenir partagé (chaque collaborateur voit l'activité des
/// autres) qu'à un souvenir perso (l'auteur voit sa propre confirmation :
/// médias ajoutés, date, souvenir concerné). Chaque destinataire doit
/// "valider" (fermer) la notification de son côté.
class MemoryActivityService {
  static final _col = FirebaseFirestore.instance.collection('memoryActivities');

  /// Enregistre une activité. `recipients` doit déjà inclure l'auteur — voir
  /// l'appelant (memory_create_screen.dart::_save) pour le calcul exact.
  /// Best-effort : ne bloque jamais la sauvegarde du souvenir lui-même si ça
  /// échoue (même philosophie que BookHistoryService.recordBook) — mais
  /// l'erreur est quand même tracée (debugPrint) pour rester diagnosticable,
  /// contrairement à l'ancien catch totalement silencieux.
  static Future<void> record({
    required String memoryId,
    required String memoryTitle,
    required String kind,
    required int photosAdded,
    required int videosAdded,
    required List<String> recipients,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || recipients.isEmpty) return;
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
    } catch (e) {
      debugPrint('MemoryActivityService.record a échoué : $e');
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
