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
}
