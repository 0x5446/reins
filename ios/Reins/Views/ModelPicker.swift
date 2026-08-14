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

    private func select(_ option: ModelOption) async {
        switching = option.id
        defer { switching = nil }
        do {
            try await session.harness.selectModel(sessionId: sessionId, option: option)
            catalog?.current = option
            dismiss()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That model couldn’t be selected."
        }
    }
}
