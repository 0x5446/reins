/**
 * Which of this machine's addresses go into a pairing code.
 *
 * Getting this wrong is quiet in both directions: an address that cannot work
 * costs the app one failed connect, and a missing one is the difference between
 * the tunnel reaching the machine from outside the building and not.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { dialableAddresses } from '../lib/index.js'

/**
 * @param {string} address - IPv4 address.
 * @param {boolean} internal - whether the interface is loopback.
 * @returns {object} one entry shaped like os.networkInterfaces() returns.
 */
function v4(address, internal = false) {
  return { family: 'IPv4', internal, address }
}

test('loopback and IPv6 are left out', () => {
  const found = dialableAddresses({
    lo0: [v4('127.0.0.1', true), { family: 'IPv6', internal: true, address: '::1' }],
    en0: [v4('192.168.1.10'), { family: 'IPv6', internal: false, address: 'fe80::1' }],
  })
  assert.deepEqual(found, ['192.168.1.10'])
})

test('a self-assigned link-local address is dropped', () => {
  // 169.254/16 means DHCP failed. It is not routable off that link, so putting
  // it in a pairing code only buys the phone a timeout.
  const found = dialableAddresses({ en1: [v4('169.254.238.91')], en0: [v4('192.168.1.10')] })
  assert.deepEqual(found, ['192.168.1.10'])
})

test('the LAN comes before the tailnet, and the tailnet before a docker bridge', () => {
  // Both work when the phone is on the tailnet; the LAN is faster and depends
  // on nothing. 172.16/12 on a developer machine is usually Docker or a VPN leg
  // the phone cannot reach, so it goes last.
  const found = dialableAddresses({
    docker0: [v4('172.19.0.1')],
    tailscale0: [v4('100.101.102.103')],
    en0: [v4('192.168.1.10')],
  })
  assert.deepEqual(found, ['192.168.1.10', '100.101.102.103', '172.19.0.1'])
})

test('a tailnet address survives even when it is the only one', () => {
  // The machine is on no LAN the phone shares — an office ethernet, a VPS.
  // Dropping this would be dropping the only way in.
  const found = dialableAddresses({ tailscale0: [v4('100.64.0.1')] })
  assert.deepEqual(found, ['100.64.0.1'])
})

test('100.x outside the CGNAT range is not mistaken for a tailnet', () => {
  // 100.0.0.0/10 through 100.63 and 100.128+ are ordinary public space.
  const found = dialableAddresses({ en0: [v4('100.200.1.1')], en1: [v4('100.64.0.1')] })
  assert.deepEqual(found, ['100.64.0.1', '100.200.1.1'], 'the real tailnet address ranks higher')
})

test('a public address is kept, because a machine with one is reachable', () => {
  const found = dialableAddresses({ en0: [v4('203.0.113.9')] })
  assert.deepEqual(found, ['203.0.113.9'])
})

test('a machine with no usable interface advertises nothing rather than guessing', () => {
  const found = dialableAddresses({ lo0: [v4('127.0.0.1', true)] })
  assert.deepEqual(found, [])
})
