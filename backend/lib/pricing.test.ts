import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  computePrice,
  computeAdditionalPrice,
  pagesOutOfRange,
  resolveCoverType,
} from './pricing.ts'
import {
  computePosterPrice,
  computeAdditionalPosterPrice,
  posterCatalogEntry,
  posterItemAttributes,
  posterLabel,
} from './poster_pricing.ts'
import {
  computePuzzlePrice,
  computeAdditionalPuzzlePrice,
} from './puzzle_pricing.ts'

// Non-régression du bug corrigé le 15.09.26 : checkout.ts ignorait
// 'layflat' et facturait au tarif 'soft' (moins cher que le coût
// d'impression réel), un poster ne passait pas du tout par ce chemin de
// prix (pageCount requis à tort). resolveCoverType() est désormais le seul
// endroit qui décide "quel type de couverture", partagé par checkout.ts et
// prodigi/[action].ts.

test('resolveCoverType reconnaît hard et layflat', () => {
  assert.equal(resolveCoverType('hard'), 'hard')
  assert.equal(resolveCoverType('layflat'), 'layflat')
})

test('resolveCoverType retombe sur soft pour toute autre valeur', () => {
  assert.equal(resolveCoverType('soft'), 'soft')
  assert.equal(resolveCoverType(undefined), 'soft')
  assert.equal(resolveCoverType(''), 'soft')
  assert.equal(resolveCoverType('hardcover'), 'soft')
})

test('le layflat est facturé plus cher que le soft à pagination égale', () => {
  const soft = computePrice('soft', 40)
  const layflat = computePrice('layflat', 40)
  assert.ok(layflat > soft, `layflat (${layflat}) devrait coûter plus cher que soft (${soft})`)
})

test('computePosterPrice couvre toutes les tailles/orientations du catalogue sauf A0 paysage', () => {
  const sizes = ['A4', 'A3', 'A2', 'A1', 'A0'] as const
  const orientations = ['portrait', 'landscape'] as const
  for (const size of sizes) {
    for (const orientation of orientations) {
      const price = computePosterPrice(size, orientation)
      if (size === 'A0' && orientation === 'landscape') {
        assert.equal(price, null, 'A0 paysage n\'existe pas au catalogue Prodigi')
      } else {
        assert.ok(price != null && price > 0, `${size}/${orientation} devrait avoir un prix`)
      }
    }
  }
})

test('tableaux muraux : toile et encadré, SKU Prodigi et attributs par matière', () => {
  for (const inches of ['12X16', '16X20', '24X32', '28X40'] as const) {
    for (const orientation of ['portrait', 'landscape'] as const) {
      const can = posterCatalogEntry(`CAN-${inches}`, orientation)
      const cfp = posterCatalogEntry(`CFP-${inches}`, orientation)
      assert.equal(can?.sku, `GLOBAL-CAN-${inches}`)
      assert.equal(cfp?.sku, `GLOBAL-CFP-${inches}`)
      assert.ok((computePosterPrice(`CAN-${inches}`, orientation) ?? 0) > 0)
      assert.ok((computePosterPrice(`CFP-${inches}`, orientation) ?? 0) > 0)
    }
  }
  assert.deepEqual(posterItemAttributes('CAN-16X20', 'black'), { wrap: 'MirrorWrap' })
  assert.deepEqual(posterItemAttributes('CFP-16X20', 'white'), { color: 'white' })
  assert.deepEqual(posterItemAttributes('A3', 'natural'), { color: 'natural' })
  assert.equal(posterLabel('CAN-16X20'), 'Toile 40×50 cm')
  assert.equal(posterLabel('A3'), 'Tirage A3')
  assert.equal(posterCatalogEntry('CAN-99X99' as never, 'portrait'), null)
})

// ── Groupage : le port ne se facture qu'une fois (audit du 01.10.26) ────────
// Avant, le total d'une commande groupée additionnait des prix d'articles
// contenant CHACUN le port, alors que Prodigi ne facture la livraison qu'une
// fois par commande : deux posters A4 étaient facturés 2 × CHF 31 au client.

test('un article supplémentaire coûte moins cher que le premier (port déduit)', () => {
  const first = computePrice('soft', 40)
  const extra = computeAdditionalPrice('soft', 40)
  assert.ok(extra < first, `extra (${extra}) devrait être < premier (${first})`)
  // L'économie correspond au port (≈ CHF 16.84 pour le soft), à l'arrondi et
  // à la marge près — jamais plus que le port lui-même.
  assert.ok(first - extra <= 18.71 * 0.9 * 1.4 + 0.5)
})

test('un article supplémentaire rapporte toujours au moins la marge plancher', () => {
  for (const cover of ['soft', 'hard', 'layflat'] as const) {
    const extra = computeAdditionalPrice(cover, 40)
    assert.ok(extra >= 10, `${cover} : ${extra} devrait couvrir le plancher de CHF 10`)
  }
})

test('deux posters groupés coûtent moins que deux posters séparés', () => {
  const alone = computePosterPrice('A4', 'portrait')!
  const extra = computeAdditionalPosterPrice('A4', 'portrait')!
  assert.ok(extra < alone)
  assert.ok(alone + extra < alone * 2)
})

test('deux puzzles groupés coûtent moins que deux puzzles séparés', () => {
  const alone = computePuzzlePrice('30')!
  const extra = computeAdditionalPuzzlePrice('30')!
  assert.ok(extra < alone)
  assert.ok(alone + extra < alone * 2)
})

test('A0 paysage n’a pas de tarif groupé non plus (absent du catalogue)', () => {
  assert.equal(computeAdditionalPosterPrice('A0', 'landscape'), null)
})

// ── Bornes de pages : refus au lieu d'un écrêtage silencieux ────────────────

test('pagesOutOfRange borne le layflat à 122 pages et le soft à 300', () => {
  assert.equal(pagesOutOfRange('layflat', 122), false)
  assert.equal(pagesOutOfRange('layflat', 123), true)
  assert.equal(pagesOutOfRange('soft', 300), false)
  assert.equal(pagesOutOfRange('soft', 301), true)
})

test('un livre dans les bornes n’est jamais refusé', () => {
  assert.equal(pagesOutOfRange('soft', 20), false)
  assert.equal(pagesOutOfRange('hard', 24), false)
  assert.equal(pagesOutOfRange('layflat', 18), false)
})

// ── Prix plancher affiché au catalogue (écran « Créer un souvenir imprimé ») ─

test('le livre le moins cher possible coûte bien 37.50 et pas 29', () => {
  assert.equal(computePrice('soft', 20), 37.5)
})
