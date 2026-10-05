// The page's unsaved changes, one pool for every tab (maa-automation/web/view.js:15 `let edits = {}`).
//
// On the web page 状态 / 方舟 / 终末地 / 鸣潮 are tabs of one page with one `edits` object: the top bar counts all of
// them (「待保存 N 项」, view.js:1551-1555), ✕ drops all of them (view.js:2950) and ✓ reviews and sends all of them in
// one go (doSave, view.js:1609; #go, view.js:2954). The tabs used to keep their own `@State edits`, so a change on one
// tab was neither counted nor sent from another. Keys are the web's `${src}|${owner}|${path}` (or `relay|…`,
// `wb|…`), so the tabs never collide. In memory only, like the web's `edits` (not in localStorage).

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class EWEdits {
    static let shared = EWEdits()

    /// key -> change waiting in 「待保存」.
    var items: [String: EWEdit] = [:]
    /// A send of this pool is out (EWSaveBar.go). One flag for every tab: a per-page @State let the ✓ of another tab send
    /// the same changes again while the first send was still going (edge audit 1b).
    var saving = false
}
