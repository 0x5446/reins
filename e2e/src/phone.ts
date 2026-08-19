/**
 * A phone, in TypeScript.
 *
 * This is the reference implementation of the app side of the tunnel: the same
 * Noise IK handshake, the same frames, the same resume semantics that
 * `ios/Reins/Protocol` implements in Swift. Keeping it here does two things —
 * it lets the end-to-end tests drive a real Bridle against a real harness with
 * no simulator in the loop, and it gives the Swift code something authoritative
 * to be checked against.
 */

import WebSocket from 'ws'
import {
  NoiseInitiator,
  TUNNEL_PROLOGUE,
  TUNNEL_VERSIONS,
  decodeFrame,
  encodeFrame,
  generateKeyPair,
  type PairingBundle,
  type ReadyFrame,
  type SecureChannel,
  type ServerFrame,
  type StaticKeyPair,
  type StreamName,
} from '@reins/protocol'

/** The result shape every dsh method answers with. */
export type CallResult =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; details: unknown } }

/** One downlink frame as the phone sees it. */
export interface PhoneEvent {
  seq: number
  stream: StreamName
  frame: unknown
}

/** Options for {@link ReinsPhone}. */
export interface PhoneOptions {
  /** The pairing bundle scanned or claimed. */
  bundle: PairingBundle
  /** This device's long-term key pair; persist it across launches. */
  keys?: StaticKeyPair
  /** Device name shown on the machine's paired list. */
  name?: string
  /** App build string. */
  client?: string
  /** Force one carrier instead of racing them. */
  prefer?: 'direct' | 'relay'
  /** Whether the one-time pairing token should be presented. */
  pairing?: boolean
  /**
   * Versions to offer, overriding this build's own set.
   *
   * Exists so a test can be a client from the future or from the past without
   * checking out a different revision — which is the only way to prove the
   * compatibility window actually holds. `[]` reproduces the oldest clients,
   * which predate negotiation and send no `versions` key at all.
   */
  versions?: number[]
}

/** Thrown when the Bridle refuses the handshake. */
export class HandshakeRefused extends Error {
  /** @param reason - the machine-readable refusal reason. */
  constructor(readonly reason: string) {
    super(`bridle refused the connection: ${reason}`)
    this.name = 'HandshakeRefused'
  }
}

let requestCounter = 0

/** An app-side tunnel to one Bridle. */
export class ReinsPhone {
  readonly keys: StaticKeyPair
  private socket: WebSocket | undefined
  private channel: SecureChannel | undefined
  private readonly pending = new Map<string, (result: CallResult) => void>()
  private readonly eventListeners = new Set<(event: PhoneEvent) => void>()
  private readonly resyncListeners = new Set<(from: number) => void>()
  private ready: ReadyFrame | undefined
  private highestSeq = 0

  /** @param options - the pairing bundle and this device's identity. */
  constructor(private readonly options: PhoneOptions) {
    this.keys = options.keys ?? generateKeyPair()
  }

  /** The `ready` frame from the last successful connection. */
  get readyFrame(): ReadyFrame | undefined {
    return this.ready
  }

  /** Highest event sequence this phone has seen. */
  get seq(): number {
    return this.highestSeq
  }

  /**
   * Dial the machine and complete the handshake.
   * @returns the `ready` frame the Bridle sends first.
   * @throws {@link HandshakeRefused} when the machine will not accept this device.
   */
  async connect(): Promise<ReadyFrame> {
    const socket = await this.dial()
    this.socket = socket
    const initiator = new NoiseInitiator(this.keys, Buffer.from(this.options.bundle.key, 'base64url'), TUNNEL_PROLOGUE)
    const offered = this.options.versions ?? [...TUNNEL_VERSIONS]
    const payload = {
      // An empty override means "behave like a client that predates
      // negotiation": omit the key entirely rather than sending an empty list.
      ...(offered.length === 0 ? {} : { versions: offered }),
      name: this.options.name ?? 'iPhone',
      client: this.options.client ?? 'reins-reference/0.1.0',
      ...(this.options.pairing === false ? {} : { token: this.options.bundle.token }),
    }

    return new Promise<ReadyFrame>((resolve, reject) => {
      const timer = setTimeout(() => { reject(new Error('bridle did not send a ready frame')) }, 15_000)
      const fail = (error: Error): void => {
        clearTimeout(timer)
        reject(error)
      }
      this.onReady = (frame: ReadyFrame): void => {
        clearTimeout(timer)
        resolve(frame)
      }

      // The listener goes on before the first byte leaves. The Bridle answers
      // the handshake and sends `ready` back to back, and a WebSocket receiver
      // can emit both from one read — an await in between would drop the
      // second. The Swift client has to be written the same way.
      let handshakeDone = false
      socket.on('message', (data: WebSocket.RawData) => {
        const bytes = toBuffer(data)
        if (handshakeDone) {
          this.onMessage(bytes)
          return
        }
        handshakeDone = true
        try {
          const reply = initiator.readMessage(bytes)
          const parsed = JSON.parse(reply.payload.toString('utf8')) as { ok?: boolean; reason?: string }
          if (parsed.ok !== true) throw new HandshakeRefused(parsed.reason ?? 'unknown')
          this.channel = reply.channel
        } catch (error) {
          socket.close()
          fail(error instanceof Error ? error : new Error(String(error)))
        }
      })
      socket.on('close', () => {
        this.failAll('connection closed')
        fail(new Error('the machine closed the connection before it was ready'))
      })

      socket.send(initiator.writeMessage(Buffer.from(JSON.stringify(payload), 'utf8')), { binary: true })
    })
  }

  private onReady: ((frame: ReadyFrame) => void) | undefined

  /**
   * Ask for everything that happened while this phone was away.
   * @param since - the highest sequence already held; defaults to this phone's own.
   */
  resume(since: number = this.highestSeq): void {
    this.send({ t: 'resume', since })
  }

  /**
   * Invoke one dsh method.
   * @param method - method path, e.g. `session.list`.
   * @param payload - the method's request payload.
   * @returns the dsh result.
   */
  call(method: string, payload: unknown = {}): Promise<CallResult> {
    requestCounter += 1
    const id = `p${String(requestCounter)}`
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      this.send({ t: 'req', id, method, payload })
    })
  }

  /**
   * Answer an approval or question.
   * @param message - the dsh `client-response` message.
   * @returns the carrier receipt.
   */
  /**
   * Answer an approval or a question.
   *
   * Builds the envelope the harness expects, which is the part a client has to
   * get right: the answer is routed by the `rpcId` of the request it replies
   * to, so echoing the wrong one answers somebody else's question. The iOS app
   * builds the same shape; keeping it here too is what makes this a reference
   * rather than a test helper.
   * @param rpcId - from the `server-request` frame being answered.
   * @param value - that responder's own payload.
   * @returns the harness receipt.
   */
  answer(rpcId: string, value: unknown): Promise<CallResult> {
    return this.respond({
      type: 'client-response',
      rpcId,
      result: { ok: true, value },
    })
  }

  /**
   * Send a pre-built response envelope.
   * @param message - the `client-response` message, verbatim.
   * @returns the harness receipt.
   */
  respond(message: unknown): Promise<CallResult> {
    requestCounter += 1
    const id = `r${String(requestCounter)}`
    return new Promise((resolve) => {
      this.pending.set(id, resolve)
      this.send({ t: 'respond', id, message })
    })
  }

  /**
   * Abandon an in-flight call.
   * @param id - the request id.
   */
  cancel(id: string): void {
    this.send({ t: 'cancel', id })
  }

  /**
   * Offer, or withdraw, somewhere to be rung when this phone is not attached.
   * @param token - the APNs device token, or null to stop being rung.
   * @param environment - which APNs host minted it.
   */
  wake(token: string | null, environment: 'sandbox' | 'production' = 'sandbox'): void {
    this.send({ t: 'wake', token, environment })
  }

  /**
   * Watch downlink events.
   * @param listener - called for every event frame, in sequence order.
   * @returns a function that detaches the listener.
   */
  onEvent(listener: (event: PhoneEvent) => void): () => void {
    this.eventListeners.add(listener)
    return (): void => { this.eventListeners.delete(listener) }
  }

  /**
   * Watch for replay gaps.
   * @param listener - called when the Bridle could not replay far enough back.
   * @returns a function that detaches the listener.
   */
  onResync(listener: (from: number) => void): () => void {
    this.resyncListeners.add(listener)
    return (): void => { this.resyncListeners.delete(listener) }
  }

  /** Close the tunnel. */
  close(): void {
    this.failAll('closed by the app')
    this.socket?.close()
    this.socket = undefined
    this.channel = undefined
  }

  private async dial(): Promise<WebSocket> {
    const candidates: string[] = []
    if (this.options.prefer !== 'relay') for (const address of this.options.bundle.direct ?? []) candidates.push(`${address}/v1/tunnel`)
    if (this.options.prefer !== 'direct') {
      const relay = new URL('/v1/app', toWebSocket(this.options.bundle.relay))
      relay.searchParams.set('device', this.options.bundle.device)
      candidates.push(relay.toString())
    }
    const failures: string[] = []
    for (const candidate of candidates) {
      try {
        return await open(candidate)
      } catch (error) {
        // Trying the LAN address first costs one failed connect when the phone
        // is elsewhere, which is cheaper than always paying for the round trip.
        failures.push(`${candidate}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    throw new Error(`could not reach the machine (${failures.join('; ')})`)
  }

  private onMessage(bytes: Buffer): void {
    const channel = this.channel
    if (channel === undefined) return
    const frame = decodeFrame(channel.decrypt(bytes)) as ServerFrame
    switch (frame.t) {
      case 'ready':
        this.ready = frame
        this.onReady?.(frame)
        this.onReady = undefined
        return
      case 'res': {
        const resolve = this.pending.get(frame.id)
        this.pending.delete(frame.id)
        resolve?.(frame.result)
        return
      }
      case 'ev':
        this.highestSeq = Math.max(this.highestSeq, frame.seq)
        for (const listener of this.eventListeners) listener({ seq: frame.seq, stream: frame.stream, frame: frame.frame })
        return
      case 'resync':
        this.highestSeq = frame.from
        for (const listener of this.resyncListeners) listener(frame.from)
        return
      case 'ping':
        this.send({ t: 'pong', nonce: frame.nonce })
        return
      default:
        return
    }
  }

  private send(frame: Parameters<typeof encodeFrame>[0]): void {
    const channel = this.channel
    const socket = this.socket
    if (channel === undefined || socket === undefined) throw new Error('tunnel is not connected')
    socket.send(channel.encrypt(encodeFrame(frame)), { binary: true })
  }

  private failAll(reason: string): void {
    for (const [, resolve] of this.pending) {
      resolve({ ok: false, error: { code: 'disconnected', message: reason, details: {} } })
    }
    this.pending.clear()
  }
}

function toWebSocket(base: string): string {
  const url = new URL(base)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  return url.toString()
}

function open(address: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(address, { handshakeTimeout: 4_000 })
    socket.once('open', () => {
      socket.removeAllListeners('error')
      socket.removeAllListeners('close')
      resolve(socket)
    })
    socket.once('error', reject)
    socket.once('close', (code: number, reason: Buffer) => {
      reject(new Error(reason.length > 0 ? reason.toString() : `closed with ${String(code)}`))
    })
  })
}

function toBuffer(data: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data)
  return Buffer.from(data)
}
