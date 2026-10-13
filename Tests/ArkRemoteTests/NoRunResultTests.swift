import XCTest

/// Regression 0108 #26: 10-07 17:56 「机器出错、上一趟失败，这个不是给日报去解决了吗？是server酱里面解决的事情啊，怎么会在
/// app上面看呢？」 (design rule 7; owner decisions S1 / S3). How the machine's runs went is the daily report's: the App
/// shows neither 「最近一趟 X」 nor 「失败 N 趟」, and does not read the state's 今天.最近 / 今天.失败 at all (d7516c8 took
/// the code path out, not only the text). The replay step status.noresult looks at the drawn page; this check keeps the
/// code from coming back, and runs with every `swift test`.
final class NoRunResultTests: XCTestCase {
    static let banned = try! NSRegularExpression(
        pattern: #"最近一趟|失败 \\\(|失败 \d+ 趟|\btodayFailed\b|\btodayLast\b|\["今天"\]|\["失败"\]|\["最近"\]"#)

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

    /// d7516c8^'s receipts header and mapping are caught; 「现在跑一趟」 and 「这一趟」 are not.
    func testTheScanCatchesTheOldHeader() {
        let old = [
            "            let note = [data.todayLast.isEmpty ? \"\" : \"最近一趟 \\(data.todayLast)\",",
            "                        data.todayFailed > 0 ? \"失败 \\(data.todayFailed) 趟\" : \"\"].filter { !$0.isEmpty }",
            "        let today = snap?[\"今天\"]",
            "        d.todayLast = today?[\"最近\"]?.jsString ?? \"\"",
        ]
        XCTAssertEqual(Self.hits(old).count, 4)
        XCTAssertEqual(Self.hits(["tileLabel(\"现在跑一趟\", x)", "Text(\"这一趟\")", "// 最近一趟 was removed"]), [])
    }
}
