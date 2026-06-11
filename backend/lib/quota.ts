import { db } from './firebase'
import { FieldValue } from 'firebase-admin/firestore'

const FREE_DAILY_AI_CALLS = 60
const PREMIUM_DAILY_AI_CALLS = 300

// Incrémente le compteur d'appels IA du jour pour cet utilisateur.
// Retourne false si le quota journalier est dépassé.
export async function consumeAiQuota(uid: string): Promise<boolean> {
  const today = new Date().toISOString().slice(0, 10) // YYYY-MM-DD
  const usageRef = db.collection('aiUsage').doc(uid)

  return db.runTransaction(async (tx) => {
    const [usageSnap, userSnap] = await Promise.all([
      tx.get(usageRef),
      tx.get(db.collection('users').doc(uid)),
    ])

    const tier = (userSnap.data()?.subscriptionTier as string) ?? 'free'
    const limit = tier === 'premium' ? PREMIUM_DAILY_AI_CALLS : FREE_DAILY_AI_CALLS

    const data = usageSnap.data()
    const count = data?.date === today ? ((data?.count as number) ?? 0) : 0
    if (count >= limit) return false

    tx.set(usageRef, {
      date: today,
      count: count + 1,
      updatedAt: FieldValue.serverTimestamp(),
    })
    return true
  })
}
