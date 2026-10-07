import XCTest
@testable import ArkRemote

/// The machine ran while the App said 「关机 · 最后心跳 22:34」: ntfy's daily quota was used up (HTTP 429), so the
/// heartbeats on ntfy were refused. The relay's heartbeat on COS counts as a beat (Live.readCosHb, 9053daa), and a 429
/// is not taken for a lost network (Live.isNetwork, beb6945).
@MainActor final class OnlineCosHeartbeatTests: XCTestCase {
    private func hb(_ json: String) -> (String) async throws -> (Data, Int) {
        { _ in (Data(json.utf8), 200) }
    }

    private func relay() -> Relay {
        let r = Relay()
        r.config = RelayConfig(topic: "t", pin: "1")   // assigned, not saveConfig: nothing written to UserDefaults
        r.snap = nil
        return r
    }

    /// A fresh heartbeat on COS reads as on, with no ntfy beat at all.
    func testFreshCosHeartbeatReadsAsOn() async {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let r = relay()
        r.fetchHb = hb(#"{"at": \#(nowSec() - 5), "every": 30, "cos_every": 30}"#)
        let live = Live(relay: r)

        await live.readCosHb()
        XCTAssertTrue(live.alive)
        XCTAssertTrue(r.statusText.hasPrefix("开机中"), r.statusText)
        XCTAssertTrue(live.cosHbSeen)
    }

    /// One older than 2 × cos_every + 30 s does not count: a machine whose power was cut must not read as on.
    func testStaleCosHeartbeatReadsAsOff() async {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let r = relay()
        r.fetchHb = hb(#"{"at": \#(nowSec() - (2 * 30 + 30 + 10)), "every": 30, "cos_every": 30}"#)
        let live = Live(relay: r)

        await live.readCosHb()
        XCTAssertFalse(live.alive)
        XCTAssertEqual(live.lastHb, 0)
        XCTAssertTrue(r.statusText.hasPrefix("关机"), r.statusText)
    }

    /// The relay's goodbye on a service stop ends a beat it counted before.
    func testByeEndsTheBeat() async {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let r = relay()
        r.fetchHb = hb(#"{"at": \#(nowSec() - 5), "every": 30, "cos_every": 30}"#)
        let live = Live(relay: r)
        await live.readCosHb()
        XCTAssertTrue(live.alive)

        r.fetchHb = hb(#"{"at": \#(nowSec()), "bye": true}"#)
        await live.readCosHb()
        XCTAssertEqual(live.lastHb, 0)
        XCTAssertFalse(live.alive)
    }

    /// No heartbeat object (an older relay, no COS) leaves the verdict alone.
    func testMissingCosHeartbeatChangesNothing() async {
        let saved = SharedStateGuard()
        defer { saved.restore() }
        let r = relay()
        r.fetchHb = { _ in (Data(), 404) }
        let live = Live(relay: r)

        await live.readCosHb()
        XCTAssertFalse(live.cosHbSeen)
        XCTAssertEqual(live.lastHb, 0)
    }

    /// ntfy's 429 (what Relay.send throws for it, either limit) is not this side's network, so the line does not say
    /// 「先看看你这边有没有网」 while the machine runs.
    func testNtfyLimitIsNotANetworkFailure() {
        XCTAssertFalse(Live.isNetwork(NtfyLimit(daily: true)))
        XCTAssertFalse(Live.isNetwork(NtfyLimit(daily: false)))
        XCTAssertFalse(Live.isNetwork(AppError("HTTP 429")))
        // and a real lost network still is
        XCTAssertTrue(Live.isNetwork(URLError(.notConnectedToInternet)))
    }
}
