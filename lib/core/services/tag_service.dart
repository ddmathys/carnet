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

  /// Nature d'un tag déduite de son libellé (et du contexte de création).
  ///
  /// C'est ce `kind` qui range le tag dans une catégorie du filtre : `annee` →
  /// Date, `lieu` → Lieu, le reste → Événement. Sans cette déduction, un tag de
  /// lieu créé depuis le formulaire (ou une année tapée à la main) retombait en
  /// `libre` et la catégorie « Lieu » du filtre restait désespérément vide.
  static String inferKind(String label, {bool isLocation = false}) {
    final clean = label.trim();
    if (RegExp(r'^\d{4}$').hasMatch(clean)) return 'annee';
    if (isLocation) return 'lieu';
    return 'libre';
  }

  /// Retourne le tag portant ce libellé, en le créant s'il n'existe pas encore.
  /// La comparaison ignore la casse : « Été » et « été » sont le même tag.
  ///
  /// Si le tag existe déjà mais sans nature (`libre`) alors qu'on en connaît
  /// une meilleure (année, lieu, enfant), on la lui donne au passage — les tags
  /// créés avant cette règle se rangent ainsi tout seuls dans le filtre.
  static Future<TagModel?> ensureTag(String label, {String kind = 'libre'}) async {
    final uid = _uid;
    final clean = label.trim();
    if (uid == null || clean.isEmpty) return null;

    final existing = await myTags();
    for (final t in existing) {
      if (t.label.toLowerCase() != clean.toLowerCase()) continue;
      if (t.kind == 'libre' && kind != 'libre') {
        await _col.doc(t.id).update({'kind': kind});
        return TagModel(
          id: t.id,
          userId: t.userId,
          label: t.label,
          kind: kind,
          color: t.color,
          birthdate: t.birthdate,
          gender: t.gender,
          companion: t.companion,
          companionName: t.companionName,
          sharedWith: t.sharedWith,
          invitedEmails: t.invitedEmails,
          createdAt: t.createdAt,
        );
      }
      return t;
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

  // ── Réparation ─────────────────────────────────────────────────────────────

  /// Remet de l'ordre dans les tags de l'utilisateur (lancée au démarrage) :
  ///
  ///  1. **fusionne les doublons** — deux tags « 2025 » (un créé par la migration
  ///     des carnets, l'autre à la volée) apparaissaient deux fois dans le
  ///     filtre. On garde le plus ancien, on lui réunit les collaborateurs des
  ///     autres, on repointe les souvenirs, et on supprime les doublons ;
  ///  2. **rend sa nature à chaque tag** — une année devient `annee`, un libellé
  ///     qui est le lieu d'un souvenir devient `lieu`. C'est ce qui fait
  ///     apparaître la catégorie « Lieu » dans le filtre, à côté de Date et
  ///     Événement.
  ///
  /// N'écrit que s'il y a quelque chose à corriger.
  static Future<void> repairTags() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final tags = await myTags();
      if (tags.isEmpty) return;

      final groups = <String, List<TagModel>>{};
      for (final t in tags) {
        groups.putIfAbsent(t.label.trim().toLowerCase(), () => []).add(t);
      }
      final hasDuplicates = groups.values.any((g) => g.length > 1);
      final hasUnclassified = tags.any((t) => t.kind == 'libre');
      if (!hasDuplicates && !hasUnclassified) return;

      // Les lieux réellement utilisés par les souvenirs : c'est eux qui font
      // qu'un tag est un tag de lieu.
      final memSnap = await _db
          .collection('memories')
          .where('userId', isEqualTo: uid)
          .get();
      final locations = <String>{
        for (final d in memSnap.docs)
          ((d.data()['location'] as String?) ?? '').trim().toLowerCase(),
      }..remove('');

      final keptByGroup = <String, TagModel>{};
      final replacedBy = <String, String>{}; // id du doublon → id du tag gardé
      final tagBatch = _db.batch();
      var tagWrites = 0;

      for (final entry in groups.entries) {
        final sorted = [...entry.value]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        final keep = sorted.first;
        final dups = sorted.skip(1).toList();
        keptByGroup[entry.key] = keep;

        final update = <String, dynamic>{};

        final wanted =
            inferKind(keep.label, isLocation: locations.contains(entry.key));
        if (keep.kind == 'libre' && wanted != 'libre') {
          update['kind'] = wanted;
        }
        // Un doublon peut porter des collaborateurs que le tag gardé n'a pas :
        // les perdre reviendrait à révoquer un partage sans le dire.
        final shared = <String>{
          ...keep.sharedWith,
          for (final d in dups) ...d.sharedWith,
        };
        final invited = <String>{
          ...keep.invitedEmails,
          for (final d in dups) ...d.invitedEmails,
        };
        if (shared.length != keep.sharedWith.length) {
          update['sharedWith'] = shared.toList();
        }
        if (invited.length != keep.invitedEmails.length) {
          update['invitedEmails'] = invited.toList();
        }
        if (update.isNotEmpty) {
          tagBatch.update(_col.doc(keep.id), update);
          tagWrites++;
        }
        for (final d in dups) {
          replacedBy[d.id] = keep.id;
          tagBatch.delete(_col.doc(d.id));
          tagWrites++;
        }
      }

      if (tagWrites > 0) await tagBatch.commit();
      if (replacedBy.isEmpty) return;

      // Les souvenirs pointent encore sur les doublons : on les repointe sur le
      // tag gardé (et on re-dérive leurs libellés).
      final kept = await myTags();
      final labelById = {for (final t in kept) t.id: t.label};
      final tagsById = {for (final t in kept) t.id: t};

      final memBatch = _db.batch();
      var memWrites = 0;
      for (final doc in memSnap.docs) {
        final ids = List<String>.from(doc.data()['tagIds'] ?? []);
        if (!ids.any(replacedBy.containsKey)) continue;
        final fixed = <String>{
          for (final id in ids) replacedBy[id] ?? id,
        }.toList();
        memBatch.update(doc.reference, {
          'tagIds': fixed,
          'tagLabels': [
            for (final id in fixed)
              if ((labelById[id] ?? '').isNotEmpty) labelById[id]!,
          ],
          'sharedWith': _sharedUnion(fixed, tagsById, uid),
        });
        memWrites++;
      }
      if (memWrites > 0) await memBatch.commit();
    } catch (_) {
      // Réparation best-effort : un échec ne doit pas empêcher l'app de démarrer.
    }
  }

  // ── Partage ────────────────────────────────────────────────────────────────

  /// Lien d'invitation partageable, pour UN ou PLUSIEURS tags.
  ///
  /// C'est la seule façon d'inviter : le backend (Admin SDK) ajoute l'arrivant
  /// aux tags ET recopie son uid sur les souvenirs déjà tagués. Une invitation
  /// par email seule ne pourrait pas faire cette seconde écriture — l'invité n'a
  /// pas le droit d'écrire chez le propriétaire tant qu'il n'a pas rejoint.
  ///
  /// Un seul lien couvre tous les tags donnés : celui qui le suit les rejoint
  /// tous d'un coup, et voit leurs souvenirs (présents et à venir).
  static Future<({String url, String downloadUrl, String title})?>
      createInviteLink(List<String> tagIds) async {
    if (tagIds.isEmpty) return null;
    final data = await BackendClient.postJson(
      '/api/tag/invite',
      {'tagIds': tagIds},
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
