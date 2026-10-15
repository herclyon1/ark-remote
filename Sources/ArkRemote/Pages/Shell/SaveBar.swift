import SwiftUI

// The one save bar of every tab (view.js updateBar / #confirm): ✕ / ✓ over the one pool of unsent changes
// (Logic/Edits.swift), 「N 项未寄出」 under the title (TopNotices), and its 「寄出前看一下」 review: nothing goes out on a
// change alone. One verb throughout, 寄出, as Mail says Send from the button to the sent state.
// Moved from Pages/Endfield/EWLive.swift: it is the shell's (tab pages only put `.modifier(EWSaveBar(title:))` on).

/// The edit bar and its review sheet, on every tab, over the one pool of unsaved changes (Logic/Edits.swift): the
/// count, ✕ and ✓ cover the changes of all tabs, as the web page's one top bar does.
/// `title`: the page title, kept while changes wait (Passwords › New Password keeps its title while editing, P12; HIG
/// Toolbars: the title says which page this is). The count is the line under it (unsentLine, TopNotices).
///
/// ✕ and ✓ are the system's cancel / confirm toolbar buttons (iOS 26 `Button(role:action:)`: the system draws the
/// symbol, ✓ prominent), the pair a sheet editing something carries (BOARD/app-page-references.txt P12: 密码 › 新建,
/// 左 X 右对勾). ✕ asks first, as Calendar does when an edit with changes is cancelled (P10, evidence/app-pages-1007/apple/
/// P10-日历-放弃确认.png): HIG Alerts "when people take an uncommon destructive action that they can't undo, it's
/// important to display an alert"; an action sheet from the button, HIG Action sheets "Use an action sheet — not an
/// alert — to offer choices related to an intentional action."
struct EWSaveBar: ViewModifier {
    var title: String? = nil
    @State var reviewing = false
    @State var discardAsk = false
    /// The 「有改动没发出去」 alert's message after a send that left changes unsent (view.js:3007 ask(..., { single: true })).
    @State var failNote: String? = nil
    /// A failure that came back while the review sheet was still going away: an alert raised then is dropped (UIKit
    /// presents one thing at a time), so it waits for the sheet's onDismiss (Pages/Shell/Feedback.swift).
    @State var heldFail: String? = nil
    @State var sheetUp = false
    /// view.js:1619 goArmedAt: while the review lists a 今天不跑 / 今天照常跑, a press that began in the sheet's first
    /// 400 ms is no confirm (the 08:46 skips, 检查 09-30); the sheet stays (MistapGate, judged in go()).
    @State var gated = false
    /// Which review this is: the Android stamps (ReviewGateStamps) count only for the sheet of this review, not for a
    /// sheet still going away.
    @State var reviewSeq = 0
    #if !os(Android)
    /// iOS: when the sheet's content appeared (RecKit.mono, ms), the start of its presentation.
    @State var shownAt = 0.0
    #endif

    private var edits: [String: EWEdit] { EWEdits.shared.items }

    func body(content: Content) -> some View {
        titled(content)
            .toolbar {
                if !edits.isEmpty {
                    // index.html:921 #discard (aria-label 放弃) / #save (aria-label 完成)
                    ToolbarItem(placement: .cancellationAction) {
                        discardButton
                            .accessibilityLabel("放弃")
                            .endsEditingOnTap()
                            .confirmationDialog("放弃这 \(edits.count) 项改动？", isPresented: $discardAsk,
                                                titleVisibility: .visible) {
                                Button("放弃改动", role: .destructive) { EWEdits.shared.items = [:] }   // view.js:2950
                            }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        confirmButton
                            .accessibilityLabel("完成")
                            .disabled(EWEdits.shared.saving)
                    }
                }
            }
            // index.html:933-939 #confirm; doSave (view.js:1609-1617). A sheet, not an alert: an alert's message is plain
            // text, and each change shows its name, the new value and the old one struck through, a shift skip in red
            // (index.html:875-878). ✕ (再想想) leading and 寄出 N 项 trailing (HIG Sheets: "the Cancel button belongs on
            // the leading edge of the top toolbar. When present, the Done button belongs on the trailing edge").
            .sheet(isPresented: $reviewing, onDismiss: {
                sheetUp = false
                if let f = heldFail { heldFail = nil; failNote = f }
            }) {
                NavigationStack {
                    List {
                        // each change: its name, the new value on its own line in the label colour, the old one under it
                        // grey and struck through (HIG Lists and tables: "Short, succinct text can help minimize
                        // truncation and wrapping"); a shift skip stays red, as the web's .diff.skip
                        ForEach(EWSave.review(edits)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: line.title)
                                    .foregroundStyle(line.skip ? Color.red : Color.primary)
                                if let old = line.old, let new = line.new {
                                    Text(verbatim: new).font(.subheadline).foregroundStyle(Color.primary)
                                    Text(verbatim: old).font(.subheadline).strikethrough().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .navigationTitle("寄出前看一下")
                    #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelReviewButton
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            // doSave (view.js:1617) names the button by how many orders go out: 「寄出 N 项」
                            Button("寄出 \(edits.count) 项", role: .confirm) { go() }
                                .disabled(EWEdits.shared.saving)
                        }
                    }
                }
                // a few rows in a full-height sheet: half height first, pulled up when the list is long (HIG Sheets: "In
                // an iPhone app, consider supporting the medium detent to allow progressive disclosure of the sheet's
                // content.")
                .presentationDetents([.medium, .large])
                #if os(Android)
                // the sheet's first drawn frame and each press's touch-down, both on the events' own clock
                // (ReviewGateStamps); the sheet is its own dialog window, which the activity's touch feed (Main.kt
                // dispatchTouchEvent) never sees
                .composeModifier { ReviewGateStamps(seq: reviewSeq) }
                #endif
                .onAppear {
                    gated = edits.values.contains(where: EWSave.isSkip)   // view.js:1619
                    #if !os(Android)
                    shownAt = RecKit.mono()
                    #endif
                }
            }
            // view.js:3007: ask("有改动没发出去", …, "好", false, { single: true })
            .alert("有改动没发出去", isPresented: Binding(get: { failNote != nil }, set: { if !$0 { failNote = nil } })) {
                Button("好") {}
            } message: {
                Text(verbatim: failNote ?? "")
            }
    }

    @ViewBuilder private var discardButton: some View {
        #if os(Android)
        Button { endEditing(); discardAsk = true } label: { Image(systemName: "xmark") }
        #else
        Button(role: .cancel) { endEditing(); discardAsk = true }
        #endif
    }

    /// The review sheet's leading button: the system's ✕ (iOS 26 `Button(role: .cancel)`, as 密码 › 新建, P12), named
    /// 再想想 for VoiceOver (HIG Toolbars: "Prefer simple, recognizable symbols for items instead of text"). Android: the
    /// same ✕ glyph as the paste sheet's cancel (PhonePage), as skip-ui has no system cancel symbol for a role-only button;
    /// named 再想想 on the image, as skip-ui otherwise gives the icon its own name for TalkBack (DiagAccessory.swift).
    @ViewBuilder private var cancelReviewButton: some View {
        #if os(Android)
        Button(role: .cancel) { reviewing = false } label: {
            Image(systemName: "xmark").accessibilityLabel("再想想")
        }
        #else
        Button(role: .cancel) { reviewing = false }
            .accessibilityLabel("再想想")
        #endif
    }

    @ViewBuilder private var confirmButton: some View {
        #if os(Android)
        Button { openReview() } label: { Image(systemName: "checkmark") }
        #else
        Button(role: .confirm) { openReview() }
        #endif
    }

    private func openReview() {
        reviewSeq += 1
        #if os(Android)
        ReviewGateClock.reset(reviewSeq)
        #endif
        sheetUp = true
        reviewing = true
    }

    /// #go (view.js:2954-3016). Android: a press that began in the first 400 ms while a skip is listed does nothing and
    /// the sheet stays.
    private func go() {
        // view.js:2953-2955 judges by when the press began. `.disabled` alone did not hold on Android: of six presses begun
        // 0.35-0.40 s after ✓ and let go after the gate opened, three sent (test pass 1, 问题 11).
        if gated {
            #if os(Android)
            // the press's own touch-down time against the sheet's first frame, both SystemClock.uptimeMillis: the times
            // the app took when it got round to handling them let an early press through on a slow emulator (0.5.2 r3
            // and-final5). The down is used once, so a later press with none (TalkBack's activate) is judged by now.
            let shown = ReviewGateClock.shownAt(), down = ReviewGateClock.takeDown()
            let open = MistapGate.allows(shownAt: shown > 0 ? shown : nil, downAt: down > 0 ? down : nil,
                                         now: ReviewGateClock.now())
            #else
            // iOS: UIKit takes no touches while the sheet is being presented (replay gate.early), so a press reaching
            // 寄出 began after that; this also holds the 400 ms from the presentation's start, judged at the release
            let open = MistapGate.allows(shownAt: shownAt, downAt: nil, now: RecKit.mono())
            #endif
            if !open { return }
        }
        let pool = EWEdits.shared
        guard !pool.saving else { return }   // 2026-09-01: three taps sent three times; one flag across the tabs
        pool.saving = true
        reviewing = false
        Task {
            let sent = pool.items
            let r = await EWSave.send(sent)
            // view.js:3003: the sent ones go, the unsent stay on the page. Only a key that went out and still holds the
            // value sent is dropped: a send takes up to a minute per order, and writing back the copy taken at the start
            // lost a change made meanwhile on any tab, and the new value of a row changed again (edge audit 1a).
            pool.items = pool.items.filter { k, v in r.left[k] != nil || sent[k] != v }
            pool.saving = false
            if sheetUp { heldFail = r.failure } else { failNote = r.failure }
        }
    }

    /// Branches on `title` only (fixed per tab), so a first edit never swaps the page's view identity.
    /// StatusTab passes none and keeps the title StatusPage sets.
    @ViewBuilder
    private func titled(_ content: Content) -> some View {
        if let title {
            content.navigationTitle(Self.title(tab: title, count: edits.count))
        } else {
            content
        }
    }

    /// The bar's title: the tab's name, also while changes wait (it said 「待保存 N 项」 and the page lost its name).
    static func title(tab: String, count: Int) -> String { tab }

    /// The line under the title while changes wait over the shared pool: 「N 项未寄出」; nil when none wait.
    static func unsentLine(count: Int) -> String? { count == 0 ? nil : "\(count) 项未寄出" }
}

/// view.js:1619 / 2953-2955 (goArmedAt, goPressAt): on a review that lists a skip, 寄出 counts only for a press that
/// touched down at least 400 ms after the sheet was first on screen. Both times are on one clock in ms: Android the
/// events' own SystemClock.uptimeMillis (ReviewGateClock), iOS RecKit.mono. `shownAt` nil = not drawn yet, so nothing
/// on it can have been seen; `downAt` nil = no touch-down recorded (an accessibility activate), judged by `now`.
enum MistapGate {
    static let ms = 400.0

    static func allows(shownAt: Double?, downAt: Double?, now: Double) -> Bool {
        guard let shownAt else { return false }
        return (downAt ?? now) - shownAt >= ms
    }
}
