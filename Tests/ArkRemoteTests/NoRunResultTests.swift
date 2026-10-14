import XCTest

/// Regression 0108 #26 (design rule 7; owner decisions S1 / S3). Defect guarded: the App goes back to showing or reading
/// how the PC's runs went (「最近一趟 X」, 「失败 N 趟」, the state's 今天.最近 / 今天.失败). That is the daily report's job,
/// so this is a product-scope guard, not a malfunction check: d7516c8 took the code path out, not only the text. The
/// replay step status.noresult looks at the drawn page; this check keeps the code from coming back, and runs with
/// every `swift test`. A failure of the App's own sending (「发送失败 …」) is not a run result and is not caught.
final class NoRunResultTests: XCTestCase {
    static let banned = try! NSRegularExpression(
        pattern: #"最近一趟|失败 \\\(.*\) 趟|失败 \d+ 趟|\btodayFailed\b|\btodayLast\b|\["今天"\]|\["失败"\]|\["最近"\]"#)

    static func hits(_ lines: [String]) -> [String] {
        lines.enumerated().compactMap { i, line in
            let c = RepoFiles.code(line)
            return banned.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) == nil
                ? nil : "\(i + 1) \(c.trimmingCharacters(in: .whitespaces))"
        }
    }

    func testNoRunResultsInTheApp() throws {
        var found: [String] = []
        for (path, lines) in try RepoFiles.swiftSources() { found += Self.hits(lines).map { "\(path):\($0)" } }
        XCTAssertEqual(found, [], "the App shows or reads how the machine's runs went")
    }

    /// d7516c8^'s receipts header and mapping are caught; 「现在跑一趟」, 「这一趟」 and a send failure are not.
    func testTheScanCatchesTheOldHeader() {
        let old = [
            "            let note = [data.todayLast.isEmpty ? \"\" : \"最近一趟 \\(data.todayLast)\",",
            "                        data.todayFailed > 0 ? \"失败 \\(data.todayFailed) 趟\" : \"\"].filter { !$0.isEmpty }",
            "        let today = snap?[\"今天\"]",
            "        d.todayLast = today?[\"最近\"]?.jsString ?? \"\"",
        ]
        XCTAssertEqual(Self.hits(old).count, 4)
        XCTAssertEqual(Self.hits(["tileLabel(\"现在跑一趟\", x)", "Text(\"这一趟\")", "// 最近一趟 was removed",
                                  "Text(\"发送失败 \\(e)\")"]), [])
    }
}
