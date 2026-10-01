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
//
// ── Réécrit le 01.10.26 (audit) ──────────────────────────────────────────────
// Deux défauts corrigés :
//
//  1. INCOMPLÈTE. Elle laissait derrière elle les brouillons de livres
//     (`bookDrafts`, qui portent des textes et des clés de photos), les
//     invitations de tags émises, les liens de partage encore vivants
//     (`shares`), le fil d'activité (`memoryActivities`, qui porte le nom de
//     la personne), les collections historiques (`books`, `children`,
//     `milestones`), le compteur `aiUsage`, et l'uid de l'utilisateur inscrit
//     dans le `sharedWith` des souvenirs d'autrui.
//
//  2. NON REPRENABLE. Elle parcourait tous les souvenirs un par un en
//     séquentiel sous un budget de 60 s : un gros compte dépassait, renvoyait
//     `500 Suppression incomplète`, et rien ne permettait de reprendre — avec
//     le risque que le compte d'authentification survive à des données déjà
//     effacées. Elle travaille maintenant par TOURS : chaque appel avance
//     jusqu'à son échéance puis renvoie `{ done: false }`, et l'app rappelle
//     tant que ce n'est pas fini (voir profile_screen.dart::_deleteAccount).
//     Le compte d'authentification part en DERNIER, une fois tout le reste
//     vide.

// Marge de sécurité sous le `maxDuration` de 60 s : on s'arrête à 45 s pour
// avoir le temps de répondre proprement.
const DELETE_BUDGET_MS = 45_000

/** Supprime les documents d'une requête un par un, en s'arrêtant à l'échéance.
 *  Retourne false s'il reste du travail. `onDoc` fait le ménage annexe
 *  (médias R2) avant la suppression du document. */
async function drainQuery(
  query: FirebaseFirestore.Query,
  deadline: number,
  onDoc?: (doc: FirebaseFirestore.QueryDocumentSnapshot) => Promise<void>
): Promise<boolean> {
  // Par paquets : une requête `limit()` relancée à chaque tour évite de
  // charger en mémoire l'historique complet d'un gros compte.
  for (;;) {
    if (Date.now() > deadline) return false
    const snap = await query.limit(50).get()
    if (snap.empty) return true
    for (const doc of snap.docs) {
      if (Date.now() > deadline) return false
      if (onDoc) await onDoc(doc)
      await doc.ref.delete()
    }
  }
}

async function handleDeleteAccount(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }
  const user = await requireAuth(req, res)
  if (!user) return
  const uid = user.uid
  const email = (user.email ?? '').toLowerCase()
  const deadline = Date.now() + DELETE_BUDGET_MS

  try {
    // 1. Souvenirs possédés, avec leurs médias (photos, vidéos, mémo vocal).
    //    Les mesures de croissance en font partie (type 'taille_poids').
    const memoriesDone = await drainQuery(
      db.collection('memories').where('userId', '==', uid),
      deadline,
      async (doc) => {
        const m = doc.data()
        const keys = [...photoKeysOf(m), ...videoKeysOf(m)]
        const audioKey = audioKeyOf(m)
        if (audioKey) keys.push(audioKey)
        await Promise.allSettled(keys.map((k) => deleteObject(k)))
      }
    )
    if (!memoriesDone) return res.status(200).json({ ok: true, done: false, step: 'memories' })

    // 2. Historique des livres générés (PDF + photo de couverture sur R2).
    const booksDone = await drainQuery(
      db.collection('generatedBooks').where('userId', '==', uid),
      deadline,
      async (doc) => {
        const b = doc.data() as Record<string, unknown>
        const keys = [b.storagePath, b.coverPhotoKey].filter(
          (k): k is string => typeof k === 'string' && k.length > 0
        )
        await Promise.allSettled(keys.map((k) => deleteObject(k)))
      }
    )
    if (!booksDone) return res.status(200).json({ ok: true, done: false, step: 'generatedBooks' })

    // 3. Brouillons de l'éditeur de livre : ils portent les textes saisis et
    //    les clés des photos mises en page. Oubliés jusqu'au 01.10.26.
    const draftsDone = await drainQuery(
      db.collection('bookDrafts').where('userId', '==', uid),
      deadline
    )
    if (!draftsDone) return res.status(200).json({ ok: true, done: false, step: 'bookDrafts' })

    // 4. Collections historiques (avant les tags) : histoires, enfants et
    //    jalons. Elles ne sont plus alimentées mais contiennent des données
    //    personnelles pour les comptes anciens.
    const legacyBooksDone = await drainQuery(
      db.collection('books').where('userId', '==', uid),
      deadline
    )
    if (!legacyBooksDone) return res.status(200).json({ ok: true, done: false, step: 'books' })

    const childrenSnap = await db
      .collection('children')
      .where('parentId', '==', uid)
      .get()
    for (const child of childrenSnap.docs) {
      const milestonesDone = await drainQuery(
        db.collection('milestones').where('childId', '==', child.id),
        deadline
      )
      if (!milestonesDone) {
        return res.status(200).json({ ok: true, done: false, step: 'milestones' })
      }
      await child.ref.delete()
    }

    // 5. Commandes : médias supprimés, données personnelles anonymisées (voir
    //    commentaire au-dessus de la fonction).
    const ordersSnap = await db.collection('orders').where('userId', '==', uid).get()
    for (const doc of ordersSnap.docs) {
      if (Date.now() > deadline) {
        return res.status(200).json({ ok: true, done: false, step: 'orders' })
      }
      const o = doc.data() as Record<string, unknown>
      if (o.accountDeleted === true) continue // déjà traitée à un tour précédent
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

    // 6. Tags : ceux possédés sont supprimés ; sur ceux des autres, on retire
    //    juste l'utilisateur de `sharedWith` (ne touche pas aux données d'autrui).
    const ownedTagsDone = await drainQuery(
      db.collection('tags').where('userId', '==', uid),
      deadline
    )
    if (!ownedTagsDone) return res.status(200).json({ ok: true, done: false, step: 'tags' })

    const sharedTagsSnap = await db
      .collection('tags')
      .where('sharedWith', 'array-contains', uid)
      .get()
    for (const doc of sharedTagsSnap.docs) {
      await doc.ref.update({ sharedWith: FieldValue.arrayRemove(uid) })
    }

    // 7. Carnets (espaces) : même logique.
    const ownedNbDone = await drainQuery(
      db.collection('notebooks').where('userId', '==', uid),
      deadline
    )
    if (!ownedNbDone) return res.status(200).json({ ok: true, done: false, step: 'notebooks' })

    const sharedNbSnap = await db
      .collection('notebooks')
      .where('sharedWith', 'array-contains', uid)
      .get()
    for (const doc of sharedNbSnap.docs) {
      const update: Record<string, unknown> = { sharedWith: FieldValue.arrayRemove(uid) }
      if (email) update.invitedEmails = FieldValue.arrayRemove(email)
      await doc.ref.update(update)
    }

    // 8. L'uid ne doit pas rester inscrit dans les souvenirs D'AUTRUI qu'on
    //    nous avait partagés : c'est un identifiant personnel résiduel, et il
    //    continuerait d'accorder un accès si le même uid réapparaissait.
    //    Oublié jusqu'au 01.10.26.
    for (;;) {
      if (Date.now() > deadline) {
        return res.status(200).json({ ok: true, done: false, step: 'sharedMemories' })
      }
      const snap = await db
        .collection('memories')
        .where('sharedWith', 'array-contains', uid)
        .limit(200)
        .get()
      if (snap.empty) break
      const batch = db.batch()
      for (const doc of snap.docs) {
        batch.update(doc.ref, { sharedWith: FieldValue.arrayRemove(uid) })
      }
      await batch.commit()
    }

    // 9. Reels vidéo (QR imprimés), invitations émises (carnets ET tags), et
    //    liens de partage encore vivants. Les `tagInvites` et les `shares`
    //    étaient oubliés : un lien de partage restait ouvert jusqu'à sept
    //    jours après la suppression du compte.
    const reelsDone = await drainQuery(
      db.collection('posterReels').where('userId', '==', uid),
      deadline
    )
    if (!reelsDone) return res.status(200).json({ ok: true, done: false, step: 'posterReels' })

    const nbInvitesDone = await drainQuery(
      db.collection('notebookInvites').where('createdBy', '==', uid),
      deadline
    )
    if (!nbInvitesDone) return res.status(200).json({ ok: true, done: false, step: 'notebookInvites' })

    const tagInvitesDone = await drainQuery(
      db.collection('tagInvites').where('createdBy', '==', uid),
      deadline
    )
    if (!tagInvitesDone) return res.status(200).json({ ok: true, done: false, step: 'tagInvites' })

    const sharesDone = await drainQuery(
      db.collection('shares').where('ownerUid', '==', uid),
      deadline
    )
    if (!sharesDone) return res.status(200).json({ ok: true, done: false, step: 'shares' })

    // 10. Fil d'activité : celles dont on est l'auteur partent, et on se
    //     retire des destinataires des autres (le champ porte notre uid).
    const myActivitiesDone = await drainQuery(
      db.collection('memoryActivities').where('actorUid', '==', uid),
      deadline
    )
    if (!myActivitiesDone) {
      return res.status(200).json({ ok: true, done: false, step: 'memoryActivities' })
    }

    for (;;) {
      if (Date.now() > deadline) {
        return res.status(200).json({ ok: true, done: false, step: 'activityRecipients' })
      }
      const snap = await db
        .collection('memoryActivities')
        .where('recipients', 'array-contains', uid)
        .limit(200)
        .get()
      if (snap.empty) break
      const batch = db.batch()
      for (const doc of snap.docs) {
        batch.update(doc.ref, {
          recipients: FieldValue.arrayRemove(uid),
          seenBy: FieldValue.arrayRemove(uid),
        })
      }
      await batch.commit()
    }

    // 11. Compteurs et verrous techniques nominatifs.
    await db.collection('aiUsage').doc(uid).delete().catch(() => {})
    if (email) {
      await db
        .collection('passwordResetThrottle')
        .doc(email)
        .delete()
        .catch(() => {})
    }

    // 12. Profil, puis le compte d'authentification lui-même — en DERNIER,
    //     une fois tout le reste vide : tant qu'il existe, l'utilisateur peut
    //     se reconnecter et relancer un tour pour finir le travail.
    await db.collection('users').doc(uid).delete().catch(() => {})
    await auth.deleteUser(uid)

    return res.status(200).json({ ok: true, done: true })
  } catch (e) {
    // Un échec n'est plus définitif : l'appelant peut relancer, chaque tour
    // reprend là où le précédent s'est arrêté.
    return res
      .status(500)
      .json({ error: `Suppression interrompue, relance pour continuer : ${e}` })
  }
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'invite') return handleInvite(req, res)
  if (action === 'join') return handleJoin(req, res)
  if (action === 'delete-account') return handleDeleteAccount(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
