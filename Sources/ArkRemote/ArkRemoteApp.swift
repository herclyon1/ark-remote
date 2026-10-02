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
}
