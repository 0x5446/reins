/**
 * The machine-level index of Bridle homes.
 *
 * Every other command speaks about one `ROWEL_HOME`, and nothing could answer
 * the question that comes right before all of them: which identities live on
 * this machine at all? That is exactly what a person with a real Bridle and a
 * demo one asks the moment either misbehaves — and until now the only answer
 * was remembering which directories you had ever pointed `ROWEL_HOME` at.
 *
 * The index remembers **paths and nothing else**. Everything shown about an
 * instance — name, device id, whether it is running, how many phones — is
 * derived at read time from that home's own files, and a path whose home no
 * longer holds an identity is dropped on read. A registry that cached any of
 * those facts would drift the moment a daemon started or a phone paired; a
 * list of paths cannot drift, only shrink.
 *
 * It lives at a fixed location regardless of `ROWEL_HOME`, because its whole
 * point is the view across homes.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { deviceIdFor } from '@rowel/protocol'
import { rowelHome, signingKeys, type BridleState } from './identity.ts'
import type { RuntimeInfo } from './runtime.ts'

/** What `bridle instances` shows about one home; all of it read fresh. */
export interface InstanceSummary {
  /** The `ROWEL_HOME` this identity lives in. */
  home: string
  machineName: string
  /** Relay device id, from the state file's signing key. */
  deviceId: string
  /** Paired phones. */
  peers: number
  /** The dsh this identity points at. */
  dshUrl: string
  /** The live daemon's snapshot, when one is running. */
  running?: RuntimeInfo
}

/**
 * Where the index lives.
 *
 * Overridable so a test does not write into the developer's real machine
 * view — the same seam `ROWEL_HOME` provides for everything else.
 */
function indexPath(): string {
  return process.env['ROWEL_INSTANCES'] ?? join(homedir(), '.rowel', 'instances.json')
}

/**
 * Put a home on the machine's map.
 *
 * Called when a daemon starts, from either doorway — that is the moment a
 * directory stops being "some folder with a JSON file" and becomes an
 * identity someone runs. Tolerant of every failure: an index that cannot be
 * written costs the machine view one entry, and that is not worth any
 * daemon's startup (the same lesson runtime.json taught with a full disk).
 * @param home - the `ROWEL_HOME` to remember; defaults to the current one.
 */
export function rememberInstance(home: string = rowelHome()): void {
  try {
    const path = indexPath()
    const canonical = resolve(home)
    const homes = readIndex()
    if (homes.includes(canonical)) return
    homes.push(canonical)
    mkdirSync(join(path, '..'), { recursive: true, mode: 0o700 })
    const temporary = `${path}.${String(process.pid)}.tmp`
    writeFileSync(temporary, `${JSON.stringify(homes, null, 2)}\n`, { mode: 0o600 })
    renameSync(temporary, path)
  } catch {
    // The next daemon start retries.
  }
}

/**
 * Every identity on this machine, read fresh.
 *
 * The default home is always considered, indexed or not — it predates the
 * index and is where most single-instance installs live. Entries whose home
 * no longer holds a state file are dropped from the answer; the file itself
 * is left alone, because a briefly-unmounted volume should not cost a real
 * identity its place on the map.
 * @returns one summary per home that currently holds an identity.
 */
export function listInstances(): InstanceSummary[] {
  const homes = new Set<string>(readIndex())
  homes.add(resolve(join(homedir(), '.rowel')))
  homes.add(resolve(rowelHome()))
  const summaries: InstanceSummary[] = []
  for (const home of [...homes].sort()) {
    const summary = summarize(home)
    if (summary !== undefined) summaries.push(summary)
  }
  return summaries
}

function readIndex(): string[] {
  try {
    const parsed: unknown = JSON.parse(readFileSync(indexPath(), 'utf8'))
    if (!Array.isArray(parsed)) return []
    return parsed.filter((entry): entry is string => typeof entry === 'string')
  } catch {
    return []
  }
}

function summarize(home: string): InstanceSummary | undefined {
  let state: { machineName?: unknown; signingKey?: unknown; dshUrl?: unknown; peers?: unknown }
  try {
    state = JSON.parse(readFileSync(join(home, 'bridle.json'), 'utf8')) as typeof state
  } catch {
    return undefined
  }
  const summary: InstanceSummary = {
    home,
    machineName: typeof state.machineName === 'string' ? state.machineName : 'a computer',
    deviceId: deviceIdOf(state.signingKey),
    peers: Array.isArray(state.peers) ? state.peers.length : 0,
    dshUrl: typeof state.dshUrl === 'string' ? state.dshUrl : '',
  }
  const running = runtimeOf(home)
  if (running !== undefined) summary.running = running
  return summary
}

/**
 * The id this identity registers at the Relay with — derived through the same
 * `signingKeys` the registration itself uses, so the list and the Relay
 * cannot disagree about who is who.
 */
function deviceIdOf(signingKey: unknown): string {
  if (typeof signingKey !== 'string') return '?'
  try {
    return deviceIdFor(signingKeys({ signingKey } as BridleState).publicKey)
  } catch {
    return '?'
  }
}

function runtimeOf(home: string): RuntimeInfo | undefined {
  let info: RuntimeInfo
  try {
    info = JSON.parse(readFileSync(join(home, 'runtime.json'), 'utf8')) as RuntimeInfo
  } catch {
    return undefined
  }
  try {
    process.kill(info.pid, 0)
  } catch {
    return undefined
  }
  return info
}

/** Whether a home currently holds an identity at all. */
export function holdsIdentity(home: string): boolean {
  return existsSync(join(home, 'bridle.json'))
}
