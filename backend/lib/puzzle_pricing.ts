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
// Catalogue resserré le 06.10.26 (positionnement premium) : les tailles 30 et
// 110 pièces ont été RETIRÉES. Elles tiraient l'étiquette « dès CHF … » vers
// le bas pour un objet qui n'est pas un cadeau (30 pièces), et contredisaient
// le discours premium. Aucune donnée à migrer : `isPuzzleSize` refuse
// désormais '30'/'110', donc une commande historique qui les porterait serait
// rejetée à la création de session Stripe et à l'envoi Prodigi plutôt que
// facturée au mauvais tarif — il n'en existe aucune en base au moment du
// changement (aucune commande puzzle n'a encore été passée).
export type PuzzleSize = '252' | '500' | '1000'

export interface PuzzleCatalogEntry {
  sku: string
  pieces: number
  /** Coût Prodigi total réel (article + livraison Suisse), en USD. */
  usdCost: number
  /** Résolution d'impression de la zone "jigsaw" (px), pour référence. */
  printAreaPx: { width: number; height: number }
  /**
   * Résolution d'impression de la zone "lid" (couvercle de la boîte métal),
   * relevée le 06.10.26 dans la fiche produit publique de Prodigi
   * (prodigi.com/download/product-range/Prodigi Jigsaw puzzles.pdf) :
   * « Print dimensions for puzzle tin lids are as follows: 30pc/110pc/252pc
   * tins (869x674px), 500pc/1000pc tins (1724x1169px) ».
   *
   * ⚠️ Ce RATIO est ce qui compte : le PDF du couvercle est composé
   * exactement à ces proportions pour que `sizing: 'fillPrintArea'` n'ait
   * rien à recadrer — sinon le QR imprimé dessus peut être coupé.
   */
  lidPrintAreaPx: { width: number; height: number }
  /** Taille du puzzle assemblé (mm), même source. Sert aux libellés. */
  assembledMm: { width: number; height: number }
}

const CATALOG: Record<PuzzleSize, PuzzleCatalogEntry> = {
  '252': {
    sku: 'JIGSAW-PUZZLE-252', pieces: 252, usdCost: 30.33,
    printAreaPx: { width: 4429, height: 3366 },
    lidPrintAreaPx: { width: 869, height: 674 },
    assembledMm: { width: 375, height: 285 },
  },
  '500': {
    sku: 'JIGSAW-PUZZLE-500', pieces: 500, usdCost: 34.34,
    printAreaPx: { width: 6259, height: 4606 },
    lidPrintAreaPx: { width: 1724, height: 1169 },
    assembledMm: { width: 530, height: 390 },
  },
  '1000': {
    sku: 'JIGSAW-PUZZLE-1000', pieces: 1000, usdCost: 39.69,
    printAreaPx: { width: 9035, height: 6200 },
    lidPrintAreaPx: { width: 1724, height: 1169 },
    assembledMm: { width: 765, height: 525 },
  },
}

const USD_TO_CHF = 0.9

// ⚠️ LE PUZZLE NE SE CALCULE PAS COMME LE LIVRE ET LE POSTER.
//
// `lib/pricing.ts` et `lib/poster_pricing.ts` appliquent une MAJORATION de
// 40 % sur le coût (`prix = coût × 1,4`), ce qui ne laisse en réalité que
// 29 % du prix de vente. Le puzzle, lui, vise une MARGE de 40 % DU PRIX DE
// VENTE : `prix = coût ÷ 0,60`. Décision de David le 06.10.26, après avoir vu
// les deux chiffrages côte à côte.
//
// Pourquoi ce produit et pas les autres : à 40 % de majoration, le 1000
// pièces sortait à CHF 50.50 livraison comprise, soit MOINS CHER que le
// leader du marché suisse (ifolor, CHF 49.95 + 5.95 de port = CHF 55.90
// livré) — intenable pour un produit vendu comme premium. Le modèle retenu
// donne 45.50 / 52.— / 60.—, donc toujours au-dessus d'ifolor sur le grand
// format, ce que justifient les deux différenciateurs réels : zéro travail de
// mise en page (les souvenirs sont déjà dans l'app) et le QR du couvercle,
// qui fait jouer les vidéos du souvenir — personne d'autre ne le propose.
//
// Le taux reste DANS le moteur coût + marge plutôt que remplacé par trois
// prix en dur : si Prodigi change ses tarifs, le prix client suit au lieu de
// vendre à perte en silence.
const MARGIN_SHARE = 0.5
const MARGIN_FLOOR = 10.0

export function puzzleCatalogEntry(size: PuzzleSize): PuzzleCatalogEntry | null {
  return CATALOG[size] ?? null
}

/**
 * Marge en francs pour un coût donné, de sorte que la marge représente
 * `MARGIN_SHARE` du PRIX DE VENTE et non du coût :
 *
 *   prix = coût / (1 − part)  ⟺  marge = coût × part / (1 − part)
 *
 * Le plancher reste un filet de sécurité (il ne joue à aucune taille du
 * catalogue actuel, même sur un article supplémentaire port déduit).
 */
function marginFor(cost: number): number {
  const margin = cost * (MARGIN_SHARE / (1 - MARGIN_SHARE))
  return margin < MARGIN_FLOOR ? MARGIN_FLOOR : margin
}

/** Prix client CHF = coût Prodigi total (article + livraison, converti) + marge, arrondi au 0.50 supérieur. */
export function computePuzzlePrice(size: PuzzleSize): number | null {
  const entry = puzzleCatalogEntry(size)
  if (!entry) return null
  const cost = entry.usdCost * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

// Part « livraison » comprise dans `usdCost`. Contrairement aux posters, elle
// n'a JAMAIS été isolée sur un devis Prodigi pour les puzzles : cette valeur
// est donc volontairement PRUDENTE (le port réel vers la Suisse est plus
// proche de $17). Elle ne sert qu'à déduire le port d'un puzzle supplémentaire
// groupé : sous-estimer surfacture légèrement le client, surestimer vendrait à
// perte.
//
// ⚠️ TOUJOURS À RECALER, mais l'outil existe depuis le 06.10.26 : bouton
// « Mesurer chez Prodigi » de l'écran puzzle (admin) → POST /api/prodigi/quote
// avec `copies: 1` puis `copies: 2`. La différence des coûts d'ARTICLES donne
// l'article sans port, et `prodigiShippingUsd` doit être IDENTIQUE sur les deux
// devis — s'il double, Prodigi facture par article et tout le modèle de
// commande groupée est faux.
const SHIPPING_USD = 12.0

/** Prix d'un puzzle SUPPLÉMENTAIRE dans la même commande : port déduit, que
 *  Prodigi ne facture qu'une fois par commande. */
export function computeAdditionalPuzzlePrice(size: PuzzleSize): number | null {
  const entry = puzzleCatalogEntry(size)
  if (!entry) return null
  const cost = Math.max(0, entry.usdCost - SHIPPING_USD) * USD_TO_CHF
  const raw = cost + marginFor(cost)
  return Math.ceil(raw * 2) / 2
}

export function isPuzzleSize(v: unknown): v is PuzzleSize {
  return v === '252' || v === '500' || v === '1000'
}
