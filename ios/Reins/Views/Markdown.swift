/// Just enough Markdown.
///
/// Agents write in a narrow dialect: paragraphs, fenced code, bullets, the odd
/// heading, and inline emphasis. A full CommonMark engine would be a dependency,
/// a build-time cost, and a source of layout surprises for the six constructs
/// that actually turn up. This handles those six and renders anything else as the
/// literal text, which is the honest failure mode — nothing disappears.
///
/// Tables were the seventh construct and were missing, which is not the same as
/// unsupported: a pipe table fell through to a paragraph and rendered as a wall
/// of literal `|` characters. That is worse than any layout compromise, so a
/// table is now parsed and drawn — scrolled sideways when it does not fit,
/// because reflowing a table into cards loses the comparison the table was for.
///
/// Inline formatting is `AttributedString`'s Markdown parser, which is in the
/// system and understands bold, italic, inline code, and links.

import SwiftUI

/// Which way a table column is set, taken from the separator row's colons.
enum MarkdownAlignment: Equatable {
    case leading, center, trailing

    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

/// One parsed block.
enum MarkdownBlock: Identifiable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(items: [String], ordered: Bool)
    case quote(String)
    case code(language: String?, text: String)
    /// A pipe table. Alignments come from the separator row and are worth
    /// keeping: a column of numbers is much easier to compare right-aligned,
    /// and that is most of what an agent puts in a table.
    case table(header: [String], rows: [[String]], alignments: [MarkdownAlignment])
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): return "p\(text.hashValue)"
        case .heading(let level, let text): return "h\(level)\(text.hashValue)"
        case .bullet(let items, let ordered): return "l\(ordered)\(items.joined().hashValue)"
        case .quote(let text): return "q\(text.hashValue)"
        case .code(let language, let text): return "c\(language ?? "")\(text.hashValue)"
        case .table(let header, let rows, _): return "t\(header.joined().hashValue)\(rows.count)"
        case .rule: return "rule"
        }
    }
}

enum Markdown {
    /// Split a `| a | b |` row into its cells.
    static func cells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Read a separator row, or decide this is not one.
    ///
    /// Returns nil for anything that is not `|---|:--:|`, which is what stops an
    /// ordinary sentence containing a pipe from being promoted to a table.
    static func separator(_ line: String) -> [MarkdownAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return nil }
        let parts = cells(trimmed)
        guard !parts.isEmpty else { return nil }
        var alignments: [MarkdownAlignment] = []
        for part in parts {
            guard part.contains("-"), part.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            let left = part.hasPrefix(":"), right = part.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments
    }

    /// Split source into blocks. Linear, single pass, no lookahead beyond the
    /// current line — which is why an unterminated fence swallows the rest of the
    /// text rather than throwing: that is what a half-streamed code block is.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered = false
        var fence: (marker: String, language: String?)?
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullet(items: bullets, ordered: ordered))
            bullets = []
        }
        func flush() {
            flushParagraph()
            flushBullets()
        }

        let lines = source.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let open = fence {
                if trimmed.hasPrefix(open.marker) {
                    blocks.append(.code(language: open.language, text: code.joined(separator: "\n")))
                    code = []
                    fence = nil
                } else {
                    code.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let marker = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (marker, language.isEmpty ? nil : language)
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
                continue
            }

            if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
                continue
            }

            if let item = bullet(trimmed) {
                flushParagraph()
                if !bullets.isEmpty && ordered != item.ordered { flushBullets() }
                ordered = item.ordered
                bullets.append(item.text)
                continue
            }

            if trimmed.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            // A table is the one construct here that cannot be recognised from
            // its first line alone: `| a | b |` is only a header if the *next*
            // line is `|---|---|`. Without that check every pipe-containing
            // sentence would become a one-row table.
            if trimmed.hasPrefix("|"), index < lines.count,
               let alignments = Markdown.separator(lines[index]) {
                flush()
                let header = Markdown.cells(trimmed)
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix("|") else { break }
                    rows.append(Markdown.cells(next))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            flushBullets()
            paragraph.append(line)
        }

        if let open = fence {
            // Still streaming, or the author forgot to close it. Either way the
            // text is code and showing it as such beats showing the fence.
            blocks.append(.code(language: open.language, text: code.joined(separator: "\n")))
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    private static func bullet(_ line: String) -> (text: String, ordered: Bool)? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return (String(line.dropFirst(2)), false)
        }
        // "1. " through "999. "
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (String(rest.dropFirst(2)), true)
    }

    /// Inline emphasis, code, and links, via the system parser. A source string
    /// the parser rejects comes back verbatim.
    static func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

// MARK: - Rendering

/// A block of agent-written prose.
struct MarkdownText: View {
    let source: String
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            ForEach(Markdown.parse(source)) { block in
                switch block {
                case .paragraph(let text):
                    Text(Markdown.inline(text))
                        .font(.system(size: size))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let text):
                    Text(Markdown.inline(text))
                        .font(.system(size: size + (level <= 2 ? 4 : 2), weight: .semibold))
                        .padding(.top, 4)
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let items, let ordered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .font(.system(size: size))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                                Text(Markdown.inline(item))
                                    .font(.system(size: size))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .quote(let text):
                    HStack(spacing: Metrics.tight) {
                        Rectangle()
                            .fill(Palette.line)
                            .frame(width: 2)
                        Text(Markdown.inline(text))
                            .font(.system(size: size))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let text):
                    CodeBlock(language: language, text: text)
                case .table(let header, let rows, let alignments):
                    MarkdownTable(header: header, rows: rows, alignments: alignments)
                case .rule:
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
            }
        }
    }
}

/// Fenced code. Scrolls sideways rather than wrapping, because wrapped code is
/// harder to read than code you have to push.
struct CodeBlock: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Metrics.gap)
                    .padding(.top, 7)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.code(12.5))
                    .textSelection(.enabled)
                    .padding(Metrics.gap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
    }
}


/// A pipe table, drawn as one.
///
/// Scrolled sideways rather than reflowed. A table exists so two rows can be
/// compared column by column, and every "responsive" trick that turns rows into
/// stacked cards destroys exactly that. A phone is narrow; the honest answer is
/// to let the table be its own width and move it under the finger.
///
/// The header stays put while the body scrolls with it — they are one grid, so
/// columns cannot drift apart, which is the failure of drawing them separately.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [MarkdownAlignment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, column: column, header: true)
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        // Pad short rows rather than dropping them: a ragged
                        // table is still information, and a missing cell should
                        // read as empty rather than shift the columns left.
                        ForEach(0..<header.count, id: \.self) { column in
                            cellView(column < row.count ? row[column] : "", column: column, header: false)
                        }
                    }
                    if index < rows.count - 1 {
                        Divider().opacity(0.4).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
    }

    private func cellView(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(Markdown.inline(text))
            .font(.system(size: 14, weight: header ? .semibold : .regular))
            .multilineTextAlignment(alignment.text)
            .frame(minWidth: 44, alignment: alignment.frame)
            .padding(.horizontal, Metrics.gap)
            .padding(.vertical, 7)
            .fixedSize(horizontal: false, vertical: true)
    }
}
