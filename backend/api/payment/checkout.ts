import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import {
  computePrice,
  computeAdditionalPrice,
  pagesOutOfRange,
  resolveCoverType,
} from '../../lib/pricing'
import {
  computePosterPrice,
  computeAdditionalPosterPrice,
  isPosterOrientation,
  isPosterSize,
  posterLabel,
} from '../../lib/poster_pricing'
import {
  computePuzzlePrice,
  computeAdditionalPuzzlePrice,
  isPuzzleSize,
} from '../../lib/puzzle_pricing'

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
  // Une commande déjà payée (ou déjà partie à l'impression) ne doit pas
  // pouvoir ouvrir une seconde session Checkout : deux encaissements pour un
  // seul livre (audit du 01.10.26).
  if (o.status !== 'received') {
    return res
      .status(409)
      .json({ error: 'Cette commande n’est plus en attente de paiement.' })
  }

  const isPoster = o.productType === 'poster'
  const isPuzzle = o.productType === 'puzzle'

  let trustedPrice: number
  let productName: string
  if (isPuzzle) {
    if (!isPuzzleSize(o.puzzleSize)) {
      return res.status(400).json({ error: 'puzzleSize invalide sur la commande' })
    }
    const price = computePuzzlePrice(o.puzzleSize)
    if (price == null) {
      return res.status(400).json({ error: `Aucun tarif pour le puzzle ${o.puzzleSize} pièces` })
    }
    trustedPrice = price
    productName = `Puzzle ${o.puzzleSize} pièces`

    // Puzzles groupés dans la même commande (voir OrderModel.additionalPuzzles
    // / backend/api/prodigi/[action].ts) : un seul article Stripe, prix total
    // du groupe.
    const extraPuzzles = Array.isArray(o.additionalPuzzles) ? o.additionalPuzzles : []
    for (const extra of extraPuzzles) {
      if (!isPuzzleSize(extra?.puzzleSize)) {
        return res.status(400).json({ error: 'puzzleSize invalide sur un puzzle supplémentaire' })
      }
      // Port déduit : Prodigi ne facture la livraison qu'une fois par
      // commande (voir computeAdditionalPuzzlePrice).
      const extraPrice = computeAdditionalPuzzlePrice(extra.puzzleSize)
      if (extraPrice == null) {
        return res.status(400).json({ error: `Aucun tarif pour le puzzle ${extra.puzzleSize} pièces (supplémentaire)` })
      }
      trustedPrice += extraPrice
    }
    if (extraPuzzles.length > 0) {
      productName = `${extraPuzzles.length + 1} puzzles`
    }
  } else if (isPoster) {
    if (!isPosterSize(o.posterSize) || !isPosterOrientation(o.posterOrientation)) {
      return res.status(400).json({ error: 'posterSize/posterOrientation invalide sur la commande' })
    }
    const price = computePosterPrice(o.posterSize, o.posterOrientation)
    if (price == null) {
      return res.status(400).json({ error: `Aucun tarif poster pour ${o.posterSize}/${o.posterOrientation}` })
    }
    trustedPrice = price
    const orientationLabel = o.posterOrientation === 'landscape' ? 'paysage' : 'portrait'
    productName = `${posterLabel(o.posterSize)} ${orientationLabel}`

    // Tirages groupés dans la même commande (voir OrderModel.additionalPosters
    // / backend/api/prodigi/[action].ts) : un seul article Stripe, prix total
    // du groupe — Prodigi les livre ensemble en une seule commande/livraison.
    const extras = Array.isArray(o.additionalPosters) ? o.additionalPosters : []
    for (const extra of extras) {
      if (!isPosterSize(extra?.posterSize) || !isPosterOrientation(extra?.posterOrientation)) {
        return res.status(400).json({ error: 'posterSize/posterOrientation invalide sur un tirage supplémentaire' })
      }
      // Port déduit (facturé une seule fois par commande chez Prodigi).
      const extraPrice = computeAdditionalPosterPrice(
        extra.posterSize,
        extra.posterOrientation
      )
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
    // Au-delà des bornes du produit, le prix était écrêté alors que la
    // commande envoyée à Prodigi portait le vrai nombre de pages : facturé
    // 122, imprimé 150 (audit du 01.10.26). On refuse plutôt que d'écrêter.
    if (pagesOutOfRange(coverType, rawPages)) {
      return res.status(400).json({
        error: `Ce livre dépasse le nombre de pages imprimable pour cette couverture (${rawPages} pages).`,
      })
    }
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
      const extraCover = resolveCoverType(extra?.coverType)
      if (pagesOutOfRange(extraCover, extraPages)) {
        return res.status(400).json({
          error: `Un livre supplémentaire dépasse le nombre de pages imprimable (${extraPages} pages).`,
        })
      }
      // Port déduit (facturé une seule fois par commande chez Prodigi).
      trustedPrice += computeAdditionalPrice(extraCover, extraPages)
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
