// What used to be a toast (view.js toast(): a line in the middle of the screen, gone after 2.6 s), as the native
// patterns HIG gives for each kind. Page code says what happened through this file only; nothing draws a toast.
//
// - Status after a send or a background event (「已派：现在跑一趟」, 「「X」已生效」, 「已从剪贴板的链接更新密钥」):
//   `Feedback.status(_:)`. It stays under each tab's title until the next one, as Mail keeps 「Updated Just Now」 in its
//   mailbox toolbar. HIG Feedback: "Consider integrating status feedback into your interface. When status feedback is
//   available near the items it describes, people get important information without having to take action or leave
//   their current context. For example, Mail in iOS and iPadOS describes the most recent update … in the toolbar of the
//   mailbox screen" (https://developer.apple.com/design/human-interface-guidelines/feedback).
// - A failure of this phone's own action (「发不出去」, 「有改动没发出去」, 「没存上」): `Feedback.alert(_:_:)`, the system
//   alert with one 「好」. HIG Feedback: "Use alerts to deliver critical — and ideally actionable — information."
//   After a sheet, set it from the sheet's onDismiss so it never races the sheet going away (SaveBar does).
// - A value that cannot be accepted yet (「两样都要填」, 「至少要留一个」): no call here; the button is disabled and the
//   section footer says why. HIG Entering data: "make the button available only after people enter the data you require."
// - Copied / shared, switched on or off, saved: no call here; ShareLink (the share sheet has Copy and is its own
//   feedback) or the control / row value is the state. HIG Alerts: "Avoid using an alert merely to provide
//   information. … prefer finding an alternative way to communicate it within the relevant context."
// Nothing here goes away on a timer: HIG Accessibility "Views and controls that auto-dismiss on a timer can be
// problematic … Prefer dismissing views with an explicit action."

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

@MainActor @Observable final class Feedback {
    static let shared = Feedback()

    /// The last status line: what happened and when (this phone's clock, seconds).
    struct Note: Equatable {
        let text: String
        let at: Int
    }

    /// Shown under each tab root's title while no change waits for its receipt (the pending line wins: it is the one
    /// that can still be acted on). In memory only; cleared when the App goes to the background.
    var note: Note?

    /// A send went out or something changed in the background: one line under the title, with the time.
    static func status(_ text: String) {
        shared.note = Note(text: text, at: nowSec())
    }

    /// This phone's own action failed: the one system alert with 「好」 (ContentView presents it).
    static func alert(_ title: String, _ message: String) {
        Relay.shared.showAlert(title, message)
    }

    /// The App went to the background: an old line would only read as news on the next open.
    static func clear() {
        if shared.note != nil { shared.note = nil }
    }

    /// 「已派：现在跑一趟 · 14:02」.
    static func line(_ n: Note) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "\(n.text) · \(f.string(from: Date(timeIntervalSince1970: Double(n.at))))"
    }
}
