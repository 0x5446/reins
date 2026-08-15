/**
 * How a Bridle proves a device slot is its own, using WebCrypto instead of
 * `node:crypto`.
 *
 * The Relay is untrusted for confidentiality — Noise IK sees to that — but it
 * decides which socket receives which phone's traffic, so slot squatting is a
 * denial of service worth closing. The device id *is* a hash of the signing
 * key, so the binding is self-certifying and the Relay keeps no database of
 * who owns what.
 *
 * Everything here is async where `@reins/protocol` is synchronous; that is the
 * only difference, and it is WebCrypto's, not the protocol's.
 */

import { fromBase64Url, toBase64Url } from './wire.ts'

/** Domain separator so a registration signature can never be replayed elsewhere. */
const REGISTRATION_CONTEXT = 'reins-relay-registration/v1'

/** Domain separator for publishing a short-code pairing offer. */
const PAIR_OFFER_CONTEXT = 'reins-pair-offer/v1'

/** Raw Ed25519 public key length. */
const KEY_LENGTH = 32

const utf8 = new TextEncoder()

/**
 * Derive the Relay device id from a Bridle's signing identity.
 *
 * `base64url(sha256("reins-device" ‖ key)[0..16])`, docs/protocol.md §2.3.
 * @param publicKey - raw 32-byte Ed25519 public key.
 * @returns the 22-character device id.
 */
export async function deviceIdFor(publicKey: Uint8Array): Promise<string> {
  const prefix = utf8.encode('reins-device')
  const body = new Uint8Array(prefix.byteLength + publicKey.byteLength)
  body.set(prefix)
  body.set(publicKey, prefix.byteLength)
  const digest = await crypto.subtle.digest('SHA-256', body)
  return toBase64Url(new Uint8Array(digest, 0, 16))
}

/**
 * Mint a registration challenge.
 * @returns 24 random bytes, base64url encoded.
 */
export function mintNonce(): string {
  return toBase64Url(crypto.getRandomValues(new Uint8Array(24)))
}

async function verifyWith(publicKey: Uint8Array, context: string, message: string, signature: string): Promise<boolean> {
  const raw = fromBase64Url(signature)
  if (raw === undefined || publicKey.byteLength !== KEY_LENGTH) return false
  try {
    const key = await crypto.subtle.importKey('raw', publicKey, { name: 'Ed25519' }, false, ['verify'])
    return await crypto.subtle.verify({ name: 'Ed25519' }, key, raw, utf8.encode(`${context}\n${message}`))
  } catch {
    // A malformed key or signature is a failed verification, not a crash.
    return false
  }
}

/**
 * Verify a Relay registration.
 * @param publicKey - raw 32-byte Ed25519 public key the Bridle presented.
 * @param nonce - the challenge this socket was issued.
 * @param signature - base64url signature from the Bridle.
 * @returns whether the signature is valid for this nonce and key.
 */
export function verifyRegistration(publicKey: Uint8Array, nonce: string, signature: string): Promise<boolean> {
  return verifyWith(publicKey, REGISTRATION_CONTEXT, nonce, signature)
}

/**
 * Verify that a short-code pairing offer came from the machine it names.
 * @param publicKey - raw 32-byte Ed25519 public key from the offer.
 * @param code - the short code being published.
 * @param signature - base64url signature from the Bridle.
 * @returns whether the offer is authentic.
 */
export function verifyPairOffer(publicKey: Uint8Array, code: string, signature: string): Promise<boolean> {
  return verifyWith(publicKey, PAIR_OFFER_CONTEXT, code, signature)
}

/**
 * Normalize a user-typed short code, exactly as docs/protocol.md §2.4 says.
 *
 * Copied rather than imported so that this Worker stays free of Node built-ins;
 * it is three lines, and the ninth character trap is in the spec, not here.
 * @param input - whatever arrived in the query string.
 * @returns the code in canonical hyphenated uppercase form.
 */
export function normalizeShortCode(input: string): string {
  const stripped = input.toUpperCase().replaceAll(/[^A-Z0-9]/gu, '')
  return stripped.length === 8 ? `${stripped.slice(0, 4)}-${stripped.slice(4)}` : stripped
}
