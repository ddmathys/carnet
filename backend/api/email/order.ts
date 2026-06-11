import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth, escapeHtml } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { sendEmail, ADMIN_EMAIL } from '../../lib/resend'

// Envoie la notification admin + la confirmation client pour une commande.
// L'app appelle ce endpoint juste après avoir créé le document orders/{orderId}.
// Toutes les données viennent de Firestore (pas du body), pour ne rien faire
// confiance au client à part l'identifiant.
export default async function handler(req: VercelRequest, res: VercelResponse) {
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

  const o = snap.data() as Record<string, unknown>
  if (o.userId !== user.uid) {
    return res.status(403).json({ error: 'Not your order' })
  }
  if (o.emailsSent === true) {
    return res.status(200).json({ ok: true, alreadySent: true })
  }

  const ref = `#${orderId.slice(0, 8).toUpperCase()}`
  const bookTitle = escapeHtml(String(o.bookTitle ?? ''))
  const fullName = escapeHtml(`${o.firstName ?? ''} ${o.lastName ?? ''}`.trim())
  const firstName = escapeHtml(String(o.firstName ?? ''))
  const userEmail = String(o.userEmail ?? '')
  const cover = o.coverType === 'hard' ? 'Rigide' : 'Souple'
  const address = escapeHtml(
    [o.street, `${o.npa ?? ''} ${o.city ?? ''}`.trim(), o.country]
      .filter(Boolean)
      .join(', ')
  )
  const price = `CHF ${Number(o.price ?? 0).toFixed(2)}`

  const adminHtml = wrap(`
    <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">🎉 Nouvelle commande reçue</p>
    ${row('Commande', `<strong>${ref}</strong>`)}
    ${row('Client', `${fullName} · ${escapeHtml(userEmail)}`)}
    ${row('Livre', bookTitle)}
    ${row('Couverture', cover)}
    ${row('Adresse', address)}
    ${row('Montant', `<strong style="color:#3A6648">${price}</strong>`)}
  `)

  const userHtml = wrap(`
    <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">Bonjour ${firstName},</p>
    <p style="margin:0 0 24px;font-size:15px;color:#2d2d2d;line-height:1.6;">
      Merci pour votre commande ! Nous avons bien reçu votre livre <strong>« ${bookTitle} »</strong>
      et nous allons le traiter dans les plus brefs délais.
    </p>
    <table width="100%" style="background:#f5ece0;border-radius:12px;margin-bottom:24px;">
      <tr><td style="padding:20px 24px;">
        <p style="margin:0 0 12px;font-size:13px;color:#7a6a5a;text-transform:uppercase;letter-spacing:1px;">Récapitulatif</p>
        <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📖 ${bookTitle}</p>
        <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📦 Couverture ${cover.toLowerCase()}</p>
        <p style="margin:0 0 6px;font-size:14px;color:#2d2d2d;">📍 ${address}</p>
        <p style="margin:0;font-size:15px;font-weight:bold;color:#3A6648;">${price} — paiement à réception</p>
      </td></tr>
    </table>
    <p style="margin:0;font-size:14px;color:#888;line-height:1.6;">
      Vous recevrez une facture avec les détails de paiement dès que votre livre sera prêt à être envoyé.
      Délai estimé : 5 à 7 jours ouvrés.
    </p>
  `)

  const [adminOk, userOk] = await Promise.all([
    sendEmail({
      to: ADMIN_EMAIL,
      subject: `🎉 Nouvelle commande ${ref} — ${fullName}`,
      html: adminHtml,
    }),
    userEmail
      ? sendEmail({
          to: userEmail,
          subject: `Commande confirmée — ${String(o.bookTitle ?? '')}`,
          html: userHtml,
        })
      : Promise.resolve(false),
  ])

  if (adminOk || userOk) {
    await snap.ref.update({ emailsSent: true })
  }

  return res.status(200).json({ ok: adminOk && userOk, adminOk, userOk })
}

function row(label: string, value: string): string {
  return `<tr>
    <td style="padding:8px 0;border-bottom:1px solid #eee;color:#888;font-size:13px;">${label}</td>
    <td style="padding:8px 0;border-bottom:1px solid #eee;font-size:13px;">${value}</td>
  </tr>`
}

function wrap(body: string): string {
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"/></head>
<body style="margin:0;padding:0;background:#f5ece0;font-family:Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 0;">
  <tr><td align="center">
    <table width="520" cellpadding="0" cellspacing="0"
           style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
      <tr><td style="background:#3A6648;padding:28px 36px;">
        <p style="margin:0;font-size:22px;font-weight:bold;color:#FFF8E8;font-style:italic;">carnet</p>
      </td></tr>
      <tr><td style="padding:28px 36px;"><table width="100%" style="border-collapse:collapse;">${body}</table></td></tr>
      <tr><td style="background:#f5ece0;padding:16px 36px;font-size:12px;color:#b0a090;text-align:center;">
        Carnet · ${new Date().getFullYear()}
      </td></tr>
    </table>
  </td></tr>
</table></body></html>`
}
