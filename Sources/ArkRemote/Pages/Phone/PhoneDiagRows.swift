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
            .diagRecordAlert(isPresented: $recordShown)
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

/// view.js showDiagSheet: 「自检结果」 / 「诊断记录已生成」 with 复制 / 分享 / 关闭, as a system alert on both platforms.
/// Title, a few lines and three buttons is an alert in Apple's own apps (Maps' 「Allow "Maps" to use your location?」,
/// iOS 27 simulator shots-1006, 10-07): centered, buttons stacked. It was a fitted bottom sheet (DiagSheetBox, 0e5b965 to
/// 70ac451) whose glass showed the red 「就是这里」 button and the toast through it.
/// Any button closes the alert; 复制's toast and 分享's outcome (DiagShare) then show on the page under it.
struct DiagAlert: ViewModifier {
    var title: String
    @Binding var isPresented: Bool
    /// Read when the alert is drawn, so 诊断记录已生成 shows the upload's state as it is then.
    var content: () -> (text: String, json: String, canShare: Bool)

    func body(content view: Content) -> some View {
        let c = isPresented ? content() : (text: "", json: "", canShare: false)
        view.alert(title, isPresented: $isPresented) {
            Button("复制") {
                PhoneLink.copy(c.json)
                Relay.shared.showToast("已复制整份记录")   // view.js:3074
            }
            if c.canShare {
                // view.js share.onclick: every outcome is said (DiagShare)
                Button("分享") { DiagShare.shared.share(c.json, title: title == "自检结果" ? "自检结果" : "诊断记录") }
            }
            Button("关闭", role: .cancel) {}
        } message: {
            Text(verbatim: c.text)
        }
    }
}

extension View {
    /// 「自检结果」 for the stored last self check (LastSelfCheck). The web's last clause 「关闭后页面重新打开，换回你自己的
    /// 数据」 is left out: the app's self check runs on its own data and closing reopens nothing.
    func selfCheckAlert(isPresented: Binding<Bool>) -> some View {
        modifier(DiagAlert(title: "自检结果", isPresented: isPresented) {
            let rec = LastSelfCheck.stored() ?? .null
            let json = rec.encodedString()
            let total = Int(rec["total"]?.number ?? 0), fails = Int(rec["fails"]?.number ?? 0)
            return ("通过 \(total - fails) / \(total)，不通过 \(fails) 项。一份 JSON，\(diagKB(json)) KB。复制后粘到聊天里，或用分享发出。",
                    json, true)
        })
    }

    /// 「诊断记录已生成」 for DiagUI.sheetRecord; once the record is in the bucket there is nothing left to hand over,
    /// so 分享 goes (view.js sent()).
    func diagRecordAlert(isPresented: Binding<Bool>) -> some View {
        modifier(DiagAlert(title: "诊断记录已生成", isPresented: isPresented) {
            let m = DiagUI.sheetMessage(DiagUI.shared.sheetRecord ?? .null)
            return (m.text, m.json, !m.sent)
        })
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
    private static let markLift: CGFloat = 47   // the red button's bottom above the tab bar
    private static let markSize: CGFloat = 64
    /// How far above the tab bar the overlay reaches: the red button's top (the #diagline under it is lower, tabBar + 8
    /// and one caption line; the word panel opens only on a tap). DiagRoom gives the pages this much bottom room.
    static let reach: CGFloat = markLift + markSize

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
                            .frame(width: Self.markSize, height: Self.markSize)
                            .background(Circle().fill(Color(red: 1, green: 59 / 255, blue: 48 / 255)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12).padding(.bottom, Self.tabBar + Self.markLift)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        // Placed from the bottom edge, so with the keyboard's safe area that edge was the keyboard's top: the red button
        // and the line rode up over the keyboard and covered two rows (test pass 6, iOS 27, 鸣潮 「周本打第几个」). They
        // stay above the tab bar, under the keyboard. Android: skip-ui's ignoresSafeArea does nothing without .container
        // (AdditionalViewModifiers.swift:728-733; skip-fuse-ui bridges .keyboard, Layout/SafeArea.swift:13), as before.
        .ignoresSafeArea(.keyboard)
        .onAppear { if ui.on { DiagWatch.start(); ui.start() } }
        .onChange(of: ui.on) { _, on in if !on { wordsOpen = false } }
        .diagRecordAlert(isPresented: Binding(get: { DiagUI.shared.sheetOpen }, set: { DiagUI.shared.sheetOpen = $0 }))
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

/// Bottom room under each tab's pages while 诊断记录 is on, so the last row scrolls up past DiagOverlay (the notice line
/// and the red button sat over 状态 「查看全部」 and 鸣潮 「周本打第几个」 with nothing to scroll them clear, test pass 3).
/// On each tab's NavigationStack (ContentView.tabs), so pushed pages get it too. A ViewModifier, not a wrapper view, so
/// the stack's .tabItem / .tag stay on the TabView's direct child; DiagUI.shared.on is read here, in body(content:),
/// because a read in ContentView's body does not redraw the tab roots (TopNotices, Logic/AppUpdate.swift).
struct DiagRoom: ViewModifier {
    func body(content: Content) -> some View {
        let on = DiagUI.shared.on
        // contentMargins on both: an environment value that reaches the List inside the NavigationStack. On iOS a
        // .safeAreaInset here did not (test pass 4, iOS 27: the last rows sat at the same y with 诊断记录 on and off);
        // on Android skip-ui has no safeAreaInset / safeAreaPadding (SafeArea.swift:73-97, unavailable) and its
        // contentMargins (ScrollView.swift:322-336 → _contentMargins) is added to the LazyColumn contentPadding
        // (List.swift:290-294; pass 4 Android: last row 291 px = 111 pt higher with it on). Every tab page is a List /
        // Form. It also reaches Lists in sheets shown from a page (a blank gap at their end while 诊断记录 is on; the
        // sheet covers the overlay anyway). 0 adds nothing.
        content.contentMargins(.bottom, on ? DiagOverlay.reach : 0)
    }
}
