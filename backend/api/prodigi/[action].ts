import type { VercelRequest, VercelResponse } from '@vercel/node'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { ADMIN_EMAIL } from '../../lib/resend'
import { refreshProdigiOrderStatus, notifyAdminOfError, PRODIGI_API_URL } from '../../lib/prodigi'
import { computePrice, printablePages, type CoverType } from '../../lib/pricing'
import {
  posterCatalogEntry,
  computePosterPrice,
  isPosterSize,
  isPosterOrientation,
  isPosterHangerColor,
  type PosterSize,
  type PosterOrientation,
} from '../../lib/poster_pricing'

// Route dynamique regroupant les endpoints Prodigi en UNE seule fonction
// serverless (le plan Hobby de Vercel plafonne à 12 fonctions). URLs :
//   POST /api/prodigi/order  → envoie une commande payée à l'impression
//                               (admin uniquement, en un seul appel — pas de
//                               brouillon/confirmation comme chez Gelato,
//                               création directe en un POST /v4.0/orders)
//   POST /api/prodigi/status → relit le statut réel d'une commande
//   GET  /api/prodigi/poll   → balaie les commandes en attente (cron only)
//   POST /api/prodigi/quote  → vérifie pages/prix contre un vrai devis Prodigi
//                               (admin, gratuit, ne modifie rien)
//
// Pas d'endpoint de calcul de tranche de couverture : confirmé le 06.08.26
// (doc technique Prodigi) qu'un seul PDF plat suffit — page 1 = couverture,
// dernière page = dos, pas de spread wraparound, Prodigi calcule et ajoute la
// tranche automatiquement selon le nombre de pages. Contrairement à Gelato,
// aucun appel réseau n'est nécessaire avant de générer le PDF final.
//
// ⚠️ PRODIGI_API_URL par défaut = sandbox (ne facture/fabrique rien). La clé
// obtenue le 06.08.26 est une clé LIVE (vérifié : 401 sur l'URL sandbox, 200
// sur l'URL prod) — il faut donc définir explicitement
// PRODIGI_API_URL=https://api.prodigi.com/v4.0 dans les env Vercel pour que
// les appels passent, sachant qu'à partir de là toute commande réelle sera
// facturée et fabriquée pour de vrai. (Constante définie une seule fois dans
// lib/prodigi.ts, importée ici pour ne jamais diverger entre les deux fichiers.)

function countryToIso(c: string): string {
  const map: Record<string, string> = {
    suisse: 'CH', switzerland: 'CH', schweiz: 'CH', svizzera: 'CH',
    france: 'FR', belgique: 'BE', belgium: 'BE',
    allemagne: 'DE', germany: 'DE', deutschland: 'DE',
    luxembourg: 'LU', italie: 'IT', italy: 'IT', italia: 'IT',
    espagne: 'ES', spain: 'ES',
  }
  const key = (c ?? '').trim().toLowerCase()
  if (map[key]) return map[key]
  if (/^[a-z]{2}$/i.test(key)) return key.toUpperCase()
  return 'CH'
}

// SKU à définir dans les env Vercel (PRODIGI_SKU_SOFT / PRODIGI_SKU_HARD /
// PRODIGI_SKU_LAYFLAT). Confirmé le 06.08.26 (fiches produit Prodigi, A4
// portrait, 21×29.7cm = vrai ISO A4) :
// - Soft : `BOOK-FE-A4-P-SOFT-MHK` (mat 120gsm, dès $10.98/20p, expédié DE)
//   ou `BOOK-FE-A4-P-SOFT-G` (gloss 150gsm, moins cher, $8.50 annoncé) —
//   20-300 pages.
// - Hard : `BOOK-FE-A4-P-HARD-G` (gloss 200gsm + finition mate, dès
//   $13.58/24p, expédié NL) — 24-300 pages (500 en 150gsm gloss only).
// - Layflat : `BOOK-FE-A4-P-LF-G` (confirmé sur le catalogue Prodigi le
//   18.08.26, même trim A4 portrait que soft/hard, dès $28.50/18p, fabriqué
//   EU) — 18-122 pages, reliure qui s'ouvre à plat (pas de gouttière au
//   centre des doubles pages).
// Livraison CH confirmée sur soft/hard (via simulateur prix Prodigi),
// méthodes Budget/Standard seules disponibles pour CH (même prix) —
// StandardPlus/Express/Overnight indisponibles. Frais de douane à la charge
// du destinataire (non inclus dans le prix Prodigi, TVA import CH ~8.1% à
// prévoir séparément) — à mentionner au client si pas déjà fait ailleurs.
const SKU_ENV_NAME: Record<CoverType, string> = {
  soft: 'PRODIGI_SKU_SOFT',
  hard: 'PRODIGI_SKU_HARD',
  layflat: 'PRODIGI_SKU_LAYFLAT',
}
function skuFor(coverType: CoverType): { sku?: string; envName: string } {
  const envName = SKU_ENV_NAME[coverType]
  return { sku: process.env[envName], envName }
}

// Forme confirmée en sandbox le 06.08.26 pour un rejet SYNCHRONE (400) de
// POST /v4.0/orders ou /v4.0/quotes : `{"outcome":"ValidationFailed",
// "failures":{"items[0].sku":[{"code":"SkuNotFound","providedValue":"..."}]}}`
// — pas de champ `error.message` comme initialement supposé.
function formatProdigiFailures(data: any, raw: string): string {
  const failures = data?.failures
  if (failures && typeof failures === 'object') {
    const parts = Object.entries(failures).map(([field, arr]) => {
      const codes = Array.isArray(arr)
        ? arr.map((f: any) => f?.code ?? JSON.stringify(f)).join(', ')
        : String(arr)
      return `${field}: ${codes}`
    })
    if (parts.length) return parts.join(' · ')
  }
  return (data?.error?.message ?? raw ?? '').toString()
}

// Envoie une commande Firestore déjà payée à l'impression chez Prodigi, ou la
// renvoie après une erreur (admin uniquement — pas de flux self-service côté
// client). Sur un renvoi, l'admin peut avoir régénéré le livre (voir
// book_generate_screen.dart en mode édition) : `pdfUrl`/`pageCount` dans le
// body écrasent alors ceux déjà sur la commande. Plafonné à 3 renvois après
// erreur (`prodigiRetryCount`), compté même sur un nouvel échec — évite une
// boucle infinie de tentatives contre un problème qui ne se résout pas tout
// seul. Garde-fou explicite : commande refusée si `status !== 'paid'`, pour
// qu'aucun livre ne parte à l'impression avant confirmation du paiement (le
// paiement se fait hors app — voir order_model.dart).
async function handleOrder(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return
  if (user.email !== ADMIN_EMAIL) {
    return res.status(403).json({ error: 'Accès refusé' })
  }

  const apiKey = process.env.PRODIGI_API_KEY
  if (!apiKey) {
    return res
      .status(503)
      .json({ error: 'Prodigi non configuré (PRODIGI_API_KEY manquante)' })
  }

  const {
    orderId,
    pdfUrl: overridePdfUrl,
    pageCount: overridePageCount,
  } = (req.body ?? {}) as { orderId?: string; pdfUrl?: string; pageCount?: number }
  if (!orderId || typeof orderId !== 'string') {
    return res.status(400).json({ error: 'Missing orderId' })
  }

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return res.status(404).json({ error: 'Order not found' })
  const o = snap.data() as Record<string, any>

  if (o.status !== 'paid') {
    return res.status(409).json({
      error: 'Commande non marquée « payée » — impossible de l’envoyer à l’impression.',
    })
  }

  const isRetry = Boolean(o.prodigiOrderId)
  if (isRetry) {
    if (o.prodigiStatus !== 'error') {
      return res.status(409).json({ error: 'Cette commande a déjà été envoyée à Prodigi.' })
    }
    const retryCount = Number(o.prodigiRetryCount ?? 0)
    if (retryCount >= 3) {
      return res
        .status(409)
        .json({ error: 'Nombre maximum de renvois atteint (3) — contacte le support Prodigi si besoin.' })
    }
  }

  const pdfUrl: string | undefined =
    typeof overridePdfUrl === 'string' && overridePdfUrl ? overridePdfUrl : o.pdfUrl
  const pageCount: number | undefined =
    typeof overridePageCount === 'number' && overridePageCount > 0
      ? overridePageCount
      : o.pageCount
  if (!pdfUrl) {
    return res.status(400).json({ error: 'Commande sans PDF (pdfUrl manquant)' })
  }

  const isPoster = o.productType === 'poster'

  // Prix de référence recalculé côté serveur — order.price vient du client à
  // la création (écrit direct dans Firestore, jamais passé par un backend qui
  // pourrait le corriger) et ne doit jamais être facturé/affiché tel quel.
  // Découvert le 21.08.26 : une vraie commande poster A1 a été facturée
  // $44.95 par Prodigi (article + livraison) alors que order.price valait
  // CHF 30 — la table de prix poster ne comptait pas la livraison à ce
  // moment-là (corrigé dans poster_pricing.ts). Ce garde-fou empêche qu'un
  // futur écart de prix (app pas à jour, table de prix qui dérive à nouveau)
  // reste invisible dans la console admin/les emails.
  let trustedPrice: number | null = null

  let item: Record<string, any>
  if (isPoster) {
    if (!isPosterSize(o.posterSize) || !isPosterOrientation(o.posterOrientation)) {
      return res.status(400).json({ error: 'posterSize/posterOrientation invalide sur la commande' })
    }
    const entry = posterCatalogEntry(o.posterSize, o.posterOrientation)
    if (!entry) {
      return res.status(400).json({ error: `Aucun SKU poster pour ${o.posterSize}/${o.posterOrientation}` })
    }
    const color = isPosterHangerColor(o.posterHangerColor) ? o.posterHangerColor : 'natural'
    item = {
      sku: entry.sku,
      copies: 1,
      sizing: 'fillPrintArea',
      attributes: { color },
      assets: [{ printArea: 'default', url: pdfUrl }],
    }
    trustedPrice = computePosterPrice(o.posterSize, o.posterOrientation)
  } else {
    const orderCoverType: CoverType =
      o.coverType === 'hard' || o.coverType === 'layflat' ? o.coverType : 'soft'
    const { sku, envName } = skuFor(orderCoverType)
    if (!sku) {
      return res.status(503).json({ error: `SKU Prodigi manquant (env ${envName})` })
    }
    item = {
      sku,
      copies: 1,
      sizing: 'fillPrintArea',
      assets: [{ printArea: 'default', url: pdfUrl, pageCount }],
    }
    trustedPrice = pageCount ? computePrice(orderCoverType, pageCount) : null
  }

  const payload = {
    merchantReference: orderId,
    shippingMethod: 'Standard',
    recipient: {
      name: `${o.firstName ?? ''} ${o.lastName ?? ''}`.trim(),
      address: {
        line1: String(o.street ?? ''),
        postalOrZipCode: String(o.npa ?? ''),
        countryCode: countryToIso(String(o.country ?? 'Suisse')),
        townOrCity: String(o.city ?? ''),
      },
    },
    items: [item],
  }

  // Champs communs mis à jour dans Firestore quel que soit le résultat de
  // l'appel Prodigi ci-dessous : le PDF régénéré (si fourni) et le compteur
  // de tentatives (uniquement sur un vrai renvoi, pas le premier envoi).
  const commonUpdate: Record<string, any> = { updatedAt: FieldValue.serverTimestamp() }
  if (typeof overridePdfUrl === 'string' && overridePdfUrl) commonUpdate.pdfUrl = overridePdfUrl
  if (typeof overridePageCount === 'number' && overridePageCount > 0) {
    commonUpdate.pageCount = overridePageCount
  }
  if (trustedPrice != null && Math.abs(Number(o.price ?? 0) - trustedPrice) > 0.001) {
    commonUpdate.price = trustedPrice
  }
  if (isRetry) commonUpdate.prodigiRetryCount = Number(o.prodigiRetryCount ?? 0) + 1

  try {
    const prodigiRes = await fetch(`${PRODIGI_API_URL}/orders`, {
      method: 'POST',
      headers: { 'X-API-Key': apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    const raw = await prodigiRes.text()
    let data: any = null
    try {
      data = JSON.parse(raw)
    } catch {
      /* réponse non-JSON — on garde raw */
    }

    if (!prodigiRes.ok) {
      const detail = formatProdigiFailures(data, raw).slice(0, 500)
      await ref.update({ ...commonUpdate, prodigiStatus: 'error', prodigiError: detail })
      return res.status(502).json({ error: 'Prodigi a refusé la commande', detail })
    }

    const prodigiOrderId = data?.id ?? data?.order?.id ?? null

    await ref.update({
      ...commonUpdate,
      prodigiOrderId,
      prodigiStatus: 'pending',
      prodigiError: null,
    })

    return res.status(200).json({ ok: true, prodigiOrderId })
  } catch (e) {
    await ref.update({ ...commonUpdate, prodigiStatus: 'error', prodigiError: String(e).slice(0, 500) })
    return res.status(502).json({ error: `Appel Prodigi échoué : ${e}` })
  }
}

// Vérifie NOTRE nombre de pages / prix contre un vrai devis Prodigi
// (POST /v4.0/quotes — gratuit, ne facture/fabrique rien). Sert à confirmer,
// avant d'envoyer une commande réelle à l'impression, que book_pricing.dart
// (formule calibrée le 06.08.26 sur 2 devis ponctuels) n'a pas divergé du
// tarif Prodigi actuel. Admin uniquement (même si un devis est gratuit, ça
// reste un appel direct à la clé live). Ne modifie rien en base.
async function handleQuote(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return
  if (user.email !== ADMIN_EMAIL) {
    return res.status(403).json({ error: 'Accès refusé' })
  }

  const apiKey = process.env.PRODIGI_API_KEY
  if (!apiKey) {
    return res
      .status(503)
      .json({ error: 'Prodigi non configuré (PRODIGI_API_KEY manquante)' })
  }

  const {
    productType,
    coverType,
    pageCount,
    country,
    shippingMethod,
    posterSize,
    posterOrientation,
  } = (req.body ?? {}) as {
    productType?: string
    coverType?: string
    pageCount?: number
    country?: string
    shippingMethod?: string
    posterSize?: string
    posterOrientation?: string
  }

  const isPoster = productType === 'poster'
  let sku: string | undefined
  let localPrintedPages: number | undefined
  let localPriceChf: number | null = null

  if (isPoster) {
    if (!isPosterSize(posterSize) || !isPosterOrientation(posterOrientation)) {
      return res.status(400).json({ error: 'posterSize/posterOrientation invalide' })
    }
    const entry = posterCatalogEntry(posterSize as PosterSize, posterOrientation as PosterOrientation)
    if (!entry) {
      return res.status(400).json({ error: `Aucun SKU poster pour ${posterSize}/${posterOrientation}` })
    }
    sku = entry.sku
    localPriceChf = computePosterPrice(posterSize as PosterSize, posterOrientation as PosterOrientation)
  } else {
    if (coverType !== 'soft' && coverType !== 'hard' && coverType !== 'layflat') {
      return res.status(400).json({ error: 'coverType doit être "soft", "hard" ou "layflat"' })
    }
    if (!Number.isFinite(pageCount) || (pageCount as number) <= 0) {
      return res.status(400).json({ error: 'pageCount invalide' })
    }
    const resolved = skuFor(coverType)
    if (!resolved.sku) {
      return res.status(503).json({ error: `SKU Prodigi manquant (env ${resolved.envName})` })
    }
    sku = resolved.sku
    // Même règle de pagination que pour une vraie commande (pair, bornes
    // produit) — c'est CE nombre-là, pas le brut, qui sera facturé/imprimé.
    localPrintedPages = printablePages(coverType as CoverType, pageCount as number)
    localPriceChf = computePrice(coverType as CoverType, pageCount as number)
  }

  const payload = {
    // Comparaison de méthode d'envoi (débogage prix admin) — 'Standard' par
    // défaut, override possible via le body pour comparer avec 'Budget'.
    shippingMethod: shippingMethod ?? 'Standard',
    destinationCountryCode: countryToIso(country ?? 'Suisse'),
    // USD pour comparer directement aux constantes calibrées dans
    // lib/pricing.ts (elles-mêmes en USD) — la conversion CHF est ensuite
    // faite localement des deux côtés avec le même taux, donc un écart révèle
    // un vrai changement de tarif Prodigi, pas juste le taux de change.
    currencyCode: 'USD',
    items: [
      isPoster
        ? { sku, copies: 1, assets: [{ printArea: 'default' }] }
        : { sku, copies: 1, assets: [{ printArea: 'default', pageCount: localPrintedPages }] },
    ],
  }

  try {
    const prodigiRes = await fetch(`${PRODIGI_API_URL}/quotes`, {
      method: 'POST',
      headers: { 'X-API-Key': apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    const raw = await prodigiRes.text()
    let data: any = null
    try {
      data = JSON.parse(raw)
    } catch {
      /* réponse non-JSON — on garde raw pour diagnostic */
    }

    if (!prodigiRes.ok) {
      return res.status(502).json({
        error: 'Devis Prodigi refusé',
        detail: formatProdigiFailures(data, raw).slice(0, 500),
      })
    }

    // Forme de réponse non confirmée aussi précisément que pour /orders
    // (jamais parsée en code avant ce jour, seulement lue à la main le
    // 06.08.26) — parsing défensif, plusieurs noms de champ possibles, et on
    // renvoie toujours le JSON brut pour vérification humaine en cas de doute.
    const quote = data?.quotes?.[0] ?? data?.quote ?? null
    const itemsUsd = Number(
      quote?.costSummary?.items?.amount ?? quote?.costSummary?.items ?? NaN
    )
    const shippingUsd = Number(
      quote?.costSummary?.shipping?.amount ?? quote?.costSummary?.shipping ?? NaN
    )
    const taxUsd = Number(
      quote?.costSummary?.tax?.amount ?? quote?.costSummary?.totalTax?.amount ?? 0
    )
    const prodigiCostUsd =
      Number.isFinite(itemsUsd) && Number.isFinite(shippingUsd)
        ? itemsUsd + shippingUsd + (Number.isFinite(taxUsd) ? taxUsd : 0)
        : null

    return res.status(200).json({
      ok: true,
      localPrintedPages,
      localPriceChf,
      prodigiCostUsd,
      prodigiRaw: data ?? raw.slice(0, 2000),
    })
  } catch (e) {
    return res.status(502).json({ error: `Appel Prodigi échoué : ${e}` })
  }
}

// Relit le statut réel d'une commande chez Prodigi (admin, ou le propriétaire
// pour suivre sa propre commande).
async function handleStatus(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const { orderId } = (req.body ?? {}) as { orderId?: string }
  if (!orderId || typeof orderId !== 'string') {
    return res.status(400).json({ error: 'Missing orderId' })
  }

  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Order not found' })
  const o = snap.data() as Record<string, any>

  if (user.email !== ADMIN_EMAIL && user.uid !== o.userId) {
    return res.status(403).json({ error: 'Accès refusé' })
  }

  const { newlyErrored } = await refreshProdigiOrderStatus(orderId)
  if (newlyErrored) {
    await notifyAdminOfError(orderId)
  }

  const fresh = (await db.collection('orders').doc(orderId).get()).data()
  return res.status(200).json({
    ok: true,
    prodigiStatus: fresh?.prodigiStatus ?? null,
    prodigiError: fresh?.prodigiError ?? null,
  })
}

// Cron quotidien (voir vercel.json) : balaie les commandes en cours chez
// Prodigi et rafraîchit chacune. Protégé par CRON_SECRET.
async function handlePoll(req: VercelRequest, res: VercelResponse) {
  const secret = process.env.CRON_SECRET
  const auth = req.headers.authorization ?? ''
  if (!secret || auth !== `Bearer ${secret}`) {
    return res.status(401).json({ error: 'Unauthorized' })
  }

  const snap = await db.collection('orders').where('prodigiStatus', '==', 'pending').get()

  let checked = 0
  let errored = 0
  for (const d of snap.docs) {
    try {
      const { newlyErrored } = await refreshProdigiOrderStatus(d.id)
      checked++
      if (newlyErrored) {
        errored++
        await notifyAdminOfError(d.id)
      }
    } catch (e) {
      console.error('[prodigi/poll] order', d.id, e)
    }
  }

  return res.status(200).json({ ok: true, checked, errored })
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'order') return handleOrder(req, res)
  if (action === 'status') return handleStatus(req, res)
  if (action === 'poll') return handlePoll(req, res)
  if (action === 'quote') return handleQuote(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
