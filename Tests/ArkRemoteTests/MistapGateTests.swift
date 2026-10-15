import XCTest
@testable import ArkRemote

/// The review sheet's 400 ms gate (SaveBar.swift MistapGate, view.js:1619 / 2953-2955). Defect guarded (0.5.2 r3
/// and-final5, 026-gate.late.png 「1 项改动已寄给机器」): on a busy emulator a press that touched down inside the
/// first 400 ms sent skip_today, because the gate ran from when the sheet was built (onAppear) to when the main thread
/// handled the press, and a slow main thread moved both. It now runs from the sheet's first drawn frame to the press's
/// own touch-down time. The replay steps gate.early / gate.trials (scripts/replay/steps.py) press it on a device.
final class MistapGateTests: XCTestCase {
    func testAPressThatTouchedDownEarlyIsHeldHoweverLateItIsHandled() {
        // sheet drawn at 1000; the finger went down 150 ms later, the app only got to the press at +900
        XCTAssertFalse(MistapGate.allows(shownAt: 1000, downAt: 1150, now: 1900))
    }

    func testTheGateCountsFromTheFirstFrameNotFromWhenTheSheetWasBuilt() {
        // built (onAppear) at 1000, first on screen at 1500: a press 600 ms after the build is 100 ms after the frame
        let built = 1000.0, drawn = 1500.0, down = 1600.0
        XCTAssertGreaterThanOrEqual(down - built, MistapGate.ms)   // what the old gate measured: it let this through
        XCTAssertFalse(MistapGate.allows(shownAt: drawn, downAt: down, now: 1700))
    }

    func testTheBoundaryIs400Ms() {
        XCTAssertFalse(MistapGate.allows(shownAt: 5000, downAt: 5399, now: 6000))
        XCTAssertTrue(MistapGate.allows(shownAt: 5000, downAt: 5400, now: 6000))
    }

    func testAPressOnASettledSheetSends() {
        XCTAssertTrue(MistapGate.allows(shownAt: 1000, downAt: 2200, now: 2300))
    }

    func testNothingCountsBeforeTheSheetHasDrawn() {
        XCTAssertFalse(MistapGate.allows(shownAt: nil, downAt: 9000, now: 9100))
        XCTAssertFalse(MistapGate.allows(shownAt: nil, downAt: nil, now: 9100))
    }

    func testAPressWithNoTouchDownIsJudgedByNow() {
        // TalkBack's activate has no pointer down: judged by when it is handled
        XCTAssertFalse(MistapGate.allows(shownAt: 1000, downAt: nil, now: 1300))
        XCTAssertTrue(MistapGate.allows(shownAt: 1000, downAt: nil, now: 1450))
    }
}
