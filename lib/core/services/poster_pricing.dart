/// Miroir exact de backend/lib/poster_pricing.ts — les deux DOIVENT rester
/// identiques. Même logique que BookPricing (voir book_pricing.dart), mais
/// table plate par SKU au lieu d'une formule par page (le poster est un
/// produit à taille/prix fixes chez Prodigi, pas de contenu variable).
///
/// Catalogue confirmé le 20.08.26 via de VRAIS appels
/// `GET /v4.0/products/{sku}` en sandbox — SKU, prix ET résolution
/// d'impression exacte (`printAreaPx`) lus directement dans la réponse, pas
/// recalculés depuis les mm. Couleur du hanger confirmée dans
/// `attributes.color` du même appel : valeurs réelles `black` / `natural`
/// (pas "oak" malgré le nom commercial "chêne") / `white`. A0 paysage
/// n'existe pas au catalogue (testé : 404 sur les 4 paliers plausibles) → A0
/// est portrait uniquement.
class PosterCatalogEntry {
  final String sku;
  final double usd;
  final int printAreaPxW;
  final int printAreaPxH;
  const PosterCatalogEntry({
    required this.sku,
    required this.usd,
    required this.printAreaPxW,
    required this.printAreaPxH,
  });
}

class PosterPricing {
  static const double _usdToChf = 0.90;
  static const double marginRate = 0.20;
  static const double marginFloor = 8.0;

  static const Map<String, Map<String, PosterCatalogEntry>> _catalog = {
    'A4': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-20-A4-PORT', usd: 10.0, printAreaPxW: 2490, printAreaPxH: 3510),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-30-A4-LAND', usd: 11.0, printAreaPxW: 3510, printAreaPxH: 2490),
    },
    'A3': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-30-A3-PORT', usd: 14.0, printAreaPxW: 3507, printAreaPxH: 4960),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-40-A3-LAND', usd: 15.0, printAreaPxW: 4960, printAreaPxH: 3507),
    },
    'A2': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-40-A2-PORT', usd: 16.0, printAreaPxW: 4960, printAreaPxH: 7015),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-60-A2-LAND', usd: 19.0, printAreaPxW: 7015, printAreaPxH: 4960),
    },
    'A1': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-60-A1-PORT', usd: 24.0, printAreaPxW: 7020, printAreaPxH: 9930),
      'landscape': PosterCatalogEntry(
          sku: 'POSTER-HANGER-80-A1-LAND', usd: 28.0, printAreaPxW: 9930, printAreaPxH: 7020),
    },
    'A0': {
      'portrait': PosterCatalogEntry(
          sku: 'POSTER-HANGER-80-A0-PORT', usd: 45.0, printAreaPxW: 9930, printAreaPxH: 14040),
      // Pas de landscape — voir commentaire d'en-tête.
    },
  };

  static const List<String> sizes = ['A4', 'A3', 'A2', 'A1', 'A0'];
  static const List<String> hangerColors = ['black', 'natural', 'white'];

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
    final p = _portraitMm[size];
    if (p == null) return null;
    return orientation == 'landscape' ? (wMm: p.hMm, hMm: p.wMm) : p;
  }

  static PosterCatalogEntry? entryFor(String size, String orientation) =>
      _catalog[size]?[orientation];

  static double marginFor(double cost) =>
      cost * marginRate < marginFloor ? marginFloor : cost * marginRate;

  /// Prix client = coût Prodigi (converti) + marge, arrondi au 0.50 supérieur.
  /// null si la combinaison taille/orientation n'existe pas (ex. A0 paysage).
  static double? price(String size, String orientation) {
    final entry = entryFor(size, orientation);
    if (entry == null) return null;
    final cost = entry.usd * _usdToChf;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';

  static String hangerColorLabel(String color) => switch (color) {
        'black' => 'Noir',
        'natural' => 'Chêne',
        'white' => 'Blanc',
        _ => color,
      };
}
