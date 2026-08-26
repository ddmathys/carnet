import { db } from './firebase'
import { FieldValue, Timestamp } from 'firebase-admin/firestore'
import { sendEmail, ADMIN_EMAIL } from './resend'
import { escapeHtml } from './verify'
import {
  parseProdigiOrder,
  isShipmentDispatched,
  type ProdigiOrderSnapshot,
} from './prodigi_parse'

// Le parsing des réponses Prodigi vit dans `prodigi_parse.ts` (module pur,
// testable sans Firebase) et est réexporté ici pour que les appelants n'aient
// qu'un seul point d'entrée.
export * from './prodigi_parse'

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

/** Chaîne non vide, ou null — pour ne jamais afficher un champ Prodigi absent. */
const str = (v: unknown): string | null =>
  typeof v === 'string' && v.trim() !== '' ? v.trim() : null

export async function fetchProdigiOrderStatus(
  prodigiOrderId: string,
  apiKey: string,
  destinationCountry: string | null = null
): Promise<ProdigiOrderSnapshot> {
  const res = await fetch(
    `${PRODIGI_API_URL}/orders/${encodeURIComponent(prodigiOrderId)}`,
    { headers: { 'X-API-Key': apiKey } }
  )
  const fullText = await res.text()
  // 1000 caractères ne suffisaient plus dès qu'une commande a des colis et des
  // charges : la réponse était tronquée avant les infos de suivi, et le champ
  // ne servait plus à rien pour diagnostiquer.
  const raw = fullText.slice(0, 4000)
  let data: any = null
  try {
    data = JSON.parse(fullText)
  } catch {
    /* réponse non-JSON — on garde raw pour diagnostic */
  }

  return parseProdigiOrder(data, res.ok, res.status, raw, destinationCountry)
}

/** ISO 2 lettres de la destination, pour choisir le bon suivi transporteur. */
function destinationIso(o: Record<string, any>): string | null {
  const map: Record<string, string> = {
    suisse: 'CH', switzerland: 'CH', schweiz: 'CH', svizzera: 'CH',
    france: 'FR', belgique: 'BE', belgium: 'BE',
    allemagne: 'DE', germany: 'DE', deutschland: 'DE',
    luxembourg: 'LU', italie: 'IT', italy: 'IT', italia: 'IT',
    espagne: 'ES', spain: 'ES',
  }
  const key = String(o.country ?? '').trim().toLowerCase()
  if (map[key]) return map[key]
  if (/^[a-z]{2}$/i.test(key)) return key.toUpperCase()
  return null
}

/**
 * Relit le statut réel d'UNE commande chez Prodigi et met Firestore à jour :
 * statut d'impression, étapes de fabrication, colis + numéros de suivi, coûts
 * réellement facturés.
 *
 * Les deux drapeaux de retour ne passent à `true` qu'au moment de la PREMIÈRE
 * détection (erreur, expédition), pour n'envoyer chaque email qu'une fois.
 */
export async function refreshProdigiOrderStatus(
  orderId: string
): Promise<{ newlyErrored: boolean; newlyShipped: boolean }> {
  const apiKey = process.env.PRODIGI_API_KEY
  if (!apiKey) return { newlyErrored: false, newlyShipped: false }

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return { newlyErrored: false, newlyShipped: false }
  const o = snap.data() as Record<string, any>
  const prodigiOrderId = o.prodigiOrderId as string | undefined
  if (!prodigiOrderId) return { newlyErrored: false, newlyShipped: false }

  const wasErrored = o.prodigiStatus === 'error'
  const wasShipped = o.prodigiStatus === 'shipped'
  const result = await fetchProdigiOrderStatus(prodigiOrderId, apiKey, destinationIso(o))

  const dispatched = result.shipments.filter(isShipmentDispatched)
  const first = dispatched[0] ?? null

  const update: Record<string, any> = {
    prodigiStatus: result.prodigiStatus,
    prodigiStage: result.stage,
    prodigiStageDetails: result.stageDetails,
    prodigiError: result.refusalReason,
    prodigiRawStatus: result.raw,
    prodigiShipments: result.shipments,
    prodigiLastCheckedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }

  // Raccourcis de premier niveau : le colis principal, pour que l'app et les
  // emails n'aient pas à fouiller le tableau.
  if (first) {
    update.trackingNumber = first.trackingNumber
    update.trackingUrl = first.trackingUrl
    update.carrierName = first.carrier
    update.shippedFromCountry = first.fromCountry
    const parsed = first.dispatchedAt ? new Date(first.dispatchedAt) : null
    if (parsed && !Number.isNaN(parsed.getTime())) {
      update.shippedAt = Timestamp.fromDate(parsed)
    } else if (!o.shippedAt) {
      update.shippedAt = FieldValue.serverTimestamp()
    }
  }

  if (result.charges) {
    update.prodigiChargedTotal = result.charges.total
    update.prodigiChargedCurrency = result.charges.currency
    update.prodigiChargedItems = result.charges.items
    update.prodigiChargedShipping = result.charges.shipping
    update.prodigiChargedTax = result.charges.tax
  }

  // Le suivi client (received → paid → shipped) n'avançait que par une action
  // admin manuelle : une commande partie depuis des jours restait affichée
  // « Payée ». Prodigi fait maintenant foi dès qu'un colis est parti.
  if (result.prodigiStatus === 'shipped' && o.status === 'paid') {
    update.status = 'shipped'
  }

  await ref.update(update)

  // L'email « votre colis est parti » ne doit partir qu'une fois : le cron
  // quotidien et le rafraîchissement déclenché à l'ouverture de l'app peuvent
  // se croiser sur la même commande. Comparer `wasShipped` ne suffit pas (les
  // deux appels lisent l'ancien état avant que l'un écrive) — d'où une
  // transaction qui pose un drapeau et n'en laisse gagner qu'un.
  const newlyShipped =
    result.prodigiStatus === 'shipped' && !wasShipped
      ? await claimShipmentNotification(orderId)
      : false

  return {
    newlyErrored: result.prodigiStatus === 'error' && !wasErrored,
    newlyShipped,
  }
}

/**
 * Pose `shippedNotifiedAt` si personne ne l'a encore fait, et dit à l'appelant
 * s'il vient de le gagner. `true` au plus une fois dans la vie d'une commande.
 */
async function claimShipmentNotification(orderId: string): Promise<boolean> {
  const ref = db.collection('orders').doc(orderId)
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref)
    if (!snap.exists || snap.get('shippedNotifiedAt')) return false
    tx.update(ref, { shippedNotifiedAt: FieldValue.serverTimestamp() })
    return true
  })
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

/**
 * Email client « votre colis est parti », envoyé une seule fois, au moment où
 * Prodigi signale la première expédition. Contient le numéro de suivi et le
 * lien transporteur — jusqu'ici l'info n'existait nulle part côté client.
 */
export async function notifyCustomerOfShipment(orderId: string): Promise<void> {
  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return
  const o = snap.data() as Record<string, any>
  const to = String(o.userEmail ?? '')
  if (!to) return

  const ref = `#${orderId.slice(0, 8).toUpperCase()}`
  const isPoster = o.productType === 'poster'
  const title = escapeHtml(
    isPoster ? `Tirage ${String(o.posterSize ?? '')}` : String(o.bookTitle ?? '')
  )
  const firstName = escapeHtml(String(o.firstName ?? ''))
  const trackingNumber = str(o.trackingNumber)
  const trackingUrl = str(o.trackingUrl)
  const carrier = str(o.carrierName)

  const trackingBlock = trackingNumber
    ? `<p style="margin:0 0 8px;font-size:14px;color:#2d2d2d;">
         📮 Numéro de suivi : <strong>${escapeHtml(trackingNumber)}</strong>
         ${carrier ? ` (${escapeHtml(carrier)})` : ''}
       </p>
       ${
         trackingUrl
           ? `<p style="margin:0;font-size:14px;"><a href="${escapeHtml(trackingUrl)}" style="color:#3A6648;">Suivre mon colis →</a></p>`
           : ''
       }`
    : `<p style="margin:0;font-size:14px;color:#2d2d2d;">Le numéro de suivi arrivera d'ici peu.</p>`

  await Promise.all([
    sendEmail({
      to,
      subject: `📦 Votre commande ${ref} est en route`,
      html: `<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"/></head>
<body style="margin:0;background:#f5ece0;font-family:Arial,sans-serif;padding:32px 0;">
  <table width="520" align="center" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:16px;overflow:hidden;">
    <tr><td style="background:#3A6648;padding:24px 32px;">
      <p style="margin:0;font-size:22px;font-weight:bold;color:#FFF8E8;font-style:italic;">carnet</p>
    </td></tr>
    <tr><td style="padding:28px 32px;">
      <p style="margin:0 0 16px;font-size:16px;color:#2d2d2d;">Bonjour ${firstName},</p>
      <p style="margin:0 0 20px;font-size:15px;color:#2d2d2d;line-height:1.6;">
        Bonne nouvelle : <strong>« ${title} »</strong> a quitté l'atelier d'impression.
      </p>
      <table width="100%" style="background:#f5ece0;border-radius:12px;">
        <tr><td style="padding:18px 22px;">${trackingBlock}</td></tr>
      </table>
      <p style="margin:20px 0 0;font-size:13px;color:#888;line-height:1.6;">
        Le suivi peut mettre quelques heures à s'activer chez le transporteur.
        Commande ${ref}.
      </p>
    </td></tr>
  </table>
</body></html>`,
    }),
    sendEmail({
      to: ADMIN_EMAIL,
      subject: `📦 ${ref} expédiée${trackingNumber ? ` — ${trackingNumber}` : ''}`,
      html: `<p>Commande ${ref} (${title}) expédiée par Prodigi.</p>
             <p>Suivi : ${trackingNumber ? escapeHtml(trackingNumber) : '—'} ${carrier ? `(${escapeHtml(carrier)})` : ''}</p>`,
    }),
  ])
}
