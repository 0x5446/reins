/// Local notifications for the moments worth interrupting someone over.
///
/// Three, and only three: a tool is asking permission, the agent is asking a
/// question, and a long turn finished. Everything else the agent does is visible
/// when you look, and a notification for each would train people to ignore all of
/// them.
///
/// These are LOCAL notifications, posted by the app while it holds a live tunnel.
/// There is no push service, so there is no third party to tell that your agent
/// wants to run `rm`, and nothing to register a device token with. The cost is
/// that a suspended app posts nothing until iOS next runs it; the benefit is that
/// the design has no server-side knowledge of your machine at all.

import Foundation
import UserNotifications

@MainActor
public final class Notifier {
    /// Suppressed while the app is in front — a banner over the screen already
    /// showing the request is just noise.
    public var foreground = true

    private var lastFinish: [String: Date] = [:]
    private let center: UNUserNotificationCenter?

    public init(center: UNUserNotificationCenter?) {
        self.center = center
    }

    /// The real one. Tests build a `Notifier(center: nil)`, which posts nothing.
    public convenience init() {
        self.init(center: .current())
    }

    /// Ask once, at the moment the first machine pairs — not at launch, where
    /// the question has no context and gets refused.
    public func requestPermission() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func approval(_ request: ApprovalRequest, machine: String, title: String) {
        guard !foreground else { return }
        post(
            id: "approval-\(request.approvalId)",
            title: "\(request.toolName) needs permission",
            body: "\(title) on \(machine)",
            interruption: .timeSensitive
        )
    }

    public func question(_ request: QuestionRequest, machine: String, title: String) {
        guard !foreground else { return }
        post(
            id: "question-\(request.id)",
            title: request.items.first?.question ?? "The agent has a question",
            body: "\(title) on \(machine)",
            interruption: .timeSensitive
        )
    }

    /// A turn ended. Rate-limited per session: an agent that runs a dozen short
    /// turns in a row should buzz once, not a dozen times.
    public func finished(machine: String, title: String) {
        guard !foreground else { return }
        let now = Date()
        if let last = lastFinish[title], now.timeIntervalSince(last) < 60 { return }
        lastFinish[title] = now
        post(id: "done-\(title.hashValue)", title: "Finished", body: "\(title) on \(machine)", interruption: .active)
    }

    private func post(id: String, title: String, body: String, interruption: UNNotificationInterruptionLevel) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruption
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
