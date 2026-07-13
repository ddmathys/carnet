import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { FieldValue } from 'firebase-admin/firestore'

// Partage d'un TAG (le remplaçant du partage de carnet). Les deux actions sont
// servies par une seule fonction — le plan Vercel Hobby plafonne à 12 fonctions
// par déploiement, comme api/video/[action].ts qui suit le même motif.
//
//  POST /api/tag/invite  { tagId }  → crée un lien d'invitation partageable
//  POST /api/tag/join    { token }  → l'appelant rejoint le tag
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

  const action = String(req.query.action ?? '')
  const body = (req.body ?? {}) as Record<string, unknown>

  if (action === 'invite') return invite(res, user.uid, body)
  if (action === 'join') return join(res, user.uid, user.email, body)
  return res.status(404).json({ error: 'Action inconnue' })
}

// ── invite ───────────────────────────────────────────────────────────────────

async function invite(
  res: VercelResponse,
  uid: string,
  body: Record<string, unknown>
) {
  const tagId = body.tagId
  if (!tagId || typeof tagId !== 'string') {
    return res.status(400).json({ error: 'Missing tagId' })
  }

  const snap = await db.collection('tags').doc(tagId).get()
  if (!snap.exists) return res.status(404).json({ error: 'Tag not found' })
  const tag = snap.data() as Record<string, unknown>
  if (tag.userId !== uid) {
    return res.status(403).json({ error: 'Seul le propriétaire peut inviter' })
  }

  const token = randomUUID().replace(/-/g, '')
  const now = Date.now()
  const label = String(tag.label ?? 'Tag')
  await db.collection('tagInvites').doc(token).set({
    tagId,
    role: 'editor',
    createdBy: uid,
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

// ── join ─────────────────────────────────────────────────────────────────────

// Deux écritures, toutes deux avec l'Admin SDK (le nouvel arrivant n'a pas
// encore le droit d'écrire chez le propriétaire) :
//  1. son uid entre dans `tags/{id}.sharedWith` ;
//  2. son uid est recopié dans le `sharedWith` de chaque souvenir portant ce
//     tag — c'est ce champ que lisent les règles Firestore et le contrôle
//     d'accès aux médias.
async function join(
  res: VercelResponse,
  uid: string,
  email: string | null | undefined,
  body: Record<string, unknown>
) {
  const token = body.token
  if (!token || typeof token !== 'string') {
    return res.status(400).json({ error: 'Missing token' })
  }

  const inviteSnap = await db.collection('tagInvites').doc(token).get()
  if (!inviteSnap.exists) {
    return res.status(404).json({ error: 'Invitation introuvable' })
  }
  const inv = inviteSnap.data() as Record<string, any>
  if (inv.revoked === true) {
    return res.status(410).json({ error: 'Invitation révoquée' })
  }
  if (typeof inv.expiresAt === 'number' && Date.now() > inv.expiresAt) {
    return res.status(410).json({ error: 'Invitation expirée' })
  }

  const tagId = String(inv.tagId)
  const tagRef = db.collection('tags').doc(tagId)
  const tagSnap = await tagRef.get()
  if (!tagSnap.exists) return res.status(404).json({ error: 'Tag introuvable' })
  const tag = tagSnap.data() as Record<string, any>

  const label = String(tag.label ?? 'Tag')
  const already =
    tag.userId === uid ||
    (Array.isArray(tag.sharedWith) && tag.sharedWith.includes(uid))
  if (already) return res.status(200).json({ ok: true, tagId, label })

  await tagRef.update({
    sharedWith: FieldValue.arrayUnion(uid),
    invitedEmails: FieldValue.arrayRemove(email ?? ''),
  })

  // Souvenirs déjà tagués : le nouvel arrivant doit les voir. Les suivants
  // hériteront du partage à l'enregistrement (côté app).
  const memories = await db
    .collection('memories')
    .where('tagIds', 'array-contains', tagId)
    .get()
  for (let i = 0; i < memories.docs.length; i += 400) {
    const batch = db.batch()
    for (const doc of memories.docs.slice(i, i + 400)) {
      batch.update(doc.ref, { sharedWith: FieldValue.arrayUnion(uid) })
    }
    await batch.commit()
  }

  return res.status(200).json({ ok: true, tagId, label })
}
