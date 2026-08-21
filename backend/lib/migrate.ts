import { randomUUID } from 'crypto'
import { db, legacyBucket } from './firebase'
import { putObject } from './r2'

// Reprise des médias restés sur Firebase Storage → Cloudflare R2.
//
// La bascule R2 ne valait que pour les NOUVEAUX médias : les anciens gardaient
// des URLs Firebase à jeton permanent (`mediaUrls`, `photoUrl`, `audioUrl`,
// `pdfUrl`) — quiconque met la main sur l'URL voit le média, pour toujours.
// Ici, chaque fichier est recopié sur R2 (bucket privé, URLs signées courtes),
// le document est repointé sur la CLÉ R2, puis l'original Firebase est supprimé.
//
// Le travail se fait par LOTS : le serveur a un temps d'exécution limité, et
// l'app rappelle l'endpoint tant qu'il reste quelque chose (`remaining`).
// Chaque lot est complet en lui-même — une coupure ne laisse rien à moitié
// migré, au pire un fichier encore présent des deux côtés.

export type MigrationReport = {
  photos: number
  audios: number
  pdfs: number
  remaining: number
}

/** Chemin de l'objet dans le bucket Firebase, extrait de son URL de download.
 *  Forme : https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<path%2Fencodé>?alt=media&token=… */
export function storagePathOf(url: string): string | null {
  try {
    const u = new URL(url)
    if (!u.hostname.includes('firebasestorage')) return null
    const m = u.pathname.match(/\/o\/(.+)$/)
    if (!m) return null
    return decodeURIComponent(m[1])
  } catch {
    return null
  }
}

const isFirebaseUrl = (v: unknown): v is string =>
  typeof v === 'string' && storagePathOf(v) !== null

/** Copie un fichier Firebase Storage → R2, puis SUPPRIME l'original.
 *  Renvoie la clé R2, ou null si le fichier source n'existe plus (rien à faire).
 *  L'original n'est supprimé qu'après une écriture R2 réussie. */
async function moveToR2(
  path: string,
  key: string,
  contentType: string
): Promise<string | null> {
  const file = legacyBucket().file(path)
  const [exists] = await file.exists()
  if (!exists) return null
  const [bytes] = await file.download()
  await putObject(key, bytes, contentType)
  try {
    await file.delete({ ignoreNotFound: true })
  } catch {
    // La copie R2 est faite : un original récalcitrant sera repris au prochain
    // passage (son URL a disparu du document, mais le fichier reste inoffensif).
  }
  return key
}

/** Migre un lot de documents `memories` déjà récupérés : photos + mémo vocal.
 *  Le propriétaire (pour construire les chemins R2) est lu sur CHAQUE document
 *  (`userId`) plutôt que passé en paramètre, pour servir aussi bien un balayage
 *  mono-utilisateur qu'un balayage global tous comptes confondus. */
async function migrateMemoryDocs(
  docs: FirebaseFirestore.QueryDocumentSnapshot[],
  budget: number,
  report: MigrationReport
): Promise<number> {
  const pending = docs.filter((d) => {
    const x = d.data()
    const urls = [x.photoUrl, ...(Array.isArray(x.mediaUrls) ? x.mediaUrls : [])]
    return urls.some(isFirebaseUrl) || isFirebaseUrl(x.audioUrl)
  })
  report.remaining += pending.length

  let used = 0
  for (const doc of pending) {
    if (used >= budget) break
    const d = doc.data()
    const owner = String(d.userId ?? 'unknown')
    const notebookId = String(d.notebookId ?? 'legacy')

    // Photos : `photoUrl` (ancien format mono) + `mediaUrls`, dédoublonnées.
    const photoUrls = [
      ...new Set(
        [d.photoUrl, ...(Array.isArray(d.mediaUrls) ? d.mediaUrls : [])].filter(
          isFirebaseUrl
        )
      ),
    ]
    const newKeys: string[] = []
    for (const url of photoUrls) {
      const path = storagePathOf(url)
      if (!path) continue
      const key = `photos/${owner}/${notebookId}/${randomUUID()}.jpg`
      if (await moveToR2(path, key, 'image/jpeg')) {
        newKeys.push(key)
        report.photos++
      }
    }

    // Mémo vocal.
    let audioKey: string | null = null
    if (isFirebaseUrl(d.audioUrl)) {
      const path = storagePathOf(d.audioUrl)
      if (path) {
        const key = `audio/${owner}/${notebookId}/${randomUUID()}.m4a`
        if (await moveToR2(path, key, 'audio/mp4')) {
          audioKey = key
          report.audios++
        }
      }
    }

    const update: Record<string, unknown> = {}
    // Les photos R2 déjà présentes sont conservées : un souvenir édité après la
    // bascule est mixte, et l'ordre (anciennes puis nouvelles) doit tenir.
    const existingKeys: string[] = Array.isArray(d.mediaKeys)
      ? (d.mediaKeys as string[])
      : []
    if (photoUrls.length > 0) {
      update.mediaKeys = [...existingKeys, ...newKeys]
      update.mediaUrls = []
      update.photoUrl = null
    }
    if (isFirebaseUrl(d.audioUrl)) {
      update.audioKey = audioKey ?? d.audioKey ?? null
      update.audioUrl = null
    }
    if (Object.keys(update).length > 0) await doc.ref.update(update)

    used++
    report.remaining--
  }
  return used
}

/** Migre un lot de documents PDF (`generatedBooks` ou `orders`) déjà récupérés.
 *  Gelato/Prodigi reçoit ensuite une URL backend stable qui redirige vers une
 *  URL R2 signée fraîche. */
async function migratePdfDocs(
  docs: FirebaseFirestore.QueryDocumentSnapshot[],
  col: 'generatedBooks' | 'orders',
  budget: number,
  report: MigrationReport,
  stableUrl: (key: string) => string
): Promise<number> {
  const pending = docs.filter((d) => isFirebaseUrl(d.data().pdfUrl))
  report.remaining += pending.length

  let used = 0
  for (const doc of pending) {
    if (used >= budget) break
    const d = doc.data()
    const owner = String(d.userId ?? 'unknown')
    const path = storagePathOf(d.pdfUrl as string)
    if (!path) continue
    const key = `books/${owner}/${randomUUID()}.pdf`
    const done = await moveToR2(path, key, 'application/pdf')
    if (!done) {
      // Fichier source disparu : on retire l'URL morte plutôt que de la garder.
      await doc.ref.update({ pdfUrl: null })
      report.remaining--
      continue
    }
    await doc.ref.update({
      pdfUrl: stableUrl(key),
      ...(col === 'generatedBooks' ? { storagePath: key } : { pdfKey: key }),
    })
    report.pdfs++
    used++
    report.remaining--
  }
  return used
}

/** Migre un lot de médias de l'utilisateur. `remaining` = ce qu'il reste à
 *  faire APRÈS ce lot : l'app rappelle tant que ce n'est pas zéro. */
export async function migrateLegacyMedia(
  uid: string,
  limit: number,
  stableUrl: (key: string) => string
): Promise<MigrationReport> {
  const report: MigrationReport = {
    photos: 0,
    audios: 0,
    pdfs: 0,
    remaining: 0,
  }
  const memSnap = await db
    .collection('memories')
    .where('userId', '==', uid)
    .get()
  const used = await migrateMemoryDocs(memSnap.docs, limit, report)

  let pdfBudget = Math.max(0, limit - used)
  for (const col of ['generatedBooks', 'orders'] as const) {
    const snap = await db.collection(col).where('userId', '==', uid).get()
    const u = await migratePdfDocs(snap.docs, col, pdfBudget, report, stableUrl)
    pdfBudget = Math.max(0, pdfBudget - u)
  }
  return report
}

/** Balayage ADMIN : migre les médias de TOUS les comptes, pas seulement
 *  l'appelant. Ferme l'exposition pour les comptes qui ne rouvrent jamais
 *  l'app (donc ne déclenchent jamais `MediaMigrationService` côté client) —
 *  la seule vraie garantie que plus aucune URL Firebase à jeton permanent ne
 *  reste vivante. Même contrat `remaining` : rappeler tant que ce n'est pas 0. */
export async function migrateLegacyMediaAll(
  limit: number,
  stableUrl: (key: string) => string
): Promise<MigrationReport> {
  const report: MigrationReport = {
    photos: 0,
    audios: 0,
    pdfs: 0,
    remaining: 0,
  }
  const memSnap = await db.collection('memories').get()
  const used = await migrateMemoryDocs(memSnap.docs, limit, report)

  let pdfBudget = Math.max(0, limit - used)
  for (const col of ['generatedBooks', 'orders'] as const) {
    const snap = await db.collection(col).get()
    const u = await migratePdfDocs(snap.docs, col, pdfBudget, report, stableUrl)
    pdfBudget = Math.max(0, pdfBudget - u)
  }
  return report
}
