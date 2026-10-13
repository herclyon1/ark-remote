import SwiftUI
import SkipFuse
#if !os(Android) && canImport(UIKit)
import UIKit
#endif

/// 诊断记录 switch, 运行自检 and the record sheet, in the 这台手机 section (web: #diagsw, #selfcheck, view.js:600-602, 1310-1322).
struct PhoneDiagRows: View {
    var appVersion: String

    @State var diagOn = DiagLog.shared.enabled
    @State var recordShown = false
    /// 「清空诊断记录」 asks first: right under 「分享诊断记录」, one stray tap wiped the record that was to be sent (edge audit 40).
    @State var clearAsk = false

    var body: some View {
        // the count is observed so the row below is redrawn after each new event
        let count = DiagCounter.shared.count >= 0 ? DiagLog.shared.count : 0
        Toggle(isOn: Binding(get: { diagOn }, set: { v in
            diagOn = v
            DiagLog.shared.setEnabled(v)
            if v { DiagWatch.start() }
            Relay.shared.showToast(v ? "诊断记录已开" : "诊断记录已关")   // view.js:1316
        })) {
            PhoneRowLabel(title: "诊断记录", hint: "开着时记下这台手机收发消息、网络通断和机器状态的变化，可复制 / 分享给我们")
        }
        .onAppear { if diagOn { DiagWatch.start(); DiagUI.shared.start() } }
        if diagOn {
            // the web opens this sheet from a tap on the bottom line (DiagOverlay); this row is the same sheet from the page
            Button("分享诊断记录（\(count) 条）") {
                DiagUI.shared.prepareSheet()
                recordShown = true
            }
            .sheet(isPresented: $recordShown) { DiagRecordSheet { recordShown = false } }
            Button("清空诊断记录", role: .destructive) { clearAsk = true }
                .alert("清空诊断记录？", isPresented: $clearAsk) {   // as PhonePage's 「清除密钥？」
                    Button("清空", role: .destructive) { DiagLog.shared.clear() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这台手机记下的 \(count) 条都会删掉，还没分享的就找不回来了。")
                }
            // view.js:602 #selfcheck is hidden while 诊断记录 is off. The running flag and the result sheet live in
            // SelfCheckRun and the sheet is on PhonePage outside its .id(reselect): a reselect of 手机 rebuilds this List
            // on Android (D39), and @State here went back to 「运行自检」 mid-run, the result sheet never coming up.
            let run = SelfCheckRun.shared
            Button(run.checking ? "正在自检…" : "运行自检") {
                guard !run.checking else { return }
                run.checking = true
                Task {
                    _ = await SelfCheck.run()   // kept in LastSelfCheck; the sheet reads it from there
                    run.checking = false
                    run.shown = true
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

/// index.html #diagsheet: title, message, then 复制 / 分享 / 关闭 in one row.
struct DiagSheetBox: View {
    var title: String
    var message: String
    var json: String
    var canShare: Bool
    var close: () -> Void

    #if !os(Android)
    /// The title + message's own height and the button row's (padding in both), measured to fit the sheet to them.
    @State private var textHeight: CGFloat = 0
    @State private var rowHeight: CGFloat = 0
    #endif

    var body: some View {
        #if os(Android)
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("复制") {
                    PhoneLink.copy(json)
                    Relay.shared.showToast("已复制整份记录")   // view.js:3074
                }
                .frame(maxWidth: .infinity)
                if canShare {
                    // view.js share.onclick: every outcome is said (DiagShare)
                    Button("分享") { DiagShare.shared.share(json, title: title == "自检结果" ? "自检结果" : "诊断记录") }
                        .frame(maxWidth: .infinity)
                }
                Button("关闭") { close() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(16)
        // the page's toast layer and alert are under the sheet (a sheet is its own presentation on both platforms):
        // 「已复制整份记录」 / 「已交给分享」 / 「分享已取消」 show here too (both layers clear the same Relay.toast), and
        // 「分享没成」 is the sheet's own alert (view.js ask("分享没成", …, "好", false, { single: true }))
        .overlay { ToastLayer() }
        .alert("分享没成", isPresented: Binding(get: { DiagShare.shared.failNote != nil },
                                                set: { if !$0 { DiagShare.shared.failNote = nil } })) {
            Button("好") {}
        } message: {
            Text(verbatim: DiagShare.shared.failNote ?? "")
        }
        #else
        // A sheet with no detents is .large: three lines and a button row came up full screen over a blank page
        // (sheet06 cell 5). It is fitted to the content instead, .height(_:) from the measured text and row
        // (developer.apple.com/documentation/swiftui/view/presentationdetents(_:), PresentationDetent.height(_:)).
        // Short text sits in a plain VStack fitted to it; a long 自检结果 (isLong) scrolls over the pinned row at .medium,
        // draggable to .large, never cut.
        Group {
            if Self.isLong(message) {
                // a long 自检结果: the text scrolls over the pinned row, the sheet at .medium, draggable to .large
                ScrollView { textBlock }
                    .scrollBounceBehavior(.basedOnSize)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionRow }
            } else {
                // a few lines: no ScrollView (one inside the 自检结果 sheet kept its text scrolled down by about 30 pt,
                // the title cut at the sheet's top edge over a gap above the buttons, diagsheet frames4 / frames5)
                VStack(spacing: 0) {
                    textBlock
                    actionRow
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        // as the Android branch: the toast layer and the 「分享没成」 alert ride on the sheet
        .overlay { ToastLayer() }
        .alert("分享没成", isPresented: Binding(get: { DiagShare.shared.failNote != nil },
                                                set: { if !$0 { DiagShare.shared.failNote = nil } })) {
            Button("好") {}
        } message: {
            Text(verbatim: DiagShare.shared.failNote ?? "")
        }
        .presentationDetents(detents)
        #endif
    }

    #if !os(Android)
    /// Past about four lines on a phone the text would not fit a fitted sheet under half the screen: it scrolls instead.
    /// Decided from the text, not from a measured height, so the layout never flips while it is measured.
    private static func isLong(_ message: String) -> Bool { message.count > 160 }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)   // its whole height, not what a detent leaves it
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
    }

    private var actionRow: some View {
        actions
            .padding(.top, 10).padding([.horizontal, .bottom], 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("复制") {
                PhoneLink.copy(json)
                Relay.shared.showToast("已复制整份记录")   // view.js:3074
            }
            .frame(maxWidth: .infinity)
            if canShare {
                // view.js share.onclick: every outcome is said (DiagShare)
                Button("分享") { DiagShare.shared.share(json, title: title == "自检结果" ? "自检结果" : "诊断记录") }
                    .frame(maxWidth: .infinity)
            }
            Button("关闭") { close() }
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    /// Until both parts are measured, about the two-line sheet's own height (168 pt measured on the 诊断记录已生成 sheet,
    /// simulator shots-1006): from .medium it would open at half the screen and then shrink to fit. Then the
    /// content's height, or .medium / .large when that is over half the screen (the window scene's screen;
    /// UIScreen.main is deprecated).
    private static let firstHeight: CGFloat = 168

    private var detents: Set<PresentationDetent> {
        let fit = textHeight + rowHeight
        guard textHeight > 0, rowHeight > 0 else { return [.height(Self.firstHeight)] }
        // UIKit only: the Mac build (swift test) has no UIApplication; the app itself only runs on iOS and Android
        #if canImport(UIKit)
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height ?? 0
        #else
        let screen: CGFloat = 0
        #endif
        if Self.isLong(message) || (screen > 0 && fit > screen / 2) { return [.medium, .large] }
        return [.height(fit)]
    }
    #endif
}

// The 诊断记录 bar over every tab (DiagOverlay, DiagRoom) is the shell's now: Pages/Shell/DiagAccessory.swift.
