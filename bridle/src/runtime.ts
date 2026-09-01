/**
 * What a running Bridle publishes about itself so a second terminal can ask
 * sensible questions.
 *
 * `bridle pair` and `bridle status` are usually typed while the daemon is
 * already running. Rather than build an IPC channel for two read-only
 * questions, the daemon drops a small file and the other commands read it. A
 * stale file is detected by its pid, not trusted blindly.
 */

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { rowelHome } from './identity.ts'

/** Snapshot written by a running daemon. */
export interface RuntimeInfo {
  /** Process id, used to tell a live daemon from a leftover file. */
  pid: number
  /** Bridle package version. */
  version: string
  /** Which doorway runs it — the rescue guidance differs between the two. */
  via?: 'cli' | 'plugin'
  /** Epoch milliseconds the daemon started. */
  startedAt: number
  /** Relay base URL in use. */
  relayUrl: string
  /** Relay connection state. */
  relayState: 'offline' | 'connecting' | 'online'
  /** dsh base URL in use. */
  dshUrl: string
  /** Whether dsh answered the last probe. */
  dshReachable: boolean
  /** LAN tunnel addresses, best candidate first; empty when direct mode is off. */
  direct: string[]
  /** Phones currently attached. */
  attached: number
}

function runtimePath(): string {
  return join(rowelHome(), 'runtime.json')
}

/**
 * Publish the current snapshot.
 * @param info - the snapshot to write.
 */
export function writeRuntime(info: RuntimeInfo): void {
  mkdirSync(rowelHome(), { recursive: true, mode: 0o700 })
  const path = runtimePath()
  const temporary = `${path}.${String(process.pid)}.tmp`
  writeFileSync(temporary, `${JSON.stringify(info, null, 2)}\n`, { mode: 0o600 })
  renameSync(temporary, path)
}

/** Remove the snapshot on a clean shutdown. */
export function clearRuntime(): void {
  try {
    rmSync(runtimePath())
  } catch {
    // Already gone, which is the desired end state either way.
  }
}

/**
 * The other Bridle already serving this identity, if one is running.
 *
 * Two Bridles reading the same ROWEL_HOME sign in at the Relay as the same
 * machine, and the Relay always believes the newest registration — so they
 * displace each other in a loop, at retry speed, forever. Nothing on either
 * side errors: each one is "online" right up until it is knocked off again.
 * Observed in the wild as four and a half thousand Relay requests in two
 * hours, from one standalone Bridle and one dsh plugin that had quietly
 * inherited the same `~/.rowel`.
 *
 * Asked at startup by both doorways — the CLI daemon and the dsh plugin —
 * because the collision is between doorways: nobody runs the same one twice,
 * but installing the plugin while the service is running is an ordinary
 * Tuesday.
 *
 * The same pid is not a competitor: the dsh plugin is reloaded inside a
 * process that already holds the file.
 * @returns the incumbent's snapshot, or undefined when this process may start.
 */
export function competingDaemon(): RuntimeInfo | undefined {
  const running = readRuntime()
  return running === undefined || running.pid === process.pid ? undefined : running
}

/**
 * Read the snapshot of a daemon that is actually alive.
 * @returns the snapshot, or undefined when no daemon is running.
 */
export function readRuntime(): RuntimeInfo | undefined {
  let info: RuntimeInfo
  try {
    info = JSON.parse(readFileSync(runtimePath(), 'utf8')) as RuntimeInfo
  } catch {
    return undefined
  }
  try {
    // Signal 0 tests for existence without delivering anything.
    process.kill(info.pid, 0)
  } catch {
    return undefined
  }
  return info
}
