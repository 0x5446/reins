/**
 * Ringing a phone that is not attached.
 *
 * The Relay carries ciphertext and cannot read any of it, which is the property
 * the whole design rests on — and it is also why this file exists. A suspended
 * iOS app cannot be woken by anything except APNs, and APNs will only take a
 * push signed by the developer's key. That key cannot ship inside a Bridle
 * running on someone's laptop, because then every user would hold the key that
 * pushes to every other user. So the Relay signs, and the Relay is therefore
 * the one component that learns a device token.
 *
 * What it does not learn is what the push is about. The Bridle sends a token
 * and a machine name; the visible text is a constant in this file. There is no
 * field for the agent's question, so there is nothing to leak and no promise
 * resting on the Relay choosing not to look. The phone wakes, opens its own
 * encrypted tunnel, asks the machine what happened, and posts a *local*
 * notification with the real words — which never crossed the Relay and never
 * reached Apple.
 *
 * Push is optional. A Relay with no key configured refuses to wake anyone and
 * says so once; every other function is unaffected.
 */

import type { Env } from './env.ts'

/** APNs hosts, by the environment that minted the token. */
const HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
} as const

/**
 * How long a signed APNs token is reused.
 *
 * Apple rejects a provider that mints these more than once every twenty
 * minutes and expires them after sixty, so the safe window is the middle of
 * that range rather than either edge.
 */
const JWT_LIFETIME_MS = 40 * 60 * 1000

/** The only words the Relay is able to say. */
const ALERT_TITLE = 'Reins'
const ALERT_BODY = 'Your agent is waiting on you.'

/** What a caller needs to ring one phone. */
export interface WakeTarget {
  token: string
  environment: 'sandbox' | 'production'
  machine?: string
}

/** Why a wake did not happen, or that it did. */
export type WakeOutcome =
  | { ok: true }
  | { ok: false; reason: 'unconfigured' | 'rejected' | 'unreachable'; detail?: string }

/** A signed provider token and when it stops being reused. */
interface CachedJwt {
  value: string
  mintedAt: number
}

let cached: CachedJwt | undefined

/**
 * Send one content-free push.
 * @param env - the Worker environment, for the APNs key material.
 * @param target - who to ring.
 * @param now - current epoch milliseconds; injectable so a test is not timed.
 * @returns whether APNs accepted it, and why not when it did not.
 */
export async function wake(env: Env, target: WakeTarget, now: number = Date.now()): Promise<WakeOutcome> {
  const key = env.REINS_APNS_KEY
  const keyId = env.REINS_APNS_KEY_ID
  const teamId = env.REINS_APNS_TEAM_ID
  const topic = env.REINS_APNS_TOPIC
  if (!key || !keyId || !teamId || !topic) return { ok: false, reason: 'unconfigured' }
  if (!/^[0-9a-f]{64,200}$/u.test(target.token)) return { ok: false, reason: 'rejected', detail: 'malformed token' }

  let jwt: string
  try {
    jwt = await providerToken(key, keyId, teamId, now)
  } catch (error) {
    return { ok: false, reason: 'unconfigured', detail: describe(error) }
  }

  // `alert`, not `content-available`. A silent push is the tempting design —
  // wake, fetch, post the real text — but iOS treats silent pushes as
  // discardable: throttled, dropped in Low Power Mode, never delivered at all
  // once the app has been force-quit. A notification that arrives when the
  // system feels like it is not a notification for "may I delete this".
  const body = JSON.stringify({
    aps: {
      alert: {
        title: ALERT_TITLE,
        body: target.machine === undefined ? ALERT_BODY : `${ALERT_BODY} · ${target.machine}`,
      },
      sound: 'default',
      'interruption-level': 'time-sensitive',
    },
  })

  let response: Response
  try {
    response = await fetch(`${HOSTS[target.environment]}/3/device/${target.token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': topic,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        // A wake that arrives an hour late is worse than one that never
        // arrives: the person opens the app to find the question already
        // answered or the agent long since given up.
        'apns-expiration': String(Math.floor(now / 1000) + 300),
      },
      body,
    })
  } catch (error) {
    return { ok: false, reason: 'unreachable', detail: describe(error) }
  }

  if (response.status === 200) return { ok: true }
  // A token goes stale when the app is reinstalled or restored to a new phone.
  // APNs says so precisely, and the Bridle holding that token is the only place
  // that can forget it — so the reason travels back rather than being swallowed.
  const detail = await response.text().catch(() => '')
  return { ok: false, reason: 'rejected', detail: `${String(response.status)} ${detail}`.trim() }
}

/** Drop the cached provider token. Only a test needs this. */
export function forgetProviderToken(): void {
  cached = undefined
}

/**
 * Sign, or reuse, the provider token APNs authenticates with.
 * @param pem - the `.p8` contents.
 * @param keyId - the key's ten-character id.
 * @param teamId - the paid team's ten-character id.
 * @param now - current epoch milliseconds.
 * @returns a compact ES256 JWT.
 */
async function providerToken(pem: string, keyId: string, teamId: string, now: number): Promise<string> {
  if (cached !== undefined && now - cached.mintedAt < JWT_LIFETIME_MS) return cached.value

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pkcs8(pem),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
  const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: keyId })))
  const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) })))
  const signed = `${header}.${claims}`
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(signed),
  )
  const value = `${signed}.${base64url(new Uint8Array(signature))}`
  cached = { value, mintedAt: now }
  return value
}

/**
 * Strip a PEM envelope down to the DER it wraps.
 * @param pem - the `.p8` file contents, newlines optional.
 * @returns the raw PKCS#8 bytes.
 */
function pkcs8(pem: string): Uint8Array {
  const base64 = pem.replace(/-----[A-Z ]+-----/gu, '').replace(/\s+/gu, '')
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
  return bytes
}

/**
 * Base64url without padding, which is what JWT requires.
 * @param bytes - what to encode.
 * @returns the encoded string.
 */
function base64url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '')
}

/**
 * @param error - anything thrown.
 * @returns a short operator-facing string.
 */
function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
