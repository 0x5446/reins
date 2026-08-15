/// Everything the app knows about one connected machine.
///
/// One of these per paired Mac. It owns the tunnel, consumes its signal stream,
/// and keeps the session list and the open conversations in step with what the
/// machine says. The views read it and never touch the tunnel directly.
///
/// The refresh policy is the interesting part. A phone loses its connection
/// constantly — the radio sleeps, the network changes, the app is suspended — so
/// "reconnected" cannot mean "start over". The Bridle replays the gap by
/// sequence number, which covers almost every drop; only when the replay buffer
/// has overflowed (`resync`) does this refetch, and then it refetches exactly
/// what is on screen rather than everything.

import Foundation
import Observation

/// Messages per history page.
///
/// dsh defaults to 50, and a page is bounded by messages but carries the whole
/// raw event range they span — which for a streaming-heavy session means tens of
/// thousands of `assistant/chunk` events. The Bridle strips the superseded ones,
/// so 50 would be affordable against a current Bridle; this stays lower anyway,
/// because the app has to survive talking to a Bridle that has not been updated
/// yet, and because 25 messages already overfills a phone screen several times.
private let historyPageSize = 25

@MainActor
@Observable
public final class MachineSession {
    public let machine: PairedMachine
    public let tunnel: Tunnel
    public let harness: Harness

    public private(set) var status: TunnelStatus = .idle
    /// Every conversation on the machine, newest first, subagents excluded.
    public private(set) var sessions: [SessionSummary] = []
    /// The machine's sidebar groups, empty when it has none or cannot say.
    ///
    /// Empty is not an error state and is never treated as one — see
    /// `refreshWorkspaces` — because the list screen has to work identically on
    /// a machine that has never made a workspace and on one whose dsh is too
    /// old to have the call.
    public private(set) var workspaces: [Workspace] = []
    /// Which of those groups are folded shut, remembered between launches.
    public let folds: GroupFolds
    /// What the machine says about itself.
    public private(set) var machineInfo: MachineDescription?
    /// Set when the harness itself is down even though the tunnel is up. The
    /// distinction matters: one is "your Mac is asleep", the other is "dsh isn't
    /// running", and they need different words and different fixes.
    public private(set) var harnessDetail: String?
    /// The six-digit number to compare with the Mac, for a typed-code pairing.
    public private(set) var confirmation: String?
    /// Tools waiting on a decision, by session.
    public private(set) var approvals: [String: ApprovalRequest] = [:]
    /// Questions waiting on an answer, by session.
    public private(set) var questions: [String: QuestionRequest] = [:]
    /// The last thing that went wrong, for a transient banner.
    public var problem: String?
    /// True while the session list is being fetched.
    public private(set) var listing = false
    /// True while the workspace list is being fetched.
    private var listingWorkspaces = false
    /// Set when a host frame arrived while that fetch was in flight.
    private var workspacesStale = false

    /// What a new conversation starts on, when the person has stated one.
    ///
    /// dsh has no such setting of its own — it routes a fresh session to
    /// whichever provider happens to be first, which on a machine with more
    /// than one configured is a coin toss, and on a machine whose first
    /// provider has no API key is simply broken. Stating it once here is the
    /// difference between "new conversation" working and needing two taps of
    /// repair every time.
    public private(set) var defaultModel: ModelOption?

    private var conversations: [String: Conversation] = [:]
    private var pump: Task<Void, Never>?
    private let notifier: Notifier
    private let defaults: UserDefaults

    public init(machine: PairedMachine, identity: StaticKeyPair, deviceName: String, clientVersion: String, pairingToken: String?, notifier: Notifier, defaults: UserDefaults = .standard) {
        self.machine = machine
        self.notifier = notifier
        self.defaults = defaults
        folds = GroupFolds(machineId: machine.id, defaults: defaults)
        if let data = defaults.data(forKey: MachineSession.defaultModelKey(machine.id)) {
            defaultModel = try? JSONDecoder().decode(ModelOption.self, from: data)
        }
        tunnel = Tunnel(
            bundle: machine.reconnectBundle,
            identity: identity,
            deviceName: deviceName,
            clientVersion: clientVersion,
            pairingToken: pairingToken
        )
        harness = Harness(tunnel: tunnel)
    }

    // MARK: - Lifecycle

    public func start() {
        guard pump == nil else { return }
        pump = Task { [tunnel] in
            let stream = await tunnel.signals()
            await tunnel.start()
            for await signal in stream {
                if Task.isCancelled { return }
                self.receive(signal)
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        Task { [tunnel] in await tunnel.stop() }
    }

    /// Reconnect now rather than waiting out the backoff.
    public func poke() {
        Task { [tunnel] in await tunnel.poke() }
    }

    /// Change what this device is called on the machine's paired list.
    public func rename(device name: String) {
        Task { [tunnel] in await tunnel.rename(to: name) }
    }

    public var isOnline: Bool {
        if case .online = status { return true }
        return false
    }

    public var harnessReachable: Bool {
        if case .online(_, _, let up) = status { return up }
        return false
    }

    public var carrier: Carrier? {
        if case .online(let carrier, _, _) = status { return carrier }
        return nil
    }

    // MARK: - Signals

    private func receive(_ signal: TunnelSignal) {
        switch signal {
        case .status(let value):
            let wasOnline = isOnline
            status = value
            if case .online = value, !wasOnline {
                Task { await self.refreshSessions() }
            }
        case .event(let frame):
            switch frame.stream {
            case .mux: handleMux(frame.frame)
            case .host: handleHost(frame.frame)
            }
        case .resync(let from):
            // The gap was too big to replay. Everything on screen is now
            // suspect, so refetch it — and only it.
            _ = from
            Task {
                await self.refreshSessions()
                for conversation in self.conversations.values {
                    await self.loadHistory(conversation, reset: true)
                }
            }
        case .harness(let reachable, let detail):
            harnessDetail = reachable ? nil : (detail ?? "dsh isn’t running on that Mac.")
        case .handshake(let number, let host):
            confirmation = number.isEmpty ? nil : number
            if let host, let described = MachineDescription(host) {
                machineInfo = described
            }
        }
    }

    private func handleMux(_ frame: JSONValue) {
        // The Bridle forwards the harness's `server-request` envelope verbatim,
        // because the rpcId inside it is what an answer has to echo.
        let rpcId = frame["rpcId"]?.stringValue ?? ""
        let payload = frame["payload"] ?? frame
        guard let type = payload["type"]?.stringValue else { return }
        let sessionId = payload["sessionId"]?.stringValue ?? ""
        switch type {
        case "session/event":
            guard let event = payload["event"] else { return }
            let conversation = existing(sessionId)
            conversation?.apply(event: event, view: payload["view"])
            touch(sessionId, event: event)
        case "approval/requested":
            let request = ApprovalRequest(
                id: rpcId,
                sessionId: sessionId,
                approvalId: payload["approvalId"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "a tool",
                reason: payload["reason"]?.stringValue,
                at: Date()
            )
            approvals[sessionId] = request
            notifier.approval(request, machine: machine.name, title: title(of: sessionId))
        case "approval/resolved":
            approvals[sessionId] = nil
        case "question/requested":
            let items = (payload["questions"]?.arrayValue ?? []).compactMap(MachineSession.question)
            guard !items.isEmpty else { return }
            let request = QuestionRequest(id: rpcId, sessionId: sessionId, items: items, at: Date())
            questions[sessionId] = request
            notifier.question(request, machine: machine.name, title: title(of: sessionId))
        case "question/resolved":
            questions[sessionId] = nil
        case "session/queue":
            existing(sessionId)?.applyQueue(payload["items"]?.arrayValue ?? [])
        case "session/projection":
            guard let key = payload["key"]?.stringValue else { return }
            let value = payload["value"] ?? .null
            let seq = payload["seq"]?.intValue ?? 0
            existing(sessionId)?.applyProjection(key: key, value: value, seq: seq)
            if key == "title", let title = value.stringValue {
                update(sessionId) { $0.title = title }
            }
        case "stream/error":
            problem = payload.path("error", "message")?.stringValue
        default:
            // `session/subscribed`, `session/jobs`, and anything a plugin adds.
            break
        }
    }

    private func handleHost(_ frame: JSONValue) {
        let payload = frame["payload"] ?? frame
        guard let type = payload["type"]?.stringValue else { return }
        let sessionId = payload["sessionId"]?.stringValue ?? ""
        switch type {
        case "host/session-added":
            guard !sessions.contains(where: { $0.id == sessionId }) else { return }
            guard var summary = SessionSummary(payload) else { return }
            summary.updatedAt = Date()
            guard !summary.isSubagent else { return }
            sessions.insert(summary, at: 0)
        case "host/session-removed":
            sessions.removeAll { $0.id == sessionId }
            conversations[sessionId] = nil
            approvals[sessionId] = nil
            questions[sessionId] = nil
        case "host/session-status":
            let running = payload["running"]?.boolValue ?? false
            update(sessionId) {
                $0.running = running
                // The added frame fires at creation, so `blank` is always true
                // there; a session that has started running has been used.
                if running { $0.blank = false }
            }
            existing(sessionId)?.setRunning(running)
            if !running { notifier.finished(machine: machine.name, title: title(of: sessionId)) }
        case "host/agent-error":
            let message = payload["message"]?.stringValue ?? "The agent failed."
            existing(sessionId)?.note(message, kind: .failure)
            if conversations[sessionId] == nil { problem = message }
        case "host/workspace-changed":
            // The frame says a workspace moved, not what it now holds, and
            // membership is the only part of it this app draws. Re-reading the
            // whole list is three items on the wire and cannot drift; patching
            // from a payload whose shape is not pinned down anywhere could.
            Task { await self.refreshWorkspaces() }
        case "host/workspace-removed":
            // Locally first so the section goes on the same frame, then a
            // re-read, because the local half depends on guessing the id field
            // right and the re-read does not.
            if let removed = payload["workspaceId"]?.stringValue {
                workspaces.removeAll { $0.id == removed }
            }
            Task { await self.refreshWorkspaces() }
        case "host/workspace-order-changed":
            // Nothing, on purpose. The sidebar order is a filing decision made
            // at the keyboard; this app sorts its sections by what was touched
            // most recently instead, so there is nothing here to apply.
            break
        case "stream/error":
            problem = payload.path("error", "message")?.stringValue
        default:
            break
        }
    }

    /// Note that a session produced an event, so the list can reorder without
    /// waiting for a refresh.
    private func touch(_ sessionId: String, event: JSONValue) {
        guard event["type"]?.stringValue == "user/message" else { return }
        update(sessionId) {
            $0.updatedAt = Date()
            $0.blank = false
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }), index > 0 else { return }
        let moved = sessions.remove(at: index)
        sessions.insert(moved, at: 0)
    }

    private func update(_ sessionId: String, _ change: (inout SessionSummary) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        change(&sessions[index])
    }

    private func title(of sessionId: String) -> String {
        sessions.first { $0.id == sessionId }?.displayTitle ?? "a conversation"
    }

    private static func question(_ item: JSONValue) -> QuestionItem? {
        guard let id = item["id"]?.stringValue, let question = item["question"]?.stringValue else { return nil }
        let options = (item["options"]?.arrayValue ?? []).compactMap { option -> QuestionOption? in
            guard let label = option["label"]?.stringValue else { return nil }
            return QuestionOption(label: label, description: option["description"]?.stringValue)
        }
        let intent = item["intent"]
        return QuestionItem(
            id: id,
            question: question,
            header: item["header"]?.stringValue,
            detail: item["detail"]?.stringValue,
            options: options,
            multiSelect: item["multiSelect"]?.boolValue ?? false,
            approveLabel: intent?["kind"]?.stringValue == "plan-review" ? intent?["approve"]?.stringValue : nil
        )
    }

    // MARK: - Reads

    /// The conversation for a session, creating and loading it on first ask.
    public func conversation(_ sessionId: String) -> Conversation {
        if let held = conversations[sessionId] { return held }
        let summary = sessions.first { $0.id == sessionId }
        let fresh = Conversation(sessionId: sessionId, title: summary?.title, cwd: summary?.cwd)
        conversations[sessionId] = fresh
        Task { await loadHistory(fresh, reset: false) }
        // Independently of the history: the machine knows which model this
        // session is on before it has ever run one, and a wrong model is worth
        // seeing before spending a turn on it rather than after.
        Task { await loadModel(fresh) }
        // Once, on open. Discovery is the whole point of this list — the
        // commands work today by typing their names — so a failure here is a
        // missing convenience, not a broken session, and is swallowed.
        Task { await loadCommands(fresh) }
        // Once on open, so the menu can say whether there is anything to look
        // at without making someone tap to find out there is not.
        Task { await loadSubagents(fresh) }
        return fresh
    }

    /// Fetch the children of a conversation.
    ///
    /// Called when the sheet opens rather than on a timer: a child list is only
    /// looked at deliberately, and polling it would spend a round trip per
    /// conversation on something usually empty.
    public func loadSubagents(_ conversation: Conversation) async {
        guard let found = try? await harness.subagents(parentSessionId: conversation.sessionId) else { return }
        conversation.subagents = found.children
        conversation.subagentsKnown = found.available
    }

    private func loadCommands(_ conversation: Conversation) async {
        guard let found = try? await harness.skills(sessionId: conversation.sessionId) else { return }
        conversation.commands = found
    }

    private func existing(_ sessionId: String) -> Conversation? {
        conversations[sessionId]
    }

    /// Fetch the session list.
    public func refreshSessions() async {
        guard !listing else { return }
        listing = true
        defer { listing = false }
        // Alongside the session list rather than after it. Two round trips on
        // one tunnel cost about what one does, and the alternative is a list
        // that draws flat and then rearranges itself into sections a beat
        // later, which on the home screen reads as a glitch.
        async let grouping: Void = refreshWorkspaces()
        do {
            let items = try await harness.listSessions()
            sessions = items.filter { !$0.isSubagent }.sorted { $0.updatedAt > $1.updatedAt }
            if machineInfo == nil, let described = try? await harness.describe() {
                machineInfo = MachineDescription(described)
            }
        } catch let error as CallError where error.code == "disconnected" {
            // The reconnect will refresh again. Saying so would be noise.
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not read the conversation list."
        }
        await grouping
    }

    /// Fetch the sidebar groups. Best effort, always.
    ///
    /// Three ways this can fail and none of them is worth a word on screen: dsh
    /// predates `workspace.list` and answers `method-not-found`, the tunnel
    /// dropped between the two calls, or the machine simply has no workspaces.
    /// All three mean the same thing to the person holding the phone — there is
    /// nothing to group by — and the list falls back to the flat one it has
    /// always drawn. A banner here would report a missing convenience as a
    /// broken conversation list.
    ///
    /// A failure keeps whatever was last known rather than clearing it, so one
    /// dropped call on a machine that *does* group cannot flatten the screen
    /// and un-flatten it a second later.
    public func refreshWorkspaces() async {
        guard !listingWorkspaces else {
            // A frame that lands mid-fetch describes a state the in-flight call
            // may have been too early to see, so it books another round rather
            // than being dropped. Dragging a conversation between workspaces on
            // the Mac emits a burst of these; this collapses the burst into two
            // calls instead of one per frame — and, unlike a plain guard, not
            // into one that settles on the state from before the drag.
            workspacesStale = true
            return
        }
        listingWorkspaces = true
        defer { listingWorkspaces = false }
        repeat {
            workspacesStale = false
            guard let items = try? await harness.listWorkspaces() else { return }
            workspaces = items
        } while workspacesStale
    }

    /// Load a conversation's tail page, or reload it after a resync.
    public func loadHistory(_ conversation: Conversation, reset: Bool) async {
        if reset { conversation.reset() }
        conversation.loading = true
        defer { conversation.loading = false }
        do {
            let page = try await harness.history(sessionId: conversation.sessionId, maxMessages: historyPageSize)
            conversation.absorb(page: page, prepend: false)
        } catch let error as CallError where error.code == "disconnected" {
            // Same reasoning as the list: the reconnect retries.
        } catch {
            conversation.note((error as? LocalizedError)?.errorDescription ?? "Could not load this conversation.", kind: .failure)
        }
    }

    /// Ask which model this session is on.
    ///
    /// Failure is silent. The header falls back to offering the picker, which is
    /// the same thing this call would have enabled.
    private func loadModel(_ conversation: Conversation) async {
        guard let catalog = try? await harness.models(sessionId: conversation.sessionId) else { return }
        conversation.setModel(catalog.current?.name)
    }

    /// Load the page before what is held.
    public func loadOlder(_ conversation: Conversation) async {
        guard conversation.hasMore, let before = conversation.oldestSeq, !conversation.loading else { return }
        conversation.loading = true
        defer { conversation.loading = false }
        do {
            let page = try await harness.history(sessionId: conversation.sessionId, beforeSeq: before, maxMessages: historyPageSize)
            conversation.absorb(page: page, prepend: true)
        } catch {
            // Scrolling back is optional. A failure leaves what is on screen
            // intact and the person can pull again.
        }
    }

    // MARK: - Writes

    /// Send a message, showing it immediately.
    public func send(sessionId: String, text: String, images: [PromptImage] = []) async {
        let conversation = conversation(sessionId)
        let pendingId = "pending-\(UUID().uuidString)"
        let steer = conversation.running
        conversation.showPending(text: text, id: pendingId)
        do {
            try await harness.prompt(sessionId: sessionId, text: text, images: images, steer: steer)
        } catch {
            conversation.dropPending(id: pendingId)
            problem = (error as? LocalizedError)?.errorDescription ?? "That message didn’t send."
        }
    }

    public func cancel(sessionId: String) async {
        do { try await harness.cancel(sessionId: sessionId) } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not stop the agent."
        }
    }

    /// Change how much the agent may touch, machine-wide.
    ///
    /// Returns the failure to show inline rather than setting `problem`: this is
    /// a choice made inside one sheet, and a banner over the whole app would put
    /// the message somewhere other than the control that produced it. Nothing is
    /// applied locally on success — the machine answers with a `permissions`
    /// projection, and letting that be the only source of truth means the
    /// checkmark cannot disagree with the machine.
    ///
    /// - Returns: nil on success, otherwise what to tell the person.
    public func setPermission(_ preset: String) async -> String? {
        do {
            try await harness.setPermission(preset)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "The Mac would not change the access mode."
        }
    }

    /// Start a conversation and return its id.
    /// Choose what new conversations start on. `nil` hands the choice back to
    /// the machine.
    public func setDefaultModel(_ option: ModelOption?) {
        defaultModel = option
        let key = MachineSession.defaultModelKey(machine.id)
        if let option, let data = try? JSONEncoder().encode(option) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Scoped per machine: two Macs rarely have the same providers configured,
    /// and a model id from one is meaningless on the other.
    private static func defaultModelKey(_ machineId: String) -> String {
        "reins.defaultModel.\(machineId)"
    }

    public func createSession(cwd: String?) async -> String? {
        do {
            let id = try await harness.createSession(cwd: cwd)
            if let defaultModel {
                // Best effort. A model that has since been removed from the
                // machine should not stop the conversation from opening; the
                // header states what it actually landed on either way.
                try? await harness.selectModel(sessionId: id, option: defaultModel)
            }
            var summary = SessionSummary(.object([
                "sessionId": .string(id),
                "updatedAt": .number(Date().timeIntervalSince1970 * 1000),
                "running": .bool(false),
                "blank": .bool(true),
            ]))
            summary?.cwd = cwd
            if let summary, !sessions.contains(where: { $0.id == id }) {
                sessions.insert(summary, at: 0)
            }
            return id
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not start a conversation."
            return nil
        }
    }

    /// Branch a conversation and return the new one's id.
    ///
    /// The machine keeps the history up to the branch point, so this is the
    /// "try it the other way without losing this" move — which is worth more on
    /// a phone than at a keyboard, where re-running something is cheap.
    public func fork(sessionId: String) async -> String? {
        do {
            let id = try await harness.fork(sessionId: sessionId)
            await refreshSessions()
            return id
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not branch the conversation."
            return nil
        }
    }

    /// Take a conversation out of the list.
    ///
    /// Removed locally before the machine confirms, because the list is the
    /// screen the person is looking at and a row that lingers for a round trip
    /// reads as a failed tap. `refreshSessions` puts it back if the Mac refused.
    public func archive(sessionId: String) async {
        let held = sessions
        sessions.removeAll { $0.id == sessionId }
        do {
            try await harness.archive(sessionId: sessionId)
        } catch {
            sessions = held
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not archive the conversation."
        }
    }

    public func rename(sessionId: String, title: String) async {
        do {
            try await harness.rename(sessionId: sessionId, title: title)
            update(sessionId) { $0.title = title }
            existing(sessionId)?.applyProjection(key: "title", value: .string(title), seq: Int.max)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not rename that conversation."
        }
    }

    public func answer(approval: ApprovalRequest, allow: Bool) async {
        // Clear first. The machine confirms with `approval/resolved`, but the
        // button must stop looking pressable the instant it is tapped.
        approvals[approval.sessionId] = nil
        do {
            try await harness.answerApproval(approval, allow: allow)
        } catch {
            approvals[approval.sessionId] = approval
            problem = (error as? LocalizedError)?.errorDescription ?? "That answer didn’t reach the Mac."
        }
    }

    public func answer(question: QuestionRequest, answers: [String: QuestionAnswer]) async {
        questions[question.sessionId] = nil
        do {
            try await harness.answerQuestion(question, answers: answers)
        } catch {
            questions[question.sessionId] = question
            problem = (error as? LocalizedError)?.errorDescription ?? "That answer didn’t reach the Mac."
        }
    }
}

/// Which sections of the conversation list are folded shut.
///
/// Remembered, because a fold that resets every launch is not a fold — someone
/// who collapsed the workspace holding 40 finished conversations did so to stop
/// scrolling past them, and doing it again tomorrow morning is the app failing
/// to listen.
///
/// Three states per section, not two. "Never said" has to be distinguishable
/// from "said open", or the default — open the most recent one — would silently
/// re-close a section the person deliberately opened as soon as something else
/// became more recent.
///
/// Kept out of `MachineSession` so it can be tested without a tunnel, and given
/// its own `UserDefaults` so a test can hand it a throwaway suite.
@MainActor
@Observable
public final class GroupFolds {
    private let machineId: String
    private let defaults: UserDefaults
    private var remembered: [String: Bool]

    public init(machineId: String, defaults: UserDefaults = .standard) {
        self.machineId = machineId
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: GroupFolds.key(machineId)) ?? [:]
        remembered = stored.compactMapValues { $0 as? Bool }
    }

    /// Whether a section is open, falling back to the arrangement's suggestion
    /// when nobody has expressed a view.
    public func isOpen(_ groupId: String, unlessRemembered fallback: Bool) -> Bool {
        remembered[groupId] ?? fallback
    }

    public func set(_ groupId: String, open: Bool) {
        remembered[groupId] = open
        defaults.set(remembered, forKey: GroupFolds.key(machineId))
    }

    /// Scoped per machine: workspace ids are the machine's, and two Macs paired
    /// with the same phone share nothing but the phone.
    ///
    /// One key holding a dictionary rather than a key per workspace, so that
    /// removing a machine's memory is one call and so that a workspace deleted
    /// on the Mac leaves one dead entry rather than one dead default.
    private static func key(_ machineId: String) -> String {
        "reins.groupFolds.\(machineId)"
    }
}
