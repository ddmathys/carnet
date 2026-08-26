// Traduction des réponses de l'API Prodigi (`GET /v4.0/orders/{id}`) en
// données exploitables : statut d'impression, colis, numéros de suivi, coûts
// facturés.
//
// Module volontairement PUR — aucun import de Firestore, de Resend ni de
// `process.env` : c'est ce qui permet de le tester directement
// (`node --test backend/lib/prodigi_parse.test.ts`) sans credentials Firebase.
// Les effets de bord (lecture/écriture Firestore, emails) vivent dans
// `prodigi.ts`, qui réexporte tout ce fichier.

// Statut d'impression stocké sur la commande Firestore.
//   pending      — envoyée, Prodigi prépare (téléchargement du PDF, atelier)
//   inProduction — en fabrication
//   shipped      — au moins un colis parti (date d'expédition et/ou tracking)
//   error        — refusée, annulée, ou échec technique
// ⚠️ `accepted` est une valeur HISTORIQUE, écrite par la version précédente de
// ce fichier qui confondait « en production » et « expédiée ». Elle n'est plus
// jamais écrite, mais reste lue partout (requête du cron ci-dessous, modèle
// Dart) tant que d'anciennes commandes la portent en base.
export type ProdigiStatus = 'error' | 'shipped' | 'inProduction' | 'pending'

/** Statuts non terminaux : ceux que le cron doit continuer à relire. */
export const PRODIGI_OPEN_STATUSES = ['pending', 'inProduction', 'accepted'] as const

export type ProdigiShipment = {
  id: string | null
  carrier: string | null
  service: string | null
  trackingNumber: string | null
  trackingUrl: string | null
  /** ISO 8601, tel que renvoyé par Prodigi. */
  dispatchedAt: string | null
  /** Pays de l'atelier d'où part le colis (ISO 2 lettres) — « from United Kingdom ». */
  fromCountry: string | null
}

export type ProdigiCharges = {
  currency: string | null
  items: number | null
  shipping: number | null
  tax: number | null
  total: number | null
}

export type ProdigiOrderSnapshot = {
  prodigiStatus: ProdigiStatus
  /** `order.status.stage` brut ("InProgress" | "Complete" | "Cancelled"). */
  stage: string | null
  /** `order.status.details` brut : downloadAssets, inProduction, shipping… */
  stageDetails: Record<string, string>
  refusalReason: string | null
  shipments: ProdigiShipment[]
  charges: ProdigiCharges | null
  raw: string
}

const num = (v: unknown): number | null => {
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

const str = (v: unknown): string | null =>
  typeof v === 'string' && v.trim() !== '' ? v.trim() : null

/**
 * Construit un lien de suivi quand Prodigi n'en fournit pas.
 *
 * Prodigi renvoie `tracking.url` la plupart du temps, mais pas toujours (vu le
 * 24.08.26 sur deux vraies commandes : transporteur « Mixed », numéro fourni
 * sans URL) — sans lien, le numéro seul n'est pas actionnable pour le client.
 * Les deux numéros observés (`LS948241359CH` depuis le Royaume-Uni,
 * `996016194900018910` depuis les Pays-Bas) se suivent tous les deux chez La
 * Poste Suisse, qui assure la livraison finale en CH quel que soit le pays de
 * départ. On route donc vers La Poste dès que la destination est la Suisse,
 * et vers un agrégateur multi-transporteurs sinon.
 */
export function resolveTrackingUrl(
  trackingNumber: string | null,
  destinationCountry: string | null
): string | null {
  if (!trackingNumber) return null
  const n = encodeURIComponent(trackingNumber)
  if ((destinationCountry ?? '').toUpperCase() === 'CH') {
    return `https://service.post.ch/ekp-web/ui/entry/search/${n}`
  }
  return `https://www.17track.net/en/track?nums=${n}`
}

/**
 * Extrait les colis d'une réponse `GET /v4.0/orders/{id}`.
 *
 * ⚠️ Un `shipment` Prodigi n'a PAS de champ `status` — c'est l'erreur qui
 * gardait les commandes bloquées sur « pending » indéfiniment : l'ancienne
 * version testait `/shipped|dispatch/i.test(s.status)` sur un champ toujours
 * `undefined`. Le vrai signal d'expédition est la présence de `dispatchDate`
 * (et/ou d'un numéro de suivi). On garde quand même une lecture défensive de
 * `status` au cas où Prodigi en ajouterait un.
 */
export function parseProdigiShipments(
  order: any,
  destinationCountry: string | null = null
): ProdigiShipment[] {
  const raw: any[] = Array.isArray(order?.shipments) ? order.shipments : []
  return raw.map((s) => {
    const trackingNumber = str(s?.tracking?.number) ?? str(s?.trackingNumber)
    return {
      id: str(s?.id),
      carrier: str(s?.carrier?.name) ?? str(s?.carrier),
      service: str(s?.carrier?.service),
      trackingNumber,
      trackingUrl:
        str(s?.tracking?.url) ?? resolveTrackingUrl(trackingNumber, destinationCountry),
      dispatchedAt: str(s?.dispatchDate) ?? str(s?.dispatchedAt) ?? str(s?.shippedAt),
      fromCountry:
        str(s?.fulfillmentLocation?.countryCode) ?? str(s?.fulfilmentLocation?.countryCode),
    }
  })
}

/** Un colis compte comme parti dès qu'il a une date d'expédition ou un tracking. */
export function isShipmentDispatched(s: ProdigiShipment): boolean {
  return Boolean(s.dispatchedAt) || Boolean(s.trackingNumber)
}

/**
 * Coûts réellement facturés par Prodigi (`order.charges`), pour comparer au
 * prix affiché au client. Ce garde-fou existe parce qu'un vrai poster A1 a
 * été facturé $44.95 alors que la commande affichait CHF 30 (voir
 * backend/api/prodigi/[action].ts) : sans le montant facturé en base, l'écart
 * reste invisible.
 *
 * Forme observée : `charges: [{ totalCost: { amount, currency },
 * items: [{ description, itemSku, cost: { amount, currency } }] }]`. La
 * ventilation article/livraison n'est pas garantie — on ne remplit `items` et
 * `shipping` que si la classification est certaine, `total` reste la valeur
 * fiable.
 */
export function parseProdigiCharges(order: any): ProdigiCharges | null {
  const charges: any[] = Array.isArray(order?.charges) ? order.charges : []
  if (charges.length === 0) return null

  let currency: string | null = null
  let total = 0
  let itemsCost = 0
  let shippingCost = 0
  let taxCost = 0
  let classified = false
  let sawTotal = false

  for (const c of charges) {
    const t = num(c?.totalCost?.amount)
    if (t != null) {
      total += t
      sawTotal = true
    }
    currency ??= str(c?.totalCost?.currency)
    const lines: any[] = Array.isArray(c?.items) ? c.items : []
    for (const line of lines) {
      const amount = num(line?.cost?.amount)
      if (amount == null) continue
      currency ??= str(line?.cost?.currency)
      const label = `${line?.description ?? ''} ${line?.itemSku ?? ''}`.toLowerCase()
      if (/ship|deliver|postage/.test(label)) {
        shippingCost += amount
        classified = true
      } else if (/tax|vat|duty/.test(label)) {
        taxCost += amount
        classified = true
      } else {
        itemsCost += amount
      }
    }
  }

  return {
    currency,
    items: classified ? itemsCost : null,
    shipping: classified ? shippingCost : null,
    tax: classified ? taxCost : null,
    total: sawTotal ? total : null,
  }
}

/**
 * Traduit une réponse `GET /v4.0/orders/{id}` en statut exploitable.
 * Fonction pure (pas de réseau, pas de Firestore) — c'est elle qu'on teste.
 *
 * Étapes `status.details`, chacune NotStarted|InProgress|Complete :
 * downloadAssets → printReadyAssetsPrepared → allocateProductionLocation →
 * inProduction → shipping. `status.stage` vaut InProgress, Complete ou
 * Cancelled.
 */
export function parseProdigiOrder(
  data: any,
  httpOk: boolean,
  httpStatus: number,
  raw: string,
  destinationCountry: string | null = null
): ProdigiOrderSnapshot {
  const order = data?.order
  const issues: any[] = Array.isArray(order?.status?.issues) ? order.status.issues : []
  const stage = str(order?.status?.stage)
  const rawDetails = order?.status?.details ?? {}
  const stageDetails: Record<string, string> = {}
  for (const [k, v] of Object.entries(rawDetails)) {
    if (typeof v === 'string') stageDetails[k] = v
  }

  const shipments = parseProdigiShipments(order, destinationCountry)
  const charges = parseProdigiCharges(order)

  const dispatched = shipments.some(isShipmentDispatched)
  const shippingDone = /complete/i.test(stageDetails.shipping ?? '')
  const stageComplete = /complete/i.test(stage ?? '')
  const inProduction = /inprogress|complete/i.test(stageDetails.inProduction ?? '')

  let prodigiStatus: ProdigiStatus
  let refusalReason: string | null = null

  if (!httpOk) {
    prodigiStatus = 'error'
    refusalReason =
      data?.error?.message ?? data?.errors?.[0]?.message ?? `HTTP ${httpStatus}`
  } else if (issues.length > 0) {
    prodigiStatus = 'error'
    refusalReason = issues
      .map((i) => i?.description ?? i?.reason ?? i?.errorCode ?? JSON.stringify(i))
      .join(' · ')
  } else if (/cancel/i.test(stage ?? '')) {
    prodigiStatus = 'error'
    refusalReason = 'Commande annulée chez Prodigi'
  } else if (dispatched || shippingDone || stageComplete) {
    // Prodigi ne passe l'ordre en `Complete` qu'une fois tout expédié : pas de
    // colis listé mais stage Complete = expédié sans tracking remonté.
    prodigiStatus = 'shipped'
  } else if (inProduction) {
    prodigiStatus = 'inProduction'
  } else {
    prodigiStatus = 'pending'
  }

  return { prodigiStatus, stage, stageDetails, refusalReason, shipments, charges, raw }
}
