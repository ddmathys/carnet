import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { ADMIN_EMAIL } from '../../lib/resend'

// Crée une commande Gelato à partir d'une commande Firestore.
// Réservé à l'admin. Par défaut en `draft` : la commande est créée chez Gelato
// mais PAS mise en production — l'admin la revoit / l'ajuste dans le dashboard
// Gelato puis la confirme. Passer { orderType: "order" } pour commander direct.
const GELATO_ORDER_URL = 'https://order.gelatoapis.com/v4/orders'

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

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return
  if (user.email !== ADMIN_EMAIL) {
    return res.status(403).json({ error: 'Réservé à l’admin' })
  }

  const apiKey = process.env.GELATO_API_KEY
  if (!apiKey) {
    return res
      .status(503)
      .json({ error: 'Gelato non configuré (GELATO_API_KEY manquante)' })
  }

  const { orderId, orderType } = (req.body ?? {}) as {
    orderId?: string
    orderType?: string
  }
  if (!orderId || typeof orderId !== 'string') {
    return res.status(400).json({ error: 'Missing orderId' })
  }
  const type = orderType === 'order' ? 'order' : 'draft'

  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Order not found' })
  const o = snap.data() as Record<string, any>

  const pdfUrl = o.pdfUrl as string | undefined
  if (!pdfUrl) {
    return res.status(400).json({ error: 'Commande sans PDF (pdfUrl manquant)' })
  }

  const isHard = o.coverType === 'hard'
  const productUid = isHard
    ? process.env.GELATO_PRODUCT_UID_HARD
    : process.env.GELATO_PRODUCT_UID_SOFT
  if (!productUid) {
    return res.status(503).json({
      error: `Product UID manquant (env GELATO_PRODUCT_UID_${isHard ? 'HARD' : 'SOFT'})`,
    })
  }

  const payload = {
    orderType: type,
    orderReferenceId: orderId,
    customerReferenceId: String(o.userId ?? ''),
    currency: 'CHF',
    items: [
      {
        itemReferenceId: orderId,
        productUid,
        files: [{ type: 'default', url: pdfUrl }],
        quantity: 1,
      },
    ],
    shippingAddress: {
      firstName: String(o.firstName ?? ''),
      lastName: String(o.lastName ?? ''),
      addressLine1: String(o.street ?? ''),
      city: String(o.city ?? ''),
      postCode: String(o.npa ?? ''),
      country: countryToIso(String(o.country ?? 'Suisse')),
      email: String(o.userEmail ?? ''),
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
      await snap.ref.update({ gelatoStatus: 'error', gelatoError: detail })
      return res
        .status(502)
        .json({ error: 'Gelato a refusé la commande', detail })
    }

    const gelatoOrderId = data?.id ?? data?.orderId ?? null
    await snap.ref.update({
      gelatoOrderId,
      gelatoStatus: type === 'draft' ? 'draft' : 'submitted',
      gelatoOrderType: type,
      gelatoError: null,
      updatedAt: new Date(),
    })

    return res.status(200).json({ ok: true, gelatoOrderId, orderType: type })
  } catch (e) {
    return res.status(502).json({ error: `Appel Gelato échoué : ${e}` })
  }
}
