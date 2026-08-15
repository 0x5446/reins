/// What this conversation has cost, and what the agent is allowed to do.
///
/// Every number here was already arriving in the projections the app folds; it
/// was being thrown away. That matters for what this screen is allowed to be:
/// nothing on it costs a request, so it can be opened at any time, including
/// while the machine is unreachable, and it will show the last thing it knew
/// rather than a spinner.
///
/// It answers the two questions the transcript cannot. *Is it stuck* — turns,
/// steps, and time to first token say more than a scroll position. *Is this
/// getting expensive* — the context bar and the token counts.
///
/// The access mode lives here too, and it is the one control on the screen. It
/// is deliberately last and deliberately loud: it is a **machine-wide** setting
/// wearing a per-conversation badge, and someone who sets "read only" here to
/// calm down one runaway session would otherwise be surprised by every other
/// conversation later.

import SwiftUI

struct SessionInfoView: View {
    @Environment(MachineSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    @State private var changingAccess = false
    @State private var accessError: String?

    // `conversation(_:)` rather than a dictionary read: the sheet can be
    // opened on a session whose history has not been fetched, and this is
    // the accessor that starts that fetch.
    private var conversation: Conversation? { session.conversation(sessionId) }

    var body: some View {
        NavigationStack {
            List {
                context
                work
                spend
                access
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Context

    @ViewBuilder
    private var context: some View {
        if let fraction = conversation?.contextFraction {
            Section {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Int((fraction * 100).rounded()))% full")
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        if let used = conversation?.contextTokens, let window = conversation?.contextWindow {
                            Text("\(Format.tokens(used)) / \(Format.tokens(window))")
                                .font(.code(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    ContextBar(fraction: fraction, breakdown: conversation?.contextBreakdown)
                    if let parts = conversation?.contextBreakdown, parts.total > 0 {
                        HStack(spacing: Metrics.gap) {
                            Legend(color: Palette.accent.opacity(0.35), label: "System", value: parts.system)
                            Legend(color: Palette.accent.opacity(0.6), label: "Tools", value: parts.tools)
                            Legend(color: Palette.accent, label: "Messages", value: parts.messages)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Context")
            } footer: {
                // The number people actually need is "how long until it
                // compacts", and saying which part is large is the only
                // actionable version of it: tools and system are fixed costs,
                // messages are the part a new conversation resets.
                Text(fraction > 0.8
                    ? "Nearly full. The agent will start compacting older messages, which loses detail. A fresh conversation keeps the system and tool cost but drops the message history."
                    : "System prompt and tool schemas are paid once per turn and do not shrink. Only the message history grows.")
            }
        }
    }

    // MARK: - Work

    @ViewBuilder
    private var work: some View {
        if let stats = conversation?.stats {
            Section("Work") {
                Row("Turns", "\(stats.turns)")
                Row("Steps", "\(stats.steps)")
                Row("Thinking", Format.duration(ms: stats.llmMs))
                if stats.toolMs > 0 {
                    Row("Running tools", Format.duration(ms: stats.toolMs))
                }
                if let ttft = stats.averageTtftMs {
                    Row("First token", "\(Format.duration(ms: ttft)) average")
                }
                if let rate = stats.tokensPerSecond, rate > 0 {
                    Row("Output speed", "\(Int(rate.rounded())) tok/s")
                }
            }
        }
    }

    // MARK: - Spend

    @ViewBuilder
    private var spend: some View {
        if let tokens = conversation?.tokens {
            Section {
                Row("Sent", Format.tokens(tokens.totalInput))
                Row("Received", Format.tokens(tokens.output))
                if let hit = tokens.cacheHitRate {
                    Row("Served from cache", "\(Int((hit * 100).rounded()))%")
                }
            } header: {
                Text("Tokens")
            } footer: {
                // Cached input is billed at a fraction of the price on every
                // provider that offers it, so a high number here is the
                // difference between a long conversation being cheap and not.
                Text("Cached input is re-sent every turn but charged at a discount. A long conversation is affordable mostly because of this number.")
            }
        }
    }

    // MARK: - Access

    @ViewBuilder
    private var access: some View {
        if let permissions = conversation?.permissions {
            Section {
                ForEach(permissions.options) { option in
                    Button {
                        change(to: option.value)
                    } label: {
                        HStack(alignment: .top, spacing: Metrics.tight) {
                            Image(systemName: option.value == permissions.current ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(option.value == permissions.current ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.tertiary))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PermissionChoice.label(for: option.value))
                                    .font(.system(size: 15, weight: option.value == permissions.current ? .semibold : .regular))
                                Text(PermissionChoice.detail(for: option.value))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(changingAccess)
                }
                if let accessError {
                    Text(accessError)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.warn)
                }
            } header: {
                Text("Access")
            } footer: {
                Text("This is a setting on the Mac, not on this conversation. Changing it here changes it for everything running there.")
            }
        }
    }

    private func change(to value: String) {
        guard !changingAccess else { return }
        changingAccess = true
        accessError = nil
        Task {
            defer { changingAccess = false }
            if let failure = await session.setPermission(value) {
                accessError = failure
            }
        }
    }
}

// MARK: - Pieces

/// The context window as a bar, split by what is filling it.
private struct ContextBar: View {
    let fraction: Double
    let breakdown: ContextBreakdown?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.well)
                HStack(spacing: 1) {
                    if let parts = breakdown, parts.total > 0 {
                        // Widths are the *share of the window*, not of the
                        // breakdown, so the bar's total length still reads as
                        // the fill percentage.
                        segment(width, parts.system, parts.total, Palette.accent.opacity(0.35))
                        segment(width, parts.tools, parts.total, Palette.accent.opacity(0.6))
                        segment(width, parts.messages, parts.total, Palette.accent)
                    } else {
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: max(2, width * fraction))
                    }
                }
            }
        }
        .frame(height: 8)
    }

    private func segment(_ width: CGFloat, _ part: Int, _ total: Int, _ color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(0, width * fraction * (Double(part) / Double(total))))
    }
}

private struct Legend: View {
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(Format.tokens(value))
                .font(.code(11))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct Row: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: Metrics.gap)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}
