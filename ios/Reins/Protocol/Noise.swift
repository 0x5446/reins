/// Noise_IK_25519_ChaChaPoly_SHA256 over CryptoKit.
///
/// The Swift twin of `protocol/src/noise.ts`. The two are held to the same bytes
/// by `ReinsTests/ParityTests.swift`, which replays vectors the TypeScript side
/// generates — if this file and that one ever disagree, the tests say so before
/// a user does.
///
/// Reins is the initiator: it learns the machine's static public key from the
/// pairing QR before the first byte, which is exactly the IK pre-message. That
/// buys mutual authentication, forward secrecy once message two lands, and
/// identity hiding from the Relay, which never sees more than two ephemeral
/// public keys and ciphertext.

import CryptoKit
import Foundation

/// Wire name of the concrete Noise instantiation both ends agree on.
public let noiseProtocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

/// Raw X25519 public-key length.
public let noiseKeyLength = 32

/// Poly1305 tag length appended to every ciphertext.
public let noiseTagLength = 16

/// A handshake or transport failure. Never carries key material.
public enum NoiseError: Error, LocalizedError, Equatable {
    case badKeyLength(String)
    case truncated(String)
    case authenticationFailed
    case outOfOrder(String)

    public var errorDescription: String? {
        switch self {
        case .badKeyLength(let what): return "\(what) has the wrong length"
        case .truncated(let what): return "\(what) is truncated"
        case .authenticationFailed: return "frame failed authentication"
        case .outOfOrder(let what): return what
        }
    }
}

/// An X25519 key pair in the raw 32-byte form the wire and the Keychain use.
public struct StaticKeyPair: Sendable, Equatable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data, publicKey: Data) {
        self.privateKey = privateKey
        self.publicKey = publicKey
    }

    /// Derive the pair from a raw private scalar.
    public init(privateKey: Data) throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.privateKey = privateKey
        self.publicKey = key.publicKey.rawRepresentation
    }

    /// Generate a fresh identity.
    public static func generate() -> StaticKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return StaticKeyPair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }
}

/// X25519 agreement over raw keys, returning the bare shared secret Noise wants.
private func diffieHellman(_ privateKey: Data, _ publicKey: Data) throws -> Data {
    guard privateKey.count == noiseKeyLength else { throw NoiseError.badKeyLength("private key") }
    guard publicKey.count == noiseKeyLength else { throw NoiseError.badKeyLength("public key") }
    let secret = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
    return secret.withUnsafeBytes { Data($0) }
}

/// Noise HKDF: RFC 5869 with an empty info, keeping the first two 32-byte outputs.
private func hkdf2(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
    let derived = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
        salt: chainingKey,
        info: Data(),
        outputByteCount: 64
    )
    let bytes = derived.withUnsafeBytes { Data($0) }
    // Re-wrap: a `Data` slice keeps the parent's indices, and code downstream
    // that indexes from zero would read the wrong bytes.
    return (Data(bytes.prefix(32)), Data(bytes.suffix(32)))
}

/// Noise 12-byte nonce: four zero bytes then the little-endian counter.
private func nonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
    var raw = Data(repeating: 0, count: 12)
    withUnsafeBytes(of: counter.littleEndian) { raw.replaceSubrange(4..<12, with: $0) }
    return try ChaChaPoly.Nonce(data: raw)
}

private func seal(key: Data, counter: UInt64, aad: Data, plaintext: Data) throws -> Data {
    let box = try ChaChaPoly.seal(
        plaintext,
        using: SymmetricKey(data: key),
        nonce: nonce(for: counter),
        authenticating: aad
    )
    return box.ciphertext + box.tag
}

private func open(key: Data, counter: UInt64, aad: Data, ciphertext: Data) throws -> Data {
    guard ciphertext.count >= noiseTagLength else { throw NoiseError.truncated("ciphertext") }
    let body = Data(ciphertext.prefix(ciphertext.count - noiseTagLength))
    let tag = Data(ciphertext.suffix(noiseTagLength))
    let box = try ChaChaPoly.SealedBox(nonce: nonce(for: counter), ciphertext: body, tag: tag)
    do {
        // The tag is the only thing that can fail here, and saying which byte
        // differed would be an oracle.
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
    } catch {
        throw NoiseError.authenticationFailed
    }
}

/// The Noise SymmetricState: running hash, chaining key, and handshake cipher.
private struct SymmetricState {
    private var chainingKey: Data
    private var hash: Data
    private var key: Data?
    private var counter: UInt64 = 0

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        hash = name.count <= 32 ? name + Data(repeating: 0, count: 32 - name.count) : Data(SHA256.hash(data: name))
        chainingKey = hash
    }

    mutating func mixHash(_ data: Data) {
        hash = Data(SHA256.hash(data: hash + data))
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let (nextChaining, nextKey) = hkdf2(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = nextChaining
        key = nextKey
        counter = 0
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key else {
            mixHash(plaintext)
            return plaintext
        }
        let ciphertext = try seal(key: key, counter: counter, aad: hash, plaintext: plaintext)
        counter += 1
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key else {
            mixHash(ciphertext)
            return ciphertext
        }
        let plaintext = try open(key: key, counter: counter, aad: hash, ciphertext: ciphertext)
        counter += 1
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (Data, Data) {
        hkdf2(chainingKey: chainingKey, inputKeyMaterial: Data())
    }

    /// Channel binding value: the final handshake hash, safe to show in the clear.
    var handshakeHash: Data { hash }
}

/// One direction of an established channel.
///
/// Counters are strictly monotonic, so a replayed or reordered frame fails to
/// decrypt rather than being accepted out of order. A failure does *not* advance
/// the counter: one injected garbage frame must not desynchronize a live
/// conversation.
private final class CipherState {
    private let key: Data
    private var counter: UInt64 = 0

    init(key: Data) { self.key = key }

    func encrypt(_ plaintext: Data) throws -> Data {
        let frame = try seal(key: key, counter: counter, aad: Data(), plaintext: plaintext)
        counter += 1
        return frame
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        let plaintext = try open(key: key, counter: counter, aad: Data(), ciphertext: ciphertext)
        counter += 1
        return plaintext
    }
}

/// An established, authenticated, bidirectional channel.
public final class SecureChannel {
    private let sending: CipherState
    private let receiving: CipherState

    /// The authenticated raw public key of the peer.
    public let remoteStatic: Data

    /// Channel binding value, used for the six-digit confirmation number.
    public let handshakeHash: Data

    fileprivate init(sending: CipherState, receiving: CipherState, remoteStatic: Data, handshakeHash: Data) {
        self.sending = sending
        self.receiving = receiving
        self.remoteStatic = remoteStatic
        self.handshakeHash = handshakeHash
    }

    /// Encrypt one outbound frame.
    public func encrypt(_ plaintext: Data) throws -> Data {
        try sending.encrypt(plaintext)
    }

    /// Decrypt one inbound frame.
    public func decrypt(_ ciphertext: Data) throws -> Data {
        try receiving.decrypt(ciphertext)
    }
}

/// Initiator half of Noise IK: the phone.
public final class NoiseInitiator {
    private var state: SymmetricState
    private let staticKeys: StaticKeyPair
    private let remoteStatic: Data
    private let ephemeral: StaticKeyPair
    private var written = false

    /// - Parameters:
    ///   - staticKeys: this device's long-term key pair.
    ///   - remoteStatic: the machine's raw static public key, from pairing.
    ///   - prologue: bytes both ends mix in first; carries the protocol version.
    ///   - ephemeral: test-only override. A fresh ephemeral per handshake is what
    ///     provides forward secrecy, so only the parity vectors pass this.
    public init(
        staticKeys: StaticKeyPair,
        remoteStatic: Data,
        prologue: Data = Data(),
        ephemeral: StaticKeyPair = .generate()
    ) throws {
        guard remoteStatic.count == noiseKeyLength else { throw NoiseError.badKeyLength("remote static key") }
        self.staticKeys = staticKeys
        self.remoteStatic = remoteStatic
        self.ephemeral = ephemeral
        state = SymmetricState(protocolName: noiseProtocolName)
        state.mixHash(prologue)
        state.mixHash(remoteStatic)
    }

    /// Produce handshake message one (`e, es, s, ss`).
    public func writeMessage(_ payload: Data) throws -> Data {
        guard !written else { throw NoiseError.outOfOrder("handshake message one was already written") }
        written = true
        state.mixHash(ephemeral.publicKey)
        state.mixKey(try diffieHellman(ephemeral.privateKey, remoteStatic))
        let encryptedStatic = try state.encryptAndHash(staticKeys.publicKey)
        state.mixKey(try diffieHellman(staticKeys.privateKey, remoteStatic))
        let encryptedPayload = try state.encryptAndHash(payload)
        return ephemeral.publicKey + encryptedStatic + encryptedPayload
    }

    /// Consume handshake message two (`e, ee, se`) and establish the channel.
    public func readMessage(_ message: Data) throws -> (channel: SecureChannel, payload: Data) {
        guard written else { throw NoiseError.outOfOrder("handshake message one has not been written") }
        let message = Data(message)
        guard message.count >= noiseKeyLength else { throw NoiseError.truncated("handshake message two") }
        let remoteEphemeral = Data(message.prefix(noiseKeyLength))
        state.mixHash(remoteEphemeral)
        state.mixKey(try diffieHellman(ephemeral.privateKey, remoteEphemeral))
        state.mixKey(try diffieHellman(staticKeys.privateKey, remoteEphemeral))
        let payload = try state.decryptAndHash(Data(message.dropFirst(noiseKeyLength)))
        let (sendKey, receiveKey) = state.split()
        let channel = SecureChannel(
            sending: CipherState(key: sendKey),
            receiving: CipherState(key: receiveKey),
            remoteStatic: remoteStatic,
            handshakeHash: state.handshakeHash
        )
        return (channel, payload)
    }
}

/// Responder half of Noise IK: the Bridle.
///
/// The app never responds to a handshake in production — it is here so the tests
/// can drive both halves and prove this file agrees with the TypeScript one in
/// both directions.
public final class NoiseResponder {
    private var state: SymmetricState
    private let staticKeys: StaticKeyPair
    private let ephemeral: StaticKeyPair
    private var remoteStatic: Data?
    private var remoteEphemeral: Data?

    public init(staticKeys: StaticKeyPair, prologue: Data = Data(), ephemeral: StaticKeyPair = .generate()) {
        self.staticKeys = staticKeys
        self.ephemeral = ephemeral
        state = SymmetricState(protocolName: noiseProtocolName)
        state.mixHash(prologue)
        state.mixHash(staticKeys.publicKey)
    }

    /// Consume handshake message one and recover the initiator's identity.
    public func readMessage(_ message: Data) throws -> (remoteStatic: Data, payload: Data) {
        guard self.remoteStatic == nil else { throw NoiseError.outOfOrder("handshake message one was already read") }
        let message = Data(message)
        let minimum = noiseKeyLength + noiseKeyLength + noiseTagLength
        guard message.count >= minimum else { throw NoiseError.truncated("handshake message one") }
        let peerEphemeral = Data(message.prefix(noiseKeyLength))
        remoteEphemeral = peerEphemeral
        state.mixHash(peerEphemeral)
        state.mixKey(try diffieHellman(staticKeys.privateKey, peerEphemeral))
        let peerStatic = try state.decryptAndHash(Data(message[noiseKeyLength..<minimum]))
        guard peerStatic.count == noiseKeyLength else { throw NoiseError.badKeyLength("peer static key") }
        state.mixKey(try diffieHellman(staticKeys.privateKey, peerStatic))
        let payload = try state.decryptAndHash(Data(message.dropFirst(minimum)))
        remoteStatic = peerStatic
        return (peerStatic, payload)
    }

    /// Produce handshake message two and establish the channel.
    public func writeMessage(_ payload: Data) throws -> (message: Data, channel: SecureChannel) {
        guard let peerStatic = remoteStatic, let peerEphemeral = remoteEphemeral else {
            throw NoiseError.outOfOrder("handshake message one has not been read")
        }
        state.mixHash(ephemeral.publicKey)
        state.mixKey(try diffieHellman(ephemeral.privateKey, peerEphemeral))
        state.mixKey(try diffieHellman(ephemeral.privateKey, peerStatic))
        let encryptedPayload = try state.encryptAndHash(payload)
        let (receiveKey, sendKey) = state.split()
        let channel = SecureChannel(
            sending: CipherState(key: sendKey),
            receiving: CipherState(key: receiveKey),
            remoteStatic: peerStatic,
            handshakeHash: state.handshakeHash
        )
        return (ephemeral.publicKey + encryptedPayload, channel)
    }
}
