import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'

// Cloudflare R2 est compatible S3. Le backend détient les clés (jamais l'app)
// et signe des URLs d'upload temporaires ; les fichiers transitent en direct
// app → R2 (egress gratuit, ne passe pas par Vercel).
const accountId = process.env.R2_ACCOUNT_ID ?? ''
const bucket = process.env.R2_BUCKET ?? ''
// On normalise l'hôte public (sans schéma ni slash final) — ce qu'on stocke en
// base est la CLÉ de l'objet, l'URL publique est reconstruite ici. Changer de
// domaine plus tard = une seule variable d'env, aucun QR imprimé cassé.
const publicHost = (process.env.R2_PUBLIC_HOST ?? '')
  .replace(/^https?:\/\//, '')
  .replace(/\/$/, '')

export const r2Bucket = bucket
export const r2PublicHost = publicHost

const s3 = new S3Client({
  region: 'auto',
  endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
  // Depuis @aws-sdk/client-s3 v3.729, le SDK calcule un checksum CRC32 par
  // défaut et l'inscrit dans les en-têtes SIGNÉS de l'URL PUT présignée. L'app
  // n'envoie pas cet en-tête lors du PUT direct → signature invalide → R2
  // rejette l'upload (SignatureDoesNotMatch). On revient au comportement
  // « checksum seulement si requis », seul mode compatible avec R2.
  requestChecksumCalculation: 'WHEN_REQUIRED',
  responseChecksumValidation: 'WHEN_REQUIRED',
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID ?? '',
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY ?? '',
  },
})

export function publicUrlForKey(key: string): string {
  return `https://${publicHost}/${key}`
}

/** URL PUT signée (valable [expiresIn] s) pour uploader directement sur R2. */
export async function presignPut(
  key: string,
  contentType: string,
  expiresIn = 600
): Promise<string> {
  const cmd = new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    ContentType: contentType,
  })
  return getSignedUrl(s3, cmd, { expiresIn })
}

/** URL GET signée (valable [expiresIn] s) pour LIRE un objet d'un bucket privé.
 *  Sert la lecture vidéo une fois le bucket R2 passé en privé (plus d'URL
 *  publique permanente) : le backend ne la délivre qu'après contrôle d'accès. */
export async function presignGet(
  key: string,
  expiresIn = 3600
): Promise<string> {
  const cmd = new GetObjectCommand({ Bucket: bucket, Key: key })
  return getSignedUrl(s3, cmd, { expiresIn })
}

export async function deleteObject(key: string): Promise<void> {
  await s3.send(new DeleteObjectCommand({ Bucket: bucket, Key: key }))
}
