/**
 * Taking the machine's identity with you.
 *
 * `~/.reins/bridle.json` holds the only copy of this machine's static key, its
 * signing key, and the list of devices that trust it. If that file goes — a
 * reinstall, a new laptop, a bad disk, an `rm` in the wrong directory — the
 * Bridle silently generates a *new* identity, every paired phone stops
 * recognising the machine, and there is no way back. The phones do not fail
 * loudly either: they see a machine whose static key does not match the one
 * they pinned, which is indistinguishable from someone impersonating it.
 *
 * So: an export that can be moved, and an import that refuses to be careless.
 *
 * The archive is encrypted with a passphrase, because it is the whole of the
 * machine's authority in one file and people put those in Dropbox. Key
 * derivation is scrypt with parameters that cost about a tenth of a second —
 * enough that a stolen archive with a weak passphrase is not free to open, and
 * not so much that restoring on a slow machine feels broken.
 */

import { createCipheriv, createDecipheriv, randomBytes, scryptSync, timingSafeEqual } from 'node:crypto'
import type { BridleState } from './identity.ts'

/** Format marker, so a future change can be refused rather than misread. */
const MAGIC = 'reins-identity/v1'

/**
 * scrypt cost. N=2^15 lands near 100ms on a laptop of this era.
 *
 * `maxmem` has to be stated: these parameters need 128·N·r = 32 MiB, which is
 * exactly Node's default ceiling, and "exactly at the limit" fails.
 */
const SCRYPT = { N: 32768, r: 8, p: 1, keyLength: 32, maxmem: 64 * 1024 * 1024 } as const

/** What a restore would overwrite, so the caller can ask before doing it. */
export interface BackupSummary {
  machineName: string
  deviceId: string
  peerCount: number
  exportedAt: string
}

/** A backup that could not be read. */
export class BackupError extends Error {}

/**
 * Encrypt the machine's identity into a portable archive.
 * @param state - the live state, as loaded from disk.
 * @param passphrase - what will be needed to restore it.
 * @param deviceId - this machine's id, recorded so a restore can be identified before decrypting nothing.
 * @returns the archive text, safe to store anywhere the passphrase is not.
 */
export function exportIdentity(state: BridleState, passphrase: string, deviceId: string): string {
  if (passphrase.length < 8) throw new BackupError('the passphrase must be at least 8 characters')
  const salt = randomBytes(16)
  const nonce = randomBytes(12)
  const key = scryptSync(passphrase, salt, SCRYPT.keyLength, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, maxmem: SCRYPT.maxmem })
  const cipher = createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  const plaintext = Buffer.from(JSON.stringify(state), 'utf8')
  const sealed = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()])

  // The header is deliberately readable: someone finding this file in two years
  // should be able to tell what it is and which machine it came from without a
  // passphrase. None of it is secret — the machine name and device id are in
  // every pairing code already.
  return `${JSON.stringify({
    magic: MAGIC,
    machineName: state.machineName,
    deviceId,
    peerCount: state.peers.length,
    exportedAt: new Date().toISOString(),
    salt: salt.toString('base64'),
    nonce: nonce.toString('base64'),
    sealed: sealed.toString('base64'),
  }, null, 2)}\n`
}

/**
 * Read an archive's header without decrypting it.
 *
 * Restoring replaces an identity, so the CLI shows what is about to arrive and
 * what it would displace before asking. That question cannot be asked if the
 * passphrase is needed first.
 * @param archive - the archive text.
 * @returns what the archive says about itself.
 */
export function describeBackup(archive: string): BackupSummary {
  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(archive) as Record<string, unknown>
  } catch {
    throw new BackupError('that file is not a Reins identity backup')
  }
  if (parsed['magic'] !== MAGIC) {
    throw new BackupError(`unrecognised backup format ${String(parsed['magic'] ?? 'unknown')}; this build reads ${MAGIC}`)
  }
  return {
    machineName: String(parsed['machineName'] ?? 'unknown'),
    deviceId: String(parsed['deviceId'] ?? 'unknown'),
    peerCount: Number(parsed['peerCount'] ?? 0),
    exportedAt: String(parsed['exportedAt'] ?? 'unknown'),
  }
}

/**
 * Decrypt an archive back into machine state.
 * @param archive - the archive text.
 * @param passphrase - the one used at export.
 * @returns the state, ready to be written to disk.
 */
export function importIdentity(archive: string, passphrase: string): BridleState {
  describeBackup(archive)
  const parsed = JSON.parse(archive) as Record<string, string>
  const salt = Buffer.from(parsed['salt'] ?? '', 'base64')
  const nonce = Buffer.from(parsed['nonce'] ?? '', 'base64')
  const sealed = Buffer.from(parsed['sealed'] ?? '', 'base64')
  if (salt.length !== 16 || nonce.length !== 12 || sealed.length <= 16) {
    throw new BackupError('the backup is damaged')
  }
  const key = scryptSync(passphrase, salt, SCRYPT.keyLength, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p, maxmem: SCRYPT.maxmem })
  const body = sealed.subarray(0, sealed.length - 16)
  const tag = sealed.subarray(sealed.length - 16)
  const decipher = createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 })
  decipher.setAuthTag(tag)
  let plaintext: Buffer
  try {
    plaintext = Buffer.concat([decipher.update(body), decipher.final()])
  } catch {
    // AEAD cannot distinguish a wrong passphrase from a corrupted file, and
    // guessing between them for the person would be a lie half the time.
    throw new BackupError('wrong passphrase, or the backup is damaged')
  }
  try {
    return JSON.parse(plaintext.toString('utf8')) as BridleState
  } catch {
    throw new BackupError('the backup decrypted to something that is not machine state')
  }
}

/**
 * Whether two archives hold the same identity.
 *
 * Used by the tests, and by a future `bridle doctor` check that wants to say
 * "your backup is stale" without holding the passphrase.
 * @param a - one summary.
 * @param b - another.
 * @returns true when both name the same device.
 */
export function sameIdentity(a: BackupSummary, b: BackupSummary): boolean {
  const left = Buffer.from(a.deviceId)
  const right = Buffer.from(b.deviceId)
  return left.length === right.length && timingSafeEqual(left, right)
}
