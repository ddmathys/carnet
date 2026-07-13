import type { VercelRequest, VercelResponse } from '@vercel/node'
import { requireAuth } from '../../lib/verify'
import { db } from '../../lib/firebase'
import { FieldValue } from 'firebase-admin/firestore'

// L'utilisateur connecté rejoint un TAG via un token d'invitation.
//
// Deux écritures, toutes deux avec l'Admin SDK (le nouvel arrivant n'a pas
// encore le droit d'écrire chez le propriétaire) :
//  1. son uid entre dans `tags/{id}.sharedWith` ;
//  2. son uid est recopié dans le `sharedWith` de chaque souvenir portant ce
//     tag — c'est ce champ que lisent les règles Firestore et le contrôle
//     d'accès aux médias.
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

  const inviteSnap = await db.collection('tagInvites').doc(token).get()
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

  const tagId = String(invite.tagId)
  const tagRef = db.collection('tags').doc(tagId)
  const tagSnap = await tagRef.get()
  if (!tagSnap.exists) return res.status(404).json({ error: 'Tag introuvable' })
  const tag = tagSnap.data() as Record<string, any>

  const label = String(tag.label ?? 'Tag')
  const already =
    tag.userId === user.uid ||
    (Array.isArray(tag.sharedWith) && tag.sharedWith.includes(user.uid))
  if (already) return res.status(200).json({ ok: true, tagId, label })

  await tagRef.update({
    sharedWith: FieldValue.arrayUnion(user.uid),
    invitedEmails: FieldValue.arrayRemove(user.email ?? ''),
  })

  // Souvenirs déjà tagués : le nouvel arrivant doit les voir. Les suivants
  // hériteront du partage à l'enregistrement (côté app).
  const memories = await db
    .collection('memories')
    .where('tagIds', 'array-contains', tagId)
    .get()
  const chunks: FirebaseFirestore.QueryDocumentSnapshot[][] = []
  for (let i = 0; i < memories.docs.length; i += 400) {
    chunks.push(memories.docs.slice(i, i + 400))
  }
  for (const chunk of chunks) {
    const batch = db.batch()
    for (const doc of chunk) {
      batch.update(doc.ref, {
        sharedWith: FieldValue.arrayUnion(user.uid),
      })
    }
    await batch.commit()
  }

  return res.status(200).json({ ok: true, tagId, label })
}
