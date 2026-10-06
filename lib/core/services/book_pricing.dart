import '../models/memory_model.dart';

/// Tarification du livre imprimé = **coût impression tout compris**
/// (impression + livraison) **+ une marge**. Objectif : rester compétitif
/// tout en couvrant l'intégralité du coût.
///
/// Constantes calibrées le 06.08.26 sur de VRAIS appels `POST /v4.0/quotes`
/// (destinationCountryCode: "CH", shippingMethod: "Standard") — pas juste le
/// simulateur web, confirmé via la vraie clé API :
/// - Soft (BOOK-FE-A4-P-SOFT-MHK), devis 40 pages : base 20p = \$10.97,
///   +\$0.30/page au-delà, livraison \$18.71 (expédié depuis DE), taxe \$0.00.
/// - Hard (BOOK-FE-A4-P-HARD-G), devis 68 pages : base 24p = \$13.48,
///   +\$0.25/page au-delà, livraison \$17.49 (expédié depuis NL), taxe \$0.00.
/// Conversion USD→CHF à ~0.90 (approximatif, à réviser périodiquement — seule
/// variable non confirmée par l'API). Pas de TVA suisse ajoutée : Prodigi
/// renvoie `totalTax: 0.00` pour la Suisse — les droits de douane/TVA import
/// sont à la charge du DESTINATAIRE à la livraison, pas facturés par Prodigi
/// (différent du modèle Gelato). DOIT rester identique à
/// backend/lib/pricing.ts.
class BookPricing {
  static const double _usdToChf = 0.90;

  // Layflat (BOOK-FE-A4-P-LF-G) : calibré le 18.08.26 sur de vrais devis
  // Prodigi (voir backend/lib/pricing.ts pour le détail du calcul) — base
  // 18p = \$24.31, +\$0.49/page, livraison \$18.75 (DE). 18-122 pages.
  static const Map<String, double> _basePriceUsd = {
    'soft': 10.97, 'hard': 13.48, 'layflat': 24.31,
  };
  static const Map<String, double> _extraPageUsd = {
    'soft': 0.30, 'hard': 0.25, 'layflat': 0.49,
  };
  static const Map<String, double> _shippingUsd = {
    'soft': 18.71, 'hard': 17.49, 'layflat': 18.75,
  };

  // ── Marge visée ──────────────────────────────────────────────────────────
  // [marginShare] est la part du PRIX DE VENTE qui reste à Carnet, PAS une
  // majoration appliquée au coût. Les deux se confondent facilement :
  //
  //   majoration de 40 % : prix = coût × 1,4  → il ne reste que 29 % du prix
  //   marge de 50 %      : prix = coût ÷ 0,50 → il reste bien 50 % du prix
  //
  // Jusqu'au 06.10.26 le code appliquait une majoration de 40 % en l'appelant
  // « marge 40 % » : tout le catalogue ne rapportait donc que 29 %. Décision
  // de David : 50 % du prix encaissé sur les livres, les tirages et les
  // puzzles. Explication complète dans backend/lib/pricing.ts, dont ce
  // fichier est le miroir.
  //
  // Le plancher de 10 CHF reste un filet de sécurité pour les toutes petites
  // commandes (suivi, frais annexes) ; il ne joue sur aucune référence du
  // catalogue actuel.
  static const double marginShare = 0.50;
  static const double marginFloor = 10.0;

  /// Coût d'impression estimé (impression + livraison) pour une couverture et
  /// un nombre de pages donnés.
  static double printCost({required String coverType, required int pages}) {
    final min = _minPages[coverType] ?? 24;
    final extraPages = (pages - min).clamp(0, 1 << 30);
    final usd = (_basePriceUsd[coverType] ?? _basePriceUsd['hard']!) +
        (_extraPageUsd[coverType] ?? _extraPageUsd['hard']!) * extraPages +
        (_shippingUsd[coverType] ?? _shippingUsd['hard']!);
    return usd * _usdToChf;
  }

  /// Marge en francs telle qu'elle représente [marginShare] du PRIX DE VENTE :
  /// `prix = coût / (1 − part)` ⟺ `marge = coût × part / (1 − part)`.
  static double marginFor(double cost) {
    final margin = cost * (marginShare / (1 - marginShare));
    return margin < marginFloor ? marginFloor : margin;
  }

  /// Prix client = coût d'impression + marge, arrondi au 0.50 supérieur (le
  /// coût reste toujours couvert).
  ///
  /// Le nombre de pages est écrêté aux bornes du produit, comme côté serveur
  /// (`printablePages`) : sans ça, l'app affichait le prix de 150 pages pour un
  /// layflat que Stripe facturait à 122 (audit du 01.10.26).
  static double price({required String coverType, required int pages}) {
    final cost =
        printCost(coverType: coverType, pages: printablePages(coverType, pages));
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Prix d'un livre SUPPLÉMENTAIRE dans la même commande : port déduit.
  /// Prodigi ne facture la livraison qu'une fois par commande — l'additionner
  /// par article faisait payer le port deux, trois fois (audit du 01.10.26).
  /// Miroir de `computeAdditionalPrice` (backend/lib/pricing.ts).
  static double priceAdditional(
      {required String coverType, required int pages}) {
    final shipping =
        (_shippingUsd[coverType] ?? _shippingUsd['hard']!) * _usdToChf;
    final cost =
        printCost(coverType: coverType, pages: printablePages(coverType, pages)) -
            shipping;
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Estimation du nombre de pages AVANT génération du PDF (fallback ; dès que
  /// l'aperçu est généré on utilise le vrai compte). ~4 photos par page + 1 page
  /// par souvenir-texte + couverture + dos.
  static int estimatePages(List<MemoryModel> memories) {
    int pages = 0;
    for (final m in memories) {
      final n = m.mediaKeys.isNotEmpty
          ? m.mediaKeys.length
          : (m.mediaUrls.isNotEmpty
              ? m.mediaUrls.length
              : (m.photoUrl != null && m.photoUrl!.isNotEmpty ? 1 : 0));
      if (n > 0) {
        pages += (n / 4).ceil(); // ~4 photos / page, ≥1 page par souvenir
      } else if (m.type != 'taille_poids') {
        pages += 1; // page texte
      }
    }
    return 2 + pages; // + couverture + dos
  }

  /// Nombre de pages réellement imprimé : PAIR par précaution (règle non
  /// confirmée comme rejetée par Prodigi — testé le 06.08.26 via de vrais
  /// devis avec pages impaires, acceptés sans erreur ; peut-être vérifiée
  /// seulement à la vraie création de commande, non testée pour éviter un
  /// risque avec la clé live). Bornes de pages, elles, confirmées le 06.08.26
  /// sur les fiches produit Prodigi : softcover 20-300, hardcover 24-300 (500
  /// en 150gsm gloss only, non géré ici par simplicité). Voir
  /// BookPdfService._validPageCount, doit rester identique à cette
  /// méthode-là. C'est sur CETTE base qu'est facturé un livre imprimé.
  static const Map<String, int> _minPages = {'soft': 20, 'hard': 24, 'layflat': 18};
  static const Map<String, int> _maxPages = {'soft': 300, 'hard': 300, 'layflat': 122};

  /// Nombre de pages maximum accepté par ce format (borne produit Prodigi).
  static int maxPages(String coverType) => _maxPages[coverType] ?? 300;

  static int printablePages(String coverType, int rawPages) {
    final min = _minPages[coverType] ?? 24;
    var v = rawPages < min ? min : (rawPages.isOdd ? rawPages + 1 : rawPages);
    final max = _maxPages[coverType] ?? 300;
    if (v > max) v = max;
    return v;
  }

  /// Prix du livre le MOINS cher possible : couverture souple au minimum de
  /// pages. Sert l'étiquette « dès … » du catalogue, qui annonçait 29 CHF en
  /// dur alors que le vrai plancher est calculé (53.50 au tarif du 06.10.26).
  static double get minPrice =>
      price(coverType: 'soft', pages: _minPages['soft']!);

  /// « CHF 24.90 »
  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';
}
