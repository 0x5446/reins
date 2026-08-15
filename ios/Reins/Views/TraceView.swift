/// The whole conversation as one line per event.
///
/// A transcript is for reading; this is for finding. After twenty minutes of
/// work the transcript is several thousand words of rendered markdown, diffs,
/// and command output, and the question someone actually has on a phone is one
/// of three: *what has it been doing*, *where did it go wrong*, and *where was
/// that one command*. None of those survive scrolling.
///
/// Nothing here is fetched. It reads the same `conversation.items` the
/// transcript does, so it opens instantly, works offline, and cannot disagree
/// with the screen behind it. Tapping a row takes the transcript to that item —
/// finding something and then having to hunt for it again would be the whole
/// point missed.

import SwiftUI

struct TraceView: View {
    let conversation: Conversation
    /// Called with the item to scroll to, after this sheet closes.
    let onJump: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var lens: Lens = .everything

    /// What to keep. Deliberately not the web UI's Duration/Turns/Calls, which
    /// are analysis axes for a wide screen. On a phone the useful cuts are "just
    /// the actions" and "just the damage".
    enum Lens: String, CaseIterable, Identifiable {
        case everything = "All"
        case tools = "Tools"
        case failures = "Problems"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    Placeholder(
                        icon: query.isEmpty ? "clock" : "magnifyingglass",
                        title: query.isEmpty ? "Nothing yet" : "No matches",
                        detail: query.isEmpty
                            ? "Steps appear here as the agent works."
                            : "Nothing in this conversation matches “\(query)”."
                    )
                } else {
                    List(rows) { row in
                        Button {
                            // Dismiss first: scrolling the view underneath while
                            // a sheet is still covering it lands on the wrong
                            // offset once the sheet animates away.
                            dismiss()
                            onJump(row.id)
                        } label: {
                            TraceRow(row: row)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Trace")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a command, file, or message")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Show", selection: $lens) {
                        ForEach(Lens.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("trace.list")
        }
    }

    private var rows: [TraceEntry] {
        let all = conversation.items.compactMap(TraceEntry.init)
        let lensed: [TraceEntry]
        switch lens {
        case .everything: lensed = all
        case .tools: lensed = all.filter { $0.kind == .tool }
        case .failures: lensed = all.filter { $0.failed }
        }
        guard !query.isEmpty else { return lensed }
        let needle = query.lowercased()
        return lensed.filter { $0.searchText.lowercased().contains(needle) }
    }
}

/// One line of the trace.
struct TraceEntry: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tool, notice }

    let id: String
    let kind: Kind
    let icon: String
    let label: String
    let detail: String
    let at: Date
    let failed: Bool
    let running: Bool

    /// What the search box matches against — the label and the detail, because
    /// someone hunting for a command remembers either the tool or the argument.
    var searchText: String { "\(label) \(detail)" }

    init?(_ item: ConversationItem) {
        switch item {
        case .user(let turn):
            // Injected context is not something a person did and is not what
            // they are scanning for; it belongs in the transcript, not here.
            guard !turn.synthetic else { return nil }
            id = turn.id
            kind = .user
            icon = "person"
            label = "You"
            detail = TraceEntry.oneLine(turn.text)
            at = turn.at
            failed = false
            running = false
        case .assistant(let turn):
            let text = turn.text.isEmpty ? turn.reasoning : turn.text
            // A bubble with nothing in it yet is noise in a list; it is already
            // visible as "thinking" on the transcript.
            guard !text.isEmpty else { return nil }
            id = turn.id
            kind = .assistant
            icon = "text.alignleft"
            label = "Reply"
            detail = TraceEntry.oneLine(text)
            at = turn.at
            failed = false
            running = !turn.complete
        case .tool(let card):
            id = card.id
            kind = .tool
            icon = TraceEntry.icon(for: card.presentation)
            label = card.name
            detail = TraceEntry.oneLine(card.headline)
            at = card.at
            failed = card.failed
            running = card.running
        case .notice(let notice):
            id = notice.id
            kind = .notice
            icon = notice.kind == .failure ? "exclamationmark.triangle" : "info.circle"
            label = notice.kind == .failure ? "Error" : "Note"
            detail = TraceEntry.oneLine(notice.text)
            at = notice.at
            failed = notice.kind == .failure
            running = false
        }
    }

    /// Collapse to something that fits one row: no newlines, no runs of spaces.
    static func oneLine(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let squeezed = flattened.split(separator: " ").joined(separator: " ")
        return squeezed.count > 200 ? String(squeezed.prefix(200)) + "…" : squeezed
    }

    static func icon(for presentation: ToolPresentation) -> String {
        switch presentation {
        case .terminal: return "terminal"
        case .diff: return "plusminus"
        case .search: return "magnifyingglass"
        case .read: return "doc.text"
        case .generic: return "wrench.and.screwdriver"
        }
    }
}

private struct TraceRow: View {
    let row: TraceEntry

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Image(systemName: row.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.failed ? Palette.bad : .secondary)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(row.failed ? Palette.bad : .primary)
                    if row.running {
                        Text("running")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Metrics.tight)
                    Text(row.at, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(row.kind == .tool ? .code(12) : .system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .contentShape(Rectangle())
    }
}
