/**
 * One phone's connection to one Bridle: the Noise responder handshake, then the
 * tunnel frame loop.
 *
 * The carrier underneath is deliberately dumb — a Relay WebSocket, a LAN
 * WebSocket, or a pair of in-memory queues in the tests. Everything that
 * matters to security and to correctness happens here.
 */

import {
  NoiseError,
  NoiseResponder,
  TUNNEL_PROLOGUE,
  TUNNEL_VERSION,
  decodeFrame,
  encodeFrame,
  type ClientFrame,
  type SecureChannel,
  type ServerFrame,
} from '@reins/protocol'
import { acceptPeer, findPeer, offerAccepts, touchPeer } from '../identity.ts'
import type { BridleCore, DshStatus } from '../core.ts'
import type { LoggedEvent } from './event-log.ts'

/** The carrier a session writes through. */
export interface TunnelTransport {
  /** Deliver one carrier message. */
  send: (bytes: Buffer) => void
  /** Tear the carrier down. */
  close: (reason: string) => void
}

/** What the app states in the handshake payload. */
interface HandshakeRequest {
  /** Tunnel protocol version. */
  v?: number
  /** One-time pairing token; required only for a device that is not yet paired. */
  token?: string
  /** Device name, shown in `bridle status` and the revoke list. */
  name?: string
  /** App build string. */
  client?: string
}

/** What the Bridle states back inside handshake message two. */
interface HandshakeReply {
  ok: boolean
  /** Refusal reason when `ok` is false. */
  reason?: 'version' | 'unpaired' | 'internal'
  /** Human-readable machine name. */
  machine?: string
  /** Bridle package version. */
  bridle?: string
}

/** Concurrent dsh calls one phone may have outstanding. */
const MAX_INFLIGHT = 64

/** Tunnel-level liveness probe interval. */
const PING_INTERVAL_MS = 25_000

/** Version reported to the app; injected so the CLI and tests agree. */
export interface SessionOptions {
  /** Bridle package version string. */
  version: string
  /** Called once the peer is authenticated. */
  onAuthenticated?: (peerKey: Buffer, name: string) => void
  /** Called when the session ends, for any reason. */
  onClosed?: (reason: string) => void
}

/** A single authenticated tunnel. */
export class TunnelSession {
  private readonly responder: NoiseResponder
  private channel: SecureChannel | undefined
  private readonly inflight = new Map<string, AbortController>()
  private unsubscribe: (() => void) | undefined
  private unwatchStatus: (() => void) | undefined
  private pingTimer: NodeJS.Timeout | undefined
  private lastSent = 0
  private closed = false

  /**
   * @param core - the machine this tunnel is attached to.
   * @param transport - the carrier.
   * @param options - version string and lifecycle hooks.
   */
  constructor(
    private readonly core: BridleCore,
    private readonly transport: TunnelTransport,
    private readonly options: SessionOptions,
  ) {
    this.responder = new NoiseResponder(core.keys, TUNNEL_PROLOGUE)
  }

  /** The authenticated peer's static public key, once the handshake completes. */
  get peerKey(): Buffer | undefined {
    return this.channel?.remoteStatic
  }

  /**
   * Feed one carrier message.
   * @param bytes - the raw message, exactly as it arrived.
   */
  receive(bytes: Buffer): void {
    if (this.closed) return
    try {
      if (this.channel === undefined) this.handleHandshake(bytes)
      else this.handleFrame(decodeFrame(this.channel.decrypt(bytes)))
    } catch (error) {
      // Any failure before the channel exists, or any authentication failure
      // after it, means this carrier cannot be trusted to carry anything else.
      this.dispose(error instanceof NoiseError ? error.message : String(error))
    }
  }

  /**
   * End the session and release everything it holds.
   * @param reason - operator-facing reason, surfaced in logs.
   */
  dispose(reason: string): void {
    if (this.closed) return
    this.closed = true
    for (const controller of this.inflight.values()) controller.abort()
    this.inflight.clear()
    this.unsubscribe?.()
    this.unwatchStatus?.()
    if (this.pingTimer !== undefined) clearInterval(this.pingTimer)
    this.transport.close(reason)
    this.options.onClosed?.(reason)
  }

  private handleHandshake(bytes: Buffer): void {
    const { remoteStatic, payload } = this.responder.readMessage(bytes)
    let request: HandshakeRequest = {}
    if (payload.length > 0) {
      try {
        request = JSON.parse(payload.toString('utf8')) as HandshakeRequest
      } catch {
        this.refuse('internal')
        return
      }
    }
    if ((request.v ?? TUNNEL_VERSION) !== TUNNEL_VERSION) {
      this.refuse('version')
      return
    }
    const name = typeof request.name === 'string' && request.name.length > 0 ? request.name : 'iPhone'
    // Re-read the file before deciding. `bridle pair` and `bridle revoke` run in
    // a different process, and both have to take effect on the next handshake
    // rather than on the next restart — one grants access, the other removes it.
    this.core.refreshState()
    const known = findPeer(this.core.state, remoteStatic)
    if (known === undefined) {
      if (request.token === undefined || !offerAccepts(this.core.state, request.token)) {
        this.refuse('unpaired')
        return
      }
      acceptPeer(this.core.state, remoteStatic, name)
    } else {
      touchPeer(this.core.state, remoteStatic)
    }
    const reply: HandshakeReply = {
      ok: true,
      machine: this.core.state.machineName,
      bridle: this.options.version,
    }
    const { message, channel } = this.responder.writeMessage(Buffer.from(JSON.stringify(reply), 'utf8'))
    this.channel = channel
    this.transport.send(message)
    this.options.onAuthenticated?.(remoteStatic, name)
    this.afterHandshake()
  }

  private refuse(reason: NonNullable<HandshakeReply['reason']>): void {
    const reply: HandshakeReply = { ok: false, reason }
    try {
      const { message } = this.responder.writeMessage(Buffer.from(JSON.stringify(reply), 'utf8'))
      this.transport.send(message)
    } catch {
      // The peer sent something we could not even answer; closing is enough.
    }
    this.dispose(`handshake refused: ${reason}`)
  }

  private afterHandshake(): void {
    const status = this.core.dshStatus
    this.sendFrame({
      t: 'ready',
      version: TUNNEL_VERSION,
      bridle: this.options.version,
      machine: this.core.state.machineName,
      dshReachable: status.reachable,
      ...(status.host === undefined ? {} : { host: status.host }),
      seq: this.core.events.head,
    })
    this.unwatchStatus = this.core.onDshStatus((next: DshStatus) => {
      this.sendFrame({ t: 'status', dshReachable: next.reachable, ...(next.detail === undefined ? {} : { detail: next.detail }) })
    })
    this.pingTimer = setInterval(() => { this.sendFrame({ t: 'ping', nonce: String(Date.now()) }) }, PING_INTERVAL_MS)
    this.pingTimer.unref()
  }

  private handleFrame(frame: ClientFrame | ServerFrame): void {
    switch (frame.t) {
      case 'req':
        void this.handleRequest(frame.id, frame.method, frame.payload)
        return
      case 'cancel':
        this.inflight.get(frame.id)?.abort()
        this.inflight.delete(frame.id)
        return
      case 'respond':
        void this.handleRespond(frame.id, frame.message)
        return
      case 'resume':
        this.handleResume(frame.since)
        return
      case 'hello':
        // The handshake payload already carried this; answering with a fresh
        // ready keeps a reconnecting app from having to special-case order.
        this.afterHandshake()
        return
      case 'ping':
        this.sendFrame({ t: 'pong', nonce: frame.nonce })
        return
      case 'pong':
        return
      default:
        // Frames only the Bridle sends, or a newer app's additions. Ignoring an
        // unknown frame is what lets the protocol grow.
        return
    }
  }

  private handleResume(since: number): void {
    this.unsubscribe?.()
    const result = this.core.events.replay(since)
    if (result.kind === 'resync') {
      this.lastSent = result.from
      this.sendFrame({ t: 'resync', from: result.from })
    } else {
      this.lastSent = since
      for (const event of result.events) this.emit(event)
    }
    // Subscribing in the same synchronous tick as the replay is what makes this
    // gapless: no append can land between the two.
    this.unsubscribe = this.core.events.subscribe((event: LoggedEvent) => { this.emit(event) })
  }

  private emit(event: LoggedEvent): void {
    if (event.seq <= this.lastSent) return
    this.lastSent = event.seq
    this.sendFrame({ t: 'ev', seq: event.seq, stream: event.stream, frame: event.frame })
  }

  private async handleRequest(id: string, method: string, payload: unknown): Promise<void> {
    if (this.inflight.size >= MAX_INFLIGHT) {
      this.sendFrame({
        t: 'res',
        id,
        result: { ok: false, error: { code: 'busy', message: `more than ${String(MAX_INFLIGHT)} calls in flight`, details: {} } },
      })
      return
    }
    const controller = new AbortController()
    this.inflight.set(id, controller)
    try {
      const result = method === 'session.export'
        ? await this.exportSession(payload)
        : await this.core.dsh.call(method, payload, controller.signal)
      if (!this.closed) this.sendFrame({ t: 'res', id, result })
    } finally {
      this.inflight.delete(id)
    }
  }

  private async exportSession(payload: unknown): Promise<{ ok: true; value: unknown } | { ok: false; error: { code: string; message: string; details: unknown } }> {
    const request = payload as { sessionId?: unknown; includeDescendants?: unknown }
    if (typeof request.sessionId !== 'string') {
      return { ok: false, error: { code: 'bad-request', message: 'session.export needs a sessionId', details: {} } }
    }
    const response = await this.core.dsh.export(request.sessionId, request.includeDescendants === true)
    if (!response.ok) {
      return { ok: false, error: { code: 'internal', message: `dsh export answered HTTP ${String(response.status)}`, details: {} } }
    }
    const body = Buffer.from(await response.arrayBuffer())
    return {
      ok: true,
      value: {
        filename: filenameOf(response.headers.get('content-disposition')) ?? `${request.sessionId}.zip`,
        contentType: response.headers.get('content-type') ?? 'application/zip',
        base64: body.toString('base64'),
      },
    }
  }

  private async handleRespond(id: string, message: unknown): Promise<void> {
    try {
      const receipt = await this.core.dsh.respond(message)
      this.sendFrame({ t: 'res', id, result: { ok: true, value: receipt } })
    } catch (error) {
      this.sendFrame({
        t: 'res',
        id,
        result: { ok: false, error: { code: 'internal', message: error instanceof Error ? error.message : String(error), details: {} } },
      })
    }
  }

  private sendFrame(frame: ServerFrame): void {
    const channel = this.channel
    if (channel === undefined || this.closed) return
    try {
      this.transport.send(channel.encrypt(encodeFrame(frame)))
    } catch (error) {
      this.dispose(error instanceof Error ? error.message : String(error))
    }
  }
}

function filenameOf(disposition: string | null): string | undefined {
  if (disposition === null) return undefined
  const match = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/iu.exec(disposition)
  return match?.[1]
}
