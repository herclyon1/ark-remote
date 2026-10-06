import SwiftUI
import SkipFuse

/// 诊断记录 switch, its record, 运行自检 and 清空 as one section of the 手机 tab (web: #diagsw, #selfcheck,
/// view.js:600-602, 1310-1322). A Toggle shows its own state; the record and the self check are handed over with the
/// share sheet, which carries Copy (HIG Activity views: "Activity views present sharing activities like messaging and
/// actions like Copy and Print", https://developer.apple.com/design/human-interface-guidelines/activity-views).
struct PhoneDiagRows: View {
    @State var diagOn = DiagLog.shared.enabled
    /// 「清空诊断记录」 asks first: one stray tap wiped the record that was to be sent (edge audit 40).
    @State var clearAsk = false

    var body: some View {
        // the count is observed so the rows below are redrawn after each new event
        let count = DiagCounter.shared.count >= 0 ? DiagLog.shared.count : 0
        let run = SelfCheckRun.shared
        Section {
            Toggle("诊断记录", isOn: $diagOn)
                .onChange(of: diagOn) { _, on in
                    DiagLog.shared.setEnabled(on)
                    if on { DiagWatch.start() }
                }
                // on the row, not the Section: skip-ui's List finds its sections by type, so a modifier around the
                // Section is not safe (MonthCardRows.swift)
                .onAppear { if diagOn { DiagWatch.start(); DiagUI.shared.start() } }
            if diagOn {
                // the web opens this from a tap on the bottom line (DiagAccessory); here it is pushed from the page, by
                // value (PhoneRoute, PhonePage's navigationDestination) so ContentView's path pops it on a reselect (D39)
                NavigationLink(value: PhoneRoute.diagRecord) {
                    LabeledContent("分享诊断记录", value: "\(count) 条")
                }
                // view.js:602 #selfcheck is hidden while 诊断记录 is off. The running flag and the result live in
                // SelfCheckRun: a reselect of 手机 rebuilds this List on Android (D39) and drops this view's @State.
                Button {
                    run.run()
                } label: {
                    LabeledContent("运行自检") {
                        if run.checking { ProgressView() }
                    }
                }
                .disabled(run.checking)
                if let rec = run.record {
                    selfCheckResult(rec)
                }
                Button("清空诊断记录", role: .destructive) { clearAsk = true }
                    .disabled(count == 0)
                    .confirmationDialog("清空诊断记录？", isPresented: $clearAsk, titleVisibility: .visible) {
                        Button("清空 \(count) 条", role: .destructive) { DiagLog.shared.clear() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("还没分享的就找不回来了。")
                    }
            }
        } footer: {
            Text("开着时记下这台手机收发消息、网络通断和机器状态的变化；出问题时按「就是这里」送出整份记录，或在这里分享给我们。")
        }
    }

    /// The last 运行自检 (LastSelfCheck): 通过 N / M as the value, the failed checks under the label, and the whole
    /// JSON to share (the web's 自检结果 sheet: 「通过 x / y，不通过 n 项」, copy / share).
    @ViewBuilder
    private func selfCheckResult(_ rec: JSONValue) -> some View {
        let total = Int(rec["total"]?.number ?? 0), fails = Int(rec["fails"]?.number ?? 0)
        let failed = (rec["rows"]?.array ?? []).filter { $0["ok"]?.bool == false }.compactMap { $0["name"]?.string }
        LabeledContent {
            Text("通过 \(total - fails) / \(total)")
        } label: {
            if failed.isEmpty {
                Text("自检结果")
            } else {
                PhoneRowLabel(title: "自检结果", hint: "没过：" + failed.joined(separator: "、"))
            }
        }
        ShareLink("分享自检结果", item: rec.encodedString(), subject: Text("自检结果"))
    }
}

/// view.js showDiagSheet as a page: what the record is (rows) and the share sheet for it. Pushed from the 手机 tab;
/// in a sheet from the status line (DiagRecordSheet). The record is taken once when the view appears
/// (DiagUI.prepareSheet), not in body: an export writes the log to storage (DiagLog.exportObject → persist).
struct DiagRecordView: View {
    var body: some View {
        let ui = DiagUI.shared
        List {
            if let rec = ui.sheetRecord {
                let f = DiagUI.facts(rec)
                Section {
                    LabeledContent("条数", value: "\(f.events) 条")
                    LabeledContent("大小", value: "\(f.kb) KB")
                    if !f.marks.isEmpty {
                        LabeledContent("你标的", value: f.marks)
                    }
                    LabeledContent("上传", value: f.upload)
                }
                Section {
                    ShareLink("分享诊断记录", item: f.json, subject: Text("诊断记录"))
                        .disabled(f.sent)
                } footer: {
                    Text(f.sent ? "这份已经送到，不用再分享。" : "送不到时分享出去，比如粘到聊天里。")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("诊断记录")
        .onAppear { ui.prepareSheet() }
    }
}

/// DiagRecordView in a sheet, Close leading (opened from the status line, which is outside every NavigationStack).
struct DiagRecordSheet: View {
    var body: some View {
        NavigationStack {
            DiagRecordView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { DiagUI.shared.sheetOpen = false }
                    }
                }
        }
    }
}

/// seg-frames-logger.js 件 B 「就是这里」 and its word panel (MARK_WORDS) as a system Menu. The mark itself has no
/// system equivalent (a one-tap "send what you see now" control); it is a system bordered button tinted red.
struct DiagMarkMenu: View {
    var body: some View {
        Menu {
            ForEach(DiagUI.markWords, id: \.self) { w in
                Button(w) { DiagUI.shared.mark(w) }
            }
            Button("直接发（不选词）") { DiagUI.shared.mark(nil) }
        } label: {
            Text("就是这里")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}

/// #diagline and #diagmark as one bar: the status line (a tap opens the record sheet) and 「就是这里」.
/// On iOS it is the tab view's bottom accessory ("Places a view as the bottom accessory of the tab view",
/// https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)), via DiagBottomAccessory.
struct DiagAccessory: View {
    #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    private var lines: Int { placement == .inline ? 1 : 2 }
    #else
    private var lines: Int { 2 }
    #endif

    var body: some View {
        let ui = DiagUI.shared
        HStack {
            Button {
                ui.openSheet()
            } label: {
                Text(ui.line)
                    .font(.footnote)
                    .lineLimit(lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            DiagMarkMenu()
        }
        .padding(.horizontal)
    }
}

/// What ContentView puts on its TabView in place of `.overlay { DiagOverlay() }`: on iOS the bar is the tab view's
/// bottom accessory while 诊断记录 is on, and the record sheet opens from the TabView; on Android (skip-ui has no
/// tabViewBottomAccessory, Containers/TabView.swift:1236-1239 unavailable) it is DiagOverlay.
struct DiagBottomAccessory: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        let ui = DiagUI.shared
        content
            .tabViewBottomAccessory(isEnabled: ui.on) { DiagAccessory() }
            .sheet(isPresented: Binding(get: { DiagUI.shared.sheetOpen }, set: { DiagUI.shared.sheetOpen = $0 })) {
                DiagRecordSheet()
            }
            .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
        #else
        content.overlay { DiagOverlay() }
        #endif
    }
}

/// Android: the bar over every tab, above the navigation bar, while 诊断记录 is on. skip-ui has neither
/// tabViewBottomAccessory (Containers/TabView.swift:1236-1239) nor safeAreaInset (skip-fuse-ui Layout/SafeArea.swift:19-22,
/// unavailable), so it is placed over the TabView from the bottom edge. iOS / macOS: nothing drawn (DiagBottomAccessory
/// carries the bar); it only starts the recorder at launch while ContentView still overlays it.
struct DiagOverlay: View {
    #if os(Android)
    /// The Material 3 navigation bar's container height, 80 dp (https://m3.material.io/components/navigation-bar/specs),
    /// which skip-ui's TabView draws at the bottom.
    private static let navigationBar: CGFloat = 80
    #endif

    var body: some View {
        let ui = DiagUI.shared
        #if os(Android)
        ZStack {
            if ui.on {
                DiagAccessory()
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { DiagBarHeight.shared.value = $0 }
                    .padding(.horizontal)
                    .padding(.bottom, Self.navigationBar + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
        .sheet(isPresented: Binding(get: { DiagUI.shared.sheetOpen }, set: { DiagUI.shared.sheetOpen = $0 })) {
            DiagRecordSheet()
        }
        #else
        Color.clear
            .allowsHitTesting(false)
            .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
        #endif
    }
}

#if os(Android)
/// The Android bar's measured height (DiagOverlay), for DiagRoom's bottom margin.
@MainActor @Observable final class DiagBarHeight {
    static let shared = DiagBarHeight()
    var value: CGFloat = 0
}
#endif

/// Android: bottom room under each tab's pages while 诊断记录 is on, so the last row scrolls up past DiagOverlay (the
/// bar sat over 状态 「查看全部」 and 鸣潮 「周本打第几个」 with nothing to scroll them clear, test pass 3). skip-ui's
/// contentMargins reaches the LazyColumn contentPadding (List.swift:290-294; ScrollView.swift:322-336). On each tab's
/// NavigationStack (ContentView.tabs), so pushed pages get it too; DiagUI.shared.on is read here, in body(content:),
/// because a read in ContentView's body does not redraw the tab roots. iOS: nothing — the system insets the content
/// for the tab view's bottom accessory.
struct DiagRoom: ViewModifier {
    func body(content: Content) -> some View {
        #if os(Android)
        content.contentMargins(.bottom, DiagUI.shared.on ? DiagBarHeight.shared.value + 8 : 0)
        #else
        content
        #endif
    }
}
