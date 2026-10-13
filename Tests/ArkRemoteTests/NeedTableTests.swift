import XCTest
@testable import ArkRemote

/// The 库存 page's need table stayed at the newest six-star of 09-23: it was only rebuilt when someone ran a script on
/// the Mac. The relay now rebuilds it every server day and puts it next to the phone state on COS (maa-automation
/// relay/ark_relay/features/needtable/needtable.py); the App reads that copy first, the old deployed one only when it
/// cannot, and the footer says on which day the table was built.
@MainActor final class NeedTableTests: XCTestCase {
    private let table = #"{"built": "2026-10-14 03:36 UTC+8", "games": [{"gameId": "endfield", "rows": []}]}"#
    private let old = #"{"built": "2026-09-23 09:26 JST", "games": [{"gameId": "endfield", "rows": []}]}"#

    /// The relay's key: `state/` + the state's 32 hex + `.need.json`; the same hex is pinned in the relay's
    /// tests/test_needtable_publish.py for "ark-test-topic".
    func testNeedURLIsNextToTheState() {
        XCTAssertEqual(Relay.needURL(topic: "ark-test-topic"),
                       "\(cosBase)/state/d980719e5e0b17d6d61cc31f7b36a714.need.json")
        XCTAssertEqual(Relay.needURL(topic: " Ark-Test-Topic "), Relay.needURL(topic: "ark-test-topic"))
    }

    /// With a topic, the relay's copy is read and the old deployed one is not asked.
    func testRelayCopyFirst() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        Relay.shared.config = RelayConfig(topic: "ark-test-topic", pin: "1")
        let store = InventoryStore()
        var asked: [String] = []
        let body = table
        store.fetchNeed = { url in asked.append(url); return (Data(body.utf8), 200) }
        let j = try await store.loadNeed()
        XCTAssertEqual(asked, [Relay.needURL(topic: "ark-test-topic")])
        XCTAssertEqual(j["built"]?.string, "2026-10-14 03:36 UTC+8")
    }

    /// No copy on COS yet (an older relay: 404): the old deployed table, as before.
    func testFallsBackToTheDeployedCopy() async throws {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        Relay.shared.config = RelayConfig(topic: "ark-test-topic", pin: "1")
        let store = InventoryStore()
        var asked: [String] = []
        let body = old
        store.fetchNeed = { url in
            asked.append(url)
            return url == InventoryStore.needURL ? (Data(body.utf8), 200) : (Data("<Error/>".utf8), 404)
        }
        let j = try await store.loadNeed()
        XCTAssertEqual(asked, [Relay.needURL(topic: "ark-test-topic"), InventoryStore.needURL])
        XCTAssertEqual(j["built"]?.string, "2026-09-23 09:26 JST")
    }

    /// No topic set up: only the deployed copy; both failing reports the last error.
    func testNoTopicAndBothFailing() async {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        Relay.shared.config = nil
        let store = InventoryStore()
        var asked: [String] = []
        store.fetchNeed = { url in asked.append(url); return (Data(), 503) }
        do {
            _ = try await store.loadNeed()
            XCTFail("no table should have been read")
        } catch {
            XCTAssertEqual(errorMessage(error), "需求表拿不到（503）")
        }
        XCTAssertEqual(asked, [InventoryStore.needURL])
    }

    /// The footer says on which day the table was built, in both stamp formats; nothing without a date.
    func testFooterSaysTheBuildDay() throws {
        XCTAssertEqual(Stockpile.builtLine("2026-10-14 03:36 UTC+8"), "需求表 10月14日 核对过最新六星")
        XCTAssertEqual(Stockpile.builtLine("2026-09-23 09:26 JST"), "需求表 9月23日 核对过最新六星")
        XCTAssertNil(Stockpile.builtLine(nil))
        XCTAssertNil(Stockpile.builtLine("fixture"))
        let g = try JSONValue.parse(Data("""
        {"built": "2026-10-14 03:36 UTC+8", "caliber": "最新六星 明河（2026-11-05 上线）",
         "rows": [{"id": "a", "name": "x", "group": "养成", "have": 3, "need": 10, "servings": 0.3}]}
        """.utf8))
        guard case .list(_, let foot) = Stockpile.list(g, .object([:]), err: "") else { return XCTFail("not a list") }
        XCTAssertTrue(foot.contains("需求表 10月14日 核对过最新六星"), "\(foot)")
        XCTAssertEqual(foot.firstIndex(of: "需求表 10月14日 核对过最新六星"), foot.firstIndex { $0.hasPrefix("一人所需") }.map { $0 + 1 })
    }
}
