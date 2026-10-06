import type { VercelRequest, VercelResponse } from '@vercel/node'
import { sendOrderEmails } from '../../lib/email_order'
import { sendShareInvitation } from '../../lib/email_share'

// Les deux envois d'e-mails tiennent dans UNE seule fonction — le plan Vercel
// Hobby plafonne à 12 fonctions par déploiement, et il en fallait une de libre
// pour api/ai/[action].ts. Même motif que api/tag/[action].ts.
//
// Les chemins appelés par l'app sont INCHANGÉS (le segment dynamique les
// capture), donc rien à modifier côté Flutter :
//   POST /api/email/order  { orderId }  → notification admin + confirmation client
//   POST /api/email/share  { notebookId, toEmail } → invitation à un carnet
//
// Chaque handler fait sa propre authentification (requireAuth) et ses propres
// contrôles de propriété : le routeur ne décide rien d'autre que la cible.
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' })
  }

  const action = String(req.query.action ?? '')

  if (action === 'order') return sendOrderEmails(req, res)
  if (action === 'share') return sendShareInvitation(req, res)

  return res.status(404).json({ error: 'Unknown action' })
}
