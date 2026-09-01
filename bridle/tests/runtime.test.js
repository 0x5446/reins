/**
 * One Bridle per identity.
 *
 * Two Bridles reading the same ROWEL_HOME register at the Relay as the same
 * machine and displace each other in a silent loop at retry speed — observed
 * as four and a half thousand Relay requests in two hours, from a standalone
 * daemon and a dsh plugin that had quietly inherited the same `~/.rowel`.
 * `competingDaemon` is the check both doorways run before starting, and this
 * file is what keeps it honest.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { spawn } from 'node:child_process'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { clearRuntime, competingDaemon, writeRuntime } from '@rowel/bridle'

/** A plausible snapshot; only the pid matters to the check. */
function snapshot(pid) {
  return {
    pid,
    version: 'test',
    startedAt: 0,
    relayUrl: '',
    relayState: 'offline',
    dshUrl: '',
    dshReachable: false,
    direct: [],
    attached: 0,
  }
}

/**
 * Run a body against a throwaway ROWEL_HOME.
 * @param {(home: string) => Promise<void> | void} body - the test body.
 */
async function withHome(body) {
  const home = mkdtempSync(join(tmpdir(), 'rowel-runtime-'))
  const previous = process.env.ROWEL_HOME
  process.env.ROWEL_HOME = home
  try {
    await body(home)
  } finally {
    if (previous === undefined) delete process.env.ROWEL_HOME
    else process.env.ROWEL_HOME = previous
  }
}

test('an unclaimed home has no competitor', async () => {
  await withHome(() => {
    assert.equal(competingDaemon(), undefined)
  })
})

test('this process is not its own competitor', async () => {
  // The dsh plugin is reloaded inside a process that already holds the file;
  // treating our own pid as an incumbent would make every reload refuse itself.
  await withHome(() => {
    writeRuntime(snapshot(process.pid))
    assert.equal(competingDaemon(), undefined)
  })
})

test('a live daemon in another process is a competitor, until it dies', async () => {
  await withHome(async () => {
    const other = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'])
    try {
      writeRuntime(snapshot(other.pid))
      assert.equal(competingDaemon()?.pid, other.pid, 'a live incumbent went unnoticed; two Bridles would now fight for one identity')
    } finally {
      other.kill('SIGKILL')
    }
    await new Promise((resolve) => other.on('exit', resolve))
    // The same file, the pid now dead: a crash leaves runtime.json behind, and
    // refusing to start over a corpse would strand the machine offline.
    assert.equal(competingDaemon(), undefined, 'a leftover file from a crashed daemon blocked the restart')
  })
})

test('a cleanly stopped daemon leaves nothing to compete with', async () => {
  await withHome(() => {
    writeRuntime(snapshot(process.pid))
    clearRuntime()
    assert.equal(competingDaemon(), undefined)
  })
})
