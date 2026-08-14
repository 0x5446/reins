/// Choosing where a conversation happens.
///
/// A new conversation needs a working directory, and on a phone that cannot be a
/// text field — nobody types `/Users/you/code/thing` with a thumb. So it browses
/// the Mac, remembers where conversations have been started before, and puts
/// those first, because the honest distribution is that people work in four or
/// five folders and revisit them constantly.

import SwiftUI

struct DirectoryPicker: View {
    let session: MachineSession
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirectoryListing?
    @State private var loading = true
    @State private var problem: String?
    @State private var showHidden = false

    /// Folders a conversation has already been started in, most used first.
    private var recents: [String] {
        var counts: [String: Int] = [:]
        for summary in session.sessions {
            guard let cwd = summary.cwd else { continue }
            counts[cwd, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && listing == nil {
                    Placeholder(icon: "folder", title: "Reading folders…")
                } else if let problem {
                    Placeholder(icon: "exclamationmark.triangle", title: "Couldn’t browse", detail: problem) {
                        Button("Start in the default folder") { pick(nil) }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.horizontal, Metrics.gutter)
                    }
                } else if let listing {
                    browser(listing)
                }
            }
            .navigationTitle("Work in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show hidden", isOn: $showHidden)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await load(nil) }
    }

    private func browser(_ listing: DirectoryListing) -> some View {
        List {
            if !recents.isEmpty && listing.path == listing.home {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button {
                            pick(path)
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                                Text(Format.path((path as NSString).deletingLastPathComponent, home: listing.home))
                                    .font(.code(10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                ForEach(entries(listing)) { entry in
                    Button {
                        Task { await load(entry.path) }
                    } label: {
                        HStack(spacing: Metrics.gap) {
                            Image(systemName: "folder")
                                .foregroundStyle(Palette.accent)
                                .frame(width: 20)
                            Text(entry.name)
                                .font(.system(size: 15))
                                .foregroundStyle(entry.hidden ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                crumbs(listing)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Button("Start here") { pick(listing.path) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, Metrics.tight)
                .background(.bar)
        }
    }

    private func crumbs(_ listing: DirectoryListing) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(listing.crumbs) { crumb in
                    Button(crumb.name) {
                        Task { await load(crumb.path) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    if crumb.id != listing.crumbs.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .textCase(nil)
        }
    }

    private func entries(_ listing: DirectoryListing) -> [DirectoryEntry] {
        showHidden ? listing.entries : listing.entries.filter { !$0.hidden }
    }

    private func load(_ path: String?) async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            listing = try await session.harness.listDirectory(path: path)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That folder couldn’t be read."
        }
    }

    private func pick(_ path: String?) {
        dismiss()
        onPick(path)
    }
}
