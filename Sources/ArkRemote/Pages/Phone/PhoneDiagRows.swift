import SwiftUI
import SkipFuse
#if !os(Android) && canImport(UIKit)
import UIKit
#endif

/// 诊断记录 switch, 运行自检 and the record sheet, in the 这台手机 section (web: #diagsw, #selfcheck, view.js:600-602, 1310-1322).
/// The Apple page of the same use: Settings › Privacy & Security › Analytics & Improvements (P13,
/// evidence/app-pages-1007/apple/P13-设置-分析数据列表.png): a switch that starts recording on this device and the
/// records to look at and share. The switch is its own feedback (no 「诊断记录已开 / 已关」 toast, shell API id 266; HIG
/// Alerts: "Avoid using an alert merely to provide information"); 运行自检 shows the system spinner in its row while it
/// runs, as Settings › General › Software Update does while it checks.
/// What turning 诊断记录 on brings; under the switch on Android, the diagnostics section's footer on iOS.
let phoneDiagHint = "开着时记下这台手机收发消息、网络通断和机器状态的变化。每页底下会出现诊断条，出问题时点「标出问题」把记录发去排查。"

struct PhoneDiagRows: View {
    var appVersion: String

    @State var diagOn = DiagLog.shared.enabled
    /// 「清空诊断记录」 asks first: right under 「分享诊断记录」, one stray tap wiped the record that was to be sent (edge audit 40).
    @State var clearAsk = false

    var body: some View {
        // the count is observed so the row below is redrawn after each new event
        let count = DiagCounter.shared.count >= 0 ? DiagLog.shared.count : 0
        Toggle(isOn: Binding(get: { diagOn }, set: { v in
            diagOn = v
            DiagLog.shared.setEnabled(v)
            if v { DiagWatch.start() }
        })) {
            // what turning it on brings: the bar under every page with the button that sends the record (HIG Toggles:
            // say what it does; the switch's own effects were not said)
            #if os(Android)
            PhoneRowLabel(title: "诊断记录", hint: phoneDiagHint)
            #else
            // iOS: the row's own words only, the explanation in the section's footer (PhonePage) — HIG Lists and tables
            // "Keep item text succinct so row content is comfortable to read." (review 10-26 #4: it was the one row of
            // 这台手机 with two lines under it)
            Text("诊断记录")
            #endif
        }
        .onAppear { if diagOn { DiagWatch.start(); DiagUI.shared.start() } }
        if diagOn {
            // the same sheet a tap on the 诊断记录 bar opens (Pages/Shell/DiagAccessory.swift DiagSheet presents it on the
            // TabView), so the two ways in show one thing and the page's pull to refresh never reaches the sheet's list
            // the count as the row's grey value, as P13 puts a number on the right of its row
            Button { DiagUI.shared.openSheet() } label: {
                LabeledContent("分享诊断记录", value: "\(count) 条")
            }
            Button("清空诊断记录", role: .destructive) { clearAsk = true }
                // as 清除密钥: an action sheet from the button (P10 / N9; HIG Action sheets "Use an action sheet — not
                // an alert — to offer choices related to an intentional action")
                .confirmationDialog("清空诊断记录？", isPresented: $clearAsk, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { DiagLog.shared.clear() }
                    Button("取消", role: .cancel) {}
                } message: {
                    // no count: the record keeps growing while the dialog is up, and a number frozen in it did not
                    // match the row behind (HIG Action sheets: "Provide a message only if necessary.")
                    Text("记下的都会删掉，还没分享的找不回来。")
                }
        }
        // 运行自检 does not read the record (SelfCheck.run), so it is not hidden behind the 诊断记录 switch (view.js:602 hid
        // it); it stays under the diagnostics rows (decision P1). The running flag and the result sheet live in
        // SelfCheckRun and the sheet is on PhonePage outside its .id(reselect): a reselect of 手机 rebuilds this List on
        // Android (D39), and @State here went back to 「运行自检」 mid-run, the result sheet never coming up.
        selfCheckButton
    }

    @ViewBuilder private var selfCheckButton: some View {
        let run = SelfCheckRun.shared
        Button {
            guard !run.checking else { return }
            run.checking = true
            Task {
                _ = await SelfCheck.run()   // kept in LastSelfCheck; the sheet reads it from there
                run.checking = false
                run.shown = true
            }
        } label: {
            if run.checking {
                LabeledContent("正在自检…") { ProgressView() }
            } else {
                Text("运行自检")
            }
        }
        .disabled(run.checking)
    }
}

/// view.js showDiagSheet(rec, "accept"): 「自检结果」 with the pass count, 复制 / 分享 / 关闭.
/// The web's last clause 「关闭后页面重新打开，换回你自己的数据」 is left out: the app's self check runs on its own data
/// and closing reopens nothing.
struct SelfCheckSheet: View {
    var close: () -> Void

    var body: some View {
        let rec = LastSelfCheck.stored() ?? .null
        let json = rec.encodedString()
        // one row per check, so a failure says which check and why (BOARD/App-待他定项-从记录定-1014.md P5; his 09-07
        // 14:59 「描述模糊是第一大禁止」); no file format or size (HIG Writing: "avoiding jargon")
        let rows = (rec["rows"]?.array ?? []).map {
            SelfCheckItem(name: $0["name"]?.jsString ?? "", ok: $0["ok"]?.truthy ?? false, detail: $0["detail"]?.jsString ?? "",
                          neutral: $0["neutral"]?.truthy ?? false, fix: $0["fix"]?.jsString ?? "")
        }
        // what the list is and what to do with it (P13 opens with one sentence of what the page is)
        DiagSheetBox(title: "自检结果", message: "查这台手机连机器的每一步。要别人帮忙查，复制或分享给对方。", json: json, canShare: true,
                     checks: rows, close: close)
    }
}

/// view.js showDiagSheet(rec): 「诊断记录」 for DiagUI.sheetRecord, redrawn while its upload moves on (the web's
/// 「诊断记录已生成」; HIG Toolbars: "Aim for a word or short phrase that distills the purpose of the window").
struct DiagRecordSheet: View {
    var close: () -> Void

    var body: some View {
        let rec = DiagUI.shared.sheetRecord ?? .null
        let m = DiagUI.sheetMessage(rec)
        // once the record is in the bucket there is nothing left to hand over: 分享 goes (view.js sent())
        DiagSheetBox(title: "诊断记录", message: m.text, json: m.json, canShare: !m.sent, close: close)
    }
}

/// index.html #diagsheet: title, message, then 复制 / 分享 / 关闭.
/// The system's sheet as P12 / P13 have it: a navigation bar with the title and the close ✕ leading (HIG Sheets: "the
/// Cancel button belongs on the leading edge of the top toolbar"), the message as the grey text over the two actions
/// (P13 puts its explanation above the rows, not in a card), the sheet at half height first and pulled up for more
/// (自检结果, whose rows would hide 复制 / 分享, opens at full height)
/// (HIG Sheets: "In an iPhone app, consider supporting the medium detent to allow progressive disclosure of the
/// sheet's content."). Nothing measured: the list scrolls a long 自检结果 by itself, never cut (no lineLimit).
/// 复制's own label says 「已复制整份记录」 once it took (shell API id 272: "a button whose label turns into 「已复制」"),
/// no toast; 分享 is the system share sheet (DiagShare), and only its failure is said, in this sheet's own alert
/// (view.js ask("分享没成", …, "好", false, { single: true })).
struct DiagSheetBox: View {
    var title: String
    var message: String
    var json: String
    var canShare: Bool
    /// 自检结果: one row per check above the buttons.
    var checks: [SelfCheckItem] = []
    var close: () -> Void

    @State var copied = false
    #if !os(Android)
    /// 自检结果 opens at full height: its rows fill the half-height sheet and pushed 复制 / 分享, its only actions, below
    /// the fold (HIG review 1014). 诊断记录 has no rows and opens at half height.
    @State var detent: PresentationDetent
    #endif

    init(title: String, message: String, json: String, canShare: Bool, checks: [SelfCheckItem] = [],
         close: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.json = json
        self.canShare = canShare
        self.checks = checks
        self.close = close
        #if !os(Android)
        _detent = State(initialValue: checks.isEmpty ? .medium : .large)
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                listSection("diag-checks", if: !checks.isEmpty) {
                    Section {
                        ForEach(checks.indices, id: \.self) { i in checkRow(checks[i]) }
                    }
                }
                Section {
                    Button(copied ? "已复制整份记录" : "复制") {
                        PhoneLink.copy(json)
                        copied = true
                    }
                    if canShare {
                        // view.js share.onclick (DiagShare)
                        Button("分享") { DiagShare.shared.share(json, title: title == "自检结果" ? "自检结果" : "诊断记录") }
                    }
                } header: {
                    Text(verbatim: message).textCase(nil)
                }
            }
            .readableColumn()   // iPhone Duo inner display: one centred column (Pages/Shell/ReadableColumn.swift)
            .navigationTitle(title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeButton
                        .accessibilityLabel("关闭")
                }
            }
        }
        #if os(Android)
        .presentationDetents([.medium, .large])
        #else
        .presentationDetents([.medium, .large], selection: $detent)
        #endif
        // a new record (the line's upload moved on, or another 分享诊断记录) is not the one that was copied
        .onChange(of: json) { _, _ in copied = false }
        .alert("分享没成", isPresented: Binding(get: { DiagShare.shared.failNote != nil },
                                                set: { if !$0 { DiagShare.shared.failNote = nil } })) {
            Button("好") {}
        } message: {
            Text(verbatim: DiagShare.shared.failNote ?? "")
        }
    }

    /// A passed check: its name and a grey value of what was found with 「通过」 (「有网 · 通过」), no colour (decision P5
    /// keeps the word and no colour; the value tells what was checked). A normal state that is not a pass (machine off,
    /// optional key not set): its words grey, no mark. A failed one: its name with what failed and what to do under it,
    /// and the system red ✗ (an error in Apple's system colours; named 没通过 for VoiceOver).
    @ViewBuilder private func checkRow(_ c: SelfCheckItem) -> some View {
        if c.ok || c.neutral {
            LabeledContent(c.name) {
                Text(c.neutral ? c.detail : [c.detail, "通过"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name)
                    Text([c.detail, c.fix].filter { !$0.isEmpty }.joined(separator: "，")).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                symbol("xmark.circle.fill", android: "Icons.Filled.Close").foregroundStyle(Color.red)
                    .accessibilityLabel("没通过")
            }
        }
    }

    /// The system's close ✕ (iOS 26 ButtonRole.close), as SaveBar's ✕; Android: the same glyph, skip has no close role.
    @ViewBuilder private var closeButton: some View {
        #if os(Android)
        Button { close() } label: { Image(systemName: "xmark") }
        #else
        Button(role: .close) { close() }
        #endif
    }
}

// The 诊断记录 bar over every tab (DiagOverlay, DiagRoom) is the shell's now: Pages/Shell/DiagAccessory.swift.
