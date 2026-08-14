/**
 * How a Bridle proves to the Relay that a device slot is its own.
 *
 * The Relay is untrusted for confidentiality — Noise IK already sees to that —
 * but it does decide which socket receives which phone's traffic, so slot
 * squatting is a denial-of-service worth closing. A Bridle holds an Ed25519
 * identity whose hash *is* its device id, and signs a Relay-issued nonce at
 * registration. That makes the binding self-certifying: the Relay keeps no
 * database, and nobody who merely photographs a pairing QR can take the slot.
 *
 * This key signs nothing but registration nonces. Tunnel authentication is the
 * separate X25519 static key in `noise.ts`.
 */

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
  sign,
  verify,
  type KeyObject,
} from 'node:crypto'

/** Domain separator so a registration signature can never be replayed elsewhere. */
const REGISTRATION_CONTEXT = 'reins-relay-registration/v1'

/** Domain separator for publishing a short-code pairing offer. */
const PAIR_OFFER_CONTEXT = 'reins-pair-offer/v1'

const DER_ED25519_PUBLIC_PREFIX = Buffer.from('302a300506032b6570032100', 'hex')
const DER_ED25519_PRIVATE_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')

/** An Ed25519 identity in raw 32-byte form. */
export interface SigningKeyPair {
  readonly privateKey: Buffer
  readonly publicKey: Buffer
}

/**
 * Generate a Relay identity.
 * @returns the raw Ed25519 key pair.
 */
export function generateSigningKeyPair(): SigningKeyPair {
  const pair = generateKeyPairSync('ed25519')
  return {
    privateKey: pair.privateKey.export({ type: 'pkcs8', format: 'der' }).subarray(DER_ED25519_PRIVATE_PREFIX.length),
    publicKey: pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(DER_ED25519_PUBLIC_PREFIX.length),
  }
}

function importSigningPrivate(raw: Buffer): KeyObject {
  return createPrivateKey({ key: Buffer.concat([DER_ED25519_PRIVATE_PREFIX, raw]), format: 'der', type: 'pkcs8' })
}

function importSigningPublic(raw: Buffer): KeyObject {
  return createPublicKey({ key: Buffer.concat([DER_ED25519_PUBLIC_PREFIX, raw]), format: 'der', type: 'spki' })
}

/**
 * Recover the public half of a raw Ed25519 private key.
 * @param privateKey - raw 32-byte seed.
 * @returns the raw 32-byte public key.
 */
export function signingPublicKeyOf(privateKey: Buffer): Buffer {
  return createPublicKey(importSigningPrivate(privateKey))
    .export({ type: 'spki', format: 'der' })
    .subarray(DER_ED25519_PUBLIC_PREFIX.length)
}

/**
 * Derive the Relay device id from a Bridle's signing identity.
 * @param publicKey - raw 32-byte Ed25519 public key.
 * @returns a base64url device id, safe to print in a QR payload.
 */
export function deviceIdFor(publicKey: Buffer): string {
  return createHash('sha256').update('reins-device').update(publicKey).digest().subarray(0, 16).toString('base64url')
}

/**
 * Mint a registration challenge.
 * @returns 24 random bytes, base64url encoded.
 */
export function mintNonce(): string {
  return randomBytes(24).toString('base64url')
}

function bodyFor(context: string, message: string): Buffer {
  return Buffer.from(`${context}\n${message}`, 'utf8')
}

function signWith(privateKey: Buffer, context: string, message: string): string {
  return sign(null, bodyFor(context, message), importSigningPrivate(privateKey)).toString('base64url')
}

function verifyWith(publicKey: Buffer, context: string, message: string, signature: string): boolean {
  try {
    return verify(null, bodyFor(context, message), importSigningPublic(publicKey), Buffer.from(signature, 'base64url'))
  } catch {
    // A malformed key or signature is a failed verification, not a crash.
    return false
  }
}

/**
 * Sign a Relay registration challenge.
 * @param privateKey - raw 32-byte Ed25519 private key.
 * @param nonce - the Relay-issued challenge.
 * @returns the signature, base64url encoded.
 */
export function signRegistration(privateKey: Buffer, nonce: string): string {
  return signWith(privateKey, REGISTRATION_CONTEXT, nonce)
}

/**
 * Verify a Relay registration.
 * @param publicKey - raw 32-byte Ed25519 public key the Bridle presented.
 * @param nonce - the challenge this Relay issued for this socket.
 * @param signature - base64url signature from the Bridle.
 * @returns whether the signature is valid for this nonce and key.
 */
export function verifyRegistration(publicKey: Buffer, nonce: string, signature: string): boolean {
  return verifyWith(publicKey, REGISTRATION_CONTEXT, nonce, signature)
}

/**
 * Sign a short-code pairing offer before handing it to the Relay to hold.
 * @param privateKey - raw 32-byte Ed25519 private key.
 * @param code - the short code the offer will be claimed with.
 * @returns the signature, base64url encoded.
 */
export function signPairOffer(privateKey: Buffer, code: string): string {
  return signWith(privateKey, PAIR_OFFER_CONTEXT, code)
}

/**
 * Verify that a short-code pairing offer came from the machine it names.
 * @param publicKey - raw 32-byte Ed25519 public key from the offer.
 * @param code - the short code being registered.
 * @param signature - base64url signature from the Bridle.
 * @returns whether the offer is authentic.
 */
export function verifyPairOffer(publicKey: Buffer, code: string, signature: string): boolean {
  return verifyWith(publicKey, PAIR_OFFER_CONTEXT, code, signature)
}
