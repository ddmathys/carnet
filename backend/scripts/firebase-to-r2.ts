/**
 * Reprise des médias restés sur Firebase Storage → Cloudflare R2.
 *
 * La bascule vers R2 (11.07.2026) ne s'appliquait qu'aux NOUVEAUX médias :
 * les anciens sont restés sur Firebase Storage, avec des URLs à jeton
 * permanent (`mediaUrls`, `photoUrl`, `audioUrl`). Ce script les déplace, ce
 * qui referme ces URLs permanentes — la raison d'être de la migration R2.
 *
 * Deux phases, volontairement séparées :
 *   --scan   (défaut) : compte ce qu'il reste sur Firebase. Ne touche à rien.
 *   --copy   : télécharge chaque média, l'envoie sur R2, met à jour le souvenir
 *              (`mediaKeys` / `audioKey`), et VIDE les champs Firebase. Les
 *              fichiers restent sur Firebase — rien n'est perdu si ça tourne mal.
 *   --purge  : supprime de Firebase Storage les fichiers déjà copiés (les clés
 *              R2 correspondantes sont vérifiées avant chaque suppression).
 *              IRRÉVERSIBLE.
 *
 * Usage :  npx tsx scripts/firebase-to-r2.ts --scan
 *          (les secrets viennent de backend/.env.migration — `vercel env pull`)
 */
import { config as loadEnv } from 'dotenv'
import { randomUUID } from 'crypto'
import { getApps, initializeApp, cert } from 'firebase-admin/app'
import { getFirestore } from 'firebase-admin/firestore'
import { getStorage } from 'firebase-admin/storage'
import {
  S3Client,
  PutObjectCommand,
  HeadObjectCommand,
} from '@aws-sdk/client-s3'

// ── Init ─────────────────────────────────────────────────────────────────────

// `--env-file` de Node ne sait pas lire une valeur multi-lignes : la clé de
// service Firebase (JSON avec sauts de ligne) en est une.
loadEnv({ path: '.env.migration' })

const sa = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT ?? '{}')
if (!sa.project_id) {
  console.error('FIREBASE_SERVICE_ACCOUNT manquant (vercel env pull).')
  process.exit(1)
}
if (getApps().length === 0) {
  initializeApp({
    credential: cert(sa),
    projectId: sa.project_id,
    storageBucket: `${sa.project_id}.firebasestorage.app`,
  })
}
const db = getFirestore()
const bucket = getStorage().bucket()

const R2_BUCKET = process.env.R2_BUCKET ?? ''
const s3 = new S3Client({
  region: 'auto',
  endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  requestChecksumCalculation: 'WHEN_REQUIRED',
  responseChecksumValidation: 'WHEN_REQUIRED',
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID ?? '',
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY ?? '',
  },
})

const mode = process.argv.includes('--purge')
  ? 'purge'
  : process.argv.includes('--copy')
    ? 'copy'
    : 'scan'

// ── Helpers ──────────────────────────────────────────────────────────────────

/** Chemin de l'objet dans le bucket Firebase, extrait de son URL de download.
 *  Forme : https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<path%2Fencode>?alt=media&token=… */
function storagePathOf(url: string): string | null {
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

async function existsOnR2(key: string): Promise<boolean> {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: R2_BUCKET, Key: key }))
    return true
  } catch {
    return false
  }
}

/** Copie un objet Firebase Storage → R2. Renvoie la clé R2, ou null si l'objet
 *  source est introuvable. */
async function copyToR2(
  path: string,
  key: string,
  contentType: string
): Promise<string | null> {
  const file = bucket.file(path)
  const [exists] = await file.exists()
  if (!exists) return null
  const [bytes] = await file.download()
  await s3.send(
    new PutObjectCommand({
      Bucket: R2_BUCKET,
      Key: key,
      Body: bytes,
      ContentType: contentType,
    })
  )
  return key
}

// ── Parcours des souvenirs ───────────────────────────────────────────────────

type Legacy = {
  id: string
  userId: string
  notebookId: string
  photoUrls: string[] // photoUrl + mediaUrls, dédoublonnés
  audioUrl: string | null
}

async function legacyMemories(): Promise<Legacy[]> {
  const snap = await db.collection('memories').get()
  const out: Legacy[] = []
  for (const doc of snap.docs) {
    const d = doc.data()
    const urls = new Set<string>()
    if (typeof d.photoUrl === 'string' && d.photoUrl) urls.add(d.photoUrl)
    for (const u of Array.isArray(d.mediaUrls) ? d.mediaUrls : []) {
      if (typeof u === 'string' && u) urls.add(u)
    }
    const audioUrl =
      typeof d.audioUrl === 'string' && d.audioUrl ? d.audioUrl : null
    // Seules les URLs Firebase nous intéressent (les clés R2 sont déjà en place).
    const photoUrls = [...urls].filter((u) => storagePathOf(u) !== null)
    const audio = audioUrl && storagePathOf(audioUrl) ? audioUrl : null
    if (photoUrls.length === 0 && !audio) continue
    out.push({
      id: doc.id,
      userId: String(d.userId ?? ''),
      notebookId: String(d.notebookId ?? ''),
      photoUrls,
      audioUrl: audio,
    })
  }
  return out
}

// ── Phases ───────────────────────────────────────────────────────────────────

async function scan() {
  const items = await legacyMemories()
  const photos = items.reduce((n, m) => n + m.photoUrls.length, 0)
  const audios = items.filter((m) => m.audioUrl).length
  console.log(`Souvenirs concernés : ${items.length}`)
  console.log(`  photos sur Firebase : ${photos}`)
  console.log(`  mémos vocaux sur Firebase : ${audios}`)
  const orphans = items.filter((m) => !m.userId).length
  if (orphans) {
    console.log(`  ⚠ ${orphans} sans userId (migration tags non passée ?)`)
  }
}

async function copy() {
  const items = await legacyMemories()
  console.log(`Copie de ${items.length} souvenir(s) vers R2…`)
  let okPhotos = 0
  let okAudio = 0
  let missing = 0

  for (const m of items) {
    const doc = db.collection('memories').doc(m.id)
    const snap = await doc.get()
    const data = snap.data() ?? {}
    const owner = m.userId || String(data.userId ?? 'unknown')
    const nb = m.notebookId || 'legacy'

    // Photos : chaque URL Firebase devient une clé R2 ajoutée à `mediaKeys`.
    const newKeys: string[] = []
    for (const url of m.photoUrls) {
      const path = storagePathOf(url)
      if (!path) continue
      const key = `photos/${owner}/${nb}/${randomUUID()}.jpg`
      const done = await copyToR2(path, key, 'image/jpeg')
      if (done) {
        newKeys.push(key)
        okPhotos++
      } else {
        missing++
      }
    }

    // Mémo vocal.
    let audioKey: string | null = null
    if (m.audioUrl) {
      const path = storagePathOf(m.audioUrl)
      if (path) {
        const key = `audio/${owner}/${nb}/${randomUUID()}.m4a`
        const done = await copyToR2(path, key, 'audio/mp4')
        if (done) {
          audioKey = key
          okAudio++
        } else {
          missing++
        }
      }
    }

    const update: Record<string, unknown> = {}
    // On garde la trace des chemins Firebase d'origine : c'est ce que --purge
    // supprimera (une fois les URLs retirées du souvenir, on ne saurait plus
    // retrouver les fichiers sources).
    const sourcePaths = [
      ...m.photoUrls.map(storagePathOf),
      m.audioUrl ? storagePathOf(m.audioUrl) : null,
    ].filter((p): p is string => p !== null)

    if (newKeys.length > 0) {
      const existing = Array.isArray(data.mediaKeys)
        ? (data.mediaKeys as string[])
        : []
      update.mediaKeys = [...existing, ...newKeys]
      // Les URLs Firebase disparaissent du souvenir : l'app lit désormais R2.
      update.mediaUrls = []
      update.photoUrl = null
    }
    if (audioKey) {
      update.audioKey = audioKey
      update.audioUrl = null
    }
    if (Object.keys(update).length > 0) {
      update.legacyStoragePaths = sourcePaths
      await doc.update(update)
    }
    process.stdout.write('.')
  }

  console.log(
    `\n✓ ${okPhotos} photo(s) et ${okAudio} mémo(s) copiés sur R2.` +
      (missing ? ` ⚠ ${missing} fichier(s) introuvable(s) côté Firebase.` : '')
  )
  console.log('Les fichiers sont encore sur Firebase — lance --purge pour les supprimer.')
}

/** Supprime de Firebase Storage les fichiers déjà copiés (`legacyStoragePaths`),
 *  et seulement après avoir VÉRIFIÉ sur R2 que la copie existe bien.
 *  IRRÉVERSIBLE. */
async function purge() {
  const snap = await db.collection('memories').get()
  let deleted = 0
  let skipped = 0

  for (const doc of snap.docs) {
    const d = doc.data()
    const paths: string[] = Array.isArray(d.legacyStoragePaths)
      ? d.legacyStoragePaths
      : []
    if (paths.length === 0) continue

    const keys: string[] = Array.isArray(d.mediaKeys) ? d.mediaKeys : []
    const audioKey = typeof d.audioKey === 'string' ? d.audioKey : ''
    const targets = [...keys, ...(audioKey ? [audioKey] : [])]

    // Filet de sécurité : pas de suppression sans copie R2 vérifiée.
    const present = await Promise.all(targets.map(existsOnR2))
    if (targets.length === 0 || present.some((ok) => !ok)) {
      skipped++
      continue
    }

    for (const path of paths) {
      try {
        await bucket.file(path).delete({ ignoreNotFound: true })
        deleted++
      } catch {
        // fichier déjà absent : rien à faire
      }
    }
    await doc.update({ legacyStoragePaths: [] })
    process.stdout.write('.')
  }

  console.log(
    `\n✓ ${deleted} fichier(s) supprimé(s) de Firebase Storage.` +
      (skipped
        ? ` ⚠ ${skipped} souvenir(s) épargnés (copie R2 non vérifiée).`
        : '')
  )
}

// ── Entrée ───────────────────────────────────────────────────────────────────

async function main() {
  if (mode === 'scan') await scan()
  else if (mode === 'copy') await copy()
  else await purge()
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
