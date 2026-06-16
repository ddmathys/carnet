import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { FieldValue } from 'firebase-admin/firestore'

// L'utilisateur connecté rejoint un carnet via un token d'invitation.
// Valide le token (existe, non révoqué, non expiré) puis ajoute son uid au
// `sharedWith` du carnet (admin SDK → contourne les règles client).
export default async function handler(req: VercelRequest, res: VercelResponse) {
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
