import '../models/poster_template.dart';
import 'poster_pricing.dart';

/// Contrôle qualité (DPI) par taille de poster — voir plan §3.
///
/// Au lieu de recalculer les pixels requis depuis les mm (risque d'erreur
/// d'arrondi ISO), on utilise directement la résolution d'impression EXACTE
/// renvoyée par l'API Prodigi pour chaque SKU (`PosterPricing.printAreaPx*`,
/// confirmée = 300 DPI) comme référence "idéale" ; le seuil "qualité limite"
/// (150 DPI) est exactement la moitié de ces pixels, à taille physique égale.
enum PosterQualityVerdict { ok, limited, disabled }

class PosterSizeQuality {
  final String size;
  final PosterQualityVerdict verdict;
  /// Index (dans la liste de photos) de la photo la plus limitante — null si
  /// la taille n'existe simplement pas pour cette orientation (ex. A0 paysage).
  final int? bottleneckPhotoIndex;
  final double? achievableDpi;
  const PosterSizeQuality({
    required this.size,
    required this.verdict,
    this.bottleneckPhotoIndex,
    this.achievableDpi,
  });
}

class PosterQualityService {
  static const double idealDpi = 300.0;
  static const double minDpi = 150.0;

  /// `photoDims` doit avoir le MÊME ORDRE/longueur que `layout.tiles` (donc
  /// que la liste de photos utilisée pour construire `layout`). Une entrée
  /// null (dimensions inconnues, ex. échec réseau) est ignorée plutôt que
  /// bloquante.
  static PosterSizeQuality evaluate({
    required String size,
    required String orientation,
    required PosterLayout layout,
    required List<({int w, int h})?> photoDims,
  }) {
    final entry = PosterPricing.entryFor(size, orientation);
    if (entry == null) {
      return PosterSizeQuality(size: size, verdict: PosterQualityVerdict.disabled);
    }

    double worstDpi = double.infinity;
    int? worstIdx;
    for (var i = 0; i < layout.tiles.length; i++) {
      final dims = i < photoDims.length ? photoDims[i] : null;
      if (dims == null || dims.w <= 0 || dims.h <= 0) continue;
      final tile = layout.tiles[i];
      final reqW = entry.printAreaPxW * tile.w;
      final reqH = entry.printAreaPxH * tile.h;
      if (reqW <= 0 || reqH <= 0) continue;
      final dpiW = dims.w / reqW * idealDpi;
      final dpiH = dims.h / reqH * idealDpi;
      final dpi = dpiW < dpiH ? dpiW : dpiH;
      if (dpi < worstDpi) {
        worstDpi = dpi;
        worstIdx = i;
      }
    }

    if (worstIdx == null) {
      // Aucune dimension connue — on n'ose pas dire "ok" : traité comme
      // qualité limite plutôt que de bloquer ou de mentir sur la netteté.
      return PosterSizeQuality(size: size, verdict: PosterQualityVerdict.limited);
    }
    final verdict = worstDpi >= idealDpi
        ? PosterQualityVerdict.ok
        : worstDpi >= minDpi
            ? PosterQualityVerdict.limited
            : PosterQualityVerdict.disabled;
    return PosterSizeQuality(
      size: size,
      verdict: verdict,
      bottleneckPhotoIndex: worstIdx,
      achievableDpi: worstDpi,
    );
  }

  /// Évalue les 5 tailles A4→A0 (portrait ou paysage selon `layout`, A0
  /// paysage étant de toute façon absent du catalogue → `disabled`).
  static Map<String, PosterSizeQuality> evaluateAll({
    required PosterLayout layout,
    required List<({int w, int h})?> photoDims,
  }) {
    final orientation =
        layout.orientation == PosterOrientation.landscape ? 'landscape' : 'portrait';
    return {
      for (final size in PosterPricing.sizes)
        size: evaluate(
          size: size,
          orientation: orientation,
          layout: layout,
          photoDims: photoDims,
        ),
    };
  }
}
