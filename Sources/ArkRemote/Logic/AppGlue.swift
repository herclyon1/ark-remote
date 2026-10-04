// App-wide wiring: the boot sequence and the cross-module hooks the web page sets up at load time.
//
// Ported from maa-automation/web: view.js boot (connect → Live start, document visibilitychange),
// render()'s `if (Stamina.fromSnapshot(snap)) Stamina.refresh(true)` and liveVals → reconcile,
// stockpile.js calling Inventory.refresh, live.js calling Stamina.refresh on ping.
//
// Differences:
//   · document.hidden / visibilitychange → scenePhase. `.active` = visible; `.background` = hidden.
//     `.inactive` (notification shade, app switcher) is ignored so the stream does not flap.
//   · The web page boots after the setup screen has a mailbox; the app can come to the foreground before
//     the topic / PIN are entered, so the live part also starts when the config first appears.
//   · navigator.onLine / online / offline → Live.deviceOnline, fed by the system's own network events
//     (no timer, no polling, no request): on Android ConnectivityManager.registerDefaultNetworkCallback in
//     AndroidAppMain (Android/app/src/main/kotlin/Main.kt) → ArkRemoteAppDelegate.onNetwork; on iOS
//     NWPathMonitor below. skip-foundation itself has no network monitor.

import Foundation
#if canImport(Network)
import Network
#endif
import SkipFuse
import SwiftUI

@MainActor enum AppGlue {
    private static var wired = false
    /// .task and the first scenePhase change can both report `.active` at launch; act once.
    private static var visible = false
    #if canImport(Network)
    /// navigator.onLine on iOS: NWPathMonitor reports each change of the system's network path.
    private static let pathMonitor = NWPathMonitor()
    #endif

    /// The hooks between the logic modules; once per process.
    static func wire() {
        guard !wired else { return }
        wired = true

        #if canImport(Network)
        pathMonitor.pathUpdateHandler = { @Sendable path in
            let online = path.status == .satisfied
            Task { @MainActor in Live.shared.deviceOnline = online }
        }
        pathMonitor.start(queue: .main)
        #endif

        // stockpile.js: Inventory.refresh(force) → the {取自, games: [...]} object
        Stockpile.shared.loader = { force in
            guard let r = await InventoryStore.shared.refresh(force: force) else { throw AppError("没有读数") }
            return try JSONValue.parse(try JSONEncoder().encode(r))
        }

        // live.js ping(): the stamina numbers come along
        Live.shared.refreshStamina = {
            _ = await StaminaStore.shared.refresh(force: false)
        }

        // view.js render() on a newer state
        Relay.shared.onNewSnapshot = { snap in
            if StaminaStore.shared.fromSnapshot(snap) {
                Task { _ = await StaminaStore.shared.refresh(force: true) }
            }
            fillLiveVals()
            Pending.shared.reconcile()
        }
        // the cached state the app starts with counts too (the 状态 switches compare against liveVals)
        if let snap = Relay.shared.snap {
            // view.js render() at boot: Stamina.fromSnapshot(snap) on the cached state as well, so a 森空岛 session the
            // machine handed over is there even while the machine is off
            if StaminaStore.shared.fromSnapshot(snap) {
                Task { _ = await StaminaStore.shared.refresh(force: true) }
            }
            fillLiveVals()
        }
    }

    /// render() fills liveVals before reconcile; StatusData.from does the same field mapping, so build it
    /// once off-screen (the 状态 tab may not be on screen when the state arrives).
    private static func fillLiveVals() {
        let d = UserDefaults.standard
        _ = StatusData.from(relay: Relay.shared, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                            currentQueue: d.string(forKey: "ark-remote-cfg-queue") ?? "",
                            estopAt: d.integer(forKey: "ark-remote-estop"), record: true)
        // view.js:575-576: the 鸣潮 周本 「打第几个」 value on the machine, on every render whatever the tab, for reconcile
        let relay = Relay.shared.snap?["relay"]
        if let n = (relay?["周常"]?["周本"] ?? relay?["周本"])?["第几个周本"]?.number {
            Pending.shared.liveVals["wb|OK-WW|第几个周本"] = .int(Int(n))
        }
    }

    /// visibilitychange → visible (also the boot sequence).
    static func enterForeground() {
        guard !visible else { return }
        visible = true
        let live = Live.shared
        live.foreground = true
        live.start()
        Task { await live.becameVisible() }
        // a 免输入链接 copied while away (Pages/Phone/PhoneTab.swift); before setup SetupScreen.onAppear takes it
        clipboardDue = true
        takeClipboardIfDue()
        // one GitHub Releases request per open (Logic/AppUpdate.swift); Android only
        #if os(Android)
        AppUpdate.shared.checkOnOpen()
        #endif
    }

    /// One clipboard look per foreground (enterForeground sets it, takeClipboardIfDue spends it).
    private static var clipboardDue = false
    /// Android 10+ hands the clipboard only to the focused window, and focus arrives after onResume / `.active`
    /// (MainActivity.onWindowFocusChanged → ArkRemoteAppDelegate.onWindowFocus → windowFocus). iOS has no such gate.
    #if os(Android)
    private static var windowFocused = false
    /// When the text clip on the clipboard was put there (ms), from the clip's description; 0 = none / not text.
    private static var clipAt: Double = 0
    /// The clipAt of the last clip whose content was read, so a clip is read once.
    private static let clipReadKey = "ark-remote-clip-read-at"
    /// Only a clip put there this recently is read: the link is copied just before opening the app.
    private static let clipFreshMs: Double = 10 * 60 * 1000
    #else
    private static let windowFocused = true
    #endif

    static func windowFocus(_ has: Bool, clipAt at: Double = 0) {
        #if os(Android)
        windowFocused = has
        if has { clipAt = at }
        #endif
        if has { takeClipboardIfDue() }
    }

    /// Reading another app's clip makes Android 12+ show 「已粘贴」 and iOS ask to paste, so the content is read
    /// only when it can be a link copied just now: on Android a text clip from the last 10 minutes not read before
    /// (its description, which shows no notice); on iOS a probable web URL (detectPatterns, which shows no prompt)
    /// that changed since the last look (changeCount).
    private static func takeClipboardIfDue() {
        guard clipboardDue, windowFocused else { return }
        clipboardDue = false
        #if os(Android)
        let d = UserDefaults.standard
        let age = Date().timeIntervalSince1970 * 1000 - clipAt
        guard clipAt > 0, age <= clipFreshMs, d.double(forKey: clipReadKey) != clipAt else {
            logger.info("clipboard: not read (\(clipAt == 0 ? "no text clip" : age > clipFreshMs ? "older than 10 min" : "read before"))")
            return
        }
        d.set(clipAt, forKey: clipReadKey)
        logger.info("clipboard: read (put there \(Int(age / 1000)) s ago)")
        PhoneLink.takeClipboardLink()
        #elseif canImport(UIKit)
        let pb = UIPasteboard.general
        guard pb.hasStrings, pb.changeCount != clipChange else { return }
        clipChange = pb.changeCount
        pb.detectPatterns(for: [.probableWebURL]) { r in
            guard case .success(let found) = r, found.contains(.probableWebURL) else { return }
            Task { @MainActor in PhoneLink.takeClipboardLink() }
        }
        #else
        PhoneLink.takeClipboardLink()
        #endif
    }
    #if !os(Android) && canImport(UIKit)
    /// UIPasteboard.changeCount at the last look.
    private static var clipChange = -1
    #endif

    /// visibilitychange → hidden.
    static func enterBackground() {
        visible = false
        let live = Live.shared
        live.foreground = false
        live.stop()
    }
}

/// ContentView plus the app lifecycle: wires the modules and follows scenePhase.
struct AppShell: View {
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        ContentView()
            .task {
                AppGlue.wire()
                if scenePhase == .active { AppGlue.enterForeground() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: AppGlue.enterForeground()
                case .background: AppGlue.enterBackground()
                default: break
                }
            }
            .onChange(of: Relay.shared.config != nil) { _, has in
                // first setup: the mailbox appears while already in the foreground
                if has && scenePhase == .active { Task { await Live.shared.becameVisible() } }
            }
    }
}
