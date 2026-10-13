import SwiftUI

// The one save bar of every tab (view.js updateBar / #confirm): ✕ / 「待保存 N 项」 / ✓ over the one pool of unsaved
// changes (Logic/Edits.swift), and its 「确认这次修改」 review: 保存 → 确认 → 寄出, nothing goes out on a change alone.
// Moved from Pages/Endfield/EWLive.swift: it is the shell's (tab pages only put `.modifier(EWSaveBar(title:))` on).

/// The edit bar and its review sheet, on every tab, over the one pool of unsaved changes (Logic/Edits.swift): the
/// count, ✕ and ✓ cover the changes of all tabs, as the web page's one top bar does.
/// `title`: the page title when nothing waits; while editing the title is 「待保存 N 项」 (view.js:1554 swaps the same span).
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
    #if os(Android)
    /// view.js:1619 goArmedAt: while the review lists a 今天不跑 / 今天照常跑, a press that began in the sheet's first
    /// 400 ms is no confirm (the 08:46 skips, 检查 09-30); the sheet stays. The web judges by when the press began
    /// (view.js:2953-2955 goPressAt), so this is the time the sheet came up plus 400 ms (RecKit.mono, ms), compared with
    /// the press's start (ReviewPress) in go(); 0 = no gate this review (nothing to skip listed). A comparison, not a wait.
    /// iOS needs none: UIKit takes no touches while the sheet is still being presented (replay gate.early).
    @State var opensAt = 0.0
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
                    .navigationTitle("确认这次修改")
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
                // where each press on the sheet began (ReviewPress); the sheet is its own dialog window, which the
                // activity's touch feed (Main.kt dispatchTouchEvent) never sees
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in ReviewPress.down() }
                    .onEnded { _ in ReviewPress.up() })
                .onAppear {
                    opensAt = edits.values.contains(where: EWSave.isSkip) ? RecKit.mono() + 400 : 0   // view.js:1619
                }
                #endif
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
    /// word, as skip-ui has no system cancel symbol for a role-only button.
    @ViewBuilder private var cancelReviewButton: some View {
        #if os(Android)
        Button("再想想", role: .cancel) { reviewing = false }
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
        #if os(Android)
        ReviewPress.reset()
        #endif
        sheetUp = true
        reviewing = true
    }

    /// #go (view.js:2954-3016). Android: a press that began in the first 400 ms while a skip is listed does nothing and
    /// the sheet stays.
    private func go() {
        #if os(Android)
        // view.js:2953-2955 judges by when the press began. `.disabled` alone did not hold on Android: of six presses begun
        // 0.35-0.40 s after ✓ and let go after the gate opened, three sent (test pass 1, 问题 11). No recorded start (the
        // gesture saw nothing, e.g. TalkBack's activate) is judged by now, the press's end.
        if opensAt > 0, (ReviewPress.began ?? RecKit.mono()) < opensAt { return }
        #endif
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
            content.navigationTitle(edits.isEmpty ? title : "待保存 \(edits.count) 项")
        } else {
            content
        }
    }
}

/// When the current press on the review sheet began (Android). skip-ui's simultaneous DragGesture with minimumDistance 0
/// reports the down itself on the Initial pass and consumes nothing (Gesture.swift:972-984 detectSimultaneousDragGestures),
/// then every move: only the first report of a press is its start. The press's up reaches this parent (Initial pass)
/// before the 寄出 button's click, so `began` still holds that press's start when go() runs. One review sheet is up at a
/// time; main thread only.
enum ReviewPress {
    nonisolated(unsafe) static var began: Double? = nil
    nonisolated(unsafe) static var pressing = false

    static func reset() { began = nil; pressing = false }
    static func down() {
        guard !pressing else { return }
        pressing = true
        began = RecKit.mono()
    }
    static func up() { pressing = false }
}
