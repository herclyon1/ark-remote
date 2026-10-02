import SwiftUI

/// The #pendbar line above the tabs (maa-automation web/pending.js:72-84): 「N 项改动已寄出 · 机器开机后生效」 or
/// 「N 项改动机器没接受（见红字）」 with a red xmark, and 「不等了，清掉」 that drops every waiting item.
/// Grey footnote, no card (index.html #pendbar: color --dim, footnote size, transparent background).
struct PendingBarView: View {
    let bar: PendingBar

    var body: some View {
        HStack(spacing: 6) {
            if bar.hasMismatch {
                // skip-ui maps "xmark" but not "xmark.circle.fill" to a Material icon (Image.swift symbol table)
                #if os(Android)
                Image(systemName: "xmark").foregroundStyle(Color.red)
                #else
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                #endif
            }
            Text(bar.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("不等了，清掉") { Pending.shared.clearAll() }
                .font(.footnote)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}
