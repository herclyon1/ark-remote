import XCTest

/// Regression 0108 #20 (and the code half of #27). The owner, 10-07 03:46 / 03:54 and again 10-08 10:19 and 10-13 16:06:
/// the App copied the phone's own Settings app, whose changes apply the moment they are made, while this App changes
/// another machine through a mailbox. 10-13 01:48: 「一改就生效这是我发现最大的问题」 (from the 10-07 commits that dropped
/// the 待保存 list). Design rule 4 (BOARD/App-设计史-1013.md): save → review → 寄出, one save, never apply on change.
///
/// Guarded here: nothing a control changes leaves the phone by itself. Every send to the mailbox is one of a fixed set of
/// places, and each of those runs only after a yes: the review sheet's 寄出 (SaveBar go()), the 状态 commands' alert
/// (StatusCommands.send), a 月卡 registration's question (MonthCardRows register), a 「再发一次」 of a change already sent
/// (Pending.resend), or the status reads (refresh / watch, which change nothing). A page that sends from a Toggle's,
/// Picker's or field's setter adds a send place and goes red.
/// Not judged here: whether a page looks like Settings (D212 condition 2, the side-by-side screenshots).
final class NoInstantApplyTests: XCTestCase {
    /// A send to the mailbox (Net.swift Relay.send) on a line of code.
    static let relaySend = try! NSRegularExpression(pattern: #"\b(relay|r|Relay\.shared|self\.relay)\.send\("#)

    /// The places allowed to send: file → the functions around the send.
    static let allowed: [String: Set<String>] = [
        "Sources/ArkRemote/Logic/Edits.swift": ["send"],              // EWSave.send, called by the review's 寄出 only
        "Sources/ArkRemote/Logic/Pending.swift": ["resend"],          // 「再发一次」 of a change that went out before
        "Sources/ArkRemote/Logic/MonthCard.swift": ["post"],          // a 月卡 registration, after its question
        "Sources/ArkRemote/Logic/Live.swift": ["pingInner", "askWatch"],   // refresh / watch: reads, no change
        "Sources/ArkRemote/Pages/Status/StatusCommands.swift": ["send"],   // 状态 commands, after their alert
    ]

    static let declaration = try! NSRegularExpression(pattern: #"\bfunc\s+(\w+)|\bvar\s+(\w+)\s*:\s*some\s+View\b"#)

    /// The name of the function (or view property) a line sits in: the nearest `func name` / `var name: some View` above it.
    static func function(around i: Int, in lines: [String]) -> String {
        for j in stride(from: i, through: 0, by: -1) {
            let c = RepoFiles.code(lines[j]) as NSString
            if let m = declaration.firstMatch(in: c as String, range: NSRange(location: 0, length: c.length)) {
                let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
                return c.substring(with: r)
            }
        }
        return "(top level)"
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Every send outside the allowed places, as "path:line function".
    static func strays(_ files: [(path: String, lines: [String])]) -> [String] {
        var out: [String] = []
        for (path, lines) in files {
            for (i, line) in lines.enumerated() where matches(relaySend, RepoFiles.code(line)) {
                let f = function(around: i, in: lines)
                if !(allowed[path]?.contains(f) ?? false) { out.append("\(path):\(i + 1) \(f)") }
                // Live's sends are the two reads only
                if path.hasSuffix("Logic/Live.swift"), !line.contains("\"refresh\""), !line.contains("\"watch\"") {
                    out.append("\(path):\(i + 1) sends something other than refresh / watch")
                }
            }
        }
        return out
    }

    /// Where `call` is made, as "path function".
    static func callers(_ call: String, in files: [(path: String, lines: [String])]) -> [String] {
        files.flatMap { path, lines in
            lines.enumerated().compactMap { i, line in
                RepoFiles.code(line).contains(call) ? "\(path) \(function(around: i, in: lines))" : nil
            }
        }
    }

    func testOnlyTheConfirmedPlacesSend() throws {
        let files = try RepoFiles.swiftSources()
        XCTAssertEqual(Self.strays(files), [], "a send outside save → review → 寄出 / a confirmed command")
        // each allowed place is reached only from its yes
        XCTAssertEqual(Set(Self.callers("EWSave.send(", in: files)), ["Sources/ArkRemote/Pages/Shell/SaveBar.swift go"])
        XCTAssertEqual(Set(Self.callers("StatusCommands.send(", in: files)), ["Sources/ArkRemote/Pages/Shell/StatusTab.swift body"])
        XCTAssertEqual(Set(Self.callers("MonthCardStore.shared.register(", in: files)),
                       ["Sources/ArkRemote/Pages/Status/MonthCardRows.swift register"])
        let bar = try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/SaveBar.swift").map(RepoFiles.code)
        let goCalls = bar.filter { $0.contains("go()") && !$0.contains("func go()") }
        XCTAssertEqual(goCalls.count, 1, "go() is called from more than the review's 寄出 button")
        XCTAssertTrue(goCalls.first?.contains("Button(\"寄出") ?? false, "go() is not the 寄出 button's action")
        // the 状态 commands go out from the alert's confirming button
        let tab = try RepoFiles.lines("Sources/ArkRemote/Pages/Shell/StatusTab.swift").map(RepoFiles.code)
        let at = try XCTUnwrap(tab.firstIndex { $0.contains("StatusCommands.send(") })
        XCTAssertTrue(tab[..<at].suffix(12).contains { $0.contains(".alert(") }, "StatusCommands.send is not inside the alert")
    }

    /// A Toggle that sends from its setter, as the 10-07 pages did, is caught; the review's own send is not.
    func testTheScanCatchesASendOnChange() {
        let page = [
            "struct ArknightsPage: View {",
            "    var body: some View {",
            "        Toggle(\"邮件\", isOn: Binding(get: { on }, set: { v in",
            "            Task { try await Relay.shared.send(.object([\"action\": .string(\"set_master\")])) } }))",
            "    }",
            "}",
        ]
        XCTAssertEqual(Self.strays([("Sources/ArkRemote/Pages/Arknights/ArknightsPage.swift", page)]),
                       ["Sources/ArkRemote/Pages/Arknights/ArknightsPage.swift:4 body"])
        let edits = ["    static func send(_ edits: [String: EWEdit]) async {", "        try await relay.send(body)", "    }"]
        XCTAssertEqual(Self.strays([("Sources/ArkRemote/Logic/Edits.swift", edits)]), [])
    }
}
