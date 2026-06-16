import type { VercelRequest, VercelResponse } from '@vercel/node'
import { db } from '../lib/firebase'
import { escapeHtml } from '../lib/verify'

// Page publique d'écoute d'un mémo vocal — cible des QR codes imprimés dans le livre.
// Pas d'authentification : le memoryId fait office de capacité (lien non devinable).
// L'URL audio est une URL de download Firebase tokenisée, déjà publiquement lisible.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const m = (req.query.m ?? '') as string
  if (!m || typeof m !== 'string') {
    return res.status(400).send(page('Lien invalide', '<p>Identifiant manquant.</p>'))
  }

  let audioUrl: string | null = null
  let title = ''
  try {
    const snap = await db.collection('memories').doc(m).get()
    if (snap.exists) {
      const d = snap.data() as Record<string, unknown>
      audioUrl = (d.audioUrl as string) ?? null
      title = (d.title as string) ?? ''
    }
  } catch {
    // ignore — affiche la page "introuvable" ci-dessous
  }

  res.setHeader('Content-Type', 'text/html; charset=utf-8')
  res.setHeader('Cache-Control', 'public, max-age=300')

  if (!audioUrl) {
    return res
      .status(404)
      .send(page('Mémo introuvable', '<p>Ce message vocal n’est plus disponible.</p>'))
  }

  const safeTitle = escapeHtml(title)
  const body = `
    ${safeTitle ? `<h1>${safeTitle}</h1>` : ''}
    <p class="sub">Message vocal</p>
    <audio controls autoplay preload="auto" src="${escapeHtml(audioUrl)}"></audio>
  `
  return res.status(200).send(page(safeTitle || 'Message vocal', body))
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
  h1{font-size:22px;color:#2d2d2d;margin:0 0 4px;}
  .sub{color:#b0a090;text-transform:uppercase;letter-spacing:1px;font-size:12px;margin:0 0 24px;}
  audio{width:100%;margin-top:8px;}
  p{color:#7a6a5a;}
</style></head>
<body><div class="card"><div class="brand">carnet</div>${body}</div></body></html>`
}
