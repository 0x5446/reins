/**
 * Tunnel frames: the application protocol carried inside the Noise channel.
 * One tunnel multiplexes every dsh interaction — unary RPC, the two event
 * downlinks, and cancellation — so the phone holds exactly one socket.
 *
 * Frames are JSON. The dsh API is JSON end to end (attachments ride as base64
 * inside it), so a binary framing would buy nothing and cost debuggability.
 */

/** Protocol version mixed into the Noise prologue; a mismatch aborts the handshake. */
export const TUNNEL_VERSION = 1

/** Noise prologue both ends mix in before the first handshake message. */
export const TUNNEL_PROLOGUE: Buffer = Buffer.from(`reins-tunnel/v${String(TUNNEL_VERSION)}`, 'utf8')

/** Which dsh downlink an event frame came from. */
export type StreamName = 'mux' | 'host'

/** App to Bridle: invoke one unary dsh method (`POST /api/<method>`). */
export interface RequestFrame {
  t: 'req'
  /** App-minted correlation id, unique per tunnel. */
  id: string
  /** dsh method path segment, e.g. `session.prompt` or `goals/create`. */
  method: string
  /** The dsh request payload (`{ args }` for Typert Remote methods). */
  payload: unknown
}

/** Bridle to App: the result of one {@link RequestFrame}. */
export interface ResponseFrame {
  t: 'res'
  id: string
  /** The dsh `server-response.result`, or a locally synthesized failure. */
  result: { ok: true; value: unknown } | { ok: false; error: { code: string; message: string; details: unknown } }
}

/** App to Bridle: abandon an in-flight request (maps to aborting the dsh fetch). */
export interface CancelFrame {
  t: 'cancel'
  id: string
}

/** App to Bridle: answer an approval or question (`POST /api/respond`). */
export interface RespondFrame {
  t: 'respond'
  id: string
  /** The dsh `client-response` message, verbatim. */
  message: unknown
}

/** Bridle to App: one downlink frame, tagged with a tunnel-level sequence. */
export interface EventFrame {
  t: 'ev'
  /** Monotonic per-tunnel sequence used by {@link ResumeFrame}. */
  seq: number
  stream: StreamName
  /** The dsh `server-request` frame, verbatim. */
  frame: unknown
}

/** App to Bridle: after a reconnect, replay everything past `since`. */
export interface ResumeFrame {
  t: 'resume'
  /** Highest sequence the app already has; `0` requests a fresh subscription. */
  since: number
}

/** Bridle to App: the replay buffer no longer reaches `since`; refetch state. */
export interface ResyncFrame {
  t: 'resync'
  /** First sequence the Bridle can still serve. */
  from: number
}

/** App to Bridle: opening frame stating what the app expects. */
export interface HelloFrame {
  t: 'hello'
  version: number
  /** Human-readable client build, shown in `bridle status`. */
  client: string
}

/** Bridle to App: connection is live; describes the machine and its dsh. */
export interface ReadyFrame {
  t: 'ready'
  version: number
  /** Bridle package version. */
  bridle: string
  /** Display name of the paired machine. */
  machine: string
  /** Whether the local dsh is reachable right now. */
  dshReachable: boolean
  /** dsh `host.describe` value when reachable. */
  host?: unknown
  /** Highest event sequence the Bridle has produced. */
  seq: number
}

/** Bridle to App: the local dsh went away or came back. */
export interface StatusFrame {
  t: 'status'
  dshReachable: boolean
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** Either direction: liveness probe. */
export interface PingFrame {
  t: 'ping'
  /** Echoed back verbatim. */
  nonce: string
}

/** Either direction: liveness answer. */
export interface PongFrame {
  t: 'pong'
  nonce: string
}

/** Bridle to App: a protocol-level refusal; the tunnel closes after it. */
export interface FaultFrame {
  t: 'fault'
  code: 'version' | 'unpaired' | 'internal' | 'busy'
  message: string
}

/** Frames the app may send. */
export type ClientFrame = HelloFrame | RequestFrame | CancelFrame | RespondFrame | ResumeFrame | PingFrame | PongFrame

/** Frames the Bridle may send. */
export type ServerFrame = ReadyFrame | ResponseFrame | EventFrame | ResyncFrame | StatusFrame | PingFrame | PongFrame | FaultFrame

/** Every tunnel frame. */
export type TunnelFrame = ClientFrame | ServerFrame

/**
 * Encode one frame for the Noise channel.
 * @param frame - the frame to send.
 * @returns UTF-8 JSON bytes.
 */
export function encodeFrame(frame: TunnelFrame): Buffer {
  return Buffer.from(JSON.stringify(frame), 'utf8')
}

/**
 * Decode one frame received from the Noise channel.
 * @param bytes - the decrypted frame body.
 * @returns the parsed frame.
 * @throws {@link Error} when the body is not a JSON object carrying a string `t`.
 */
export function decodeFrame(bytes: Buffer): TunnelFrame {
  let parsed: unknown
  try {
    parsed = JSON.parse(bytes.toString('utf8'))
  } catch {
    throw new Error('tunnel frame is not JSON')
  }
  if (typeof parsed !== 'object' || parsed === null || typeof (parsed as { t?: unknown }).t !== 'string') {
    throw new Error('tunnel frame has no type tag')
  }
  return parsed as TunnelFrame
}
