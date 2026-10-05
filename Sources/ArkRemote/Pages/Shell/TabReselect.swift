// D39: a reselect of a tab at its root scrolls that root page to its top (ContentView.reselect, Android only; iOS's tab
// bar does it natively). The counts were a custom EnvironmentKey (\.tabReselect) set on each tab's NavigationStack root;
// on Android reselecting a scrolled root page did nothing (test pass 1, 问题 10) while the pop half of the same call
// worked. The tab roots are composed inside skip-ui's TabView content, outside ContentView's body (the same reason
// TopNotices reads Pending itself, Logic/AppUpdate.swift), so the counts are now one @Observable that each root page reads
// in its own body, the way every page already follows Relay / Pending.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class TabReselect {
    static let shared = TabReselect()

    /// Bumped by a reselect of the tab at its root; a root page scrolls to its top on the change.
    var status = 0
    var arknights = 0
    var endfield = 0
    var wuwa = 0
    var phone = 0

    func bump(_ t: ContentTab) {
        switch t {
        case .status: status += 1
        case .arknights: arknights += 1
        case .endfield: endfield += 1
        case .wuwa: wuwa += 1
        case .phone: phone += 1
        }
    }
}
