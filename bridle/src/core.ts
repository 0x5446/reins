/**
 * The long-lived half of a Bridle: identity, the loopback dsh client, and the
 * downlink pumps that keep the replay buffer filled whether or not a phone is
 * currently attached.
 *
 * Tunnels come and go with the phone's radio. This does not.
 */

import { watch, type FSWatcher } from 'node:fs'
import { basename } from 'node:path'
import { DshClient, type DshHealth } from './dsh/client.ts'
import type { AgentClient } from './agents/types.ts'
import { EventLog } from './tunnel/event-log.ts'
import { loadState, reinsHome, saveState, statePath, staticKeys, type BridleState } from './identity.ts'
import type { StaticKeyPair } from '@reins/protocol'

/**
 * What makes one pending request distinguishable from another.
 *
 * `rpcId` is what dsh routes an answer by, so it is unique per request and
 * stable across the re-sends dsh performs for new subscribers. The approval or
 * question id is the fallback for a frame shaped differently.
 * @param frame - a mux frame, verbatim.
 * @returns a comparable identity, or undefined when the frame carries none.
 */
function identityOf(frame: unknown): string | undefined {
  const outer = frame as { rpcId?: unknown; payload?: { approvalId?: unknown; id?: unknown } }
  if (typeof outer.rpcId === 'string') return outer.rpcId
  if (typeof outer.payload?.approvalId === 'string') return outer.payload.approvalId
  if (typeof outer.payload?.id === 'string') return outer.payload.id
  return undefined
}

/** Current dsh reachability as the core last observed it. */
export interface DshStatus {
  reachable: boolean
  /** `host.describe` value from the last successful probe. */
  host?: unknown
  /** Operator-facing reason when unreachable. */
  detail?: string
}

/** How often to re-probe dsh while its downlinks are down. */
const HEALTH_INTERVAL_MS = 5_000

/** Everything a tunnel needs from the machine it is attached to. */
export class BridleCore {
  readonly state: BridleState
  readonly keys: StaticKeyPair
  readonly dsh: AgentClient
  readonly events: EventLog

  private readonly abort = new AbortController()
  private readonly statusListeners = new Set<(status: DshStatus) => void>()
  private readonly connected = new Set<'mux' | 'host'>()
  private status: DshStatus = { reachable: false, detail: 'not probed yet' }

  /**
   * The requests dsh is still waiting on a person for, by session.
   *
   * An approval or a question crosses the wire once, as a live event. A phone
   * that is not attached at that instant never learns the machine has stopped
   * — and "not attached at that instant" is the normal case for this app,
   * whose whole premise is that you are somewhere else. Opening Reins to find
   * out why the agent went quiet showed a conversation that simply stopped.
   *
   * dsh does not have this problem because it re-sends pending requests to
   * every new subscriber on the mux stream, which is what makes a browser
   * reload work. Bridle's subscription is long-lived, so it collects that
   * re-send only when *it* restarts, never when a phone reconnects. Holding
   * them here puts the same guarantee one layer further out, where the phones
   * actually come and go.
   *
   * Keyed by kind and session because that is the shape of the thing: a
   * session waits on one approval or one question at a time, and the
   * `resolved` event names the session rather than the request it closes.
   */
  private readonly waiting = new Map<string, unknown>()

  /**
   * Live tunnels, counted rather than listed.
   *
   * The only question anyone asks of it is "is there anybody there", which
   * decides whether a request that has stopped the agent needs a push to reach
   * a phone or will be delivered over a socket that already exists. A count
   * answers that; a list would invite someone to start addressing them
   * individually, and the two transports create their sessions in different
   * files.
   */
  private attachments = 0

  private readonly waitingListeners = new Set<() => void>()

  /**
   * The LAN addresses a phone can dial this machine on right now, best first.
   *
   * A function, not an array, and that is the whole point. The first version
   * stored the value the direct listener reported when it started, which made
   * every `ready` frame advertise the network the Mac was on at boot: a laptop
   * that moved from a hotspot to an office went on telling every phone to dial
   * the hotspot, forever, while `bridle status` — which recomputes — showed the
   * right one. Measured from the phone's own connection log, dialling an
   * address from the night before.
   *
   * Set by whoever owns the listener. The pairing bundle carries a copy too,
   * but that one is frozen at pairing time and this is what corrects it.
   */
  directAddresses: () => string[] = () => []
  private healthTimer: NodeJS.Timeout | undefined
  private watcher: FSWatcher | undefined
  private writing = false

  /**
   * @param state - loaded identity state; `dshUrl` selects the harness.
   * @param overrides - injection points for the dsh client and the replay depth.
   */
  constructor(state: BridleState = loadState(), overrides: { dsh?: AgentClient; eventCapacity?: number } = {}) {
    this.state = state
    this.keys = staticKeys(state)
    this.dsh = overrides.dsh ?? new DshClient({ baseUrl: state.dshUrl })
    this.events = overrides.eventCapacity === undefined ? new EventLog() : new EventLog(overrides.eventCapacity)
  }

  /** Every request still waiting on a person, for an app that just attached. */
  get pendingRequests(): unknown[] {
    return [...this.waiting.values()]
  }

  /** Whether any phone currently holds a tunnel, over either transport. */
  get attached(): number {
    return this.attachments
  }

  /**
   * Note a live tunnel.
   * @returns a function that forgets it; safe to call more than once.
   */
  attach(): () => void {
    this.attachments += 1
    this.waitingChanged()
    let released = false
    return (): void => {
      if (released) return
      released = true
      this.attachments -= 1
      // The moment that used to be missed: the last phone leaves while a
      // question it never answered is still outstanding.
      this.waitingChanged()
    }
  }

  /**
   * Watch for any change to whether somebody needs fetching.
   *
   * Not "a request arrived" — that was the first version and it was the wrong
   * event. Whether a phone should be rung is a *state*, standing on two facts
   * that both move: something is waiting on a person, and nobody is attached to
   * be told. A listener fired only when the first became true was wrong in both
   * directions. Asked while the phone was in someone's hand, no ring was ever
   * owed, so putting the phone down without answering left the machine waiting
   * in silence forever. And a ring owed while the Relay was down was still owed
   * when it returned, even if the question had been answered in the browser
   * meanwhile.
   *
   * So this fires whenever either fact changes and the listener decides again.
   * @param listener - called after the change is recorded.
   * @returns a function that detaches the listener.
   */
  onWaitingChanged(listener: () => void): () => void {
    this.waitingListeners.add(listener)
    return (): void => { this.waitingListeners.delete(listener) }
  }

  /** Tell every listener the answer may have changed. */
  private waitingChanged(): void {
    for (const listener of this.waitingListeners) {
      try {
        listener()
      } catch {
        // Same reasoning as every other listener here: one bad subscriber must
        // not stop the rest, and must not stop the event fold.
      }
    }
  }

  /**
   * Note a request that has stopped the agent, or forget one that was answered.
   * @param frame - a mux frame, verbatim.
   */
  private trackWaiting(frame: unknown): void {
    const payload = (frame as { payload?: { type?: unknown; sessionId?: unknown } }).payload
    const type = payload?.type
    const sessionId = payload?.sessionId
    if (typeof type !== 'string' || typeof sessionId !== 'string') return
    if (type === 'approval/requested' || type === 'question/requested') {
      const key = `${type}:${sessionId}`
      // The same request or a different one? dsh re-sends everything pending to
      // each new subscriber, and this Bridle resubscribes whenever dsh
      // restarts, so a repeat is usually a replay and ringing again would wake
      // someone for a question they were already woken for an hour ago.
      //
      // Usually, but not always. A downlink that drops can lose the `resolved`
      // event, and then a genuinely new question for the same session looks
      // exactly like a replay of the old one — nobody is rung, and the phone
      // shows the stale card. So the identity of the request decides, not the
      // session it belongs to.
      const identity = identityOf(frame)
      if (this.waiting.has(key) && identityOf(this.waiting.get(key)) === identity) return
      this.waiting.set(key, frame)
      for (const listener of this.waitingListeners) {
        try {
          listener()
        } catch {
          // Same reasoning as every other listener here: one bad subscriber
          // must not stop the rest, and must not stop the event fold.
        }
      }
      return
    }
    // Answered — by this phone, another one, or the browser on the machine
    // itself. Whoever it was, nobody should be asked again.
    // Answered — by this phone, another one, or the browser on the machine
    // itself. A listener re-deciding whether to ring has to hear this too:
    // an owed ring that was never sent because the Relay was down must not
    // survive the answer.
    const answered = (type === 'approval/resolved' && this.waiting.delete(`approval/requested:${sessionId}`))
      || (type === 'question/resolved' && this.waiting.delete(`question/requested:${sessionId}`))
    if (answered) this.waitingChanged()
  }

  /**
   * Stop holding a request for a session that no longer exists.
   *
   * The only way an entry could outlive its answer: a session deleted while it
   * was waiting on someone resolves nothing, so without this it would be
   * offered to every phone that ever attached, forever. Small, but the only
   * part of this bookkeeping that was not already bounded by construction.
   * @param frame - a host-stream frame, verbatim.
   */
  private forgetRemoved(frame: unknown): void {
    const payload = (frame as { payload?: { type?: unknown; sessionId?: unknown } }).payload
    if (payload?.type !== 'host/session-removed') return
    const sessionId = payload.sessionId
    if (typeof sessionId !== 'string') return
    this.waiting.delete(`approval/requested:${sessionId}`)
    this.waiting.delete(`question/requested:${sessionId}`)
  }

  /** dsh reachability as of the last probe or downlink transition. */
  get dshStatus(): DshStatus {
    return this.status
  }

  /**
   * Start the downlink pumps and the health probe.
   * @returns once the first health probe has completed.
   */
  async start(): Promise<void> {
    const signal = this.abort.signal
    void this.dsh.pump('mux', frame => {
      this.trackWaiting(frame)
      this.events.append('mux', frame)
    }, (up, detail) => { this.onStream('mux', up, detail) }, signal)
    void this.dsh.pump('host', frame => {
      this.forgetRemoved(frame)
      this.events.append('host', frame)
    }, (up, detail) => { this.onStream('host', up, detail) }, signal)
    await this.probe()
    this.healthTimer = setInterval(() => { void this.probe() }, HEALTH_INTERVAL_MS)
    this.healthTimer.unref()
    this.watchState()
  }

  /** Stop the pumps and release timers. */
  stop(): void {
    this.abort.abort()
    if (this.healthTimer !== undefined) clearInterval(this.healthTimer)
    this.watcher?.close()
  }

  /**
   * Re-read the parts of the state file another `bridle` invocation may have
   * changed: the paired devices, the outstanding offer, and the machine name.
   * The keys are never re-read — this process owns its identity for its whole
   * life, and a swapped key file should not silently take effect.
   */
  refreshState(): void {
    try {
      const fresh = loadState()
      this.state.peers = fresh.peers
      if (fresh.offer === undefined) delete this.state.offer
      else this.state.offer = fresh.offer
      this.state.machineName = fresh.machineName
    } catch {
      // A partially written file will be whole again in a moment, and the
      // in-memory copy is the better answer until then.
    }
  }

  /**
   * Pick up pairing offers and revocations made by another `bridle` invocation.
   * A running daemon and a `bridle pair` in a second terminal are the normal
   * case, so the daemon follows the file rather than owning it.
   *
   * The directory is watched rather than the file: `saveState` writes to a
   * temporary and renames it into place, which replaces the inode a file watch
   * is pinned to and would stop delivering events after the first save.
   */
  private watchState(): void {
    const name = basename(statePath())
    try {
      this.watcher = watch(reinsHome(), { persistent: false }, (_event, filename) => {
        if (filename !== null && filename !== name) return
        if (this.writing) return
        this.refreshState()
      })
    } catch {
      // Watching is an optimisation; every handshake re-reads the file anyway.
    }
  }

  /**
   * Watch dsh reachability.
   * @param listener - called on every transition, not on every probe.
   * @returns a function that detaches the listener.
   */
  onDshStatus(listener: (status: DshStatus) => void): () => void {
    this.statusListeners.add(listener)
    return (): void => { this.statusListeners.delete(listener) }
  }

  /** Persist the identity state after a mutation. */
  save(): void {
    this.writing = true
    try {
      saveState(this.state)
    } finally {
      // The watcher fires on the next tick; clearing later than the write keeps
      // this process from reloading its own change.
      setTimeout(() => { this.writing = false }, 50).unref()
    }
  }

  private onStream(stream: 'mux' | 'host', up: boolean, detail?: string): void {
    if (up) this.connected.add(stream)
    else this.connected.delete(stream)
    // A live downlink is stronger evidence than a periodic probe, so let it
    // drive the status directly rather than waiting up to five seconds.
    if (up && !this.status.reachable) void this.probe()
    else if (!up && this.connected.size === 0) this.publish({ reachable: false, ...(detail === undefined ? {} : { detail }) })
  }

  private async probe(): Promise<void> {
    const health: DshHealth = await this.dsh.health()
    this.publish(
      health.reachable
        ? { reachable: true, host: health.host }
        : { reachable: false, ...(health.detail === undefined ? {} : { detail: health.detail }) },
    )
  }

  private publish(next: DshStatus): void {
    if (next.reachable === this.status.reachable && next.detail === this.status.detail) {
      // Refresh the cached describe value without waking every listener.
      this.status = next
      return
    }
    this.status = next
    for (const listener of this.statusListeners) {
      try {
        listener(next)
      } catch {
        // Same reasoning as EventLog: one bad listener must not stall the rest.
      }
    }
  }
}
