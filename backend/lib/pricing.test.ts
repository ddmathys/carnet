import { test } from 'node:test'
import assert from 'node:assert/strict'
import { computePrice, resolveCoverType } from './pricing.ts'
import { computePosterPrice } from './poster_pricing.ts'

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
