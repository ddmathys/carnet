// Miroir exact de lib/core/services/book_pricing.dart — les deux DOIVENT rester
// identiques. Recalculé ici pour ne jamais faire confiance au prix écrit par le
// client dans Firestore (order.price).
//
// Constantes calibrées le 06.08.26 sur de VRAIS appels `POST /v4.0/quotes`
// (destinationCountryCode: "CH", shippingMethod: "Standard") — pas juste le
// simulateur web, confirmé via la vraie clé API :
// - Soft (BOOK-FE-A4-P-SOFT-MHK), devis 40 pages : base 20p = $10.97,
//   +$0.30/page au-delà, livraison $18.71 (expédié depuis DE), taxe $0.00.
// - Hard (BOOK-FE-A4-P-HARD-G), devis 68 pages : base 24p = $13.48,
//   +$0.25/page au-delà, livraison $17.49 (expédié depuis NL), taxe $0.00.
// Conversion USD→CHF à ~0.90 (approximatif, à réviser périodiquement — le
// cours bouge, seule variable non confirmée par l'API). Prodigi n'ajoute PAS
// de TVA suisse à ces montants (`totalTax: 0.00` confirmé sur le devis) : les
// droits de douane/TVA import (~8.1%) sont à la charge du DESTINATAIRE à la
// livraison, pas facturés par Prodigi — d'où l'absence d'un multiplicateur de
// taxe ici (contrairement à l'ancien modèle Gelato).
const USD_TO_CHF = 0.9

const MIN_PAGES: Record<CoverType, number> = { soft: 20, hard: 24 }
const MAX_PAGES = 300

const BASE_PRICE_USD: Record<CoverType, number> = { soft: 10.97, hard: 13.48 }
const EXTRA_PAGE_USD: Record<CoverType, number> = { soft: 0.3, hard: 0.25 }
const SHIPPING_USD: Record<CoverType, number> = { soft: 18.71, hard: 17.49 }

const MARGIN_RATE = 0.2
const MARGIN_FLOOR = 8.0

export type CoverType = 'hard' | 'soft'

// Nombre de pages réellement facturable : PAIR par précaution (règle non
// confirmée comme rejetée par Prodigi — testé le 06.08.26 via de vrais
// POST /v4.0/quotes avec pages impaires, acceptés sans erreur ; peut-être
// vérifiée seulement à la vraie création de commande, non testée pour
// éviter un risque avec la clé live). Bornes de pages confirmées le 06.08.26
// sur les fiches produit Prodigi : softcover 20-300, hardcover 24-300 (500
// en 150gsm gloss only, non géré ici par simplicité).
export function printablePages(coverType: CoverType, rawPages: number): number {
  const min = MIN_PAGES[coverType]
  let v = rawPages < min ? min : rawPages % 2 !== 0 ? rawPages + 1 : rawPages
  if (v > MAX_PAGES) v = MAX_PAGES
  return v
}

function printCost(coverType: CoverType, pages: number): number {
  const min = MIN_PAGES[coverType]
  const extraPages = Math.max(0, pages - min)
  const usd =
    BASE_PRICE_USD[coverType] +
    EXTRA_PAGE_USD[coverType] * extraPages +
    SHIPPING_USD[coverType]
  return usd * USD_TO_CHF
}

function marginFor(cost: number): number {
  return cost * MARGIN_RATE < MARGIN_FLOOR ? MARGIN_FLOOR : cost * MARGIN_RATE
}

// Prix client = coût impression + marge, arrondi au 0.50 supérieur.
export function computePrice(coverType: CoverType, rawPages: number): number {
  const pages = printablePages(coverType, rawPages)
  const cost = printCost(coverType, pages)
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}
