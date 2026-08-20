// Miroir exact de lib/core/services/poster_pricing.dart — les deux DOIVENT
// rester identiques. Recalculé ici pour ne jamais faire confiance au prix
// écrit par le client dans Firestore (order.price), même logique que
// lib/pricing.ts pour les livres.
//
// Catalogue confirmé le 20.08.26 via de VRAIS appels
// `GET /v4.0/products/{sku}` en sandbox (pas juste le tableau collé par
// l'utilisateur depuis le dashboard Prodigi — chaque SKU a été vérifié vivant,
// et la résolution d'impression exacte lue directement dans la réponse
// (`variants[].printAreaSizes.default`), donc PAS recalculée depuis les mm —
// c'est la source la plus fiable possible pour le contrôle qualité DPI côté
// app). Couleur du hanger confirmée dans `attributes.color` du même appel :
// valeurs réelles `"black" | "natural" | "white"` (PAS "oak" malgré le nom
// commercial "chêne" côté site Prodigi — c'est bien "natural" à envoyer dans
// `items[].attributes.color`).
//
// A0 paysage n'existe PAS au catalogue (testé 20.08.26 : 404/EntityNotFound
// sur POSTER-HANGER-{60,70,80,90}-A0-LAND) → A0 est portrait uniquement.
export type PosterSize = 'A4' | 'A3' | 'A2' | 'A1' | 'A0'
export type PosterOrientation = 'portrait' | 'landscape'
export type PosterHangerColor = 'black' | 'natural' | 'white'

export interface PosterCatalogEntry {
  sku: string
  usd: number
  /** Résolution d'impression exacte (px) confirmée par l'API Prodigi pour ce SKU. */
  printAreaPx: { width: number; height: number }
}

const CATALOG: Record<PosterSize, Partial<Record<PosterOrientation, PosterCatalogEntry>>> = {
  A4: {
    portrait: { sku: 'POSTER-HANGER-20-A4-PORT', usd: 10.0, printAreaPx: { width: 2490, height: 3510 } },
    landscape: { sku: 'POSTER-HANGER-30-A4-LAND', usd: 11.0, printAreaPx: { width: 3510, height: 2490 } },
  },
  A3: {
    portrait: { sku: 'POSTER-HANGER-30-A3-PORT', usd: 14.0, printAreaPx: { width: 3507, height: 4960 } },
    landscape: { sku: 'POSTER-HANGER-40-A3-LAND', usd: 15.0, printAreaPx: { width: 4960, height: 3507 } },
  },
  A2: {
    portrait: { sku: 'POSTER-HANGER-40-A2-PORT', usd: 16.0, printAreaPx: { width: 4960, height: 7015 } },
    landscape: { sku: 'POSTER-HANGER-60-A2-LAND', usd: 19.0, printAreaPx: { width: 7015, height: 4960 } },
  },
  A1: {
    portrait: { sku: 'POSTER-HANGER-60-A1-PORT', usd: 24.0, printAreaPx: { width: 7020, height: 9930 } },
    landscape: { sku: 'POSTER-HANGER-80-A1-LAND', usd: 28.0, printAreaPx: { width: 9930, height: 7020 } },
  },
  A0: {
    portrait: { sku: 'POSTER-HANGER-80-A0-PORT', usd: 45.0, printAreaPx: { width: 9930, height: 14040 } },
    // Pas de landscape — voir commentaire d'en-tête.
  },
}

// Même taux/marge/arrondi que lib/pricing.ts, pour rester cohérent visuellement
// avec le prix des livres (un seul modèle de marge dans toute l'app).
const USD_TO_CHF = 0.9
const MARGIN_RATE = 0.2
const MARGIN_FLOOR = 8.0

export function posterCatalogEntry(
  size: PosterSize,
  orientation: PosterOrientation
): PosterCatalogEntry | null {
  return CATALOG[size]?.[orientation] ?? null
}

function marginFor(cost: number): number {
  return cost * MARGIN_RATE < MARGIN_FLOOR ? MARGIN_FLOOR : cost * MARGIN_RATE
}

/** Prix client CHF = coût Prodigi (converti) + marge, arrondi au 0.50 supérieur. */
export function computePosterPrice(size: PosterSize, orientation: PosterOrientation): number | null {
  const entry = posterCatalogEntry(size, orientation)
  if (!entry) return null
  const cost = entry.usd * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

export function isPosterSize(v: unknown): v is PosterSize {
  return v === 'A4' || v === 'A3' || v === 'A2' || v === 'A1' || v === 'A0'
}

export function isPosterOrientation(v: unknown): v is PosterOrientation {
  return v === 'portrait' || v === 'landscape'
}

export function isPosterHangerColor(v: unknown): v is PosterHangerColor {
  return v === 'black' || v === 'natural' || v === 'white'
}
