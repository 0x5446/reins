/// What the window shows.
///
/// Three states, in priority order: a broken identity, no machines yet, and the
/// normal case. Keeping the branch here means every other screen can assume it
/// has an identity and a machine, and none of them need an "if not paired" path.

import SwiftUI

public struct RootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            if let fatal = model.fatal {
                FatalView(message: fatal)
            } else if model.isNew {
                OnboardingView()
            } else {
                MachineView()
            }
        }
        .background(Palette.paper)
        .animation(.easeInOut(duration: 0.22), value: model.isNew)
    }
}

/// The identity could not be created. There is nothing to do in the app until it
/// can be, so this offers the one action that has ever fixed it.
struct FatalView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        Placeholder(
            icon: "exclamationmark.triangle",
            title: "Reins can’t start",
            detail: message
        ) {
            Button("Reset Reins") { model.resetEverything() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.horizontal, Metrics.gutter * 2)
        }
    }
}

/// The connected machine: its conversations, and everything reachable from them.
struct MachineView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let session = model.active {
                    SessionListView(session: session, path: $path)
                } else {
                    Placeholder(
                        icon: "desktopcomputer",
                        title: "No machine connected",
                        detail: "Pick one of your paired Macs to carry on."
                    ) {
                        Button("Choose a Mac") { showPicker = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.horizontal, Metrics.gutter * 2)
                    }
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                if let session = model.active {
                    ConversationView(session: session, sessionId: sessionId)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showPicker = true
                    } label: {
                        MachineChip(name: model.active?.machine.name ?? "Reins", status: model.active?.status ?? .idle)
                    }
                    .accessibilityLabel("Switch Mac")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(Palette.paper, for: .navigationBar)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPicker) { MachinePicker() }
        .onChange(of: model.active?.machine.id) { _, _ in
            // Switching machines invalidates every session id on the stack.
            path = []
        }
    }
}

/// The title-bar control: which Mac, and whether it is reachable.
struct MachineChip: View {
    let name: String
    let status: TunnelStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
    }
}

/// Connection state as one dot. The colour carries the meaning; the status line
/// under the header carries the words, so this stays silent when all is well.
struct StatusDot: View {
    let status: TunnelStatus
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .opacity(connecting && pulsing ? 0.3 : 1)
            .animation(connecting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulsing)
            .onAppear { pulsing = true }
    }

    private var connecting: Bool {
        if case .connecting = status { return true }
        return false
    }

    private var colour: Color {
        switch status {
        case .online(_, _, let harnessUp): return harnessUp ? Palette.good : Palette.warn
        case .connecting: return Palette.warn
        case .waiting: return Palette.warn
        case .refused: return Palette.bad
        case .idle: return .secondary
        }
    }
}

/// One line of plain language about the connection, shown only when something is
/// not normal. A connected app says nothing, because "Connected" is noise.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    let session: MachineSession

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if retryable {
                    Button("Retry") { session.poke() }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.11))
        }
    }

    private var message: String? {
        switch session.status {
        case .idle:
            return nil
        case .connecting:
            return "Reaching \(session.machine.name)…"
        case .waiting(let detail, let retryIn):
            let seconds = max(1, Int(retryIn.rounded()))
            return "\(detail) Trying again in \(seconds)s."
        case .refused(let reason):
            switch reason {
            case .unpaired:
                return "\(session.machine.name) doesn’t recognise this iPhone. Run `bridle pair` on the Mac and scan the new code."
            case .version:
                return "This app and the Bridle on \(session.machine.name) are different versions. Update the older one."
            case .machineError(let detail):
                return detail
            }
        case .online:
            return session.harnessDetail
        }
    }

    private var icon: String {
        switch session.status {
        case .refused: return "xmark.octagon"
        case .online: return "bolt.horizontal.circle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch session.status {
        case .refused: return Palette.bad
        case .online: return Palette.warn
        default: return Palette.warn
        }
    }

    private var retryable: Bool {
        switch session.status {
        case .waiting: return true
        case .online: return false
        default: return false
        }
    }
}

/// Switch between paired Macs, or add another.
struct MachinePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.machines) { machine in
                        Button {
                            model.connect(to: machine.id)
                            dismiss()
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(machine.name).font(.system(size: 16, weight: .medium))
                                    Text(machine.id)
                                        .font(.code(11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if model.active?.machine.id == machine.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Pair another Mac", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Your Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $adding) {
            PairingFlow { dismiss() }
        }
    }
}
