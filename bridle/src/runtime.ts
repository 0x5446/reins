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
import { reinsHome } from './identity.ts'

/** Snapshot written by a running daemon. */
export interface RuntimeInfo {
  /** Process id, used to tell a live daemon from a leftover file. */
  pid: number
  /** Bridle package version. */
  version: string
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
  return join(reinsHome(), 'runtime.json')
}

/**
 * Publish the current snapshot.
 * @param info - the snapshot to write.
 */
export function writeRuntime(info: RuntimeInfo): void {
  mkdirSync(reinsHome(), { recursive: true, mode: 0o700 })
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
