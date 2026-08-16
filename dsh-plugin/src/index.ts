/**
 * The Bridle, as a plugin dsh loads itself.
 *
 * Same Bridle, second doorway. `bridle` the command is right for someone who
 * wants it supervised separately, or who will point it at a different agent
 * later; this is right for the common case, where the answer to "what do I
 * install" should be one line and the thing should start and stop with dsh.
 *
 *   dsh plugin --profile web add @reins/bridle-plugin
 *
 * It still speaks to dsh over loopback HTTP rather than reaching into the
 * process it is running inside. That looks wasteful and is not: the call never
 * leaves the machine, it is the same path the standalone binary uses and the
 * same path every test covers, and it keeps this file a lifecycle wrapper
 * instead of a second implementation that can drift.
 *
 * What it does NOT do is change the security model. The listener it opens
 * speaks only the Noise tunnel, exactly as before — dsh's own API stays bound
 * to loopback and stays unreachable to anything that has not completed a
 * handshake.
 */

import {
  BridleCore,
  DirectServer,
  RelayClient,
  clearRuntime,
  loadState,
  writeRuntime,
  type BridleState,
} from '@reins/bridle'

/** How often to refresh the snapshot `bridle status` reads. */
const HEARTBEAT_MS = 5_000

/** Shown in dsh's plugin list and in diagnostics. */
export const name = 'reins-bridle'

/** What the plugin page writes, and what `cordis.yml` can set by hand. */
export interface BridlePluginConfig {
  /** Relay to dial out to. Empty disables the relay and leaves only direct paths. */
  relay?: string
  /** dsh's own address. Defaults to the loopback web profile. */
  dsh?: string
  /** Fixed port for the local-network listener; `0` lets the OS choose. */
  directPort?: number
  /** Turn off the local-network listener entirely. */
  noDirect?: boolean
  /**
   * Extra addresses to put in the pairing code — a tunnel hostname the machine
   * cannot discover for itself. LAN and Tailscale addresses are found by
   * enumerating interfaces and do not belong here.
   */
  advertise?: string[]
}

/** The version reported to a paired app; overridden by the build. */
const VERSION = '0.1.0'

/**
 * Cordis entry point.
 * @param ctx - the plugin context; its dispose hook owns teardown.
 * @param config - plugin settings, all optional.
 */
export function apply(ctx: { on: (event: 'dispose', handler: () => void) => void }, config: BridlePluginConfig = {}): void {
  const state: BridleState = loadState()
  if (config.relay !== undefined && config.relay.length > 0) state.relayUrl = config.relay
  if (config.dsh !== undefined && config.dsh.length > 0) state.dshUrl = config.dsh

  const core = new BridleCore(state)
  const startedAt = Date.now()
  let direct: DirectServer | undefined
  let relay: RelayClient | undefined

  // The same snapshot the standalone daemon publishes, for the same reason.
  //
  // `bridle status`, `bridle doctor` and `bridle pair` are typed in a second
  // terminal and read this file to find the Bridle that is already running.
  // Without it they conclude there is no Bridle at all — which, once the plugin
  // is the recommended way to install, means the three commands the help page
  // sends people to when something is broken all lie about the one thing they
  // exist to report. The file is keyed by pid, and this pid is dsh's, so a
  // stale file is still detected the same way.
  function publish(relayState: 'offline' | 'connecting' | 'online' = relay?.connectionState ?? 'offline'): void {
    writeRuntime({
      pid: process.pid,
      version: VERSION,
      startedAt,
      relayUrl: state.relayUrl,
      relayState,
      dshUrl: state.dshUrl,
      dshReachable: core.dshStatus.reachable,
      direct: direct?.addresses ?? [],
      attached: relay?.attachedCircuits ?? 0,
    })
  }

  const heartbeat = setInterval(() => { publish() }, HEARTBEAT_MS)
  heartbeat.unref()

  // Nothing here awaits: Cordis mounts plugins concurrently and a plugin that
  // blocks its apply() holds up the harness it is meant to be a guest in.
  void (async () => {
    await core.start()

    if (config.noDirect !== true) {
      direct = new DirectServer(core, { version: VERSION, port: config.directPort ?? 0, log: () => {} })
      await direct.listen()
      // Same publication the standalone makes, for the same reason: the ready
      // frame is how a phone learns where this machine lives *now*, as opposed
      // to where it lived when they paired.
      core.directAddresses = [...(config.advertise ?? []), ...direct.addresses]
    } else {
      core.directAddresses = config.advertise ?? []
    }

    if (state.relayUrl.length > 0) {
      relay = new RelayClient(core, { version: VERSION, log: () => {}, onState: (next) => { publish(next) } })
      relay.start()
    }
    publish()
  })()

  ctx.on('dispose', () => {
    // Reverse order, and every step tolerant: a plugin that throws on unload
    // takes the reload with it.
    clearInterval(heartbeat)
    try { relay?.stop() } catch { /* already down */ }
    try { direct?.close() } catch { /* already down */ }
    try { core.stop() } catch { /* already down */ }
    // Removed on unload, so a `bridle status` after `dsh plugin remove` says
    // nothing is running rather than pointing at a live dsh that no longer
    // has a Bridle in it.
    try { clearRuntime() } catch { /* already gone */ }
  })
}

/**
 * The addresses a phone can currently reach this machine on.
 *
 * Exported so the plugin's settings page can show them, and so `bridle pair`
 * run in another terminal can find them without a second listener.
 * @param direct - the running listener, if there is one.
 * @returns `ws://host:port` candidates, best first.
 */
export function reachableAddresses(direct: DirectServer | undefined): string[] {
  return direct?.addresses ?? []
}
