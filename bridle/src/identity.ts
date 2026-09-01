/**
 * Bridle on-disk identity: the machine's long-term Noise key, the devices it
 * has accepted, and the pairing offer currently outstanding. The file is the
 * only secret this process owns, so it is created 0600 inside a 0700 directory
 * and rewritten atomically.
 */

import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { hostname, homedir, userInfo } from 'node:os'
import { join } from 'node:path'
import {
  deviceIdFor,
  generateKeyPair,
  generateSigningKeyPair,
  mintPairingToken,
  mintShortCode,
  publicKeyOf,
  signingPublicKeyOf,
  PAIRING_TTL_MS,
  type SigningKeyPair,
  type StaticKeyPair,
} from '@rowel/protocol'

/** On-disk format version; a newer file refuses to load on an older Bridle. */
const STATE_VERSION = 1

/** One device this Bridle has accepted. */
export interface PairedPeer {
  /** Raw static public key, base64url. */
  key: string
  /** Device name the app reported at pairing time. */
  name: string
  /** Epoch milliseconds of the pairing. */
  pairedAt: number
  /** Epoch milliseconds of the most recent successful handshake. */
  lastSeen: number
  /**
   * Where to ring this device when it is not attached.
   *
   * Learned inside the Noise channel and kept here rather than at the Relay,
   * so the Relay is handed a token only at the instant a push is sent and has
   * no standing list of who can be reached. Absent until the app offers one,
   * and removed when it withdraws it or Apple says the device is gone.
   *
   * Just the token: which APNs host minted it is Apple's question to answer,
   * not something three components should carry around.
   */
  push?: string
}

/** A pairing offer waiting to be claimed. */
export interface PairingOffer {
  /** One-time token embedded in the QR payload. */
  token: string
  /** Typed alternative to scanning. */
  code: string
  /** Epoch milliseconds after which the offer is refused. */
  expiresAt: number
}

/** The complete persisted state. */
export interface BridleState {
  version: number
  /** Stable machine id the Relay uses to pair sockets; derived from {@link BridleState.signingKey}. */
  deviceId: string
  /** Raw X25519 static private key, base64url. Authenticates the tunnel. */
  privateKey: string
  /** Raw Ed25519 private key, base64url. Claims the Relay device slot. */
  signingKey: string
  /** Display name of this machine. */
  machineName: string
  /** Relay base URL this Bridle dials out to. */
  relayUrl: string
  /** dsh base URL on loopback. */
  dshUrl: string
  /**
   * The DSH_HOME this identity fronts, when binding by home.
   *
   * The home is the instance's identity — its sessions, config, and (when it
   * declares one) its port all live there — so a binding recorded as a home
   * is anchored to the world itself, and `dshUrl` becomes a derived cache of
   * where that world answers. Optional: a plain URL binding works as before.
   */
  dshHome?: string
  peers: PairedPeer[]
  offer?: PairingOffer
}

/** Default public Relay. Overridable per install; the Relay never sees plaintext either way. */
export const DEFAULT_RELAY_URL = 'wss://rowel-relay.novabox.ai'

/**
 * Addresses this project used to ship as the default, and no longer serves.
 *
 * These are deliberately the *old* spellings, including the ones from before
 * the project was called Rowel. A list whose whole job is to remember names
 * that no longer work is the one place a rename must not reach — rewriting
 * these to the current hostname would turn the migration into a no-op and
 * leave every older install dialling a name with no record behind it.
 *
 * Two moves are recorded here. The relay left `reins.novabox.ai` so that the
 * public site and the infrastructure would stop sharing a hostname — one cache
 * rule, one WAF rule, or one "under attack" toggle aimed at the marketing pages
 * would otherwise take the relay with it, and the relay is the half that must
 * not go down. Then the project itself was renamed, and the relay moved again.
 *
 * Migrated on load rather than left to break, because the address lives in a
 * file written months ago and nobody would connect a silent connection failure
 * to a hostname they never chose. **Only these exact strings are rewritten** —
 * an address someone set themselves, or pointed at their own relay, is theirs
 * and is left alone.
 */
const RETIRED_RELAY_URLS: readonly string[] = [
  'wss://reins.novabox.ai',
  'wss://relay.novabox.ai',
  'wss://reins-relay.novabox.ai',
]

/** Default dsh loopback address, matching the web profile's own default port. */
export const DEFAULT_DSH_URL = 'http://127.0.0.1:3080'

/**
 * Resolve the Bridle home directory.
 * @returns `$ROWEL_HOME`, else `~/.rowel`.
 */
export function rowelHome(): string {
  return process.env['ROWEL_HOME'] ?? join(homedir(), '.rowel')
}

/**
 * Absolute path of the state file.
 * @returns `<ROWEL_HOME>/bridle.json`.
 */
export function statePath(): string {
  return join(rowelHome(), 'bridle.json')
}

function defaultMachineName(): string {
  const host = hostname().replace(/\.local$/u, '')
  if (host.length > 0) return host
  return `${userInfo().username}'s Mac`
}

/**
 * Load the persisted state, creating a fresh identity on first run.
 * @returns the current state, already written to disk.
 */
export function loadState(): BridleState {
  const home = rowelHome()
  mkdirSync(home, { recursive: true, mode: 0o700 })
  const path = statePath()
  let raw: string | undefined
  try {
    raw = readFileSync(path, 'utf8')
  } catch (error) {
    // Any read failure other than absence is a real problem worth reporting;
    // absence is the ordinary first-run path.
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
  if (raw !== undefined) {
    const parsed = JSON.parse(raw) as BridleState
    if (parsed.version > STATE_VERSION) {
      throw new Error(`${path} was written by a newer Bridle (format ${String(parsed.version)})`)
    }
    if (RETIRED_RELAY_URLS.includes(parsed.relayUrl)) {
      parsed.relayUrl = DEFAULT_RELAY_URL
      saveState(parsed)
    }
    return applyEnvironment(parsed)
  }
  const keys = generateKeyPair()
  const signing = generateSigningKeyPair()
  const state: BridleState = {
    version: STATE_VERSION,
    deviceId: deviceIdFor(signing.publicKey),
    privateKey: keys.privateKey.toString('base64url'),
    signingKey: signing.privateKey.toString('base64url'),
    machineName: defaultMachineName(),
    relayUrl: DEFAULT_RELAY_URL,
    dshUrl: DEFAULT_DSH_URL,
    peers: [],
  }
  saveState(state)
  return applyEnvironment(state)
}

/**
 * Overlay the environment on loaded state. The overrides are not persisted: a
 * `ROWEL_DSH_URL` set for one test run must not silently become the machine's
 * configuration.
 * @param state - state as read from disk.
 * @returns the same object with any overrides applied.
 */
function applyEnvironment(state: BridleState): BridleState {
  const relay = process.env['ROWEL_RELAY_URL']
  const dsh = process.env['ROWEL_DSH_URL']
  if (relay !== undefined && relay.length > 0) state.relayUrl = relay
  if (dsh !== undefined && dsh.length > 0) state.dshUrl = dsh
  return state
}

/**
 * Persist state atomically with owner-only permissions.
 * @param state - the state to write.
 */
export function saveState(state: BridleState): void {
  const home = rowelHome()
  mkdirSync(home, { recursive: true, mode: 0o700 })
  const path = statePath()
  const temporary = `${path}.${String(process.pid)}.tmp`
  writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 })
  renameSync(temporary, path)
  chmodSync(path, 0o600)
}

/**
 * The static key pair for this machine.
 * @param state - loaded state.
 * @returns the raw key pair.
 */
export function staticKeys(state: BridleState): StaticKeyPair {
  const privateKey = Buffer.from(state.privateKey, 'base64url')
  return { privateKey, publicKey: publicKeyOf(privateKey) }
}

/**
 * The Relay signing identity for this machine.
 * @param state - loaded state.
 * @returns the raw Ed25519 key pair whose hash is {@link BridleState.deviceId}.
 */
export function signingKeys(state: BridleState): SigningKeyPair {
  const privateKey = Buffer.from(state.signingKey, 'base64url')
  return { privateKey, publicKey: signingPublicKeyOf(privateKey) }
}

/**
 * Create (or refresh) the outstanding pairing offer.
 * @param state - loaded state, mutated and persisted.
 * @param now - current epoch milliseconds.
 * @returns the offer to render as a QR and a typed code.
 */
export function openPairingOffer(state: BridleState, now: number = Date.now()): PairingOffer {
  const offer: PairingOffer = {
    token: mintPairingToken(),
    code: mintShortCode(),
    expiresAt: now + PAIRING_TTL_MS,
  }
  state.offer = offer
  saveState(state)
  return offer
}

/**
 * Whether a claimed token matches the outstanding, unexpired offer.
 * @param state - loaded state.
 * @param token - token presented by the app.
 * @param now - current epoch milliseconds.
 * @returns true when the offer is live and the token matches.
 */
export function offerAccepts(state: BridleState, token: string, now: number = Date.now()): boolean {
  const offer = state.offer
  if (offer === undefined || offer.expiresAt <= now) return false
  // The token is high-entropy and single-use; a length-varying compare here
  // leaks nothing an attacker cannot already measure by trying.
  return offer.token === token
}

/**
 * Record a newly paired device and consume the offer.
 * @param state - loaded state, mutated and persisted.
 * @param key - the device's raw static public key.
 * @param name - the device name reported by the app.
 * @param now - current epoch milliseconds.
 */
export function acceptPeer(state: BridleState, key: Buffer, name: string, now: number = Date.now()): void {
  const encoded = key.toString('base64url')
  const existing = state.peers.find(peer => peer.key === encoded)
  if (existing !== undefined) {
    existing.name = name
    existing.lastSeen = now
  } else {
    state.peers.push({ key: encoded, name, pairedAt: now, lastSeen: now })
  }
  delete state.offer
  saveState(state)
}

/**
 * Look up an already-paired device.
 * @param state - loaded state.
 * @param key - the device's raw static public key.
 * @returns the peer record, or undefined when the device is unknown.
 */
export function findPeer(state: BridleState, key: Buffer): PairedPeer | undefined {
  const encoded = key.toString('base64url')
  return state.peers.find(peer => peer.key === encoded)
}

/**
 * Update a peer's last-seen stamp.
 * @param state - loaded state, mutated and persisted.
 * @param key - the device's raw static public key.
 * @param now - current epoch milliseconds.
 */
export function touchPeer(state: BridleState, key: Buffer, now: number = Date.now()): void {
  const peer = findPeer(state, key)
  if (peer === undefined) return
  peer.lastSeen = now
  saveState(state)
}

/**
 * Remove a paired device.
 * @param state - loaded state, mutated and persisted.
 * @param keyPrefix - full key or a unique base64url prefix.
 * @returns the removed peer, or undefined when nothing matched.
 */
export function revokePeer(state: BridleState, keyPrefix: string): PairedPeer | undefined {
  const index = state.peers.findIndex(peer => peer.key.startsWith(keyPrefix))
  if (index < 0) return undefined
  const [removed] = state.peers.splice(index, 1)
  saveState(state)
  return removed
}
