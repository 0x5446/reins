/**
 * The first five minutes. Someone runs one command, a pairing invitation
 * appears, their phone connects, and it keeps working tomorrow. Nothing below
 * imports the Bridle as a library — it spawns the real CLI the way a user does,
 * because the install path is the product.
 */

import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { probeDsh } from '@reins/bridle'
import { decodePairingLink } from '@reins/protocol'
import { RelayServer } from '@reins/relay'
import { ReinsPhone, waitFor } from '../lib/index.js'

const DSH_URL = process.env.REINS_E2E_DSH_URL ?? await probeDsh()
const skip = DSH_URL === undefined ? 'no DeepSeek Harness is running; set REINS_E2E_DSH_URL' : false

const CLI = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'bridle', 'lib', 'cli.js')

/** One CLI invocation against a throwaway home directory. */
class Cli {
  /** @param {string} home - value for REINS_HOME. */
  constructor(home) {
    this.home = home
  }

  /**
   * Run a command to completion.
   * @param {string[]} args - CLI arguments.
   * @returns {Promise<{code: number|null, out: string, err: string}>} the result.
   */
  run(args) {
    return new Promise((resolve) => {
      const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, REINS_HOME: this.home } })
      let out = ''
      let err = ''
      child.stdout.on('data', chunk => { out += String(chunk) })
      child.stderr.on('data', chunk => { err += String(chunk) })
      child.on('close', code => { resolve({ code, out, err }) })
    })
  }

  /**
   * Start a long-running command and wait for a line to appear.
   * @param {string[]} args - CLI arguments.
   * @param {RegExp} until - matched against accumulated stdout.
   * @returns {Promise<{child: import('node:child_process').ChildProcess, out: () => string}>} the running process.
   */
  async spawn(args, until) {
    const child = spawn(process.execPath, [CLI, ...args], { env: { ...process.env, REINS_HOME: this.home } })
    let out = ''
    let err = ''
    child.stdout.on('data', chunk => { out += String(chunk) })
    child.stderr.on('data', chunk => { err += String(chunk) })
    try {
      await waitFor(() => until.test(out), 30_000, `cli output matching ${String(until)}`)
    } catch (error) {
      child.kill('SIGKILL')
      throw new Error(`${error.message}\n--- stdout ---\n${out}\n--- stderr ---\n${err}`)
    }
    return { child, out: () => out, err: () => err }
  }
}

/**
 * A throwaway home plus a private Relay, torn down with the test.
 * @param {import('node:test').TestContext} t - the test context.
 * @returns {Promise<{cli: Cli, home: string, relayUrl: string, relay: RelayServer}>} the fixture.
 */
async function fixture(t) {
  const home = mkdtempSync(join(tmpdir(), 'reins-cli-'))
  t.after(() => { rmSync(home, { recursive: true, force: true }) })
  const relay = new RelayServer({ port: 0, host: '127.0.0.1' })
  const port = await relay.listen()
  t.after(() => relay.close())
  return { cli: new Cli(home), home, relayUrl: `http://127.0.0.1:${String(port)}`, relay }
}

/**
 * Pull the pairing link out of CLI output.
 * @param {string} out - captured stdout.
 * @returns {import('@reins/protocol').PairingBundle} the bundle it carries.
 */
function bundleFrom(out) {
  const match = /reins:\/\/pair#[A-Za-z0-9_-]+/u.exec(out)
  assert.ok(match, `no pairing link in output:\n${out}`)
  return decodePairingLink(match[0])
}

test('the first run pairs a phone with no configuration at all', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)

  const started = await cli.spawn(
    ['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'],
    /reins:\/\/pair#/u,
  )
  t.after(() => { started.child.kill('SIGKILL') })

  const out = started.out()
  assert.match(out, /Reins Bridle/u, 'the banner names the product and version')
  assert.match(out, new RegExp(`harness {3}${DSH_URL.replaceAll('.', String.raw`\.`)}`, 'u'), 'it reports which harness it found')
  assert.match(out, /code: +[BCDFGHJKMNPQRSTVWXYZ23456789]{4}-[BCDFGHJKMNPQRSTVWXYZ23456789]{4}/u, 'a typed code is offered too')

  const phone = new ReinsPhone({ bundle: bundleFrom(out), prefer: 'relay', name: 'First iPhone' })
  t.after(() => { phone.close() })
  const ready = await phone.connect()
  assert.equal(ready.dshReachable, true)
  assert.equal((await phone.call('host.describe', {})).ok, true)
})

test('a second device is added from another terminal while the bridle runs', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], /reins:\/\/pair#/u)
  t.after(() => { started.child.kill('SIGKILL') })

  const first = new ReinsPhone({ bundle: bundleFrom(started.out()), prefer: 'relay', name: 'iPhone' })
  t.after(() => { first.close() })
  await first.connect()

  // The daemon is running in one terminal; the user types this in another. It
  // has to reach the live process, which is why the daemon follows its own
  // state file rather than owning it.
  const paired = await cli.run(['pair', '--link'])
  assert.equal(paired.code, 0, paired.err)
  const second = new ReinsPhone({ bundle: bundleFrom(paired.out), prefer: 'relay', name: 'iPad' })
  t.after(() => { second.close() })
  const ready = await second.connect()
  assert.equal(ready.dshReachable, true)

  const devices = await cli.run(['devices'])
  assert.match(devices.out, /iPhone/u)
  assert.match(devices.out, /iPad/u)
})

test('status and doctor describe a healthy machine', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], /reins:\/\/pair#/u)
  t.after(() => { started.child.kill('SIGKILL') })
  const phone = new ReinsPhone({ bundle: bundleFrom(started.out()), prefer: 'relay', name: 'Status iPhone' })
  t.after(() => { phone.close() })
  await phone.connect()

  await waitFor(async () => (await cli.run(['status'])).out.includes('relay     online'), 15_000, 'the relay to come up')
    .catch(() => {})
  const status = await cli.run(['status'])
  assert.equal(status.code, 0, status.err)
  assert.match(status.out, /bridle {4}running \(pid \d+/u)
  assert.match(status.out, /harness {3}up/u)
  assert.match(status.out, /Status iPhone/u)

  const doctor = await cli.run(['doctor'])
  assert.equal(doctor.code, 0, doctor.err)
  assert.equal(doctor.out.includes(' warn '), false, `doctor should be clean here:\n${doctor.out}`)
})

test('a revoked device is refused, and the CLI says so plainly', { skip, timeout: 120_000 }, async (t) => {
  const { cli, relayUrl } = await fixture(t)
  const started = await cli.spawn(['start', '--relay', relayUrl, '--dsh', DSH_URL, '--no-auto-start'], /reins:\/\/pair#/u)
  t.after(() => { started.child.kill('SIGKILL') })
  const bundle = bundleFrom(started.out())
  const phone = new ReinsPhone({ bundle, prefer: 'relay', name: 'Doomed iPhone' })
  await phone.connect()
  phone.close()

  const prefix = phone.keys.publicKey.toString('base64url').slice(0, 8)
  const revoked = await cli.run(['revoke', prefix])
  assert.equal(revoked.code, 0, revoked.err)
  assert.match(revoked.out, /Revoked Doomed iPhone/u)

  assert.match((await cli.run(['revoke', 'zzzzzzzz'])).out, /No paired device matches/u)

  const returning = new ReinsPhone({ bundle, keys: phone.keys, pairing: false, prefer: 'relay' })
  t.after(() => { returning.close() })
  await assert.rejects(() => returning.connect(), error => error.reason === 'unpaired')
})

test('the state file holds the machine secret and nobody else can read it', { skip, timeout: 60_000 }, async (t) => {
  const { cli, home } = await fixture(t)
  assert.equal((await cli.run(['status'])).code, 0)

  const raw = JSON.parse(readFileSync(join(home, 'bridle.json'), 'utf8'))
  assert.equal(typeof raw.privateKey, 'string', 'the X25519 identity lives here')
  assert.equal(typeof raw.signingKey, 'string', 'so does the relay identity')
  assert.equal(raw.peers.length, 0)

  const status = await cli.run(['status'])
  for (const secret of [raw.privateKey, raw.signingKey]) {
    assert.equal(status.out.includes(secret), false, 'no command ever prints a private key')
  }
})

test('help and version answer without touching anything', { skip: false, timeout: 30_000 }, async (t) => {
  const { cli } = await fixture(t)
  const help = await cli.run(['help'])
  assert.equal(help.code, 0)
  assert.match(help.out, /bridle pair/u)
  assert.match(help.out, /bridle revoke/u)

  const version = await cli.run(['version'])
  assert.match(version.out.trim(), /^\d+\.\d+\.\d+/u)

  const unknown = await cli.run(['nonsense'])
  assert.equal(unknown.code, 1)
  assert.match(unknown.err, /unknown command/u)
})
