/**
 * The replay buffer that makes a phone's connection lossless.
 *
 * The web UI can be sloppy about disconnects: it is on a desk, and when the
 * socket blinks it just refetches everything. A phone drops its socket every
 * time it changes cell, locks, or backgrounds, and refetching a long session
 * each time is both slow and visibly wrong — a half-written assistant message
 * would jump. So Bridle keeps subscribing to dsh whether or not anyone is
 * listening, numbers every downlink frame, and replays the gap on reconnect.
 */

import type { StreamName } from '@rowel/protocol'

/** One buffered downlink frame. */
export interface LoggedEvent {
  /** Monotonic per-process sequence. */
  seq: number
  stream: StreamName
  /** The dsh `server-request` frame, verbatim. */
  frame: unknown
}

/** What a resume request can be answered with. */
export type ReplayResult =
  | { kind: 'replay'; events: LoggedEvent[] }
  /** The gap is wider than the buffer; the app must refetch state from `from`. */
  | { kind: 'resync'; from: number }

/** Frames retained by default: roughly a long working session's worth of deltas. */
const DEFAULT_CAPACITY = 2000

/** Fed by the dsh downlinks, read by whatever tunnel is currently attached. */
export class EventLog {
  private readonly buffer: LoggedEvent[] = []
  private readonly capacity: number
  private readonly listeners = new Set<(event: LoggedEvent) => void>()
  private sequence = 0

  /** @param capacity - how many frames to retain. */
  constructor(capacity: number = DEFAULT_CAPACITY) {
    this.capacity = capacity
  }

  /** Highest sequence issued so far; `0` before the first frame. */
  get head(): number {
    return this.sequence
  }

  /** Lowest sequence still retained; `head + 1` when the buffer is empty. */
  get tail(): number {
    return this.buffer[0]?.seq ?? this.sequence + 1
  }

  /**
   * Record one downlink frame and notify the attached tunnel.
   * @param stream - which dsh downlink produced it.
   * @param frame - the frame, verbatim.
   * @returns the logged event, carrying its assigned sequence.
   */
  append(stream: StreamName, frame: unknown): LoggedEvent {
    this.sequence += 1
    const event: LoggedEvent = { seq: this.sequence, stream, frame }
    this.buffer.push(event)
    if (this.buffer.length > this.capacity) this.buffer.splice(0, this.buffer.length - this.capacity)
    for (const listener of this.listeners) {
      try {
        listener(event)
      } catch {
        // A listener that throws is a broken tunnel, not a reason to stop
        // buffering for everyone else.
      }
    }
    return event
  }

  /**
   * Answer a resume request.
   * @param since - the highest sequence the app already holds.
   * @returns the missing frames, or an instruction to refetch.
   */
  replay(since: number): ReplayResult {
    if (since >= this.sequence) {
      // Also covers the app claiming a sequence from a previous Bridle process:
      // there is nothing to replay, and the fresh subscription starts clean.
      return since > this.sequence ? { kind: 'resync', from: this.sequence } : { kind: 'replay', events: [] }
    }
    if (since + 1 < this.tail) return { kind: 'resync', from: this.sequence }
    return { kind: 'replay', events: this.buffer.filter(event => event.seq > since) }
  }

  /**
   * Attach a live listener.
   * @param listener - called for every subsequent {@link append}.
   * @returns a function that detaches the listener.
   */
  subscribe(listener: (event: LoggedEvent) => void): () => void {
    this.listeners.add(listener)
    return (): void => { this.listeners.delete(listener) }
  }
}
