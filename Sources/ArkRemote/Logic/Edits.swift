// The changes not yet sent, one pool for every tab (maa-automation/web/view.js:15 `let edits = {}`).
//
// A change applies as it is made (decision 验收 10-07): EWSave.apply puts it here, so its row shows it at once, and its
// drain sends the pool's queued keys one at a time (Pages/Endfield/EWLive.swift). A change stays here while it is queued
// or out, and after a send that failed (EWEdit.failure) until it is sent again or dropped. Keys are the web's
// `${src}|${owner}|${path}` (or `relay|…`, `wb|…`), so the tabs never collide. In memory only, like the web's `edits`
// (not in localStorage).

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class EWEdits {
    static let shared = EWEdits()

    /// key -> change not yet sent (queued, out, or failed).
    var items: [String: EWEdit] = [:]
}
