/// What the connection has actually been doing.
///
/// The screen that should have existed already. An app that talks to a machine
/// over two different networks will one day fail on exactly one of them, and
/// the phone holding the failing network is usually nowhere near the Mac that
/// could be asked. Without this the only report available is "it won't
/// connect", and the only reply available is guesswork.
///
/// Everything here is already in memory — `MachineSession.notes` is filled as
/// the tunnel dials — so this costs nothing to open and works while offline,
/// which is the state it is for.
///
/// No filter, no search, no levels to configure. A hundred lines is a screen
/// and a half; anything more elaborate is a feature for a bug that has not
/// happened yet.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DiagnosticsView: View {
    let session: MachineSession

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if session.notes.isEmpty {
                    Placeholder(
                        icon: "waveform.path",
                        title: "Nothing yet",
                        detail: "Lines appear here each time Rowel dials this Mac."
                    )
                } else {
                    ScrollViewReader { scroller in
                        List {
                            Section {
                                ForEach(session.notes) { note in
                                    NoteRow(note: note).id(note.id)
                                }
                            } header: {
                                Text("Connection")
                            } footer: {
                                Text("Addresses, verdicts, and timings only — never a key, a folder, or anything from a conversation. Kept in memory, so it is gone when Rowel closes.")
                            }
                        }
                        .listStyle(.plain)
                        // Newest last, and the newest line is the one being
                        // waited on, so land there rather than at the top.
                        .onAppear { scroller.scrollTo(session.notes.last?.id, anchor: .bottom) }
                        .onChange(of: session.notes.last?.id) { _, id in
                            withAnimation { scroller.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "Copied" : "Copy") { copy() }
                        .disabled(session.notes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The whole log as text, so it can be pasted somewhere a person can read
    /// it. A screenshot loses the lines that scrolled off.
    private func copy() {
        let stamp = Date.FormatStyle(date: .omitted, time: .standard)
        let body = session.notes
            .map { "\($0.at.formatted(stamp))  \($0.text)" }
            .joined(separator: "\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = "Rowel \(session.machine.name)\n\(body)"
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

private struct NoteRow: View {
    let note: ConnectionNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.tight) {
            Text(note.at.formatted(.dateTime.hour().minute().second()))
                .font(.code(11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(note.text)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 5, leading: Metrics.gutter, bottom: 5, trailing: Metrics.gutter))
        .textSelection(.enabled)
    }

    private var tint: Color {
        switch note.level {
        case .attempt: return .secondary
        case .ok: return Palette.accent
        case .fail: return Palette.warn
        }
    }
}
