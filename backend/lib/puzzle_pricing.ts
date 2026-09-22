// Miroir exact de lib/core/services/puzzle_pricing.dart — les deux DOIVENT
// rester identiques. Recalculé ici pour ne jamais faire confiance au prix
// écrit par le client dans Firestore (order.price), même logique que
// lib/poster_pricing.ts.
//
// Catalogue SKU/résolution/coût confirmé le 22.09.26 via `GET /v4.0/products/
// {sku}` puis `POST /v4.0/quotes` (`shippingMethod: Standard`,
// `destinationCountryCode: CH`) en PRODUCTION (pas sandbox — le compte
// Prodigi de carnet n'a que des clés live, voir backend/lib/prodigi.ts).
// `usdCost` = item + livraison réels vers la Suisse (même piège que les
// posters le 21.08.26 : ne JAMAIS compter que le prix article).
//
// Un seul photoformat par taille (pas d'orientation à choisir comme pour le
// poster) : Prodigi cadre lui-même la photo dans la zone d'impression
// (`sizing: 'fillPrintArea'`, voir backend/api/prodigi/[action].ts), donc pas
// de couple taille/orientation ni de résolution à valider côté app — la
// résolution du catalogue est gardée ici pour référence uniquement.
export type PuzzleSize = '30' | '110' | '252' | '500' | '1000'

export interface PuzzleCatalogEntry {
  sku: string
  pieces: number
  /** Coût Prodigi total réel (article + livraison Suisse), en USD. */
  usdCost: number
  /** Résolution d'impression de la zone "jigsaw" (px), pour référence. */
  printAreaPx: { width: number; height: number }
}

const CATALOG: Record<PuzzleSize, PuzzleCatalogEntry> = {
  '30': { sku: 'JIGSAW-PUZZLE-30', pieces: 30, usdCost: 26.32, printAreaPx: { width: 2952, height: 2362 } },
  '110': { sku: 'JIGSAW-PUZZLE-110', pieces: 110, usdCost: 28.99, printAreaPx: { width: 2952, height: 2362 } },
  '252': { sku: 'JIGSAW-PUZZLE-252', pieces: 252, usdCost: 30.33, printAreaPx: { width: 4429, height: 3366 } },
  '500': { sku: 'JIGSAW-PUZZLE-500', pieces: 500, usdCost: 34.34, printAreaPx: { width: 6259, height: 4606 } },
  '1000': { sku: 'JIGSAW-PUZZLE-1000', pieces: 1000, usdCost: 39.69, printAreaPx: { width: 9035, height: 6200 } },
}

// Même taux/marge/arrondi que poster_pricing.ts et lib/pricing.ts — un seul
// modèle de marge dans toute l'app.
const USD_TO_CHF = 0.9
const MARGIN_RATE = 0.4
const MARGIN_FLOOR = 10.0

export function puzzleCatalogEntry(size: PuzzleSize): PuzzleCatalogEntry | null {
  return CATALOG[size] ?? null
}

function marginFor(cost: number): number {
  return cost * MARGIN_RATE < MARGIN_FLOOR ? MARGIN_FLOOR : cost * MARGIN_RATE
}

/** Prix client CHF = coût Prodigi total (article + livraison, converti) + marge, arrondi au 0.50 supérieur. */
export function computePuzzlePrice(size: PuzzleSize): number | null {
  const entry = puzzleCatalogEntry(size)
  if (!entry) return null
  const cost = entry.usdCost * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

export function isPuzzleSize(v: unknown): v is PuzzleSize {
  return v === '30' || v === '110' || v === '252' || v === '500' || v === '1000'
}
