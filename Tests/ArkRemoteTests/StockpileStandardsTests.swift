import XCTest
@testable import ArkRemote

/// The 库存 page with the 2026-10-15 need table (maa-automation needtable, two standards): the newest released six-star
/// (祀, 专武 玉中身) first, the announced one (明河, 11-05) second, and the signature weapon's essence advice.
///
/// Defects guarded:
/// - the page showed only the table's one standard, and the table had picked the announced 明河 while 祀 had gone live
///   that day, so the page had no numbers for the six-star just released; with two standards the page must default to
///   standards[0] and still reach the second.
/// - 明河 has no charId yet (""), so a key of charId alone gave her an empty picker id and made her unpickable.
/// - 明河's groups are per owner (「明河」 / 「专武 唤月」); the game-level list mirrors 祀's and would misorder hers.
/// - each advice names the one weapon to tick in MaaEnd (只勾玉中身 / 只勾唤月): only the shown standard's may appear.
///
/// The table is the real file the relay built on 2026-10-15 16:05 (Tests/Fixtures/need-1015.json); the material list is
/// 森空岛's public catalogue (skland-material-list.json). The warehouse counts are made up here (not his).
@MainActor final class StockpileStandardsTests: XCTestCase {
    static let siKey = "38bc410d7e134743ed8ee881d8400833"
    static let mingheKey = "2503"
    static let keys = [InventoryStore.standardKey + ":endfield", InventoryStore.matKey, InventoryStore.needURLKey,
                       StaminaStore.skBaseKey]

    private var saved: SharedStateGuard?
    private var savedDefaults: [(String, Any?)] = []

    override func setUp() async throws {
        saved = SharedStateGuard()
        savedDefaults = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() async throws {
        saved?.restore()
        for (k, v) in savedDefaults {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    static func fixture(_ name: String) throws -> Data {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: dir.appendingPathComponent("Fixtures").appendingPathComponent(name))
    }

    /// Made-up counts for every row of every standard: a third twice the need, a third half of it, the rest 1.2 times.
    static func counts(_ table: JSONValue) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        var i = 0
        for s in table["games"]?[0]?["standards"]?.array ?? [] {
            for r in s["rows"]?.array ?? [] {
                guard let id = r["id"]?.string, !id.hasPrefix("exp:"), out[id] == nil else { continue }
                let need = Int(r["need"]?.number ?? 0)
                let have = i % 3 == 0 ? need * 2 : i % 3 == 1 ? need / 2 : need + need / 5
                out[id] = .int(have)
                i += 1
            }
        }
        return out
    }

    /// One read of the 库存 page against the fixture table and a stand-in 森空岛; returns the page and the number of
    /// 森空岛 requests made.
    private func readPage(table: Data) async throws -> (Stockpile, InventoryStore, () -> Int) {
        let j = try JSONValue.parse(table)
        let counts = Self.counts(j)
        let matBody = try Self.fixture("skland-material-list.json")
        var asked = 0
        StaminaStore.shared.tokens = .object(["sk": .object(["cred": .string("c"), "token": .string("t"), "dId": .string("d"), "efRole": .string("1"), "efServer": .string("1")])])
        StaminaStore.shared.fetch = { url, _, _, _, _ in
            asked += 1
            if url.contains("/auth/refresh") {
                return (Data(#"{"code":0,"data":{"token":"t"}}"#.utf8), 200)
            }
            if url.contains("user-game-data") {
                let body = JSONValue.object(["code": .int(0), "data": .object(["userGameData": .object(["itemCount": .object(counts)])])])
                return (body.encoded(), 200)
            }
            if url.contains("material-list") {
                return (Data(#"{"code":0,"data":"#.utf8) + matBody + Data("}".utf8), 200)
            }
            throw AppError("unexpected \(url)")
        }
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (table, 200) }
        let page = Stockpile()
        page.loader = { force in
            guard let r = await inv.refresh(force: force) else { throw AppError("没有读数") }
            return try JSONValue.parse(try JSONEncoder().encode(r))
        }
        page.picker = { key in
            inv.setStandard(key)
            guard let r = inv.repick() else { return nil }
            return try? JSONValue.parse(try JSONEncoder().encode(r))
        }
        await page.load(force: true)
        return (page, inv, { asked })
    }

    private func essenceText(_ t: StockTop?) -> String {
        guard let e = t?.essence else { return "" }
        return ([e.header, e.pointsTitle, e.points ?? "", e.footer ?? ""] + e.terms.map { $0.slot + $0.name }).joined(separator: "|")
    }

    func testNewestReleasedFirstAnnouncedSecond() async throws {
        let (page, _, _) = try await readPage(table: try Self.fixture("need-1015.json"))
        guard case .list(let sections, let foot) = page.content else { return XCTFail("not a list: \(page.content)") }
        let top = try XCTUnwrap(page.top)
        XCTAssertEqual(top.choices.map(\.title), ["祀", "明河"])
        XCTAssertEqual(top.choices.map(\.id), [Self.siKey, Self.mingheKey])
        XCTAssertEqual(top.selected, Self.siKey)
        XCTAssertEqual(top.caption, "最新六星，10-15 上线，专武 玉中身。下一位：明河（11-05 上线）")
        XCTAssertEqual(sections.map(\.name).prefix(7), ["干员精英化", "干员技能升级", "干员技能专精", "干员等级提升", "武器突破", "武器等级提升", "多处共用"])
        XCTAssertTrue(foot.contains { $0.hasPrefix("一人所需 = 最新六星 祀（2026-10-15 上线）") }, "\(foot)")
        XCTAssertFalse(foot.contains { $0.hasPrefix("下一位") }, "the next one is in the caption already: \(foot)")
    }

    func testEssenceAdviceForTheShownWeaponOnly() async throws {
        let (page, _, _) = try await readPage(table: try Self.fixture("need-1015.json"))
        let e = try XCTUnwrap(page.top?.essence)
        XCTAssertEqual(e.header, "基质刷取 · 玉中身")
        XCTAssertEqual(e.terms, [StockTerm(slot: "基础属性", name: "智识提升"), StockTerm(slot: "附加属性", name: "寒冷伤害提升"),
                                 StockTerm(slot: "技能属性", name: "效益")])
        XCTAssertEqual(e.pointsTitle, "重度能量淤积点")
        XCTAssertEqual(e.points, "枢纽区、源石研究园、矿脉源区、藏剑谷、应龙关")
        XCTAssertEqual(e.footer, "MaaEnd「基质刷取」切到「目标选择」、只勾玉中身：它自己挑地方、自己预刻写，背包里有了对得上的基质就停")
        XCTAssertFalse(essenceText(page.top).contains("唤月"), essenceText(page.top))
        guard case .list(_, let foot) = page.content else { return XCTFail("not a list") }
        XCTAssertTrue(foot.contains("基质词条和掉落地点取自 MaaEnd 的数据（2026-10-08 版）"), "\(foot)")
    }

    /// Picking 明河 shows her numbers, her own section order and 唤月's advice, from the same read (no new request).
    func testPickingTheNextOneReusesTheRead() async throws {
        let (page, inv, asked) = try await readPage(table: try Self.fixture("need-1015.json"))
        let before = asked()
        XCTAssertGreaterThan(before, 0)
        await page.pick(Self.mingheKey)
        XCTAssertEqual(asked(), before, "switching must not ask 森空岛 again")
        XCTAssertEqual(inv.chosenStandard(), Self.mingheKey)
        guard case .list(let sections, let foot) = page.content else { return XCTFail("not a list") }
        XCTAssertEqual(page.top?.selected, Self.mingheKey)
        XCTAssertEqual(page.top?.caption, "下一位六星，11-05 上线，专武 唤月")
        XCTAssertEqual(Array(sections.map(\.name).prefix(3)), ["明河", "专武 唤月", "明河 + 专武 唤月"])
        XCTAssertEqual(page.top?.essence?.header, "基质刷取 · 唤月")
        XCTAssertEqual(page.top?.essence?.points, "源石研究园、供能高地、首墩、应龙关")
        XCTAssertFalse(essenceText(page.top).contains("玉中身"), essenceText(page.top))
        XCTAssertTrue(foot.contains("明河：上线前按客户端预览表，棱柱和折金票含天赋树"), "\(foot)")
        XCTAssertTrue(foot.contains { $0.hasPrefix("一人所需 = 下一位六星 明河") }, "\(foot)")
        // and back
        await page.pick(Self.siKey)
        XCTAssertEqual(page.top?.essence?.header, "基质刷取 · 玉中身")
        XCTAssertEqual(asked(), before)
    }

    /// standardFor unchanged: nothing picked lands on `standard` (祀); a stored pick of 明河 (her wikiItemId) is honoured.
    func testStandardKeysAndDefault() throws {
        let inv = InventoryStore()
        inv.need = try JSONValue.parse(try Self.fixture("need-1015.json"))
        XCTAssertEqual(inv.standards().map(\.id), [Self.siKey, Self.mingheKey])
        XCTAssertEqual(inv.shell().game.standard?.name, "祀")
        XCTAssertEqual(inv.shell().game.useSource?.hasPrefix("用途按森空岛养成计算器"), true)
        inv.setStandard(Self.mingheKey)
        let g = inv.shell().game
        XCTAssertEqual(g.standard?.name, "明河")
        XCTAssertEqual(g.groups, ["明河", "专武 唤月", "明河 + 专武 唤月"])
        XCTAssertEqual(g.useSource, "", "明河's own empty useSource, not 祀's")
        XCTAssertEqual(g.next?.name, "明河")
    }

    /// A table from before 2026-10-15 (one standard, no role / label / essence / coverage.next) renders as before.
    func testOldTableStillRenders() throws {
        let g = try JSONValue.parse(Data("""
        {"game": "终末地", "gameId": "endfield", "caliber": "最新六星 明河（2026-11-05 上线）", "built": "2026-10-14 03:36 UTC+8",
         "groups": ["养成"], "standard": {"charId": "", "name": "明河", "weapon": "唤月"},
         "standards": [{"charId": "", "name": "明河", "weapon": "唤月", "key": ""}],
         "rows": [{"id": "a", "name": "x", "group": "养成", "have": 3, "need": 10, "servings": 0.3}]}
        """.utf8))
        XCTAssertNil(Stockpile.top(g))
        guard case .list(let sections, let foot) = Stockpile.list(g, .object([:]), err: "") else { return XCTFail("not a list") }
        XCTAssertEqual(sections.map(\.name), ["养成"])
        XCTAssertFalse(foot.contains { $0.contains("下一位") || $0.contains("基质") }, "\(foot)")
    }

    /// The old shape through the store: no next, no essence, groups from the game.
    func testOldTableThroughTheStore() throws {
        let inv = InventoryStore()
        inv.need = try JSONValue.parse(Data("""
        {"built": "2026-10-14 03:36 UTC+8", "games": [{"gameId": "endfield", "groups": ["养成"], "standard": "c1",
         "standards": [{"charId": "c1", "name": "明河", "weapon": {"name": "唤月"}, "rows": [{"id": "a", "group": "养成", "need": 1}]}]}]}
        """.utf8))
        let g = inv.shell().game
        XCTAssertNil(g.next)
        XCTAssertNil(g.standard?.essence)
        XCTAssertEqual(g.groups, ["养成"])
        XCTAssertEqual(g.standards.map(\.id), ["c1"])
    }

    /// The second standard failed to build: no picker, the footer names her and why.
    func testNextErrorInTheFooter() throws {
        var j = try JSONValue.parse(try Self.fixture("need-1015.json"))
        guard case .object(var root) = j, case .array(var games)? = root["games"], case .object(var g0) = games[0],
              case .array(let stds)? = g0["standards"], case .object(var cov)? = g0["coverage"] else { return XCTFail("shape") }
        g0["standards"] = .array([stds[0]])
        cov["nextError"] = .string("预览表里没有她")
        g0["coverage"] = .object(cov)
        games[0] = .object(g0)
        root["games"] = .array(games)
        j = .object(root)
        let inv = InventoryStore()
        inv.need = j
        var game = inv.shell().game
        game.rows = []
        let enc = try JSONValue.parse(try JSONEncoder().encode(game))
        XCTAssertEqual(Stockpile.top(enc)?.choices, [], "one standard: no picker")
        XCTAssertNotNil(Stockpile.top(enc)?.essence)
        var withRow = enc
        if case .object(var o) = withRow {
            o["rows"] = .array([.object(["id": .string("a"), "name": .string("x"), "group": .string("干员精英化"), "have": .int(3),
                                          "need": .int(10), "servings": .double(0.3)])])
            withRow = .object(o)
        }
        guard case .list(_, let foot) = Stockpile.list(withRow, .object([:]), err: "") else { return XCTFail("not a list") }
        XCTAssertTrue(foot.contains("下一位：明河（11-05 上线），她的用量这次没算出来：预览表里没有她"), "\(foot)")
    }

    /// An essence without terms (weapon not in MaaEnd's data): no advice section, the reason in the footer.
    func testEssenceWithoutTermsShowsOnlyTheReason() throws {
        let e = InventoryStore.essence(try JSONValue.parse(Data(#"{"weapon": "唤月", "terms": null, "points": null, "reason": "MaaEnd 的数据里还没有唤月"}"#.utf8)))
        XCTAssertNil(e.advice)
        XCTAssertEqual(e.reason, "MaaEnd 的数据里还没有唤月")
        XCTAssertNil(InventoryStore.essence(try JSONValue.parse(Data(#"{"terms": []}"#.utf8))).advice)
        let g = try JSONValue.parse(Data("""
        {"standard": {"name": "明河", "essenceReason": "MaaEnd 的数据里还没有唤月"},
         "rows": [{"id": "a", "name": "x", "group": "养成", "have": 3, "need": 10, "servings": 0.3}]}
        """.utf8))
        XCTAssertNil(Stockpile.top(g))
        guard case .list(_, let foot) = Stockpile.list(g, .object([:]), err: "") else { return XCTFail("not a list") }
        XCTAssertTrue(foot.contains("基质刷取建议这次没有：MaaEnd 的数据里还没有唤月"), "\(foot)")
    }

    /// The replay test's stand-ins are taken only on this machine's loopback (or the Android emulator's alias of it).
    func testLoopbackOverridesOnly() async throws {
        UserDefaults.standard.set("http://127.0.0.1:8933", forKey: StaminaStore.skBaseKey)
        XCTAssertEqual(StaminaStore.zonai, "http://127.0.0.1:8933")
        UserDefaults.standard.set("https://evil.example.com", forKey: StaminaStore.skBaseKey)
        XCTAssertEqual(StaminaStore.zonai, "https://zonai.skland.com")
        UserDefaults.standard.removeObject(forKey: StaminaStore.skBaseKey)
        XCTAssertEqual(StaminaStore.zonai, "https://zonai.skland.com")

        Relay.shared.config = RelayConfig(topic: "ark-test-topic", pin: "1")
        let inv = InventoryStore()
        var asked: [String] = []
        inv.fetchNeed = { url in asked.append(url); return (Data(#"{"games": []}"#.utf8), 200) }
        UserDefaults.standard.set("http://10.0.2.2:8933/need.json", forKey: InventoryStore.needURLKey)
        _ = try await inv.loadNeed()
        XCTAssertEqual(asked, ["http://10.0.2.2:8933/need.json"])
        asked = []
        UserDefaults.standard.set("https://example.com/need.json", forKey: InventoryStore.needURLKey)
        _ = try await inv.loadNeed()
        XCTAssertEqual(asked, [Relay.needURL(topic: "ark-test-topic")])
    }

    func testMonthDayAndCaveat() {
        XCTAssertEqual(Stockpile.monthDay("2026-11-05"), "11-05")
        XCTAssertEqual(Stockpile.monthDay("待定"), "待定")
        XCTAssertEqual(Stockpile.caveat("人份 = 库存 ÷ 明河满练所需（…；2026-11-05 上线的下一位六星）（上线前按客户端预览表，棱柱和折金票含天赋树）"),
                       "上线前按客户端预览表，棱柱和折金票含天赋树")
        XCTAssertNil(Stockpile.caveat("人份 = 库存 ÷ 祀满练所需（1→90 全突破；2026-10-15 上线的最新六星）"))
        XCTAssertNil(Stockpile.caveat(nil))
    }
}
