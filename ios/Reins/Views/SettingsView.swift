/// Settings, and the security screen that lives inside them.
///
/// Most of this is one-time: the device name, and forgetting a Mac. The part
/// worth reading is the connection section, which is the only place someone can
/// check what the app is actually doing — direct or relayed, and against which
/// key. Putting that behind a "learn more" link would be a way of not saying it.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var choosingDefaultModel = false
    @State private var unpairing: PairedMachine?

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                if let session = model.active {
                    connection(session)

                    Section {
                        Button {
                            choosingDefaultModel = true
                        } label: {
                            LabeledContent("New conversations use") {
                                Text(session.defaultModel?.name ?? "Machine default")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    } footer: {
                        Text("dsh routes a new conversation to whichever provider is configured first. Naming one here means it starts on the model you meant.")
                    }
                }

                Section("This iPhone") {
                    LabeledContent("Name") {
                        TextField("iPhone", text: $model.deviceName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    Row(label: "Key fingerprint", value: model.deviceFingerprint, mono: true)
                        .textCase(nil)
                }

                Section {
                    ForEach(model.machines) { machine in
                        Button {
                            unpairing = machine
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(machine.name)
                                        .font(.system(size: 15, weight: .medium))
                                    Text(machine.fingerprint)
                                        .font(.code(11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: Metrics.tight)
                                if machine.id == model.active?.machine.id {
                                    Text("Connected")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                        // The same action by swipe, for people who expect it.
                        // A swipe alone would not do: it is invisible, and the
                        // only way to discover it is to already know.
                        .swipeActions {
                            Button(role: .destructive) {
                                unpairing = machine
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    Text("Tap a Mac to forget it on this iPhone. To stop that Mac trusting this iPhone, run `bridle revoke` there — this end cannot do it for you.")
                }

                Section {
                    Link(destination: Links.help) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    Link(destination: Links.privacy) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    Row(label: "Version", value: model.clientVersion)
                }

                Section {
                    Button("Start over as a new device", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("Throws away this iPhone’s key, so every Mac stops recognising it and you pair again from scratch. Only useful if the key itself is the problem — to remove one Mac, tap it above.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $choosingDefaultModel) {
                if let session = model.active {
                    DefaultModelPicker(session: session)
                }
            }
            .confirmationDialog("Start over as a new device?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Start over", role: .destructive) {
                    model.resetEverything()
                    dismiss()
                }
            } message: {
                Text("This iPhone gets a new key. Every Mac will treat it as one it has never seen, and each will still list the old one until you run `bridle revoke` there.")
            }
            .confirmationDialog(
                unpairing.map { "Forget \($0.name)?" } ?? "",
                isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Forget this Mac", role: .destructive) {
                    if let target = unpairing { model.unpair(target.id) }
                    unpairing = nil
                }
            } message: {
                Text("It disappears from this iPhone. That Mac still trusts this iPhone until you run `bridle revoke` on it.")
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private func connection(_ session: MachineSession) -> some View {
        Section {
            Row(label: "Machine", value: session.machine.name)
            Row(label: "Route", value: route(session))
            if let info = session.machineInfo {
                Row(label: "dsh", value: info.version)
                Row(label: "Folder", value: Format.path(info.cwd, home: info.cwd), mono: true)
            }
            Row(label: "Its fingerprint", value: session.machine.fingerprint, mono: true)
            if let confirmation = session.confirmation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirmation number")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(confirmation)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .kerning(3)
                    Text("Your Mac shows the same six digits after `bridle pair`. If they differ, forget this Mac and pair again.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text(session.carrier == .lan
                ? "Direct over your local network. Nothing leaves your Wi-Fi."
                : "Through the relay, which forwards encrypted bytes it can’t read.")
        }
    }

    private func route(_ session: MachineSession) -> String {
        switch session.status {
        case .online(let carrier, _, let harnessUp):
            let path = carrier == .lan ? "Direct (Wi-Fi)" : "Relay"
            return harnessUp ? path : "\(path), dsh down"
        case .connecting: return "Connecting"
        case .waiting: return "Retrying"
        case .refused: return "Refused"
        case .idle: return "Not connected"
        }
    }
}

/// A label and a value, the way every settings row in the app looks.
private struct Row: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: Metrics.gap)
            Text(value)
                .font(mono ? .code(12) : .system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
