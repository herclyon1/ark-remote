import SwiftUI
import SkipFuse

/// 诊断记录 switch, 运行自检 and the record sheet, in the 这台手机 section (web: #diagsw, #selfcheck, view.js:600-602, 1310-1322).
struct PhoneDiagRows: View {
    var appVersion: String

    @State var diagOn = DiagLog.shared.enabled
    @State var checking = false
    @State var checkShown = false
    @State var recordShown = false

    var body: some View {
        // the count is observed so the row below is redrawn after each new event
        let count = DiagCounter.shared.count >= 0 ? DiagLog.shared.count : 0
        Toggle(isOn: Binding(get: { diagOn }, set: { v in
            diagOn = v
            DiagLog.shared.setEnabled(v)
            if v { DiagWatch.start() }
            Relay.shared.showToast(v ? "诊断记录已开" : "诊断记录已关")   // view.js:1316
        })) {
            PhoneRowLabel(title: "诊断记录", hint: "开着时页面按 ?diag 方式启动：底部一行几何数，分段控件每次操作后弹出记录，可复制 / 分享给我们")
        }
        .onAppear { if diagOn { DiagWatch.start(); DiagUI.shared.start() } }
        .sheet(isPresented: $checkShown) { SelfCheckSheet { checkShown = false } }
        if diagOn {
            // the web opens this sheet from a tap on the bottom line (DiagOverlay); this row is the same sheet from the page
            Button("分享诊断记录（\(count) 条）") {
                DiagUI.shared.prepareSheet()
                recordShown = true
            }
            .sheet(isPresented: $recordShown) { DiagRecordSheet { recordShown = false } }
            Button("清空诊断记录", role: .destructive) { DiagLog.shared.clear() }
            // view.js:602 #selfcheck is hidden while 诊断记录 is off
            Button(checking ? "正在自检…" : "运行自检") {
                guard !checking else { return }
                checking = true
                Task {
                    _ = await SelfCheck.run()   // kept in LastSelfCheck; the sheet reads it from there
                    checking = false
                    checkShown = true
                }
            }
            .disabled(checking)
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

    var body: some View {
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
                    ShareLink(item: json) { Text("分享") }
                        .frame(maxWidth: .infinity)
                }
                Button("关闭") { close() }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// seg-frames-logger.js 件 B and #diagline over every tab while 诊断记录 is on: the red 「就是这里」 button bottom-right with
/// its word panel, and the status line bottom-left above the tab bar (tap = the record sheet). Meant to sit over the
/// TabView next to ToastLayer (ContentView).
struct DiagOverlay: View {
    @State var wordsOpen = false

    #if os(Android)
    private static let tabBar: CGFloat = 80   // the Material navigation bar
    #else
    private static let tabBar: CGFloat = 49
    #endif
    private static let dark = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)

    var body: some View {
        let ui = DiagUI.shared
        ZStack {
            if ui.on {
                // #diagline: left 12, right 88, 8 above the tab bar; a tap opens the copy / share sheet
                Text(ui.line)
                    .font(.caption)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Self.dark.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { ui.openSheet() }
                    .padding(.leading, 12).padding(.trailing, 88).padding(.bottom, Self.tabBar + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                // #diagmark: right 12, 96 above the safe-area bottom (47 above the iPhone tab bar)
                VStack(alignment: .trailing, spacing: 8) {
                    if wordsOpen {
                        VStack(spacing: 6) {
                            ForEach(DiagUI.markWords, id: \.self) { w in
                                markWord(w, word: w)
                            }
                            markWord("直接发（不选词）", word: nil)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                        .background(Self.dark.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button { wordsOpen.toggle() } label: {
                        Text("就是这里")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Color(red: 1, green: 59 / 255, blue: 48 / 255)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12).padding(.bottom, Self.tabBar + 47)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
        .onChange(of: ui.on) { _, on in if !on { wordsOpen = false } }
        .sheet(isPresented: Binding(get: { DiagUI.shared.sheetOpen }, set: { DiagUI.shared.sheetOpen = $0 })) {
            DiagRecordSheet { DiagUI.shared.sheetOpen = false }
        }
    }

    private func markWord(_ title: String, word: String?) -> some View {
        Button {
            DiagUI.shared.mark(word)
            wordsOpen = false
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
