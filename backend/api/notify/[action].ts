import type { VercelRequest, VercelResponse } from '@vercel/node'
import { FieldValue } from 'firebase-admin/firestore'
import { requireAuth } from '../../lib/verify'
import { auth, db } from '../../lib/firebase'
import { deleteObject, presignGet } from '../../lib/r2'
import { sendEmail, ADMIN_EMAIL } from '../../lib/resend'
import { row, wrap } from '../email/order'

// URLs :
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
//   POST /api/notify/share-apk     → l'ADMIN envoie le lien d'installation
//                                    Android à un ou plusieurs emails (amis,
//                                    famille, collègues) — console admin,
//                                    bouton "Partager l'app". Réservé à
//                                    ADMIN_EMAIL comme prodigi/video.
//
// Regroupé en route dynamique comme prodigi/tag/video : le plan Hobby de Vercel
// plafonne à 12 fonctions serverless.

function authorized(req: VercelRequest): boolean {
  const secret = process.env.CRON_SECRET
  const auth = req.headers.authorization ?? ''
  return Boolean(secret) && auth === `Bearer ${secret}`
}

function toDate(value: unknown): Date | null {
  if (!value) return null
  // Timestamp Firestore ou nombre (ms).
  const anyValue = value as { toDate?: () => Date }
  if (typeof anyValue.toDate === 'function') return anyValue.toDate()
  if (typeof value === 'number') return new Date(value)
  return null
}

/** Rappel admin quotidien : commandes reçues (`status === 'received'`) mais
 * pas encore marquées payées — « en attente de validation ». Un seul mail
 * récapitulatif (pas un par commande), envoyé seulement s'il y en a au moins
 * une — pas de mail vide tous les jours pour dire "rien à signaler". */
async function handleOrdersPending(req: VercelRequest, res: VercelResponse) {
  if (!authorized(req)) return res.status(401).json({ error: 'Unauthorized' })

  // Deux catégories distinctes, toutes deux "bloquées sur une action admin" :
  // - 'received' : le client n'a pas encore payé (ou l'admin n'a pas encore
  //   marqué le paiement reçu).
  // - 'paid' sans prodigiOrderId : payée mais jamais transmise à Prodigi —
  //   trou de suivi découvert à l'audit du 15.09.26, ce cas n'était avant
  //   couvert par AUCUN rappel automatique et pouvait rester invisible
  //   indéfiniment si l'admin oubliait de l'envoyer à l'impression.
  const [receivedSnap, paidSnap] = await Promise.all([
    db.collection('orders').where('status', '==', 'received').get(),
    db.collection('orders').where('status', '==', 'paid').get(),
  ])
  const unsentPaidDocs = paidSnap.docs.filter((d) => !d.data().prodigiOrderId)

  if (receivedSnap.empty && unsentPaidDocs.length === 0) {
    return res.status(200).json({ ok: true, pending: 0, sent: false })
  }

  const now = Date.now()
  const toRow = (d: FirebaseFirestore.QueryDocumentSnapshot, stage: string) => {
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
      stage,
    }
  }

  const rows = [
    ...receivedSnap.docs.map((d) => toRow(d, 'en attente de validation')),
    ...unsentPaidDocs.map((d) => toRow(d, 'payée, pas encore envoyée à l\'impression')),
  ]
    // La plus ancienne (donc la plus urgente) en premier.
    .sort((a, b) => (b.days ?? 0) - (a.days ?? 0))

  const listHtml = rows
    .map((r) =>
      row(
        `<strong>${r.ref}</strong>`,
        `${r.name} · ${r.item} · ${r.price} · ${r.stage}` +
          (r.days !== null ? ` · depuis ${r.days} j` : '')
      )
    )
    .join('')

  const count = rows.length
  const unsentPaidCount = unsentPaidDocs.length
  const html = wrap(`
    <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">
      ⏳ ${count} commande${count > 1 ? 's' : ''} en attente d'une action — n'attends pas !
    </p>
    ${listHtml}
    <p style="margin:20px 0 0;font-size:13px;color:#888;line-height:1.6;">
      Une commande « en attente de validation » : marque-la « payée » dans
      l'app pour lancer l'impression.${
        unsentPaidCount > 0
          ? ` Une commande « payée, pas encore envoyée » : le paiement est
      confirmé mais elle n'a pas (encore) été transmise à Prodigi — envoie-la
      depuis la console admin.`
          : ''
      } Ce rappel revient chaque jour tant qu'une commande reste bloquée.
    </p>
  `)

  const sent = await sendEmail({
    to: ADMIN_EMAIL,
    subject: `⏳ ${count} commande${count > 1 ? 's' : ''} en attente d'une action`,
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

/** Lien d'installation public de l'APK — le même que celui utilisé pour le
 * propre téléchargement de l'admin (voir STATUS.md / mémoire du projet),
 * republié automatiquement à chaque build CI. Pas de secret ici : le fichier
 * est déjà public, seul l'ENVOI par email est réservé à l'admin. */
const APK_DOWNLOAD_URL = 'https://dmathys.dev/download/carnet.apk'
// Borne large mais raisonnable : un envoi groupé n'a pas vocation à devenir
// une liste de diffusion (chaque destinataire déclenche un appel Resend).
const MAX_SHARE_RECIPIENTS = 30

async function handleShareApk(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' })
  const user = await requireAuth(req, res)
  if (!user) return
  if (user.email !== ADMIN_EMAIL) {
    return res.status(403).json({ error: 'Accès refusé' })
  }

  const rawEmails = req.body?.emails
  const emails = Array.from(
    new Set(
      (Array.isArray(rawEmails) ? rawEmails : [])
        .map((e) => String(e).trim().toLowerCase())
        .filter((e) => e.includes('@'))
    )
  )
  if (emails.length === 0) {
    return res.status(400).json({ error: 'Aucun email valide' })
  }
  if (emails.length > MAX_SHARE_RECIPIENTS) {
    return res.status(400).json({ error: `Maximum ${MAX_SHARE_RECIPIENTS} destinataires à la fois` })
  }

  const note = typeof req.body?.message === 'string' ? req.body.message.trim() : ''

  const html = wrap(`
    <p style="margin:0 0 20px;font-size:16px;color:#2d2d2d;">
      📖 On te partage <strong>Carnet</strong>, l'app pour garder les souvenirs de famille.
    </p>
    ${
      note
        ? `<p style="margin:0 0 20px;font-size:14px;color:#555;line-height:1.6;">${note.replace(/\n/g, '<br/>')}</p>`
        : ''
    }
    <p style="margin:0 0 20px;">
      <a href="${APK_DOWNLOAD_URL}"
         style="display:inline-block;background:#4a7c59;color:#fff;padding:12px 24px;
                border-radius:8px;text-decoration:none;font-weight:600;">
        Installer Carnet (Android)
      </a>
    </p>
    <p style="margin:0;font-size:13px;color:#888;line-height:1.6;">
      L'appli n'est pas encore sur le Play Store — Android peut demander
      d'autoriser l'installation depuis cette source la première fois, c'est
      normal.
    </p>
  `)

  const results = await Promise.all(
    emails.map(async (to) => ({
      to,
      sent: await sendEmail({ to, subject: '📖 Découvre Carnet', html }),
    }))
  )
  const sent = results.filter((r) => r.sent).map((r) => r.to)
  const failed = results.filter((r) => !r.sent).map((r) => r.to)

  return res.status(200).json({ ok: failed.length === 0, sent, failed })
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const action = (req.query.action ?? '') as string

  if (action === 'orders-pending') return handleOrdersPending(req, res)
  if (action === 'order-received') return handleOrderReceived(req, res)
  if (action === 'reset-password') return handleResetPassword(req, res)
  if (action === 'order-cancel') return handleOrderCancel(req, res)
  if (action === 'share-apk') return handleShareApk(req, res)

  return res.status(404).json({ error: 'Action inconnue' })
}
