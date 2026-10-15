import XCTest
@testable import ArkRemote

/// Regression 0108 #28. The owner's question, 10-07 19:16-19:18 (asked three times): 「这个首页摆出的数的位置是不是应该都是
/// 固定的吗？」, with 「只不过它取决状态，它有些时候会强调出来。否则它位置变的话我岂不是每次都要重找」. Design rules 1 and 5
/// (BOARD/App-设计史-1013.md): the everyday numbers stay where they are, a state only changes how one is shown.
/// The fix named in the list (c6eecd5, HomeFactsTests) was for the 「Home D」 page, which was dropped with D215; 0.5.x is
/// built on 0.4.4's 状态 page, so the guard is re-made for that page.
///
/// StatusHomeDataTests (#25) already holds that every number is on the page in the on / off / unreadable states and
/// that no state flag hides its section. This adds what makes the places fixed:
///  1. the stamina tiles are always the same three in the same order, whatever the shifts run or which keys are set
///     (a game left out of every shift, no 库街区 key, a full or unreadable game only changes that tile's text);
///  2. the page draws the everyday blocks in one fixed order: action tiles, stamina, 班次, 机器, 月卡;
///  3. the 月卡 rows are every game in the fixed game order, registered or not.
@MainActor final class StatusFixedPlacesTests: XCTestCase {
    static let tileOrder = ["明日方舟 理智", "终末地 理智", "鸣潮 波片"]

    /// A state whose shifts run `scripts` (早班) and 晚班 MAA only.
    static func snap(early scripts: [String]) throws -> JSONValue {
        let list = scripts.map { "\"\($0)\"" }.joined(separator: ", ")
        return try JSONValue.parse("""
            {"at": \(Int(nowMs() / 1000) - 60), "config": {"MAA": {"关卡": "1-7"}},
             "queues": [{"名": "早班", "定时": true, "脚本": [\(list)]}, {"名": "晚班", "定时": true, "脚本": ["MAA"]}],
             "plan": "🕘 04:00\\n▸ 明日方舟\\n刷 1-7", "relay": {"最近指令": []}}
            """)
    }

    func testTheTilesKeepTheirPlaces() throws {
        let guardState = SharedStateGuard()
        defer { guardState.restore() }
        let full = GameStamina(current: 135, max: 135)
        let readings: [(String, StaminaReading)] = [
            ("normal", StaminaReading(arknights: GameStamina(current: 80, max: 135), endfield: GameStamina(current: 100, max: 240),
                                      wuwa: WuwaStamina(waveplates: 120, max: 240, reserve: 30, weekly: 2, weeklyMax: 3), takenAt: "09:00")),
            ("arknights full, no 库街区 key", StaminaReading(arknights: full, endfield: GameStamina(current: 100, max: 240),
                                                          wuwa: WuwaStamina(error: "没配库街区"), takenAt: "09:00")),
            ("终末地 unreadable", StaminaReading(arknights: GameStamina(current: 80, max: 135), endfield: GameStamina(error: "读不到"),
                                               wuwa: WuwaStamina(waveplates: 240, max: 240, reserve: 0, weekly: 0, weeklyMax: 3), takenAt: "09:00")),
        ]
        let shifts: [[String]] = [["MAA", "MaaEnd", "OK-WW"], ["MAA", "OK-WW"], ["MAA"], []]
        for scripts in shifts {
            for (name, reading) in readings {
                let r = Relay.shared, s = StaminaStore.shared
                r.snap = try Self.snap(early: scripts)
                (r.statusText, r.statusState) = ("实时 · 开机中", "on")
                s.data = reading
                s.takenMs = nowMs()
                let d = StatusData.from(relay: r, live: Live.shared, stamina: s, pending: Pending.shared,
                                        currentQueue: "早班", estopAt: 0)
                let tiles = try XCTUnwrap(d.stamina, "\(scripts) \(name): no tiles")
                XCTAssertEqual(tiles.map(\.label), Self.tileOrder, "\(scripts) \(name): the tiles moved")
            }
        }
    }

    /// Where each everyday block is first drawn in StatusPage's `page` body, in source order.
    static func blockOrder(_ lines: [String]) -> [String] {
        guard let page = RepoFiles.body(after: "private var page: some View", in: lines) else { return [] }
        var seen: [String] = []
        for line in page {
            for s in StatusHomeDataTests.sections where !seen.contains(s) {
                if StatusHomeDataTests.position(of: s, in: line) != nil { seen.append(s) }
            }
        }
        return seen
    }

    func testTheBlocksKeepTheirOrder() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        XCTAssertEqual(Self.blockOrder(lines), ["actionTiles", "staminaSection", "shifts", "machineSection", "MonthCardRows(today:"],
                       "the everyday blocks of 状态 changed places")
        // the 月卡 rows: every game, in this order, registered or not
        XCTAssertEqual(MonthCardStore.games, ["明日方舟", "终末地", "鸣潮"])
        let rows = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/MonthCardRows.swift").map(RepoFiles.code)
            .joined(separator: "\n")
        XCTAssertTrue(rows.contains("ForEach(MonthCardStore.games"), "月卡 rows no longer list every game in order")
        XCTAssertFalse(rows.contains("MonthCardStore.games.filter") || rows.contains("MonthCardStore.games.sorted"),
                       "月卡 rows are filtered or reordered")
    }

    /// A page that moved 月卡 above the stamina tiles is caught.
    func testTheOrderScanSeesAMove() {
        let page = ["    private var page: some View {", "        return List {", "            actionTiles",
                    "            MonthCardRows(today: MonthCardStore.today())", "            staminaSection", "            shifts",
                    "            machineSection", "        }", "    }"]
        XCTAssertEqual(Self.blockOrder(page), ["actionTiles", "MonthCardRows(today:", "staminaSection", "shifts", "machineSection"])
    }
}
