import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { computePrice, type CoverType } from '../../lib/pricing'

// Crée une session Stripe Checkout pour payer une commande (TWINT + carte).
// Le montant est RECALCULÉ ici depuis coverType + pageCount (lib/pricing.ts) —
// order.price vient du client à la création et ne doit jamais être facturé tel
// quel. CHF requis pour TWINT. Renvoie l'URL de paiement hébergée par Stripe.
const BASE_URL =
  process.env.PUBLIC_BASE_URL ?? 'https://bloom-backend-gray.vercel.app'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return

  const secret = process.env.STRIPE_SECRET_KEY
  if (!secret) {
    return res
      .status(503)
      .json({ error: 'Paiement non configuré (STRIPE_SECRET_KEY manquante)' })
  }

  const { orderId } = (req.body ?? {}) as { orderId?: string }
  if (!orderId || typeof orderId !== 'string') {
    return res.status(400).json({ error: 'Missing orderId' })
  }

  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Order not found' })
  const o = snap.data() as Record<string, any>
  if (o.userId !== user.uid) {
    return res.status(403).json({ error: 'Not your order' })
  }

  const rawPages = Number(o.pageCount ?? 0)
  if (!rawPages || rawPages <= 0) {
    return res
      .status(400)
      .json({ error: 'pageCount manquant sur la commande — PDF non généré ?' })
  }
  const coverType: CoverType = o.coverType === 'hard' ? 'hard' : 'soft'
  const trustedPrice = computePrice(coverType, rawPages)
  const amount = Math.round(trustedPrice * 100) // centimes

  // Le prix stocké venait du client à la création — on le corrige ici pour que
  // l'app/les emails affichent toujours ce qui est réellement facturé.
  if (Math.abs(Number(o.price ?? 0) - trustedPrice) > 0.001) {
    await snap.ref.update({ price: trustedPrice })
  }

  const bookTitle = String(o.bookTitle ?? 'Livre')
  const cover = coverType === 'hard' ? 'rigide' : 'souple'

  const params = new URLSearchParams()
  params.set('mode', 'payment')
  params.append('payment_method_types[0]', 'twint')
  params.append('payment_method_types[1]', 'card')
  params.set('line_items[0][quantity]', '1')
  params.set('line_items[0][price_data][currency]', 'chf')
  params.set('line_items[0][price_data][unit_amount]', String(amount))
  params.set(
    'line_items[0][price_data][product_data][name]',
    `${bookTitle} — couverture ${cover}`
  )
  params.set('metadata[orderId]', orderId)
  params.set('client_reference_id', orderId)
  if (o.userEmail) params.set('customer_email', String(o.userEmail))
  params.set(
    'success_url',
    `${BASE_URL}/api/payment/success?session_id={CHECKOUT_SESSION_ID}`
  )
  params.set('cancel_url', `${BASE_URL}/api/payment/success?canceled=1`)

  try {
    const r = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${secret}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
    })
    const data: any = await r.json()
    if (!r.ok) {
      return res.status(502).json({
        error: 'Stripe a refusé la session',
        detail: data?.error?.message ?? null,
      })
    }
    await snap.ref.update({ stripeSessionId: data.id })
    return res.status(200).json({ url: data.url })
  } catch (e) {
    return res.status(502).json({ error: `Appel Stripe échoué : ${e}` })
  }
}
