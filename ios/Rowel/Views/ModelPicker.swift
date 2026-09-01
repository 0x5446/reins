/// Switching a conversation's model.
///
/// Grouped by provider, because that is how the harness reports them and how
/// people think about them. Providers that failed to load are listed rather than
/// dropped: a missing model is otherwise indistinguishable from a model that was
/// never installed, and the fix is different.

import SwiftUI

struct ModelPicker: View {
    let session: MachineSession
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var problem: String?
    @State private var switching: String?
    /// The level chosen for the current model, before it is sent.
    @State private var effort: String?

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    list(catalog)
                } else if let problem {
                    Placeholder(icon: "exclamationmark.triangle", title: "Couldn’t list models", detail: problem)
                } else {
                    Placeholder(icon: "cpu", title: "Loading models…")
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func list(_ catalog: ModelCatalog) -> some View {
        List {
            ForEach(groups(catalog), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.options) { option in
                        Button {
                            Task { await select(option) }
                        } label: {
                            HStack(alignment: .top, spacing: Metrics.gap) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .font(.system(size: 15, weight: .medium))
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if switching == option.id {
                                    ProgressView().controlSize(.small)
                                } else if catalog.current?.id == option.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)

                        // Under the model it belongs to, and only for the one
                        // in use. Showing every model's levels would triple the
                        // list to answer a question nobody asked about models
                        // they are not on.
                        if catalog.current?.id == option.id {
                            let levels = catalog.efforts(for: option)
                            if !levels.isEmpty {
                                Picker("Thinking", selection: Binding(
                                    get: { effort ?? catalog.currentEffort ?? catalog.defaultEffort(for: option) ?? levels[0].id },
                                    set: { chosen in
                                        effort = chosen
                                        Task { await select(option, effort: chosen, keepOpen: true) }
                                    }
                                )) {
                                    ForEach(levels) { level in
                                        Text(level.name).tag(level.id)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .listRowInsets(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 10, trailing: Metrics.gutter))
                            }
                        }
                    }
                }
            }
            if !catalog.failures.isEmpty {
                Section("Unavailable") {
                    ForEach(catalog.failures, id: \.self) { failure in
                        Text(failure)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct ProviderGroup {
        var provider: String
        var name: String
        var options: [ModelOption]
    }

    private func groups(_ catalog: ModelCatalog) -> [ProviderGroup] {
        var order: [String] = []
        var byProvider: [String: ProviderGroup] = [:]
        for option in catalog.options {
            if byProvider[option.provider] == nil {
                order.append(option.provider)
                byProvider[option.provider] = ProviderGroup(provider: option.provider, name: option.providerName, options: [])
            }
            byProvider[option.provider]?.options.append(option)
        }
        return order.compactMap { byProvider[$0] }
    }

    private func load() async {
        do {
            catalog = try await session.harness.models(sessionId: sessionId)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "The Mac didn’t answer."
        }
    }

    /// Apply a model, and the thinking level that goes with it.
    ///
    /// - Parameters:
    ///   - effort: nil lets the machine keep whatever the model defaults to.
    ///   - keepOpen: true when only the level changed. Dismissing then would
    ///     make trying two levels a matter of reopening the sheet each time.
    private func select(_ option: ModelOption, effort chosen: String? = nil, keepOpen: Bool = false) async {
        switching = option.id
        defer { switching = nil }
        // Switching model carries the new model's own default rather than the
        // level the previous one happened to be on — "Max" on a small model and
        // "Max" on a large one are not the same amount of money.
        let level = chosen ?? catalog?.defaultEffort(for: option)
        // Through the session, not the harness. The header reads the
        // conversation, so a write that only touched this sheet's copy left the
        // two disagreeing until the next turn.
        if let failure = await session.selectModel(sessionId: sessionId, option: option, effort: level) {
            problem = failure
            return
        }
        catalog?.current = option
        catalog?.currentEffort = level
        effort = level
        if !keepOpen { dismiss() }
    }
}
