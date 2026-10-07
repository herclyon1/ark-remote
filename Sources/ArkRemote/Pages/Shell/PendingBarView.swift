import SwiftUI

/// The #pendbar line (maa-automation web/pending.js:76-88; placed by TopNotices, Logic/AppUpdate.swift):
/// 「N 项改动已寄出 · 机器开机后生效」 or 「N 项改动机器没接受（见红字）」, and 「不再等待」, which stops waiting for every
/// receipt after a confirmation (it cannot be undone: the list of sent changes is dropped).
///
/// iOS: no bar of its own. The line is the tab root's navigation subtitle (SwiftUI navigationSubtitle(_:): "Configures the
/// view's subtitle for purposes of navigation", iOS 26) and 「不再等待」 a button in the navigation bar; see `PendingStatus`.
/// Android: this row above the tab's content, with a red cross when the machine did not take a change.
struct PendingBarView: View {
    let bar: PendingBar

    var body: some View {
        HStack(spacing: 6) {
            if bar.hasMismatch {
                // the text beside says it (「机器没接受」): the cross is hidden from screen readers (HIG VoiceOver:
                // "Exclude purely decorative images from VoiceOver.")
                // skip-ui maps "xmark" but not "xmark.circle.fill" to a Material icon (Image.swift symbol table)
                Image(systemName: "xmark").foregroundStyle(Color.red).accessibilityHidden(true)
            }
            Text(bar.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // skip-fuse-ui marks controlSize unavailable (View/AdditionalViewModifiers.swift:224-226), so the Material
            // button keeps its own size
            PendingClearButton()
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

/// 「不再等待」 with its confirmation attached to the button itself, so the dialog comes from the button that was pressed
/// (SwiftUI confirmationDialog(_:isPresented:titleVisibility:actions:message:): the documented example attaches the
/// modifier to the Button that presents it). HIG Action sheets / confirmationDialog: a destructive action is confirmed,
/// its button marked destructive, with 取消 to back out.
struct PendingClearButton: View {
    @State var confirming = false

    var body: some View {
        Button("不再等待", role: .destructive) { confirming = true }
            .confirmationDialog("不再等待这些改动的回执？", isPresented: $confirming, titleVisibility: .visible) {
                Button("不再等待", role: .destructive) { Pending.shared.clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只清掉这里的等待记录，已寄出的改动不会撤回，也不再显示它们有没有生效。")
            }
    }
}

#if os(iOS)
/// iOS: the pending line as the tab root's navigation subtitle and 「不再等待」 as a navigation-bar button (see
/// PendingBarView). A view of its own so its body is what reads Pending (TopNotices explains why).
struct PendingStatus<Content: View>: View {
    let content: Content

    var body: some View {
        let bar = Pending.shared.bar
        content
            // an empty subtitle draws nothing; the modifier stays either way, so the page keeps its identity (scroll
            // position and state) when the line comes and goes
            .navigationSubtitle(Text(verbatim: bar?.text ?? ""))
            .toolbar {
                if bar != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        PendingClearButton()
                    }
                }
            }
    }
}
#endif
