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
            }
    }
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
    }

    /* SKIP @bridge */public func onPause() {
        logger.debug("onPause")
    }

    /* SKIP @bridge */public func onStop() {
        logger.debug("onStop")
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
    }

    /// MainActivity.onWindowFocusChanged (Main.kt): the clipboard can be read only while the window has focus.
    /* SKIP @bridge */public func onWindowFocus(hasFocus: Bool) {
        Task { @MainActor in AppGlue.windowFocus(hasFocus) }
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
