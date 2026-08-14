/// One conversation.
///
/// The screen people will spend all their time on. Three bands: a header that
/// answers "where am I and what is it doing", the transcript, and the composer.
/// Anything that blocks the agent slots in between the last two, so the thing
/// waiting on a person is always directly above their thumb.

import SwiftUI

struct ConversationView: View {
    let session: MachineSession
    let sessionId: String

    @State private var conversation: Conversation?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showModels = false
    @State private var atBottom = true

    var body: some View {
        VStack(spacing: 0) {
            if let conversation {
                if !conversation.todos.isEmpty {
                    TodoStrip(todos: conversation.todos)
                }
                transcript(conversation)
                footer(conversation)
            } else {
                Placeholder(icon: "ellipsis", title: "Opening…")
            }
        }
        .background(Palette.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            let held = session.conversation(sessionId)
            conversation = held
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await session.rename(sessionId: sessionId, title: renameText) }
            }
        }
        .sheet(isPresented: $showModels) {
            ModelPicker(session: session, sessionId: sessionId)
        }
        .overlay(alignment: .top) { ProblemBanner(session: session) }
    }

    // MARK: - Transcript

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                    header(conversation)

                    if conversation.hasMore {
                        Button {
                            Task { await session.loadOlder(conversation) }
                        } label: {
                            if conversation.loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load earlier messages")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metrics.tight)
                    }

                    ForEach(conversation.items) { item in
                        TranscriptItem(item: item)
                            .id(item.id)
                    }

                    if conversation.running, conversation.items.last.map(stillOpen) != true {
                        Thinking().padding(.leading, 2)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Anchor.bottom)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.gap)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        withAnimation { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
                    }
                    .padding(Metrics.gap)
                }
            }
            .onChange(of: conversation.items.count) { _, _ in
                guard atBottom else { return }
                proxy.scrollTo(Anchor.bottom, anchor: .bottom)
            }
            .onChange(of: lastLength(conversation)) { _, _ in
                // Streaming grows the last bubble without changing the count, so
                // following along needs its length too.
                guard atBottom else { return }
                proxy.scrollTo(Anchor.bottom, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(Anchor.bottom, anchor: .bottom)
            }
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    // Dragging downward means reading back; stop chasing the tail
                    // until the person returns to it.
                    if value.translation.height > 24 { atBottom = false }
                }
            )
            .onChange(of: conversation.running) { _, running in
                if running { atBottom = true }
            }
        }
    }

    private enum Anchor: Hashable { case bottom }

    private func stillOpen(_ item: ConversationItem) -> Bool {
        switch item {
        case .assistant(let turn): return !turn.complete
        case .tool(let card): return card.running
        default: return false
        }
    }

    private func lastLength(_ conversation: Conversation) -> Int {
        guard case .assistant(let turn)? = conversation.items.last else { return 0 }
        return turn.text.count + turn.reasoning.count
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ conversation: Conversation) -> some View {
        if conversation.items.isEmpty && conversation.loaded {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing here yet")
                    .font(.system(size: 17, weight: .semibold))
                Text(conversation.cwd.map { "Working in \(Format.path($0, home: session.machineInfo?.cwd))" } ?? "Say what you want done.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Metrics.gutter)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ conversation: Conversation) -> some View {
        VStack(spacing: Metrics.tight) {
            if let approval = session.approvals[sessionId] {
                ApprovalCard(request: approval) { allow in
                    Task { await session.answer(approval: approval, allow: allow) }
                }
                .padding(.horizontal, Metrics.gutter)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let question = session.questions[sessionId] {
                QuestionCard(request: question) { answers in
                    Task { await session.answer(question: question, answers: answers) }
                }
                .padding(.horizontal, Metrics.gutter)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !conversation.queue.isEmpty {
                QueueStrip(queue: conversation.queue) { item in
                    Task {
                        try? await session.harness.updateQueue(sessionId: sessionId, itemId: item.id, action: .remove)
                    }
                }
            }
            Composer(
                running: conversation.running,
                planning: conversation.planning,
                enabled: session.harnessReachable,
                onSend: { text, images in
                    atBottom = true
                    Task { await session.send(sessionId: sessionId, text: text, images: images) }
                },
                onStop: {
                    Task { await session.cancel(sessionId: sessionId) }
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: session.approvals[sessionId])
        .animation(.easeInOut(duration: 0.2), value: session.questions[sessionId])
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(conversation?.title ?? summary?.displayTitle ?? "Conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    renameText = conversation?.title ?? ""
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    showModels = true
                } label: {
                    Label("Model", systemImage: "cpu")
                }
                if conversation?.running == true {
                    Button(role: .destructive) {
                        Task { await session.cancel(sessionId: sessionId) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
                if let fraction = conversation?.contextFraction {
                    Section {
                        Label("Context \(Int(fraction * 100))% full", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var summary: SessionSummary? {
        session.sessions.first { $0.id == sessionId }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let cwd = conversation?.cwd ?? summary?.cwd {
            parts.append((cwd as NSString).lastPathComponent)
        }
        if let model = conversation?.modelName {
            parts.append(model)
        }
        if let fraction = conversation?.contextFraction, fraction > 0.7 {
            parts.append("context \(Int(fraction * 100))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
