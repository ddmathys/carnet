import '../models/memory_model.dart';

/// Tarification du livre imprimé = **coût Gelato tout compris** (impression +
/// livraison + TVA) **+ une marge**. Objectif : rester compétitif tout en
/// couvrant l'intégralité du coût.
///
/// Calibré sur une commande réelle Gelato (Photo Book 8×11", juin 2026 :
/// 68 pages rigide → impression 23.72 + livraison 9.35 + TVA 8% = 35.75 CHF).
/// Les constantes ci-dessous sont les seuls leviers à ajuster.
class BookPricing {
  // ── Coût Gelato estimé (leviers) ──────────────────────────────────────────
  static const double perPage = 0.24;        // CHF / page (impression)
  static const double printBaseHard = 8.50;  // surcoût couverture rigide
  static const double printBaseSoft = 4.50;  // surcoût couverture souple
  static const double shipping = 9.35;        // livraison Suisse (Swiss Post Eco)
  static const double taxRate = 0.08;         // TVA Gelato (~8%)

  // ── Marge visée ──────────────────────────────────────────────────────────
  // 20% du coût, avec un PLANCHER absolu de 8 CHF : sur un petit livre (peu
  // de pages), 20% ne représenterait que quelques francs — insuffisant pour
  // couvrir la validation manuelle de la commande (dashboard Gelato) et les
  // frais annexes. Le plancher protège ces petites commandes ; au-delà, c'est
  // le pourcentage qui prend le relais (gros livres = marge plus élevée).
  static const double marginRate = 0.20;
  static const double marginFloor = 8.0;

  /// Coût Gelato estimé (impression + livraison + TVA) pour une couverture et
  /// un nombre de pages donnés.
  static double gelatoCost({required String coverType, required int pages}) {
    final base = coverType == 'hard' ? printBaseHard : printBaseSoft;
    final printCost = base + perPage * pages;
    return (printCost + shipping) * (1 + taxRate);
  }

  /// Marge appliquée sur un coût donné : max(20% du coût, plancher 8 CHF).
  static double marginFor(double cost) => cost * marginRate < marginFloor
      ? marginFloor
      : cost * marginRate;

  /// Prix client = coût Gelato + marge, arrondi au 0.50 supérieur (le coût reste
  /// toujours couvert).
  static double price({required String coverType, required int pages}) {
    final cost = gelatoCost(coverType: coverType, pages: pages);
    final raw = cost + marginFor(cost);
    return (raw * 2).ceilToDouble() / 2;
  }

  /// Estimation du nombre de pages AVANT génération du PDF (fallback ; dès que
  /// l'aperçu est généré on utilise le vrai compte). ~4 photos par page + 1 page
  /// par souvenir-texte + la couverture.
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
    return 1 + pages; // + couverture
  }

  /// Nombre de pages réellement imprimé : contrainte Gelato (pair, min 28, max
  /// 200). C'est sur CETTE base qu'est facturé un livre imprimé.
  static int printablePages(int rawPages) {
    var v = rawPages < 28 ? 28 : (rawPages.isOdd ? rawPages + 1 : rawPages);
    if (v > 200) v = 200;
    return v;
  }

  /// « CHF 24.90 »
  static String format(double price) => 'CHF ${price.toStringAsFixed(2)}';
}
