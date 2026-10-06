/// Miroir exact de backend/lib/puzzle_pricing.ts — les deux DOIVENT rester
/// identiques. Même logique que PosterPricing.
///
/// Catalogue/coût confirmé le 22.09.26 via l'API Prodigi réelle (production,
/// pas sandbox) : `GET /v4.0/products/{sku}` puis `POST /v4.0/quotes`
/// (`shippingMethod: Standard`, `destinationCountryCode: CH`).
///
/// Une seule zone d'impression par taille : Prodigi cadre lui-même la photo
/// (`sizing: 'fillPrintArea'`, voir backend/api/prodigi/[action].ts) — pas
/// d'orientation à choisir comme pour le poster.
class PuzzleCatalogEntry {
  final String sku;
  final int pieces;
  final double usdCost;
  final int printAreaPxW;
  final int printAreaPxH;

  /// Zone d'impression du COUVERCLE de la boîte métal, relevée le 06.10.26
  /// dans la fiche produit publique de Prodigi (« 30pc/110pc/252pc tins
  /// 869x674px, 500pc/1000pc tins 1724x1169px »). C'est le RATIO qui compte :
  /// le PDF du couvercle est composé exactement à ces proportions pour que
  /// `sizing: 'fillPrintArea'` n'ait rien à recadrer — sinon le QR imprimé
  /// dessus peut être coupé. Miroir de backend/lib/puzzle_pricing.ts.
  final int lidPrintAreaPxW;
  final int lidPrintAreaPxH;

  /// Taille du puzzle assemblé (mm), même source — sert aux libellés.
  final int assembledMmW;
  final int assembledMmH;

  const PuzzleCatalogEntry({
    required this.sku,
    required this.pieces,
    required this.usdCost,
    required this.printAreaPxW,
    required this.printAreaPxH,
    required this.lidPrintAreaPxW,
    required this.lidPrintAreaPxH,
    required this.assembledMmW,
    required this.assembledMmH,
  });

  /// Proportions du couvercle (largeur / hauteur).
  double get lidAspect => lidPrintAreaPxW / lidPrintAreaPxH;
}

class PuzzlePricing {
  static const double _usdToChf = 0.90;

  /// ⚠️ LE PUZZLE NE SE CALCULE PAS COMME LE LIVRE ET LE POSTER.
  ///
  /// `BookPricing` et `PosterPricing` appliquent une MAJORATION de 40 % sur le
  /// coût (`prix = coût × 1,4`), ce qui ne laisse en réalité que 29 % du prix
  /// de vente. Le puzzle vise une MARGE de 40 % DU PRIX DE VENTE
  /// (`prix = coût ÷ 0,60`) — décision de David le 06.10.26. Justification
  /// complète dans backend/lib/puzzle_pricing.ts, dont ce fichier est le
  /// miroir exact.
  static const double marginShare = 0.40;
  static const double marginFloor = 10.0;

  /// Catalogue resserré le 06.10.26 : 30 et 110 pièces retirés (un puzzle de
  /// 30 pièces n'est pas un cadeau et tirait l'étiquette « dès CHF … » vers le
  /// bas). Miroir de `PuzzleSize` côté backend.
  static const List<String> sizes = ['252', '500', '1000'];

  static const Map<String, PuzzleCatalogEntry> _catalog = {
    '252': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-252', pieces: 252, usdCost: 30.33,
        printAreaPxW: 4429, printAreaPxH: 3366,
        lidPrintAreaPxW: 869, lidPrintAreaPxH: 674,
        assembledMmW: 375, assembledMmH: 285),
    '500': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-500', pieces: 500, usdCost: 34.34,
        printAreaPxW: 6259, printAreaPxH: 4606,
        lidPrintAreaPxW: 1724, lidPrintAreaPxH: 1169,
        assembledMmW: 530, assembledMmH: 390),
    '1000': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-1000', pieces: 1000, usdCost: 39.69,
        printAreaPxW: 9035, printAreaPxH: 6200,
        lidPrintAreaPxW: 1724, lidPrintAreaPxH: 1169,
        assembledMmW: 765, assembledMmH: 525),
  };

  static PuzzleCatalogEntry? entryFor(String size) => _catalog[size];

  /// Marge en francs telle qu'elle représente [marginShare] du PRIX DE VENTE
  /// et non du coût : `marge = coût × part / (1 − part)`. Le plancher reste un
  /// filet de sécurité (il ne joue à aucune taille du catalogue actuel).
  static double marginFor(double cost) {
    final margin = cost * (marginShare / (1 - marginShare));
    return margin < marginFloor ? marginFloor : margin;
  }

  /// Prix client = coût Prodigi total (article + livraison, converti) + marge,
  /// arrondi au 0.50 supérieur. null si la taille n'existe pas.
  static double? price(String size) {
    final entry = entryFor(size);
    if (entry == null) return null;
    final cost = entry.usdCost * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Part « livraison » comprise dans `usdCost`. Jamais isolée sur un devis
  /// Prodigi pour les puzzles : volontairement PRUDENTE (le port réel est plus
  /// proche de 17 USD). À recaler avec le bouton « Mesurer chez Prodigi » de
  /// l'écran puzzle (admin, depuis le 06.10.26). Miroir de
  /// backend/lib/puzzle_pricing.ts.
  static const double _shippingUsd = 12.0;

  /// Prix d'un puzzle SUPPLÉMENTAIRE dans la même commande : port déduit.
  static double? priceAdditional(String size) {
    final entry = entryFor(size);
    if (entry == null) return null;
    final usd = entry.usdCost - _shippingUsd;
    final cost = (usd < 0 ? 0.0 : usd) * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';

  /// Prix du puzzle le moins cher du catalogue. Étiquette « dès … ».
  static double get minPrice {
    double? best;
    for (final s in sizes) {
      final p = price(s);
      if (p != null && (best == null || p < best)) best = p;
    }
    return best ?? 0;
  }

  static String label(String size) => '${entryFor(size)?.pieces ?? size} pièces';
}
