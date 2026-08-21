import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/growth_measurement.dart';
import '../models/memory_model.dart';
import 'space_service.dart';
import 'tag_service.dart';

/// Écriture et regroupement des mesures taille/poids.
///
/// Règle : **un seul souvenir `taille_poids` par tag**, qui accumule toutes les
/// mesures dans son tableau `measurements`. Avant, chaque pesée créait son
/// propre document — d'où autant de lignes à cocher dans le sélecteur de
/// souvenirs du livre qu'il y avait eu de pesées.
///
/// Les anciens documents ne sont pas laissés de côté : [consolidate] les fusionne
/// dans le souvenir porteur dès qu'on ouvre l'écran Croissance ou qu'on
/// enregistre une mesure. En attendant, [collect] sait lire les deux formats,
/// donc une courbe reste correcte même avant fusion.
class GrowthMeasurementService {
  static const String memoryType = 'taille_poids';

  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('memories');

  /// Toutes les mesures portées par [memories], tous souvenirs confondus,
  /// triées par date croissante.
  static List<GrowthMeasurement> collect(Iterable<MemoryModel> memories) {
    final out = <GrowthMeasurement>[];
    for (final m in memories) {
      if (m.type != memoryType) continue;
      out.addAll(m.measurements.where((e) => !e.isEmpty));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// Souvenirs `taille_poids` portant [tagId], le plus ancien d'abord.
  ///
  /// Le plus ancien fait foi : c'est lui qu'on garde comme porteur, pour que
  /// l'id du souvenir ne change pas sous les pieds d'un livre déjà composé.
  static List<MemoryModel> _carriersFor(
          Iterable<MemoryModel> memories, String tagId) =>
      memories
          .where((m) => m.type == memoryType && m.tagIds.contains(tagId))
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  /// Relit les souvenirs porteurs depuis Firestore.
  ///
  /// Comme ailleurs dans l'app, les souvenirs possédés et ceux partagés via un
  /// tag viennent de deux requêtes (Firestore ne sait pas faire un OR entre
  /// deux champs), fusionnées par id. Le filtrage type/tag se fait côté client
  /// pour ne pas imposer d'index composite.
  static Future<List<MemoryModel>> _fetchCarriers(String tagId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];
    final results = await Future.wait([
      _col.where('userId', isEqualTo: uid).get(),
      _col.where('sharedWith', arrayContains: uid).get(),
    ]);
    final byId = <String, MemoryModel>{};
    for (final snap in results) {
      for (final doc in snap.docs) {
        byId[doc.id] = MemoryModel.fromFirestore(doc);
      }
    }
    return _carriersFor(byId.values, tagId);
  }

  /// Fusionne les éventuels souvenirs multiples d'un tag en un seul.
  ///
  /// Ne fait rien s'il n'y en a qu'un (le cas normal une fois migré), pour ne
  /// pas réécrire un document à chaque ouverture d'écran. Renvoie `true` si une
  /// fusion a bien eu lieu.
  static Future<bool> consolidate({
    required String tagId,
    required String tagLabel,
    required List<MemoryModel> memories,
  }) async {
    final carriers = _carriersFor(memories, tagId);
    if (carriers.length < 2) return false;

    final target = carriers.first;
    final merged = <String, GrowthMeasurement>{};
    for (final m in carriers) {
      for (final e in m.measurements) {
        if (e.isEmpty) continue;
        merged[e.id] = e;
      }
    }
    final entries = merged.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final batch = FirebaseFirestore.instance.batch();
    batch.update(_col.doc(target.id), _carrierPayload(entries, tagLabel));
    for (final m in carriers.skip(1)) {
      batch.delete(_col.doc(m.id));
    }
    await batch.commit();
    return true;
  }

  /// Ajoute ou remplace une mesure dans le souvenir du tag, en le créant s'il
  /// n'existe pas encore. Passer [memories] (la liste déjà chargée par l'écran
  /// appelant) évite une relecture ; sinon les porteurs sont relus.
  ///
  /// Renvoie l'id du souvenir porteur.
  static Future<String> saveMeasurement({
    required String tagId,
    required String tagLabel,
    required GrowthMeasurement entry,
    List<MemoryModel>? memories,
    List<String> extraTagLabels = const [],
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final spaceId = await SpaceService.ensureSpaceId() ?? '';

    final tagIds = <String>[tagId];
    final tagLabels = <String>[tagLabel];
    for (final label in extraTagLabels) {
      if (label == tagLabel) continue;
      final tag = await TagService.ensureTag(label,
          kind: TagService.inferKind(label));
      if (tag == null || tagIds.contains(tag.id)) continue;
      tagIds.add(tag.id);
      tagLabels.add(tag.label);
    }
    final allTags = await TagService.visibleTags();
    final sharedWith = TagService.sharedUidsFor(tagIds, allTags, uid);

    final carriers = memories != null
        ? _carriersFor(memories, tagId)
        : await _fetchCarriers(tagId);

    // Toutes les mesures connues du tag, la nouvelle écrasant l'entrée de même
    // id (cas d'une édition).
    final merged = <String, GrowthMeasurement>{};
    for (final m in carriers) {
      for (final e in m.measurements) {
        if (e.isEmpty) continue;
        merged[e.id] = e;
      }
    }
    merged[entry.id] = entry;
    final entries = merged.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final payload = {
      ..._carrierPayload(entries, tagLabel),
      'notebookId': spaceId,
      'userId': uid,
      'tagIds': tagIds,
      'tagLabels': tagLabels,
      'sharedWith': sharedWith,
      'type': memoryType,
      'subType': null,
    };

    if (carriers.isEmpty) {
      final doc = await _col.add({...payload, 'createdAt': Timestamp.now()});
      return doc.id;
    }

    final target = carriers.first;
    final batch = FirebaseFirestore.instance.batch();
    batch.update(_col.doc(target.id), payload);
    // Une édition peut avoir lieu alors que d'anciens documents traînent
    // encore : on en profite pour finir la fusion, sinon leurs mesures
    // reviendraient en double au prochain chargement.
    for (final m in carriers.skip(1)) {
      batch.delete(_col.doc(m.id));
    }
    await batch.commit();
    return target.id;
  }

  /// Supprime une mesure. Le souvenir porteur disparaît avec sa dernière
  /// mesure — un souvenir « croissance » sans aucune mesure n'aurait rien à
  /// afficher ni dans l'app ni dans le livre.
  static Future<void> deleteMeasurement({
    required String tagId,
    required String tagLabel,
    required String entryId,
    List<MemoryModel>? memories,
  }) async {
    final carriers = memories != null
        ? _carriersFor(memories, tagId)
        : await _fetchCarriers(tagId);
    if (carriers.isEmpty) return;

    final merged = <String, GrowthMeasurement>{};
    for (final m in carriers) {
      for (final e in m.measurements) {
        if (e.isEmpty) continue;
        merged[e.id] = e;
      }
    }
    merged.remove(entryId);
    final entries = merged.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final batch = FirebaseFirestore.instance.batch();
    if (entries.isEmpty) {
      for (final m in carriers) {
        batch.delete(_col.doc(m.id));
      }
    } else {
      batch.update(
          _col.doc(carriers.first.id), _carrierPayload(entries, tagLabel));
      for (final m in carriers.skip(1)) {
        batch.delete(_col.doc(m.id));
      }
    }
    await batch.commit();
  }

  /// Champs du souvenir porteur déduits de ses mesures.
  static Map<String, dynamic> _carrierPayload(
      List<GrowthMeasurement> entries, String tagLabel) {
    final last = entries.isNotEmpty ? entries.last : null;
    return {
      'measurements': entries.map((e) => e.toMap()).toList(),
      'title': 'Courbe de croissance · $tagLabel',
      'rawContent': _summary(entries),
      // La date du souvenir suit la dernière mesure : c'est elle qui situe la
      // courbe dans les listes triées par date.
      'date': Timestamp.fromDate(last?.date ?? DateTime.now()),
      'datePrecision': 'exact',
      'dateLabel': null,
      // Les photos des mesures restent accessibles depuis le souvenir (choix
      // de couverture, compteurs) ; chacune reste par ailleurs rattachée à son
      // entrée.
      'mediaKeys': [for (final e in entries) ...e.mediaKeys],
      'mediaUrls': const <String>[],
      'photoUrl': null,
      // Les champs plats d'origine n'ont plus de sens sur un souvenir qui porte
      // plusieurs mesures : on les vide pour qu'aucun ancien code de lecture ne
      // les prenne pour la seule mesure du tag.
      'heightCm': null,
      'weightKg': null,
    };
  }

  static String _summary(List<GrowthMeasurement> entries) {
    if (entries.isEmpty) return 'Aucune mesure';
    final last = entries.last;
    final parts = <String>[];
    if (last.heightCm != null) {
      parts.add('${last.heightCm!.toStringAsFixed(0)} cm');
    }
    if (last.weightKg != null) {
      parts.add('${last.weightKg!.toStringAsFixed(1)} kg');
    }
    final count =
        entries.length == 1 ? '1 mesure' : '${entries.length} mesures';
    return parts.isEmpty ? count : '$count · dernière : ${parts.join(', ')}';
  }
}
