/// The slash commands this machine knows.
///
/// A skill is just text: typing `/bro` and sending it is the whole mechanism,
/// and `session.prompt` needs nothing new. So this is a discovery problem, not
/// a capability one — the commands exist and are unreachable because nobody can
/// be expected to remember the names of thirty of them.
///
/// It appears while the message is a bare `/word` with no space yet, which is
/// exactly the window in which someone is trying to remember a name and no
/// other window. After the first space they are writing arguments and a list
/// covering the screen would be in the way.
///
/// The list is fetched once per session and kept. It changes when someone adds
/// a skill file on the Mac, which is not something that happens mid-sentence,
/// and a request on every keystroke would be.

import SwiftUI

/// One command the machine offers.
public struct SkillCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var detail: String

    public init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        detail = value["description"]?.stringValue ?? ""
    }

    /// The first sentence, which is all that fits and usually all there is worth
    /// reading — these descriptions are written for a model, at model length.
    public var summary: String {
        let cut = detail.firstIndex { $0 == "." || $0 == "。" }
        let head = cut.map { String(detail[detail.startIndex..<$0]) } ?? detail
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whether `text` is someone partway through typing a command name.
///
/// - Returns: the partial name, or nil when this is not that.
public func commandPrefix(in text: String) -> String? {
    guard text.hasPrefix("/") else { return nil }
    let body = text.dropFirst()
    // A space means they have moved on to arguments; a newline means they are
    // writing a message that merely starts with a slash.
    guard !body.contains(where: { $0 == " " || $0.isNewline }) else { return nil }
    return String(body)
}

struct CommandPicker: View {
    let commands: [SkillCommand]
    let filter: String
    let onPick: (SkillCommand) -> Void

    private var matches: [SkillCommand] {
        guard !filter.isEmpty else { return commands }
        let needle = filter.lowercased()
        // Prefix matches first: someone typing `/co` means the command starting
        // with "co", not the one whose description mentions it.
        let starts = commands.filter { $0.name.lowercased().hasPrefix(needle) }
        let contains = commands.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return starts + contains
    }

    var body: some View {
        if !matches.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { command in
                        Button {
                            onPick(command)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/\(command.name)")
                                    .font(.code(14))
                                    .foregroundStyle(.primary)
                                if !command.summary.isEmpty {
                                    Text(command.summary)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.gutter)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        Divider().padding(.leading, Metrics.gutter)
                    }
                }
            }
            // Tall enough for three or four without becoming the screen. The
            // transcript is how someone decides what to run next, so covering
            // it would trade one kind of blindness for another.
            .frame(maxHeight: 210)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityIdentifier("command.picker")
        }
    }
}
