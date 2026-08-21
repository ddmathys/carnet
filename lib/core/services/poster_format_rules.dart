import '../models/poster_template.dart';
import 'poster_pricing.dart';

/// Format papier IMPOSÉ par le collage : plus il y a de photos (et plus les
/// cases sont petites), plus le papier doit être grand pour que chaque photo
/// reste regardable sur un mur. Une seule règle, appliquée à la disposition
/// RÉELLE (donc en tenant compte des photos mises en avant, qui occupent un
/// bloc plus grand) : le côté le plus court de la PLUS PETITE case ne descend
/// jamais sous `minTileMm`.
///
/// Complémentaire de `PosterQualityService`, qui interdit les formats TROP
/// GRANDS pour la résolution des photos : ici on interdit les formats trop
/// PETITS pour le nombre de photos. Les deux se lisent sur les mêmes cases.
class PosterFormatRules {
  /// 8 cm : la largeur d'un tirage photo classique (9×13). En dessous, une
  /// photo noyée dans un collage accroché au mur n'est plus lisible.
  static const double minTileMm = 80.0;

  static String orientationOf(PosterLayout layout) =>
      layout.orientation == PosterOrientation.landscape ? 'landscape' : 'portrait';

  /// Côté le plus court, en mm, de la plus petite case de `layout` imprimée
  /// au format `size`. null si ce format n'existe pas dans l'orientation du
  /// collage (ex. A0 paysage, absent du catalogue Prodigi).
  static double? smallestTileMm(PosterLayout layout, String size) {
    final orientation = orientationOf(layout);
    if (PosterPricing.entryFor(size, orientation) == null) return null;
    final mm = PosterPricing.mmFor(size, orientation);
    if (mm == null || layout.tiles.isEmpty) return null;
    // La bande légende/QR mange le bas de la page : les cases se partagent
    // le reste (même découpage que PosterPdfService.generate).
    final contentHmm = mm.hMm * (1 - posterBandFraction);
    var smallest = double.infinity;
    for (final t in layout.tiles) {
      final w = t.w * mm.wMm;
      final h = t.h * contentHmm;
      final side = w < h ? w : h;
      if (side < smallest) smallest = side;
    }
    return smallest;
  }

  /// Vrai si chaque photo garde au moins `minTileMm` de côté à ce format.
  static bool fits(PosterLayout layout, String size) {
    final side = smallestTileMm(layout, size);
    // Tolérance d'un dixième de mm : les fractions de case (1/3, 1/7…) ne
    // tombent jamais rond, on ne va pas refuser un A3 pour 0.02 mm.
    return side != null && side >= minTileMm - 0.1;
  }

  /// Plus petit format du catalogue qui respecte la règle. Si aucun ne suffit
  /// (collage très dense), renvoie le plus grand format disponible : mieux
  /// vaut le maximum possible qu'un écran sans aucun choix.
  static String minSizeFor(PosterLayout layout) {
    final orientation = orientationOf(layout);
    String? largest;
    for (final size in PosterPricing.sizes) {
      if (PosterPricing.entryFor(size, orientation) == null) continue;
      largest = size;
      if (fits(layout, size)) return size;
    }
    return largest ?? PosterPricing.sizes.first;
  }

  /// Formats sélectionnables : le minimum imposé et tous ceux au-dessus
  /// (`PosterPricing.sizes` est trié du plus petit au plus grand), moins ceux
  /// qui n'existent pas dans l'orientation du collage (A0 paysage).
  static List<String> allowedSizes(PosterLayout layout) {
    final orientation = orientationOf(layout);
    final from = PosterPricing.sizes.indexOf(minSizeFor(layout));
    return [
      for (final size in PosterPricing.sizes.sublist(from < 0 ? 0 : from))
        if (PosterPricing.entryFor(size, orientation) != null) size,
    ];
  }

  static bool isTooSmall(PosterLayout layout, String size) =>
      !allowedSizes(layout).contains(size);

  /// Taille approximative d'une photo du collage à ce format, pour l'afficher
  /// à l'utilisateur (« environ 9 cm par photo »). null si format indisponible.
  static double? smallestTileCm(PosterLayout layout, String size) {
    final mm = smallestTileMm(layout, size);
    return mm == null ? null : mm / 10;
  }
}
