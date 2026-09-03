/**
 * Finding, and if necessary starting, the dsh a Bridle should serve.
 *
 * The friction this removes is real: a person installing Rowel should not have
 * to know which port their harness picked, or start it by hand before opening
 * the app. Bridle probes the ports dsh actually uses, and can launch one itself
 * when nothing answers.
 */

import { spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createConnection } from 'node:net'
import { DshClient } from './client.ts'

/** Ports probed in order: the web profile default, then the range it falls back through. */
const CANDIDATE_PORTS = [3080, 3081, 3082, 3083, 8080, 8791]

/** How long a single TCP probe may take. */
const PROBE_TIMEOUT_MS = 300

/** How long to wait for a freshly spawned dsh to answer `host.describe`. */
const LAUNCH_TIMEOUT_MS = 45_000

/** A dsh instance Bridle can talk to. */
export interface DiscoveredDsh {
  /** Loopback base URL. */
  url: string
  /** Whether Bridle started this process itself. */
  launched: boolean
}

/**
 * Whether anything is listening on a loopback TCP port.
 * @param port - the port to probe.
 * @returns true when the connection is accepted.
 */
export function portOpen(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port })
    const finish = (open: boolean): void => {
      socket.destroy()
      resolve(open)
    }
    socket.setTimeout(PROBE_TIMEOUT_MS)
    socket.once('connect', () => { finish(true) })
    socket.once('timeout', () => { finish(false) })
    socket.once('error', () => { finish(false) })
  })
}

/**
 * Probe the usual dsh ports for one that answers the harness API.
 *
 * The candidate scan exists for dsh's own sake, not for multi-instance
 * convenience: dsh falls back through these ports itself when its default is
 * taken, so a single-dsh machine legitimately answers on 3081 some mornings.
 * What the scan must never do is *silently* move a binding — that decision
 * belongs to the caller, which knows whether the URL was stated by a person
 * (`pinned`) or is just where dsh answered last time.
 * @param preferred - a URL to try before the candidates, e.g. from config.
 * @param pinned - when true, the preferred URL is the *only* one tried. This
 *   is the `--dsh` contract: a person who named a harness gets that harness
 *   or an error, never a quiet substitute fronting a different session
 *   history — on the machines that run more than one dsh, the substitute is
 *   by definition the wrong one.
 * @returns the first dsh that answers, or undefined.
 */
export async function probeDsh(preferred?: string, pinned = false): Promise<string | undefined> {
  const urls = [...(preferred === undefined ? [] : [preferred])]
  if (!pinned || preferred === undefined) {
    for (const port of CANDIDATE_PORTS) urls.push(`http://127.0.0.1:${String(port)}`)
  }
  const seen = new Set<string>()
  for (const url of urls) {
    if (seen.has(url)) continue
    seen.add(url)
    let port: number
    try {
      const parsed = new URL(url)
      port = Number(parsed.port === '' ? (parsed.protocol === 'https:' ? 443 : 80) : parsed.port)
    } catch {
      continue
    }
    if (!await portOpen(port)) continue
    // Something is listening, but it might be any other local service; only a
    // successful harness method proves it is dsh.
    let client: DshClient
    try {
      client = new DshClient({ baseUrl: url })
    } catch {
      continue
    }
    const health = await client.health()
    if (health.reachable) return url
  }
  return undefined
}

/**
 * The address a DSH_HOME declares for itself, if it declares one.
 *
 * A dsh home can carry its own host and port (`profiles/web/cordis.patch.yml`,
 * entry `webserver`), and a home that does is the strongest binding there is:
 * the port doubles as a single-instance lock — a second boot from the same
 * home dies on EADDRINUSE instead of wandering off to another port — so the
 * URL derived here names the identity, not an incarnation.
 *
 * The parse is deliberately narrow: literal `host:` and `port:` inside the
 * `webserver` block, nothing else. A home without the patch, or one using a
 * `!!js` expression, yields undefined — the caller says so plainly rather
 * than this function guessing. Narrow beats a YAML dependency for reading a
 * file whose one relevant shape is two literal lines.
 * @param home - the DSH_HOME directory.
 * @returns the declared base URL, or undefined when the home does not say.
 */
export function dshHomeUrl(home: string): string | undefined {
  let text: string
  try {
    text = readFileSync(join(home, 'profiles', 'web', 'cordis.patch.yml'), 'utf8')
  } catch {
    return undefined
  }
  // Entries start at column zero with "- "; the webserver block is whatever
  // lies between its header and the next entry.
  const block = text.split(/^- /mu).find(chunk => chunk.startsWith('id: webserver'))
  if (block === undefined) return undefined
  const host = /^\s+host:\s*([\w.-]+)\s*$/mu.exec(block)?.[1]
  const port = /^\s+port:\s*(\d+)\s*$/mu.exec(block)?.[1]
  if (host === undefined || port === undefined) return undefined
  return `http://${host}:${String(Number(port))}`
}

/** How Bridle should behave when no dsh is running. */
export interface EnsureOptions {
  /** Configured dsh URL, tried first. */
  preferred?: string
  /** Only the preferred URL counts; see {@link probeDsh}. */
  pinned?: boolean
  /** Start dsh when nothing answers. */
  autoStart: boolean
  /** Command to start dsh; defaults to the published CLI via npx. */
  command?: string
  /** Arguments for that command. */
  args?: string[]
  /** Port a launched dsh should bind on loopback. */
  port?: number
  /** Progress reporting for the CLI. */
  log?: (message: string) => void
}

/**
 * Return a reachable dsh, launching one if allowed.
 * @param options - discovery and auto-start behaviour.
 * @returns the discovered or launched instance.
 * @throws {@link Error} when nothing answers and auto-start is off or fails.
 */
export async function ensureDsh(options: EnsureOptions): Promise<DiscoveredDsh> {
  const log = options.log ?? ((): void => {})
  const found = await probeDsh(options.preferred, options.pinned ?? false)
  if (found !== undefined) return { url: found, launched: false }
  if (!options.autoStart) {
    // Naming the flag they already passed, not an `--auto-start` that does not
    // exist: launching is the default, `--no-auto-start` is the only switch,
    // and advice to add a flag that nothing reads sends someone looking for a
    // bug in their command line instead of starting a harness.
    throw new Error(
      'no dsh web server is running; start one, or drop --no-auto-start and let bridle launch it')
  }
  // A pinned URL is also where a launched dsh must live: starting the
  // default port when the person said 3081 would bind them to a harness they
  // explicitly did not name.
  const pinnedPort = options.pinned === true && options.preferred !== undefined
    ? Number((() => { try { return new URL(options.preferred).port } catch { return '' } })() || '3080')
    : undefined
  const port = options.port ?? pinnedPort ?? 3080
  const command = options.command ?? 'dsh'
  const args = options.args ?? ['web', '--host', '127.0.0.1', '--port', String(port), '--no-open']
  log(`starting dsh on 127.0.0.1:${String(port)}`)
  const child = spawn(command, args, { stdio: 'ignore', detached: true })
  child.unref()
  const url = `http://127.0.0.1:${String(port)}`
  const client = new DshClient({ baseUrl: url })
  const deadline = Date.now() + LAUNCH_TIMEOUT_MS
  let spawnFailed: string | undefined
  child.once('error', (error: Error) => { spawnFailed = error.message })
  while (Date.now() < deadline) {
    if (spawnFailed !== undefined) {
      throw new Error(`could not start dsh with ${JSON.stringify(command)}: ${spawnFailed}`)
    }
    const health = await client.health()
    if (health.reachable) {
      log(`dsh is up at ${url}`)
      return { url, launched: true }
    }
    await new Promise<void>((resolve) => { setTimeout(resolve, 500) })
  }
  throw new Error(`dsh did not answer at ${url} within ${String(LAUNCH_TIMEOUT_MS / 1000)}s`)
}
