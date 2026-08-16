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
    /// `direct` is where the machine says it can be dialled locally right now —
    /// nil from a Bridle too old to say.
    case handshake(confirmation: String, host: JSONValue?, direct: [String]?)
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

/// Every deadline the tunnel keeps, in one place.
///
/// Gathered into a value rather than left as file constants so a test can run
/// them in milliseconds. The failures worth testing here are all defined by
/// time — a carrier that has been quiet *too long*, an address that died *too
/// soon* after being adopted — and a suite that has to wait forty real seconds
/// to ask about the first one is a suite nobody runs.
///
/// The defaults are the shipping values, and each is explained where it is used.
public struct TunnelTimings: Sendable {
    /// How long a single harness call may take before the app gives up on it.
    public var call: TimeInterval = 120
    /// How long to wait for a carrier to answer the handshake.
    public var handshake: TimeInterval = 8

    /// Backoff ceiling. Past this the phone is probably not on a network at
    /// all, and `poke()` from the foreground observer will get there faster
    /// than any timer.
    public var maximumBackoff: TimeInterval = 30

    /// How long the Relay waits before joining a dial the LAN has started.
    ///
    /// Long enough that a local handshake — tens of milliseconds on the same
    /// Wi-Fi — always finishes first, so a phone at home never touches the
    /// Relay. Short enough that a phone on cellular, where the LAN attempts
    /// will only ever time out, pays this and nothing more.
    public var relayHeadStart: TimeInterval = 0.4

    /// How long the app will sit on a silent carrier before deciding it is dead.
    ///
    /// The Bridle pings every 25 seconds whether or not anything is happening,
    /// so silence longer than that is not a quiet conversation — it is a socket
    /// nobody has been told about. That is the ordinary end of a cellular
    /// connection: the radio hands over, the old flow is never delivered again,
    /// and nothing anywhere reports an error.
    ///
    /// Left alone this costs minutes. `URLSessionWebSocketTask.receive()` waits
    /// on dead TCP until the stack gives up, and for the whole of that wait the
    /// app says it is connected, shows a conversation that has moved on without
    /// it, and answers every tap with a call timeout. That is the failure this
    /// file's own header promises not to have.
    ///
    /// Reconnecting costs nothing to be wrong about: the handshake is fast and
    /// `resume` replays the gap by sequence number, so a false positive is a
    /// blink and a missed detection is minutes of lying.
    public var silenceLimit: TimeInterval = 40

    /// How often to check for that silence.
    public var livenessCheck: TimeInterval = 5

    /// A direct connection that dies this soon after being adopted was not
    /// worth adopting. Long enough to cover a handshake that succeeds onto
    /// Wi-Fi the phone is about to fall off, short enough that an ordinary
    /// evening's disconnection is not mistaken for one.
    public var flapWindow: TimeInterval = 20

    /// How long to leave a flapping address alone. Long enough that walking out
    /// of range does not produce a switch every time the signal returns; short
    /// enough that a router which was rebooting is forgiven within the sitting.
    public var flapPenalty: TimeInterval = 300

    public init() {}
}

public actor Tunnel {
    private let bundle: PairingBundle
    private let identity: StaticKeyPair
    private let clientVersion: String
    private let open: CarrierOpener
    private let timings: TunnelTimings
    private let watchNetwork: Bool
    private var deviceName: String
    private var pairingToken: String?

    private var carrier: (any Carrying)?
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
    private var watcher: PathWatcher?
    private var upgrade: Task<Void, Never>?
    /// Bumped on every adopted carrier, so `pump` can tell a socket it is still
    /// reading from apart from one that was retired under it.
    private var carrierGeneration = 0
    /// Which direct address is live, and since when — the two facts needed to
    /// know whether a drop counts as flapping.
    private var adoptedLabel: String?
    private var adoptedAt: Date?
    /// Direct addresses not to try again before this moment.
    private var lanPenalty: [String: Date] = [:]
    /// Whether the phone currently has Wi-Fi. Set by the first path update,
    /// which `NWPathMonitor` delivers as soon as it is started.
    private var onWiFi = false
    /// The machine's current LAN addresses, as told by the last `ready` frame.
    ///
    /// The bundle's copy is a snapshot from pairing day; this one is from the
    /// last time the machine actually answered. A Mac that moved to a hotspot
    /// is dialled where it is, not where it was. `nil` until a ready frame says
    /// — including from an old Bridle that never will, which keeps the bundle
    /// copy in use rather than discarding addresses that may still be right.
    private var learnedDirect: [String]?

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
    ///   - open: how to obtain a carrier. Tests pass a pair of in-memory pipes
    ///     so that a socket can be made to go quiet, or to be retired mid-read,
    ///     on demand — the two failures that made this file worth testing and
    ///     that a real WebSocket cannot be asked to perform.
    ///   - watchNetwork: whether to observe the system's network path. Off in
    ///     tests, where a real `NWPathMonitor` would fire on the machine running
    ///     them and start upgrades nobody asked for.
    public init(
        bundle: PairingBundle,
        identity: StaticKeyPair,
        deviceName: String,
        clientVersion: String,
        pairingToken: String?,
        open: @escaping CarrierOpener = { WebSocketCarrier.open(url: $0, timeout: $1) },
        watchNetwork: Bool = true,
        timings: TunnelTimings = TunnelTimings()
    ) {
        self.bundle = bundle
        self.identity = identity
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.pairingToken = pairingToken
        self.open = open
        self.watchNetwork = watchNetwork
        self.timings = timings
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
        if watchNetwork {
            watcher = PathWatcher { [weak self] onWiFi in
                Task { await self?.networkChanged(onWiFi: onWiFi) }
            }
        }
        loop = Task { await self.run() }
    }

    /// Stop, fail everything in flight, and release the socket.
    public func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        upgrade?.cancel()
        upgrade = nil
        watcher = nil
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
        // Coming back is also the likeliest moment to have walked in the door
        // while the app was asleep, still holding a relayed connection.
        considerUpgrade()
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
        let limit = timings.call
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
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
                backoff = min(backoff * 2, timings.maximumBackoff)
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
        let (winner, failures, refusal) = await dial(plan, remoteStatic: remoteStatic)

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

    /// Race a set of candidates and return the first handshake that completed.
    ///
    /// Shared by the opening dial and by the upgrade to Wi-Fi, which are the
    /// same operation asked at different moments — and which must stay the same
    /// operation, because the second one exists to hand over to a connection
    /// indistinguishable from one the first would have made.
    private func dial(
        _ plan: [Candidate],
        remoteStatic: Data
    ) async -> (winner: Attempt?, failures: [String], refusal: RefusalReason?) {
        let request = HandshakeRequest(name: deviceName, client: clientVersion, token: pairingToken)
        for candidate in plan { note(.attempt, "Dialling \(candidate.label)") }

        var winner: Attempt?
        var failures: [String] = []
        var refusal: RefusalReason?

        await withTaskGroup(of: Outcome.self) { group in
            for candidate in plan {
                group.addTask {
                    await Tunnel.race(candidate, identity: self.identity, remoteStatic: remoteStatic, request: request, open: self.open, timeout: self.timings.handshake)
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
        return (winner, failures, refusal)
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
        let interval = timings.livenessCheck
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.checkLiveness()
            }
        }
    }

    /// Drop a carrier that has gone quiet for longer than the Bridle's ping.
    private func checkLiveness() {
        guard let socket = carrier else { return }
        let silence = Date().timeIntervalSince(lastFrameAt)
        guard silence > timings.silenceLimit else { return }
        note(.fail, "Nothing heard for \(elapsed(silence)) — treating the connection as dead")
        // Closing is the whole action. It makes the blocked `receive()` throw,
        // which throws out of `pump`, which the reconnect loop already knows
        // how to handle — including failing the calls that were waiting on a
        // socket that was never going to answer.
        socket.close("silent for \(Int(silence))s")
    }

    // MARK: - Upgrading to the local network

    /// Move a relayed connection onto the local network when one appears.
    ///
    /// A phone that walks in the door is still talking through Cloudflare, and
    /// will be until something makes it reconnect — which, since the relay is
    /// working, is nothing. That costs latency on every keystroke, spends the
    /// Worker's request budget on traffic that never needed to leave the flat,
    /// and tells the relay a session is happening when the two machines are a
    /// metre apart.
    ///
    /// Three rules, and each one is there because the naive version is worse
    /// than not doing it:
    ///
    /// - **Triggered, never polled.** Only a path change or a return to the
    ///   foreground starts this. A timer would wake the radio to ask a question
    ///   whose answer is almost always "no".
    /// - **Built before adopted.** The relay carrier is not touched until the
    ///   local handshake has completed. A failed upgrade is invisible; there is
    ///   no window in which neither is live.
    /// - **Penalised if it flaps.** Wi-Fi at the edge of range connects and
    ///   dies, and a switch that keeps happening is worse than never switching
    ///   at all. An address that drops within {@link flapWindow} of being
    ///   adopted is left alone for {@link flapPenalty}.
    private func considerUpgrade() {
        // Without Wi-Fi there is no local address to reach, and trying anyway
        // costs two eight-second timeouts with the radio awake for both — on
        // every return to the foreground, for a phone that is out of the house
        // and cannot possibly succeed.
        guard onWiFi else { return }
        guard case .online(.relay, _, _) = status else { return }
        guard upgrade == nil else { return }
        // Only while nothing is outstanding. A call already sent to the relay
        // would be answered on a socket about to be retired, and while the
        // event stream survives a swap by sequence number, a reply does not:
        // it has nowhere to be replayed from.
        guard pending.isEmpty else { return }
        let targets = directCandidates()
        guard !targets.isEmpty else { return }
        upgrade = Task { await self.attemptUpgrade(targets) }
    }

    private func attemptUpgrade(_ targets: [Candidate]) async {
        defer { upgrade = nil }
        guard let remoteStatic = bundle.staticKey else { return }
        note(.attempt, "On the relay with Wi-Fi available — trying to go direct")
        let (winner, _, refusal) = await dial(targets, remoteStatic: remoteStatic)
        // A refusal here is not the refusal it would be during a dial. The
        // relay connection is up and working, and whatever the Mac thinks of
        // this device over the local address, taking down a live tunnel to act
        // on it would replace a working app with a broken one.
        if let refusal { note(.fail, "The Mac refused the direct connection: \(refusal)") }
        guard let winner else {
            note(.attempt, "Staying on the relay")
            return
        }

        // Everything checked before the dial has had a whole handshake to stop
        // being true: the relay may have dropped, a call may have gone out, the
        // person may have backgrounded the app. Adopting on stale premises is
        // how a "seamless" switch loses a reply.
        guard case .online(.relay, _, _) = status, pending.isEmpty else {
            winner.socket.close("no longer needed")
            return
        }
        let retiring = carrier
        adopt(winner)
        adoptedAt = Date()
        adoptedLabel = winner.label
        // Retired only after the new one is in place, and its in-flight bytes
        // are dropped rather than decrypted: `pump` compares generations, and
        // anything it discards is replayed by `resume` because nothing that was
        // dropped ever advanced `highestSeq`.
        retiring?.close("upgraded to the local network")
        note(.ok, "Moved off the relay onto \(winner.label) in \(elapsed(winner.took))")
    }

    /// Local addresses worth trying, minus any that have just proved flaky.
    private func directCandidates() -> [Candidate] {
        let now = Date()
        return candidates().filter { candidate in
            guard candidate.carrier == .lan else { return false }
            guard let until = lanPenalty[candidate.label] else { return true }
            return now >= until
        }
    }

    /// Record that a direct connection did not last, so the next chance to take
    /// it is not taken immediately.
    private func penaliseIfItFlapped() {
        guard let label = adoptedLabel, let at = adoptedAt else { return }
        adoptedLabel = nil
        adoptedAt = nil
        guard Date().timeIntervalSince(at) < timings.flapWindow else { return }
        lanPenalty[label] = Date().addingTimeInterval(timings.flapPenalty)
        note(.fail, "\(label) dropped after \(elapsed(Date().timeIntervalSince(at))) — leaving it alone for a while")
    }

    /// The phone's network changed under the connection.
    private func networkChanged(onWiFi: Bool) {
        self.onWiFi = onWiFi
        note(.attempt, onWiFi ? "Joined a Wi-Fi network" : "Left Wi-Fi")
        // Retry now rather than sitting out a backoff that was set for a
        // network that no longer exists.
        sleeper?.cancel()
        if onWiFi {
            considerUpgrade()
        } else if case .online(.lan, _, _) = status {
            // A local address is not merely slow without Wi-Fi, it is
            // unreachable, so there is nothing to wait forty seconds to learn.
            note(.fail, "Wi-Fi went away while connected directly — reconnecting")
            carrier?.close("left the network")
        }
    }

    /// Move a finished handshake into place as the live tunnel.
    private func adopt(_ attempt: Attempt) {
        carrier = attempt.socket
        channel = attempt.channel
        carrierGeneration += 1
        lastFrameAt = Date()
        startWatchdog()
        pairingToken = nil
        confirmation = Pairing.confirmationNumber(handshakeHash: attempt.channel.handshakeHash)
        // Whether dsh is up is a fact about the Mac, not about the wire, so it
        // survives a change of wire. Resetting it would flash "dsh isn't
        // running" across the screen during an upgrade in which nothing about
        // dsh happened; on a first connection there is nothing to carry and
        // `ready` fills it in a moment later either way.
        var harnessUp = false
        if case .online(_, _, let known) = status { harnessUp = known }
        status = .online(
            carrier: attempt.carrier,
            machine: attempt.reply.machine ?? bundle.name,
            harnessUp: harnessUp
        )
        // Tracked for any adopted direct carrier, not just an upgraded one: an
        // address that drops connections does it whether the opening race or
        // the upgrade was what picked it.
        if attempt.carrier == .lan {
            adoptedLabel = attempt.label
            adoptedAt = Date()
        } else {
            adoptedLabel = nil
            adoptedAt = nil
        }
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
        let socket: any Carrying
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
        let now = Date()
        for address in learnedDirect ?? bundle.direct ?? [] {
            guard let url = URL(string: "\(address)/v1/tunnel") else { continue }
            let label = "Wi-Fi \(Tunnel.place(url))"
            // A penalised address is skipped by the opening dial too, not just
            // by the upgrade. Racing an address that has just proved it drops
            // connections is how a flap becomes a loop: it wins the race
            // precisely because it is local, then dies, then wins again.
            if let until = lanPenalty[label], now < until { continue }
            found.append(Candidate(url: url, carrier: .lan, label: label, delay: 0))
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
                    delay: found.isEmpty ? 0 : timings.relayHeadStart
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
        request: HandshakeRequest,
        open: CarrierOpener,
        timeout: TimeInterval
    ) async -> Outcome {
        if candidate.delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(candidate.delay * 1_000_000_000))
            if Task.isCancelled { return .cancelled }
        }
        let started = Date()
        let socket = open(candidate.url, timeout)
        do {
            let initiator = try NoiseInitiator(staticKeys: identity, remoteStatic: remoteStatic, prologue: tunnelPrologue)
            try await socket.send(initiator.writeMessage(try request.encoded()))
            let reply = try await withTimeout(timeout) { try await socket.receive() }
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
    ///
    /// Re-reads `carrier` every pass rather than holding the one it started
    /// with, because an upgrade to Wi-Fi replaces it mid-loop. The generation
    /// counter is what makes that safe: bytes that arrive on a socket already
    /// retired belong to a cipher state that no longer exists, and its failure
    /// belongs to a connection nobody is using — neither should be allowed to
    /// tear down the connection that took its place. Discarding them loses
    /// nothing, because nothing discarded advanced `highestSeq`, and the new
    /// carrier's `resume` asks for everything past it.
    private func pump() async throws {
        while !Task.isCancelled {
            guard let socket = carrier, let channel else {
                throw CallError(code: "disconnected", message: "Not connected.")
            }
            let generation = carrierGeneration
            let bytes: Data
            do {
                bytes = try await socket.receive()
            } catch {
                if carrierGeneration != generation { continue }
                throw error
            }
            guard carrierGeneration == generation else { continue }
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
            if let direct = ready.direct, direct != learnedDirect {
                learnedDirect = direct
                note(.ok, direct.isEmpty
                    ? "The Mac says it has no direct address"
                    : "The Mac is now at \(direct.compactMap { URL(string: $0).map(Tunnel.place) }.joined(separator: ", "))")
            }
            status = .online(carrier: currentCarrier, machine: ready.machine, harnessUp: ready.dshReachable)
            continuation?.yield(.handshake(confirmation: confirmation ?? "", host: ready.host, direct: ready.direct))
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
        penaliseIfItFlapped()
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

// MARK: - Test seam

extension Tunnel {
    /// Pretend the system reported a network change.
    ///
    /// The real signal comes from `NWPathMonitor`, which cannot be asked to
    /// produce one — and the behaviour worth testing is entirely what happens
    /// *after* the signal: whether the connection moves off the relay, and
    /// whether it declines to try when there is no Wi-Fi to move onto.
    func networkChangedForTesting(onWiFi: Bool) {
        networkChanged(onWiFi: onWiFi)
    }
}
