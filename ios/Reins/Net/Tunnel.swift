/// One encrypted tunnel to one machine.
///
/// Everything the app does with a machine goes through here: unary calls, both
/// harness downlinks, approvals. One socket, because a phone that holds four is
/// a phone that reconnects four times every time the radio blinks.
///
/// Three properties this file is responsible for:
///
/// - **Confidentiality from the Relay.** Noise IK with the machine's static key
///   known in advance, so the party switching the bytes cannot read or alter
///   them, and cannot substitute itself.
/// - **Losslessness across reconnects.** The Bridle numbers every downlink frame
///   and keeps a replay buffer. On reconnect the app says how far it got and the
///   gap arrives in order, so a half-streamed answer resumes instead of jumping.
/// - **Never hanging.** A phone changes network without telling anyone. Every
///   in-flight call has a deadline, every dropped socket fails its calls, and the
///   reconnect loop backs off rather than hammering.

import Foundation

/// What the app shows about a connection.
public enum TunnelStatus: Equatable, Sendable {
    /// Not started, or stopped on purpose.
    case idle
    /// Dialling, including every retry after the first.
    case connecting
    /// Live. `carrier` is how it got there and `harnessUp` is whether dsh answers.
    case online(carrier: Carrier, machine: String, harnessUp: Bool)
    /// Waiting to retry after a failure. `detail` is what went wrong last time.
    case waiting(detail: String, retryIn: TimeInterval)
    /// The machine will not accept this device. No amount of retrying fixes it.
    case refused(reason: RefusalReason)
}

/// Which path a live tunnel took.
public enum Carrier: String, Equatable, Sendable, Codable {
    /// A direct connection over the local network. No third party involved at all.
    case lan
    /// Through the Relay, which forwards ciphertext it cannot read.
    case relay
}

/// Why a machine refused a device. Each one needs different words on screen.
public enum RefusalReason: Equatable, Sendable {
    /// This device was never paired, or was revoked.
    case unpaired
    /// The app and the Bridle disagree about the protocol version.
    case version
    /// The machine failed internally during the handshake.
    case machineError(String)
}

/// Everything the tunnel tells the app about.
public enum TunnelSignal: Sendable {
    case status(TunnelStatus)
    /// One downlink frame, in sequence.
    case event(EventFrame)
    /// The replay buffer could not reach back far enough. Refetch state.
    case resync(from: Int)
    /// The machine's harness went away or came back.
    case harness(reachable: Bool, detail: String?)
    /// A fresh handshake completed; `confirmation` is the six-digit number.
    case handshake(confirmation: String, host: JSONValue?)
}

/// How long a single harness call may take before the app gives up on it.
private let callTimeout: TimeInterval = 120

/// How long to wait for a carrier to answer the handshake before trying the next.
private let handshakeTimeout: TimeInterval = 8

/// Backoff ceiling. Past this the phone is probably not on a network at all, and
/// `poke()` from the foreground observer will get there faster than any timer.
private let maximumBackoff: TimeInterval = 30

public actor Tunnel {
    private let bundle: PairingBundle
    private let identity: StaticKeyPair
    private let clientVersion: String
    private var deviceName: String
    private var pairingToken: String?

    private var carrier: WebSocketCarrier?
    private var channel: SecureChannel?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var sendChain: Task<Void, Never> = Task {}
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var counter = 0
    private var highestSeq = 0
    private var everConnected = false

    private var continuation: AsyncStream<TunnelSignal>.Continuation?
    private(set) public var status: TunnelStatus = .idle {
        didSet { if status != oldValue { continuation?.yield(.status(status)) } }
    }

    /// The six-digit number to compare against the Mac's screen, for a pairing
    /// that came in by typed code rather than by QR.
    private(set) public var confirmation: String?

    /// - Parameters:
    ///   - bundle: the pairing bundle for this machine.
    ///   - identity: this device's long-term key pair.
    ///   - deviceName: what the machine should call this device.
    ///   - clientVersion: app build string, shown in `bridle status`.
    ///   - pairingToken: present only until the first successful handshake.
    public init(
        bundle: PairingBundle,
        identity: StaticKeyPair,
        deviceName: String,
        clientVersion: String,
        pairingToken: String?
    ) {
        self.bundle = bundle
        self.identity = identity
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.pairingToken = pairingToken
    }

    /// The signal stream. Call once; the second caller gets an empty stream.
    public func signals() -> AsyncStream<TunnelSignal> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.status(status))
        }
    }

    /// Rename this device on the machine's paired list. Takes effect next connect.
    public func rename(to name: String) {
        deviceName = name
    }

    /// Start connecting, and keep reconnecting until `stop()`.
    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Stop, fail everything in flight, and release the socket.
    public func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        teardown(reason: "closed by the app")
        status = .idle
    }

    /// Retry now instead of waiting out the backoff. Called when the app comes
    /// to the foreground or the network path changes.
    public func poke() {
        sleeper?.cancel()
    }

    // MARK: - Calls

    /// Invoke one harness method.
    ///
    /// - Throws: `CallError`. `code == "disconnected"` means the socket went away
    ///   and the call may be safely retried; anything else came from the harness.
    @discardableResult
    public func call(_ method: String, _ payload: JSONValue = .emptyObject) async throws -> JSONValue {
        counter += 1
        let id = "c\(counter)"
        let frame = RequestFrame(id: id, method: method, payload: payload)
        return try await withRequest(id: id) { try self.write(frame) }
    }

    /// Answer an approval or a question.
    ///
    /// The harness routes the answer by the `rpcId` of the request frame, so the
    /// id is echoed back verbatim; `value` is that responder's own payload.
    @discardableResult
    public func respond(rpcId: String, value: JSONValue) async throws -> JSONValue {
        counter += 1
        let id = "r\(counter)"
        let message = JSONValue.object([
            "type": .string("client-response"),
            "rpcId": .string(rpcId),
            "result": .object(["ok": .bool(true), "value": value]),
        ])
        let frame = RespondFrame(id: id, message: message)
        return try await withRequest(id: id) { try self.write(frame) }
    }

    private func withRequest(id: String, _ send: @escaping () throws -> Void) async throws -> JSONValue {
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(callTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.settle(id, .failure(CallError(code: "timeout", message: "The Mac did not answer in time.")))
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send()
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func settle(_ id: String, _ result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    /// Encrypt one frame and hand it to the send queue.
    ///
    /// The cipher counter advances at encryption time, so frames have to reach
    /// the wire in the order they were encrypted — a frame that overtakes its
    /// predecessor fails to authenticate and tears the tunnel down. Encryption
    /// is synchronous on the actor, which fixes the order; `sendChain` then keeps
    /// the awaits in that same order instead of letting the runtime interleave
    /// them.
    private func write(_ frame: TunnelFrame) throws {
        guard let channel, let carrier else {
            throw CallError(code: "disconnected", message: "Not connected to that Mac.")
        }
        let bytes = try channel.encrypt(try frame.encoded())
        let previous = sendChain
        sendChain = Task {
            await previous.value
            try? await carrier.send(bytes)
        }
    }

    // MARK: - Connection loop

    private func run() async {
        var backoff: TimeInterval = 0.5
        while !Task.isCancelled {
            status = .connecting
            do {
                try await connectOnce()
                backoff = 0.5
                try await pump()
            } catch let refusal as RefusalReason {
                status = .refused(reason: refusal)
                teardown(reason: "refused")
                return
            } catch {
                teardown(reason: "\(error.localizedDescription)")
                if Task.isCancelled { return }
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                status = .waiting(detail: detail, retryIn: backoff)
                await sleep(backoff)
                backoff = min(backoff * 2, maximumBackoff)
                continue
            }
            // `pump` returned without throwing only if it was cancelled.
            return
        }
    }

    /// Dial the carriers in order and complete one handshake.
    ///
    /// LAN first: when the phone is on the same Wi-Fi this costs one local round
    /// trip instead of a trip through the Relay, and the Relay never even sees
    /// that the session happened. When the phone is elsewhere, it costs one
    /// failed connect with a short timeout.
    ///
    /// A pairing token is one-time, but attempting LAN first cannot waste it: the
    /// Bridle records this device's static key the moment it accepts the
    /// handshake, so a later attempt from the same device is recognised without
    /// a token at all.
    private func connectOnce() async throws {
        var lastError: Error = CarrierError(reason: "No way to reach that Mac.", closeCode: nil)
        for candidate in candidates() {
            if Task.isCancelled { throw CancellationError() }
            let socket = WebSocketCarrier.open(url: candidate.url, timeout: handshakeTimeout)
            do {
                try await handshake(over: socket, carrier: candidate.carrier)
                return
            } catch let refusal as RefusalReason {
                socket.close("refused")
                throw refusal
            } catch {
                socket.close("handshake failed")
                lastError = error
            }
        }
        throw lastError
    }

    private func candidates() -> [(url: URL, carrier: Carrier)] {
        var found: [(URL, Carrier)] = []
        for address in bundle.direct ?? [] {
            if let url = URL(string: "\(address)/v1/tunnel") { found.append((url, .lan)) }
        }
        if var components = URLComponents(string: bundle.relay) {
            components.scheme = components.scheme == "https" || components.scheme == "wss" ? "wss" : "ws"
            components.path = "/v1/app"
            components.queryItems = [URLQueryItem(name: "device", value: bundle.device)]
            if let url = components.url { found.append((url, .relay)) }
        }
        return found
    }

    private func handshake(over socket: WebSocketCarrier, carrier kind: Carrier) async throws {
        guard let remoteStatic = bundle.staticKey else {
            throw RefusalReason.machineError("That pairing code has no machine key.")
        }
        let initiator = try NoiseInitiator(staticKeys: identity, remoteStatic: remoteStatic, prologue: tunnelPrologue)
        let request = HandshakeRequest(name: deviceName, client: clientVersion, token: pairingToken)
        try await socket.send(initiator.writeMessage(try request.encoded()))

        let reply = try await withTimeout(handshakeTimeout) { try await socket.receive() }
        let opened = try initiator.readMessage(reply)
        let answer = try JSONDecoder().decode(HandshakeReply.self, from: opened.payload)
        guard answer.ok else {
            switch answer.reason {
            case "unpaired": throw RefusalReason.unpaired
            case "version": throw RefusalReason.version
            default: throw RefusalReason.machineError(answer.reason ?? "unknown")
            }
        }

        carrier = socket
        channel = opened.channel
        pairingToken = nil
        confirmation = Pairing.confirmationNumber(handshakeHash: opened.channel.handshakeHash)
        status = .online(carrier: kind, machine: answer.machine ?? bundle.name, harnessUp: false)
    }

    /// Read frames until the socket dies or the task is cancelled.
    private func pump() async throws {
        guard let socket = carrier, let channel else { throw CallError(code: "disconnected", message: "Not connected.") }
        while !Task.isCancelled {
            let bytes = try await socket.receive()
            let plaintext: Data
            do {
                plaintext = try channel.decrypt(bytes)
            } catch {
                // A frame that fails authentication means this carrier is no
                // longer trustworthy for anything. Tearing down is the only safe
                // response; the reconnect gets a fresh handshake.
                throw CarrierError(reason: "The connection was tampered with and has been closed.", closeCode: nil)
            }
            handle(try ServerFrame.decode(plaintext))
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .ready(let ready):
            // Events do not flow until the app asks. On a first connection it
            // asks from the machine's own head, so it gets what happens next
            // rather than a replay of a conversation it is about to fetch in
            // full; on a reconnect it asks from where it left off.
            if !everConnected {
                highestSeq = ready.seq
                everConnected = true
            }
            status = .online(carrier: currentCarrier, machine: ready.machine, harnessUp: ready.dshReachable)
            continuation?.yield(.handshake(confirmation: confirmation ?? "", host: ready.host))
            continuation?.yield(.harness(reachable: ready.dshReachable, detail: nil))
            try? write(ResumeFrame(since: highestSeq))
        case .response(let id, let result):
            settle(id, result.mapError { $0 as Error })
        case .event(let event):
            highestSeq = max(highestSeq, event.seq)
            continuation?.yield(.event(event))
        case .resync(let from):
            highestSeq = from
            continuation?.yield(.resync(from: from))
        case .status(let reachable, let detail):
            if case .online(let carrier, let machine, _) = status {
                status = .online(carrier: carrier, machine: machine, harnessUp: reachable)
            }
            continuation?.yield(.harness(reachable: reachable, detail: detail))
        case .ping(let nonce):
            try? write(PongFrame(nonce: nonce))
        case .pong:
            break
        case .fault(let code, let message):
            status = .refused(reason: code == "unpaired" ? .unpaired : .machineError(message))
        case .unknown:
            // Frames a newer Bridle sends. Ignoring them is what lets the
            // protocol grow without stranding installed apps.
            break
        }
    }

    private var currentCarrier: Carrier {
        if case .online(let carrier, _, _) = status { return carrier }
        return .relay
    }

    private func teardown(reason: String) {
        carrier?.close(reason)
        carrier = nil
        channel = nil
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: CallError(code: "disconnected", message: "The connection to that Mac dropped."))
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        let task = Task {
            _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        sleeper = task
        await task.value
        sleeper = nil
    }
}

/// Race an operation against a deadline.
private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CarrierError(reason: "The Mac did not answer in time.", closeCode: nil)
        }
        guard let first = try await group.next() else {
            throw CarrierError(reason: "The Mac did not answer.", closeCode: nil)
        }
        group.cancelAll()
        return first
    }
}

extension RefusalReason: Error, LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unpaired: return "This iPhone isn’t paired with that Mac any more."
        case .version: return "The Reins app and that Mac’s Bridle are different versions."
        case .machineError(let detail): return detail
        }
    }
}
