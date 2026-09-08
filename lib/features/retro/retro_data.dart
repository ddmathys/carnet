import 'package:intl/intl.dart';
import '../../core/models/memory_model.dart';
import '../../core/models/tag_model.dart';
import '../tags/tag_picker_sheet.dart' show TagCategory, categoryOf;

/// Données de la rétrospective — calculées **100 % côté client** à partir des
/// souvenirs déjà en cache (aucun appel réseau, aucune IA). Le récit de chaque
/// mois est, pour l'instant, la matière réelle des souvenirs (leurs
/// descriptions) ; l'emplacement du texte est prévu pour, plus tard, être
/// remplacé par une génération.

/// Un sujet possible de rétrospective : un tag (personne, lieu, date…) avec de
/// quoi donner envie de l'ouvrir — nombre de souvenirs et plage d'années.
class RetroSubject {
  final String tagId;
  final String label;
  final TagCategory category;
  final int count;
  final int firstYear;
  final int lastYear;
  // Photo de tête (clé R2) et couleur du tag — pour la pastille de l'écran de
  // choix du sujet. `color` a toujours une valeur (palette du tag).
  final String? photoKey;
  final String color;

  const RetroSubject({
    required this.tagId,
    required this.label,
    required this.category,
    required this.count,
    required this.firstYear,
    required this.lastYear,
    this.photoKey,
    this.color = '#C4714B',
  });

  /// « 2015–2026 », ou « 2019 » si tout tient sur une année.
  String get rangeLabel =>
      firstYear == lastYear ? '$firstYear' : '$firstYear–$lastYear';

  /// Une personne taguée sur au moins un souvenir est proposée comme sujet —
  /// pas de seuil minimum (David préfère voir apparaître une personne tout de
  /// suite, quitte à ce que son récit soit encore court).
  static const int minMemories = 1;

  /// Sujets éligibles (≥ [minMemories] souvenirs), tous types confondus, triés
  /// par richesse décroissante. Calculé depuis les souvenirs visibles.
  static List<RetroSubject> eligible(
    List<MemoryModel> memories,
    List<TagModel> tags, {
    int min = minMemories,
  }) {
    final byTag = <String, List<MemoryModel>>{};
    for (final m in memories) {
      for (final id in m.tagIds) {
        byTag.putIfAbsent(id, () => []).add(m);
      }
    }
    final tagById = {for (final t in tags) t.id: t};
    final out = <RetroSubject>[];
    byTag.forEach((id, mems) {
      if (mems.length < min) return;
      final tag = tagById[id];
      if (tag == null) return;
      final years = mems.map((m) => m.date.year).toList()..sort();
      out.add(RetroSubject(
        tagId: id,
        label: tag.label,
        category: categoryOf(tag),
        count: mems.length,
        firstYear: years.first,
        lastYear: years.last,
        photoKey: tag.photoKey,
        color: tag.color,
      ));
    });
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}

/// Données déjà en cache transmises à l'écran de lecture (souvenirs + tags) —
/// l'écran de choix du sujet les a déjà chargées (et les tient à jour en
/// temps réel) ; les redemander en ouvrant un sujet ferait clignoter un
/// écran de chargement à chaque sélection pour rien.
class RetroViewArgs {
  final RetroSubject subject;
  final List<MemoryModel> memories;
  final List<TagModel> tags;

  const RetroViewArgs({
    required this.subject,
    required this.memories,
    required this.tags,
  });
}

/// Une section mensuelle de la timeline : un mois, ses souvenirs, et jusqu'à 3
/// souvenirs « héros » (les mieux notés qui portent une photo).
class RetroSection {
  final int year;
  final int month;
  final String label; // « Janvier 2025 »
  final List<MemoryModel> memories;
  final List<MemoryModel> heroes; // 1 à 3, porteurs de photo

  const RetroSection({
    required this.year,
    required this.month,
    required this.label,
    required this.memories,
    required this.heroes,
  });

  /// Le « récit » du mois sans IA : les descriptions réelles non vides des
  /// souvenirs, mises bout à bout. Vide si le mois n'a que des photos.
  String get narrative {
    final parts = <String>[];
    for (final m in memories) {
      final t = m.rawContent.trim();
      if (t.isNotEmpty) parts.add(t);
    }
    return parts.join('\n\n');
  }
}

/// Rétrospective complète d'un sujet, prête à afficher.
class RetroData {
  final RetroSubject subject;
  final List<RetroSection> sections; // chronologiques (ancien → récent)
  final Map<int, int> yearHistogram; // année → nb de souvenirs
  final int? densestYear;
  final String? topCoTagLabel; // tag co-occurrent le plus fréquent
  final int placeCount; // lieux distincts traversés

  const RetroData({
    required this.subject,
    required this.sections,
    required this.yearHistogram,
    required this.densestYear,
    required this.topCoTagLabel,
    required this.placeCount,
  });

  /// Toutes les années de la plage, y compris celles sans souvenir (barre à
  /// zéro) — pour ne pas fausser la perception de la durée dans la ligne de
  /// temps.
  List<int> get years => [
        for (var y = subject.firstYear; y <= subject.lastYear; y++) y,
      ];

  int get maxYearCount =>
      yearHistogram.values.fold(0, (a, b) => a > b ? a : b);

  /// Index de la première section d'une année donnée (pour la navigation depuis
  /// la ligne de temps), ou -1 si l'année n'a aucun souvenir.
  int firstSectionIndexOfYear(int year) =>
      sections.indexWhere((s) => s.year == year);

  static final _monthFmt = DateFormat('MMMM yyyy', 'fr');

  /// Construit la rétrospective d'un [subject] à partir des souvenirs visibles.
  static RetroData build(
    RetroSubject subject,
    List<MemoryModel> allMemories,
    List<TagModel> tags,
  ) {
    final mems = allMemories
        .where((m) => m.tagIds.contains(subject.tagId))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    // Regroupement par (année, mois).
    final groups = <int, List<MemoryModel>>{}; // clé = année*100 + mois
    final histogram = <int, int>{};
    for (final m in mems) {
      final key = m.date.year * 100 + m.date.month;
      groups.putIfAbsent(key, () => []).add(m);
      histogram.update(m.date.year, (v) => v + 1, ifAbsent: () => 1);
    }

    final keys = groups.keys.toList()..sort();
    final sections = <RetroSection>[];
    for (final key in keys) {
      final ms = groups[key]!;
      final year = key ~/ 100;
      final month = key % 100;
      final heroes = _heroes(ms);
      final label = _monthFmt.format(DateTime(year, month));
      sections.add(RetroSection(
        year: year,
        month: month,
        label: '${label[0].toUpperCase()}${label.substring(1)}',
        memories: ms,
        heroes: heroes,
      ));
    }

    // Année la plus dense.
    int? densest;
    var densestN = -1;
    histogram.forEach((y, n) {
      if (n > densestN) {
        densestN = n;
        densest = y;
      }
    });

    // Tag co-occurrent le plus fréquent (hors le sujet lui-même et hors années,
    // qui co-occurrent trivialement). Résolu en libellé.
    final tagById = {for (final t in tags) t.id: t};
    final coCount = <String, int>{};
    for (final m in mems) {
      for (final id in m.tagIds) {
        if (id == subject.tagId) continue;
        final t = tagById[id];
        if (t == null || t.kind == 'annee') continue;
        coCount.update(id, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    String? topCoLabel;
    var topN = 0;
    coCount.forEach((id, n) {
      if (n > topN) {
        topN = n;
        topCoLabel = tagById[id]?.label;
      }
    });

    // Lieux distincts traversés (champ `location` des souvenirs).
    final places = <String>{
      for (final m in mems) (m.location ?? '').trim().toLowerCase(),
    }..remove('');

    return RetroData(
      subject: subject,
      sections: sections,
      yearHistogram: histogram,
      densestYear: densest,
      topCoTagLabel: topCoLabel,
      placeCount: places.length,
    );
  }

  /// Jusqu'à 3 souvenirs porteurs de photo, les mieux notés du mois.
  /// L'idée : là où l'utilisateur a mis de l'intention (il a écrit, taggé,
  /// enregistré sa voix, donné un titre), il y a de la valeur émotionnelle.
  static List<MemoryModel> _heroes(List<MemoryModel> monthMemories) {
    final withPhoto = monthMemories.where(_hasPhoto).toList()
      ..sort((a, b) => _score(b).compareTo(_score(a)));
    return withPhoto.take(3).toList();
  }

  static bool _hasPhoto(MemoryModel m) =>
      m.mediaKeys.isNotEmpty ||
      m.mediaUrls.isNotEmpty ||
      (m.photoUrl != null && m.photoUrl!.isNotEmpty);

  static int _score(MemoryModel m) {
    var s = 0;
    if (m.rawContent.trim().length > 80) s += 3; // description soignée
    s += m.tagIds.length; // +1 par tag
    if ((m.audioKey?.isNotEmpty ?? false) ||
        (m.audioUrl?.isNotEmpty ?? false)) {
      s += 2; // mémo vocal
    }
    if (m.title?.trim().isNotEmpty ?? false) s += 2; // titre donné
    return s;
  }
}
