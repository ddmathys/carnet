import '../models/memory_model.dart';

/// Tarification du livre imprimé, alignée sur le nombre de pages.
///
/// Prix = base (selon la couverture) couvrant jusqu'à [includedPages] pages,
/// puis [perExtraPage] CHF par page au-delà. Les constantes ci-dessous sont les
/// seuls leviers à ajuster pour changer la grille tarifaire.
class BookPricing {
  // ── Leviers de prix (à ajuster librement) ────────────────────────────────
  static const double softBase = 24.90; // couverture souple, livre « standard »
  static const double hardBase = 34.90; // couverture rigide
  static const int includedPages = 24; // pages incluses dans le prix de base
  static const double perExtraPage = 0.50; // CHF par page au-delà

  /// Prix d'un livre pour une couverture donnée et un nombre de pages.
  static double price({required String coverType, required int pages}) {
    final base = coverType == 'hard' ? hardBase : softBase;
    final extra = pages > includedPages ? (pages - includedPages) * perExtraPage : 0.0;
    return base + extra;
  }

  /// Estimation du nombre de pages AVANT génération du PDF (pour afficher le
  /// prix sur les écrans format/commande). La pagination réelle dépend de
  /// l'orientation des photos (portrait = 1 page, paysages = 2/page), inconnue
  /// sans télécharger les images : on estime donc ~1 page par photo (la plupart
  /// des photos de téléphone sont en portrait) + 1 page par souvenir-texte +
  /// la couverture. Le prix affiché = prix facturé (cohérence).
  static int estimatePages(List<MemoryModel> memories) {
    int photos = 0;
    int textOnly = 0;
    for (final m in memories) {
      final n = m.mediaUrls.isNotEmpty
          ? m.mediaUrls.length
          : (m.photoUrl != null && m.photoUrl!.isNotEmpty ? 1 : 0);
      if (n > 0) {
        photos += n;
      } else if (m.type != 'taille_poids') {
        textOnly += 1;
      }
    }
    return 1 + photos + textOnly; // couverture + pages photo + pages texte
  }

  /// « CHF 24.90 »
  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';
}
