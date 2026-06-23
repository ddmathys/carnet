import { db } from './firebase'

// Contrôle d'accès centralisé : on ne sert un média que si le demandeur est
// membre du carnet qui le possède. La vérité sur l'appartenance vit dans
// Firestore (propriétaire `userId` ou collaborateur `sharedWith`), exactement
// comme dans firestore.rules (fonction canAccessNotebook). Réutilisable pour
// vidéos ET photos.
export async function memoryIfMember(
  memoryId: string,
  uid: string,
  email?: string | null
): Promise<Record<string, unknown> | null> {
  if (!memoryId || !uid) return null

  const memSnap = await db.collection('memories').doc(memoryId).get()
  if (!memSnap.exists) return null
  const mem = memSnap.data() as Record<string, unknown>

  const notebookId = mem.notebookId as string | undefined
  if (!notebookId) return null

  const nbSnap = await db.collection('notebooks').doc(notebookId).get()
  if (!nbSnap.exists) return null
  const nb = nbSnap.data() as Record<string, unknown>

  const asStrings = (v: unknown): string[] =>
    Array.isArray(v) ? (v as unknown[]).filter((x): x is string => typeof x === 'string') : []
  const sharedWith = asStrings(nb.sharedWith)
  const invitedEmails = asStrings(nb.invitedEmails)

  // Membre = propriétaire, collaborateur (sharedWith), ou invité par email pas
  // encore « accepté » (invitedEmails) — même périmètre que la lecture autorisée
  // par firestore.rules. Permet au grand-parent invité de voir depuis le QR
  // dès sa première connexion, avant même d'ouvrir l'app.
  const isMember =
    nb.userId === uid ||
    sharedWith.includes(uid) ||
    (!!email && invitedEmails.includes(email))

  return isMember ? mem : null
}

/** Extrait les clés vidéo d'un souvenir (nouveau format `videoKeys`, repli sur
 *  l'ancien `videoKey` unique). */
export function videoKeysOf(mem: Record<string, unknown>): string[] {
  if (Array.isArray(mem.videoKeys)) {
    return (mem.videoKeys as unknown[]).filter(
      (k): k is string => typeof k === 'string' && k.length > 0
    )
  }
  return typeof mem.videoKey === 'string' && mem.videoKey ? [mem.videoKey] : []
}
