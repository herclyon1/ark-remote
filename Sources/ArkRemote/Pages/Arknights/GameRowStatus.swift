import SwiftUI

/// The one line under a settings row on the 方舟 and 鸣潮 tabs: 「正在寄出」 while the change goes out, then the receipt
/// (「已寄出 HH:MM · …」 / 「已应用 HH:MM」 / 「没生效 · …」, pending.js:47-67), or why the change did not go out.
/// A change applies when it is made (验收 10-07: a Toggle / Picker sends at once, a text or number field on submit), so
/// there is no 「待保存」 state and no tinted row: the status is secondary text in the row (brief 1007 rule "Status of a row").
struct GameRowStatus: Equatable {
    var text: String
    /// 「没生效」, or a change that did not go out: red.
    var bad = false
    /// 「再发一次」 for this Pending key (under 「没生效」 and the 10 h 「没回执」 line, pending.js:59).
    var resendKey: String? = nil
    /// A change that did not go out (EWEdit.failure, set by EWSave.apply's drain), by its pool key: the row offers
    /// 「再发一次」 (EWSave.retry) and 「不改了」 (EWSave.drop), as the 终末地 rows do (ewRowActions).
    var retryKey: String? = nil
    /// The change is on its way: an indeterminate indicator in place, gone when the send is done (HIG Progress
    /// indicators: indeterminate ones are "for unquantifiable tasks"; "All progress indicators are transient, appearing
    /// only while an operation is ongoing and disappearing after it completes.").
    var sending = false

    static let sendingNow = GameRowStatus(text: "正在寄出", sending: true)

    init(text: String, bad: Bool = false, resendKey: String? = nil, retryKey: String? = nil, sending: Bool = false) {
        self.text = text
        self.bad = bad
        self.resendKey = resendKey
        self.retryKey = retryKey
        self.sending = sending
    }

    /// The line for a row from its EWRowTag (ewTag: the pool, EWSendQueue and Pending): sending, then a change that did
    /// not go out, then the receipt. nil when the row has nothing under it.
    static func from(_ t: EWRowTag?, key: String) -> GameRowStatus? {
        guard let t else { return nil }
        if t.sending { return .sendingNow }
        if let failure = t.failure { return GameRowStatus(text: failure, bad: true, retryKey: t.retryKey ?? key) }
        if let text = t.text { return GameRowStatus(text: text, bad: t.bad, resendKey: t.resendKey) }
        return nil
    }
}

extension View {
    /// The row with its status line under it, and its actions as the row's swipe actions and context-menu items (brief
    /// 1007: "per-row actions (再发一次) as .swipeActions + .contextMenu"): 「再发一次」 / 「不改了」 for a change that did not go
    /// out, 「再发一次」 for one the machine did not take. One shape with or without a status: the control stays the first
    /// child, so a status line that appears does not rebuild a text field being typed in.
    func gameRowStatus(_ status: GameRowStatus?, onResend: @escaping (String) -> Void) -> some View {
        let retry = status?.sending == true ? nil : status?.retryKey
        let resend = status?.sending == true ? nil : status?.resendKey
        return VStack(alignment: .leading, spacing: 4) {
            self
            if let status {
                HStack(spacing: 6) {
                    if status.sending {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: status.text)
                        .font(.footnote)
                        .foregroundStyle(status.bad ? Color.red : Color.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let retry {
                Button("再发一次") { EWSave.retry(retry) }
                    .tint(.accentColor)
                Button("不改了") { EWSave.drop(retry) }
            } else if let resend {
                Button("再发一次") { onResend(resend) }
                    .tint(.accentColor)
            }
        }
        .contextMenu {
            if let retry {
                Button("再发一次", systemImage: "arrow.clockwise") { EWSave.retry(retry) }
                Button("不改了", systemImage: "arrow.uturn.backward") { EWSave.drop(retry) }
            } else if let resend {
                Button("再发一次", systemImage: "arrow.clockwise") { onResend(resend) }
            }
        }
    }
}
