/**
 * The plugin declining to start a second Bridle for an identity already served.
 *
 * The usual collision is a standalone `bridle` service still running when the
 * plugin is installed: both read the same ROWEL_HOME, register at the Relay as
 * the same machine, and displace each other in a silent loop at retry speed.
 * The refusal has to happen before the plugin creates anything — a refused
 * instance that still heartbeats would overwrite the incumbent's runtime
 * snapshot every five seconds, and its dispose would delete it.
 *
 * A separate file from plugin.test.js on purpose: that file's tests leave
 * heartbeats publishing into a shared ROWEL_HOME, which would race the
 * incumbent snapshot this file plants.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readRuntime, writeRuntime } from '@rowel/bridle'
import { apply } from '../lib/index.js'

process.env.ROWEL_HOME = mkdtempSync(join(tmpdir(), 'rowel-solo-'))
// The machine-level index gets the same isolation: apply() registers the
// home it starts, and a test must not put its scratch identity on the
// developer's real map.
process.env.ROWEL_INSTANCES = join(process.env.ROWEL_HOME, 'instances-index.json')

test('the plugin refuses an identity another process is already serving', async (t) => {
  const other = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'])
  t.after(() => { other.kill('SIGKILL') })
  writeRuntime({
    pid: other.pid,
    version: 'incumbent',
    startedAt: 0,
    relayUrl: '',
    relayState: 'online',
    dshUrl: '',
    dshReachable: true,
    direct: [],
    attached: 0,
  })

  const errors = []
  let disposers = 0
  apply({
    on: () => { disposers += 1 },
    logger: { error: (message) => errors.push(message) },
  })

  assert.equal(disposers, 0, 'the refused plugin registered a teardown; its dispose would delete the incumbent\'s snapshot')
  assert.equal(errors.length, 1, 'the refusal was silent; nobody would learn why the plugin is not running')
  assert.match(errors[0], new RegExp(String(other.pid), 'u'), 'the error does not say who holds the identity')
  assert.match(errors[0], /ROWEL_HOME/u, 'the error does not say how to run two on purpose')
  assert.equal(readRuntime()?.pid, other.pid, 'the refused plugin overwrote the incumbent\'s snapshot')
})
