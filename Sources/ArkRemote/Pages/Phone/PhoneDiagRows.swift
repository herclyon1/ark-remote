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
            PhoneRowLabel(title: "诊断记录", hint: "开着时记下这台手机收发消息、网络通断和机器状态的变化，可复制 / 分享给我们")
        }
        .onAppear { if diagOn { DiagWatch.start(); DiagUI.shared.start() } }
        if diagOn {
            // the same sheet a tap on the 诊断记录 bar opens (Pages/Shell/DiagAccessory.swift DiagSheet presents it on the
            // TabView), so the two ways in show one thing and the page's pull to refresh never reaches the sheet's list
            Button("分享诊断记录（\(count) 条）") { DiagUI.shared.openSheet() }
            Button("清空诊断记录", role: .destructive) { clearAsk = true }
                // as 清除密钥: an action sheet from the button (P10 / N9; HIG Action sheets "Use an action sheet — not
                // an alert — to offer choices related to an intentional action")
                .confirmationDialog("清空诊断记录？", isPresented: $clearAsk, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { DiagLog.shared.clear() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这台手机记下的 \(count) 条都会删掉，还没分享的就找不回来了。")
                }
            // view.js:602 #selfcheck is hidden while 诊断记录 is off. The running flag and the result sheet live in
            // SelfCheckRun and the sheet is on PhonePage outside its .id(reselect): a reselect of 手机 rebuilds this List
            // on Android (D39), and @State here went back to 「运行自检」 mid-run, the result sheet never coming up.
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
}

/// view.js showDiagSheet(rec, "accept"): 「自检结果」 with the pass count, 复制 / 分享 / 关闭.
/// The web's last clause 「关闭后页面重新打开，换回你自己的数据」 is left out: the app's self check runs on its own data
/// and closing reopens nothing.
struct SelfCheckSheet: View {
    var close: () -> Void

    var body: some View {
        let rec = LastSelfCheck.stored() ?? .null
        let json = rec.encodedString()
        let total = Int(rec["total"]?.number ?? 0), fails = Int(rec["fails"]?.number ?? 0)
        DiagSheetBox(title: "自检结果",
                     message: "通过 \(total - fails) / \(total)，不通过 \(fails) 项。一份 JSON，\(diagKB(json)) KB。复制后粘到聊天里，或用分享发出。",
                     json: json, canShare: true, close: close)
    }
}

/// view.js showDiagSheet(rec): 「诊断记录已生成」 for DiagUI.sheetRecord, redrawn while its upload moves on.
struct DiagRecordSheet: View {
    var close: () -> Void

    var body: some View {
        let rec = DiagUI.shared.sheetRecord ?? .null
        let m = DiagUI.sheetMessage(rec)
        // once the record is in the bucket there is nothing left to hand over: 分享 goes (view.js sent())
        DiagSheetBox(title: "诊断记录已生成", message: m.text, json: m.json, canShare: !m.sent, close: close)
    }
}

/// index.html #diagsheet: title, message, then 复制 / 分享 / 关闭.
/// The system's sheet as P12 / P13 have it: a navigation bar with the title and the close ✕ leading (HIG Sheets: "the
/// Cancel button belongs on the leading edge of the top toolbar"), the message and the two actions as list rows. No
/// detents (the system's full-height sheet, as Passwords' 「New Password」, evidence/app-pages-1007/apple/
/// P12-密码-新建弹出单.png) and nothing measured: the list scrolls a long 自检结果 by itself, never cut (no lineLimit).
/// 复制's own label says 「已复制整份记录」 once it took (shell API id 272: "a button whose label turns into 「已复制」"),
/// no toast; 分享 is the system share sheet (DiagShare), and only its failure is said, in this sheet's own alert
/// (view.js ask("分享没成", …, "好", false, { single: true })).
struct DiagSheetBox: View {
    var title: String
    var message: String
    var json: String
    var canShare: Bool
    var close: () -> Void

    @State var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(verbatim: message)
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
                }
            }
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
        // a new record (the line's upload moved on, or another 分享诊断记录) is not the one that was copied
        .onChange(of: json) { _, _ in copied = false }
        .alert("分享没成", isPresented: Binding(get: { DiagShare.shared.failNote != nil },
                                                set: { if !$0 { DiagShare.shared.failNote = nil } })) {
            Button("好") {}
        } message: {
            Text(verbatim: DiagShare.shared.failNote ?? "")
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
