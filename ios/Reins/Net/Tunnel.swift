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
    /// The app and the Bridle share no protocol version.
    ///
    /// Carries which end is behind, because "update the older one" is only
    /// actionable if we say which one that is. The machine tells us what it
    /// supports precisely so this can be answered.
    case version(appIsOlder: Bool)
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
    /// One line about what the connection is doing, for the diagnostics screen.
    case note(ConnectionNote)
}

/// One line in the connection log.
///
/// This exists because of a bug that took forty minutes to find and would have
/// taken ten seconds to read: the app had shipped pointing at a relay hostname
/// that had moved, and every screen it could show said "Reaching…". There was
/// no way, from the phone, to learn which address it was dialling or what came
/// back — and the phone is the only place the failing network exists. A Mac
/// cannot reproduce a carrier's route to Cloudflare.
///
/// **Never contains a key, a token, a path, or anything from a conversation.**
/// Host and port, a verdict, and a duration. That bound is what lets this be
/// always-on and screenshot-safe rather than a debug mode someone has to have
/// enabled *before* the thing they need to diagnose.
public struct ConnectionNote: Identifiable, Sendable, Equatable {
    public enum Level: Sendable, Equatable {
        /// Starting something.
        case attempt
        /// It worked.
        case ok
        /// It did not.
        case fail
    }

    public let id: Int
    public let at: Date
    public let level: Level
    public let text: String
}

/// How long a single harness call may take before the app gives up on it.
private let callTimeout: TimeInterval = 120

/// How long to wait for a carrier to answer the handshake before trying the next.
private let handshakeTimeout: TimeInterval = 8

/// Backoff ceiling. Past this the phone is probably not on a network at all, and
/// `poke()` from the foreground observer will get there faster than any timer.
private let maximumBackoff: TimeInterval = 30

/// How long the Relay waits before joining a dial the LAN has already started.
///
/// Long enough that a local handshake — tens of milliseconds on the same Wi-Fi —
/// always finishes first, so a phone at home never touches the Relay. Short
/// enough that a phone on cellular, where the LAN attempts will only ever time
/// out, pays this and nothing more.
private let relayHeadStart: TimeInterval = 0.4

/// How long the app will sit on a silent carrier before deciding it is dead.
///
/// The Bridle pings every 25 seconds whether or not anything is happening, so
/// silence longer than that is not a quiet conversation — it is a socket nobody
/// has been told about. That is the ordinary end of a cellular connection: the
/// radio hands over, the old flow is never delivered again, and nothing
/// anywhere reports an error.
///
/// Left alone this costs minutes. `URLSessionWebSocketTask.receive()` waits on
/// a dead TCP connection until the stack gives up, and for the whole of that
/// wait the app says it is connected, shows a conversation that has moved on
/// without it, and answers every tap with a two-minute call timeout. That is
/// the failure this file's own header promises not to have.
///
/// Reconnecting costs nothing to be wrong about: the handshake is fast and
/// `resume` replays the gap by sequence number, so a false positive is a blink
/// and a missed detection is minutes of lying.
private let silenceLimit: TimeInterval = 40

/// How often to check for that silence.
private let livenessCheckInterval: TimeInterval = 5

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
    private var noteCounter = 0
    /// When the last frame of any kind arrived, including the Bridle's pings.
    private var lastFrameAt = Date()
    private var watchdog: Task<Void, Never>?

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

    /// Add one line to the connection log.
    private func note(_ level: ConnectionNote.Level, _ text: String) {
        noteCounter += 1
        continuation?.yield(.note(ConnectionNote(id: noteCounter, at: Date(), level: level, text: text)))
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
    ///
    /// Also the moment to distrust a connection that looks fine. Coming back to
    /// the app is exactly when the socket is most likely to have died unheard —
    /// iOS suspended the process, the radio moved on without it — so this
    /// checks rather than waiting out the watchdog's next tick.
    public func poke() {
        sleeper?.cancel()
        checkLiveness()
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
                note(.fail, "Refused by the Mac")
                status = .refused(reason: refusal)
                teardown(reason: "refused")
                return
            } catch {
                teardown(reason: "\(error.localizedDescription)")
                if Task.isCancelled { return }
                let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                note(.fail, "\(detail) Retrying in \(elapsed(backoff))")
                status = .waiting(detail: detail, retryIn: backoff)
                await sleep(backoff)
                backoff = min(backoff * 2, maximumBackoff)
                continue
            }
            // `pump` returned without throwing only if it was cancelled.
            return
        }
    }

    /// Dial every way of reaching the machine at once and adopt the first that
    /// answers.
    ///
    /// This used to try the LAN addresses and then the Relay, one after the
    /// other, and that ordering was a bug wearing the clothes of an
    /// optimisation. A LAN address is unroutable from a phone on cellular, and
    /// an unroutable address does not fail — it times out. Two of them cost
    /// sixteen seconds before the Relay was dialled at all, on the one network
    /// where the Relay is the only path that can work.
    ///
    /// So they race. The Relay starts {@link relayHeadStart} late, which is the
    /// whole of the old preference expressed as a number: on Wi-Fi the local
    /// round trip finishes in tens of milliseconds and wins outright, so the
    /// Relay is not dialled at all and never learns the session happened. Off
    /// Wi-Fi the head start is the entire cost of trying, and the LAN attempts
    /// simply time out unheard alongside a connection that is already up.
    ///
    /// A pairing token is one-time, and racing cannot waste it: the Bridle
    /// records this device's static key the moment it accepts a handshake, so
    /// any later attempt from the same device is recognised without a token.
    private func connectOnce() async throws {
        let plan = candidates()
        guard let remoteStatic = bundle.staticKey else {
            throw RefusalReason.machineError("That pairing code has no machine key.")
        }
        guard !plan.isEmpty else {
            throw CarrierError(reason: "No way to reach that Mac.", closeCode: nil)
        }
        let request = HandshakeRequest(name: deviceName, client: clientVersion, token: pairingToken)
        for candidate in plan { note(.attempt, "Dialling \(candidate.label)") }

        var winner: Attempt?
        var failures: [String] = []
        var refusal: RefusalReason?

        await withTaskGroup(of: Outcome.self) { group in
            for candidate in plan {
                group.addTask {
                    await Tunnel.race(candidate, identity: self.identity, remoteStatic: remoteStatic, request: request)
                }
            }
            for await outcome in group {
                switch outcome {
                case .won(let attempt):
                    // A second winner is possible: cancellation is cooperative
                    // and a racer already past its last checkpoint runs to
                    // completion. Closing the loser here is what stops the
                    // Bridle holding a socket nobody reads.
                    if winner == nil {
                        winner = attempt
                        group.cancelAll()
                    } else {
                        attempt.socket.close("lost the race")
                    }
                case .failed(let label, let reason, let took):
                    failures.append("\(label): \(reason)")
                    note(.fail, "\(label) failed after \(elapsed(took)) — \(reason)")
                case .refused(let reason):
                    refusal = reason
                    group.cancelAll()
                case .cancelled:
                    break
                }
            }
        }

        // A refusal outranks a win. It means the machine has an opinion about
        // this device — unpaired, or a protocol it cannot speak — and adopting
        // some other carrier's success would hide an answer that no amount of
        // retrying changes.
        if let refusal {
            winner?.socket.close("refused")
            throw refusal
        }
        guard let winner else {
            if Task.isCancelled { throw CancellationError() }
            throw CarrierError(reason: dialFailure(failures), closeCode: nil)
        }

        note(.ok, "Connected over \(winner.label) in \(elapsed(winner.took))")
        adopt(winner)
    }

    /// Turn what each path did wrong into one sentence a person can act on.
    ///
    /// Every path, not just the last one. "Could not reach that address" is a
    /// different problem depending on whether it came from the Wi-Fi attempt or
    /// the Relay, and the old code kept only whichever failed last.
    private func dialFailure(_ failures: [String]) -> String {
        guard !failures.isEmpty else { return "Could not reach that Mac." }
        return failures.joined(separator: " · ") + "."
    }

    /// Watch for a carrier that has stopped delivering.
    ///
    /// Deliberately not a timeout on `receive()`: a tunnel is idle most of the
    /// time and an idle tunnel is healthy. What distinguishes the two is the
    /// Bridle's ping, which arrives whether or not anyone is talking, so the
    /// question worth asking is "when did anything last arrive", not "how long
    /// has this read been waiting".
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(livenessCheckInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.checkLiveness()
            }
        }
    }

    /// Drop a carrier that has gone quiet for longer than the Bridle's ping.
    private func checkLiveness() {
        guard let socket = carrier else { return }
        let silence = Date().timeIntervalSince(lastFrameAt)
        guard silence > silenceLimit else { return }
        note(.fail, "Nothing heard for \(elapsed(silence)) — treating the connection as dead")
        // Closing is the whole action. It makes the blocked `receive()` throw,
        // which throws out of `pump`, which the reconnect loop already knows
        // how to handle — including failing the calls that were waiting on a
        // socket that was never going to answer.
        socket.close("silent for \(Int(silence))s")
    }

    /// Move a finished handshake into place as the live tunnel.
    private func adopt(_ attempt: Attempt) {
        carrier = attempt.socket
        channel = attempt.channel
        lastFrameAt = Date()
        startWatchdog()
        pairingToken = nil
        confirmation = Pairing.confirmationNumber(handshakeHash: attempt.channel.handshakeHash)
        status = .online(
            carrier: attempt.carrier,
            machine: attempt.reply.machine ?? bundle.name,
            harnessUp: false
        )
    }

    /// One address worth trying.
    private struct Candidate: Sendable {
        let url: URL
        let carrier: Carrier
        /// What to call it on screen and in the log. Host and port only — never
        /// a key, a token, or anything from a conversation.
        let label: String
        /// How long to wait before starting, so a preference can be expressed
        /// without giving up the parallelism.
        let delay: TimeInterval
    }

    /// A handshake that completed, before anyone has adopted it.
    private struct Attempt: @unchecked Sendable {
        let socket: WebSocketCarrier
        let channel: SecureChannel
        let reply: HandshakeReply
        let carrier: Carrier
        let label: String
        let took: TimeInterval
    }

    private enum Outcome: @unchecked Sendable {
        case won(Attempt)
        case failed(label: String, reason: String, took: TimeInterval)
        case refused(RefusalReason)
        case cancelled
    }

    private func candidates() -> [Candidate] {
        var found: [Candidate] = []
        for address in bundle.direct ?? [] {
            guard let url = URL(string: "\(address)/v1/tunnel") else { continue }
            found.append(Candidate(url: url, carrier: .lan, label: "Wi-Fi \(Tunnel.place(url))", delay: 0))
        }
        if var components = URLComponents(string: bundle.relay) {
            components.scheme = components.scheme == "https" || components.scheme == "wss" ? "wss" : "ws"
            components.path = "/v1/app"
            components.queryItems = [URLQueryItem(name: "device", value: bundle.device)]
            if let url = components.url {
                found.append(Candidate(
                    url: url,
                    carrier: .relay,
                    label: "Relay \(Tunnel.place(url))",
                    // No LAN address to lose to means nothing to wait for.
                    delay: found.isEmpty ? 0 : relayHeadStart
                ))
            }
        }
        return found
    }

    /// Host and port, which is all of a URL that is safe to show and all of it
    /// that helps: the path is a constant and the query carries the device id.
    private nonisolated static func place(_ url: URL) -> String {
        let host = url.host ?? "?"
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// Run one candidate to a verdict, touching nothing shared.
    ///
    /// Deliberately not a method on the actor: a racer that hops onto the
    /// actor's executor to do its waiting is not racing, it is queueing, and
    /// the whole point here is that the attempts overlap.
    private nonisolated static func race(
        _ candidate: Candidate,
        identity: StaticKeyPair,
        remoteStatic: Data,
        request: HandshakeRequest
    ) async -> Outcome {
        if candidate.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(candidate.delay * 1_000_000_000))
            if Task.isCancelled { return .cancelled }
        }
        let started = Date()
        let socket = WebSocketCarrier.open(url: candidate.url, timeout: handshakeTimeout)
        do {
            let initiator = try NoiseInitiator(staticKeys: identity, remoteStatic: remoteStatic, prologue: tunnelPrologue)
            try await socket.send(initiator.writeMessage(try request.encoded()))
            let reply = try await withTimeout(handshakeTimeout) { try await socket.receive() }
            let opened = try initiator.readMessage(reply)
            let answer = try JSONDecoder().decode(HandshakeReply.self, from: opened.payload)
            guard answer.ok else {
                socket.close("refused")
                switch answer.reason {
                case "unpaired": return .refused(.unpaired)
                case "version": return .refused(.version(appIsOlder: answer.weAreTheOldEnd))
                default: return .refused(.machineError(answer.reason ?? "unknown"))
                }
            }
            if Task.isCancelled {
                socket.close("lost the race")
                return .cancelled
            }
            return .won(Attempt(
                socket: socket,
                channel: opened.channel,
                reply: answer,
                carrier: candidate.carrier,
                label: candidate.label,
                took: Date().timeIntervalSince(started)
            ))
        } catch {
            socket.close("handshake failed")
            if Task.isCancelled { return .cancelled }
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(label: candidate.label, reason: reason, took: Date().timeIntervalSince(started))
        }
    }

    /// Read frames until the socket dies or the task is cancelled.
    private func pump() async throws {
        guard let socket = carrier, let channel else { throw CallError(code: "disconnected", message: "Not connected.") }
        while !Task.isCancelled {
            let bytes = try await socket.receive()
            lastFrameAt = Date()
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
        watchdog?.cancel()
        watchdog = nil
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

/// A duration, short enough to read at a glance in a log line.
private func elapsed(_ seconds: TimeInterval) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded()))ms" : String(format: "%.1fs", seconds)
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
