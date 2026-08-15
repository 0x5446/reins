/// What the screens render.
///
/// These are the app's own types, not the harness's. The harness vocabulary is
/// open — plugins add event types and tool cards — so the boundary is deliberate:
/// `Conversation` folds whatever arrives into this closed set, and anything it
/// does not recognise becomes a plain notice rather than nothing at all.

import Foundation

/// A machine this device has paired with.
public struct PairedMachine: Codable, Identifiable, Equatable, Sendable {
    /// The Relay device id. Stable for the life of the machine's install.
    public var id: String
    /// Display name, from the machine, editable here.
    public var name: String
    /// Relay base URL.
    public var relay: String
    /// LAN addresses last advertised, best first.
    public var direct: [String]
    /// The machine's raw static public key, base64url.
    public var key: String
    public var addedAt: Date
    /// How the last successful connection got there, for the status line.
    public var lastCarrier: Carrier?

    public init(bundle: PairingBundle, addedAt: Date = Date()) {
        id = bundle.device
        name = bundle.name
        relay = bundle.relay
        direct = bundle.direct ?? []
        key = bundle.key
        self.addedAt = addedAt
    }

    /// A bundle for reconnecting. No token: the pairing already happened, and
    /// this device is recognised by its key from here on.
    public var reconnectBundle: PairingBundle {
        PairingBundle(relay: relay, direct: direct, device: id, key: key, token: "", name: name)
    }

    /// Human-readable identity check, matching what `bridle devices` prints.
    public var fingerprint: String {
        guard let raw = Data(base64url: key) else { return "unknown" }
        return Pairing.keyFingerprint(raw)
    }
}

/// One row in the session list.
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var updatedAt: Date
    public var running: Bool
    /// True until the first prompt: an untouched session nobody has used yet.
    public var blank: Bool
    public var cwd: String?
    public var agentPreset: String?
    public var parentSessionId: String?
    /// Set when this session is a subagent's, which the list hides by default.
    public var isSubagent: Bool

    /// What to show when the session has no title yet.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if blank { return "New conversation" }
        if let cwd { return (cwd as NSString).lastPathComponent }
        return "Untitled"
    }

    /// Parse one `session.list` row.
    public init?(_ value: JSONValue) {
        guard let id = value["sessionId"]?.stringValue else { return nil }
        self.id = id
        updatedAt = Date(timeIntervalSince1970: (value["updatedAt"]?.doubleValue ?? 0) / 1000)
        running = value["running"]?.boolValue ?? false
        blank = value["blank"]?.boolValue ?? false
        cwd = value["cwd"]?.stringValue
        agentPreset = value["agentPreset"]?.stringValue
        parentSessionId = value["parentSessionId"]?.stringValue
        isSubagent = value["origin"]?.stringValue == "subagent"
        title = value.path("projections", "values", "title")?.stringValue
    }
}

/// One rendered item in a conversation, in log order.
public enum ConversationItem: Identifiable, Equatable {
    case user(UserTurn)
    case assistant(AssistantTurn)
    case tool(ToolCard)
    case notice(Notice)

    public var id: String {
        switch self {
        case .user(let item): return item.id
        case .assistant(let item): return item.id
        case .tool(let item): return item.id
        case .notice(let item): return item.id
        }
    }
}

/// Something the person said, or a synthetic message injected on their behalf.
public struct UserTurn: Identifiable, Equatable {
    public var id: String
    public var text: String
    /// Attached images, as data URLs the view can render directly.
    public var images: [ImageAttachment]
    /// True for context the harness injected rather than something typed.
    public var synthetic: Bool
    public var at: Date
}

/// An image carried by a message.
public struct ImageAttachment: Equatable, Identifiable {
    public var id: String
    public var mediaType: String
    /// Base64 payload, when it travelled inline.
    public var base64: String?
}

/// One assistant response, possibly still streaming.
public struct AssistantTurn: Identifiable, Equatable {
    public var id: String
    public var turn: Int
    public var step: Int
    public var text: String
    /// Reasoning content, shown collapsed.
    public var reasoning: String
    /// False while chunks are still arriving.
    public var complete: Bool
    public var at: Date
}

/// How a tool call wants to be drawn. Mirrors the harness's render intent, which
/// the machine computes so the app never has to know what a given tool does.
public enum ToolPresentation: Equatable {
    case generic(title: String, kind: String?, detail: String?)
    case terminal(command: String, cwd: String?, output: String?, exitCode: Int?)
    case diff(title: String, files: [FileDiff])
    case search(title: String, lines: [String], truncated: Bool, total: Int)
    case read(path: String, lines: [NumberedLine], totalLines: Int)
}

/// One file's before and after, for the diff card.
public struct FileDiff: Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var oldText: String?
    public var newText: String
}

/// One line of a read result, keeping the file's own numbering.
public struct NumberedLine: Equatable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var text: String
}

/// A tool call and, once it lands, its result.
public struct ToolCard: Identifiable, Equatable {
    public var id: String
    public var name: String
    /// Raw arguments as the model produced them, for the expanded view.
    public var arguments: String
    public var presentation: ToolPresentation
    /// Model-facing result text, shown when there is no better card.
    public var resultText: String?
    public var failed: Bool
    public var running: Bool
    public var at: Date
    /// When `tool/result` arrived. The events carry no duration field, so this
    /// is the only place a *measured* one comes from — everything else in the
    /// log can only be timed by the gap to whatever happened next.
    public var finishedAt: Date?

    /// How long the tool ran, once it has stopped.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(at) }
    }

    /// A short line for the collapsed row.
    public var headline: String {
        switch presentation {
        case .generic(let title, _, _): return title
        case .terminal(let command, _, _, _): return command
        case .diff(let title, _): return title
        case .search(let title, _, _, _): return title
        case .read(let path, _, _): return (path as NSString).lastPathComponent
        }
    }
}

/// Anything that is neither a message nor a tool: mode changes, compaction,
/// errors, and event types this build has never heard of.
public struct Notice: Identifiable, Equatable {
    public enum Kind: Equatable {
        case info
        case warning
        case failure
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var at: Date
}

/// A tool waiting for the person to allow or refuse it.
public struct ApprovalRequest: Identifiable, Equatable {
    /// The harness rpcId, echoed back with the answer.
    public var id: String
    public var sessionId: String
    public var approvalId: String
    public var toolName: String
    public var reason: String?
    public var at: Date
}

/// A question the agent asked, with its options.
public struct QuestionRequest: Identifiable, Equatable {
    public var id: String
    public var sessionId: String
    public var items: [QuestionItem]
    public var at: Date
}

/// One question inside a batch.
public struct QuestionItem: Identifiable, Equatable {
    public var id: String
    public var question: String
    public var header: String?
    public var detail: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool
    /// The label that approves, when the agent is submitting a plan for review.
    /// Present only for `plan-review`; every other option declines.
    public var approveLabel: String?

    /// Whether this question is a plan waiting for a verdict, which the app
    /// renders as a document with two buttons rather than as a menu.
    public var isPlanReview: Bool { approveLabel != nil }
}

/// One selectable answer.
public struct QuestionOption: Identifiable, Equatable {
    public var id: String { label }
    public var label: String
    public var description: String?
}

/// One item on the agent's checklist.
public struct TodoItem: Identifiable, Equatable {
    public enum Status: String, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String { "\(content)#\(status.rawValue)" }
    public var content: String
    public var status: Status
}

/// A message the person sent that the agent has not claimed yet.
public struct QueuedMessage: Identifiable, Equatable {
    public var id: String
    public var text: String
    /// `queued`, `steering`, or `context`.
    public var placement: String
}

/// One entry in the folder browser used when starting a conversation.
public struct DirectoryEntry: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var hidden: Bool
}

/// A folder listing plus the trail back to the root.
public struct DirectoryListing: Equatable {
    public var path: String
    public var home: String
    public var crumbs: [DirectoryEntry]
    public var entries: [DirectoryEntry]
    public var truncated: Bool
}

/// One model the session can switch to.
public struct ModelOption: Identifiable, Equatable, Codable {
    public var id: String { "\(provider)/\(model)" }
    public var provider: String
    public var providerName: String
    public var model: String
    public var name: String
    public var description: String?
}

/// The models available to a session, and the one in use.
public struct ModelCatalog: Equatable {
    public var current: ModelOption?
    public var options: [ModelOption]
    /// Provider groups that failed to load, so the picker can say why.
    public var failures: [String]
}

/// What the machine says about itself.
public struct MachineDescription: Equatable {
    public var version: String
    public var cwd: String
    public var provider: String?
    public var model: String?
    public var attachedSessions: Int

    public init?(_ value: JSONValue?) {
        guard let value, let version = value["version"]?.stringValue else { return nil }
        self.version = version
        cwd = value["cwd"]?.stringValue ?? "~"
        provider = value["provider"]?.stringValue
        model = value["model"]?.stringValue
        attachedSessions = value["attachedSessions"]?.intValue ?? 0
    }
}

// MARK: - What the session cost

/// Time and shape of the work so far.
///
/// Every field here is already arriving in the `sessionStats` projection, and
/// was being dropped on the floor. On a phone this is the answer to the two
/// questions the transcript cannot answer at a glance — *is it stuck* and *is
/// this getting expensive* — so it costs nothing to keep and reads as the
/// summary line the web UI puts under its composer.
public struct SessionStats: Equatable, Sendable {
    public var turns: Int
    public var steps: Int
    public var llmMs: Int
    public var toolMs: Int
    /// Time to first token, summed over `ttftSteps` steps rather than one.
    public var ttftMs: Int
    public var ttftSteps: Int
    public var decodeMs: Int
    public var decodeTokens: Int

    public init?(_ value: JSONValue?) {
        guard let value, let turns = value["turns"]?.intValue else { return nil }
        self.turns = turns
        steps = value["steps"]?.intValue ?? 0
        llmMs = value["llmMs"]?.intValue ?? 0
        toolMs = value["toolMs"]?.intValue ?? 0
        ttftMs = value["ttftMs"]?.intValue ?? 0
        ttftSteps = value["ttftSteps"]?.intValue ?? 0
        decodeMs = value["decodeMs"]?.intValue ?? 0
        decodeTokens = value["decodeTokens"]?.intValue ?? 0
    }

    /// Mean time to first token, or nil before there is one to average.
    public var averageTtftMs: Int? {
        ttftSteps > 0 ? ttftMs / ttftSteps : nil
    }

    /// Output tokens per second while decoding, or nil before decoding happened.
    public var tokensPerSecond: Double? {
        decodeMs > 0 ? Double(decodeTokens) / (Double(decodeMs) / 1000) : nil
    }
}

/// What has been paid for, in tokens.
public struct TokenUsage: Equatable, Sendable {
    public var uncachedInput: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init?(_ value: JSONValue?) {
        guard let value, value["outputTokens"] != nil || value["uncachedInputTokens"] != nil else { return nil }
        uncachedInput = value["uncachedInputTokens"]?.intValue ?? 0
        output = value["outputTokens"]?.intValue ?? 0
        cacheRead = value["cacheReadTokens"]?.intValue ?? 0
        cacheWrite = value["cacheWriteTokens"]?.intValue ?? 0
    }

    public var totalInput: Int { uncachedInput + cacheRead + cacheWrite }

    /// Share of input served from cache. Nil when nothing went in, rather than
    /// zero — "no requests yet" and "every request missed" are not the same
    /// thing and a 0% that means the first is misleading.
    public var cacheHitRate: Double? {
        totalInput > 0 ? Double(cacheRead) / Double(totalInput) : nil
    }
}

/// Where the context window has gone.
public struct ContextBreakdown: Equatable, Sendable {
    public var system: Int
    public var tools: Int
    public var messages: Int

    public init?(_ value: JSONValue?) {
        guard let value, value["systemTokens"] != nil || value["messageTokens"] != nil else { return nil }
        system = value["systemTokens"]?.intValue ?? 0
        tools = value["toolsTokens"]?.intValue ?? 0
        messages = value["messageTokens"]?.intValue ?? 0
    }

    public var total: Int { system + tools + messages }
}

/// How much the agent is allowed to touch, and what else it could be set to.
///
/// Arrives per session in the `permissions` projection, but it is a *machine*
/// setting — changing it changes it everywhere. The UI has to say so, because
/// "read only" that quietly applied to every other conversation would be a
/// nasty surprise in the other direction too.
public struct PermissionChoice: Equatable, Sendable {
    public struct Option: Identifiable, Equatable, Sendable {
        public var id: String { value }
        public var value: String
        public var name: String
    }

    public var options: [Option]
    public var current: String

    public init?(_ value: JSONValue?) {
        guard let value, let current = value["currentValue"]?.stringValue else { return nil }
        self.current = current
        options = (value["options"]?.arrayValue ?? []).compactMap { entry in
            guard let raw = entry["value"]?.stringValue else { return nil }
            return Option(value: raw, name: entry["name"]?.stringValue ?? raw)
        }
    }

    /// The label to show for a raw value. The machine sends the raw string as
    /// the name too, so this is where `danger-full-access` becomes something
    /// worth reading on a phone.
    public static func label(for value: String) -> String {
        switch value {
        case "read-only": return "Read only"
        case "workspace-write": return "Workspace write"
        case "danger-full-access": return "Full access"
        default: return value
        }
    }

    /// What the choice actually permits, in one line.
    public static func detail(for value: String) -> String {
        switch value {
        case "read-only": return "Look, don’t touch. Every write asks first."
        case "workspace-write": return "Edit inside the working folder without asking. Anything outside it still asks."
        case "danger-full-access": return "No sandbox and no questions. Everything your account can do, it can do."
        default: return ""
        }
    }
}
