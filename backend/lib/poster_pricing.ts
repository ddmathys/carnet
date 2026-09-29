// Miroir exact de lib/core/services/poster_pricing.dart — les deux DOIVENT
// rester identiques. Recalculé ici pour ne jamais faire confiance au prix
// écrit par le client dans Firestore (order.price), même logique que
// lib/pricing.ts pour les livres.
//
// Catalogue SKU/résolution confirmé le 20.08.26 via `GET /v4.0/products/{sku}`
// en sandbox (résolution lue directement dans la réponse
// (`variants[].printAreaSizes.default`), donc PAS recalculée depuis les mm).
// Couleur du hanger confirmée dans `attributes.color` du même appel : valeurs
// réelles `"black" | "natural" | "white"` (PAS "oak" malgré le nom commercial
// "chêne" côté site Prodigi).
//
// A0 paysage n'existe PAS au catalogue (testé 20.08.26 : 404/EntityNotFound
// sur POSTER-HANGER-{60,70,80,90}-A0-LAND) → A0 est portrait uniquement.
//
// ⚠️ `usdCost` recalibré le 21.08.26 : une VRAIE commande (A1 portrait) a été
// facturée $44.95 par Prodigi (item $27.28 + livraison $17.67) alors que
// l'app affichait CHF 30 au client — la table précédente ne contenait QUE le
// prix article (`GET /products`), la livraison n'était JAMAIS comptée, pour
// aucune taille. Valeurs ci-dessous = item + livraison réels vers la Suisse,
// lus via `POST /v4.0/quotes` (`shippingMethod: Standard`,
// `destinationCountryCode: CH`) le 21.08.26 — à re-vérifier si Prodigi change
// ses tarifs de livraison.
// Tableaux muraux (ajoutés le 29.09.26) : même produit « poster » côté
// commande, la MATIÈRE est portée par la taille — `CAN-16X20` = toile tendue
// Prodigi GLOBAL-CAN-16X20, `CFP-16X20` = tirage encadré GLOBAL-CFP-16X20.
// Aucune donnée de commande à migrer, tout le flux poster (paiement, mails,
// commandes groupées, admin) reste valable. Les deux SKU sont les mêmes en
// portrait et en paysage (Prodigi oriente d'après l'image).
//
// ⚠️ `usdCost` des tableaux = ESTIMATIONS, pas encore confirmées par un devis
// Prodigi (la route temporaire utilisée pour le puzzle n'a pas pu être
// refaite). Côté app, ces produits restent réservés à l'admin tant que
// `wallCostsVerified` (poster_pricing.dart) est faux — l'admin vérifie chaque
// taille avec « Vérifier chez Prodigi » puis on remplace ces valeurs.
export type WallMaterial = 'CAN' | 'CFP'
export type WallInches = '12X16' | '16X20' | '24X32' | '28X40'
export type WallSize = `${WallMaterial}-${WallInches}`
export type PosterSize = 'A4' | 'A3' | 'A2' | 'A1' | 'A0' | WallSize
export type PosterOrientation = 'portrait' | 'landscape'
export type PosterHangerColor = 'black' | 'natural' | 'white'

export interface PosterCatalogEntry {
  sku: string
  /** Coût Prodigi total réel (article + livraison Suisse), en USD. */
  usdCost: number
  /** Résolution d'impression exacte (px) confirmée par l'API Prodigi pour ce SKU. */
  printAreaPx: { width: number; height: number }
}

const CATALOG: Partial<Record<PosterSize, Partial<Record<PosterOrientation, PosterCatalogEntry>>>> = {
  A4: {
    portrait: { sku: 'POSTER-HANGER-20-A4-PORT', usdCost: 23.03, printAreaPx: { width: 2490, height: 3510 } },
    landscape: { sku: 'POSTER-HANGER-30-A4-LAND', usdCost: 24.20, printAreaPx: { width: 3510, height: 2490 } },
  },
  A3: {
    portrait: { sku: 'POSTER-HANGER-30-A3-PORT', usdCost: 27.70, printAreaPx: { width: 3507, height: 4960 } },
    landscape: { sku: 'POSTER-HANGER-40-A3-LAND', usdCost: 28.85, printAreaPx: { width: 4960, height: 3507 } },
  },
  A2: {
    portrait: { sku: 'POSTER-HANGER-40-A2-PORT', usdCost: 35.25, printAreaPx: { width: 4960, height: 7015 } },
    landscape: { sku: 'POSTER-HANGER-60-A2-LAND', usdCost: 37.98, printAreaPx: { width: 7015, height: 4960 } },
  },
  A1: {
    portrait: { sku: 'POSTER-HANGER-60-A1-PORT', usdCost: 44.93, printAreaPx: { width: 7020, height: 9930 } },
    landscape: { sku: 'POSTER-HANGER-80-A1-LAND', usdCost: 50.39, printAreaPx: { width: 9930, height: 7020 } },
  },
  A0: {
    portrait: { sku: 'POSTER-HANGER-80-A0-PORT', usdCost: 69.48, printAreaPx: { width: 9930, height: 14040 } },
    // Pas de landscape — voir commentaire d'en-tête.
  },
}

const WALL_INCHES: Record<WallInches, { w: number; h: number }> = {
  '12X16': { w: 12, h: 16 },
  '16X20': { w: 16, h: 20 },
  '24X32': { w: 24, h: 32 },
  '28X40': { w: 28, h: 40 },
}

// Coût estimé article + livraison Suisse (USD) — voir ⚠️ en tête de fichier.
const WALL_USD_COST: Record<WallMaterial, Record<WallInches, number>> = {
  CAN: { '12X16': 45, '16X20': 55, '24X32': 85, '28X40': 110 },
  CFP: { '12X16': 55, '16X20': 70, '24X32': 120, '28X40': 150 },
}

function parseWallSize(size: string): { material: WallMaterial; inches: WallInches } | null {
  const m = /^(CAN|CFP)-(12X16|16X20|24X32|28X40)$/.exec(size)
  return m ? { material: m[1] as WallMaterial, inches: m[2] as WallInches } : null
}

function wallCatalogEntry(size: string, orientation: PosterOrientation): PosterCatalogEntry | null {
  const wall = parseWallSize(size)
  if (!wall) return null
  const { w, h } = WALL_INCHES[wall.inches]
  // Résolution de référence à 300 DPI (contrôle qualité côté app uniquement —
  // Prodigi cadre lui-même le fichier, `sizing: 'fillPrintArea'`).
  const px = { width: w * 300, height: h * 300 }
  return {
    sku: `GLOBAL-${wall.material}-${wall.inches}`,
    usdCost: WALL_USD_COST[wall.material][wall.inches],
    printAreaPx: orientation === 'landscape' ? { width: px.height, height: px.width } : px,
  }
}

/**
 * Attributs Prodigi de l'article selon la matière : couleur de la baguette
 * (poster) ou du cadre (encadré), bords en miroir pour la toile (la photo
 * reste entière en façade, les côtés du châssis prolongent l'image).
 */
export function posterItemAttributes(size: string, color: string): Record<string, string> {
  const wall = parseWallSize(size)
  if (wall?.material === 'CAN') return { wrap: 'MirrorWrap' }
  return { color }
}

/** Libellé client : « Tirage A3 », « Toile 40×50 cm », « Tirage encadré 40×50 cm ». */
export function posterLabel(size: string): string {
  const wall = parseWallSize(size)
  if (!wall) return `Tirage ${size}`
  const { w, h } = WALL_INCHES[wall.inches]
  const cm = `${Math.round((w * 2.54) / 10) * 10}×${Math.round((h * 2.54) / 10) * 10} cm`
  return wall.material === 'CAN' ? `Toile ${cm}` : `Tirage encadré ${cm}`
}

/** Libellé de la couleur choisie (baguette ou cadre) — vide pour la toile. */
export function posterColorLabel(size: string, color: string): string {
  const wall = parseWallSize(size)
  if (wall?.material === 'CAN') return 'Bords en miroir'
  const labels: Record<string, string> = {
    black: 'Noir',
    natural: wall ? 'Bois naturel' : 'Chêne',
    white: 'Blanc',
  }
  return labels[color] ?? color
}

// Même taux/marge/arrondi que lib/pricing.ts, pour rester cohérent visuellement
// avec le prix des livres (un seul modèle de marge dans toute l'app).
const USD_TO_CHF = 0.9
const MARGIN_RATE = 0.4
const MARGIN_FLOOR = 10.0

export function posterCatalogEntry(
  size: PosterSize,
  orientation: PosterOrientation
): PosterCatalogEntry | null {
  return CATALOG[size]?.[orientation] ?? wallCatalogEntry(size, orientation)
}

function marginFor(cost: number): number {
  return cost * MARGIN_RATE < MARGIN_FLOOR ? MARGIN_FLOOR : cost * MARGIN_RATE
}

/** Prix client CHF = coût Prodigi total (article + livraison, converti) + marge, arrondi au 0.50 supérieur. */
export function computePosterPrice(size: PosterSize, orientation: PosterOrientation): number | null {
  const entry = posterCatalogEntry(size, orientation)
  if (!entry) return null
  const cost = entry.usdCost * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

export function isPosterSize(v: unknown): v is PosterSize {
  return (
    v === 'A4' || v === 'A3' || v === 'A2' || v === 'A1' || v === 'A0' ||
    (typeof v === 'string' && parseWallSize(v) != null)
  )
}

export function isPosterOrientation(v: unknown): v is PosterOrientation {
  return v === 'portrait' || v === 'landscape'
}

export function isPosterHangerColor(v: unknown): v is PosterHangerColor {
  return v === 'black' || v === 'natural' || v === 'white'
}
