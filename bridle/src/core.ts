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
    void this.dsh.pump('mux', frame => { this.events.append('mux', frame) }, (up, detail) => { this.onStream('mux', up, detail) }, signal)
    void this.dsh.pump('host', frame => { this.events.append('host', frame) }, (up, detail) => { this.onStream('host', up, detail) }, signal)
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
