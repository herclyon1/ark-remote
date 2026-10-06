import SwiftUI

/// The one line under a settings row on the 方舟 and 鸣潮 tabs: 「正在寄出」 while the change goes out, then the receipt
/// (「已寄出 HH:MM · …」 / 「已应用 HH:MM」 / 「没生效 · …」, pending.js:47-67), or why a typed value was not sent.
/// A change applies when it is made (验收 10-07: a Toggle / Picker sends at once, a text or number field on submit), so
/// there is no 「待保存」 state and no tinted row: the status is secondary text in the row (brief 1007 rule "Status of a row").
struct GameRowStatus: Equatable {
    var text: String
    /// 「没生效」 or a value that cannot be sent: red.
    var bad = false
    /// 「再发一次」 for this Pending key (under 「没生效」 and the 10 h 「没回执」 line, pending.js:59).
    var resendKey: String? = nil
    /// The change is on its way: an activity indicator in place (HIG Progress indicators: "Use an activity indicator
    /// … when it's not possible to calculate how long a task will take").
    var sending = false

    static let sendingNow = GameRowStatus(text: "正在寄出", sending: true)
}

extension View {
    /// The row with its status line under it, and 「再发一次」 as the row's swipe action and context-menu item (brief 1007:
    /// "per-row actions (再发一次) as .swipeActions + .contextMenu"). One shape with or without a status: the control stays
    /// the first child, so a status line that appears does not rebuild a text field being typed in.
    func gameRowStatus(_ status: GameRowStatus?, onResend: @escaping (String) -> Void) -> some View {
        let key = status?.resendKey
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let key {
                Button("再发一次") { onResend(key) }
                    .tint(.accentColor)
            }
        }
        .contextMenu {
            if let key {
                Button("再发一次", systemImage: "arrow.clockwise") { onResend(key) }
            }
        }
    }
}

/// The reason inside an EWSave.send failure, for a one-item send that applied on change. EWSave words its failure for
/// the batch bar (「一项都没发出去（原因）。改动还在页面上，可以再按一次保存。」, EWLive.swift); here the control goes back
/// to the value it had and there is no save button, so only the reason is kept. Falls back to the whole text.
func gameSendFailure(_ label: String, _ failure: String) -> String {
    if let open = failure.firstIndex(of: "（"), let close = failure.lastIndex(of: "）"), open < close {
        let why = failure[failure.index(after: open)..<close]
        return "「\(label)」没寄到游戏机（\(why)），已改回原来的值。"
    }
    return failure
}
