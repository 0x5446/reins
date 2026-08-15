/// Typed calls into the harness.
///
/// A thin layer over `Tunnel.call`, and deliberately thin: the harness's own
/// contract is JSON, its vocabulary grows with whatever plugins a person has
/// mounted, and a Swift mirror of every payload would be stale the first time
/// someone installs one. What is worth typing is the two dozen methods this app
/// actually invokes, so a typo becomes a compile error instead of a runtime
/// `method-not-found`.

import Foundation

public struct Harness: Sendable {
    public let tunnel: Tunnel

    public init(tunnel: Tunnel) {
        self.tunnel = tunnel
    }

    // MARK: - Machine

    /// Version, working directory, and current model of the machine.
    public func describe() async throws -> JSONValue {
        try await tunnel.call("host.describe")
    }

    /// Browse the machine's filesystem for a folder to start a conversation in.
    public func listDirectory(path: String?) async throws -> DirectoryListing {
        let value = try await tunnel.call("host.listDirectory", .object(dropping: ["path": path.map(JSONValue.string)]))
        return DirectoryListing(
            path: value["path"]?.stringValue ?? "/",
            home: value["home"]?.stringValue ?? "/",
            crumbs: Harness.entries(value["crumbs"]),
            entries: Harness.entries(value["entries"]),
            truncated: value["truncated"]?.boolValue ?? false
        )
    }

    private static func entries(_ value: JSONValue?) -> [DirectoryEntry] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let path = entry["path"]?.stringValue else { return nil }
            return DirectoryEntry(
                name: entry["name"]?.stringValue ?? (path as NSString).lastPathComponent,
                path: path,
                hidden: entry["hidden"]?.boolValue ?? false
            )
        }
    }

    // MARK: - Sessions

    /// Every persisted conversation, newest first.
    public func listSessions() async throws -> [SessionSummary] {
        let value = try await tunnel.call("session.list")
        return (value["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
    }

    /// One page of a session's event log. Omit `beforeSeq` for the tail.
    public func history(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int? = nil) async throws -> JSONValue {
        try await tunnel.call("session.history", .object(dropping: [
            "sessionId": .string(sessionId),
            "beforeSeq": beforeSeq.map { JSONValue.number(Double($0)) },
            "maxMessages": maxMessages.map { JSONValue.number(Double($0)) },
        ]))
    }

    /// Start a conversation in a folder.
    public func createSession(cwd: String?, agentPreset: String? = nil) async throws -> String {
        let value = try await tunnel.call("session.create", .object(dropping: [
            "cwd": cwd.map(JSONValue.string),
            "agentPreset": agentPreset.map(JSONValue.string),
        ]))
        guard let id = value["sessionId"]?.stringValue else {
            throw CallError(code: "internal", message: "The Mac created a conversation but didn’t say which.")
        }
        return id
    }

    /// Send a message.
    ///
    /// `steer` interrupts the running turn with the new instruction; `queue`
    /// waits for the current one to finish. The app picks `steer` when a turn is
    /// running because that is what a person tapping send mid-answer means.
    public func prompt(sessionId: String, text: String, images: [PromptImage] = [], steer: Bool) async throws {
        var content: [JSONValue] = []
        if !text.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for image in images {
            content.append(.object(dropping: [
                "type": .string("image"),
                "mediaType": .string(image.mediaType),
                "data": .string(image.base64),
                "name": image.name.map(JSONValue.string),
            ]))
        }
        try await tunnel.call("session.prompt", .object([
            "sessionId": .string(sessionId),
            "mode": .string(steer ? "steer" : "queue"),
            "content": .array(content),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ]))
    }

    /// Stop the running turn.
    public func cancel(sessionId: String) async throws {
        try await tunnel.call("session.cancel", .object(["sessionId": .string(sessionId)]))
    }

    /// Change how much the agent is allowed to touch.
    ///
    /// Two calls, because the machine uses optimistic concurrency: read the
    /// namespace's revision, then send the patch against it. Passing a stale
    /// revision is refused rather than silently overwriting whoever changed it
    /// in between — which on this machine is most likely the person sitting at
    /// it, and losing their change would be the worse outcome.
    ///
    /// This is a machine-wide setting. `permission` is one namespace and it has
    /// one value; there is no per-session variant to reach for.
    public func setPermission(_ preset: String) async throws {
        let described = try await tunnel.call("settings.describe")
        let revision = (described["namespaces"]?.arrayValue ?? [])
            .first { $0["ns"]?.stringValue == "permission" }?["revision"]?.intValue
        var payload: [String: JSONValue] = [
            "ns": .string("permission"),
            "patch": .object(["defaultPreset": .string(preset)]),
        ]
        if let revision { payload["expectedRevision"] = .number(Double(revision)) }
        try await tunnel.call("settings.update", .object(payload))
    }

    /// Set a session's title by hand.
    public func rename(sessionId: String, title: String) async throws {
        try await tunnel.call("session.rename", .object([
            "sessionId": .string(sessionId),
            "title": .string(title),
        ]))
    }

    /// Search the message surface across conversations.
    ///
    /// The machine answers with ids and excerpts, not summaries — titles and
    /// timestamps stay owned by `session.list` — so the caller joins the hits
    /// against the list it already holds.
    public func search(query: String) async throws -> (hits: [SearchHit], hasMore: Bool) {
        let value = try await tunnel.call("session.search", .object(["query": .string(query)]))
        let hits = (value["items"]?.arrayValue ?? []).compactMap { item -> SearchHit? in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            return SearchHit(id: id, snippet: item["snippet"]?.stringValue ?? "")
        }
        return (hits, value["hasMore"]?.boolValue ?? false)
    }

    /// Remove or promote one queued message.
    public func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
        var payload: JSONValue = .object(["kind": .string(action.kind)])
        if case .edit(let text) = action {
            payload = .object([
                "kind": .string("edit"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])
        }
        try await tunnel.call("session.updateQueue", .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
            "action": payload,
        ]))
    }

    /// Fetch one image referenced by a message, as base64.
    public func attachment(sessionId: String, attachmentId: String) async throws -> (mediaType: String, base64: String) {
        let value = try await tunnel.call("session.attachment", .object([
            "sessionId": .string(sessionId),
            "attachmentId": .string(attachmentId),
        ]))
        return (
            value.path("attachment", "mediaType")?.stringValue ?? "image/png",
            value["data"]?.stringValue ?? ""
        )
    }

    /// The slash commands available in a session.
    ///
    /// Per session rather than per machine: skills can be scoped, and asking
    /// the machine in general would offer names that turn out not to work here.
    public func skills(sessionId: String) async throws -> [SkillCommand] {
        let value = try await tunnel.call("skill.list", .object(["sessionId": .string(sessionId)]))
        return (value["skills"]?.arrayValue ?? []).compactMap(SkillCommand.init)
    }

    // MARK: - Models

    /// The models this session can switch to.
    public func models(sessionId: String) async throws -> ModelCatalog {
        Harness.catalog(try await tunnel.call("session.models", .object(["sessionId": .string(sessionId)])))
    }

    /// Every model the machine can route to, independent of any session.
    ///
    /// `session.models` needs a session to ask about, which is the wrong shape
    /// for choosing what a session that does not exist yet should start on.
    public func machineModels() async throws -> ModelCatalog {
        Harness.catalog(try await tunnel.call("llm.models", .emptyObject))
    }

    /// Both calls answer with the same `groups → models` shape.
    static func catalog(_ value: JSONValue) -> ModelCatalog {
        var options: [ModelOption] = []
        for group in value["groups"]?.arrayValue ?? [] {
            let provider = group["id"]?.stringValue ?? ""
            let providerName = group["name"]?.stringValue ?? provider
            for model in group["models"]?.arrayValue ?? [] {
                guard let id = model["id"]?.stringValue else { continue }
                options.append(ModelOption(
                    provider: provider,
                    providerName: providerName,
                    model: id,
                    name: model["name"]?.stringValue ?? id,
                    description: model["description"]?.stringValue
                ))
            }
        }
        let currentProvider = value.path("current", "provider")?.stringValue
        let currentModel = value.path("current", "model")?.stringValue
        let current = options.first { $0.provider == currentProvider && $0.model == currentModel }
            ?? currentModel.map {
                ModelOption(
                    provider: currentProvider ?? "",
                    providerName: currentProvider ?? "",
                    model: $0,
                    name: $0,
                    description: nil
                )
            }
        let failures = (value["failures"]?.arrayValue ?? []).map { failure in
            let name = failure["name"]?.stringValue ?? failure["id"]?.stringValue ?? "a provider"
            return "\(name): \(failure["message"]?.stringValue ?? "could not be reached")"
        }
        return ModelCatalog(current: current, options: options, failures: failures)
    }

    /// Switch this session's model.
    public func selectModel(sessionId: String, option: ModelOption, reasoningEffort: String? = nil) async throws {
        try await tunnel.call("session.selectModel", .object(dropping: [
            "sessionId": .string(sessionId),
            "provider": .string(option.provider),
            "model": .string(option.model),
            "reasoningEffort": reasoningEffort.map(JSONValue.string),
        ]))
    }

    // MARK: - Answering the agent

    /// Allow or refuse one tool call.
    public func answerApproval(_ request: ApprovalRequest, allow: Bool) async throws {
        try await tunnel.respond(rpcId: request.id, value: .object([
            "sessionId": .string(request.sessionId),
            "approvalId": .string(request.approvalId),
            "outcome": .string(allow ? "allowed-once" : "rejected"),
        ]))
    }

    /// Answer one batch of questions.
    public func answerQuestion(_ request: QuestionRequest, answers: [String: QuestionAnswer]) async throws {
        let payload = request.items.map { item -> JSONValue in
            let answer = answers[item.id]
            return .object(dropping: [
                "id": .string(item.id),
                "selected": .array((answer?.selected ?? []).map(JSONValue.string)),
                "custom": answer?.custom.map(JSONValue.string),
            ])
        }
        try await tunnel.respond(rpcId: request.id, value: .object([
            "sessionId": .string(request.sessionId),
            "answer": .object(["answers": .array(payload)]),
        ]))
    }
}

/// What to do with a message the agent has not claimed yet.
public enum QueueAction: Equatable, Sendable {
    case edit(String)
    case remove
    case steer

    var kind: String {
        switch self {
        case .edit: return "edit"
        case .remove: return "remove"
        case .steer: return "steer"
        }
    }
}

/// One conversation the search matched, and where.
public struct SearchHit: Identifiable, Equatable, Sendable {
    public var id: String
    public var snippet: String
}

/// An image being sent with a prompt.
public struct PromptImage: Sendable, Equatable {
    public var mediaType: String
    public var base64: String
    public var name: String?

    public init(mediaType: String, base64: String, name: String?) {
        self.mediaType = mediaType
        self.base64 = base64
        self.name = name
    }
}

/// What the person picked for one question.
public struct QuestionAnswer: Equatable {
    public var selected: [String]
    public var custom: String?

    public init(selected: [String] = [], custom: String? = nil) {
        self.selected = selected
        self.custom = custom
    }
}
