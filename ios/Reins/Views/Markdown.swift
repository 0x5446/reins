/// Just enough Markdown.
///
/// Agents write in a narrow dialect: paragraphs, fenced code, bullets, the odd
/// heading, and inline emphasis. A full CommonMark engine would be a dependency,
/// a build-time cost, and a source of layout surprises for the six constructs
/// that actually turn up. This handles those six and renders anything else as the
/// literal text, which is the honest failure mode — nothing disappears.
///
/// Inline formatting is `AttributedString`'s Markdown parser, which is in the
/// system and understands bold, italic, inline code, and links.

import SwiftUI

/// One parsed block.
enum MarkdownBlock: Identifiable, Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(items: [String], ordered: Bool)
    case quote(String)
    case code(language: String?, text: String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let text): return "p\(text.hashValue)"
        case .heading(let level, let text): return "h\(level)\(text.hashValue)"
        case .bullet(let items, let ordered): return "l\(ordered)\(items.joined().hashValue)"
        case .quote(let text): return "q\(text.hashValue)"
        case .code(let language, let text): return "c\(language ?? "")\(text.hashValue)"
        case .rule: return "rule"
        }
    }
}

enum Markdown {
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

        for line in source.components(separatedBy: "\n") {
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
