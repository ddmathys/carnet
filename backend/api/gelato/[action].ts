import type { VercelRequest, VercelResponse } from '@vercel/node'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { ADMIN_EMAIL } from '../../lib/resend'
import { HttpError, refreshGelatoOrderStatus, notifyClientOfRefusal } from '../../lib/gelato'

// Route dynamique regroupant les endpoints Gelato en UNE seule fonction
// serverless (le plan Hobby de Vercel plafonne à 12 fonctions). Les URLs
// publiques restent identiques :
//   POST /api/gelato/order            → crée/renvoie la commande chez Gelato
//                                        (admin, ou client pour un renvoi
//                                        après refus — cf. handleOrder)
//   POST /api/gelato/cover-dimensions → dimensions exactes du gabarit
//                                        couverture (wraparound) pour un
//                                        coverType + pageCount donnés
//   POST /api/gelato/status           → relit le VRAI statut d'une commande
//                                        chez Gelato (admin ou propriétaire)
//   GET  /api/gelato/poll             → balaie les commandes en attente et
//                                        rafraîchit leur statut (cron only)
const GELATO_ORDER_URL = 'https://order.gelatoapis.com/v4/orders'
const GELATO_PRODUCT_URL = 'https://product.gelatoapis.com/v3/products'

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

function productUidFor(coverType: string): { productUid?: string; isHard: boolean } {
  const isHard = coverType === 'hard'
  const productUid = isHard
    ? process.env.GELATO_PRODUCT_UID_HARD
    : process.env.GELATO_PRODUCT_UID_SOFT
  return { productUid, isHard }
}

// Crée ou renvoie une commande Gelato à partir d'une commande Firestore.
//
// Deux façons de l'appeler :
// - ADMIN, { orderType: "draft" } (défaut) : brouillon chez Gelato, à
//   revoir/confirmer dans LEUR dashboard — inchangé depuis toujours, c'est le
//   seul vrai garde-fou humain sur un livre jamais encore validé.
// - Propriétaire de la commande (client) OU admin, { orderType: "order",
//   pdfUrl, pageCount } : renvoi DIRECT en production, sans passer par un
//   brouillon — seule façon d'obtenir un vrai résultat de validation
//   prépresse (un brouillon ne le déclenche jamais, voir lib/gelato.ts).
//   Réservé au cas où la commande vient d'être refusée
//   (`gelatoStatus === 'refused'`), plafonné à 3 renvois côté client, et
//   l'écart de pages avec ce qui a déjà été facturé est limité à ±3 pour ne
//   pas devoir réajuster le prix. Un verrou transactionnel Firestore empêche
//   deux commandes réelles de partir en même temps pour le même livre (ex. le
//   client renvoie pendant que l'admin confirme un brouillon dans le
//   dashboard Gelato).
async function handleOrder(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const apiKey = process.env.GELATO_API_KEY
  if (!apiKey) {
    return res
      .status(503)
      .json({ error: 'Gelato non configuré (GELATO_API_KEY manquante)' })
  }

  const { orderId, orderType, pdfUrl: overridePdfUrl, pageCount: overridePageCount } =
    (req.body ?? {}) as {
      orderId?: string
      orderType?: string
      pdfUrl?: string
      pageCount?: number
    }
  if (!orderId || typeof orderId !== 'string') {
    return res.status(400).json({ error: 'Missing orderId' })
  }
  const type = orderType === 'order' ? 'order' : 'draft'

  const ref = db.collection('orders').doc(orderId)
  const snap0 = await ref.get()
  if (!snap0.exists) return res.status(404).json({ error: 'Order not found' })
  const o0 = snap0.data() as Record<string, any>

  const isAdmin = user.email === ADMIN_EMAIL
  const isOwner = user.uid === o0.userId
  if (!isAdmin && !isOwner) {
    return res.status(403).json({ error: 'Accès refusé' })
  }

  if (!isAdmin) {
    // Le client ne peut jamais créer de brouillon (ça resterait invisible
    // pour lui, seul le renvoi direct a un intérêt ici) ni agir sur une
    // commande d'un autre utilisateur.
    if (type !== 'order') {
      return res
        .status(403)
        .json({ error: 'Seul un renvoi direct en production est autorisé.' })
    }
    if (typeof overridePdfUrl !== 'string' || !overridePdfUrl) {
      return res
        .status(400)
        .json({ error: 'pdfUrl manquant (livre régénéré requis pour renvoyer)' })
    }
    if (typeof overridePageCount !== 'number' || overridePageCount <= 0) {
      return res.status(400).json({ error: 'pageCount manquant' })
    }
  }

  let pdfUrl: string | undefined = o0.pdfUrl
  let pageCount: number | undefined = o0.pageCount

  if (type === 'order') {
    try {
      await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref)
        const o = snap.data() as Record<string, any>

        if (o.gelatoStatus === 'pending') {
          throw new HttpError(
            409,
            'Une vérification est déjà en cours pour cette commande — patiente un instant.'
          )
        }
        if (o.gelatoStatus === 'accepted') {
          throw new HttpError(
            409,
            'Cette commande est déjà acceptée par Gelato — impossible de la renvoyer.'
          )
        }

        if (!isAdmin) {
          if (o.gelatoStatus !== 'refused') {
            throw new HttpError(409, 'Cette commande n’a pas été refusée — rien à renvoyer.')
          }
          const retryCount = Number(o.gelatoRetryCount ?? 0)
          if (retryCount >= 3) {
            throw new HttpError(
              409,
              'Nombre maximum de renvois atteint — contacte l’équipe Carnet.'
            )
          }
          const chargedPages = Number(o.pageCount ?? 0)
          const diff = Math.abs(overridePageCount! - chargedPages)
          if (diff > 3) {
            throw new HttpError(
              400,
              `Écart de pages trop important (${diff} pages) — contacte l’équipe Carnet pour ajuster le prix.`
            )
          }
          pdfUrl = overridePdfUrl
          pageCount = overridePageCount
          tx.update(ref, {
            pdfUrl: overridePdfUrl,
            pageCount: overridePageCount,
            gelatoStatus: 'pending',
            gelatoRetryCount: retryCount + 1,
            updatedAt: FieldValue.serverTimestamp(),
          })
        } else {
          tx.update(ref, {
            gelatoStatus: 'pending',
            updatedAt: FieldValue.serverTimestamp(),
          })
        }
      })
    } catch (e) {
      if (e instanceof HttpError) {
        return res.status(e.status).json({ error: e.message })
      }
      throw e
    }
  }

  if (!pdfUrl) {
    return res.status(400).json({ error: 'Commande sans PDF (pdfUrl manquant)' })
  }

  const isHard = o0.coverType === 'hard'
  const { productUid } = productUidFor(o0.coverType)
  if (!productUid) {
    return res.status(503).json({
      error: `Product UID manquant (env GELATO_PRODUCT_UID_${isHard ? 'HARD' : 'SOFT'})`,
    })
  }

  const payload = {
    orderType: type,
    orderReferenceId: orderId,
    customerReferenceId: String(o0.userId ?? ''),
    currency: 'CHF',
    items: [
      {
        itemReferenceId: orderId,
        productUid,
        files: [{ type: 'default', url: pdfUrl }],
        quantity: 1,
        ...(pageCount ? { pageCount } : {}),
      },
    ],
    shippingAddress: {
      firstName: String(o0.firstName ?? ''),
      lastName: String(o0.lastName ?? ''),
      addressLine1: String(o0.street ?? ''),
      city: String(o0.city ?? ''),
      postCode: String(o0.npa ?? ''),
      country: countryToIso(String(o0.country ?? 'Suisse')),
      email: String(o0.userEmail ?? ''),
    },
  }

  try {
    const gelatoRes = await fetch(GELATO_ORDER_URL, {
      method: 'POST',
      headers: { 'X-API-KEY': apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
    const raw = await gelatoRes.text()
    let data: any = null
    try {
      data = JSON.parse(raw)
    } catch {
      /* réponse non-JSON — on garde raw */
    }

    if (!gelatoRes.ok) {
      const detail = (data?.message ?? raw ?? '').toString().slice(0, 500)
      // Échec synchrone (payload invalide, etc.) — distinct d'un refus
      // prépresse, qui lui n'apparaît jamais ici (cf. lib/gelato.ts). Un
      // renvoi client raté de cette façon consomme quand même une tentative
      // sur les 3 : simplification assumée plutôt que de compenser la
      // transaction pour ce cas rare.
      await ref.update({ gelatoStatus: 'error', gelatoError: detail })
      return res
        .status(502)
        .json({ error: 'Gelato a refusé la commande', detail })
    }

    const gelatoOrderId = data?.id ?? data?.orderId ?? null
    await ref.update({
      gelatoOrderId,
      // Pour un brouillon : statut 'draft' comme avant. Pour un envoi direct
      // en production, le statut reste 'pending' (déjà posé par la
      // transaction ci-dessus) — seul /api/gelato/status ou le cron sauront
      // dire s'il a été accepté ou refusé.
      ...(type === 'draft' ? { gelatoStatus: 'draft' } : {}),
      gelatoOrderType: type,
      gelatoError: null,
      updatedAt: FieldValue.serverTimestamp(),
    })

    return res.status(200).json({ ok: true, gelatoOrderId, orderType: type })
  } catch (e) {
    await ref.update({ gelatoStatus: 'error', gelatoError: String(e).slice(0, 500) })
    return res.status(502).json({ error: `Appel Gelato échoué : ${e}` })
  }
}

// Relit le VRAI statut d'une commande chez Gelato (admin, ou le propriétaire
// pour rafraîchir sa propre commande) — voir lib/gelato.ts pour le détail.
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

  const { newlyRefused } = await refreshGelatoOrderStatus(orderId)
  if (newlyRefused) {
    await notifyClientOfRefusal(orderId)
  }

  const fresh = (await db.collection('orders').doc(orderId).get()).data()
  return res.status(200).json({
    ok: true,
    gelatoStatus: fresh?.gelatoStatus ?? null,
    refusalReason: fresh?.refusalReason ?? null,
    refusalReasonCode: fresh?.refusalReasonCode ?? null,
  })
}

// Cron quotidien (voir vercel.json) : balaie les commandes dont le statut
// Gelato n'est pas encore tranché et rafraîchit chacune. Protégé par
// CRON_SECRET — Vercel ajoute automatiquement `Authorization: Bearer
// $CRON_SECRET` aux requêtes cron dès que cette variable d'env est définie.
async function handlePoll(req: VercelRequest, res: VercelResponse) {
  const secret = process.env.CRON_SECRET
  const auth = req.headers.authorization ?? ''
  if (!secret || auth !== `Bearer ${secret}`) {
    return res.status(401).json({ error: 'Unauthorized' })
  }

  const snap = await db
    .collection('orders')
    .where('gelatoStatus', 'in', ['draft', 'pending'])
    .get()

  let checked = 0
  let refused = 0
  for (const d of snap.docs) {
    try {
      const { newlyRefused } = await refreshGelatoOrderStatus(d.id)
      checked++
      if (newlyRefused) {
        refused++
        await notifyClientOfRefusal(d.id)
      }
    } catch (e) {
      console.error('[gelato/poll] order', d.id, e)
    }
  }

  return res.status(200).json({ ok: true, checked, refused })
}

// Dimensions exactes du gabarit de couverture (wraparound = dos + tranche +
// face) pour un type de couverture + un nombre de pages intérieures donnés —
// la largeur de la tranche dépend du nombre de pages. Sans ça, une couverture
// générée à la taille d'une page simple ne remplit qu'une fraction du gabarit
// Gelato (le reste du spread part blanc). Accessible à tout utilisateur
// connecté : appelé côté app juste avant de générer le PDF final de commande.
async function handleCoverDimensions(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const apiKey = process.env.GELATO_API_KEY
  if (!apiKey) {
    return res
      .status(503)
      .json({ error: 'Gelato non configuré (GELATO_API_KEY manquante)' })
  }

  const body =
    (typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body) ??
    {}
  const coverType = body.coverType === 'hard' ? 'hard' : 'soft'
  const { productUid, isHard } = productUidFor(coverType)
  if (!productUid) {
    return res.status(503).json({
      error: `Product UID manquant (env GELATO_PRODUCT_UID_${isHard ? 'HARD' : 'SOFT'})`,
    })
  }

  const pageCount = Number(body.pageCount)
  if (!Number.isFinite(pageCount) || pageCount <= 0) {
    return res.status(400).json({ error: 'pageCount invalide' })
  }

  try {
    const url = `${GELATO_PRODUCT_URL}/${encodeURIComponent(productUid)}/cover-dimensions?pageCount=${Math.round(pageCount)}`
    const gelatoRes = await fetch(url, { headers: { 'X-API-KEY': apiKey } })
    const raw = await gelatoRes.text()
    let data: any = null
    try {
      data = JSON.parse(raw)
    } catch {
      /* réponse non-JSON — on garde raw */
    }

    if (!gelatoRes.ok) {
      const detail = (data?.message ?? raw ?? '').toString().slice(0, 500)
      return res
        .status(502)
        .json({ error: 'Gelato a refusé la requête cover-dimensions', detail })
    }

    return res.status(200).json(data)
  } catch (e) {
    return res.status(502).json({ error: `Appel Gelato échoué : ${e}` })
  }
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'order') return handleOrder(req, res)
  if (action === 'cover-dimensions') return handleCoverDimensions(req, res)
  if (action === 'status') return handleStatus(req, res)
  if (action === 'poll') return handlePoll(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
