import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/tag_model.dart';
import 'backend_client.dart';

/// Tags : l'organisation des souvenirs, et le point de pilotage du partage.
///
/// Règle d'or : un souvenir porte `tagIds` + `sharedWith`. Le `sharedWith` du
/// souvenir est la RÉUNION des `sharedWith` de ses tags — recopié à chaque fois
/// qu'un partage ou un tag change. C'est cette dénormalisation qui permet aux
/// règles Firestore de trancher en lisant le seul document du souvenir.
class TagService {
  static final _db = FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('tags');

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Lecture ────────────────────────────────────────────────────────────────

  /// Tags dont l'utilisateur est propriétaire.
  static Stream<List<TagModel>> streamMine() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('userId', isEqualTo: uid).snapshots().map((s) {
      final tags = s.docs.map((d) => TagModel.fromFirestore(d)).toList()
        ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return tags;
    });
  }

  /// Tags partagés AVEC l'utilisateur par quelqu'un d'autre.
  static Stream<List<TagModel>> streamSharedWithMe() {
    final uid = _uid;
    if (uid == null) return Stream.value(const []);
    return _col.where('sharedWith', arrayContains: uid).snapshots().map((s) {
      final tags = s.docs.map((d) => TagModel.fromFirestore(d)).toList()
        ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      return tags;
    });
  }

  static Future<List<TagModel>> myTags() async {
    final uid = _uid;
    if (uid == null) return const [];
    final snap = await _col.where('userId', isEqualTo: uid).get();
    final tags = snap.docs.map((d) => TagModel.fromFirestore(d)).toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return tags;
  }

  /// Tous les tags visibles (les miens + ceux qu'on m'a partagés).
  static Future<List<TagModel>> visibleTags() async {
    final uid = _uid;
    if (uid == null) return const [];
    final results = await Future.wait([
      _col.where('userId', isEqualTo: uid).get(),
      _col.where('sharedWith', arrayContains: uid).get(),
    ]);
    final byId = <String, TagModel>{};
    for (final snap in results) {
      for (final d in snap.docs) {
        byId[d.id] = TagModel.fromFirestore(d);
      }
    }
    final tags = byId.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return tags;
  }

  static Future<TagModel?> byId(String tagId) async {
    final doc = await _col.doc(tagId).get();
    return doc.exists ? TagModel.fromFirestore(doc) : null;
  }

  // ── Création ───────────────────────────────────────────────────────────────

  /// Retourne le tag portant ce libellé, en le créant s'il n'existe pas encore.
  /// La comparaison ignore la casse : « Été » et « été » sont le même tag.
  static Future<TagModel?> ensureTag(String label, {String kind = 'libre'}) async {
    final uid = _uid;
    final clean = label.trim();
    if (uid == null || clean.isEmpty) return null;

    final existing = await myTags();
    for (final t in existing) {
      if (t.label.toLowerCase() == clean.toLowerCase()) return t;
    }

    final tag = TagModel(
      id: '',
      userId: uid,
      label: clean,
      kind: kind,
      color: _colorFor(clean),
      createdAt: DateTime.now(),
    );
    final ref = await _col.add(tag.toFirestore());
    final doc = await ref.get();
    return TagModel.fromFirestore(doc);
  }

  /// Tags posés d'office sur un nouveau souvenir : l'année et le lieu.
  /// L'utilisateur peut les retirer ensuite comme n'importe quel autre tag.
  static Future<List<TagModel>> autoTags({
    required DateTime date,
    String? location,
  }) async {
    final tags = <TagModel>[];
    final year = await ensureTag('${date.year}', kind: 'annee');
    if (year != null) tags.add(year);
    final place = location?.trim() ?? '';
    if (place.isNotEmpty) {
      final t = await ensureTag(place, kind: 'lieu');
      if (t != null) tags.add(t);
    }
    return tags;
  }

  /// Palette stable : deux tags de même nom gardent la même couleur d'un
  /// appareil à l'autre (couleur dérivée du libellé).
  static String _colorFor(String label) {
    const palette = [
      '#C4714B', // terracotta
      '#D98E63', // pêche
      '#8A6242', // brun
      '#A65D4E', // brique
      '#B8834F', // ocre
      '#7C6A5A', // taupe
    ];
    var h = 0;
    for (final c in label.toLowerCase().codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return palette[h % palette.length];
  }

  // ── Édition ────────────────────────────────────────────────────────────────

  static Future<void> rename(TagModel tag, String label) async {
    final clean = label.trim();
    if (clean.isEmpty || clean == tag.label) return;
    await _col.doc(tag.id).update({'label': clean});
    // Le libellé est recopié sur les souvenirs (affichage sans lecture des tags).
    final memories = await _memoriesWithTag(tag.id);
    final batch = _db.batch();
    for (final doc in memories) {
      final labels = List<String>.from(doc.data()['tagLabels'] ?? []);
      final ids = List<String>.from(doc.data()['tagIds'] ?? []);
      final i = ids.indexOf(tag.id);
      if (i >= 0 && i < labels.length) {
        labels[i] = clean;
      } else if (!labels.contains(clean)) {
        labels.add(clean);
      }
      batch.update(doc.reference, {'tagLabels': labels});
    }
    await batch.commit();
  }

  /// Supprime le tag et le retire des souvenirs (les souvenirs, eux, restent).
  static Future<void> delete(TagModel tag) async {
    final uid = _uid;
    if (uid == null) return;
    final memories = await _memoriesWithTag(tag.id);
    final tagsById = {for (final t in await myTags()) t.id: t};
    tagsById.remove(tag.id);

    final batch = _db.batch();
    for (final doc in memories) {
      final ids = List<String>.from(doc.data()['tagIds'] ?? [])
        ..remove(tag.id);
      final labels = [
        for (final id in ids) tagsById[id]?.label ?? '',
      ]..removeWhere((l) => l.isEmpty);
      batch.update(doc.reference, {
        'tagIds': ids,
        'tagLabels': labels,
        'sharedWith': _sharedUnion(ids, tagsById, uid),
      });
    }
    batch.delete(_col.doc(tag.id));
    await batch.commit();
  }

  // ── Partage ────────────────────────────────────────────────────────────────

  /// Lien d'invitation partageable (deep link `carnet://join?token=…`).
  ///
  /// C'est la seule façon d'inviter : le backend (Admin SDK) ajoute l'arrivant
  /// au tag ET recopie son uid sur les souvenirs déjà tagués. Une invitation par
  /// email seule ne pourrait pas faire cette seconde écriture — l'invité n'a pas
  /// le droit d'écrire chez le propriétaire tant qu'il n'a pas rejoint.
  static Future<({String url, String downloadUrl, String title})?>
      createInviteLink(String tagId) async {
    final data = await BackendClient.postJson(
      '/api/tag/invite',
      {'tagId': tagId},
      timeout: const Duration(seconds: 20),
    );
    final url = data?['url'] as String?;
    if (url == null) return null;
    return (
      url: url,
      downloadUrl: (data?['downloadUrl'] as String?) ??
          'https://dmathys.dev/download/carnet.apk',
      title: (data?['tagLabel'] as String?) ?? 'Tag',
    );
  }

  /// Rejoint un tag via le token d'un lien d'invitation.
  static Future<({String tagId, String label})?> joinByToken(String token) async {
    final data = await BackendClient.postJson(
      '/api/tag/join',
      {'token': token},
      timeout: const Duration(seconds: 20),
    );
    if (data != null && data['ok'] == true && data['tagId'] != null) {
      return (
        tagId: data['tagId'] as String,
        label: (data['label'] as String?) ?? 'Tag',
      );
    }
    return null;
  }

  /// Retire un collaborateur d'un tag. Il perd l'accès aux souvenirs de ce tag,
  /// sauf à ceux qu'un AUTRE tag partagé avec lui couvre encore.
  static Future<void> revoke(TagModel tag, {String? uid, String? email}) async {
    final update = <String, dynamic>{};
    if (uid != null) update['sharedWith'] = FieldValue.arrayRemove([uid]);
    if (email != null) {
      update['invitedEmails'] = FieldValue.arrayRemove([email.toLowerCase()]);
    }
    if (update.isEmpty) return;
    await _col.doc(tag.id).update(update);
    await _propagateSharing(tag.id);
  }

  /// Recopie les accès des tags sur les souvenirs concernés. Appelé après tout
  /// changement de partage ; les souvenirs qui portent le tag voient leur
  /// `sharedWith` recalculé à partir de TOUS leurs tags.
  static Future<void> _propagateSharing(String tagId) async {
    final uid = _uid;
    if (uid == null) return;
    final tagsById = {for (final t in await myTags()) t.id: t};
    final memories = await _memoriesWithTag(tagId);
    if (memories.isEmpty) return;
    final batch = _db.batch();
    for (final doc in memories) {
      final ids = List<String>.from(doc.data()['tagIds'] ?? []);
      batch.update(
          doc.reference, {'sharedWith': _sharedUnion(ids, tagsById, uid)});
    }
    await batch.commit();
  }

  /// Les UIDs qui doivent voir un souvenir portant [tagIds] : la réunion des
  /// collaborateurs de ses tags. À écrire dans le champ `sharedWith` du souvenir.
  ///
  /// [ownerUid] est le PROPRIÉTAIRE du souvenir (son champ `userId`), pas
  /// forcément celui qui enregistre : quand un collaborateur modifie un souvenir
  /// qu'on lui a partagé, il doit rester dans `sharedWith` — sinon il perdrait
  /// l'accès au souvenir qu'il vient d'éditer.
  static List<String> sharedUidsFor(
      List<String> tagIds, List<TagModel> allTags, String ownerUid) {
    final byId = {for (final t in allTags) t.id: t};
    return _sharedUnion(tagIds, byId, ownerUid);
  }

  static List<String> _sharedUnion(
      List<String> tagIds, Map<String, TagModel> tagsById, String ownerUid) {
    final uids = <String>{};
    for (final id in tagIds) {
      final t = tagsById[id];
      if (t == null) continue;
      uids.addAll(t.sharedWith);
      // Le propriétaire du tag doit voir ce qu'un collaborateur y dépose : sans
      // ça, un souvenir créé par l'invité serait invisible pour l'invitant.
      uids.add(t.userId);
    }
    uids.remove(ownerUid); // le propriétaire n'a pas besoin d'être « partagé »
    return uids.toList();
  }

  /// Souvenirs de l'utilisateur portant ce tag. On interroge par `userId` (ce
  /// que les règles autorisent sans index composite) et on filtre le tag côté
  /// client — le volume par utilisateur reste modeste.
  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
      _memoriesWithTag(String tagId) async {
    final uid = _uid;
    if (uid == null) return const [];
    final snap = await _db
        .collection('memories')
        .where('userId', isEqualTo: uid)
        .get();
    return snap.docs
        .where((d) =>
            List<String>.from(d.data()['tagIds'] ?? []).contains(tagId))
        .toList();
  }
}
