/** The Relay's two contracts: how circuits are framed, and how a machine claims its slot. */

import assert from 'node:assert/strict'
import test from 'node:test'
import {
  MUX_HEADER_LENGTH,
  MuxType,
  decodeMux,
  deviceIdFor,
  encodeMux,
  generateSigningKeyPair,
  mintNonce,
  signPairOffer,
  signRegistration,
  signingPublicKeyOf,
  verifyPairOffer,
  verifyRegistration,
} from '../lib/index.js'

test('mux frames round trip with their circuit id intact', () => {
  const payload = Buffer.from('ciphertext would go here')
  const encoded = encodeMux(MuxType.Data, 4_294_967_295, payload)
  const decoded = decodeMux(encoded)
  assert.equal(decoded.type, MuxType.Data)
  assert.equal(decoded.circuit, 4_294_967_295)
  assert.deepEqual(decoded.payload, payload)
})

test('a bare close frame carries no payload', () => {
  const decoded = decodeMux(encodeMux(MuxType.Close, 7))
  assert.equal(decoded.payload.length, 0)
  assert.equal(decoded.circuit, 7)
})

test('a frame shorter than the header is refused', () => {
  assert.throws(() => decodeMux(Buffer.alloc(MUX_HEADER_LENGTH - 1)), /shorter than its header/)
})

test('an unknown frame type is refused rather than guessed at', () => {
  const bogus = encodeMux(MuxType.Data, 1, Buffer.alloc(0))
  bogus.writeUInt8(0x7f, 0)
  assert.throws(() => decodeMux(bogus), /unknown type/)
})

test('a device id is the hash of the signing key, so it cannot be claimed by anyone else', () => {
  const keys = generateSigningKeyPair()
  assert.equal(deviceIdFor(keys.publicKey), deviceIdFor(signingPublicKeyOf(keys.privateKey)))
  assert.notEqual(deviceIdFor(keys.publicKey), deviceIdFor(generateSigningKeyPair().publicKey))
})

test('a registration verifies only against the nonce it was signed for', () => {
  const keys = generateSigningKeyPair()
  const nonce = mintNonce()
  const signature = signRegistration(keys.privateKey, nonce)
  assert.equal(verifyRegistration(keys.publicKey, nonce, signature), true)
  assert.equal(verifyRegistration(keys.publicKey, mintNonce(), signature), false)
  assert.equal(verifyRegistration(generateSigningKeyPair().publicKey, nonce, signature), false)
})

test('a registration signature cannot be replayed as a pairing offer', () => {
  // Domain separation: the two signatures cover different contexts, so a
  // captured registration cannot park a pairing bundle in someone else's name.
  const keys = generateSigningKeyPair()
  const value = mintNonce()
  assert.equal(verifyPairOffer(keys.publicKey, value, signRegistration(keys.privateKey, value)), false)
  assert.equal(verifyRegistration(keys.publicKey, value, signPairOffer(keys.privateKey, value)), false)
})

test('malformed keys and signatures fail verification instead of throwing', () => {
  assert.equal(verifyRegistration(Buffer.alloc(3), 'nonce', 'not-a-signature'), false)
})
