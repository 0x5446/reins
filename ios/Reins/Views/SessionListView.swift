/// The list of conversations on one machine.
///
/// The home screen. Its job is to get someone into the right conversation in one
/// tap, so the rows carry the two things that decide that — what it is about, and
/// whether it needs them right now — and nothing else.

import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    let session: MachineSession
    @Binding var path: [String]

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    /// Why the machine could not run a full-text search, when it could not.
    ///
    /// Shown rather than swallowed. The first version used `try?`, which turned
    /// "this Mac has the session index switched off" into an empty list — the
    /// app telling someone their words matched nothing when the truth was that
    /// it never asked.
    @State private var searchUnavailable: String?
    @State private var picking = false
    @State private var renaming: SessionSummary?
    @State private var renameText = ""

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            NewButton { picking = true }
                .padding(Metrics.gutter)
                .opacity(session.harnessReachable ? 1 : 0.4)
                .disabled(!session.harnessReachable)
        }
        .background(Palette.paper)
        .navigationTitle("")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
        .task(id: query) { await runSearch() }
        .refreshable { await session.refreshSessions() }
        .sheet(isPresented: $picking) {
            DirectoryPicker(session: session) { cwd in
                Task {
                    if let id = await session.createSession(cwd: cwd) {
                        path.append(id)
                    }
                }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let target = renaming {
                    Task { await session.rename(sessionId: target.id, title: renameText) }
                }
                renaming = nil
            }
        }
        .overlay(alignment: .top) {
            ProblemBanner(session: session)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            StatusLine(session: session)
            if rows.isEmpty {
                empty
            } else {
                List {
                    ForEach(rows) { row in
                        Button {
                            path.append(row.summary.id)
                        } label: {
                            SessionRow(
                                summary: row.summary,
                                snippet: row.snippet,
                                needsYou: session.approvals[row.summary.id] != nil || session.questions[row.summary.id] != nil,
                                home: session.machineInfo?.cwd
                            )
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
                        .listRowBackground(Palette.paper)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button {
                                renameText = row.summary.title ?? ""
                                renaming = row.summary
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(Palette.accent)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Palette.paper)
                .accessibilityIdentifier("sessions.list")
                // Under the results, not over them: what is on screen is real
                // and useful, and what is missing is only the message-content
                // half. A banner would imply the list itself is untrustworthy.
                // The compose button floats over the bottom-trailing corner, so
                // the list has to end above it. Without this the last row sits
                // under the button and cannot be read or tapped.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 72)
                }
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if session.listing && session.sessions.isEmpty {
            Placeholder(icon: "ellipsis", title: "Loading conversations…")
        } else if !query.isEmpty, searchUnavailable != nil {
            // Not "nothing matched" — the machine never ran the search, so no
            // claim about matches is warranted. And the remedy is four lines of
            // YAML, so it belongs here rather than in a support page: dsh ships
            // with the index off for everyone, which makes this the single most
            // likely thing a new user sees when they first tap search.
            Placeholder(
                icon: "magnifyingglass",
                title: "Search is off on this Mac",
                detail: """
                dsh ships with its session index disabled. To switch it on, add this to \
                ~/.dsh/profiles/web/cordis.patch.yml and restart dsh:

                - id: session-query-sqlite
                  config:
                    path: ~/.dsh/session-query.sqlite
                    openAt: first-search
                """
            )
        } else if !query.isEmpty {
            Placeholder(icon: "magnifyingglass", title: "Nothing matched", detail: "Try a word from the conversation itself.")
        } else if !session.isOnline {
            // Not reachable at all. Saying anything about dsh here would be
            // stating something the app cannot know: with no tunnel there is no
            // information about what is running on the far side, and the last
            // time this claimed "dsh isn't running" the truth was that dsh was
            // fine and the Bridle had stopped.
            Placeholder(
                icon: "antenna.radiowaves.left.and.right.slash",
                title: "Can’t reach \(session.machine.name)",
                detail: "The Mac is asleep, off your network, or Bridle isn’t running on it."
            )
        } else if !session.harnessReachable {
            Placeholder(
                icon: "bolt.horizontal.circle",
                title: "dsh isn’t running",
                detail: session.harnessDetail ?? "Start the agent on \(session.machine.name) and this fills in by itself."
            )
        } else {
            Placeholder(
                icon: "bubble.left.and.text.bubble.right",
                title: "No conversations yet",
                detail: "Start one and pick the folder to work in."
            ) {
                Button("New conversation") { picking = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, Metrics.gutter * 2)
            }
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        var id: String { summary.id }
        var summary: SessionSummary
        var snippet: String?
    }

    /// Search results, when there is a query, joined against the list this screen
    /// already holds — the machine answers with ids and excerpts, and the titles
    /// and timestamps live here.
    private var rows: [Row] {
        guard !query.isEmpty else {
            return session.sessions.map { Row(summary: $0, snippet: nil) }
        }
        // The machine is the only search backend, deliberately. An earlier
        // version filtered titles locally as a floor when the machine could not
        // search, and that was wrong for a reason worth keeping written down:
        // the two match different things — message contents versus a title —
        // and blended into one list nobody can tell which is which, so the
        // local half quietly returns rows the machine would not have. Half a
        // search that disagrees with the machine is worse than no search that
        // says so.
        let byId = Dictionary(uniqueKeysWithValues: session.sessions.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let summary = byId[hit.id] else { return nil }
            return Row(summary: summary, snippet: hit.snippet.isEmpty ? nil : hit.snippet)
        }
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            hits = []
            return
        }
        // A keystroke-per-request would hammer the tunnel; a beat of quiet first
        // means one search per pause in typing.
        try? await Task.sleep(nanoseconds: 280_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            hits = try await session.harness.search(query: text).hits
            searchUnavailable = nil
        } catch {
            hits = []
            // dsh says "session search is disabled: … openAt \"never\"" when the
            // index was never opened, which is a deployment choice rather than a
            // fault. Either way the local matches below still stand, so this is
            // a footnote under results and not a banner over them.
            searchUnavailable = (error as? LocalizedError)?.errorDescription
                ?? "This Mac has full-text search turned off."
        }
    }
}

/// One conversation.
struct SessionRow: View {
    let summary: SessionSummary
    var snippet: String?
    var needsYou: Bool
    /// The machine's home directory, so paths read as `~/code/thing`.
    var home: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Metrics.tight) {
                    Text(summary.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if needsYou {
                        Pill("Needs you", color: Palette.warn, icon: "hand.raised.fill")
                    } else if summary.running {
                        Pill("Running", color: Palette.accent, icon: "circle.fill")
                    }
                }
                HStack(spacing: 6) {
                    if let cwd = summary.cwd {
                        // The path relative to home, not just its last
                        // component: everything in one workspace shares a last
                        // component, and eight rows all reading "workspace" is
                        // the same as showing nothing.
                        Text(Format.path(cwd, home: home))
                            .font(.code(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(Format.ago(summary.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                if let snippet {
                    Text(snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// The one action on this screen.
struct NewButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Palette.accent, in: Circle())
                .shadow(color: Palette.accent.opacity(0.35), radius: 12, y: 4)
        }
        .accessibilityLabel("New conversation")
    }
}

/// A transient failure, shown over whatever is on screen and dismissed by tapping
/// it or by time. Failures here are things like "that didn't send" — worth saying
/// once, not worth a modal.
struct ProblemBanner: View {
    let session: MachineSession

    var body: some View {
        if let problem = session.problem {
            Text(problem)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Metrics.gap)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bad, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                .padding(.horizontal, Metrics.gutter)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { session.problem = nil }
                .task(id: problem) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    session.problem = nil
                }
        }
    }
}
