/**
 * The one seam between the Bridle and whatever agent it is fronting.
 *
 * Everything above this line — the Noise tunnel, the replay buffer, pairing,
 * the Relay client, the direct listener — is agent-agnostic. Everything below
 * it speaks one specific agent's wire protocol. Five methods is the whole of
 * the contact surface, and keeping it five is what makes a second agent a new
 * file rather than a rewrite.
 *
 * The architecture document has claimed this seam exists for a while. Writing
 * it down as a type is what makes the claim checkable: `DshClient` now has to
 * satisfy it, and a test double can stand in its place without pretending to be
 * an HTTP server.
 *
 * **This does not mean a second agent is nearly free.** The methods below still
 * carry dsh's shapes — `pump` names dsh's two downlinks, `respond` takes dsh's
 * `client-response` envelope, and the frames that come out of `pump` are dsh's
 * `server-request` verbatim. A second backend needs a normalisation layer above
 * this interface, not just another implementation of it. See
 * `docs/architecture.md` §12, which now says so.
 */

/**
 * Result of one unary agent call.
 *
 * A discriminated union rather than `{ ok: boolean, value?, error? }`: the
 * looser shape lets a caller read `value` on a failure and get `undefined`
 * instead of a type error, which is exactly the mistake this boundary should
 * make impossible.
 */
export type AgentResult =
  | { ok: true; value: unknown }
  | { ok: false; error: { code: string; message: string; details: unknown } }

/** What one reachability probe found. */
export interface AgentHealth {
  reachable: boolean
  /** The agent's self-description when reachable. */
  host?: unknown
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** Which downlink a frame arrived on. */
export type AgentStream = 'mux' | 'host'

/** Unary and streaming access to one local agent. */
export interface AgentClient {
  /** The address this client talks to, for diagnostics. */
  readonly baseUrl: string

  /**
   * Invoke one agent method.
   * @param method - method name, passed through opaquely.
   * @param payload - the method's request payload.
   * @param signal - abandons the call.
   * @returns the business result; carrier failures fold into the error branch.
   */
  call: (method: string, payload: unknown, signal?: AbortSignal) => Promise<AgentResult>

  /**
   * Answer something the agent asked — an approval, a question.
   * @param message - the agent's response envelope, verbatim.
   * @returns the agent's receipt.
   */
  respond: (message: unknown) => Promise<unknown>

  /**
   * Probe reachability.
   * @returns whether the agent answered, and what it said about itself.
   */
  health: () => Promise<AgentHealth>

  /**
   * Follow one downlink until the signal aborts, redialling as needed.
   * @param stream - which downlink.
   * @param onFrame - called with each frame, verbatim.
   * @param onState - called when the downlink goes up or down.
   * @param signal - stops the pump.
   */
  pump: (
    stream: AgentStream,
    onFrame: (frame: unknown) => void,
    onState: (connected: boolean, detail?: string) => void,
    signal: AbortSignal,
  ) => Promise<void>

  /**
   * Export a session as an archive.
   * @param sessionId - the session to export.
   * @param includeDescendants - whether to include subagent sessions.
   * @returns the raw HTTP response, so the caller can read headers and bytes.
   */
  export: (sessionId: string, includeDescendants: boolean) => Promise<Response>
}
