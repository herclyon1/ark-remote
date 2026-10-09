// The shift picked on the 状态 tab, for the game tabs' ShiftGate (ContentView.swift).
//
// The pick is stored under "ark-remote-cfg-queue" (@AppStorage on StatusTab / ArknightsTab / ContentView). The game tabs'
// roots are composed inside skip-ui's TabView content, outside ContentView's body (TabReselect.swift says the same of
// D39), so a ShiftGate handed ContentView's answer kept the first one on Android: after a change of shift on the 状态 tab
// the 终末地 tab went on showing its page until a cold start (10-07 replay, n1007-seg2/002-shift.night.png,
// probe-android/ef-night-cold.png). An @AppStorage inside the generic ShiftGate does not build through Skip's bridge
// (the generated ContentView_Bridge.swift mixes up AppStorageSupport and StateSupport), so the pick is mirrored in one
// @Observable that the gate reads in its own body, the way every page already follows Relay / Pending.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class ShiftPick {
    static let shared = ShiftPick()

    static let key = "ark-remote-cfg-queue"

    /// The picked shift's name; "" = none picked (the first queue is shown).
    var queue: String = UserDefaults.standard.string(forKey: ShiftPick.key) ?? ""
}
