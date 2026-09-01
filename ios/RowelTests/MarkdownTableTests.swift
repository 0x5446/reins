/// Tables, which were the one construct the renderer met often and drew as
/// literal pipes.
///
/// The fixture is the reply that exposed it — a `df -h` summary the agent laid
/// out as a table, which arrived on the phone as a wall of `|`.

import XCTest
@testable import Rowel

final class MarkdownTableTests: XCTestCase {
    func testTheTableThatArrivedAsPipes() {
        let source = """
        具体情况：

        | 挂载点 | 容量 | 已用 | 可用 |
        |---|---|---|---|
        | 系统卷 / | 460 Gi | 11 Gi | 88 Gi |
        | 数据卷 /System/Volumes/Data | 460 Gi | 338 Gi | 88 Gi |

        补充两点：
        """
        let blocks = Markdown.parse(source)

        guard let table = blocks.compactMap({ block -> (header: [String], rows: [[String]])? in
            if case .table(let header, let rows, _) = block { return (header, rows) }
            return nil
        }).first else {
            return XCTFail("no table; it fell through to a paragraph again: \(blocks)")
        }
        XCTAssertEqual(table.header, ["挂载点", "容量", "已用", "可用"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[1], ["数据卷 /System/Volumes/Data", "460 Gi", "338 Gi", "88 Gi"])
        // The prose either side must survive as its own blocks.
        XCTAssertEqual(blocks.count, 3)
    }

    /// The reason a table needs lookahead: without it every sentence with a
    /// pipe in it becomes a one-row table.
    func testAPipeInProseIsNotATable() {
        for source in ["run `a | b` to pipe it", "| not a table", "| a | b |\nplain text"] {
            let blocks = Markdown.parse(source)
            XCTAssertFalse(blocks.contains { if case .table = $0 { return true }; return false },
                           "promoted to a table: \(source)")
        }
    }

    func testAlignmentComesFromTheSeparatorRow() {
        let blocks = Markdown.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |")
        guard case .table(_, _, let alignments) = blocks.first else { return XCTFail("no table") }
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
    }

    /// A table still streaming in, or one the agent wrote raggedly.
    func testARaggedTableKeepsItsColumns() {
        let blocks = Markdown.parse("| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 |")
        guard case .table(let header, let rows, _) = blocks.first else { return XCTFail("no table") }
        XCTAssertEqual(header.count, 3)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], ["1"], "a short row is kept; the view pads it rather than dropping it")
    }
}
