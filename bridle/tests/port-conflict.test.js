/**
 * What happens when the direct port is already taken.
 *
 * This crashed a running dsh. A restart that overlapped its predecessor could
 * not bind 61000, `ws` re-emitted the EADDRINUSE as an unhandled `error`
 * event, and Node took the whole harness down — so a phone saw both paths
 * fail at once and the machine simply vanished. The plugin is a guest inside
 * dsh, and a guest that cannot start must fail alone.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { createServer } from 'node:http'
import { BridleCore, DirectServer } from '@reins/bridle'

function core() {
  return new BridleCore(
    {
      version: 1, deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac', relayUrl: '', dshUrl: 'http://127.0.0.1:9', peers: [],
    },
    { dsh: { baseUrl: 'http://127.0.0.1:9', call: async () => ({ ok: true, value: {} }),
             health: async () => ({ reachable: false }), pump: async () => {} } },
  )
}

/** Occupy a port so the next listener has to cope with it being gone. */
function squat() {
  return new Promise((resolve) => {
    const server = createServer()
    server.listen(0, '0.0.0.0', () => resolve({ server, port: server.address().port }))
  })
}

test('a taken port falls back to one the OS picks instead of throwing', async (t) => {
  const { server, port } = await squat()
  t.after(() => { server.close() })

  const machine = core()
  const direct = new DirectServer(machine, { version: 'test', port })
  t.after(() => { direct.close() })

  const bound = await direct.listen()
  assert.notEqual(bound, port, 'it bound the port that was already in use')
  assert.ok(bound > 0, 'no listener at all — a phone on the same Wi-Fi has no direct path')
  assert.ok(direct.addresses.every(a => a.endsWith(`:${String(bound)}`)),
    'the advertised addresses must name the port it actually got')
})

test('a free pinned port is still used, since a stable address is the point', async (t) => {
  const { server, port } = await squat()
  server.close()
  await new Promise(r => server.on('close', r))

  const machine = core()
  const direct = new DirectServer(machine, { version: 'test', port })
  t.after(() => { direct.close() })
  assert.equal(await direct.listen(), port)
})
