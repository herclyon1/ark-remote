import SwiftUI

// P14, the 诊断记录 bar on every tab while the switch is on (seg-frames-logger.js #diagline and #diagmark 「就是这里」).
// Moved from Pages/Phone/PhoneDiagRows.swift (DiagOverlay / DiagRoom): it hangs on the shell's TabView.
//
// iOS: the tab view's bottom accessory, Music's MiniPlayer place (BOARD/app-page-references.txt P14 / N15, image
// evidence/app-pages-1007/apple/P14-音乐-MiniPlayer-苹果iOS27手册.png): one row, the status line and on its right one
// icon button in the accent colour, not a red disc ("按钮去红": red is for destructive actions). HIG Tab bars: "For tab
// bars with an attached accessory, like the MiniPlayer in Music, you can choose to minimize the tab bar and move the
// accessory inline with it when a person scrolls down." The system insets every tab's content for it.
// Android: skip-ui has no tabViewBottomAccessory (Containers/TabView.swift:1236-1239, unavailable) and no
// safeAreaInset (skip-fuse-ui Layout/SafeArea.swift:19-22), so the same row sits under each tab's pages in the tab's own
// column (DiagRoom): the pages end above it, nothing measured, nothing drawn over the list.

/// 「就是这里」 and its words (seg-frames-logger.js MARK_WORDS) as a system Menu: one tap opens the words, a word sends.
struct DiagMarkMenu: View {
    var body: some View {
        Menu {
            ForEach(DiagUI.markWords, id: \.self) { w in
                Button(w) { DiagUI.shared.mark(w) }
            }
            Button("直接发（不选词）") { DiagUI.shared.mark(nil) }
        } label: {
            // skip-ui has no flag: Material's Feedback icon ("report an issue") on Android
            Label { Text("就是这里") } icon: { symbol("flag", android: "Icons.Outlined.Feedback") }
        }
    }
}

/// The bar's row: the status line (a tap opens the record sheet: copy / share) and 「就是这里」.
struct DiagAccessory: View {
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    /// Inline (beside the minimised tab bar) there is room for one line and the flag alone; expanded, two lines and
    /// the flag with its name.
    private var inline: Bool { placement == .inline }
    #else
    private var inline: Bool { false }
    #endif

    var body: some View {
        let ui = DiagUI.shared
        HStack {
            Button {
                ui.openSheet()
            } label: {
                Label {
                    Text(verbatim: ui.line)
                        .lineLimit(inline ? 1 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    // the recorder's sign, as MiniPlayer leads with the artwork; skip-ui has no record symbol, so
                    // Android's row starts with the text
                    #if !os(Android)
                    Image(systemName: "record.circle").accessibilityHidden(true)
                    #endif
                }
                .font(.footnote)
            }
            .buttonStyle(.plain)
            DiagMarkMenu()
                .labelStyle(.iconOnly)
                .font(.title3)   // MiniPlayer's buttons are the row's largest glyphs (imageScale is not in skip-fuse-ui)
        }
        .padding(.horizontal)
    }
}

/// On the TabView (ContentView): the bar while 诊断记录 is on, and the record sheet the line opens.
struct DiagBottomAccessory: ViewModifier {
    func body(content: Content) -> some View {
        let ui = DiagUI.shared
        #if os(iOS)
        content
            .tabViewBottomAccessory(isEnabled: ui.on) { DiagAccessory() }
            .modifier(DiagSheet())
        #else
        content.modifier(DiagSheet())
        #endif
    }
}

/// The record sheet (Pages/Phone/PhoneDiagRows.swift DiagRecordSheet) from a tap on the line or the first failed
/// upload of a run (DiagUI.report), and the recorder started at launch while the switch is on.
struct DiagSheet: ViewModifier {
    func body(content: Content) -> some View {
        let ui = DiagUI.shared
        content
            .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
            .sheet(isPresented: Binding(get: { DiagUI.shared.sheetOpen }, set: { DiagUI.shared.sheetOpen = $0 })) {
                DiagRecordSheet { DiagUI.shared.sheetOpen = false }
            }
    }
}

/// On each tab's NavigationStack (ContentView.tabs). Android: the bar under the tab's pages while 诊断记录 is on, in the
/// tab's own column, so the last row of a list ends above it (it sat over 状态 「查看全部」 and 鸣潮 「周本打第几个」 as an
/// overlay, test pass 3). The stack expands (maxHeight .infinity: skip-ui gives an expanding child the column's
/// remaining height, Containers/VStack.swift:99-104) and the bar takes its own height. A ViewModifier, so .tabItem / .tag
/// stay on the TabView's direct child; DiagUI.shared.on is read here, in body(content:), because a read in ContentView's
/// body does not redraw the tab roots (TopNotices, Logic/AppUpdate.swift). iOS: nothing, the bottom accessory insets
/// the content itself.
struct DiagRoom: ViewModifier {
    func body(content: Content) -> some View {
        #if os(Android)
        VStack(spacing: 0) {
            content.frame(maxHeight: .infinity)
            if DiagUI.shared.on {
                Divider()
                DiagAccessory().padding(.vertical, 8)
            }
        }
        #else
        content
        #endif
    }
}
