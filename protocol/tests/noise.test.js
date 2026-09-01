/**
 * The handshake is the only thing standing between a stranger on the Relay and
 * someone's shell. These tests are about the ways it must refuse.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import {
  NoiseError,
  NoiseInitiator,
  NoiseResponder,
  TUNNEL_PROLOGUE,
  constantTimeEqual,
  generateKeyPair,
  publicKeyOf,
  negotiateVersion,
} from '../lib/index.js'

/**
 * Run a complete IK handshake.
 * @param {object} [options] - overrides for the failure cases.
 * @returns {{initiator: object, responder: object, channels: object}} both ends.
 */
function handshake(options = {}) {
  const app = options.app ?? generateKeyPair()
  const bridle = options.bridle ?? generateKeyPair()
  const believedKey = options.believedKey ?? bridle.publicKey
  const initiator = new NoiseInitiator(app, believedKey, TUNNEL_PROLOGUE)
  const responder = new NoiseResponder(bridle, options.responderPrologue ?? TUNNEL_PROLOGUE)
  const first = initiator.writeMessage(Buffer.from(options.request ?? '{"v":1}', 'utf8'))
  const read = responder.readMessage(first)
  const { message, channel: server } = responder.writeMessage(Buffer.from(options.reply ?? '{"ok":true}', 'utf8'))
  const { channel: client, payload } = initiator.readMessage(message)
  return { app, bridle, read, client, server, replyPayload: payload }
}

test('a full handshake authenticates both ends and agrees on a channel', () => {
  const { app, bridle, read, client, server, replyPayload } = handshake()
  assert.ok(constantTimeEqual(read.remoteStatic, app.publicKey), 'bridle learns the app identity')
  assert.ok(constantTimeEqual(client.remoteStatic, bridle.publicKey), 'app confirms the bridle identity')
  assert.equal(read.payload.toString('utf8'), '{"v":1}')
  assert.equal(replyPayload.toString('utf8'), '{"ok":true}')
  assert.ok(constantTimeEqual(client.handshakeHash, server.handshakeHash), 'both ends bind to the same transcript')
})

test('transport frames survive a round trip in both directions', () => {
  const { client, server } = handshake()
  const up = Buffer.from(JSON.stringify({ t: 'req', id: '1', method: 'session.list', payload: {} }))
  assert.deepEqual(server.decrypt(client.encrypt(up)), up)
  const down = Buffer.from(JSON.stringify({ t: 'res', id: '1', result: { ok: true, value: [] } }))
  assert.deepEqual(client.decrypt(server.encrypt(down)), down)
})

test('a frame larger than the Noise message cap still works', () => {
  // dsh carries image attachments as base64 inside JSON, so multi-megabyte
  // frames are ordinary rather than exceptional.
  const { client, server } = handshake()
  const big = Buffer.alloc(3 * 1024 * 1024, 0x41)
  assert.deepEqual(server.decrypt(client.encrypt(big)), big)
})

test('a tampered frame is refused rather than decrypted', () => {
  const { client, server } = handshake()
  const sealed = client.encrypt(Buffer.from('hello'))
  sealed[2] ^= 0x01
  assert.throws(() => server.decrypt(sealed), NoiseError)
})

test('a replayed frame is refused because counters only move forward', () => {
  const { client, server } = handshake()
  const first = client.encrypt(Buffer.from('one'))
  assert.deepEqual(server.decrypt(first), Buffer.from('one'))
  assert.throws(() => server.decrypt(first), NoiseError)
})

test('a frame delivered out of order is refused without desyncing the channel', () => {
  // A failed decryption must not advance the counter. If it did, anyone able to
  // inject one garbage frame could permanently break a live conversation.
  const { client, server } = handshake()
  const first = client.encrypt(Buffer.from('one'))
  const second = client.encrypt(Buffer.from('two'))
  assert.throws(() => server.decrypt(second), NoiseError)
  assert.deepEqual(server.decrypt(first), Buffer.from('one'))
  assert.deepEqual(server.decrypt(second), Buffer.from('two'))
})

test('injected garbage does not break the frames that follow it', () => {
  const { client, server } = handshake()
  assert.throws(() => server.decrypt(Buffer.alloc(64)), NoiseError)
  const real = client.encrypt(Buffer.from('still fine'))
  assert.deepEqual(server.decrypt(real), Buffer.from('still fine'))
})

test('an app that believes the wrong static key cannot complete the handshake', () => {
  // This is the whole point of putting the key in the QR: a Relay that swaps in
  // its own key fails here instead of quietly reading everything.
  const impostor = generateKeyPair()
  assert.throws(() => handshake({ believedKey: impostor.publicKey }), NoiseError)
})

test('a prologue mismatch aborts the handshake', () => {
  assert.throws(() => handshake({ responderPrologue: Buffer.from('rowel-tunnel/v999') }), NoiseError)
})

test('a truncated first message is refused', () => {
  const bridle = generateKeyPair()
  const responder = new NoiseResponder(bridle, TUNNEL_PROLOGUE)
  assert.throws(() => responder.readMessage(Buffer.alloc(40)), NoiseError)
})

test('public keys round trip through the raw encoding', () => {
  const pair = generateKeyPair()
  assert.ok(constantTimeEqual(publicKeyOf(pair.privateKey), pair.publicKey))
  assert.equal(pair.publicKey.length, 32)
  assert.equal(pair.privateKey.length, 32)
})

test('constant-time comparison rejects different lengths without throwing', () => {
  assert.equal(constantTimeEqual(Buffer.from('ab'), Buffer.from('abc')), false)
  assert.equal(constantTimeEqual(Buffer.from('abc'), Buffer.from('abc')), true)
})

test('the prologue carries no version, so a mismatch can be answered', () => {
  // The property this protects: both ends mix the *same* prologue regardless of
  // which versions they speak, so the responder can always decrypt message one
  // and always send back an authenticated refusal. A version in the prologue
  // made the mismatch fail inside the handshake, where nothing can be said.
  assert.equal(TUNNEL_PROLOGUE.toString('utf8'), 'rowel-tunnel')
  assert.ok(!TUNNEL_PROLOGUE.toString('utf8').includes('/v'))
})

test('negotiation picks the highest shared version', () => {
  assert.equal(negotiateVersion([2, 1], [1, 2]), 2)
  assert.equal(negotiateVersion([1], [1, 2]), 1, 'an older app gets the version it can speak')
  assert.equal(negotiateVersion([3, 2], [1, 2]), 2, 'a newer app falls back to the shared one')
})

test('no overlap is reported rather than guessed at', () => {
  assert.equal(negotiateVersion([9], [1]), undefined)
  assert.equal(negotiateVersion([1], [9]), undefined)
})

test('a client that predates negotiation is treated as version 1', () => {
  // The oldest clients send no `versions` key at all. Refusing them would be a
  // silent break for exactly the population this whole change exists to protect.
  assert.equal(negotiateVersion(undefined, [1, 2]), 1)
  assert.equal(negotiateVersion([], [1, 2]), 1)
  assert.equal(negotiateVersion(undefined, [2]), undefined, 'unless 1 is no longer supported')
})
