import SwiftUI

/// The #pendbar line above each tab's content, on iOS and Android (maa-automation web/pending.js:76-88; placed by
/// TopNotices, Logic/AppUpdate.swift): 「N 项改动已寄出 · 机器开机后生效」 or 「N 项改动机器没接受（见红字）」 with a red
/// xmark, and 「不再等待」, which stops waiting for every receipt after a confirmation (it cannot be undone: the list of
/// sent changes is dropped). Secondary footnote text on the bar material, no card.
struct PendingBarView: View {
    let bar: PendingBar
    @State var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            if bar.hasMismatch {
                // the text beside says it (「机器没接受」): the cross is hidden from screen readers (HIG VoiceOver:
                // "Exclude purely decorative images from VoiceOver.")
                // skip-ui maps "xmark" but not "xmark.circle.fill" to a Material icon (Image.swift symbol table)
                #if os(Android)
                Image(systemName: "xmark").foregroundStyle(Color.red).accessibilityHidden(true)
                #else
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red).accessibilityHidden(true)
                #endif
            }
            Text(bar.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            clear
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // HIG Action sheets / confirmationDialog: a destructive action is confirmed, its button marked destructive,
        // with 取消 to back out
        .confirmationDialog("不再等待这些改动的回执？", isPresented: $confirming, titleVisibility: .visible) {
            Button("不再等待", role: .destructive) { Pending.shared.clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清掉这里的等待记录，已寄出的改动不会撤回，也不再显示它们有没有生效。")
        }
    }

    /// iOS: the small bordered button (controlSize .small). Android: skip-fuse-ui marks controlSize unavailable
    /// (View/AdditionalViewModifiers.swift:224-226), so the Material button keeps its own size there.
    @ViewBuilder private var clear: some View {
        #if os(Android)
        Button("不再等待", role: .destructive) { confirming = true }
            .buttonStyle(.bordered)
        #else
        Button("不再等待", role: .destructive) { confirming = true }
            .buttonStyle(.bordered)
            .controlSize(.small)
        #endif
    }
}
