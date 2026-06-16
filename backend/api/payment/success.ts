import type { VercelRequest, VercelResponse } from '@vercel/node'
import { db } from '../../lib/firebase'
import { escapeHtml } from '../../lib/verify'
import { FieldValue } from 'firebase-admin/firestore'

// Page de retour après Stripe Checkout. On revérifie le statut de paiement
// directement auprès de Stripe (avec la clé secrète) avant de marquer la
// commande payée — on ne fait pas confiance aux seuls paramètres d'URL.
export default async function handler(req: VercelRequest, res: VercelResponse) {
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
      await db.collection('orders').doc(orderId).update({
        status: 'paid',
        paidAt: FieldValue.serverTimestamp(),
        stripeSessionId: sessionId,
        updatedAt: FieldValue.serverTimestamp(),
      })
      return res.status(200).send(page('Paiement reçu 🎉',
        '<p>Merci ! Ton paiement est confirmé. Tu peux revenir dans l’app.</p>'))
    }

    return res.status(200).send(page('Paiement en attente',
      '<p>Le paiement n’est pas encore confirmé. Si tu as payé, patiente un instant.</p>'))
  } catch {
    return res.status(502).send(page('Erreur', '<p>Une erreur est survenue.</p>'))
  }
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
