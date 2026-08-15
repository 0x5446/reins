/**
 * A harness that does exactly what a test tells it to.
 *
 * The real dsh is the right thing to test against for most of the suite, and
 * `tunnel.test.js` does. But some behaviour cannot be provoked on cue: an
 * approval arriving at a chosen instant, a question with a known shape, a
 * downlink dropping mid-turn. Waiting for a model to decide to run `rm` is not
 * a test, it is a hope.
 *
 * So this implements the same five-method seam the Bridle talks to
 * (`AgentClient`), and hands the test a lever for each of those moments. Using
 * it is also the only proof that the seam is real: if `AgentClient` had secretly
 * grown a sixth requirement, this file would not compile.
 */

import type { AgentClient, AgentHealth, AgentResult, AgentStream } from '@reins/bridle'

/** One call the Bridle forwarded, recorded for assertions. */
export interface RecordedCall {
  method: string
  payload: unknown
}

export class FakeAgent implements AgentClient {
  readonly baseUrl = 'http://127.0.0.1:0'
  /** Every unary call the Bridle forwarded, in order. */
  readonly calls: RecordedCall[] = []
  /** Every `client-response` envelope the Bridle forwarded back. */
  readonly responses: unknown[] = []

  private readonly listeners = new Map<AgentStream, (frame: unknown) => void>()
  private reachable = true

  /** Answers keyed by method; anything unlisted returns an empty object. */
  readonly answers = new Map<string, AgentResult>()

  /**
   * Answers computed from the payload, for the cases a fixed value cannot
   * express — a page whose size depends on how many messages were asked for,
   * a call that should fail only the third time.
   */
  private readonly handlers = new Map<string, (payload: any) => AgentResult>()

  /**
   * Answer this method by running a function over its payload.
   * @param method - the method to intercept.
   * @param handler - called with the payload; its return value is the answer.
   */
  handle(method: string, handler: (payload: any) => AgentResult): void {
    this.handlers.set(method, handler)
  }

  async call(method: string, payload: unknown): Promise<AgentResult> {
    this.calls.push({ method, payload })
    const handler = this.handlers.get(method)
    if (handler !== undefined) return Promise.resolve(handler(payload))
    return Promise.resolve(this.answers.get(method) ?? { ok: true, value: {} })
  }

  async respond(message: unknown): Promise<unknown> {
    this.responses.push(message)
    return Promise.resolve({ accepted: true })
  }

  async health(): Promise<AgentHealth> {
    return Promise.resolve(
      this.reachable
        ? { reachable: true, host: { version: 'fake', cwd: '/tmp' } }
        : { reachable: false, detail: 'the fake harness was told to be down' },
    )
  }

  async pump(
    stream: AgentStream,
    onFrame: (frame: unknown) => void,
    onState: (connected: boolean, detail?: string) => void,
    signal: AbortSignal,
  ): Promise<void> {
    this.listeners.set(stream, onFrame)
    onState(true)
    // Stay up until the Bridle tears down, the way a real downlink does.
    await new Promise<void>((resolve) => {
      if (signal.aborted) { resolve(); return }
      signal.addEventListener('abort', () => { resolve() }, { once: true })
    })
    this.listeners.delete(stream)
  }

  async export(): Promise<Response> {
    return Promise.resolve(new Response(Buffer.from('fake archive'), {
      headers: { 'content-type': 'application/zip' },
    }))
  }

  // MARK: - Levers

  /**
   * Emit one downlink frame, exactly as dsh would.
   * @param frame - the `server-request` envelope.
   * @param stream - which downlink; defaults to the session mux.
   */
  emit(frame: unknown, stream: AgentStream = 'mux'): void {
    const listener = this.listeners.get(stream)
    if (listener === undefined) throw new Error(`nothing is pumping ${stream} yet`)
    listener(frame)
  }

  /**
   * Ask for approval of a tool call, the way dsh does.
   * @param options - which session, and what is being approved.
   * @returns the rpcId the answer has to echo.
   */
  requestApproval(options: { sessionId: string; toolName: string; reason?: string }): string {
    const rpcId = `fake-approval-${String(this.calls.length + this.responses.length + 1)}`
    this.emit({
      type: 'server-request',
      rpcId,
      payload: {
        type: 'approval/requested',
        sessionId: options.sessionId,
        approvalId: `a-${rpcId}`,
        toolName: options.toolName,
        ...(options.reason === undefined ? {} : { reason: options.reason }),
      },
    })
    return rpcId
  }

  /**
   * Ask the person a question, the way dsh does.
   * @param options - which session, and what to ask.
   * @returns the rpcId the answer has to echo.
   */
  askQuestion(options: { sessionId: string; question: string; options: string[] }): string {
    const rpcId = `fake-question-${String(this.calls.length + this.responses.length + 1)}`
    this.emit({
      type: 'server-request',
      rpcId,
      payload: {
        type: 'question/requested',
        sessionId: options.sessionId,
        questions: [{
          id: 'q1',
          question: options.question,
          options: options.options.map(label => ({ label })),
          multiSelect: false,
        }],
      },
    })
    return rpcId
  }

  /** Whether `pump` has been called for a stream yet. */
  isPumping(stream: AgentStream = 'mux'): boolean {
    return this.listeners.has(stream)
  }
}
