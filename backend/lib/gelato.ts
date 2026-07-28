import { db } from './firebase'
import { FieldValue } from 'firebase-admin/firestore'
import { sendEmail, ADMIN_EMAIL } from './resend'
import { escapeHtml } from './verify'

const GELATO_ORDER_URL = 'https://order.gelatoapis.com/v4/orders'

/** Erreur HTTP typée, utilisée pour sortir proprement d'une transaction Firestore. */
export class HttpError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

type GelatoStatus = 'refused' | 'accepted' | 'pending'

// Interroge le VRAI statut d'une commande chez Gelato. Contrairement à la
// réponse synchrone de création (POST /v4/orders), qui réussit même pour un
// fichier invalide, un refus prépresse n'apparaît QUE via cet endpoint, après
// coup — seule façon fiable confirmée de diagnostiquer un rejet (voir mémoire
// projet : plusieurs commandes réellement payées refusées après coup, jamais
// détectées avant).
//
// Champs `refusalReason`/`refusalReasonCode` confirmés empiriquement lors de
// diagnostics précédents (endpoints temporaires) ; le nom exact du champ de
// statut global et ses valeurs possibles ne sont PAS documentés par Gelato —
// l'heuristique ci-dessous (accepté = statut au-delà de "draft" sans raison de
// refus) est une hypothèse à affiner si un statut intermédiaire inattendu
// apparaît lors du prochain test réel.
async function fetchGelatoOrderStatus(
  gelatoOrderId: string,
  apiKey: string
): Promise<{
  gelatoStatus: GelatoStatus
  refusalReason: string | null
  refusalReasonCode: string | null
  raw: string
}> {
  const res = await fetch(
    `${GELATO_ORDER_URL}/${encodeURIComponent(gelatoOrderId)}`,
    { headers: { 'X-API-KEY': apiKey } }
  )
  const raw = (await res.text()).slice(0, 1000)
  let data: any = null
  try {
    data = JSON.parse(raw)
  } catch {
    /* réponse non-JSON — on garde raw pour diagnostic */
  }

  const item = data?.items?.[0]
  const refusalReason: string | null =
    data?.refusalReason ?? item?.refusalReason ?? null
  const refusalReasonCode: string | null =
    data?.refusalReasonCode ?? item?.refusalReasonCode ?? null
  const fulfillmentStatus: string | undefined =
    data?.fulfillmentStatus ?? item?.fulfillmentStatus

  let gelatoStatus: GelatoStatus
  if (refusalReason) {
    gelatoStatus = 'refused'
  } else if (fulfillmentStatus && fulfillmentStatus !== 'draft') {
    gelatoStatus = 'accepted'
  } else {
    gelatoStatus = 'pending'
  }

  return { gelatoStatus, refusalReason, refusalReasonCode, raw }
}

/**
 * Relit le statut réel d'UNE commande chez Gelato et met Firestore à jour.
 * Retourne `newlyRefused: true` seulement au moment où le refus est détecté
 * pour la première fois (pour ne notifier le client qu'une seule fois).
 */
export async function refreshGelatoOrderStatus(
  orderId: string
): Promise<{ newlyRefused: boolean }> {
  const apiKey = process.env.GELATO_API_KEY
  if (!apiKey) return { newlyRefused: false }

  const ref = db.collection('orders').doc(orderId)
  const snap = await ref.get()
  if (!snap.exists) return { newlyRefused: false }
  const o = snap.data() as Record<string, any>
  const gelatoOrderId = o.gelatoOrderId as string | undefined
  if (!gelatoOrderId) return { newlyRefused: false }

  const wasRefused = o.gelatoStatus === 'refused'
  const result = await fetchGelatoOrderStatus(gelatoOrderId, apiKey)

  await ref.update({
    gelatoStatus: result.gelatoStatus,
    refusalReason: result.refusalReason,
    refusalReasonCode: result.refusalReasonCode,
    gelatoRawStatus: result.raw,
    gelatoLastCheckedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  })

  return { newlyRefused: result.gelatoStatus === 'refused' && !wasRefused }
}

/** Email client (langage clair) + copie admin, envoyés dès qu'un refus est détecté. */
export async function notifyClientOfRefusal(orderId: string): Promise<void> {
  const snap = await db.collection('orders').doc(orderId).get()
  if (!snap.exists) return
  const o = snap.data() as Record<string, any>
  const userEmail = String(o.userEmail ?? '')
  const ref = `#${orderId.slice(0, 8).toUpperCase()}`
  const bookTitle = escapeHtml(String(o.bookTitle ?? ''))
  const firstName = escapeHtml(String(o.firstName ?? ''))
  const retriesLeft = Math.max(0, 3 - Number(o.gelatoRetryCount ?? 0))

  if (userEmail) {
    const html = wrap(`
      <p style="margin:0 0 16px;font-size:16px;color:#2d2d2d;">Bonjour ${firstName},</p>
      <p style="margin:0 0 20px;font-size:15px;color:#2d2d2d;line-height:1.6;">
        Notre imprimeur n'a pas pu accepter le fichier de votre livre
        <strong>« ${bookTitle} »</strong> (commande ${ref}) — un souci technique de
        mise en page, rien de grave.
      </p>
      <table width="100%" style="background:#fff7e6;border:1px solid #f0d9a0;border-radius:12px;margin-bottom:20px;">
        <tr><td style="padding:16px 20px;">
          <p style="margin:0;font-size:14px;color:#2d2d2d;line-height:1.6;">
            Ouvrez l'application Carnet, rubrique <strong>Mes commandes</strong> :
            vous pourrez ajuster le livre en un clic et le renvoyer directement à
            l'impression.
          </p>
        </td></tr>
      </table>
      <p style="margin:0;font-size:13px;color:#888;line-height:1.6;">
        ${
          retriesLeft > 0
            ? `Il vous reste ${retriesLeft} tentative${retriesLeft > 1 ? 's' : ''} de renvoi automatique — au-delà, notre équipe reprend la main.`
            : `Le nombre de tentatives automatiques est atteint — notre équipe reprend la main et vous recontacte.`
        }
      </p>
    `)
    await sendEmail({
      to: userEmail,
      subject: `Petit ajustement nécessaire pour « ${o.bookTitle ?? 'votre livre'} » (${ref})`,
      html,
    })
  }

  // Copie admin discrète : vue d'ensemble sans devoir vérifier chaque commande à la main.
  await sendEmail({
    to: ADMIN_EMAIL,
    subject: `⚠️ Gelato a refusé ${ref} — ${o.gelatoRetryCount ?? 0}/3 tentatives client`,
    html: `<p>Commande ${ref} (${bookTitle}) refusée par Gelato.</p><p>Raison : ${escapeHtml(String(o.refusalReason ?? ''))}</p>`,
  })
}

function wrap(body: string): string {
  return `<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"/></head>
<body style="margin:0;padding:0;background:#f5ece0;font-family:Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="padding:40px 0;">
  <tr><td align="center">
    <table width="520" cellpadding="0" cellspacing="0"
           style="background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
      <tr><td style="background:#3A6648;padding:28px 36px;">
        <p style="margin:0;font-size:22px;font-weight:bold;color:#FFF8E8;font-style:italic;">carnet</p>
      </td></tr>
      <tr><td style="padding:28px 36px;">${body}</td></tr>
      <tr><td style="background:#f5ece0;padding:16px 36px;font-size:12px;color:#b0a090;text-align:center;">
        Carnet · ${new Date().getFullYear()}
      </td></tr>
    </table>
  </td></tr>
</table></body></html>`
}
