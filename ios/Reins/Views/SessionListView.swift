/// The list of conversations on one machine.
///
/// The home screen. Its job is to get someone into the right conversation in one
/// tap, so the rows carry the two things that decide that — what it is about, and
/// whether it needs them right now — and nothing else.

import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
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
    /// The workspace whose name is being edited, and what it is being changed
    /// to. Held as the whole group rather than an id so the alert can say which
    /// one it is about even as the list underneath it changes.
    @State private var renamingGroup: SessionGroup?
    @State private var groupName = ""
    @State private var deletingGroup: SessionGroup?

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
        .alert("Rename workspace", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $groupName)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") {
                if let target = renamingGroup {
                    Task { await session.renameWorkspace(target.id, title: groupName) }
                }
                renamingGroup = nil
            }
        } message: {
            // Said because it is not obvious from a phone: this is the Mac's own
            // sidebar, and the name changes there too.
            Text("This is the name on the Mac’s sidebar as well.")
        }
        .confirmationDialog(
            "Stop grouping by \(deletingGroup?.title ?? "this folder")?",
            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove workspace", role: .destructive) {
                guard let target = deletingGroup else { return }
                deletingGroup = nil
                Task {
                    // Not undoable from here: re-registering the same folder
                    // mints a new workspace that adopts nothing, so the grouping
                    // is gone for good even though nothing else is.
                    guard await lock.confirm("Remove the \(target.title) workspace on your Mac.") else { return }
                    await session.deleteWorkspace(target.id)
                }
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            // Checked against the machine's own contract rather than assumed.
            // Deleting a workspace removes the grouping and nothing else: the
            // folder, the files in it, and every conversation stay exactly as
            // they were, and the conversations reappear under Ungrouped.
            Text("The folder, its files, and \(held) stay exactly as they are — they just move to Ungrouped. Only the grouping goes.")
        }
        .overlay(alignment: .top) {
            ProblemBanner(session: session)
        }
    }

    /// What the workspace about to be removed is holding, for the confirmation.
    /// The count is the reassuring part — someone is about to tap a red button
    /// over a section with forty conversations under it.
    private var held: String {
        let count = deletingGroup?.sessions.count ?? 0
        return count == 1 ? "the conversation in it" : "all \(count) conversations in it"
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            StatusLine(session: session)
            if rows.isEmpty {
                empty
            } else {
                let arrangement = board
                List {
                    // Flat while searching, on purpose. A search is already a
                    // way of crossing the folders, and putting three results
                    // behind three headers would hide them behind the very
                    // structure the person just chose to ignore.
                    //
                    // Flat, too, when there is nothing to divide by: one
                    // workspace, none at all, or a dsh too old to have
                    // `workspace.list`. That is the same list this screen drew
                    // before grouping existed, which is what makes the failure
                    // path unremarkable rather than a special case.
                    if query.isEmpty, arrangement.grouped {
                        sections(arrangement)
                    } else {
                        ForEach(rows) { row($0) }
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(Metrics.tight)
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

    // MARK: - Sections

    /// The list arranged into workspaces, with whatever is stuck lifted clear.
    ///
    /// Recomputed per render rather than cached: it is a couple of dictionary
    /// passes over a few dozen rows, and a cache would need invalidating on
    /// every event that touches a session, an approval, or a workspace — three
    /// chances to show something stale in exchange for microseconds.
    private var board: SessionBoard {
        SessionBoard(
            sessions: session.sessions,
            workspaces: session.workspaces,
            waitingOn: Set(session.approvals.keys).union(session.questions.keys),
            archived: session.archivedSessionIds
        )
    }

    @ViewBuilder
    private func sections(_ arrangement: SessionBoard) -> some View {
        // Above everything and outside every fold. This is the one thing on the
        // screen that is not filing — a tool waiting on a tap does not care
        // which folder it is in, and burying it under a collapsed header would
        // defeat the entire reason for carrying this app around.
        if !arrangement.waiting.isEmpty {
            Section {
                ForEach(arrangement.waiting) { row(Row(summary: $0, snippet: nil)) }
            } header: {
                GroupHeader(title: "Needs you", count: arrangement.waiting.count, open: nil, tint: Palette.warn) {}
            }
        }
        ForEach(arrangement.groups) { group in
            let open = session.folds.isOpen(group.id, unlessRemembered: group.id == arrangement.openByDefault)
            Section {
                if open {
                    ForEach(group.sessions) { row(Row(summary: $0, snippet: nil)) }
                }
            } header: {
                GroupHeader(title: group.title, count: group.sessions.count, open: open) {
                    // Short and unspringy. A fold near the top of the list
                    // moves everything under it, and a bouncy curve turns that
                    // into the whole screen lurching.
                    withAnimation(.easeOut(duration: 0.2)) {
                        session.folds.set(group.id, open: !open)
                    }
                }
                // Long press rather than a swipe: a section header is not a row
                // and cannot carry swipe actions, and rename and remove are both
                // things done once, deliberately, not while scrolling past.
                //
                // Attached only to real workspaces, and by branching rather than
                // by an empty menu body — a `contextMenu` with nothing in it
                // still opens on long press, and a blank popup reads as broken.
                // "Ungrouped" is this app's own word for what nothing claims;
                // there is no workspace behind it to rename or remove.
                .modifier(WorkspaceHeaderActions(
                    group: group,
                    rename: {
                        groupName = group.title
                        renamingGroup = group
                    },
                    remove: { deletingGroup = group }
                ))
            }
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        var id: String { summary.id }
        var summary: SessionSummary
        var snippet: String?
    }

    @ViewBuilder
    private func row(_ item: Row) -> some View {
        Button {
            path.append(item.summary.id)
        } label: {
            SessionRow(
                summary: item.summary,
                snippet: item.snippet,
                needsYou: session.approvals[item.summary.id] != nil || session.questions[item.summary.id] != nil,
                home: session.machineInfo?.cwd
            )
        }
        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
        .listRowBackground(Palette.paper)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button {
                renameText = item.summary.title ?? ""
                renaming = item.summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Palette.accent)
        }
        // Rename is here as well as on the swipe so this menu is never empty:
        // the filing item below is absent for most rows, and a context menu with
        // nothing in it still opens on long press.
        .contextMenu {
            Button {
                renameText = item.summary.title ?? ""
                renaming = item.summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            filing(item.summary)
        }
    }

    /// The one thing that can be done about a conversation's grouping.
    ///
    /// Not a "move to…" menu, because there is nowhere to move it to. A
    /// conversation belongs to the workspace whose folder is its own working
    /// folder, that folder never changes, and the machine refuses to file a
    /// conversation anywhere else. So the only case worth a menu item is the one
    /// this app used to cause: a conversation sitting in the leftovers whose
    /// folder does have — or could have — a workspace.
    @ViewBuilder
    private func filing(_ summary: SessionSummary) -> some View {
        switch session.filing(for: summary) {
        case .settled:
            EmptyView()
        case .join(let workspaceId, let title):
            Button {
                Task { await session.fileSession(summary.id, into: workspaceId) }
            } label: {
                Label("Move into \(title)", systemImage: "folder")
            }
        case .claim(let folder):
            Button {
                Task {
                    // Two calls, and the second is the point: making the
                    // workspace groups nothing by itself. Stopping after the
                    // first would leave the row exactly where it was, under a
                    // section that had just appeared empty.
                    if let failure = await session.createWorkspace(path: folder) {
                        session.problem = failure
                        return
                    }
                    guard case .joins(let workspaceId, _) = session.placement(for: folder) else { return }
                    await session.fileSession(summary.id, into: workspaceId)
                }
            } label: {
                Label("Group by \((folder as NSString).lastPathComponent)", systemImage: "folder.badge.plus")
            }
        }
    }

    /// Search results, when there is a query, joined against the list this screen
    /// already holds — the machine answers with ids and excerpts, and the titles
    /// and timestamps live here.
    private var rows: [Row] {
        // The same archive filter `SessionBoard` applies, because this is the
        // path taken when there is nothing to group by — a machine with one
        // workspace or none — and an archived conversation must not come back
        // just because the sections did not draw.
        let visible = session.archivedSessionIds.isEmpty
            ? session.sessions
            : session.sessions.filter { !session.archivedSessionIds.contains($0.id) }
        guard !query.isEmpty else {
            return visible.map { Row(summary: $0, snippet: nil) }
        }
        // The machine is the only search backend, deliberately. An earlier
        // version filtered titles locally as a floor when the machine could not
        // search, and that was wrong for a reason worth keeping written down:
        // the two match different things — message contents versus a title —
        // and blended into one list nobody can tell which is which, so the
        // local half quietly returns rows the machine would not have. Half a
        // search that disagrees with the machine is worse than no search that
        // says so.
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
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

/// Long-press actions for a section that stands for a real workspace.
///
/// A modifier rather than an `if` inside the menu body, because an empty
/// `contextMenu` is not the same as no `contextMenu`: the first still opens a
/// blank popup over the header. A group is either the leftovers or a workspace
/// for its whole life, so branching on it never swaps a view's identity
/// mid-flight.
private struct WorkspaceHeaderActions: ViewModifier {
    let group: SessionGroup
    let rename: () -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        if group.isUngrouped {
            content
        } else {
            content.contextMenu {
                Button(action: rename) {
                    Label("Rename workspace", systemImage: "pencil")
                }
                Button(role: .destructive, action: remove) {
                    Label("Remove workspace", systemImage: "folder.badge.minus")
                }
            }
        }
    }
}

/// A section head: what the group is, how much is in it, and whether it is open.
///
/// The count is not decoration. Folded, this row is the only thing standing for
/// forty conversations, and a header with no number says "empty" as readily as
/// it says "collapsed".
private struct GroupHeader: View {
    let title: String
    let count: Int
    /// nil for a section that cannot fold — the one holding whatever is waiting
    /// on an answer, which has no business being hidden.
    let open: Bool?
    var tint: Color = .secondary
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: open == nil ? "hand.raised.fill" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open == true ? 90 : 0))
                    .foregroundStyle(open == nil ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            // Section headers are uppercased by some list styles. These are
            // folder names someone typed, and shouting them back changes what
            // they say.
            .textCase(nil)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        // Only ever used as a section header, so it carries its own row metrics
        // rather than making both call sites restate them. The paper
        // background matters: a plain list pins headers as you scroll, and the
        // default backing would show as a grey band over the cards.
        .listRowInsets(EdgeInsets(top: 2, leading: Metrics.gutter, bottom: 2, trailing: Metrics.gutter))
        .listRowBackground(Palette.paper)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) conversations")
        .accessibilityHint(open == nil ? "" : (open == true ? "Collapses this group" : "Expands this group"))
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
