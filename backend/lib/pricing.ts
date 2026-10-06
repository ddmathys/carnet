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

// Layflat (BOOK-FE-A4-P-LF-G) : calibré le 18.08.26 sur de VRAIS
// POST /v4.0/quotes (CH, Standard) — 2 points (40 et 100 pages) : items
// $35.01/$64.18 → régression linéaire base 18p = $24.31, +$0.49/page ;
// shipping $18.75 constant, expédié DE (comme le softcover). 18-122 pages
// (borne produit catalogue Prodigi).
const MIN_PAGES: Record<CoverType, number> = { soft: 20, hard: 24, layflat: 18 }
const MAX_PAGES: Record<CoverType, number> = { soft: 300, hard: 300, layflat: 122 }

const BASE_PRICE_USD: Record<CoverType, number> = { soft: 10.97, hard: 13.48, layflat: 24.31 }
const EXTRA_PAGE_USD: Record<CoverType, number> = { soft: 0.3, hard: 0.25, layflat: 0.49 }
const SHIPPING_USD: Record<CoverType, number> = { soft: 18.71, hard: 17.49, layflat: 18.75 }

// ── MODÈLE DE MARGE COMMUN AUX TROIS PRODUITS (06.10.26) ────────────────────
//
// `MARGIN_SHARE` est la part du PRIX DE VENTE qui reste à Carnet, PAS une
// majoration appliquée au coût. Les deux se confondent facilement et ne
// donnent pas du tout la même chose :
//
//   majoration de 40 % : prix = coût × 1,4  → il ne reste que 29 % du prix
//   marge de 50 %      : prix = coût ÷ 0,50 → il reste bien 50 % du prix
//
// Jusqu'au 06.10.26 le code appliquait une majoration de 40 % en l'appelant
// « marge 40 % », donc tout le catalogue ne rapportait en réalité que 29 %.
// Décision de David : 50 % du prix encaissé sur les livres, les tirages et
// les puzzles.
//
// Le plancher reste un filet de sécurité : il ne joue sur aucune référence du
// catalogue actuel.
const MARGIN_SHARE = 0.5
const MARGIN_FLOOR = 10.0

export type CoverType = 'hard' | 'soft' | 'layflat'

// Un seul endroit pour "quel type de couverture pour cette valeur brute
// venue de Firestore/du client" — dupliqué avant le 15.09.26 dans
// checkout.ts et prodigi/[action].ts avec un ternaire qui a divergé une fois
// (checkout.ts ignorait 'layflat' et facturait au tarif 'soft', moins cher).
export function resolveCoverType(raw: unknown): CoverType {
  return raw === 'hard' || raw === 'layflat' ? raw : 'soft'
}

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
  const max = MAX_PAGES[coverType]
  if (v > max) v = max
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

/**
 * Marge en francs telle qu'elle représente `MARGIN_SHARE` du PRIX DE VENTE :
 *   prix = coût / (1 − part)  ⟺  marge = coût × part / (1 − part)
 */
function marginFor(cost: number): number {
  const margin = cost * (MARGIN_SHARE / (1 - MARGIN_SHARE))
  return margin < MARGIN_FLOOR ? MARGIN_FLOOR : margin
}

// Prix client = coût impression + marge, arrondi au 0.50 supérieur.
export function computePrice(coverType: CoverType, rawPages: number): number {
  const pages = printablePages(coverType, rawPages)
  const cost = printCost(coverType, pages)
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

// ── Articles GROUPÉS dans une même commande ──────────────────────────────────
//
// Prodigi facture la livraison UNE FOIS par commande, pas par article : c'est
// tout l'intérêt du groupage (voir `additionalPosters`/`additionalBooks`/
// `additionalPuzzles`). Or le prix total additionnait des prix d'articles qui
// contiennent CHACUN le port — le client payait donc le port autant de fois
// qu'il commandait d'articles (audit du 01.10.26 : deux posters A4 facturés
// 2 × CHF 31 alors que Prodigi n'encaisse qu'un seul port).
//
// Le PREMIER article garde son prix complet (port inclus) ; chaque article
// SUPPLÉMENTAIRE est facturé sans port. La marge (40 %, plancher CHF 10)
// s'applique normalement au coût réduit, donc chaque article supplémentaire
// rapporte toujours au moins CHF 10.
export function computeAdditionalPrice(
  coverType: CoverType,
  rawPages: number
): number {
  const pages = printablePages(coverType, rawPages)
  const cost = printCost(coverType, pages) - SHIPPING_USD[coverType] * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

// Nombre de pages hors bornes produit : refusé plutôt qu'écrêté en silence.
// `printablePages` ramenait un livre layflat de 150 pages à 122 pour le PRIX,
// alors que la commande envoyée à Prodigi transportait les 150 pages réelles —
// facturé 122, imprimé 150 (audit du 01.10.26).
export function pagesOutOfRange(coverType: CoverType, rawPages: number): boolean {
  return rawPages > MAX_PAGES[coverType]
}
