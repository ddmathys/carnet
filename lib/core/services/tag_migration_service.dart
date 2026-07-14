import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'space_service.dart';

/// Migration « carnets → tags » (une seule fois par utilisateur).
///
/// Chaque carnet devient un tag de même nom (couleur, partage et — pour un
/// carnet enfant — date de naissance repris tels quels), et ses souvenirs :
///  - reçoivent ce tag, plus le tag de leur année ;
///  - reçoivent `userId` (propriétaire) et `sharedWith` (réunion des tags), les
///    deux champs sur lesquels reposent désormais les règles Firestore ;
///  - sont rattachés à l'espace unique de l'utilisateur (`notebookId`).
///
/// Les carnets ne sont PAS supprimés : ils restent le porteur technique
/// (quotas, clés R2), simplement invisibles. L'indicateur de passage vit dans
/// Firestore (`users/{uid}.tagsMigratedAt`) et non sur l'appareil, pour ne pas
/// rejouer la migration sur un second téléphone.
class TagMigrationService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> runIfNeeded() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final userRef = _db.collection('users').doc(uid);
      final userDoc = await userRef.get();
      if (userDoc.exists && userDoc.data()?['tagsMigratedAt'] != null) return;

      final spaceId = await SpaceService.ensureSpaceId();
      if (spaceId == null) return;

      final notebooks =
          await _db.collection('notebooks').where('userId', isEqualTo: uid).get();

      // 1) Un tag par carnet.
      final tagIdByNotebook = <String, String>{};
      final sharedByTag = <String, List<String>>{};
      for (final nb in notebooks.docs) {
        final d = nb.data();
        final title = (d['title'] ?? d['firstName'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final shared = List<String>.from(d['sharedWith'] ?? []);
        final tagRef = _db.collection('tags').doc();
        await tagRef.set({
          'userId': uid,
          'label': title,
          'kind': d['type'] == 'enfant' ? 'enfant' : 'libre',
          'color': d['coverColor'] ?? '#C4714B',
          if (d['birthdate'] != null) 'birthdate': d['birthdate'],
          if (d['gender'] != null) 'gender': d['gender'],
          if (d['companion'] != null) 'companion': d['companion'],
          if (d['companionName'] != null) 'companionName': d['companionName'],
          'sharedWith': shared,
          'invitedEmails': List<String>.from(d['invitedEmails'] ?? []),
          'createdAt': d['createdAt'] ?? FieldValue.serverTimestamp(),
        });
        tagIdByNotebook[nb.id] = tagRef.id;
        sharedByTag[tagRef.id] = shared;
      }

      // 2) Tags d'année, créés à la demande pendant le parcours des souvenirs.
      // On REPREND un tag existant de même libellé s'il y en a un (l'app a pu en
      // créer un avant que la migration ne tourne) — sans quoi on se retrouve
      // avec deux « 2025 » dans le filtre.
      final existingTags =
          await _db.collection('tags').where('userId', isEqualTo: uid).get();
      final yearTagIds = <int, String>{
        for (final d in existingTags.docs)
          if (int.tryParse(
                  ((d.data()['label'] ?? '') as String).trim()) !=
              null)
            int.parse(((d.data()['label'] ?? '') as String).trim()): d.id,
      };
      Future<String> yearTag(int year) async {
        final cached = yearTagIds[year];
        if (cached != null) return cached;
        final ref = _db.collection('tags').doc();
        await ref.set({
          'userId': uid,
          'label': '$year',
          'kind': 'annee',
          'color': '#B8834F',
          'sharedWith': <String>[],
          'invitedEmails': <String>[],
          'createdAt': FieldValue.serverTimestamp(),
        });
        yearTagIds[year] = ref.id;
        return ref.id;
      }

      // 3) Les souvenirs : tags, propriétaire, partage, espace.
      final tagLabelById = <String, String>{};
      for (final nb in notebooks.docs) {
        final tagId = tagIdByNotebook[nb.id];
        if (tagId != null) {
          tagLabelById[tagId] =
              (nb.data()['title'] ?? nb.data()['firstName'] ?? '').toString();
        }
      }

      for (final nb in notebooks.docs) {
        final tagId = tagIdByNotebook[nb.id];
        final memories = await _db
            .collection('memories')
            .where('notebookId', isEqualTo: nb.id)
            .get();
        for (final mem in memories.docs) {
          final data = mem.data();
          final date = (data['date'] as Timestamp?)?.toDate() ?? DateTime.now();
          final yTag = await yearTag(date.year);
          tagLabelById[yTag] = '${date.year}';

          final ids = <String>{
            ...List<String>.from(data['tagIds'] ?? []),
            if (tagId != null) tagId,
            yTag,
          }.toList();
          final shared = <String>{
            for (final id in ids) ...(sharedByTag[id] ?? const <String>[]),
          }..remove(uid);

          await mem.reference.update({
            'notebookId': spaceId,
            'userId': uid,
            'tagIds': ids,
            'tagLabels': [
              for (final id in ids)
                if ((tagLabelById[id] ?? '').isNotEmpty) tagLabelById[id]!,
            ],
            'sharedWith': shared.toList(),
          });
        }
      }

      await userRef.set(
        {'tagsMigratedAt': FieldValue.serverTimestamp()},
        SetOptions(merge: true),
      );
    } catch (_) {
      // Migration best-effort : un échec (réseau, permissions) ne doit pas
      // empêcher l'app de démarrer — elle sera retentée au prochain lancement.
    }
  }
}
