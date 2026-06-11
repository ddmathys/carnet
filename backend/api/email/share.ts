import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth, escapeHtml } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { sendEmail } from '../../lib/resend'

const APP_DOWNLOAD_URL =
  process.env.APP_DOWNLOAD_URL ?? 'https://dmathys.dev/download/carnet.apk'

// Envoie l'email d'invitation à un carnet partagé.
// Vérifie que l'appelant est bien le propriétaire du carnet.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const user = await requireAuth(req, res)
  if (!user) return

  const { notebookId, toEmail } = (req.body ?? {}) as {
    notebookId?: string
    toEmail?: string
  }
  if (!notebookId || typeof notebookId !== 'string') {
    return res.status(400).json({ error: 'Missing notebookId' })
  }
  const email = (toEmail ?? '').trim().toLowerCase()
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return res.status(400).json({ error: 'Invalid email' })
  }

  const snap = await db.collection('notebooks').doc(notebookId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Notebook not found' })

  const nb = snap.data() as Record<string, unknown>
  if (nb.userId !== user.uid) {
    return res.status(403).json({ error: 'Only the owner can invite' })
  }

  const title = escapeHtml(String(nb.title ?? 'Carnet'))
  const inviter = escapeHtml(user.email ?? 'Un membre de votre famille')

  const ok = await sendEmail({
    to: email,
    subject: `${user.email ?? 'Quelqu’un'} vous invite à rejoindre le carnet « ${String(nb.title ?? '')} »`,
    html: buildInvitationHtml({
      toEmail: escapeHtml(email),
      notebookTitle: title,
      inviterEmail: inviter,
      downloadUrl: APP_DOWNLOAD_URL,
    }),
  })

  return res.status(200).json({ ok })
}

function buildInvitationHtml({
  toEmail,
  notebookTitle,
  inviterEmail,
  downloadUrl,
}: {
  toEmail: string
  notebookTitle: string
  inviterEmail: string
  downloadUrl: string
}): string {
  return `<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1.0"/></head>
<body style="margin:0;padding:0;background:#f5ece0;font-family:'Helvetica Neue',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5ece0;padding:40px 0;">
    <tr><td align="center">
      <table width="520" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,0.08);">
        <tr>
          <td style="background:#3A6648;padding:32px 40px;text-align:center;">
            <p style="margin:0;font-size:28px;font-weight:bold;color:#FFF8E8;letter-spacing:2px;font-style:italic;">carnet</p>
            <p style="margin:8px 0 0;font-size:13px;color:rgba(255,248,232,0.75);">Chaque histoire mérite d'être racontée.</p>
          </td>
        </tr>
        <tr>
          <td style="padding:36px 40px;">
            <p style="margin:0 0 16px;font-size:16px;color:#2d2d2d;line-height:1.6;">Bonjour,</p>
            <p style="margin:0 0 24px;font-size:16px;color:#2d2d2d;line-height:1.6;">
              <strong>${inviterEmail}</strong> vous invite à accéder au carnet
              <strong>« ${notebookTitle} »</strong> sur l'application <em>Carnet</em>.
            </p>
            <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5ece0;border-radius:12px;margin-bottom:28px;">
              <tr><td style="padding:20px 24px;">
                <p style="margin:0;font-size:13px;color:#7a6a5a;text-transform:uppercase;letter-spacing:1px;">Carnet partagé</p>
                <p style="margin:6px 0 0;font-size:20px;font-weight:bold;color:#1C3D2B;">${notebookTitle}</p>
              </td></tr>
            </table>
            <p style="margin:0 0 8px;font-size:15px;color:#2d2d2d;line-height:1.6;">Pour accéder au carnet :</p>
            <ol style="margin:0 0 28px;padding-left:20px;font-size:15px;color:#2d2d2d;line-height:2;">
              <li>Télécharge l'application</li>
              <li>Crée un compte avec cette adresse email&nbsp;: <strong>${toEmail}</strong></li>
              <li>Le carnet apparaîtra automatiquement</li>
            </ol>
            <table width="100%" cellpadding="0" cellspacing="0" style="margin-bottom:28px;">
              <tr><td align="center">
                <a href="${downloadUrl}"
                   style="display:inline-block;background:#3A6648;color:#FFF8E8;text-decoration:none;font-size:15px;font-weight:600;padding:14px 36px;border-radius:10px;letter-spacing:0.3px;">
                  Télécharger l'application (Android)
                </a>
              </td></tr>
            </table>
            <p style="margin:0;font-size:13px;color:#9a8a7a;line-height:1.6;text-align:center;">
              Si vous n'avez pas demandé cet accès, ignorez simplement cet email.
            </p>
          </td>
        </tr>
        <tr>
          <td style="background:#f5ece0;padding:20px 40px;text-align:center;border-top:1px solid #e8ddd0;">
            <p style="margin:0;font-size:12px;color:#b0a090;">Envoyé par Carnet</p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`
}
