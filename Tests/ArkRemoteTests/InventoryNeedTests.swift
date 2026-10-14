import XCTest
@testable import ArkRemote

/// Defect guarded: when the need table cannot be used, the 库存 page blames 森空岛. With no table (both the relay's
/// copy and the old deployed one failing), with a table that has no 终末地 entry or no rows in it, or with rows that
/// carry no group, the rows came out without a group and the page said 「森空岛没有返回仓库数据。」, sending him to
/// check the wrong thing. The page must say the table is what is missing, and 森空岛 is not asked then (nothing could
/// be worked out from its answer). Logic/Inventory.swift refresh, Logic/Stockpile.swift list; carried from origin/main
/// e053854 / b359c8e / f34b2a8 onto the two-copy loadNeed.
/// The 森空岛 session in these tests has no 终末地 role, so a read that did ask 森空岛 stops before the network.
@MainActor final class InventoryNeedTests: XCTestCase {
    static let wrongLine = "森空岛没有返回仓库数据。"
    static let noRole: JSONValue = .object(["sk": .object(["efRole": .string("")])])

    /// One refresh with `table` (nil = every copy answers 404), the reading drawn by the 库存 page.
    private func page(table: String?, tokens: JSONValue? = noRole) async throws -> (InventoryStore, InventoryGame?, StockpileContent) {
        let inv = InventoryStore()
        inv.fetchNeed = { _ in table.map { (Data($0.utf8), 200) } ?? (Data(), 404) }
        StaminaStore.shared.tokens = tokens
        let reading = await inv.refresh(force: true)
        let json = try JSONValue.parse(try JSONEncoder().encode(try XCTUnwrap(reading)))
        let page = Stockpile()
        page.loader = { _ in json }
        await page.load(force: true)
        return (inv, reading?.games.first, page.content)
    }

    func testNoTableIsNamedOnThePage() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let (inv, g, content) = try await page(table: nil)
        XCTAssertNil(inv.need)
        XCTAssertEqual(inv.err, "需求表拿不到（404）")
        XCTAssertTrue(g?.rows.isEmpty ?? false)
        XCTAssertEqual(content, .empty(title: "读不到库存", text: "这次是需求表没拿到（不是森空岛回报的），算不出人份：需求表拿不到（404）",
                                       button: "重试", action: .retry))
    }

    /// No 森空岛 session still says so first: that is the state he can act on.
    func testNoSessionStillWins() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let (_, g, _) = try await page(table: nil, tokens: .object([:]))
        XCTAssertEqual(g?.error, "没配森空岛")
    }

    /// A later good read clears the table error, so it does not leak into the next read's message.
    func testErrorClearsOnNextRead() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let inv = InventoryStore()
        StaminaStore.shared.tokens = .object([:])
        inv.fetchNeed = { _ in (Data(), 500) }
        _ = await inv.refresh(force: true)
        XCTAssertFalse(inv.err.isEmpty)
        inv.fetchNeed = { _ in (Data(#"{"built":"t","games":[]}"#.utf8), 200) }
        _ = await inv.refresh(force: true)
        XCTAssertEqual(inv.err, "")
    }

    func testTableWithoutEndfield() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let (_, g, content) = try await page(table: #"{"built":"t","games":[]}"#)
        let text = "需求表拿到了，但里面没有终末地这一项（不是森空岛回报的），算不出人份"
        XCTAssertEqual(g?.error, text)
        XCTAssertEqual(content, .empty(title: "读不到库存", text: text, button: "重试", action: .retry))
    }

    func testEndfieldEntryWithoutRows() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let (_, g, _) = try await page(table: #"{"built":"t","games":[{"gameId":"endfield","rows":[]}]}"#)
        XCTAssertEqual(g?.error, "需求表里终末地这一项没有材料（不是森空岛回报的），算不出人份")
    }

    /// A usable table still goes on to 森空岛 (here it stops at the missing role, before the network).
    func testUsableTableAsksSkland() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let (_, g, _) = try await page(table: #"{"built":"t","games":[{"gameId":"endfield","rows":[{"id":"a","name":"A","need":3,"group":"g"}]}]}"#)
        XCTAssertEqual(g?.error, "密钥串里没有终末地的角色")
    }

    /// Rows came back but none carries a group: the page says the table's grouping does not match, not that 森空岛
    /// returned nothing.
    func testUngroupedRowsBlameTheTable() async throws {
        let json = try JSONValue.parse(Data(#"{"取自":"02:40","games":[{"game":"终末地","gameId":"endfield","错误":"","rows":[{"id":"a","name":"A","have":5,"need":null}]}]}"#.utf8))
        let page = Stockpile()
        page.loader = { _ in json }
        await page.load(force: true)
        XCTAssertEqual(page.content, .zero("需求表里终末地的材料都没有分组，和这次读到的库存对不上（不是森空岛回报的），列不出来"))
        XCTAssertNotEqual(page.content, .zero(Self.wrongLine))
    }
}
