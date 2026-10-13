import XCTest

/// Regression 0108 #8: 10-02 20:49 「回执现在完全显示不出来内容，是被截断了，不应该是省略号，你加了省略号依旧显示不了信息」
/// (cf2e0c2: a receipt shows its whole text, wrapping). Owner decision S8 says the same for every plan hint on 状态.
/// The check: no text in Sources/ is cut. A `.lineLimit` / `.truncationMode` is allowed only where it cannot cut: on a
/// short value that keeps its whole width (`.fixedSize(horizontal: true, vertical: false)` on the same line), or as the
/// height a multi-line input field reserves (`reservesSpace: true`). The receipt row's text itself carries neither.
final class NoCutTextTests: XCTestCase {
    /// "line text" of every limit that could cut.
    static func cuts(_ lines: [String]) -> [String] {
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let c = RepoFiles.code(line)
            guard c.contains(".lineLimit(") || c.contains(".truncationMode(") else { continue }
            if c.contains(".fixedSize(horizontal: true, vertical: false)") || c.contains("reservesSpace: true") { continue }
            out.append("\(i + 1) \(c.trimmingCharacters(in: .whitespaces))")
        }
        return out
    }

    func testNothingIsCut() throws {
        var hits: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() { hits += Self.cuts(lines).map { "\(path):\($0)" } }
        XCTAssertEqual(hits, [], "text that can be cut off")
    }

    /// The receipt's own text line is a bare Text, nothing chained after it on the line.
    func testReceiptTextWraps() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        let row = try XCTUnwrap(RepoFiles.body(after: "func receiptRow(", in: lines), "receiptRow is gone")
        let text = try XCTUnwrap(row.first { $0.contains("Text(r.text)") }, "receiptRow no longer shows r.text")
        XCTAssertFalse(text.contains("lineLimit") || text.contains("truncation"), text)
    }

    func testTheScanCatchesTheOldRow() {
        XCTAssertEqual(Self.cuts(["            Text(r.text).lineLimit(1)"]), ["1 Text(r.text).lineLimit(1)"])
        XCTAssertEqual(Self.cuts(["Text(r.text)", "    .lineLimit(2).truncationMode(.tail)"]),
                       ["2 .lineLimit(2).truncationMode(.tail)"])
        XCTAssertEqual(Self.cuts(["Text(when).lineLimit(1).fixedSize(horizontal: true, vertical: false)"]), [])
    }
}
