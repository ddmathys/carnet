import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'

// Lien d'invitation à un TAG (remplace l'invitation à un carnet). Le
// propriétaire du tag appelle ce endpoint ; le token vit dans
// `tagInvites/{token}` et l'URL renvoyée rebondit vers l'app via /join.
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

  const { tagId } = (req.body ?? {}) as { tagId?: string }
  if (!tagId || typeof tagId !== 'string') {
    return res.status(400).json({ error: 'Missing tagId' })
  }

  const snap = await db.collection('tags').doc(tagId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Tag not found' })
  const tag = snap.data() as Record<string, unknown>
  if (tag.userId !== user.uid) {
    return res.status(403).json({ error: 'Seul le propriétaire peut inviter' })
  }

  const token = randomUUID().replace(/-/g, '')
  const now = Date.now()
  const label = String(tag.label ?? 'Tag')
  await db.collection('tagInvites').doc(token).set({
    tagId,
    role: 'editor',
    createdBy: user.uid,
    tagLabel: label,
    createdAt: now,
    expiresAt: now + INVITE_TTL_DAYS * 24 * 60 * 60 * 1000,
    revoked: false,
  })

  return res.status(200).json({
    token,
    url: `${BASE_URL}/join?token=${token}&kind=tag`,
    downloadUrl: DOWNLOAD_URL,
    tagLabel: label,
  })
}
