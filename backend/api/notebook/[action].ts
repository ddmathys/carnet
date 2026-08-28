import type { VercelRequest, VercelResponse } from '@vercel/node'
import { randomUUID } from 'crypto'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { db, auth } from '../../lib/firebase'
import { deleteObject } from '../../lib/r2'
import { photoKeysOf, videoKeysOf, audioKeyOf } from '../../lib/access'

// Suppression de compte (voir handleDeleteAccount) peut toucher beaucoup de
// médias R2 pour un utilisateur avec un long historique — même marge que
// video/[action].ts.
export const config = { maxDuration: 60 }

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

// Supprime le compte de l'utilisateur connecté et TOUTES ses données, sans
// exception — bouton "Supprimer mon compte" de l'écran Profil, voir
// landing/delete-account.html pour la procédure équivalente par email.
//
// Seule exception délibérée : les commandes (`orders`) déjà payées ne sont
// pas effacées mais ANONYMISÉES (adresse, email, titre retirés ; prix, date,
// statut conservés) — obligations comptables/légales, documentées sur la
// page de suppression. Tous les médias (PDF, photo de couverture) de ces
// commandes sont eux bien supprimés de R2.
async function handleDeleteAccount(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return
  const uid = user.uid

  try {
    // 1. Souvenirs (photos/vidéos/audio + mesures de croissance, qui sont des
    // souvenirs de type 'taille_poids') possédés par l'utilisateur.
    const memSnap = await db.collection('memories').where('userId', '==', uid).get()
    for (const doc of memSnap.docs) {
      const m = doc.data()
      const keys = [...photoKeysOf(m), ...videoKeysOf(m)]
      const audioKey = audioKeyOf(m)
      if (audioKey) keys.push(audioKey)
      await Promise.allSettled(keys.map((k) => deleteObject(k)))
      await doc.ref.delete()
    }

    // 2. Historique des livres générés (PDF + photo de couverture sur R2).
    const booksSnap = await db.collection('generatedBooks').where('userId', '==', uid).get()
    for (const doc of booksSnap.docs) {
      const b = doc.data() as Record<string, unknown>
      const keys = [b.storagePath, b.coverPhotoKey].filter(
        (k): k is string => typeof k === 'string' && k.length > 0
      )
      await Promise.allSettled(keys.map((k) => deleteObject(k)))
      await doc.ref.delete()
    }

    // 3. Commandes : médias supprimés, données personnelles anonymisées (voir
    // commentaire au-dessus de la fonction).
    const ordersSnap = await db.collection('orders').where('userId', '==', uid).get()
    for (const doc of ordersSnap.docs) {
      const o = doc.data() as Record<string, unknown>
      const keys: string[] = []
      if (typeof o.posterPhotoKey === 'string' && o.posterPhotoKey) keys.push(o.posterPhotoKey)
      if (typeof o.pdfUrl === 'string' && o.pdfUrl) {
        try {
          const key = new URL(o.pdfUrl).searchParams.get('key')
          if (key) keys.push(key)
        } catch {
          // pdfUrl mal formée (ancien format) → rien à extraire, pas bloquant.
        }
      }
      await Promise.allSettled(keys.map((k) => deleteObject(k)))
      await doc.ref.update({
        userEmail: FieldValue.delete(),
        firstName: FieldValue.delete(),
        lastName: FieldValue.delete(),
        street: FieldValue.delete(),
        city: FieldValue.delete(),
        npa: FieldValue.delete(),
        bookTitle: FieldValue.delete(),
        posterCaption: FieldValue.delete(),
        posterPhotoKey: FieldValue.delete(),
        posterPhotoUrl: FieldValue.delete(),
        pdfUrl: FieldValue.delete(),
        adminNote: FieldValue.delete(),
        accountDeleted: true,
      })
    }

    // 4. Tags : ceux possédés sont supprimés ; sur ceux des autres, on retire
    // juste l'utilisateur de `sharedWith` (ne touche pas aux données d'autrui).
    const ownedTagsSnap = await db.collection('tags').where('userId', '==', uid).get()
    for (const doc of ownedTagsSnap.docs) await doc.ref.delete()
    const sharedTagsSnap = await db
      .collection('tags')
      .where('sharedWith', 'array-contains', uid)
      .get()
    for (const doc of sharedTagsSnap.docs) {
      await doc.ref.update({ sharedWith: FieldValue.arrayRemove(uid) })
    }

    // 5. Carnets (espaces) : même logique — supprimés si possédés, sinon
    // juste retirés des collaborateurs.
    const ownedNbSnap = await db.collection('notebooks').where('userId', '==', uid).get()
    for (const doc of ownedNbSnap.docs) await doc.ref.delete()
    const sharedNbSnap = await db
      .collection('notebooks')
      .where('sharedWith', 'array-contains', uid)
      .get()
    for (const doc of sharedNbSnap.docs) {
      const update: Record<string, unknown> = { sharedWith: FieldValue.arrayRemove(uid) }
      if (user.email) update.invitedEmails = FieldValue.arrayRemove(user.email)
      await doc.ref.update(update)
    }

    // 6. Reels vidéo (QR code des tirages) et invitations créés par l'utilisateur.
    const reelsSnap = await db.collection('posterReels').where('userId', '==', uid).get()
    for (const doc of reelsSnap.docs) await doc.ref.delete()
    const invitesSnap = await db
      .collection('notebookInvites')
      .where('createdBy', '==', uid)
      .get()
    for (const doc of invitesSnap.docs) await doc.ref.delete()

    // 7. Profil, puis le compte d'authentification lui-même (en dernier : s'il
    // échoue, tout le reste a quand même été nettoyé).
    await db.collection('users').doc(uid).delete().catch(() => {})
    await auth.deleteUser(uid)

    return res.status(200).json({ ok: true })
  } catch (e) {
    return res.status(500).json({ error: `Suppression incomplète : ${e}` })
  }
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'invite') return handleInvite(req, res)
  if (action === 'join') return handleJoin(req, res)
  if (action === 'delete-account') return handleDeleteAccount(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
