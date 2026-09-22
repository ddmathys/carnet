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
  const PuzzleCatalogEntry({
    required this.sku,
    required this.pieces,
    required this.usdCost,
    required this.printAreaPxW,
    required this.printAreaPxH,
  });
}

class PuzzlePricing {
  static const double _usdToChf = 0.90;
  static const double marginRate = 0.40;
  static const double marginFloor = 10.0;

  static const List<String> sizes = ['30', '110', '252', '500', '1000'];

  static const Map<String, PuzzleCatalogEntry> _catalog = {
    '30': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-30', pieces: 30, usdCost: 26.32, printAreaPxW: 2952, printAreaPxH: 2362),
    '110': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-110', pieces: 110, usdCost: 28.99, printAreaPxW: 2952, printAreaPxH: 2362),
    '252': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-252', pieces: 252, usdCost: 30.33, printAreaPxW: 4429, printAreaPxH: 3366),
    '500': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-500', pieces: 500, usdCost: 34.34, printAreaPxW: 6259, printAreaPxH: 4606),
    '1000': PuzzleCatalogEntry(
        sku: 'JIGSAW-PUZZLE-1000', pieces: 1000, usdCost: 39.69, printAreaPxW: 9035, printAreaPxH: 6200),
  };

  static PuzzleCatalogEntry? entryFor(String size) => _catalog[size];

  static double marginFor(double cost) =>
      cost * marginRate < marginFloor ? marginFloor : cost * marginRate;

  /// Prix client = coût Prodigi total (article + livraison, converti) + marge,
  /// arrondi au 0.50 supérieur. null si la taille n'existe pas.
  static double? price(String size) {
    final entry = entryFor(size);
    if (entry == null) return null;
    final cost = entry.usdCost * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';

  static String label(String size) => '${entryFor(size)?.pieces ?? size} pièces';
}
