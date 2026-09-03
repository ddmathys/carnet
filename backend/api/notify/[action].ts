import type { VercelRequest, VercelResponse } from '@vercel/node'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { auth, db, messaging } from '../../lib/firebase'
import { deleteObject, presignGet } from '../../lib/r2'
import { sendEmail, ADMIN_EMAIL } from '../../lib/resend'
import { row, wrap } from '../email/order'

// « Souvenir du jour » : la notification qui ressort une photo au hasard, façon
// Google Photos. URLs :
//   GET  /api/notify/cron          → balaie les utilisateurs abonnés et envoie (cron only)
//   GET  /api/notify/test          → même chose pour UN utilisateur, envoi immédiat
//                                    (diagnostic admin, protégé par CRON_SECRET)
//   POST /api/notify/send-now      → même chose pour SOI-MÊME (bouton "Envoyer
//                                    maintenant" du profil), protégé par le token
//                                    Firebase de l'utilisateur — pas de CRON_SECRET
//                                    côté client.
//   GET  /api/notify/orders-pending → rappel admin quotidien (mail) : commandes
//                                    reçues mais pas encore marquées payées —
//                                    pour ne pas laisser un client sans réponse
//                                    (cron only, voir vercel.json).
//   POST /api/notify/order-received → le CLIENT confirme avoir reçu sa
//                                    commande expédiée (bouton "J'ai bien
//                                    reçu ma commande" sur le suivi) — passe
//                                    la commande en statut 'archived' et
//                                    prévient l'admin par mail.
//   POST /api/notify/reset-password → lien de réinitialisation de mot de
//                                    passe, envoyé via Resend au lieu du
//                                    relai email par défaut de Firebase Auth
//                                    (peu fiable — atterrit souvent en spam
//                                    ou n'arrive jamais, domaine d'envoi
//                                    partagé entre des millions de projets
//                                    Firebase). Non authentifié (l'utilisateur
//                                    n'est PAS connecté à ce moment) — ne
//                                    JAMAIS révéler si le compte existe.
//                                    Throttlé par email (voir RESET_THROTTLE_MS)
//                                    pour empêcher le spam d'un email arbitraire
//                                    (trouvé à l'audit sécurité du 03.09.26).
//   POST /api/notify/order-cancel  → le CLIENT annule sa commande avant
//                                    paiement (bouton "Annuler la commande").
//                                    Authentifiée, vérifie ownership + statut
//                                    'received'. Remplace un delete Firestore
//                                    direct côté client, bloqué par les règles
//                                    (orders : delete admin-only) — le bouton
//                                    était cassé pour un vrai client (trouvé à
//                                    l'audit UX du 03.09.26).
//
// Regroupé en route dynamique comme prodigi/tag/video : le plan Hobby de Vercel
// plafonne à 12 fonctions serverless.

// Envoyé le dimanche pour les abonnés « hebdomadaire » (0 = dimanche).
const WEEKLY_DAY = 0
// Plafond de souvenirs relus par utilisateur : borne le coût en lectures
// Firestore (une lecture par souvenir, chaque matin).
//
// Limite connue : au-delà de ce plafond, Firestore renvoie toujours le même
// sous-ensemble (ordre par id de document), donc les souvenirs au-delà ne
// sortiront jamais en notification. Tant qu'un carnet tient sous 500 souvenirs,
// aucune importance. Pour lever ça proprement il faudrait un champ « random »
// sur chaque souvenir (donc une migration) — à faire le jour où ça se voit.
const MAX_MEMORIES_SCANNED = 500

interface Candidate {
  id: string
  title: string
  date: Date | null
  mediaKey: string | null
  mediaUrl: string | null
}

/** Formule « Il y a 3 ans », ou la date si le souvenir est récent. */
function whenLabel(date: Date | null, now: Date): string {
  if (!date) return 'Un souvenir'
  const years = now.getFullYear() - date.getFullYear()
  const sameDay =
    date.getDate() === now.getDate() && date.getMonth() === now.getMonth()
  if (sameDay && years >= 1) {
    return years === 1 ? 'Il y a un an, jour pour jour' : `Il y a ${years} ans, jour pour jour`
  }
  if (years >= 1) return years === 1 ? 'Il y a un an' : `Il y a ${years} ans`
  return 'Ce souvenir'
}

function toDate(value: unknown): Date | null {
  if (!value) return null
  // Timestamp Firestore ou nombre (ms).
  const anyValue = value as { toDate?: () => Date }
  if (typeof anyValue.toDate === 'function') return anyValue.toDate()
  if (typeof value === 'number') return new Date(value)
  return null
}

/**
 * Tire un souvenir pour l'utilisateur. On privilégie les ANNIVERSAIRES (même
 * jour et même mois, une année précédente) — c'est ce qui rend la notification
 * touchante plutôt qu'arbitraire ; à défaut, tirage au hasard.
 *
 * Un souvenir sans média est écarté : une notification « souvenir » sans image
 * n'a pas grand intérêt.
 */
async function pickMemory(uid: string, now: Date): Promise<Candidate | null> {
  // ⚠️ PAS de `orderBy` ici, volontairement : `where(userId) + orderBy(autre
  // champ)` exige un index composite, et ce projet n'en déclare aucun (voir le
  // commentaire de `memory_query_service.dart`, qui trie côté client pour la
  // même raison). Avec un orderBy, ce cron échouerait en FAILED_PRECONDITION —
  // en silence, tous les matins. L'ordre renvoyé importe peu : on tire au sort.
  const snap = await db
    .collection('memories')
    .where('userId', '==', uid)
    .limit(MAX_MEMORIES_SCANNED)
    .select('title', 'date', 'mediaKeys', 'mediaUrls', 'photoUrl')
    .get()

  const candidates: Candidate[] = []
  for (const doc of snap.docs) {
    const d = doc.data() as Record<string, any>
    const keys: string[] = Array.isArray(d.mediaKeys) ? d.mediaKeys : []
    const urls: string[] = Array.isArray(d.mediaUrls) ? d.mediaUrls : []
    const legacy = typeof d.photoUrl === 'string' ? d.photoUrl : ''
    const mediaKey = keys.length > 0 ? String(keys[0]) : null
    const mediaUrl = urls.length > 0 ? String(urls[0]) : legacy || null
    if (!mediaKey && !mediaUrl) continue
    candidates.push({
      id: doc.id,
      title: typeof d.title === 'string' && d.title.trim() ? d.title.trim() : 'Un souvenir',
      date: toDate(d.date),
      mediaKey,
      mediaUrl,
    })
  }
  if (candidates.length === 0) return null

  const anniversaries = candidates.filter(
    (c) =>
      c.date &&
      c.date.getDate() === now.getDate() &&
      c.date.getMonth() === now.getMonth() &&
      c.date.getFullYear() < now.getFullYear()
  )
  const pool = anniversaries.length > 0 ? anniversaries : candidates
  return pool[Math.floor(Math.random() * pool.length)]
}

/** URL d'image affichable dans la notification (R2 signé, ou ancienne URL). */
async function imageUrlFor(memory: Candidate): Promise<string | null> {
  if (memory.mediaKey) {
    try {
      // 6 h : la notification est téléchargée dès sa réception, mais l'appareil
      // peut être éteint un moment — inutile d'être trop juste.
      return await presignGet(memory.mediaKey, 6 * 3600)
    } catch {
      return memory.mediaUrl
    }
  }
  return memory.mediaUrl
}

/** Envoie à tous les appareils d'un utilisateur ; nettoie les jetons morts. */
async function sendToUser(
  uid: string,
  tokens: string[],
  memory: Candidate,
  now: Date
): Promise<{ sent: number; pruned: number }> {
  const image = await imageUrlFor(memory)
  const title = whenLabel(memory.date, now)
  const body = memory.title

  const response = await messaging.sendEachForMulticast({
    tokens,
    notification: { title, body, ...(image ? { imageUrl: image } : {}) },
    // `data` est ce que l'appli lit pour ouvrir le bon souvenir au tap.
    data: { memoryId: memory.id, type: 'memory_of_the_day' },
    android: {
      priority: 'normal',
      notification: {
        channelId: 'souvenirs',
        ...(image ? { imageUrl: image } : {}),
      },
    },
    apns: {
      payload: { aps: { 'mutable-content': 1 } },
      ...(image ? { fcmOptions: { imageUrl: image } } : {}),
    },
  })

  // Jetons révoqués (appli désinstallée, réinstallée) : on les retire, sinon
  // ils s'accumulent indéfiniment dans le document utilisateur.
  const dead: string[] = []
  response.responses.forEach((r, i) => {
    const code = r.error?.code ?? ''
    if (
      code === 'messaging/registration-token-not-registered' ||
      code === 'messaging/invalid-registration-token' ||
      code === 'messaging/invalid-argument'
    ) {
      dead.push(tokens[i])
    }
  })
  if (dead.length > 0) {
    await db
      .collection('users')
      .doc(uid)
      .update({ fcmTokens: FieldValue.arrayRemove(...dead) })
      .catch(() => {})
  }

  return { sent: response.successCount, pruned: dead.length }
}

function authorized(req: VercelRequest): boolean {
  const secret = process.env.CRON_SECRET
  const auth = req.headers.authorization ?? ''
  return Boolean(secret) && auth === `Bearer ${secret}`
}

async function handleCron(req: VercelRequest, res: VercelResponse) {
  if (!authorized(req)) return res.status(401).json({ error: 'Unauthorized' })

  const now = new Date()
  const weekly = now.getDay() === WEEKLY_DAY
  const frequencies = weekly ? ['daily', 'weekly'] : ['daily']

  const snap = await db
    .collection('users')
    .where('notifyFrequency', 'in', frequencies)
    .get()

  let users = 0
  let sent = 0
  let skipped = 0
  for (const doc of snap.docs) {
    const data = doc.data() as Record<string, any>
    const tokens: string[] = Array.isArray(data.fcmTokens)
      ? data.fcmTokens.filter((t: unknown) => typeof t === 'string' && t)
      : []
    if (tokens.length === 0) {
      skipped++
      continue
    }
    try {
      const memory = await pickMemory(doc.id, now)
      // Compte tout neuf, ou aucun souvenir avec photo : rien à raconter.
      if (!memory) {
        skipped++
        continue
      }
      const result = await sendToUser(doc.id, tokens, memory, now)
      users++
      sent += result.sent
      await doc.ref
        .update({ notifyLastSentAt: FieldValue.serverTimestamp() })
        .catch(() => {})
    } catch (e) {
      console.error('[notify/cron] user', doc.id, e)
    }
  }

  return res.status(200).json({ ok: true, users, sent, skipped })
}

/** Envoi immédiat à un utilisateur précis : `?uid=…`. Pour tester sans attendre. */
async function handleTest(req: VercelRequest, res: VercelResponse) {
  if (!authorized(req)) return res.status(401).json({ error: 'Unauthorized' })

  const uid = (req.query.uid ?? '') as string
  if (!uid) return res.status(400).json({ error: 'Missing uid' })

  const userSnap = await db.collection('users').doc(uid).get()
  if (!userSnap.exists) return res.status(404).json({ error: 'Utilisateur inconnu' })
  const tokens: string[] = (userSnap.data()?.fcmTokens ?? []).filter(
    (t: unknown) => typeof t === 'string' && t
  )
  if (tokens.length === 0) {
    return res.status(400).json({ error: 'Aucun appareil enregistré' })
  }

  const now = new Date()
  const memory = await pickMemory(uid, now)
  if (!memory) return res.status(404).json({ error: 'Aucun souvenir avec photo' })

  const result = await sendToUser(uid, tokens, memory, now)
  return res.status(200).json({ ok: true, memoryId: memory.id, ...result })
}

/** Envoi immédiat à SOI-MÊME (bouton "Envoyer maintenant" du profil, auth
 * Firebase normale — pas de CRON_SECRET côté client). */
async function handleSendNow(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const user = await requireAuth(req, res)
  if (!user) return

  const userSnap = await db.collection('users').doc(user.uid).get()
  const tokens: string[] = (userSnap.data()?.fcmTokens ?? []).filter(
    (t: unknown) => typeof t === 'string' && t
  )
  if (tokens.length === 0) {
    return res.status(400).json({
      error: 'Aucun appareil enregistré — active les notifications d\'abord.',
    })
  }

  const now = new Date()
  const memory = await pickMemory(user.uid, now)
  if (!memory) {
    return res.status(404).json({ error: 'Aucun souvenir avec photo à envoyer' })
  }

  const result = await sendToUser(user.uid, tokens, memory, now)
  await db
    .collection('users')
    .doc(user.uid)
    .update({ notifyLastSentAt: FieldValue.serverTimestamp() })
    .catch(() => {})
  return res.status(200).json({ ok: true, memoryId: memory.id, ...result })
}

/** Rappel admin quotidien : commandes reçues (`status === 'received'`) mais
 * pas encore marquées payées — « en attente de validation ». Un seul mail
 * récapitulatif (pas un par commande), envoyé seulement s'il y en a au moins
 * une — pas de mail vide tous les jours pour dire "rien à signaler". */
async function handleOrdersPending(req: VercelRequest, res: VercelResponse) {
  if (!authorized(req)) return res.status(401).json({ error: 'Unauthorized' })

  const snap = await db.collection('orders').where('status', '==', 'received').get()
  if (snap.empty) return res.status(200).json({ ok: true, pending: 0, sent: false })

  const now = Date.now()
  const rows = snap.docs
    .map((d) => {
      const o = d.data() as Record<string, any>
      const createdAt = toDate(o.createdAt)
      const days = createdAt ? Math.floor((now - createdAt.getTime()) / 86400000) : null
      return {
        ref: `#${d.id.slice(0, 8).toUpperCase()}`,
        name: `${o.firstName ?? ''} ${o.lastName ?? ''}`.trim() || '—',
        item:
          o.productType === 'poster'
            ? `Tirage ${String(o.posterSize ?? '')}`
            : String(o.bookTitle ?? 'Livre'),
        price: `CHF ${Number(o.price ?? 0).toFixed(2)}`,
        days,
      }
    })
    // La plus ancienne (donc la plus urgente) en premier.
    .sort((a, b) => (b.days ?? 0) - (a.days ?? 0))

  const listHtml = rows
    .map((r) =>
      row(
        `<strong>${r.ref}</strong>`,
        `${r.name} · ${r.item} · ${r.price}` +
          (r.days !== null ? ` · depuis ${r.days} j` : '')
      )
    )
    .join('')

  const count = rows.length
  const html = wrap(`
    <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">
      ⏳ ${count} commande${count > 1 ? 's' : ''} en attente de validation — n'attends pas !
    </p>
    ${listHtml}
    <p style="margin:20px 0 0;font-size:13px;color:#888;line-height:1.6;">
      Une fois le paiement reçu, marque la commande « payée » dans l'app pour
      lancer l'impression. Ce rappel revient chaque jour tant qu'une commande
      reste en attente.
    </p>
  `)

  const sent = await sendEmail({
    to: ADMIN_EMAIL,
    subject: `⏳ ${count} commande${count > 1 ? 's' : ''} en attente de validation`,
    html,
  })

  return res.status(200).json({ ok: true, pending: count, sent })
}

/** Le client confirme avoir reçu sa commande expédiée : passe la commande en
 * 'archived' (elle sort de la bannière "commandes en cours" du dashboard) et
 * prévient l'admin par mail — la console admin affiche ensuite le nouveau
 * statut sans action manuelle nécessaire. Refuse si la commande n'appartient
 * pas à l'appelant, ou si elle n'est pas (encore) au statut 'shipped' — on ne
 * veut pas qu'un client archive une commande pas encore expédiée par erreur. */
async function handleOrderReceived(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const user = await requireAuth(req, res)
  if (!user) return

  const orderId = (req.body?.orderId ?? '') as string
  if (!orderId) return res.status(400).json({ error: 'Missing orderId' })

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return res.status(404).json({ error: 'Commande introuvable' })
  const order = snap.data() as Record<string, any>
  if (order.userId !== user.uid) {
    return res.status(403).json({ error: 'Cette commande ne t\'appartient pas' })
  }
  if (order.status !== 'shipped') {
    return res.status(400).json({ error: 'Cette commande n\'est pas (encore) expédiée' })
  }

  await ref.update({
    status: 'archived',
    archivedAt: FieldValue.serverTimestamp(),
    archivedBy: 'client',
    updatedAt: FieldValue.serverTimestamp(),
  })

  const ref8 = `#${orderId.slice(0, 8).toUpperCase()}`
  const item =
    order.productType === 'poster'
      ? `Tirage ${String(order.posterSize ?? '')}`
      : String(order.bookTitle ?? 'Livre')
  const html = wrap(`
    <p style="margin:0 0 16px;font-size:16px;color:#2d2d2d;">
      ✅ ${item} (${ref8}) confirmée reçue par le client.
    </p>
    ${row('Client', `${order.firstName ?? ''} ${order.lastName ?? ''}`.trim() || order.userEmail || '—')}
    ${row('Commande', ref8)}
    <p style="margin:20px 0 0;font-size:13px;color:#888;line-height:1.6;">
      Statut mis à jour automatiquement en « Archivée » dans la console admin —
      rien à faire de ton côté, sauf si quelque chose cloche.
    </p>
  `)
  const sent = await sendEmail({
    to: ADMIN_EMAIL,
    subject: `✅ Commande ${ref8} reçue par le client`,
    html,
  })

  return res.status(200).json({ ok: true, sent })
}

/** Génère le vrai lien de réinitialisation Firebase (Admin SDK — même
 * mécanisme que l'envoi automatique de Firebase, juste pas son email) et
 * l'envoie via Resend. Réponse 200 identique que le compte existe ou non :
 * révéler l'inexistence d'un compte par ce biais est une fuite classique
 * (email enumeration) — Firebase Auth a la même protection activée sur ce
 * projet (`emailPrivacyConfig.enableImprovedEmailPrivacy`). */
// Un envoi par email toutes les 60s max — sans ça, endpoint public ouvert au
// spam d'un email arbitraire (harcèlement, ou épuisement du quota Resend).
const RESET_THROTTLE_MS = 60_000

async function handleResetPassword(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })

  const email = ((req.body?.email ?? '') as string).trim()
  if (!email || !email.includes('@')) {
    return res.status(400).json({ error: 'Email invalide' })
  }

  // Réponse 200 identique dans TOUS les cas (throttlé, compte inexistant,
  // envoi réussi) — ne jamais laisser deviner l'état réel depuis l'extérieur.
  const throttleRef = db.collection('passwordResetThrottle').doc(email.toLowerCase())
  const throttleSnap = await throttleRef.get()
  const lastSentAt = throttleSnap.data()?.lastSentAt?.toMillis?.() ?? 0
  if (Date.now() - lastSentAt < RESET_THROTTLE_MS) {
    return res.status(200).json({ ok: true })
  }
  await throttleRef.set({ lastSentAt: FieldValue.serverTimestamp() })

  try {
    const link = await auth.generatePasswordResetLink(email)
    const html = wrap(`
      <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">
        Voici ton lien pour réinitialiser ton mot de passe Carnet 👇
      </p>
      <p style="margin:0 0 20px;">
        <a href="${link}"
           style="display:inline-block;background:#4a7c59;color:#fff;padding:12px 24px;
                  border-radius:8px;text-decoration:none;font-weight:600;">
          Réinitialiser mon mot de passe
        </a>
      </p>
      <p style="margin:0;font-size:13px;color:#888;line-height:1.6;">
        Si tu n'es pas à l'origine de cette demande, ignore simplement ce mail —
        rien ne se passera.
      </p>
    `)
    await sendEmail({ to: email, subject: 'Réinitialise ton mot de passe — Carnet', html })
  } catch (e: any) {
    // 'auth/user-not-found' : silencieux, volontaire (voir doc ci-dessus).
    if (e?.code !== 'auth/user-not-found') {
      console.error('[notify/reset-password]', e)
    }
  }

  return res.status(200).json({ ok: true })
}

/** Le client annule sa commande avant paiement — mêmes conditions que le
 * bouton côté app (`status == 'received'`), vérifiées ici aussi puisque
 * l'app ne peut plus faire confiance à ses propres règles Firestore pour
 * ça (delete réservé à l'admin). Supprime le PDF sur R2 (déjà généré à la
 * création de la commande) puis le document. */
async function handleOrderCancel(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const user = await requireAuth(req, res)
  if (!user) return

  const orderId = (req.body?.orderId ?? '') as string
  if (!orderId) return res.status(400).json({ error: 'Missing orderId' })

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return res.status(404).json({ error: 'Commande introuvable' })
  const order = snap.data() as Record<string, any>
  if (order.userId !== user.uid) {
    return res.status(403).json({ error: 'Cette commande ne t\'appartient pas' })
  }
  if (order.status !== 'received') {
    return res.status(400).json({ error: 'Cette commande ne peut plus être annulée' })
  }

  if (typeof order.pdfUrl === 'string' && order.pdfUrl) {
    try {
      const key = new URL(order.pdfUrl).searchParams.get('key')
      if (key) await deleteObject(key)
    } catch {
      // pdfUrl mal formée ou déjà absente sur R2 — pas bloquant, on supprime
      // quand même la commande.
    }
  }
  await ref.delete()

  return res.status(200).json({ ok: true })
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'cron') return handleCron(req, res)
  if (action === 'test') return handleTest(req, res)
  if (action === 'send-now') return handleSendNow(req, res)
  if (action === 'orders-pending') return handleOrdersPending(req, res)
  if (action === 'order-received') return handleOrderReceived(req, res)
  if (action === 'reset-password') return handleResetPassword(req, res)
  if (action === 'order-cancel') return handleOrderCancel(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
