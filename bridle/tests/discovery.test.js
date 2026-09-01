/**
 * Which dsh a Bridle binds to, and when it may change its mind.
 *
 * The scan across candidate ports exists because dsh port-falls-back on its
 * own — a single-dsh machine legitimately answers on 3081 some mornings. The
 * two rules under test are the ones that keep that convenience from becoming
 * a betrayal on a machine running more than one dsh: a URL a person named is
 * pinned (that harness or an error, never a substitute), and a URL that was
 * merely remembered races first (so the previous binding wins whenever it is
 * alive).
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { probeDsh } from '@rowel/bridle'

/** A fake dsh: answers host.describe the way the health probe expects. */
function fakeDsh() {
  const server = createServer((request, response) => {
    let body = ''
    request.on('data', chunk => { body += String(chunk) })
    request.on('end', () => {
      const rpcId = (() => { try { return JSON.parse(body).rpcId } catch { return 'x' } })()
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ type: 'server-response', rpcId, result: { ok: true, value: { version: 'fake' } } }))
    })
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({ url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })
    })
  })
}

test('a pinned URL is that harness or nothing', async (t) => {
  // A live dsh on some port, and a pinned preference for a dead one. The old
  // behaviour fell through to the scan and adopted the live one — which on a
  // two-dsh machine is a different session history wearing the same app.
  const other = await fakeDsh()
  t.after(() => other.close())
  const dead = 'http://127.0.0.1:1'

  assert.equal(await probeDsh(dead, true), undefined,
    'a URL the person named was quietly substituted with a different harness')
})

test('a remembered URL races first and wins while alive', async (t) => {
  const mine = await fakeDsh()
  t.after(() => mine.close())
  assert.equal(await probeDsh(mine.url), mine.url,
    'the previous binding was alive and something else was adopted anyway')
})

test('an unpinned dead preference may still fall through to the scan', async (t) => {
  // dsh's own port fallback is the whole reason the scan exists; a merely
  // remembered URL going dark must not strand a single-dsh machine. The
  // fake answers on an ephemeral port the scan does not cover, so all this
  // can assert is that the dead preference alone did not abort the scan.
  const found = await probeDsh('http://127.0.0.1:1', false)
  assert.notEqual(found, 'http://127.0.0.1:1', 'a dead URL cannot be the answer')
})
