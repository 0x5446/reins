/**
 * Noise_IK_25519_ChaChaPoly_SHA256 over Node's standard library.
 *
 * The app is the initiator and already knows the Bridle's static public key
 * (it came off the pairing QR), which is exactly the IK pre-message. That buys
 * mutual authentication, forward secrecy once the second message lands, and
 * initiator-identity hiding from a passive relay — the Relay only ever sees
 * two ephemeral public keys and ciphertext.
 *
 * One documented deviation from the Noise spec: transport messages are not
 * capped at 65535 bytes. Session attachments ride the dsh API as base64 inside
 * a JSON body, so a single frame can be several megabytes. The AEAD is
 * length-agnostic and the 64-bit counter is nowhere near exhaustion, so the cap
 * buys nothing here; handshake messages still obey it.
 */

import {
  createHmac,
  createCipheriv,
  createDecipheriv,
  createHash,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  timingSafeEqual,
  type KeyObject,
} from 'node:crypto'

/** Wire name of the concrete Noise instantiation both ends must agree on. */
export const PROTOCOL_NAME = 'Noise_IK_25519_ChaChaPoly_SHA256'

/** Raw X25519 public-key length. */
export const KEY_LENGTH = 32

/** Poly1305 tag length appended to every ciphertext. */
export const TAG_LENGTH = 16

const DER_PUBLIC_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')
const DER_PRIVATE_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex')

/** An X25519 key pair in the raw 32-byte form the wire and disk both use. */
export interface StaticKeyPair {
  /** Raw 32-byte private scalar. */
  readonly privateKey: Buffer
  /** Raw 32-byte public key. */
  readonly publicKey: Buffer
}

/**
 * Generate a fresh X25519 key pair.
 * @returns the raw 32-byte private and public keys.
 */
export function generateKeyPair(): StaticKeyPair {
  const pair = generateKeyPairSync('x25519')
  return {
    privateKey: rawPrivate(pair.privateKey),
    publicKey: rawPublic(pair.publicKey),
  }
}

/**
 * Recover the public key of a raw X25519 private key.
 * @param privateKey - raw 32-byte private scalar.
 * @returns the matching raw 32-byte public key.
 */
export function publicKeyOf(privateKey: Buffer): Buffer {
  return rawPublic(createPublicKey(importPrivate(privateKey)))
}

function rawPublic(key: KeyObject): Buffer {
  return key.export({ type: 'spki', format: 'der' }).subarray(DER_PUBLIC_PREFIX.length)
}

function rawPrivate(key: KeyObject): Buffer {
  return key.export({ type: 'pkcs8', format: 'der' }).subarray(DER_PRIVATE_PREFIX.length)
}

function importPrivate(raw: Buffer): KeyObject {
  assertKeyLength(raw, 'private key')
  return createPrivateKey({ key: Buffer.concat([DER_PRIVATE_PREFIX, raw]), format: 'der', type: 'pkcs8' })
}

function importPublic(raw: Buffer): KeyObject {
  assertKeyLength(raw, 'public key')
  return createPublicKey({ key: Buffer.concat([DER_PUBLIC_PREFIX, raw]), format: 'der', type: 'spki' })
}

function assertKeyLength(raw: Buffer, what: string): void {
  if (raw.length !== KEY_LENGTH) throw new NoiseError(`${what} must be ${String(KEY_LENGTH)} bytes`)
}

/**
 * X25519 agreement over raw keys.
 * @param privateKey - raw 32-byte private scalar.
 * @param publicKey - raw 32-byte peer public key.
 * @returns the 32-byte shared secret.
 */
function dh(privateKey: Buffer, publicKey: Buffer): Buffer {
  return diffieHellman({ privateKey: importPrivate(privateKey), publicKey: importPublic(publicKey) })
}

/** Handshake or transport failure. Never carries key material in its message. */
export class NoiseError extends Error {
  /** @param message - correction-oriented diagnostic with no secret values. */
  constructor(message: string) {
    super(message)
    this.name = 'NoiseError'
  }
}

/** Noise HKDF: RFC 5869 with an empty info, returning the first two 32-byte outputs. */
function hkdf2(chainingKey: Buffer, inputKeyMaterial: Buffer): [Buffer, Buffer] {
  const out = Buffer.from(hkdfSync('sha256', inputKeyMaterial, chainingKey, Buffer.alloc(0), 64))
  return [out.subarray(0, 32), out.subarray(32, 64)]
}

function sha256(...parts: Buffer[]): Buffer {
  const hash = createHash('sha256')
  for (const part of parts) hash.update(part)
  return hash.digest()
}

/** Noise 12-byte nonce: four zero bytes then the little-endian counter. */
function nonceFor(counter: bigint): Buffer {
  const nonce = Buffer.alloc(12)
  nonce.writeBigUInt64LE(counter, 4)
  return nonce
}

function seal(key: Buffer, counter: bigint, associatedData: Buffer, plaintext: Buffer): Buffer {
  const cipher = createCipheriv('chacha20-poly1305', key, nonceFor(counter), { authTagLength: TAG_LENGTH })
  cipher.setAAD(associatedData, { plaintextLength: plaintext.length })
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()])
  return Buffer.concat([body, cipher.getAuthTag()])
}

function open(key: Buffer, counter: bigint, associatedData: Buffer, ciphertext: Buffer): Buffer {
  if (ciphertext.length < TAG_LENGTH) throw new NoiseError('ciphertext shorter than its authentication tag')
  const body = ciphertext.subarray(0, ciphertext.length - TAG_LENGTH)
  const tag = ciphertext.subarray(ciphertext.length - TAG_LENGTH)
  const decipher = createDecipheriv('chacha20-poly1305', key, nonceFor(counter), { authTagLength: TAG_LENGTH })
  decipher.setAAD(associatedData, { plaintextLength: body.length })
  decipher.setAuthTag(tag)
  try {
    return Buffer.concat([decipher.update(body), decipher.final()])
  } catch {
    // The tag is the only thing that can fail here, and saying which byte
    // differed would be an oracle.
    throw new NoiseError('frame failed authentication')
  }
}

/** The Noise SymmetricState: the running hash, chaining key, and handshake cipher. */
class SymmetricState {
  private chainingKey: Buffer
  private hash: Buffer
  private key: Buffer | undefined
  private counter = 0n

  constructor(protocolName: string) {
    const name = Buffer.from(protocolName, 'utf8')
    this.hash = name.length <= 32 ? Buffer.concat([name, Buffer.alloc(32 - name.length)]) : sha256(name)
    this.chainingKey = Buffer.from(this.hash)
  }

  mixHash(data: Buffer): void {
    this.hash = sha256(this.hash, data)
  }

  mixKey(inputKeyMaterial: Buffer): void {
    const [chainingKey, key] = hkdf2(this.chainingKey, inputKeyMaterial)
    this.chainingKey = chainingKey
    this.key = key
    this.counter = 0n
  }

  encryptAndHash(plaintext: Buffer): Buffer {
    if (this.key === undefined) {
      this.mixHash(plaintext)
      return plaintext
    }
    const ciphertext = seal(this.key, this.counter, this.hash, plaintext)
    this.counter += 1n
    this.mixHash(ciphertext)
    return ciphertext
  }

  decryptAndHash(ciphertext: Buffer): Buffer {
    if (this.key === undefined) {
      this.mixHash(ciphertext)
      return ciphertext
    }
    const plaintext = open(this.key, this.counter, this.hash, ciphertext)
    this.counter += 1n
    this.mixHash(ciphertext)
    return plaintext
  }

  split(): [Buffer, Buffer] {
    return hkdf2(this.chainingKey, Buffer.alloc(0))
  }

  /** Channel binding value: the final handshake hash, safe to compare in the clear. */
  get handshakeHash(): Buffer {
    return Buffer.from(this.hash)
  }
}

/**
 * One direction of an established channel. Counters are strictly monotonic in
 * both directions, so a replayed or reordered frame fails decryption instead of
 * being accepted out of order.
 */
class CipherState {
  private counter = 0n

  constructor(private readonly key: Buffer) {}

  encrypt(plaintext: Buffer): Buffer {
    const frame = seal(this.key, this.counter, Buffer.alloc(0), plaintext)
    this.counter += 1n
    return frame
  }

  decrypt(ciphertext: Buffer): Buffer {
    const plaintext = open(this.key, this.counter, Buffer.alloc(0), ciphertext)
    this.counter += 1n
    return plaintext
  }
}

/** An established, authenticated, bidirectional channel. */
export class SecureChannel {
  /**
   * @param send - cipher state for outbound frames.
   * @param receive - cipher state for inbound frames.
   * @param remoteStatic - the authenticated raw public key of the peer.
   * @param handshakeHash - channel binding value for out-of-band verification.
   */
  constructor(
    private readonly send: CipherState,
    private readonly receive: CipherState,
    readonly remoteStatic: Buffer,
    readonly handshakeHash: Buffer,
  ) {}

  /**
   * Encrypt one outbound frame.
   * @param plaintext - frame body.
   * @returns the ciphertext to hand to the carrier.
   */
  encrypt(plaintext: Buffer): Buffer {
    return this.send.encrypt(plaintext)
  }

  /**
   * Decrypt one inbound frame.
   * @param ciphertext - exactly one carrier message.
   * @returns the frame body.
   * @throws {@link NoiseError} when authentication, ordering, or replay checks fail.
   */
  decrypt(ciphertext: Buffer): Buffer {
    return this.receive.decrypt(ciphertext)
  }
}

/**
 * Initiator half of Noise IK (the phone). Knows the responder's static key up
 * front from the pairing payload.
 */
export class NoiseInitiator {
  private readonly state = new SymmetricState(PROTOCOL_NAME)
  private written = false

  /**
   * @param staticKeys - this device's long-term key pair.
   * @param remoteStatic - the Bridle's raw static public key from pairing.
   * @param prologue - bytes both ends mix in before the handshake (protocol version).
   * @param ephemeral - test-only override making a transcript reproducible; a
   * fresh random ephemeral per handshake is what provides forward secrecy, so
   * nothing outside the cross-implementation vectors may pass this.
   */
  constructor(
    private readonly staticKeys: StaticKeyPair,
    private readonly remoteStatic: Buffer,
    prologue: Buffer = Buffer.alloc(0),
    private readonly ephemeral: StaticKeyPair = generateKeyPair(),
  ) {
    assertKeyLength(remoteStatic, 'remote static key')
    this.state.mixHash(prologue)
    this.state.mixHash(remoteStatic)
  }

  /**
   * Produce handshake message one (`e, es, s, ss`).
   * @param payload - application payload carried inside the message.
   * @returns the bytes to send.
   */
  writeMessage(payload: Buffer): Buffer {
    if (this.written) throw new NoiseError('handshake message one was already written')
    this.written = true
    this.state.mixHash(this.ephemeral.publicKey)
    this.state.mixKey(dh(this.ephemeral.privateKey, this.remoteStatic))
    const encryptedStatic = this.state.encryptAndHash(this.staticKeys.publicKey)
    this.state.mixKey(dh(this.staticKeys.privateKey, this.remoteStatic))
    const encryptedPayload = this.state.encryptAndHash(payload)
    return Buffer.concat([this.ephemeral.publicKey, encryptedStatic, encryptedPayload])
  }

  /**
   * Consume handshake message two (`e, ee, se`) and establish the channel.
   * @param message - the responder's handshake bytes.
   * @returns the established channel and the responder's payload.
   */
  readMessage(message: Buffer): { channel: SecureChannel; payload: Buffer } {
    if (!this.written) throw new NoiseError('handshake message one has not been written')
    if (message.length < KEY_LENGTH) throw new NoiseError('handshake message two is truncated')
    const remoteEphemeral = message.subarray(0, KEY_LENGTH)
    this.state.mixHash(remoteEphemeral)
    this.state.mixKey(dh(this.ephemeral.privateKey, remoteEphemeral))
    this.state.mixKey(dh(this.staticKeys.privateKey, remoteEphemeral))
    const payload = this.state.decryptAndHash(message.subarray(KEY_LENGTH))
    const [sendKey, receiveKey] = this.state.split()
    return {
      channel: new SecureChannel(
        new CipherState(sendKey),
        new CipherState(receiveKey),
        Buffer.from(this.remoteStatic),
        this.state.handshakeHash,
      ),
      payload,
    }
  }
}

/** Responder half of Noise IK (the Bridle). */
export class NoiseResponder {
  private readonly state = new SymmetricState(PROTOCOL_NAME)
  private remoteStatic: Buffer | undefined
  private remoteEphemeral: Buffer | undefined

  /**
   * @param staticKeys - the Bridle's long-term key pair.
   * @param prologue - bytes both ends mix in before the handshake (protocol version).
   * @param ephemeral - test-only override; see {@link NoiseInitiator}.
   */
  constructor(
    private readonly staticKeys: StaticKeyPair,
    prologue: Buffer = Buffer.alloc(0),
    private readonly ephemeral: StaticKeyPair = generateKeyPair(),
  ) {
    this.state.mixHash(prologue)
    this.state.mixHash(staticKeys.publicKey)
  }

  /**
   * Consume handshake message one and recover the initiator's identity.
   * @param message - the initiator's handshake bytes.
   * @returns the initiator's authenticated static key and its payload.
   */
  readMessage(message: Buffer): { remoteStatic: Buffer; payload: Buffer } {
    if (this.remoteStatic !== undefined) throw new NoiseError('handshake message one was already read')
    const minimum = KEY_LENGTH + KEY_LENGTH + TAG_LENGTH
    if (message.length < minimum) throw new NoiseError('handshake message one is truncated')
    const remoteEphemeral = message.subarray(0, KEY_LENGTH)
    this.remoteEphemeral = remoteEphemeral
    this.state.mixHash(remoteEphemeral)
    this.state.mixKey(dh(this.staticKeys.privateKey, remoteEphemeral))
    const remoteStatic = this.state.decryptAndHash(message.subarray(KEY_LENGTH, minimum))
    assertKeyLength(remoteStatic, 'peer static key')
    this.state.mixKey(dh(this.staticKeys.privateKey, remoteStatic))
    const payload = this.state.decryptAndHash(message.subarray(minimum))
    this.remoteStatic = remoteStatic
    return { remoteStatic, payload }
  }

  /**
   * Produce handshake message two and establish the channel.
   * @param payload - application payload carried inside the message.
   * @returns the bytes to send and the established channel.
   */
  writeMessage(payload: Buffer): { message: Buffer; channel: SecureChannel } {
    const remoteStatic = this.remoteStatic
    const remoteEphemeral = this.remoteEphemeral
    if (remoteStatic === undefined || remoteEphemeral === undefined) {
      throw new NoiseError('handshake message one has not been read')
    }
    this.state.mixHash(this.ephemeral.publicKey)
    this.state.mixKey(dh(this.ephemeral.privateKey, remoteEphemeral))
    this.state.mixKey(dh(this.ephemeral.privateKey, remoteStatic))
    const encryptedPayload = this.state.encryptAndHash(payload)
    const [receiveKey, sendKey] = this.state.split()
    return {
      message: Buffer.concat([this.ephemeral.publicKey, encryptedPayload]),
      channel: new SecureChannel(
        new CipherState(sendKey),
        new CipherState(receiveKey),
        Buffer.from(remoteStatic),
        this.state.handshakeHash,
      ),
    }
  }
}

/**
 * Constant-time equality for public keys and pairing tokens.
 * @param a - first value.
 * @param b - second value.
 * @returns whether the two byte strings are identical.
 */
export function constantTimeEqual(a: Buffer, b: Buffer): boolean {
  return a.length === b.length && timingSafeEqual(a, b)
}
