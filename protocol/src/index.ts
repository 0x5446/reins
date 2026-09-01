/**
 * Everything two Rowel parties must agree on byte for byte: the Noise
 * instantiation, the tunnel frames carried inside it, the pairing payloads, and
 * the Relay's content-blind switching format.
 *
 * The iOS app reimplements this in Swift. Whenever anything here changes, the
 * Swift twin in `ios/Rowel/Protocol` changes with it, and
 * `e2e/protocol-parity.test.js` is the place that proves they still agree.
 */

export * from './noise.ts'
export * from './frames.ts'
export * from './pairing.ts'
export * from './mux.ts'
export * from './relay-auth.ts'
