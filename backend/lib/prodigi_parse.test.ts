import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseProdigiOrder,
  parseProdigiShipments,
  parseProdigiCharges,
  resolveTrackingUrl,
} from './prodigi_parse.ts'

// Réponses calquées sur deux VRAIES commandes du 24.08.26, celles qui restaient
// affichées « pending » dans l'app alors que le tableau de bord Prodigi les
// donnait expédiées depuis deux jours. Elles servent de non-régression :
// c'est exactement cette forme-là que le parsing doit reconnaître.

/** Livre A4 rigide, expédié du Royaume-Uni — shp_13944500. */
const shippedFromGb = {
  order: {
    id: '14417089',
    status: {
      stage: 'InProgress',
      issues: [],
      details: {
        downloadAssets: 'Complete',
        printReadyAssetsPrepared: 'Complete',
        allocateProductionLocation: 'Complete',
        inProduction: 'Complete',
        shipping: 'InProgress',
      },
    },
    charges: [
      {
        totalCost: { amount: '42.19', currency: 'USD' },
        items: [
          { description: 'Book', itemSku: 'BOOK-FE-A4-P-HARD-G', cost: { amount: '24.52', currency: 'USD' } },
          { description: 'Shipping', itemSku: null, cost: { amount: '17.67', currency: 'USD' } },
        ],
      },
    ],
    shipments: [
      {
        id: 'shp_13944500',
        carrier: { name: 'Mixed', service: 'Mixed' },
        fulfillmentLocation: { countryCode: 'GB', labCode: 'prodigi_gb2' },
        tracking: { number: 'LS948241359CH', url: null },
        dispatchDate: '2026-08-24T13:53:00Z',
      },
    ],
  },
}

/** Livre expédié des Pays-Bas, sans objet `tracking.url` — shp_13931052. */
const shippedFromNl = {
  order: {
    id: '14417088',
    status: {
      stage: 'Complete',
      issues: [],
      details: {
        downloadAssets: 'Complete',
        printReadyAssetsPrepared: 'Complete',
        allocateProductionLocation: 'Complete',
        inProduction: 'Complete',
        shipping: 'Complete',
      },
    },
    shipments: [
      {
        id: 'shp_13931052',
        carrier: { name: 'Mixed', service: 'Mixed' },
        fulfillmentLocation: { countryCode: 'NL', labCode: 'prodigi_nl1' },
        tracking: { number: '996016194900018910' },
        dispatchDate: '2026-08-24T12:52:00Z',
      },
    ],
  },
}

test('une commande expédiée n’est plus bloquée sur « pending »', () => {
  // Régression : l'ancien parsing cherchait `shipment.status`, un champ que
  // l'API Prodigi ne renvoie pas — le statut restait donc « pending » à vie.
  const gb = parseProdigiOrder(shippedFromGb, true, 200, '', 'CH')
  assert.equal(gb.prodigiStatus, 'shipped')

  const nl = parseProdigiOrder(shippedFromNl, true, 200, '', 'CH')
  assert.equal(nl.prodigiStatus, 'shipped')
})

test('le suivi, le transporteur et le pays de départ sont extraits', () => {
  const [parcel] = parseProdigiShipments(shippedFromGb.order, 'CH')
  assert.equal(parcel.id, 'shp_13944500')
  assert.equal(parcel.trackingNumber, 'LS948241359CH')
  assert.equal(parcel.carrier, 'Mixed')
  assert.equal(parcel.fromCountry, 'GB')
  assert.equal(parcel.dispatchedAt, '2026-08-24T13:53:00Z')
})

test('un lien de suivi est construit quand Prodigi n’en fournit pas', () => {
  // `tracking.url` vaut null (GB) ou est absent (NL) : sans repli, le numéro
  // ne serait pas cliquable pour le client.
  const [gb] = parseProdigiShipments(shippedFromGb.order, 'CH')
  const [nl] = parseProdigiShipments(shippedFromNl.order, 'CH')
  assert.match(gb.trackingUrl ?? '', /post\.ch.*LS948241359CH/)
  assert.match(nl.trackingUrl ?? '', /post\.ch.*996016194900018910/)
})

test('une URL de suivi fournie par Prodigi est préférée à la nôtre', () => {
  const order = {
    shipments: [{ tracking: { number: 'X1', url: 'https://carrier.example/X1' } }],
  }
  assert.equal(parseProdigiShipments(order, 'CH')[0].trackingUrl, 'https://carrier.example/X1')
})

test('pas de numéro de suivi = pas de lien inventé', () => {
  assert.equal(resolveTrackingUrl(null, 'CH'), null)
})

test('une commande en fabrication n’est pas annoncée comme expédiée', () => {
  const inProduction = {
    order: {
      status: {
        stage: 'InProgress',
        issues: [],
        details: { downloadAssets: 'Complete', inProduction: 'InProgress', shipping: 'NotStarted' },
      },
      shipments: [],
    },
  }
  assert.equal(parseProdigiOrder(inProduction, true, 200, '').prodigiStatus, 'inProduction')
})

test('une commande tout juste envoyée reste « pending »', () => {
  const fresh = {
    order: {
      status: {
        stage: 'InProgress',
        issues: [],
        details: { downloadAssets: 'InProgress', inProduction: 'NotStarted' },
      },
      shipments: [],
    },
  }
  assert.equal(parseProdigiOrder(fresh, true, 200, '').prodigiStatus, 'pending')
})

test('un problème signalé par Prodigi devient une erreur lisible', () => {
  const withIssue = {
    order: {
      status: { stage: 'InProgress', issues: [{ description: 'Asset download failed' }], details: {} },
    },
  }
  const parsed = parseProdigiOrder(withIssue, true, 200, '')
  assert.equal(parsed.prodigiStatus, 'error')
  assert.equal(parsed.refusalReason, 'Asset download failed')
})

test('une commande annulée chez Prodigi est traitée comme une erreur', () => {
  const cancelled = { order: { status: { stage: 'Cancelled', issues: [], details: {} } } }
  const parsed = parseProdigiOrder(cancelled, true, 200, '')
  assert.equal(parsed.prodigiStatus, 'error')
  assert.equal(parsed.refusalReason, 'Commande annulée chez Prodigi')
})

test('une réponse HTTP en échec ne peut pas passer pour un succès', () => {
  const parsed = parseProdigiOrder(null, false, 404, 'Not found')
  assert.equal(parsed.prodigiStatus, 'error')
  assert.equal(parsed.refusalReason, 'HTTP 404')
})

test('les montants réellement facturés sont ventilés', () => {
  const charges = parseProdigiCharges(shippedFromGb.order)
  assert.equal(charges?.currency, 'USD')
  assert.equal(charges?.total, 42.19)
  assert.equal(charges?.items, 24.52)
  assert.equal(charges?.shipping, 17.67)
})

test('sans bloc de charges, on ne fabrique pas de montant', () => {
  assert.equal(parseProdigiCharges(shippedFromNl.order), null)
})
