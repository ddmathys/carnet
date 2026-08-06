import { db } from './firebase'
import { FieldValue } from 'firebase-admin/firestore'
import { sendEmail, ADMIN_EMAIL } from './resend'
import { escapeHtml } from './verify'

// Base URL Prodigi : sandbox par défaut (ne facture/fabrique rien), bascule
// en prod via PRODIGI_API_URL (à définir explicitement en env Production
// Vercel une fois la migration validée en sandbox). Source unique — importée
// telle quelle par backend/api/prodigi/[action].ts pour ne jamais diverger.
// Sandbox et Live ont des clés ET des URLs distinctes, non interchangeables —
// PRODIGI_API_KEY doit correspondre à l'environnement pointé ici.
export const PRODIGI_API_URL =
  process.env.PRODIGI_API_URL ?? 'https://api.sandbox.prodigi.com/v4.0'

/** Erreur HTTP typée, utilisée pour sortir proprement d'une transaction Firestore. */
export class HttpError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

type ProdigiStatus = 'error' | 'accepted' | 'pending'

// Contrairement à Gelato, la création de commande Prodigi (POST /v4.0/orders)
// se fait en un seul appel, sans brouillon à confirmer manuellement — mais
// reste ASYNCHRONE derrière ce 200 : confirmé en sandbox le 06.08.26, une
// commande créée reste `status.stage: "InProgress"` pendant que Prodigi
// télécharge le PDF, alloue un atelier de production, etc. (mêmes étapes que
// `status.details` : downloadAssets → printReadyAssetsPrepared →
// allocateProductionLocation → inProduction → shipping, chacune
// NotStarted|InProgress|Complete). ⚠️ Testé aussi : un fichier de test à 2
// pages déclaré avec `pageCount: 41` (bien en-dessous du minimum 20 pages du
// produit) a été accepté SANS erreur et est passé directement en
// `inProduction` — Prodigi ne semble PAS valider le nombre de pages
// déclaré vs. réel ni le respect des bornes produit, au moins en sandbox.
// Notre propre validation cliente (page count pair, bornes min/max) reste
// donc le SEUL vrai garde-fou, pas une redondance avec Prodigi.
//
// Forme de réponse confirmée : `order.status.stage` (string, seule valeur
// vue : "InProgress" — les valeurs terminales exactes ne sont pas confirmées,
// pas réussi à provoquer une vraie erreur en sandbox dans le temps testé) et
// `order.status.issues` (array, vide dans tous les tests). La forme d'un
// `issue` non vide reste donc INCONNUE — `refusalReason` ci-dessous reste
// défensif (essaie plusieurs noms de champ, sinon stringifie l'objet brut).
export async function fetchProdigiOrderStatus(
  prodigiOrderId: string,
  apiKey: string
): Promise<{
  prodigiStatus: ProdigiStatus
  refusalReason: string | null
  raw: string
}> {
  const res = await fetch(
    `${PRODIGI_API_URL}/orders/${encodeURIComponent(prodigiOrderId)}`,
    { headers: { 'X-API-Key': apiKey } }
  )
  const fullText = await res.text()
  const raw = fullText.slice(0, 1000)
  let data: any = null
  try {
    data = JSON.parse(fullText)
  } catch {
    /* réponse non-JSON — on garde raw pour diagnostic */
  }

  const order = data?.order
  const issues: any[] = Array.isArray(order?.status?.issues) ? order.status.issues : []
  const stage: string | undefined = order?.status?.stage
  const shipments: any[] = Array.isArray(order?.shipments) ? order.shipments : []
  const shipped = shipments.some(
    (s) => typeof s?.status === 'string' && /shipped|dispatch/i.test(s.status)
  )
  const details = order?.status?.details ?? {}
  const inProductionDone = details?.inProduction === 'Complete'

  let prodigiStatus: ProdigiStatus
  let refusalReason: string | null = null
  if (!res.ok) {
    prodigiStatus = 'error'
    refusalReason = data?.error?.message ?? data?.errors?.[0]?.message ?? `HTTP ${res.status}`
  } else if (issues.length > 0) {
    prodigiStatus = 'error'
    refusalReason = issues
      .map((i) => i?.description ?? i?.reason ?? i?.errorCode ?? JSON.stringify(i))
      .join(' · ')
  } else if (shipped || inProductionDone || (stage && /complete/i.test(stage))) {
    prodigiStatus = 'accepted'
  } else {
    prodigiStatus = 'pending'
  }

  return { prodigiStatus, refusalReason, raw }
}

/**
 * Relit le statut réel d'UNE commande chez Prodigi et met Firestore à jour.
 * Retourne `newlyErrored: true` seulement au moment où l'erreur est détectée
 * pour la première fois (pour ne notifier l'admin qu'une seule fois).
 */
export async function refreshProdigiOrderStatus(
  orderId: string
): Promise<{ newlyErrored: boolean }> {
  const apiKey = process.env.PRODIGI_API_KEY
  if (!apiKey) return { newlyErrored: false }

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return { newlyErrored: false }
  const o = snap.data() as Record<string, any>
  const prodigiOrderId = o.prodigiOrderId as string | undefined
  if (!prodigiOrderId) return { newlyErrored: false }

  const wasErrored = o.prodigiStatus === 'error'
  const result = await fetchProdigiOrderStatus(prodigiOrderId, apiKey)

  await ref.update({
    prodigiStatus: result.prodigiStatus,
    prodigiError: result.refusalReason,
    prodigiRawStatus: result.raw,
    prodigiLastCheckedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  })

  return { newlyErrored: result.prodigiStatus === 'error' && !wasErrored }
}

/** Email admin, envoyé dès qu'une erreur de commande Prodigi est détectée.
 * Pas de flux de renvoi automatique côté client (voir plan de migration) —
 * l'admin corrige et relance manuellement depuis la console. */
export async function notifyAdminOfError(orderId: string): Promise<void> {
  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return
  const o = snap.data() as Record<string, any>
  const ref = `#${orderId.slice(0, 8).toUpperCase()}`
  const bookTitle = escapeHtml(String(o.bookTitle ?? ''))

  await sendEmail({
    to: ADMIN_EMAIL,
    subject: `⚠️ Prodigi a signalé une erreur sur ${ref}`,
    html: `<p>Commande ${ref} (${bookTitle}) en erreur chez Prodigi.</p><p>Raison : ${escapeHtml(String(o.prodigiError ?? ''))}</p>`,
  })
}
