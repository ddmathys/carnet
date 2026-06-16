import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'

// Crée un lien d'invitation à un carnet. Le propriétaire appelle ce endpoint ;
// on stocke un token dans `notebookInvites/{token}` et on renvoie l'URL https
// partageable (qui rebondit vers l'app via la page /join).
const BASE_URL =
  process.env.PUBLIC_BASE_URL ?? 'https://bloom-backend-gray.vercel.app'
const DOWNLOAD_URL =
  process.env.APP_DOWNLOAD_URL ?? 'https://dmathys.dev/download/carnet.apk'
const INVITE_TTL_DAYS = 30

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return

  const { notebookId } = (req.body ?? {}) as { notebookId?: string }
  if (!notebookId || typeof notebookId !== 'string') {
    return res.status(400).json({ error: 'Missing notebookId' })
  }

  const snap = await db.collection('notebooks').doc(notebookId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Notebook not found' })
  const nb = snap.data() as Record<string, unknown>
  if (nb.userId !== user.uid) {
    return res.status(403).json({ error: 'Seul le propriétaire peut inviter' })
  }

  const token = randomUUID().replace(/-/g, '')
  const now = Date.now()
  await db.collection('notebookInvites').doc(token).set({
    notebookId,
    role: 'editor',
    createdBy: user.uid,
    notebookTitle: String(nb.title ?? 'Carnet'),
    createdAt: now,
    expiresAt: now + INVITE_TTL_DAYS * 24 * 60 * 60 * 1000,
    revoked: false,
  })

  return res.status(200).json({
    token,
    url: `${BASE_URL}/join?token=${token}`,
    downloadUrl: DOWNLOAD_URL,
    notebookTitle: String(nb.title ?? 'Carnet'),
  })
}
