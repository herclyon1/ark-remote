import XCTest
@testable import ArkRemote

/// The 库存 page when the need table (data/need.json) cannot be read: it must say the table is what is missing,
/// not 「森空岛没有返回仓库数据。」 (Logic/Inventory.swift refresh, Logic/Stockpile.swift paint).
@MainActor final class InventoryNeedTests: XCTestCase {
    static let wrongLine = "森空岛没有返回仓库数据。"

    /// refresh() with the table fetch failing and a 森空岛 session stored: the game carries the table's error,
    /// and 森空岛 is not asked.
    func testRefreshReportsTheNeedTable() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(), 404) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object(["sk": .object(["efRole": .string("1")])])
        defer { StaminaStore.shared.tokens = saved }

        let r = await inv.refresh(force: true)
        let g = r?.games.first
        XCTAssertNil(inv.need)
        XCTAssertEqual(inv.err, "需求表拿不到（404）")
        XCTAssertTrue(g?.error.contains("需求表") ?? false, g?.error ?? "no game")
        XCTAssertFalse(g?.error.contains(Self.wrongLine) ?? true)
        XCTAssertTrue(g?.rows.isEmpty ?? false)
    }

    /// No 森空岛 session still says so first: that is the state the user can act on.
    func testNoSessionStillWins() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(), 404) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object([:])
        defer { StaminaStore.shared.tokens = saved }

        let r = await inv.refresh(force: true)
        XCTAssertEqual(r?.games.first?.error, "没配森空岛")
    }

    /// A later good read clears the table error.
    func testErrorClearsOnNextRead() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(), 500) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object([:])
        defer { StaminaStore.shared.tokens = saved }
        _ = await inv.refresh(force: true)
        XCTAssertFalse(inv.err.isEmpty)
        inv.fetchNeed = { _ in (Data(#"{"built":"t","games":[]}"#.utf8), 200) }
        _ = await inv.refresh(force: true)
        XCTAssertEqual(inv.err, "")
    }

    /// What the page shows for that reading: the 读不到库存 state with the table's sentence and 重试.
    func testPageShowsTheNeedTableLine() async throws {
        let game = InventoryStore.needMissing("需求表拿不到（404）")
        let reading = InventoryReading(takenAt: "01:40", games: [game])
        let json = try JSONValue.parse(try JSONEncoder().encode(reading))
        let page = Stockpile()
        page.loader = { _ in json }
        await page.load(force: true)
        guard case let .empty(title, text, button, action) = page.content else {
            return XCTFail("expected the empty state, got \(page.content)")
        }
        XCTAssertEqual(title, "读不到库存")
        XCTAssertEqual(text, "这次是需求表没拿到（不是森空岛回报的），算不出人份：需求表拿不到（404）")
        XCTAssertEqual(button, "重试")
        XCTAssertEqual(action, .retry)
        XCTAssertNotEqual(page.content, .zero(Self.wrongLine))
    }

    static let endfieldTable = #"{"built":"t","games":[{"gameId":"endfield","rows":[{"id":"a","name":"A","need":3,"group":"g"}]}]}"#

    /// A table that was read but has no 终末地 entry: the game says so, and 森空岛 is not asked
    /// (efRole is set, so asking would have gone to the network and come back with a 森空岛 error).
    func testTableWithoutEndfield() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(#"{"built":"t","games":[]}"#.utf8), 200) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object(["sk": .object(["efRole": .string("1")])])
        defer { StaminaStore.shared.tokens = saved }

        let g = await inv.refresh(force: true)?.games.first
        XCTAssertEqual(g?.error, "需求表拿到了，但里面没有终末地这一项（不是森空岛回报的），算不出人份")
        XCTAssertTrue(g?.rows.isEmpty ?? false)
    }

    /// The 终末地 entry is there but has no rows: same, naming the missing rows.
    func testEndfieldEntryWithoutRows() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(#"{"built":"t","games":[{"gameId":"endfield","rows":[]}]}"#.utf8), 200) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object(["sk": .object(["efRole": .string("1")])])
        defer { StaminaStore.shared.tokens = saved }

        let g = await inv.refresh(force: true)?.games.first
        XCTAssertEqual(g?.error, "需求表里终末地这一项没有材料（不是森空岛回报的），算不出人份")
    }

    /// The page for that game: 读不到库存 with the table's sentence, not 「森空岛没有返回仓库数据。」.
    func testPageShowsTheMissingEntry() async throws {
        let reading = InventoryReading(takenAt: "02:10", games: [InventoryStore.needLacks("需求表拿到了，但里面没有终末地这一项")])
        let json = try JSONValue.parse(try JSONEncoder().encode(reading))
        let page = Stockpile()
        page.loader = { _ in json }
        await page.load(force: true)
        XCTAssertEqual(page.content, .empty(title: "读不到库存", text: "需求表拿到了，但里面没有终末地这一项（不是森空岛回报的），算不出人份",
                                            button: "重试", action: .retry))
    }

    /// A table read earlier, this fetch failing: the game carries a note with the failure and when the old table was read.
    /// efRole is empty so the 森空岛 part stops before the network.
    func testStaleTableIsNoted() async {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in (Data(Self.endfieldTable.utf8), 200) }
        let saved = StaminaStore.shared.tokens
        StaminaStore.shared.tokens = .object(["sk": .object(["efRole": .string("")])])
        defer { StaminaStore.shared.tokens = saved }

        let first = await inv.refresh(force: true)?.games.first
        XCTAssertNil(first?.needNote)
        let readAt = inv.needAt
        XCTAssertGreaterThan(readAt, 0)
        inv.fetchNeed = { _ in (Data(), 500) }
        let g = await inv.refresh(force: true)?.games.first
        XCTAssertNotNil(inv.need)
        XCTAssertEqual(inv.needAt, readAt)
        XCTAssertEqual(g?.needNote, "需求表这次没拿到（需求表拿不到（500）），人份按 \(clockHHMM(ms: readAt)) 拿到的旧表算")
    }

    /// The note survives encoding (InventoryGame has explicit CodingKeys) and the page shows it under the list.
    func testPageShowsTheStaleNote() async throws {
        var game = InventoryGame(game: "终末地", gameId: "endfield")
        game.needNote = "需求表这次没拿到（需求表拿不到（500）），人份按 01:00 拿到的旧表算"
        let encoded = try JSONValue.parse(try JSONEncoder().encode(game))
        XCTAssertEqual(encoded["needNote"]?.jsString, game.needNote)
        let json = try JSONValue.parse(Data(#"{"取自":"02:10","games":[{"game":"终末地","gameId":"endfield","错误":"","needNote":"\#(game.needNote!)","rows":[{"id":"a","name":"A","group":"g","have":1,"need":3,"servings":0.3,"box":0,"short":2}]}]}"#.utf8))
        let page = Stockpile()
        page.loader = { _ in json }
        await page.load(force: true)
        guard case let .list(_, foot) = page.content else { return XCTFail("expected the list, got \(page.content)") }
        XCTAssertEqual(foot.first, "02:10 从森空岛读取")
        XCTAssertEqual(foot.dropFirst().first, game.needNote)
    }

    /// Older than today: the date goes in front of the time.
    func testReadAtOlderThanToday() {
        let ms = Date().addingTimeInterval(-3 * 86400).timeIntervalSince1970 * 1000
        XCTAssertTrue(InventoryStore.readAt(ms).contains("月"))
        XCTAssertEqual(InventoryStore.readAt(Date().timeIntervalSince1970 * 1000).count, 5)
    }
}
