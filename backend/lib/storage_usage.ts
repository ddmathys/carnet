import { FieldValue } from 'firebase-admin/firestore'
import { db } from './firebase'
import { bytesUnderPrefix } from './r2'

// Plafond de stockage par compte (21.10.26). L'app reste gratuite et la marge
// se fait sur l'imprimé : chaque compte qui stocke sans jamais commander coûte
// du R2 tous les mois. Le plafond est volontairement GÉNÉREUX — très au-dessus
// des compteurs de l'app (QuotaService : photos, vidéos, mémos vocaux, environ
// 35 Go au maximum) — et sert de filet serveur : ces compteurs-là ne tournent
// que dans l'app, contournables par tout appelant muni d'un jeton valide.
export const STORAGE_LIMIT_BYTES = 50 * 1024 ** 3 // 50 Go

// Mesurer le bucket coûte une liste R2 par tranche de 1000 objets : on mesure
// au plus une fois par jour, et on additionne entre-temps chaque envoi signé.
// Un envoi abandonné compte donc jusqu'à la mesure suivante, et une
// suppression ne libère sa place qu'à ce moment-là — sans conséquence à 50 Go.
const REMEASURE_MS = 24 * 60 * 60 * 1000

/** Médias d'un compte : photos, vidéos et mémos vocaux (les PDF de commande
 *  ne comptent pas — ce sont des fichiers d'impression, pas des souvenirs). */
async function measure(uid: string): Promise<number> {
  const sizes = await Promise.all(
    ['photos', 'videos', 'audio'].map((p) => bytesUnderPrefix(`${p}/${uid}/`))
  )
  return sizes.reduce((a, b) => a + b, 0)
}

/** Réserve [adding] octets pour un envoi. Refuse si le plafond est dépassé.
 *  Une panne de mesure laisse PASSER l'envoi : le plafond est un garde-fou de
 *  coûts, il ne doit jamais faire perdre un souvenir à cause de R2. */
export async function reserveStorage(
  uid: string,
  adding: number
): Promise<{ ok: boolean; used: number; limit: number }> {
  const limit = STORAGE_LIMIT_BYTES
  const ref = db.collection('storageUsage').doc(uid)
  try {
    const snap = await ref.get()
    const data = snap.data() ?? {}
    let used = typeof data.bytes === 'number' ? data.bytes : 0
    const measuredAt = typeof data.measuredAt === 'number' ? data.measuredAt : 0
    if (!snap.exists || Date.now() - measuredAt > REMEASURE_MS) {
      used = await measure(uid)
      await ref.set({ bytes: used, measuredAt: Date.now() })
    }
    if (used + adding > limit) return { ok: false, used, limit }
    await ref.update({ bytes: FieldValue.increment(adding) })
    return { ok: true, used: used + adding, limit }
  } catch (e) {
    console.error('[storage-usage]', e)
    return { ok: true, used: 0, limit }
  }
}

export const STORAGE_FULL_MESSAGE =
  "Ton espace de stockage est plein (50 Go). Supprime quelques vidéos ou écris-nous : on trouvera une solution."
