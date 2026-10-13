import XCTest
@testable import ArkRemote

/// Regression 0108 #25: 10-07 17:40 「你首页那个不应该把信息数据都显示出来吗？目前你把哪些信息放到了第二层。」 (and owner
/// decisions S4 / S8: the read-only numbers stay on 状态). The everyday numbers are on the 状态 page itself, whether the
/// machine is on, off, or its config cannot be read: the three stamina tiles (理智 ×2, 波片 with 鸣潮's 周本), the
/// shift's 下一趟 and its plan, the two 机器 switches and each game's 月卡 days.
/// Two halves: the page data (StatusData.from) carries them in all three states, and the page's List draws their
/// sections with no condition on the machine's state (a section hidden off-line, or moved behind a row, goes red).
@MainActor final class StatusHomeDataTests: XCTestCase {
    enum State: CaseIterable { case on, off, unreadable }

    static func snap(_ state: State, monthCardLast: String) throws -> JSONValue {
        let config = state == .unreadable ? #"{"_错误": "AUTO-MAS 没在运行"}"# : #"{"MAA": {"关卡": "1-7"}}"#
        return try JSONValue.parse("""
            {"at": \(Int(nowMs() / 1000) - 60),
             "config": \(config),
             "queues": [{"名": "早班", "定时": true, "脚本": ["MAA", "MaaEnd", "OK-WW"]},
                        {"名": "晚班", "定时": true, "脚本": ["MAA"]}],
             "plan": "🕘 04:00\\n▸ 明日方舟\\n刷 1-7\\n▸ 终末地\\n▸ 鸣潮\\n🕘 16:00\\n▸ 明日方舟\\n刷 CE-6",
             "relay": {"下次别关机": true, "调试模式": "2026-10-14 23:30", "最近指令": [],
                       "月卡": {"终末地": {"最后领取": "\(monthCardLast)"}}}}
            """)
    }

    static func reading(_ state: State) -> StaminaReading {
        if state == .unreadable {
            return StaminaReading(arknights: GameStamina(error: "读不到"), endfield: GameStamina(error: "读不到"),
                                  wuwa: WuwaStamina(error: "读不到"), takenAt: "09:00")
        }
        return StaminaReading(arknights: GameStamina(current: 80, max: 135), endfield: GameStamina(current: 100, max: 240),
                              wuwa: WuwaStamina(waveplates: 120, max: 240, reserve: 30, weekly: 2, weeklyMax: 3),
                              takenAt: "09:00")
    }

    func testEveryNumberInEveryState() throws {
        let guardState = SharedStateGuard()
        let savedCards = UserDefaults.standard.object(forKey: MonthCardStore.localKey)
        defer {
            guardState.restore()
            if let savedCards { UserDefaults.standard.set(savedCards, forKey: MonthCardStore.localKey) }
            else { UserDefaults.standard.removeObject(forKey: MonthCardStore.localKey) }
        }
        let last = MonthCardStore.plus(MonthCardStore.today(), 12)
        for state in State.allCases {
            let r = Relay.shared, s = StaminaStore.shared
            r.snap = try Self.snap(state, monthCardLast: last)
            (r.statusText, r.statusState) = state == .off ? ("关机 · 20 分钟前", "off") : ("实时 · 开机中", "on")
            s.data = Self.reading(state)
            s.takenMs = nowMs()
            let d = StatusData.from(relay: r, live: Live.shared, stamina: s, pending: Pending.shared,
                                    currentQueue: "早班", estopAt: 0)
            let tiles = try XCTUnwrap(d.stamina, "\(state): no stamina tiles")
            XCTAssertEqual(tiles.map(\.label), ["明日方舟 理智", "终末地 理智", "鸣潮 波片"], "\(state)")
            if state == .unreadable {
                XCTAssertEqual(tiles.compactMap(\.error).count, 3, "\(state): the tiles say they could not read")
            } else {
                XCTAssertEqual(tiles.map(\.value), [80, 100, 120], "\(state)")
                XCTAssertTrue(tiles[2].sub.contains("周本 2/3"), "\(state): 鸣潮 周本 missing from \(tiles[2].sub)")
            }
            XCTAssertEqual(d.nextAt, "04:00", "\(state): 下一趟")
            XCTAssertEqual(d.plan.first { $0.queueName == "早班" }?.games.map(\.name), ["明日方舟", "终末地", "鸣潮"], "\(state)")
            XCTAssertTrue(d.skipShutdown, "\(state): 下次跑完不关机")
            XCTAssertNotNil(d.debugModeUntil, "\(state): 调试模式")
            XCTAssertEqual(d.machineOff, state == .off)
            XCTAssertEqual(d.configUnreadable, state == .unreadable)
            let cards = MonthCardStore()
            cards.records = [:]
            XCTAssertEqual(cards.entry("终末地")?.left, 12, "\(state): 月卡 days")
        }
    }

    /// The `page` List draws these sections unconditionally, in this order.
    static let sections = ["actionTiles", "staminaSection", "thisShift", "machineSection", "MonthCardRows(today:", "tomorrow"]
    /// What would hide a section by the machine's state.
    static let stateFlags = ["data.online", "data.machineOff", "data.dotOn", "data.configUnreadable", "data.configIsStale"]

    /// The problems in StatusPage's page body and section bodies.
    static func hidden(_ lines: [String]) -> [String] {
        guard let page = RepoFiles.body(after: "private var page: some View", in: lines) else { return ["page is gone"] }
        var out: [String] = []
        var at = 0
        for s in sections {
            guard let i = page.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(s) }) else {
                out.append("\(s) is not drawn on the page itself"); continue
            }
            if i < at { out.append("\(s) moved") }
            at = i
            // directly in the List: indented as its other rows (a wrapping `if` / Group indents it further)
            if !page[i].hasPrefix("            \(s)") || page[i].hasPrefix("             ") { out.append("\(s) is wrapped") }
        }
        for s in ["actionTiles", "staminaSection", "thisShift", "machineSection", "tomorrow"] {
            guard let body = RepoFiles.body(after: "private var \(s): some View", in: lines) else { out.append("\(s) is gone"); continue }
            // the 机器 section's footer may warn that the config is unreadable; nothing may hide the section
            let head = body.prefix { !$0.contains("} footer: {") }
            for f in stateFlags where head.contains(where: { $0.contains(f) }) { out.append("\(s) depends on \(f)") }
        }
        return out
    }

    func testThePageShowsThemOnTheFirstLayer() throws {
        let lines = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/StatusPage.swift")
        XCTAssertEqual(Self.hidden(lines), [])
        let rows = try RepoFiles.lines("Sources/ArkRemote/Pages/Status/MonthCardRows.swift").map(RepoFiles.code)
            .joined(separator: "\n")
        XCTAssertTrue(rows.contains("ForEach(MonthCardStore.games"), "月卡 rows no longer list every game")
        XCTAssertTrue(rows.contains("Text(MonthCardStore.line(e))"), "月卡 rows no longer show the days")
    }

    func testTheScanSeesAHiddenSection() {
        let page = ["    private var page: some View {", "        return List {", "            actionTiles", "            staminaSection",
                    "            thisShift", "            if data.online {", "                machineSection", "            }",
                    "            MonthCardRows(today: MonthCardStore.today())", "            tomorrow", "        }", "    }",
                    "    private var actionTiles: some View { Section { } }", "    private var staminaSection: some View { Section { } }",
                    "    private var thisShift: some View { Section { } }",
                    "    private var machineSection: some View {", "        Section { } footer: {", "            if data.configUnreadable { }",
                    "        }", "    }",
                    "    private var tomorrow: some View { listSection(\"t\", if: !data.machineOff) { } }"]
        XCTAssertEqual(Self.hidden(page), ["machineSection is wrapped", "tomorrow depends on data.machineOff"])
    }
}
