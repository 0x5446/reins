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

    // `conversation(_:)` rather than a dictionary read: the sheet can be
    // opened on a session whose history has not been fetched, and this is
    // the accessor that starts that fetch.
    private var conversation: Conversation? { session.conversation(sessionId) }
    private var summary: SessionSummary? { session.sessions.first { $0.id == sessionId } }

    var body: some View {
        NavigationStack {
            List {
                context
                work
                spend
                access
            }
            .task { await session.loadPresets() }
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
                // Which agent this conversation runs as — fixed at creation,
                // like the access mode, so it is stated rather than offered.
                if let preset = summary?.agentPreset {
                    Row("Agent", session.presets.first { $0.id == preset }?.name ?? preset)
                }
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
                // Broken out rather than summed, because the three kinds of
                // input are not the same price. Cache reads are typically
                // around a tenth of fresh input and cache writes rather more
                // than it, so a single "sent" figure hides the one number that
                // decides what a long conversation costs.
                Row("Fresh input", Format.tokens(tokens.uncachedInput))
                if tokens.cacheWrite > 0 {
                    Row("Written to cache", Format.tokens(tokens.cacheWrite))
                }
                Row("Read from cache", Format.tokens(tokens.cacheRead))
                Row("Output", Format.tokens(tokens.output))
                if let hit = tokens.cacheHitRate {
                    Row("Cache hit rate", "\(Int((hit * 100).rounded()))%")
                }
            } header: {
                Text("Tokens")
            } footer: {
                Text(cacheFootnote(tokens))
            }
        }
    }

    // MARK: - Access

    /// What this conversation is allowed to touch. **Read-only, and that is the
    /// finding rather than a shortcut.**
    ///
    /// This was a three-way picker, and it did not work: tapping an option
    /// changed nothing on screen and the person reported it as a dead control.
    /// It was worse than dead. The only write available is
    /// `settings.update {ns: permission, patch: {defaultPreset}}` — the clue is
    /// in the field name — and measuring it settles what that means: after
    /// changing the machine default to `read-only` and running another turn, an
    /// existing session's `permissions` projection still read `workspace-write`.
    /// **A session's access mode is fixed when the session is created.**
    ///
    /// So the picker was offering to change something that cannot be changed,
    /// and the reason it looked broken is that it was honest by accident: the
    /// checkmark follows the projection, and the projection never moved. Had it
    /// updated locally the way the model picker used to, it would have shown a
    /// mode this conversation was not running under — which is the worse
    /// failure, because this particular lie is about what the agent may do to
    /// someone's files.
    ///
    /// The control moved to Settings, where it is labelled as what it is: the
    /// mode new conversations start in.
    @ViewBuilder
    private var access: some View {
        if let permissions = conversation?.permissions {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PermissionChoice.label(for: permissions.current))
                        .font(.system(size: 15, weight: .semibold))
                    Text(PermissionChoice.detail(for: permissions.current))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Access")
            } footer: {
                Text("Fixed when this conversation started and cannot be changed now — the Mac only lets the mode be chosen for new ones. Settings ▸ New conversations sets that. To run this work under a different mode, start a conversation.")
            }
        }
    }

    /// Say what the cache numbers mean for this particular conversation, since
    /// the same three figures read very differently at 5% and at 95%.
    private func cacheFootnote(_ tokens: TokenUsage) -> String {
        guard let hit = tokens.cacheHitRate else {
            return "Nothing has been sent yet."
        }
        if hit > 0.6 {
            return "Most of the input is being re-read from cache, which is charged at a fraction of fresh input. This is why a long conversation stays affordable."
        }
        if tokens.totalInput < 5_000 {
            return "Too early to say much — the cache warms up over the first few turns."
        }
        // A low rate late in a conversation usually means something keeps
        // changing near the front of the prompt, which invalidates everything
        // after it.
        return "A low hit rate this far in usually means something near the start of the prompt keeps changing, which throws away the cache behind it."
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
