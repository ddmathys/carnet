import 'package:cloud_firestore/cloud_firestore.dart';

/// Une mesure taille/poids datée.
///
/// Historiquement, chaque mesure était un document `memories` à part entière
/// (type `taille_poids`, champs plats `heightCm`/`weightKg`) : dix pesées =
/// dix souvenirs, donc dix lignes à cocher au moment de composer un livre.
/// Désormais toutes les mesures d'un tag vivent dans le tableau
/// `measurements` d'UN SEUL souvenir — un par tag — que l'on met à jour à
/// chaque nouvelle pesée.
///
/// Les noms de champs (`date`, `heightCm`, `weightKg`, `mediaKeys`,
/// `rawContent`) sont volontairement identiques à ceux de `MemoryModel` : les
/// graphiques et les listes qui manipulaient des souvenirs continuent de
/// fonctionner en changeant seulement le type déclaré.
class GrowthMeasurement {
  /// Identifiant stable de l'entrée à l'intérieur du tableau. Sans lui, éditer
  /// ou supprimer une mesure imposerait de la retrouver par position, ce qui
  /// casse dès qu'une autre mesure est insérée avant elle.
  final String id;

  /// Souvenir porteur. Renseigné à la lecture, jamais persisté dans l'entrée :
  /// c'est ce qui permet à l'écran d'édition de savoir quel document mettre à
  /// jour sans le rechercher à nouveau.
  final String memoryId;

  final DateTime date;
  final String datePrecision; // 'exact' | 'month' | 'quarter'
  final String? dateLabel;
  final double? heightCm;
  final double? weightKg;

  /// Commentaire libre saisi avec la mesure.
  final String rawContent;

  /// Photo(s) de la mesure, clés d'objets R2 (une par mesure en pratique).
  final List<String> mediaKeys;

  const GrowthMeasurement({
    required this.id,
    this.memoryId = '',
    required this.date,
    this.datePrecision = 'exact',
    this.dateLabel,
    this.heightCm,
    this.weightKg,
    this.rawContent = '',
    this.mediaKeys = const [],
  });

  bool get isEmpty => heightCm == null && weightKg == null;

  factory GrowthMeasurement.fromMap(Map<String, dynamic> d,
      {String memoryId = ''}) {
    final rawDate = d['date'];
    final date = rawDate is Timestamp ? rawDate.toDate() : DateTime.now();
    final storedId = d['id'] as String?;
    return GrowthMeasurement(
      // Repli sur la date si l'entrée n'a pas d'id : les fusions indexent les
      // mesures par id, et deux entrées partageant un id vide n'en feraient
      // plus qu'une.
      id: (storedId != null && storedId.isNotEmpty)
          ? storedId
          : 'd${date.microsecondsSinceEpoch.toRadixString(36)}',
      memoryId: memoryId,
      date: date,
      datePrecision: d['datePrecision'] ?? 'exact',
      dateLabel: d['dateLabel'],
      heightCm: (d['heightCm'] as num?)?.toDouble(),
      weightKg: (d['weightKg'] as num?)?.toDouble(),
      rawContent: d['rawContent'] ?? '',
      mediaKeys: List<String>.from(d['mediaKeys'] ?? const []),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'date': Timestamp.fromDate(date),
        'datePrecision': datePrecision,
        'dateLabel': dateLabel,
        'heightCm': heightCm,
        'weightKg': weightKg,
        'rawContent': rawContent,
        'mediaKeys': mediaKeys,
      };

  GrowthMeasurement copyWith({
    String? id,
    String? memoryId,
    DateTime? date,
    String? datePrecision,
    String? dateLabel,
    double? heightCm,
    double? weightKg,
    String? rawContent,
    List<String>? mediaKeys,
  }) =>
      GrowthMeasurement(
        id: id ?? this.id,
        memoryId: memoryId ?? this.memoryId,
        date: date ?? this.date,
        datePrecision: datePrecision ?? this.datePrecision,
        dateLabel: dateLabel ?? this.dateLabel,
        heightCm: heightCm ?? this.heightCm,
        weightKg: weightKg ?? this.weightKg,
        rawContent: rawContent ?? this.rawContent,
        mediaKeys: mediaKeys ?? this.mediaKeys,
      );

  /// Identifiant unique pour une nouvelle entrée. L'horodatage suffit : une
  /// seule mesure est enregistrée à la fois, depuis un seul appareil.
  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}
