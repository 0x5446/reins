#!/usr/bin/env node
/**
 * The whole computer-side surface of Reins: one command, sensible defaults, and
 * a first run that ends with a QR code on screen and nothing else to decide.
 *
 * `npx @reins/bridle` finds the harness, starts it if it is not running, opens
 * a tunnel out to the Relay, and prints an invitation. Everything else here is
 * for the days after that.
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import QRCode from 'qrcode'
import { keyFingerprint } from '@reins/protocol'
import { BridleCore } from './core.ts'
import { DirectServer } from './direct-server.ts'
import { DshClient } from './dsh/client.ts'
import { ensureDsh, probeDsh } from './dsh/discovery.ts'
import { loadState, reinsHome, revokePeer, saveState, signingKeys, staticKeys } from './identity.ts'
import { deviceIdFor } from '@reins/protocol'
import { BackupError, describeBackup, exportIdentity, importIdentity } from './backup.ts'
import { createInvitation, publishInvitation, toHttpUrl, type Invitation } from './pair.ts'
import { RelayClient } from './relay-client.ts'
import { clearRuntime, readRuntime, writeRuntime } from './runtime.ts'
import { installService, serviceLogPath, uninstallService } from './service.ts'

const VERSION = readVersion()

/** Parsed command line. */
interface Options {
  command: string
  flags: Map<string, string | true>
}

/**
 * Entry point.
 * @param argv - process arguments after the node binary and script.
 */
async function main(argv: string[]): Promise<void> {
  const options = parse(argv)
  switch (options.command) {
    case 'start':
      await start(options)
      return
    case 'pair':
      await pair(options)
      return
    case 'status':
      await status()
      return
    case 'devices':
      devices()
      return
    case 'revoke':
      revoke(options)
      return
    case 'service':
      service(options)
      return
    case 'backup':
      await backup(options)
      return
    case 'restore':
      await restore(options)
      return
    case 'doctor':
      await doctor()
      return
    case 'version':
      process.stdout.write(`${VERSION}\n`)
      return
    case 'help':
      usage()
      return
    default:
      process.stderr.write(`unknown command: ${options.command}\n\n`)
      usage()
      process.exitCode = 1
  }
}

function parse(argv: string[]): Options {
  const flags = new Map<string, string | true>()
  let command = 'start'
  let seenCommand = false
  const positional: string[] = []
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index] ?? ''
    if (token.startsWith('--')) {
      const [name, inline] = splitFlag(token.slice(2))
      const next = argv[index + 1]
      if (inline !== undefined) flags.set(name, inline)
      else if (next !== undefined && !next.startsWith('--')) {
        flags.set(name, next)
        index += 1
      } else flags.set(name, true)
      continue
    }
    if (!seenCommand) {
      command = token
      seenCommand = true
      continue
    }
    positional.push(token)
  }
  if (positional.length > 0) flags.set('_', positional.join(' '))
  return { command, flags }
}

function splitFlag(token: string): [string, string | undefined] {
  const at = token.indexOf('=')
  return at < 0 ? [token, undefined] : [token.slice(0, at), token.slice(at + 1)]
}

function flagString(options: Options, name: string): string | undefined {
  const value = options.flags.get(name)
  return typeof value === 'string' ? value : undefined
}

function flagBoolean(options: Options, name: string): boolean {
  return options.flags.has(name) && options.flags.get(name) !== 'false'
}

async function start(options: Options): Promise<void> {
  const startedAt = Date.now()
  const state = loadState()
  const relayOverride = flagString(options, 'relay')
  if (relayOverride !== undefined) {
    state.relayUrl = relayOverride
    saveState(state)
  }
  const dshOverride = flagString(options, 'dsh')

  say(`Reins Bridle ${VERSION} · ${state.machineName}`)
  const discovered = await ensureDsh({
    ...(dshOverride === undefined ? {} : { preferred: dshOverride }),
    autoStart: !flagBoolean(options, 'no-auto-start'),
    ...(flagString(options, 'dsh-command') === undefined ? {} : { command: flagString(options, 'dsh-command') as string }),
    log: say,
  })
  state.dshUrl = discovered.url
  const core = new BridleCore(state, { dsh: new DshClient({ baseUrl: discovered.url }) })
  await core.start()
  say(`harness   ${discovered.url}${discovered.launched ? ' (started by bridle)' : ''}`)

  let direct: DirectServer | undefined
  let directAddresses: string[] = []
  if (!flagBoolean(options, 'no-direct')) {
    const port = Number(flagString(options, 'direct-port') ?? '0')
    direct = new DirectServer(core, { version: VERSION, port, log: () => {} })
    await direct.listen()
    directAddresses = direct.addresses
    if (directAddresses.length > 0) say(`local     ${directAddresses[0] ?? ''}`)
  }

  // An address this machine cannot discover for itself: a Cloudflare Tunnel
  // hostname, an ngrok URL, a port-forwarded public address. Interface
  // enumeration finds LAN and tailnet addresses on its own, but a name that
  // resolves to someone else's edge only exists if it is stated.
  //
  // It goes first: someone who set this up did so because it is the path they
  // want used.
  const advertised = (flagString(options, 'advertise') ?? '')
    .split(',')
    .map(entry => entry.trim())
    .filter(entry => entry.length > 0)
  if (advertised.length > 0) {
    directAddresses = [...advertised, ...directAddresses]
    for (const entry of advertised) say(`advertised ${entry}`)
  }
  // Published to every app in the ready frame, so a phone paired on one
  // network learns where this machine lives on the next one.
  core.directAddresses = directAddresses

  const relay = new RelayClient(core, {
    version: VERSION,
    log: say,
    onState: (next) => { publish(next) },
  })
  relay.start()
  say(`relay     ${state.relayUrl}`)

  function publish(relayState: 'offline' | 'connecting' | 'online' = relay.connectionState): void {
    writeRuntime({
      pid: process.pid,
      version: VERSION,
      startedAt,
      relayUrl: state.relayUrl,
      relayState,
      dshUrl: state.dshUrl,
      dshReachable: core.dshStatus.reachable,
      direct: directAddresses,
      attached: relay.attachedCircuits,
    })
  }
  publish()
  const heartbeat = setInterval(() => { publish() }, 5_000)
  heartbeat.unref()

  if (state.peers.length === 0 || flagBoolean(options, 'pair')) {
    say('')
    const invitation = createInvitation(state, directAddresses)
    await tryPublish(state, invitation)
    await printInvitation(invitation, state, flagBoolean(options, 'link'))
  } else {
    say(`paired    ${String(state.peers.length)} device${state.peers.length === 1 ? '' : 's'} · run "bridle pair" to add another`)
  }

  const shutdown = (): void => {
    clearInterval(heartbeat)
    relay.stop()
    direct?.close()
    core.stop()
    clearRuntime()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
  await new Promise<never>(() => {})
}

async function pair(options: Options): Promise<void> {
  const state = loadState()
  const runtime = readRuntime()
  if (runtime === undefined) {
    say('No bridle is running on this machine. Start one with "bridle start" first,')
    say('or keep this invitation and start it before scanning.')
    say('')
  }
  const invitation = createInvitation(state, runtime?.direct ?? [])
  if (!flagBoolean(options, 'no-relay-offer')) await tryPublish(state, invitation)
  await printInvitation(invitation, state, flagBoolean(options, 'link'))
}

async function tryPublish(state: ReturnType<typeof loadState>, invitation: Invitation): Promise<void> {
  try {
    await publishInvitation(state, invitation)
  } catch (error) {
    // The QR path does not need the Relay to hold anything, so a Relay that is
    // down costs the typed code and nothing else.
    say(`(short code unavailable: ${error instanceof Error ? error.message : String(error)})`)
  }
}

async function printInvitation(invitation: Invitation, state: ReturnType<typeof loadState>, forceLink = false): Promise<void> {
  // Block-drawing QR codes only survive a real terminal. Over SSH into a log,
  // in CI, or piped anywhere, the link is the thing that still works.
  const drawable = process.stdout.isTTY === true
  if (drawable) {
    const qr = await QRCode.toString(invitation.link, { type: 'terminal', small: true, errorCorrectionLevel: 'M' })
    say('Scan this in the Reins app:')
    process.stdout.write(`\n${qr}\n`)
    say(`or type this code:   ${invitation.code}`)
  } else {
    say('Pair the Reins app with either of these:')
    say(`code:                ${invitation.code}`)
  }
  if (forceLink || !drawable) say(`link:                ${invitation.link}`)
  say(`machine:             ${state.machineName}`)
  say(`identity:            ${keyFingerprint(staticKeys(state).publicKey)}`)
  say(`expires:             ${new Date(invitation.expiresAt).toLocaleTimeString()}`)
  say('')
  say('No app yet? Get it at https://reins.novabox.ai/get')
}

/**
 * Write an encrypted copy of this machine's identity.
 *
 * Without this, `~/.reins/bridle.json` is a single point of failure with no
 * recovery: lose it and every paired phone stops recognising the machine, with
 * no way to tell them apart from an impostor.
 * @param options - parsed command line; the positional argument is the path.
 */
async function backup(options: Options): Promise<void> {
  const target = flagString(options, '_')
  if (target === undefined) {
    say('Usage: bridle backup <file>')
    process.exitCode = 1
    return
  }
  const state = loadState()
  const passphrase = await readSecret('Passphrase for the backup: ')
  const again = await readSecret('Again: ')
  if (passphrase !== again) {
    say('Those did not match. Nothing was written.')
    process.exitCode = 1
    return
  }
  const deviceId = deviceIdFor(signingKeys(state).publicKey)
  try {
    writeFileSync(target, exportIdentity(state, passphrase, deviceId), { mode: 0o600 })
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }
  say(`Wrote ${target} (0600).`)
  say(`It holds this machine's key and ${String(state.peers.length)} paired device(s).`)
  say('Anyone with this file and its passphrase can become this machine. Store it accordingly.')
}

/**
 * Replace this machine's identity with a saved one.
 *
 * Destructive, so it says exactly what it is about to displace and requires the
 * word "replace" — the person doing this is usually mid-migration and tired.
 * @param options - parsed command line; the positional argument is the path.
 */
async function restore(options: Options): Promise<void> {
  const source = flagString(options, '_')
  if (source === undefined) {
    say('Usage: bridle restore <file>')
    process.exitCode = 1
    return
  }
  let archive: string
  try {
    archive = readFileSync(source, 'utf8')
  } catch {
    say(`Could not read ${source}`)
    process.exitCode = 1
    return
  }

  let summary
  try {
    summary = describeBackup(archive)
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }

  const current = loadState()
  say(`Backup:  ${summary.machineName} · ${String(summary.peerCount)} device(s) · saved ${summary.exportedAt}`)
  say(`Current: ${current.machineName} · ${String(current.peers.length)} device(s)`)
  say('')
  say('Restoring replaces this machine\'s key. Devices paired to the *current*')
  say('identity will stop recognising it, and devices in the backup will start.')
  const confirm = await readLine('Type "replace" to continue: ')
  if (confirm.trim() !== 'replace') {
    say('Nothing changed.')
    return
  }

  const passphrase = await readSecret('Passphrase: ')
  try {
    saveState(importIdentity(archive, passphrase))
  } catch (error) {
    say(error instanceof BackupError ? error.message : String(error))
    process.exitCode = 1
    return
  }
  say('Restored. Restart the bridle for it to take effect.')
}

async function status(): Promise<void> {
  const state = loadState()
  const runtime = readRuntime()
  say(`machine   ${state.machineName}`)
  say(`identity  ${keyFingerprint(staticKeys(state).publicKey)}`)
  say(`device    ${state.deviceId}`)
  say(`state     ${join(reinsHome(), 'bridle.json')}`)
  if (runtime === undefined) {
    say('bridle    not running · start it with "bridle start"')
  } else {
    say(`bridle    running (pid ${String(runtime.pid)}, ${VERSION}) · ${String(runtime.attached)} attached`)
    say(`relay     ${runtime.relayState} · ${runtime.relayUrl}`)
    if (runtime.direct.length > 0) say(`local     ${runtime.direct.join(', ')}`)
  }
  const dshUrl = runtime?.dshUrl ?? state.dshUrl
  const health = await new DshClient({ baseUrl: dshUrl }).health()
  say(`harness   ${health.reachable ? 'up' : 'down'} · ${dshUrl}${health.reachable ? '' : ` (${health.detail ?? 'no answer'})`}`)
  say('')
  printDevices(state)
}

function devices(): void {
  printDevices(loadState())
}

function printDevices(state: ReturnType<typeof loadState>): void {
  if (state.peers.length === 0) {
    say('No paired devices. Run "bridle pair" to add one.')
    return
  }
  say(`Paired devices (${String(state.peers.length)}):`)
  for (const peer of state.peers) {
    const seen = new Date(peer.lastSeen).toLocaleString()
    say(`  ${peer.key.slice(0, 8)}  ${peer.name.padEnd(20)} last seen ${seen}`)
  }
}

function revoke(options: Options): void {
  const target = flagString(options, '_')
  if (target === undefined) {
    say('Usage: bridle revoke <device-id-prefix>   (see "bridle devices")')
    process.exitCode = 1
    return
  }
  const state = loadState()
  const removed = revokePeer(state, target)
  if (removed === undefined) {
    say(`No paired device matches ${target}.`)
    process.exitCode = 1
    return
  }
  say(`Revoked ${removed.name} (${removed.key.slice(0, 8)}).`)
  say('It will be refused at the next handshake; restart bridle to drop a live tunnel.')
}

function service(options: Options): void {
  const action = flagString(options, '_') ?? 'install'
  if (action === 'install') {
    const outcome = installService()
    say(outcome.detail)
    say(`file: ${outcome.path}`)
    say(`log:  ${serviceLogPath()}`)
    return
  }
  if (action === 'uninstall') {
    const outcome = uninstallService()
    say(outcome.detail)
    return
  }
  say('Usage: bridle service install | bridle service uninstall')
  process.exitCode = 1
}

async function doctor(): Promise<void> {
  const state = loadState()
  const major = Number(process.versions.node.split('.')[0] ?? '0')
  check(major >= 22, `node ${process.versions.node}`, 'Reins needs Node 22 or newer')
  const found = await probeDsh(state.dshUrl)
  check(found !== undefined, `harness at ${found ?? state.dshUrl}`, 'no dsh web server answered; "bridle start" can launch one')
  let relayReachable = false
  let relayDetail = ''
  try {
    const response = await fetch(new URL('/healthz', toHttpUrl(state.relayUrl)), { signal: AbortSignal.timeout(5_000) })
    relayReachable = response.ok
    relayDetail = `HTTP ${String(response.status)}`
  } catch (error) {
    relayDetail = error instanceof Error ? error.message : String(error)
  }
  check(relayReachable, `relay ${state.relayUrl}`, `relay unreachable (${relayDetail}); the local network path still works`)
  check(state.peers.length > 0, `${String(state.peers.length)} paired device(s)`, 'nothing paired yet; run "bridle pair"')
}

function check(ok: boolean, good: string, bad: string): void {
  say(`${ok ? '  ok  ' : ' warn '} ${ok ? good : bad}`)
}

function usage(): void {
  process.stdout.write(`Reins Bridle ${VERSION} — reach your local DeepSeek Harness from your phone.

  bridle                    start the bridle (and pair, on first run)
  bridle pair               show a new pairing QR and short code
  bridle status             machine, relay, harness, and paired devices
  bridle devices            list paired devices
  bridle revoke <prefix>    remove a paired device
  bridle service install    keep the bridle running after login
  bridle service uninstall  remove the background service
  bridle backup <file>      save this machine's identity, encrypted
  bridle restore <file>     put a saved identity back (replaces the current one)
  bridle doctor             check this machine's setup

Options for start:
  --relay <url>       Relay to dial out to (default: the public Relay)
  --dsh <url>         harness address, if it is not on a usual port
  --dsh-command <cmd> how to launch the harness (default: dsh)
  --direct-port <n>   fixed port for the local-network tunnel
  --advertise <url>   extra address(es) to put in the pairing code, comma
                      separated. For a tunnel hostname the machine cannot
                      discover itself, e.g. wss://reins.example.com. LAN and
                      Tailscale addresses are found automatically.
  --no-direct         do not listen on the local network
  --no-auto-start     never launch the harness
  --pair              show a pairing invitation even if devices are paired
  --link              also print the raw pairing link (useful over SSH)
`)
}

function say(message: string): void {
  process.stdout.write(`${message}\n`)
}

/**
 * Read one line from the terminal.
 * @param prompt - shown before the cursor.
 * @returns what was typed, without the newline.
 */
let lines: AsyncIterator<string> | undefined

async function readLine(prompt: string): Promise<string> {
  process.stdout.write(prompt)
  // One interface for the whole process, created lazily. A fresh
  // `createInterface` per prompt reads ahead and swallows the lines the *next*
  // prompt was going to get — invisible on a terminal, and it silently ate the
  // second line of every piped `printf 'pass\npass\n' | bridle backup`.
  lines ??= createInterface({ input: process.stdin, terminal: false })[Symbol.asyncIterator]()
  const next = await lines.next()
  return next.done === true ? '' : next.value
}

/**
 * Read a line without echoing it.
 *
 * Falls back to a visible read when stdin is not a terminal — a pipe has no
 * echo to suppress, and refusing there would break scripted restores.
 * @param prompt - shown before the cursor.
 * @returns what was typed.
 */
async function readSecret(prompt: string): Promise<string> {
  if (!process.stdin.isTTY) return readLine(prompt)
  process.stdout.write(prompt)
  process.stdin.setRawMode(true)
  process.stdin.resume()
  let value = ''
  try {
    for await (const chunk of process.stdin) {
      const text = String(chunk)
      // Ctrl-C and Ctrl-D during a passphrase prompt mean "stop", not "submit
      // what I have so far".
      if (text.includes('\u0003') || text.includes('\u0004')) {
        process.stdout.write('\n')
        process.exit(130)
      }
      if (text.includes('\r') || text.includes('\n')) {
        value += text.split(/[\r\n]/u)[0] ?? ''
        break
      }
      // Backspace, so a typo is recoverable without restarting the command.
      if (text === '\u007f' || text === '\b') {
        value = value.slice(0, -1)
        continue
      }
      value += text
    }
  } finally {
    process.stdin.setRawMode(false)
    process.stdin.pause()
    process.stdout.write('\n')
  }
  return value
}

function readVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url))
    const manifest = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8')) as { version?: string }
    return manifest.version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

main(process.argv.slice(2)).catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
  process.exit(1)
})
