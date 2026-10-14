import XCTest
@testable import ArkRemote

/// Regression 0108 #5. Defect guarded: an update check that answers mid-download, mid-install or while the confirm
/// sheet is up restarts the download or resets the notice; a failure never offers the update again; a finished update
/// leaves the notice on screen (e56d5ff: one download per version, a Material notice under the top bar). The notice draws AppUpdate.phase (Logic/AppUpdate.swift UpdateBanner: 有新版本 /
/// 正在下载 / 正在安装 / 没能更新到), so the phases it moves through are checked here, the way Kotlin reports them:
/// a check that answers while a download, install or confirm sheet is running leaves it alone (no second download, no
/// notice jumping back to 「有新版本」), a failure starts over as 「有新版本」 on the next check, and a finished update
/// leaves no notice. The Kotlin half (the retry with the confirm sheet, #6) is Android/app/src/test AppUpdaterTest.
/// How the notice looks in each phase needs the Android emulator and is not judged here.
@MainActor final class AppUpdatePhaseTests: XCTestCase {
    func testPhasesOfOneUpdate() {
        let u = AppUpdate.shared
        u.installed()
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .available)
        XCTAssertTrue(u.showsBanner)

        u.progress(done: 50, total: 100)
        XCTAssertEqual(u.phase, .downloading)
        XCTAssertEqual(u.fraction, 0.5)
        // the App opened again mid-download: the check's answer keeps the running download
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .downloading, "a check during the download restarted it")
        XCTAssertEqual(u.fraction, 0.5)
        u.progress(done: 10, total: 0)
        XCTAssertNil(u.fraction, "an unknown size draws the indeterminate bar")

        u.installing(message: "正在交给系统")
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .installing, "a check during the install reset it")
        u.confirming()
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .confirming, "a check while the system's confirm sheet is up reset it")

        u.failed(message: "安装被取消")
        XCTAssertEqual(u.phase, .failed)
        XCTAssertNil(u.fraction)
        XCTAssertEqual(u.message, "安装被取消")
        XCTAssertTrue(u.showsBanner)
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .available, "after a failure the next check offers the update again")
        XCTAssertNil(u.message)

        u.needsPermission()
        u.found(version: "0.9.0", canInstall: false)
        XCTAssertEqual(u.phase, .needsPermission, "「安装未知应用」 still off: the note stays")
        u.found(version: "0.9.0", canInstall: true)
        XCTAssertEqual(u.phase, .available)

        u.installed()
        XCTAssertEqual(u.phase, .idle)
        XCTAssertFalse(u.showsBanner, "a finished update leaves a notice")
    }
}
