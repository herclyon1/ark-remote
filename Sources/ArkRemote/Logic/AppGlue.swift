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
//   · navigator.onLine → Live.deviceOnline stays true: skip-foundation has no network monitor
//     (only URL.checkResourceIsReachable for files).
//     TODO: feed Live.deviceOnline from Android ConnectivityManager / NWPathMonitor.

import Foundation
import SkipFuse
import SwiftUI

@MainActor enum AppGlue {
    private static var wired = false
    /// .task and the first scenePhase change can both report `.active` at launch; act once.
    private static var visible = false

    /// The hooks between the logic modules; once per process.
    static func wire() {
        guard !wired else { return }
        wired = true

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
    }

    /// render() fills liveVals before reconcile; StatusData.from does the same field mapping, so build it
    /// once off-screen (the 状态 tab may not be on screen when the state arrives).
    private static func fillLiveVals() {
        let d = UserDefaults.standard
        _ = StatusData.from(relay: Relay.shared, live: Live.shared, stamina: StaminaStore.shared, pending: Pending.shared,
                            currentQueue: d.string(forKey: "ark-remote-cfg-queue") ?? "",
                            estopAt: d.integer(forKey: "ark-remote-estop"))
    }

    /// visibilitychange → visible (also the boot sequence).
    static func enterForeground() {
        guard !visible else { return }
        visible = true
        let live = Live.shared
        live.foreground = true
        live.start()
        Task { await live.becameVisible() }
    }

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
