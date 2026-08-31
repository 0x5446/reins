/**
 * The machine-level map of Bridle homes.
 *
 * Every other command answers questions about one REINS_HOME; `bridle
 * instances` answers the one that comes first — which identities live on
 * this machine at all. The index under test remembers only paths, so these
 * tests are really about the two properties that make that design safe:
 * everything shown is derived fresh from each home's own files, and a path
 * whose identity is gone drops out of the answer by itself.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { listInstances, loadState, rememberInstance, writeRuntime } from '@reins/bridle'

/** A scratch index plus a scratch home, torn down per test. */
function scratch(t) {
  const root = mkdtempSync(join(tmpdir(), 'reins-instances-'))
  t.after(() => { rmSync(root, { recursive: true, force: true }) })
  const previousIndex = process.env.REINS_INSTANCES
  const previousHome = process.env.REINS_HOME
  process.env.REINS_INSTANCES = join(root, 'index.json')
  t.after(() => {
    if (previousIndex === undefined) delete process.env.REINS_INSTANCES
    else process.env.REINS_INSTANCES = previousIndex
    if (previousHome === undefined) delete process.env.REINS_HOME
    else process.env.REINS_HOME = previousHome
  })
  return root
}

/** Create a real identity in a fresh home and put it on the map. */
function identityAt(root, name) {
  const home = join(root, name)
  process.env.REINS_HOME = home
  loadState()
  rememberInstance()
  return home
}

test('a remembered home shows up with facts read from its own files', (t) => {
  const root = scratch(t)
  const home = identityAt(root, 'one')

  const homes = listInstances().map(i => i.home)
  assert.ok(homes.includes(home), 'the home this test just registered is not on the map')
  const mine = listInstances().find(i => i.home === home)
  assert.equal(mine.peers, 0)
  assert.notEqual(mine.deviceId, '?', 'the relay device id could not be derived from the state file')
})

test('a home whose identity is gone drops out of the answer', (t) => {
  const root = scratch(t)
  const home = identityAt(root, 'gone')
  rmSync(join(home, 'bridle.json'))
  assert.equal(listInstances().some(i => i.home === home), false,
    'a directory with no identity is still being presented as one')
})

test('running is a live pid in that home, nothing else', async (t) => {
  const root = scratch(t)
  const home = identityAt(root, 'runner')
  const other = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'])
  t.after(() => { other.kill('SIGKILL') })
  writeRuntime({
    pid: other.pid,
    version: 'test',
    via: 'plugin',
    startedAt: 0,
    relayUrl: '',
    relayState: 'online',
    dshUrl: 'http://127.0.0.1:3081',
    dshReachable: true,
    direct: [],
    attached: 0,
  })

  const alive = listInstances().find(i => i.home === home)
  assert.equal(alive.running?.via, 'plugin', 'the doorway did not travel with the snapshot')

  other.kill('SIGKILL')
  await new Promise((resolve) => other.on('exit', resolve))
  const dead = listInstances().find(i => i.home === home)
  assert.equal(dead.running, undefined, 'a dead pid is still being reported as a running bridle')
})

test('an index that cannot be written costs an entry, not the caller', (t) => {
  const root = scratch(t)
  // A directory where the index file should be: every write attempt fails.
  mkdirSync(process.env.REINS_INSTANCES, { recursive: true })
  process.env.REINS_HOME = join(root, 'tolerant')
  loadState()
  assert.doesNotThrow(() => { rememberInstance() },
    'a broken index took down the daemon start that tried to register')
})
