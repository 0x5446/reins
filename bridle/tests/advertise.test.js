/**
 * What a machine tells a phone about where to find it.
 *
 * The `ready` frame's `direct` list is the only thing that corrects a pairing
 * bundle written on another network, so it has to be the truth at the moment
 * it is sent. The first version stored the addresses the listener reported at
 * startup, which meant a laptop that moved from a hotspot to an office went on
 * advertising the hotspot to every phone that connected — found in the wild,
 * in a phone's own connection log, dialling an address from the night before.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BridleCore, TunnelSession } from '@rowel/bridle'

/** A core that answers nothing, since only the ready frame matters here. */
function core() {
  return new BridleCore(
    {
      version: 1,
      deviceId: 'd',
      privateKey: Buffer.alloc(32).toString('base64url'),
      signingKey: Buffer.alloc(64).toString('base64url'),
      machineName: 'a-mac',
      relayUrl: '',
      dshUrl: 'http://127.0.0.1:9',
      peers: [],
    },
    { dsh: { baseUrl: 'http://127.0.0.1:9', call: async () => ({ ok: true, value: {} }), health: async () => ({ reachable: false }), pump: async () => {} } },
  )
}

test('the advertised addresses are asked for, not remembered', () => {
  const machine = core()
  let live = ['ws://172.20.10.2:61000']
  machine.directAddresses = () => live

  assert.deepEqual(machine.directAddresses(), ['ws://172.20.10.2:61000'])

  // The laptop joins a different network. Nothing re-registers anything; the
  // next question simply gets the current answer.
  live = ['ws://10.1.151.64:61000']
  assert.deepEqual(
    machine.directAddresses(),
    ['ws://10.1.151.64:61000'],
    'the ready frame would still name the network this machine booted on',
  )
})

test('a machine with no listener advertises nothing rather than something stale', () => {
  const machine = core()
  assert.deepEqual(machine.directAddresses(), [])
})

test('the ready frame carries whatever the provider says at that moment', () => {
  const machine = core()
  let live = ['ws://10.0.0.1:61000']
  machine.directAddresses = () => live

  const sent = []
  const session = new TunnelSession(machine, { send: (b) => sent.push(b), close: () => {} }, { version: 'test' })
  // Reach past the handshake: the ready frame is built from core state, and
  // building it is the behaviour under test, not the Noise exchange.
  session.channel = { encrypt: (b) => b, decrypt: (b) => b, remoteStatic: Buffer.alloc(32) }
  session.afterHandshake()

  const ready = JSON.parse(sent[0].toString('utf8'))
  assert.equal(ready.t, 'ready')
  assert.deepEqual(ready.direct, ['ws://10.0.0.1:61000'])

  live = ['ws://192.168.1.5:61000']
  sent.length = 0
  session.afterHandshake()
  assert.deepEqual(JSON.parse(sent[0].toString('utf8')).direct, ['ws://192.168.1.5:61000'])
  session.dispose('done')
})
