/** Pairing payloads: what the QR carries, what a person can type, and what they compare. */

import assert from 'node:assert/strict'
import test from 'node:test'
import {
  confirmationNumber,
  decodePairingLink,
  encodePairingLink,
  generateKeyPair,
  keyFingerprint,
  mintPairingToken,
  mintShortCode,
  normalizeShortCode,
} from '../lib/index.js'

/** @returns {object} a representative bundle. */
function bundle() {
  return {
    v: 1,
    relay: 'wss://relay.reins.app',
    direct: ['ws://192.168.1.24:51820'],
    device: 'zH8pQ1nR2sT3uV4w',
    key: generateKeyPair().publicKey.toString('base64url'),
    token: mintPairingToken(),
    name: "Alex's MacBook Pro",
  }
}

test('a pairing link round trips, including the machine name', () => {
  const original = bundle()
  const decoded = decodePairingLink(encodePairingLink(original))
  assert.deepEqual(decoded, original)
})

test('the payload lives in the fragment so it never reaches a web server', () => {
  const link = encodePairingLink(bundle())
  assert.ok(link.startsWith('reins://pair#'))
  assert.equal(link.indexOf('?'), -1)
})

test('a link that is not ours is refused', () => {
  assert.throws(() => decodePairingLink('https://example.com/#abc'), /not a Reins pairing link/)
  assert.throws(() => decodePairingLink('reins://pair'), /not a Reins pairing link/)
})

test('a link missing a required field is refused', () => {
  const broken = bundle()
  delete broken.token
  assert.throws(() => decodePairingLink(encodePairingLink(broken)), /missing token/)
})

test('short codes avoid vowels and ambiguous characters', () => {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const code = mintShortCode()
    assert.match(code, /^[BCDFGHJKMNPQRSTVWXYZ23456789]{4}-[BCDFGHJKMNPQRSTVWXYZ23456789]{4}$/u)
  }
})

test('a short code typed loosely normalizes to the canonical form', () => {
  assert.equal(normalizeShortCode('ktpq3wrm'), 'KTPQ-3WRM')
  assert.equal(normalizeShortCode(' ktpq 3wrm '), 'KTPQ-3WRM')
  assert.equal(normalizeShortCode('KTPQ-3WRM'), 'KTPQ-3WRM')
})

test('the confirmation number is six digits and depends on the transcript', () => {
  const first = confirmationNumber(Buffer.alloc(32, 1))
  const second = confirmationNumber(Buffer.alloc(32, 2))
  assert.match(first, /^\d{6}$/u)
  assert.notEqual(first, second, 'a substituted key must produce a different number')
  assert.equal(first, confirmationNumber(Buffer.alloc(32, 1)), 'the same transcript always agrees')
})

test('the identity fingerprint is stable and readable', () => {
  const key = generateKeyPair().publicKey
  assert.match(keyFingerprint(key), /^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$/u)
  assert.equal(keyFingerprint(key), keyFingerprint(key))
})
