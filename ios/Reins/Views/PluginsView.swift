/// What is mounted in the Mac's dsh.
///
/// Read-only on purpose. Enabling or removing a plugin edits a YAML file on
/// the Mac, and a mistake there does not degrade dsh — a plugin that fails to
/// load takes the whole harness down with it, measured the hard way. That is
/// not an action to offer on a phone screen; what a phone needs is the answer
/// to "is my thing actually loaded", which is exactly the question this app's
/// own Bridle plugin raises during setup.
///
/// Fetched fresh on every open rather than cached: the list changes when the
/// person edits their profile, and staleness here would misreport exactly the
/// thing someone opens this to check.

import SwiftUI

struct PluginsView: View {
    let session: MachineSession

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PluginEntry]?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    listing(entries)
                } else if failed {
                    Placeholder(
                        icon: "puzzlepiece.extension",
                        title: "Couldn’t ask",
                        detail: "This dsh may be too old to list its plugins, or the connection dropped mid-question."
                    )
                } else {
                    Placeholder(icon: "ellipsis", title: "Asking the Mac…")
                }
            }
            .navigationTitle("Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                entries = await session.plugins()
                failed = entries == nil
            }
            .refreshable {
                entries = await session.plugins() ?? entries
            }
        }
    }

    @ViewBuilder
    private func listing(_ entries: [PluginEntry]) -> some View {
        let enabled = entries.filter(\.enabled)
        let disabled = entries.filter { !$0.enabled }
        List {
            Section {
                ForEach(enabled) { PluginRow(entry: $0) }
            } header: {
                Text("Running · \(enabled.count)")
            } footer: {
                Text("Managed on the Mac, in ~/.dsh/profiles. Reins shows the list so you can check something loaded without walking over.")
            }
            if !disabled.isEmpty {
                Section("Disabled · \(disabled.count)") {
                    ForEach(disabled) { PluginRow(entry: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct PluginRow: View {
    let entry: PluginEntry

    var body: some View {
        HStack(spacing: Metrics.gap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.module)
                    .font(.code(12.5))
                    .foregroundStyle(entry.enabled ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                // The entry id, only when it says something the module name
                // does not — most are one-to-one.
                if entry.id != entry.module, !entry.module.hasSuffix(entry.id) {
                    Text(entry.id)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Metrics.tight)
            // An enabled plugin that is not active is the interesting state:
            // it should be running and is not, which is precisely the situation
            // this screen exists to catch.
            if entry.enabled, entry.phase != "active" {
                Pill(entry.phase ?? "not running", color: Palette.warn, icon: "exclamationmark.triangle.fill")
            }
        }
        .padding(.vertical, 1)
    }
}
