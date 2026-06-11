const RESEND_URL = 'https://api.resend.com/emails'

export const FROM_EMAIL = process.env.EMAIL_FROM ?? 'Carnet <noreply@dmathys.dev>'
export const ADMIN_EMAIL = process.env.ADMIN_EMAIL ?? 'david.mathys24@gmail.com'

export async function sendEmail({
  to,
  subject,
  html,
}: {
  to: string
  subject: string
  html: string
}): Promise<boolean> {
  const key = process.env.RESEND_API_KEY
  if (!key) {
    console.error('[resend] RESEND_API_KEY is not configured')
    return false
  }
  const res = await fetch(RESEND_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from: FROM_EMAIL, to: [to], subject, html }),
  })
  if (!res.ok) {
    console.error('[resend] send failed', res.status, await res.text())
    return false
  }
  return true
}
