import Foundation
import SkipFuse
import SwiftUI

/// A logger for the ArkRemote module.
let logger: Logger = Logger(subsystem: "com.herclyon.arkremote", category: "ArkRemote")

/// The shared top-level view for the app, loaded from the platform-specific App delegates below.
///
/// Loads the `ContentView` inside `AppShell`, which wires the logic modules and follows scenePhase (Logic/AppGlue.swift).
/* SKIP @bridge */public struct ArkRemoteRootView : View {
    /* SKIP @bridge */public init() {
    }

    public var body: some View {
        AppShell()
            .task {
                logger.info("Skip app logs are viewable in the Xcode console for iOS; Android logs can be viewed in Studio or using adb logcat")
                await startRecorders()
            }
    }
}

/// index.html loads crash-rec.js and fluency-rec.js on every page load: the app starts both recorders once per process
/// (Logic/CrashRec.swift, Logic/FluencyRec.swift); later calls do nothing.
@MainActor func startRecorders() {
    CrashRec.shared.start()
    FluencyRec.shared.start()
    #if !os(Android) && canImport(UIKit)
    TouchProbe.install()
    #endif
}

/// Global application delegate functions.
///
/// These functions can update a shared observable object to communicate app state changes to interested views.
/* SKIP @bridge */public final class ArkRemoteAppDelegate : Sendable {
    /* SKIP @bridge */public static let shared = ArkRemoteAppDelegate()

    private init() {
    }

    /* SKIP @bridge */public func onInit() {
        logger.debug("onInit")
    }

    /* SKIP @bridge */public func onLaunch() {
        logger.debug("onLaunch")
    }

    /* SKIP @bridge */public func onResume() {
        logger.debug("onResume")
        // visibilitychange → visible for the recorders (crash-rec heartbeat, queued uploads)
        CrashRec.shared.shown()
        #if !os(Android) && canImport(UIKit)
        Task { @MainActor in TouchProbe.install() }
        #endif
    }

    /* SKIP @bridge */public func onPause() {
        logger.debug("onPause")
        // visibilitychange → hidden: the alive marker is written at once (crash-rec), a pending flu hit is sent
        CrashRec.shared.hidden()
        FluencyRec.shared.hidden()
    }

    /* SKIP @bridge */public func onStop() {
        logger.debug("onStop")
        CrashRec.shared.hidden()
        FluencyRec.shared.hidden()
    }

    /* SKIP @bridge */public func onDestroy() {
        logger.debug("onDestroy")
    }

    /* SKIP @bridge */public func onLowMemory() {
        logger.debug("onLowMemory")
    }

    /// navigator.onLine / online / offline on Android: AndroidAppMain (Main.kt) forwards the system's
    /// default-network callback here. Called on a ConnectivityManager thread; Live is main-actor state.
    /* SKIP @bridge */public func onNetwork(online: Bool) {
        Task { @MainActor in Live.shared.deviceOnline = online }
        // window "online": the recorders' queues go when the network comes back
        CrashRec.shared.network(online)
        if online { Task.detached { await FluencyRec.shared.flushIfQueued() } }
    }

    /// MainActivity.onWindowFocusChanged (Main.kt): the clipboard can be read only while the window has focus.
    /// `clipAt`: when the text clip on the clipboard was put there (ms since 1970), 0 for none or not text.
    /* SKIP @bridge */public func onWindowFocus(hasFocus: Bool, clipAt: Double) {
        Task { @MainActor in AppGlue.windowFocus(hasFocus, clipAt: clipAt) }
        CrashRec.shared.focus(hasFocus)   // crash-rec's focused / focus_changed tags (window focus / blur)
    }

    // MARK: Recorders (Android; Logic/CrashRec.swift, Logic/FluencyRec.swift)

    /// MainActivity.dispatchTouchEvent (Main.kt), the primary pointer only: `phase` 0 = down, 1 = up, 2 = cancel;
    /// x / y in dp from the window's top left; `waitMs` = SystemClock.uptimeMillis() − the event's eventTime when the
    /// activity got it (how late the press reached the main thread). On the main thread.
    /* SKIP @bridge */public func onTouch(phase: Int, x: Double, y: Double, waitMs: Double) {
        if phase == 0 {
            TouchFeed.down(x: x, y: y, waitMs: max(0, waitMs))
            #if os(Android)
            Task { @MainActor in FrameClock.run() }
            #endif
        } else {
            TouchFeed.up(x: x, y: y, cancelled: phase == 2, waitMs: max(0, waitMs))
        }
    }

    /// The activity's view tree is about to be drawn (Main.kt OnDrawListener, within 11 s of a press): fluency-rec's
    /// UI-commit signal for slow / inp. On the main thread.
    /* SKIP @bridge */public func onDraw() {
        FluencyRec.shared.commit(ts: RecKit.mono())
    }

    /// Thread.setDefaultUncaughtExceptionHandler (Main.kt): an uncaught Kotlin exception is about to kill the app;
    /// crash-rec keeps it synchronously and sends it at the next start.
    /* SKIP @bridge */public func onUncaughtException(message: String, stack: String) {
        CrashRec.shared.fatal(message, stack: stack)
    }

    /// AndroidAppMain hands over the scan of earlier runs' 「应用无响应」 exits (Main.kt AnrScan) once at startup;
    /// CrashRec.start calls it, as iOS installs its MetricKit subscriber there.
    /* SKIP @bridge */public func registerAnrScan(scan: @escaping () -> Void) {
        CrashRec.androidAnrScan = scan
    }

    /// One ANR of an earlier run (ApplicationExitInfo.REASON_ANR, Main.kt AnrScan), reported once: a "stall"
    /// incident with how "anr", the main thread's stack from the ANR trace, and the version that run wrote into its
    /// process state summary ("" for a run before that summary was written). `at` = the exit's timestamp (ms since
    /// 1970), `description` = ApplicationExitInfo.getDescription(). Called on a worker thread.
    /* SKIP @bridge */public func onPastAnr(at: Double, stack: String, prevV: String, description: String) {
        CrashRec.shared.past([["type": .string("stall"), "how": .string("anr"), "at": .string(RecKit.iso(at)),
                               "message": .string(RecKit.cut(description, 500)), "stack": .string(RecKit.cut(stack, 3000)),
                               "prev_v": .string(prevV)]])
    }

    // MARK: Share (Android; ShareSheet.kt drives the system share panel, Pages/Phone/PhoneDiagRows.swift DiagShare asks)

    /// AndroidAppMain hands over the share entry point once at startup: `share(text, title)` opens the system chooser.
    /* SKIP @bridge */public func registerSharer(share: @escaping (String, String) -> Void) {
        DiagShare.androidShare = share
    }

    /// What the chooser told ShareSheet.kt: `state` 0 = an app was picked, 1 = back without a pick (inferred: no pick
    /// came before the activity resumed), 2 = the chooser could not be opened (`message` says why).
    /* SKIP @bridge */public func onShareResult(state: Int, message: String) {
        Task { @MainActor in DiagShare.finish(state: state, message: message) }
    }

    // MARK: In-app update (Android only; AppUpdater.kt drives these, Logic/AppUpdate.swift shows them)

    /// AndroidAppMain hands over the two Kotlin entry points once at startup: `check` (one GitHub request)
    /// and `install` (download + PackageInstaller session). AppUpdate calls them on the main thread.
    /* SKIP @bridge */public func registerUpdater(check: @escaping () -> Void, install: @escaping () -> Void) {
        AppUpdate.hooks = AppUpdate.Hooks(check: check, install: install)
    }

    /// The latest release is newer than this build and carries an .apk asset; `canInstall` = 「安装未知应用」 is on
    /// for this app. Called on a worker thread.
    /* SKIP @bridge */public func onUpdateAvailable(version: String, canInstall: Bool) {
        Task { @MainActor in AppUpdate.shared.found(version: version, canInstall: canInstall) }
    }

    /// 「更新」 found 「安装未知应用」 off; AppUpdater opened that setting.
    /* SKIP @bridge */public func onUpdateNeedsPermission() {
        Task { @MainActor in AppUpdate.shared.needsPermission() }
    }

    /// The system's install confirmation is up (STATUS_PENDING_USER_ACTION).
    /* SKIP @bridge */public func onUpdateConfirming() {
        Task { @MainActor in AppUpdate.shared.confirming() }
    }

    /// STATUS_SUCCESS: the new version is installed.
    /* SKIP @bridge */public func onUpdateInstalled() {
        Task { @MainActor in AppUpdate.shared.installed() }
    }

    /// Download progress in bytes; `total` is 0 or less when the server sent no Content-Length.
    /* SKIP @bridge */public func onUpdateProgress(done: Int, total: Int) {
        Task { @MainActor in AppUpdate.shared.progress(done: done, total: total) }
    }

    /// The APK is downloaded and handed to the system installer; `message` says what the user sees now.
    /* SKIP @bridge */public func onUpdateInstalling(message: String) {
        Task { @MainActor in AppUpdate.shared.installing(message: message) }
    }

    /// Download or install failed; `message` is shown as is.
    /* SKIP @bridge */public func onUpdateError(message: String) {
        Task { @MainActor in AppUpdate.shared.failed(message: message) }
    }
}
