import 'puzzle_pricing.dart';

/// Contrôle qualité (DPI) par taille de puzzle — même raisonnement que
/// [PosterQualityService], mais en une seule photo et une seule zone
/// d'impression (pas de collage, pas d'orientation à choisir).
///
/// Pourquoi ce fichier existe (audit du 06.10.26) : les photos sont stockées
/// compressées à 2048 px sur le grand côté (`PhotoService._maxDimension`,
/// dimensionné pour une impression demi-page dans un livre), alors que la
/// zone d'impression du puzzle 1000 pièces fait 9035 × 6200 px. Sans garde,
/// l'app laissait commander un 1000 pièces à **68 DPI effectifs** — un objet
/// physique, payé, visiblement flou. Le poster avait ce contrôle depuis le
/// 20.08.26, le puzzle n'en avait aucun.
///
/// La résolution de référence (`idealDpi`) n'est pas recalculée depuis des mm
/// (risque d'arrondi) : on compare directement aux pixels de la zone
/// d'impression renvoyés par l'API Prodigi pour chaque SKU
/// (`PuzzlePricing.printAreaPx*`, confirmés à 300 DPI).
enum PuzzleQualityVerdict { ok, limited, disabled }

class PuzzleSizeQuality {
  final String size;
  final PuzzleQualityVerdict verdict;

  /// DPI réellement atteignable avec cette photo sur cette taille — null si
  /// les dimensions de la photo n'ont pas pu être lues.
  final double? achievableDpi;

  const PuzzleSizeQuality({
    required this.size,
    required this.verdict,
    this.achievableDpi,
  });

  bool get isOrderable => verdict != PuzzleQualityVerdict.disabled;
}

class PuzzleQualityService {
  static const double idealDpi = 300.0;
  static const double minDpi = 150.0;

  /// Évalue UNE taille pour UNE photo.
  ///
  /// Prodigi recadre la photo pour COUVRIR la zone d'impression
  /// (`sizing: 'fillPrintArea'`, voir backend/api/prodigi/[action].ts) : le
  /// facteur limitant est donc le plus petit des deux rapports, exactement
  /// comme pour une tuile de poster. Une photo portrait sur une zone paysage
  /// est pénalisée par ce `min`, et c'est voulu — c'est bien la largeur
  /// manquante qui sera étirée.
  static PuzzleSizeQuality evaluate({
    required String size,
    required ({int w, int h})? photoDims,
  }) {
    final entry = PuzzlePricing.entryFor(size);
    if (entry == null) {
      return PuzzleSizeQuality(size: size, verdict: PuzzleQualityVerdict.disabled);
    }
    if (photoDims == null ||
        photoDims.w <= 0 ||
        photoDims.h <= 0 ||
        entry.printAreaPxW <= 0 ||
        entry.printAreaPxH <= 0) {
      // Dimensions inconnues (en-tête illisible) : on n'ose pas dire « ok »,
      // mais on ne bloque pas non plus une commande sur un échec de lecture —
      // même arbitrage que PosterQualityService.
      return PuzzleSizeQuality(size: size, verdict: PuzzleQualityVerdict.limited);
    }

    final dpiW = photoDims.w / entry.printAreaPxW * idealDpi;
    final dpiH = photoDims.h / entry.printAreaPxH * idealDpi;
    final dpi = dpiW < dpiH ? dpiW : dpiH;

    final verdict = dpi >= idealDpi
        ? PuzzleQualityVerdict.ok
        : dpi >= minDpi
            ? PuzzleQualityVerdict.limited
            : PuzzleQualityVerdict.disabled;
    return PuzzleSizeQuality(size: size, verdict: verdict, achievableDpi: dpi);
  }

  /// Évalue toutes les tailles du catalogue pour une photo donnée.
  static Map<String, PuzzleSizeQuality> evaluateAll(
          ({int w, int h})? photoDims) =>
      {
        for (final size in PuzzlePricing.sizes)
          size: evaluate(size: size, photoDims: photoDims),
      };

  /// La plus grande taille commandable avec cette photo, ou null si même la
  /// plus petite est bloquée. `PuzzlePricing.sizes` est trié du plus petit au
  /// plus grand et la qualité ne peut que se dégrader en montant, donc le
  /// dernier `isOrderable` est le bon.
  static String? largestOrderable(({int w, int h})? photoDims) {
    final all = evaluateAll(photoDims);
    String? best;
    for (final size in PuzzlePricing.sizes) {
      if (all[size]?.isOrderable ?? false) best = size;
    }
    return best;
  }

  /// Formule courte pour l'UI : « ~68 DPI ».
  static String dpiLabel(PuzzleSizeQuality q) =>
      q.achievableDpi == null ? '—' : '~${q.achievableDpi!.round()} DPI';
}
