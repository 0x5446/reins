/**
 * A guest must fail alone — even at the disk.
 *
 * The plugin's heartbeat writes a status snapshot inside dsh's own process,
 * and an uncaught throw there does not kill a plugin, it kills the harness
 * and every session in it. The standalone CLI died exactly this way in the
 * wild: ENOSPC, five-second heartbeat, daemon gone over a file that exists
 * only so `bridle status` has something to read.
 *
 * The write is made to fail deterministically here by planting a directory
 * where runtime.json goes — the atomic rename cannot replace a directory —
 * which is the same shape as a full disk without needing one.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { apply } from '../lib/index.js'

process.env.ROWEL_HOME = mkdtempSync(join(tmpdir(), 'rowel-heartbeat-'))
// The machine-level index gets the same isolation: apply() registers the
// home it starts, and a test must not put its scratch identity on the
// developer's real map.
process.env.ROWEL_INSTANCES = join(process.env.ROWEL_HOME, 'instances-index.json')

test('a snapshot that cannot be written does not take the host down', async (t) => {
  // A state file with the relay switched off and dsh pointed at a dead port,
  // so the plugin under test starts nothing that outlives the test — the
  // first version of this file left an orphaned relay client dialling
  // production forever, and the test run never exited.
  writeFileSync(join(process.env.ROWEL_HOME, 'bridle.json'), JSON.stringify({
    version: 1,
    deviceId: 'heartbeat-test',
    privateKey: Buffer.alloc(32).toString('base64url'),
    signingKey: Buffer.alloc(64).toString('base64url'),
    machineName: 'heartbeat-test',
    relayUrl: '',
    dshUrl: 'http://127.0.0.1:9',
    peers: [],
  }))
  // The claim, the heartbeat, and every state-change publish all funnel into
  // the same write; blocking the destination makes each of them throw unless
  // the plugin swallows it.
  mkdirSync(join(process.env.ROWEL_HOME, 'runtime.json'))

  const handlers = []
  const errors = []
  assert.doesNotThrow(() => {
    apply({
      on: (event, handler) => { handlers.push(handler) },
      logger: { error: (message) => errors.push(message) },
      // No direct listener: apply()'s startup is deliberately fire-and-forget,
      // so a listener opened after this test's dispose ran would be an orphan
      // that keeps the test runner's event loop alive forever.
    }, { noDirect: true })
  }, 'the startup claim threw; inside dsh this is the harness dying, not the plugin')

  // Teardown must survive the same hostile disk.
  t.after(() => { for (const handler of handlers) handler() })
  assert.equal(handlers.length, 1, 'the plugin did not reach its dispose registration')
})
