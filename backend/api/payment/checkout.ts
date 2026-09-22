import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { computePrice, resolveCoverType } from '../../lib/pricing'
import {
  computePosterPrice,
  isPosterOrientation,
  isPosterSize,
} from '../../lib/poster_pricing'

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

  const isPoster = o.productType === 'poster'

  let trustedPrice: number
  let productName: string
  if (isPoster) {
    if (!isPosterSize(o.posterSize) || !isPosterOrientation(o.posterOrientation)) {
      return res.status(400).json({ error: 'posterSize/posterOrientation invalide sur la commande' })
    }
    const price = computePosterPrice(o.posterSize, o.posterOrientation)
    if (price == null) {
      return res.status(400).json({ error: `Aucun tarif poster pour ${o.posterSize}/${o.posterOrientation}` })
    }
    trustedPrice = price
    const orientationLabel = o.posterOrientation === 'landscape' ? 'paysage' : 'portrait'
    productName = `Tirage ${o.posterSize} ${orientationLabel}`

    // Tirages groupés dans la même commande (voir OrderModel.additionalPosters
    // / backend/api/prodigi/[action].ts) : un seul article Stripe, prix total
    // du groupe — Prodigi les livre ensemble en une seule commande/livraison.
    const extras = Array.isArray(o.additionalPosters) ? o.additionalPosters : []
    for (const extra of extras) {
      if (!isPosterSize(extra?.posterSize) || !isPosterOrientation(extra?.posterOrientation)) {
        return res.status(400).json({ error: 'posterSize/posterOrientation invalide sur un tirage supplémentaire' })
      }
      const extraPrice = computePosterPrice(extra.posterSize, extra.posterOrientation)
      if (extraPrice == null) {
        return res.status(400).json({ error: `Aucun tarif poster pour ${extra.posterSize}/${extra.posterOrientation} (tirage supplémentaire)` })
      }
      trustedPrice += extraPrice
    }
    if (extras.length > 0) {
      productName = `${extras.length + 1} tirages`
    }
  } else {
    const rawPages = Number(o.pageCount ?? 0)
    if (!rawPages || rawPages <= 0) {
      return res
        .status(400)
        .json({ error: 'pageCount manquant sur la commande — PDF non généré ?' })
    }
    const coverType = resolveCoverType(o.coverType)
    trustedPrice = computePrice(coverType, rawPages)
    const bookTitle = String(o.bookTitle ?? 'Livre')
    const cover =
      coverType === 'hard' ? 'rigide' : coverType === 'layflat' ? 'layflat' : 'souple'
    productName = `${bookTitle} — couverture ${cover}`

    // Livres groupés dans la même commande (voir OrderModel.additionalBooks
    // / backend/api/prodigi/[action].ts) : un seul article Stripe, prix total
    // du groupe.
    const extraBooks = Array.isArray(o.additionalBooks) ? o.additionalBooks : []
    for (const extra of extraBooks) {
      const extraPages = Number(extra?.pageCount ?? 0)
      if (!extraPages || extraPages <= 0) {
        return res.status(400).json({ error: 'pageCount manquant sur un livre supplémentaire' })
      }
      trustedPrice += computePrice(resolveCoverType(extra?.coverType), extraPages)
    }
    if (extraBooks.length > 0) {
      productName = `${extraBooks.length + 1} livres`
    }
  }
  const amount = Math.round(trustedPrice * 100) // centimes

  // Le prix stocké venait du client à la création — on le corrige ici pour que
  // l'app/les emails affichent toujours ce qui est réellement facturé.
  if (Math.abs(Number(o.price ?? 0) - trustedPrice) > 0.001) {
    await snap.ref.update({ price: trustedPrice })
  }

  const params = new URLSearchParams()
  params.set('mode', 'payment')
  params.append('payment_method_types[0]', 'twint')
  params.append('payment_method_types[1]', 'card')
  params.set('line_items[0][quantity]', '1')
  params.set('line_items[0][price_data][currency]', 'chf')
  params.set('line_items[0][price_data][unit_amount]', String(amount))
  params.set('line_items[0][price_data][product_data][name]', productName)
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
