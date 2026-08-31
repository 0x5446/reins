/// The split that makes streaming affordable.
///
/// `Markdown.settle` divides text at the last block boundary so the prefix can
/// render behind an equality check. That is only sound if the division is
/// invisible: the two halves parsed apart must be the whole parsed together,
/// for every shape of half-arrived text — and the prefix must never rewrite
/// itself mid-stream, or the skip it exists for stops firing.

import XCTest
@testable import Reins

final class MarkdownSettleTests: XCTestCase {
    /// Shapes chosen for their boundary behaviour: fences that swallow blank
    /// lines, constructs that need adjacency, blanks in every position.
    private let corpus = [
        "",
        "one paragraph, no boundary",
        "two\nlines of one paragraph",
        "first\n\nsecond",
        "first\n\nsecond\n\n",
        "\n\nleading blanks",
        "a\n\n\n\nb",
        "para\n\n- one\n- two\n\n1. first\n2. second",
        "# Title\n\ntext under it\n\n---\n\n> a quote",
        "before\n\n```swift\ncode\n\nstill code after a blank line\n```\n\nafter",
        "before\n\n```\nan unterminated fence\n\nwith a blank inside",
        "tilde\n\n~~~\nfenced\n\n~~~\n\ntail",
        "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\noutro",
        "text\n\n```\n---\n\n# not a heading, code\n```",
    ]

    func testHalvesParseAsTheWhole() {
        for source in corpus {
            let (settled, live) = Markdown.settle(source)
            XCTAssertEqual(
                Markdown.parse(settled) + Markdown.parse(live),
                Markdown.parse(source),
                "split changed the reading of: \(source.debugDescription)"
            )
        }
    }

    func testSingleBlockStaysWhollyLive() {
        let (settled, live) = Markdown.settle("still being written")
        XCTAssertEqual(settled, "")
        XCTAssertEqual(live, "still being written")
    }

    func testBlankInsideOpenFenceIsNotABoundary() {
        let (settled, _) = Markdown.settle("a\n\n```\nx\n\ny")
        XCTAssertEqual(settled, "a", "an open fence must keep its interior live")
    }

    /// Stream a document in and require the settled prefix to only ever grow.
    /// A prefix that shrank or changed would re-render the whole bubble — the
    /// exact cost this split removes.
    func testSettledPrefixIsStableUnderStreaming() {
        let document = corpus.joined(separator: "\n\n")
        var previous = ""
        var partial = ""
        for character in document {
            partial.append(character)
            let (settled, _) = Markdown.settle(partial)
            XCTAssertTrue(
                settled.hasPrefix(previous),
                "settled text rewrote itself at: \(partial.suffix(30).debugDescription)"
            )
            previous = settled
        }
    }
}
