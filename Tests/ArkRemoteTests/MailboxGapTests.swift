import XCTest
@testable import ArkRemote

/// relay.信箱空窗 (maa-automation relay/ark_relay/features/phone/phone.py mailbox_status): a change sent while the machine
/// was off past ntfy's 12 h cache was dropped before the machine read it. Its row says so with 「再发一次」 at once,
/// and the pending bar counts it, instead of 「已寄出 · 机器开机后生效」 until the 10 h mark.
@MainActor final class MailboxGapTests: XCTestCase {
    private var saved: SharedStateGuard!

    override func setUp() async throws {
        saved = SharedStateGuard()
    }

    override func tearDown() async throws {
        saved.restore()
    }

    private func snap(windows: [(Double, Double)]) -> JSONValue {
        .object(["relay": .object(["信箱空窗": .array(windows.map { .object(["从": .double($0.0), "到": .double($0.1)]) })])])
    }

    func testChangeSentInsideAWindowIsLost() {
        let now = nowSec()
        Relay.shared.clockSkewMs = 0
        Relay.shared.snap = snap(windows: [(Double(now - 3600), Double(now))])
        let p = Pending(relay: .shared)
        p.items = ["k": PendingEdit(label: "早班", src: "relay", to: .bool(true), sentAt: now - 600)]

        XCTAssertEqual(p.tag(for: "k"), .sent(text: Pending.lostText))
        XCTAssertEqual(p.staleResendKey(for: "k"), "k")
        XCTAssertEqual(p.bar?.text, "1 项改动机器没收到（关机超过 12 小时），要的话点「再发一次」")
    }

    func testChangeSentOutsideAWindowWaits() {
        let now = nowSec()
        Relay.shared.clockSkewMs = 0
        Relay.shared.snap = snap(windows: [(Double(now - 7200), Double(now - 3600))])
        let p = Pending(relay: .shared)
        p.items = ["k": PendingEdit(label: "早班", src: "relay", to: .bool(true), sentAt: now - 600)]

        XCTAssertNotEqual(p.tag(for: "k"), .sent(text: Pending.lostText))
        XCTAssertNil(p.staleResendKey(for: "k"))
        XCTAssertFalse(p.bar?.text.contains("没收到") ?? true)
    }

    /// An older relay sends no 信箱空窗: nothing counts as lost.
    func testNoWindowsNothingLost() {
        let now = nowSec()
        Relay.shared.snap = .object(["relay": .object([:])])
        let p = Pending(relay: .shared)
        p.items = ["k": PendingEdit(label: "早班", src: "relay", to: .bool(true), sentAt: now - 600)]
        XCTAssertFalse(p.isLost(p.items["k"]!))
    }
}
