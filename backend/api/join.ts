import type { VercelRequest, VercelResponse } from '@vercel/node'
import { db } from '../lib/firebase'
import { escapeHtml } from '../lib/verify'

// Page publique cible des liens d'invitation https. Elle rebondit vers l'app
// (schéma carnet://join?token=…) et propose le téléchargement en repli.
const APP_SCHEME = 'carnet'
const DOWNLOAD_URL =
  process.env.APP_DOWNLOAD_URL ?? 'https://dmathys.dev/download/carnet.apk'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const token = (req.query.token ?? '') as string
  res.setHeader('Content-Type', 'text/html; charset=utf-8')

  if (!token || typeof token !== 'string') {
    return res.status(400).send(page('Lien invalide', '<p>Token manquant.</p>'))
  }

  let title = 'un carnet'
  let valid = false
  try {
    const snap = await db.collection('notebookInvites').doc(token).get()
    if (snap.exists) {
      const d = snap.data() as Record<string, any>
      const expired =
        typeof d.expiresAt === 'number' && Date.now() > d.expiresAt
      if (!d.revoked && !expired) {
        valid = true
        title = String(d.notebookTitle ?? 'un carnet')
      }
    }
  } catch {
    // ignore — affiche l'état "invalide" ci-dessous
  }

  if (!valid) {
    return res
      .status(404)
      .send(page('Invitation expirée', '<p>Ce lien n’est plus valide.</p>'))
  }

  const appUrl = `${APP_SCHEME}://join?token=${encodeURIComponent(token)}`
  const safeTitle = escapeHtml(title)
  const body = `
    <h1>Rejoindre « ${safeTitle} »</h1>
    <p class="sub">Tu es invité·e à contribuer à ce carnet de souvenirs.</p>
    <a class="btn" href="${escapeHtml(appUrl)}">Ouvrir dans l’app</a>
    <p class="hint">L’app ne s’ouvre pas ? <a href="${escapeHtml(DOWNLOAD_URL)}">Télécharge Carnet</a>, puis rouvre ce lien.</p>
    <script>setTimeout(function(){ window.location.href = ${JSON.stringify(appUrl)} }, 600);</script>
  `
  return res.status(200).send(page(`Rejoindre ${safeTitle}`, body))
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
  h1{font-size:22px;color:#2d2d2d;margin:0 0 8px;}
  .sub{color:#7a6a5a;margin:0 0 24px;}
  .btn{display:inline-block;background:#3A6648;color:#fff;text-decoration:none;
    padding:14px 24px;border-radius:30px;font-weight:bold;}
  .hint{color:#b0a090;font-size:13px;margin-top:20px;}
  .hint a{color:#3A6648;}
  p{color:#7a6a5a;}
</style></head>
<body><div class="card"><div class="brand">carnet</div>${body}</div></body></html>`
}
