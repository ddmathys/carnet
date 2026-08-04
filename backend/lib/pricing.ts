// Miroir exact de lib/core/services/book_pricing.dart — les deux DOIVENT rester
// identiques. Recalculé ici pour ne jamais faire confiance au prix écrit par le
// client dans Firestore (order.price) au moment de facturer via Stripe.

const PER_PAGE = 0.24 // CHF / page (impression)
const PRINT_BASE_HARD = 8.5 // surcoût couverture rigide
const PRINT_BASE_SOFT = 4.5 // surcoût couverture souple
const SHIPPING = 9.35 // livraison Suisse (Swiss Post Eco)
const TAX_RATE = 0.08 // TVA Gelato (~8%)

const MARGIN_RATE = 0.2
const MARGIN_FLOOR = 8.0

export type CoverType = 'hard' | 'soft'

// Nombre de pages réellement facturable : PAIR, entre 28 et 200 (seule valeur
// acceptée par la création réelle de commande chez Gelato). Voir
// BookPricing.printablePages côté Dart pour l'historique complet.
export function printablePages(rawPages: number): number {
  let v = rawPages < 28 ? 28 : rawPages % 2 !== 0 ? rawPages + 1 : rawPages
  if (v > 200) v = 200
  return v
}

function gelatoCost(coverType: CoverType, pages: number): number {
  const base = coverType === 'hard' ? PRINT_BASE_HARD : PRINT_BASE_SOFT
  const printCost = base + PER_PAGE * pages
  return (printCost + SHIPPING) * (1 + TAX_RATE)
}

function marginFor(cost: number): number {
  return cost * MARGIN_RATE < MARGIN_FLOOR ? MARGIN_FLOOR : cost * MARGIN_RATE
}

// Prix client = coût Gelato + marge, arrondi au 0.50 supérieur.
export function computePrice(coverType: CoverType, rawPages: number): number {
  const pages = printablePages(rawPages)
  const cost = gelatoCost(coverType, pages)
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}
