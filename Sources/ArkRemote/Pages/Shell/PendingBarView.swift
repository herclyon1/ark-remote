import SwiftUI

// P15, the line that says what was sent and is still waiting for the machine (web/pending.js:76-88 #pendbar), placed by
// TopNotices (Logic/AppUpdate.swift) on each tab root.
//
// iOS: under the large title, as Mail puts 「Undo Send」 there (BOARD/app-page-references.txt P15 / N16, image
// evidence/app-pages-1007/apple/P15-邮件-撤回发送-苹果iOS27手册-近似.png) through the toolbar's subtitle placement
// (ToolbarItemPlacement.largeSubtitle, iOS 26). HIG Feedback: "Consider integrating status feedback into your
// interface." A tap asks before 「不等了，清掉」 with an action sheet from the line: HIG Action sheets "Use an action sheet
// … to offer choices related to an intentional action." With nothing waiting, the same place shows the last
// Feedback.status line (Pages/Shell/Feedback.swift).
// Android: skip-ui has no subtitle placement (Commands/Toolbar.swift:249-252 `@available(*, unavailable)`), so the line
// stays a row over the list with its own button, as in 0.4.4.

#if !os(Android)
/// The line itself: the pending text (a red cross while something was refused), or the last status note.
struct SubtitleLine: View {
    /// true: under the large title (leading, as Mail's 「Undo Send」); false: under the collapsed title (centred with it,
    /// smaller).
    var large = true
    @State var asking = false

    var body: some View {
        if let bar = Pending.shared.bar {
            Button { asking = true } label: {
                if bar.hasMismatch {
                    // the text says it (「机器没接受」): the cross is hidden from screen readers (HIG VoiceOver: "Exclude
                    // purely decorative images from VoiceOver.")
                    Label {
                        Text(verbatim: bar.text)
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red).accessibilityHidden(true)
                    }
                    .labelStyle(.titleAndIcon)   // a toolbar draws a Label as its icon alone otherwise
                } else {
                    Text(verbatim: bar.text)
                }
            }
            // a link in the accent colour under the title, as Mail's 「Undo Send」
            .foregroundStyle(.tint)
            .modifier(SubtitlePlace(large: large))
            .confirmationDialog(bar.text, isPresented: $asking, titleVisibility: .visible) {
                Button(PendingBar.clearLabel, role: .destructive) { Pending.shared.clearAll() }
            } message: {
                Text("只是这台手机不再等回执，已经寄出的不会撤回。")
            }
        } else if let n = Feedback.shared.note {
            Text(verbatim: Feedback.line(n))
                .foregroundStyle(.secondary)
                .modifier(SubtitlePlace(large: large))
        }
    }
}

/// The text style and alignment of the line for its title: subheadline at the large title's leading edge, footnote
/// centred under the collapsed one.
struct SubtitlePlace: ViewModifier {
    let large: Bool

    func body(content: Content) -> some View {
        content
            .font(large ? .subheadline : .footnote)
            .frame(maxWidth: .infinity, alignment: large ? .leading : .center)
    }
}
#endif

/// Android: the #pendbar row over the list (grey footnote, the 「不等了，清掉」 button), or the last status note.
struct PendingBarView: View {
    let bar: PendingBar

    var body: some View {
        HStack(spacing: 6) {
            if bar.hasMismatch {
                // skip-ui maps "xmark" but not "xmark.circle.fill" to a Material icon (Image.swift symbol table)
                Image(systemName: "xmark").foregroundStyle(Color.red).accessibilityHidden(true)
            }
            Text(bar.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(PendingBar.clearLabel) { Pending.shared.clearAll() }
                .font(.subheadline)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

/// Android: the last Feedback.status line in the same place, while nothing waits.
struct StatusNoteRow: View {
    let note: Feedback.Note

    var body: some View {
        Text(verbatim: Feedback.line(note))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
