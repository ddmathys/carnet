import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'

// Endpoints « carnet » regroupés en UNE fonction serverless. URLs INCHANGÉES —
// la route dynamique capte les deux :
//   POST /api/notebook/invite → crée un lien d'invitation à un carnet
//   POST /api/notebook/join   → rejoint un carnet via un token d'invitation
//
// Le regroupement n'est pas cosmétique : le plan Hobby de Vercel plafonne à 12
// fonctions, et le backend était pile à 12. Ces deux-là étaient les plus petits
// et les moins critiques (hérités des carnets d'avant les tags, `tag/[action]`
// étant le chemin actuel), donc les moins risqués à réunir.

const BASE_URL =
  process.env.PUBLIC_BASE_URL ?? 'https://bloom-backend-gray.vercel.app'
const DOWNLOAD_URL =
  process.env.APP_DOWNLOAD_URL ?? 'https://dmathys.dev/download/carnet.apk'
const INVITE_TTL_DAYS = 30

// Crée un lien d'invitation à un carnet. Le propriétaire appelle ce endpoint ;
// on stocke un token dans `notebookInvites/{token}` et on renvoie l'URL https
// partageable (qui rebondit vers l'app via la page /join).
async function handleInvite(req: VercelRequest, res: VercelResponse) {
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

// L'utilisateur connecté rejoint un carnet via un token d'invitation.
// Valide le token (existe, non révoqué, non expiré) puis ajoute son uid au
// `sharedWith` du carnet (admin SDK → contourne les règles client).
async function handleJoin(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return

  const { token } = (req.body ?? {}) as { token?: string }
  if (!token || typeof token !== 'string') {
    return res.status(400).json({ error: 'Missing token' })
  }

  const inviteSnap = await db.collection('notebookInvites').doc(token).get()
  if (!inviteSnap.exists) {
    return res.status(404).json({ error: 'Invitation introuvable' })
  }
  const invite = inviteSnap.data() as Record<string, any>
  if (invite.revoked === true) {
    return res.status(410).json({ error: 'Invitation révoquée' })
  }
  if (typeof invite.expiresAt === 'number' && Date.now() > invite.expiresAt) {
    return res.status(410).json({ error: 'Invitation expirée' })
  }

  const notebookId = String(invite.notebookId)
  const nbRef = db.collection('notebooks').doc(notebookId)
  const nbSnap = await nbRef.get()
  if (!nbSnap.exists) {
    return res.status(404).json({ error: 'Carnet introuvable' })
  }
  const nb = nbSnap.data() as Record<string, any>

  // Déjà propriétaire ou déjà membre → rien à faire, on renvoie OK.
  const already =
    nb.userId === user.uid ||
    (Array.isArray(nb.sharedWith) && nb.sharedWith.includes(user.uid))
  if (!already) {
    await nbRef.update({
      sharedWith: FieldValue.arrayUnion(user.uid),
      // si l'email était en attente, on le retire
      invitedEmails: FieldValue.arrayRemove(user.email ?? ''),
    })
  }

  return res
    .status(200)
    .json({ ok: true, notebookId, title: String(nb.title ?? 'Carnet') })
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'invite') return handleInvite(req, res)
  if (action === 'join') return handleJoin(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
