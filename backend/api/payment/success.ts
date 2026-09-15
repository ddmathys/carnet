import type { VercelRequest, VercelResponse } from '@vercel/node'
import { createHmac, timingSafeEqual } from 'crypto'
import { db } from '../../lib/firebase'
import { escapeHtml } from '../../lib/verify'
import { FieldValue } from 'firebase-admin/firestore'

// Double rôle sur la même URL (pas un fichier séparé : le plan Vercel Hobby
// plafonne à 12 fonctions, déjà atteint — voir STATUS.md) :
//   GET  → page de retour navigateur après Stripe Checkout (comportement
//          d'origine, inchangé) : revérifie le statut directement auprès de
//          Stripe avant de marquer la commande payée.
//   POST → webhook Stripe (`checkout.session.completed`), filet de sécurité
//          ajouté le 15.09.26 : si le client paie (notamment via TWINT, qui
//          redirige vers une appli tierce) puis ne revient jamais sur cette
//          page, la commande restait « non payée » en base malgré
//          l'encaissement réel côté Stripe. Le webhook marque la commande
//          payée indépendamment du retour navigateur.
//          Activation : créer un endpoint webhook dans le dashboard Stripe
//          pointant vers `${BASE_URL}/api/payment/success`, événement
//          `checkout.session.completed`, copier le « signing secret » dans
//          `STRIPE_WEBHOOK_SECRET` (Vercel). Sans cette variable, le POST
//          répond 200 sans rien faire — comportement identique à avant.
export const config = { api: { bodyParser: false } }

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method === 'POST') return handleWebhook(req, res)
  return handleBrowserReturn(req, res)
}

async function handleBrowserReturn(req: VercelRequest, res: VercelResponse) {
  res.setHeader('Content-Type', 'text/html; charset=utf-8')

  if (req.query.canceled === '1') {
    return res.status(200).send(page('Paiement annulé',
      '<p>Le paiement a été annulé. Tu peux réessayer depuis l’app.</p>'))
  }

  const sessionId = (req.query.session_id ?? '') as string
  const secret = process.env.STRIPE_SECRET_KEY
  if (!sessionId || !secret) {
    return res.status(400).send(page('Lien invalide', '<p>Session manquante.</p>'))
  }

  try {
    const r = await fetch(
      `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}`,
      { headers: { Authorization: `Bearer ${secret}` } }
    )
    const s: any = await r.json()
    if (!r.ok) {
      return res.status(502).send(page('Erreur', '<p>Vérification impossible.</p>'))
    }

    const paid = s.payment_status === 'paid'
    const orderId = s.metadata?.orderId as string | undefined

    if (paid && orderId) {
      await markOrderPaid(orderId, sessionId)
      return res.status(200).send(page('Paiement reçu 🎉',
        '<p>Merci ! Ton paiement est confirmé. Tu peux revenir dans l’app.</p>'))
    }

    return res.status(200).send(page('Paiement en attente',
      '<p>Le paiement n’est pas encore confirmé. Si tu as payé, patiente un instant.</p>'))
  } catch {
    return res.status(502).send(page('Erreur', '<p>Une erreur est survenue.</p>'))
  }
}

async function handleWebhook(req: VercelRequest, res: VercelResponse) {
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET
  if (!webhookSecret) {
    // Pas encore configuré côté Stripe/Vercel — no-op silencieux, le paiement
    // reste confirmé au retour navigateur comme avant (voir en-tête).
    return res.status(200).json({ ok: true, skipped: 'STRIPE_WEBHOOK_SECRET not configured' })
  }

  const sig = req.headers['stripe-signature']
  if (!sig || typeof sig !== 'string') {
    return res.status(400).json({ error: 'Missing Stripe-Signature header' })
  }

  const rawBody = await readRawBody(req)
  if (!verifyStripeSignature(rawBody, sig, webhookSecret)) {
    return res.status(400).json({ error: 'Invalid signature' })
  }

  let event: any
  try {
    event = JSON.parse(rawBody.toString('utf8'))
  } catch {
    return res.status(400).json({ error: 'Invalid JSON payload' })
  }

  if (
    event?.type === 'checkout.session.completed' ||
    event?.type === 'checkout.session.async_payment_succeeded'
  ) {
    const session = event.data?.object ?? {}
    const orderId = session.metadata?.orderId as string | undefined
    const paid = session.payment_status === 'paid'
    if (paid && orderId) {
      await markOrderPaid(orderId, String(session.id ?? ''))
    }
  }

  return res.status(200).json({ received: true })
}

async function markOrderPaid(orderId: string, stripeSessionId: string) {
  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return
  const o = snap.data() as Record<string, any>
  // Idempotent : déjà marquée par le retour navigateur OU un webhook
  // précédent (Stripe peut renvoyer le même événement plusieurs fois).
  if (o.status === 'paid') return
  await ref.update({
    status: 'paid',
    paidAt: FieldValue.serverTimestamp(),
    stripeSessionId,
    updatedAt: FieldValue.serverTimestamp(),
  })
}

async function readRawBody(req: VercelRequest): Promise<Buffer> {
  const chunks: Buffer[] = []
  for await (const chunk of req) {
    chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk)
  }
  return Buffer.concat(chunks)
}

// Vérifie la signature `Stripe-Signature: t=…,v1=…` sans le SDK stripe (le
// projet n'en a pas — tous les appels Stripe passent par fetch() direct, cf.
// checkout.ts). Tolérance de 5 min sur l'horodatage (anti-rejeu).
function verifyStripeSignature(rawBody: Buffer, header: string, secret: string): boolean {
  const parts: Record<string, string> = {}
  for (const p of header.split(',')) {
    const idx = p.indexOf('=')
    if (idx === -1) continue
    parts[p.slice(0, idx)] = p.slice(idx + 1)
  }
  const timestamp = parts.t
  const v1 = parts.v1
  if (!timestamp || !v1) return false
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false

  const signedPayload = `${timestamp}.${rawBody.toString('utf8')}`
  const expected = createHmac('sha256', secret).update(signedPayload).digest('hex')
  const expectedBuf = Buffer.from(expected, 'hex')
  const gotBuf = Buffer.from(v1, 'hex')
  return expectedBuf.length === gotBuf.length && timingSafeEqual(expectedBuf, gotBuf)
}

function page(titleText: string, body: string): string {
  return `<!DOCTYPE html><html lang="fr"><head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${escapeHtml(titleText)} · carnet</title>
<style>
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#f5ece0;font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;padding:24px;}
  .card{background:#fff;border-radius:20px;box-shadow:0 4px 24px rgba(0,0,0,.08);
    padding:36px 32px;max-width:420px;width:100%;text-align:center;}
  .brand{color:#3A6648;font-style:italic;font-weight:bold;font-size:20px;margin-bottom:20px;}
  h1{font-size:22px;color:#2d2d2d;margin:0 0 12px;}
  p{color:#7a6a5a;}
</style></head>
<body><div class="card"><div class="brand">carnet</div><h1>${escapeHtml(titleText)}</h1>${body}</div></body></html>`
}
