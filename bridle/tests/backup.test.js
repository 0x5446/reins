/**
 * The machine's identity, taken somewhere else.
 *
 * The failure this guards against is quiet and total: `~/.rowel/bridle.json`
 * goes missing, the Bridle generates a fresh identity, and every paired phone
 * sees a machine whose key does not match the one it pinned — indistinguishable
 * from an impostor. There was no way back before this existed.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { BackupError, describeBackup, exportIdentity, importIdentity, sameIdentity } from '../lib/index.js'

/**
 * @returns {object} state shaped like what loadState() returns.
 */
function state() {
  return {
    machineName: 'Test Mac',
    relayUrl: 'wss://relay.test',
    dshUrl: 'http://127.0.0.1:3080',
    staticSecret: Buffer.alloc(32, 7).toString('base64'),
    signingSecret: Buffer.alloc(32, 9).toString('base64'),
    peers: [{ key: 'aaa', name: 'A phone', addedAt: 1, lastSeenAt: 2 }],
  }
}

test('an identity survives a round trip', () => {
  const archive = exportIdentity(state(), 'correct horse battery', 'dev-1')
  const restored = importIdentity(archive, 'correct horse battery')
  assert.deepEqual(restored, state(), 'every field comes back, not just the keys')
})

test('the header is readable without the passphrase', () => {
  // Someone finding this file in two years must be able to tell what it is and
  // which machine it came from. None of it is secret — the machine name and
  // device id are in every pairing code already.
  const summary = describeBackup(exportIdentity(state(), 'a passphrase', 'dev-1'))
  assert.equal(summary.machineName, 'Test Mac')
  assert.equal(summary.deviceId, 'dev-1')
  assert.equal(summary.peerCount, 1)
  assert.match(summary.exportedAt, /^\d{4}-\d{2}-\d{2}T/u)
})

test('the secret is not readable without the passphrase', () => {
  const archive = exportIdentity(state(), 'a passphrase', 'dev-1')
  assert.ok(!archive.includes(state().staticSecret), 'the static key must not appear in the clear')
  assert.ok(!archive.includes(state().signingSecret), 'nor the signing key')
})

test('a wrong passphrase is refused rather than half-decrypted', () => {
  const archive = exportIdentity(state(), 'the right one', 'dev-1')
  assert.throws(() => importIdentity(archive, 'the wrong one'), BackupError)
})

test('a tampered archive is refused', () => {
  // AEAD, so flipping any byte of the ciphertext has to fail the tag rather
  // than yield plausible-looking state.
  const parsed = JSON.parse(exportIdentity(state(), 'a passphrase', 'dev-1'))
  const sealed = Buffer.from(parsed.sealed, 'base64')
  sealed[0] ^= 0x01
  parsed.sealed = sealed.toString('base64')
  assert.throws(() => importIdentity(JSON.stringify(parsed), 'a passphrase'), BackupError)
})

test('a file that is not a backup says so instead of throwing something obscure', () => {
  assert.throws(() => describeBackup('not json at all'), BackupError)
  assert.throws(() => describeBackup(JSON.stringify({ hello: 'world' })), BackupError)
})

test('a future format is refused by name', () => {
  // Reading a v2 archive with v1 rules would be worse than refusing: it might
  // half-work and write a broken identity to disk.
  const archive = JSON.stringify({ magic: 'rowel-identity/v2', machineName: 'x' })
  assert.throws(() => describeBackup(archive), /rowel-identity\/v1/u)
})

test('a too-short passphrase is refused at export, not discovered at restore', () => {
  assert.throws(() => exportIdentity(state(), 'short', 'dev-1'), BackupError)
})

test('two exports of the same machine are recognisably the same identity', () => {
  const a = describeBackup(exportIdentity(state(), 'a passphrase', 'dev-1'))
  const b = describeBackup(exportIdentity(state(), 'another one', 'dev-1'))
  assert.ok(sameIdentity(a, b))
  const other = describeBackup(exportIdentity(state(), 'a passphrase', 'dev-2'))
  assert.ok(!sameIdentity(a, other))
})

test('each export uses fresh salt and nonce', () => {
  // Reusing either under the same passphrase would leak that two archives hold
  // the same plaintext, and reusing a nonce under the same derived key is fatal.
  const a = JSON.parse(exportIdentity(state(), 'a passphrase', 'dev-1'))
  const b = JSON.parse(exportIdentity(state(), 'a passphrase', 'dev-1'))
  assert.notEqual(a.salt, b.salt)
  assert.notEqual(a.nonce, b.nonce)
})
