/// Miroir exact de backend/lib/poster_pricing.ts — les deux DOIVENT rester
/// identiques. Même logique que BookPricing (voir book_pricing.dart), mais
/// table plate par SKU au lieu d'une formule par page (le poster est un
/// produit à taille/prix fixes chez Prodigi, pas de contenu variable).
///
/// Catalogue SKU/résolution confirmé le 20.08.26 via `GET /v4.0/products/{sku}`
/// en sandbox. Couleur du hanger confirmée dans `attributes.color` du même
/// appel : valeurs réelles `black` / `natural` (pas "oak" malgré le nom
/// commercial "chêne") / `white`. A0 paysage n'existe pas au catalogue (testé :
/// 404 sur les 4 paliers plausibles) → A0 est portrait uniquement.
///
/// ⚠️ `usdCost` recalibré le 21.08.26 suite à une VRAIE commande (A1 portrait)
/// facturée $44.95 par Prodigi (item $27.28 + livraison $17.67) alors que
/// l'app affichait CHF 30 au client — la table précédente ne contenait QUE le
/// prix article (`GET /products`), jamais la livraison. Valeurs ici =
/// item + livraison réels vers la Suisse, lus via `POST /v4.0/quotes`
/// (`shippingMethod: Standard`, `destinationCountryCode: CH`) le 21.08.26 —
/// à re-vérifier si Prodigi change ses tarifs de livraison.
class PosterCatalogEntry {
  final String sku;
  final double usdCost;
  final int printAreaPxW;
  final int printAreaPxH;
  const PosterCatalogEntry({
    required this.sku,
    required this.usdCost,
    required this.printAreaPxW,
    required this.printAreaPxH,
  });
}

class PosterPricing {
  static const double _usdToChf = 0.90;
  static const double marginRate = 0.40;
  static const double marginFloor = 10.0;

  static const Map<String, Map<String, PosterCatalogEntry>> _catalog = {
    'A4': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-20-A4-PORT', usdCost: 23.03, printAreaPxW: 2490, printAreaPxH: 3510),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-30-A4-LAND', usdCost: 24.20, printAreaPxW: 3510, printAreaPxH: 2490),
    },
    'A3': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-30-A3-PORT', usdCost: 27.70, printAreaPxW: 3507, printAreaPxH: 4960),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-40-A3-LAND', usdCost: 28.85, printAreaPxW: 4960, printAreaPxH: 3507),
    },
    'A2': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-40-A2-PORT', usdCost: 35.25, printAreaPxW: 4960, printAreaPxH: 7015),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-60-A2-LAND', usdCost: 37.98, printAreaPxW: 7015, printAreaPxH: 4960),
    },
    'A1': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-60-A1-PORT', usdCost: 44.93, printAreaPxW: 7020, printAreaPxH: 9930),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-80-A1-LAND', usdCost: 50.39, printAreaPxW: 9930, printAreaPxH: 7020),
    },
    'A0': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-80-A0-PORT', usdCost: 69.48, printAreaPxW: 9930, printAreaPxH: 14040),
      // Pas de landscape — voir commentaire d'en-tête.
    },
  };

  static const List<String> sizes = ['A4', 'A3', 'A2', 'A1', 'A0'];
  static const List<String> hangerColors = ['black', 'natural', 'white'];

  // ── Tableaux muraux (29.09.26) ─────────────────────────────────────────
  // Même produit « poster » côté commande : la MATIÈRE est portée par la
  // taille — `CAN-16X20` = toile tendue Prodigi GLOBAL-CAN-16X20,
  // `CFP-16X20` = tirage encadré GLOBAL-CFP-16X20 (miroir de
  // backend/lib/poster_pricing.ts). Mêmes SKU en portrait et en paysage.
  //
  // ⚠️ Coûts ESTIMÉS, pas encore confirmés par un devis Prodigi : tant que
  // `wallCostsVerified` est faux, toile et encadré ne sont proposés qu'à
  // l'admin (qui vérifie chaque taille avec « Vérifier chez Prodigi »).
  static const bool wallCostsVerified = false;

  /// 'hanger' (affiche + baguette bois), 'canvas' (toile), 'framed' (encadré).
  static const List<String> materials = ['hanger', 'canvas', 'framed'];
  static const List<String> _wallInches = ['12X16', '16X20', '24X32', '28X40'];
  static const Map<String, ({int w, int h})> _inches = {
    '12X16': (w: 12, h: 16),
    '16X20': (w: 16, h: 20),
    '24X32': (w: 24, h: 32),
    '28X40': (w: 28, h: 40),
  };
  // Coût estimé article + livraison Suisse (USD) — voir ⚠️ ci-dessus.
  static const Map<String, Map<String, double>> _wallUsdCost = {
    'CAN': {'12X16': 45, '16X20': 55, '24X32': 85, '28X40': 110},
    'CFP': {'12X16': 55, '16X20': 70, '24X32': 120, '28X40': 150},
  };

  static String _prefixOf(String material) =>
      material == 'canvas' ? 'CAN' : 'CFP';

  /// Matière d'une taille (« A3 » → hanger, « CAN-16X20 » → canvas…).
  static String materialOf(String size) => size.startsWith('CAN-')
      ? 'canvas'
      : size.startsWith('CFP-')
          ? 'framed'
          : 'hanger';

  /// Tailles proposées pour une matière, de la plus petite à la plus grande.
  static List<String> sizesFor(String material) => material == 'hanger'
      ? sizes
      : [for (final i in _wallInches) '${_prefixOf(material)}-$i'];

  static List<String> get allSizes =>
      [for (final m in materials) ...sizesFor(m)];

  static ({String prefix, ({int w, int h}) inches})? _wall(String size) {
    final dash = size.indexOf('-');
    if (dash < 0) return null;
    final prefix = size.substring(0, dash);
    final inches = _inches[size.substring(dash + 1)];
    if ((prefix != 'CAN' && prefix != 'CFP') || inches == null) return null;
    return (prefix: prefix, inches: inches);
  }

  static String materialLabel(String material) => switch (material) {
        'canvas' => 'Toile',
        'framed' => 'Encadré',
        _ => 'Affiche',
      };

  static String materialDescription(String material) => switch (material) {
        'canvas' => 'Toile tendue sur châssis bois de 38 mm, prête à accrocher',
        'framed' => 'Tirage d\'art sous cadre, prêt à accrocher',
        _ => 'Tirage d\'art avec baguettes bois magnétiques',
      };

  /// « A3 » ou « 40 × 50 cm » (arrondi aux 10 cm, comme sur le site Prodigi).
  static String sizeLabel(String size) {
    final wall = _wall(size);
    if (wall == null) return size;
    int cm(int inch) => ((inch * 2.54) / 10).round() * 10;
    return '${cm(wall.inches.w)} × ${cm(wall.inches.h)} cm';
  }

  /// Libellé client complet : « Tirage A3 », « Toile 40 × 50 cm »…
  static String label(String size) => switch (materialOf(size)) {
        'canvas' => 'Toile ${sizeLabel(size)}',
        'framed' => 'Tirage encadré ${sizeLabel(size)}',
        _ => 'Tirage $size',
      };

  /// Couleurs proposées pour une matière (aucune pour la toile).
  static List<String> colorsFor(String material) =>
      material == 'canvas' ? const [] : hangerColors;

  // Dimensions ISO 216 exactes (portrait ; paysage = largeur/hauteur
  // inversées), confirmées via `productDimensions` sur les mêmes appels API
  // que le catalogue ci-dessus (21.0×29.7cm, 29.7×42.0cm, 42.0×59.4cm,
  // 59.4×84.1cm, 84.1×118.8cm).
  static const Map<String, ({double wMm, double hMm})> _portraitMm = {
    'A4': (wMm: 210.0, hMm: 297.0),
    'A3': (wMm: 297.0, hMm: 420.0),
    'A2': (wMm: 420.0, hMm: 594.0),
    'A1': (wMm: 594.0, hMm: 841.0),
    'A0': (wMm: 841.0, hMm: 1189.0),
  };

  static ({double wMm, double hMm})? mmFor(String size, String orientation) {
    final wall = _wall(size);
    final p = wall != null
        ? (wMm: wall.inches.w * 25.4, hMm: wall.inches.h * 25.4)
        : _portraitMm[size];
    if (p == null) return null;
    return orientation == 'landscape' ? (wMm: p.hMm, hMm: p.wMm) : p;
  }

  static PosterCatalogEntry? entryFor(String size, String orientation) {
    final entry = _catalog[size]?[orientation];
    if (entry != null) return entry;
    final wall = _wall(size);
    if (wall == null ||
        (orientation != 'portrait' && orientation != 'landscape')) {
      return null;
    }
    // Résolution de référence à 300 DPI (contrôle qualité uniquement —
    // Prodigi cadre lui-même le fichier, `sizing: 'fillPrintArea'`).
    final w = wall.inches.w * 300, h = wall.inches.h * 300;
    final landscape = orientation == 'landscape';
    return PosterCatalogEntry(
      sku: 'GLOBAL-$size',
      usdCost: _wallUsdCost[wall.prefix]![size.substring(4)]!,
      printAreaPxW: landscape ? h : w,
      printAreaPxH: landscape ? w : h,
    );
  }

  /// Part « livraison » comprise dans `usdCost` (devis réel du 21.08.26 :
  /// A1 portrait = article $27.28 + livraison $17.67). Miroir de
  /// backend/lib/poster_pricing.ts — ne sert qu'à déduire le port d'un tirage
  /// supplémentaire groupé.
  static const double _shippingUsd = 17.67;

  static double marginFor(double cost) =>
      cost * marginRate < marginFloor ? marginFloor : cost * marginRate;

  /// Prix client = coût Prodigi total (article + livraison, converti) + marge,
  /// arrondi au 0.50 supérieur. null si la combinaison taille/orientation
  /// n'existe pas (ex. A0 paysage).
  static double? price(String size, String orientation) {
    final entry = entryFor(size, orientation);
    if (entry == null) return null;
    final cost = entry.usdCost * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Prix d'un tirage SUPPLÉMENTAIRE dans la même commande : port déduit,
  /// Prodigi ne le facturant qu'une fois par commande. Miroir de
  /// `computeAdditionalPosterPrice` (backend/lib/poster_pricing.ts).
  static double? priceAdditional(String size, String orientation) {
    final entry = entryFor(size, orientation);
    if (entry == null) return null;
    final usd = entry.usdCost - _shippingUsd;
    final cost = (usd < 0 ? 0.0 : usd) * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Prix du tirage le moins cher du catalogue PUBLIC (les tableaux muraux
  /// restent réservés à l'admin tant que leurs coûts ne sont pas confirmés,
  /// voir `wallCostsVerified`). Sert l'étiquette « dès … » du catalogue.
  static double get minPrice {
    double? best;
    for (final size in sizes) {
      for (final o in const ['portrait', 'landscape']) {
        final p = price(size, o);
        if (p != null && (best == null || p < best)) best = p;
      }
    }
    return best ?? 0;
  }

  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';

  static String hangerColorLabel(String color) => switch (color) {
        'black' => 'Noir',
        'natural' => 'Chêne',
        'white' => 'Blanc',
        _ => color,
      };

  /// Couleur choisie selon la matière (baguette, cadre, ou bords de toile).
  static String colorLabel(String size, String color) =>
      switch (materialOf(size)) {
        'canvas' => 'Bords en miroir',
        'framed' => color == 'natural' ? 'Bois naturel' : hangerColorLabel(color),
        _ => hangerColorLabel(color),
      };
}
