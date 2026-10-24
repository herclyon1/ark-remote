import SwiftUI

/// The 手机 tab, carried over from the web page (maa-automation web/view.js, the 「这台手机」 and 「游戏账号」 sections;
/// the tab takes the sections whose title matches /^这台手机|^游戏账号/, view.js TABS). PhoneTab fills it from the stores.
struct PhonePageData {
    /// 版本 (the web's 页面版本): the web page shows view.js's ?v= stamp; the app shows its own version.
    var pageVersion: String = ""
    /// 游戏账号 · 已配置: Stamina.status() on the web; empty = 「没有」, and the 清除密钥 button is hidden.
    var staminaStatus: String = ""
    /// The 库街区 key (鸣潮's 体力) and the 森空岛 session (from the machine) are stored.
    var hasKuro = false
    var hasSkland = false
    /// This phone has a mailbox and PIN to put in the 免输入链接; without them 复制免输入链接 is disabled.
    var hasConfig: Bool = true
}

/// What the page's controls do (view.js #tokpaste / #tokclear / #mklink handlers).
struct PhonePageActions {
    /// Stamina.fromPaste(s); throws with the message the web shows in 「没存上」.
    var pasteTokens: (String) throws -> Void = { _ in }
    var clearTokens: () -> Void = {}
    /// Copies the no-input link.
    var copyNoInputLink: () -> PhoneCopyResult = { .noConfig }
    /// A 免输入链接 on the clipboard → its mailbox and PIN (SetupScreen.takeLink's path); false when there is none.
    var pasteNoInputLink: () -> Bool = { false }
}

enum PhoneCopyResult {
    case copied
    /// No mailbox config to put in the link.
    case noConfig
    /// The clipboard did not take it; the link is shown for a long-press copy.
    case failed(String)
}

/// The 手机 tab: 0.4.4's two groups in their order, each part fitted to the Apple page of the same use
/// (BOARD/app-page-references.txt):
/// - rows: the value on the right of its row, grey (P11 row's component conclusion);
/// - 粘贴密钥串: Passwords' 「New Password」 sheet, ✕ leading and ✓ trailing (P12, evidence/app-pages-1007/apple/
///   P12-密码-新建弹出单.png). HIG Sheets: "A sheet is useful for requesting specific information from people or
///   presenting a simple task that they can complete before returning to the parent view."
/// - 清除密钥: an action sheet from its button (P10 / N9). HIG Action sheets: "Use an action sheet — not an alert — to
///   offer choices related to an intentional action."
/// - feedback in place, no toast (Pages/Shell/Feedback.swift): the 密钥 row's value is the state after a paste; the
///   copy button's own label says 「链接已复制」 until the page goes away. HIG Alerts: "Avoid using an alert merely to
///   provide information … prefer finding an alternative way to communicate it within the relevant context."
struct PhonePage: View {
    var data: PhonePageData
    var actions: PhonePageActions = PhonePageActions()

    @State var pasteShown = false
    @State var pasteText = ""
    @State var clearShown = false
    @State var manualLink = ""
    @State var manualShown = false
    @State var pasteErr = ""
    @State var pasteErrShown = false
    /// 「没存上」 held until the paste sheet is gone: UIKit presents one thing at a time (SaveBar.swift heldFail).
    @State var heldPasteErr: String? = nil
    /// 复制免输入链接 took: its label reads 「链接已复制」 until the page goes away (no timer).
    @State var linkCopied = false
    /// 粘贴免输入链接 found no link on the clipboard (the alert SetupScreen shows for the same button).
    @State var noLinkShown = false
    /// The medicine whose 「记录服用」 sheet is up (MedicationLogSheet).
    @State var logging: Medication? = nil
    /// A reselect of the 手机 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.phone }

    private var hasTokens: Bool { !data.staminaStatus.isEmpty }
    private var pasteEmpty: Bool { pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // read here so its change redraws this page (the sheet's Binding is read outside body)
        let selfCheckShown = SelfCheckRun.shared.shown
        List {
            // 用药 is archived (owner 10-25 08:5x 「用药记录这个东西可以先归档了」: he logs medicine in Health's Medications on
            // the iPhone now, and the course is finished). MedicationSection / MedicationStore stay in the tree, unshown.
            Section {
                // a name and a value, no hint under them (HIG Lists: "Keep item text succinct"; P13's rows)
                PhoneValueRow(title: "版本", value: data.pageVersion)
                PhoneDiagRows(appVersion: data.pageVersion)
            } header: {
                Text("这台手机")
            }

            // The two links in a section of their own with their footer right under them: the footer explained the last
            // row of 「这台手机」 four diagnostics rows away (P13: one subject a section, its footer about it alone).
            // 粘贴免输入链接 is here under the name the first-use page gives it (SetupScreen): it replaces the mailbox and
            // PIN, which hid behind 「粘贴密钥串」 before.
            Section {
                Button(linkCopied ? "链接已复制" : "复制免输入链接") {
                    // view.js #mklink; prompt("长按复制这条链接：", url) when the clipboard refuses
                    switch actions.copyNoInputLink() {
                    case .copied: linkCopied = true
                    case .noConfig: break   // the button is disabled then; the footer says why
                    case .failed(let link):
                        manualLink = link
                        manualShown = true
                    }
                }
                // HIG Entering data: "make the button available only after people enter the data you require"
                .disabled(!data.hasConfig)
                Button("粘贴免输入链接") {
                    if !actions.pasteNoInputLink() { noLinkShown = true }
                }
            } header: {
                Text("换手机")
            } footer: {
                // one sentence of what the link does (HIG Writing: "If you can use fewer words, do so."). The link opens
                // the App now (PhoneLink.linkBase), not the web page, so no 「存成书签或放到主屏幕」.
                Text((data.hasConfig ? "" : "这台手机还没填信箱和 PIN，链接里没东西可带。")
                     + "把链接发到另一台手机，复制后打开遥控，就不用再填信箱和 PIN；别转发给别人。")
            }

            Section {
                // one row per key, each saying whose it is and what it is for (a bare 「密钥 没有」 did not say which of
                // the two); the 森空岛 one comes from the machine, the 库街区 one is pasted here
                PhoneValueRow(title: "库街区密钥（鸣潮体力）", value: data.hasKuro ? "已填" : "没有")
                PhoneValueRow(title: "森空岛密钥（方舟）", value: data.hasSkland ? "游戏机已给" : "游戏机还没给")
                Button("粘贴密钥串") {
                    pasteText = ""
                    pasteShown = true
                }
                if hasTokens {
                    Button("清除密钥", role: .destructive) { clearShown = true }
                        // view.js #tokclear; from the button that asks (7b6a3f1's pattern, P10 / N9)
                        .confirmationDialog("清除密钥？", isPresented: $clearShown, titleVisibility: .visible) {
                            Button("清除", role: .destructive) { actions.clearTokens() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("清除这台手机里的游戏密钥？体力数字会消失。")
                        }
                }
            } header: {
                Text("游戏账号")
            } footer: {
                // plain words, no paths or file names (HIG Writing: "Choose simple, plain language … avoiding jargon");
                // what to paste is the paste field's own prompt now
                Text("库街区的点「粘贴密钥串」填；密钥只存在这台手机里，免输入链接会一起带上。")
            }
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. Not scrollTo(the first row): the top inset and the first section's top stay above the screen, the
        // first card's top edge cut under the title (StatusPage.swift explains, at its own .id(reselect)).
        .id(reselect)
        // A pull here reads the stamina again, the one thing on this tab that comes from outside the phone; asking the
        // machine (view.js:1150 ping) changed nothing on this page and held the spinner up to 11 s (HIG Refresh content
        // controls). Inside the sheets below: a sheet's content inherits the refresh action, and the 自检结果 sheet's
        // ScrollView (DiagSheetBox) then kept room for a refresh control, its title cut at the sheet's top edge
        // (diagsheet frames4).
        .refreshable { await StaminaStore.shared.refresh(force: true) }
        // a 用药 row pushes by value (PhoneRoute), so ContentView's phonePath can pop it on a reselect (D39) and push it
        // again on a cold launch. On the List, not a Section or row (StatusPage's navigationDestination says why); outside
        // `.refreshable`, so the medicine page does not inherit the stamina refresh
        .navigationDestination(for: PhoneRoute.self) { route in
            switch route {
            case .medication(let raw):
                MedicationPage(med: Medication(rawValue: raw) ?? .loxoprofen)
            }
        }
        // 「记录服用」 of a 用药 row, outside `.refreshable` as the sheets below (a sheet inherits the refresh action)
        .sheet(item: $logging) { m in
            MedicationLogSheet(med: m) { logging = nil }
        }
        .onDisappear { linkCopied = false }
        // 运行自检's result (PhoneDiagRows), here outside .id(reselect) so a reselect mid-run keeps it (SelfCheckRun)
        .sheet(isPresented: Binding(get: { selfCheckShown }, set: { SelfCheckRun.shared.shown = $0 })) {
            SelfCheckSheet { SelfCheckRun.shared.shown = false }
        }
        // the title (the tab's name, or 「待保存 N 项」 while changes wait, view.js:1283 / 1554) is set by ContentView's EWSaveBar
        // view.js #tokpaste: prompt("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：") — a multi-line field here,
        // so the two lines stay two lines (a one-line field would join them)
        .sheet(isPresented: $pasteShown, onDismiss: {
            // view.js:1304: ask("没存上", e.message, "好") — the system alert, once the paste sheet is down
            if let e = heldPasteErr {
                heldPasteErr = nil
                pasteErr = e
                pasteErrShown = true
            }
        }) {
            pasteSheet
        }
        .alert("没存上", isPresented: $pasteErrShown) {
            Button("好", role: .cancel) {}
        } message: {
            Text(pasteErr)
        }
        .alert("剪贴板里没有免输入链接", isPresented: $noLinkShown) {
            Button("好") {}
        }
        .alert("长按复制这条链接：", isPresented: $manualShown) {
            TextField("", text: $manualLink)
            Button("好", role: .cancel) {}
        }
    }

    /// Passwords' 「New Password」 sheet (P12): the system's full-height sheet, cancel ✕ leading, confirm ✓ trailing and
    /// disabled while there is nothing to save (HIG Sheets: "the Cancel button belongs on the leading edge of the top
    /// toolbar. When present, the Done button belongs on the trailing edge"). The ✕ / ✓ are the system's own glyphs for
    /// the cancel / confirm roles; their spoken names stay 取消 / 存.
    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    // what to paste as the field's prompt (HIG Text fields: "Show a hint in a text field to help
                    // communicate its purpose"; Passwords' grey 「User」 / 「Notes」, P12), not a footer under it
                    // the key only: the 免输入链接 has its own row (粘贴免输入链接); a link pasted here still works
                    // (PhoneTab pasteTokens) but is not asked for
                    TextField("", text: $pasteText, prompt: Text("KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行"), axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                        .setupPlainInput()
                    #if !os(Android)
                    // The system paste control (P12 row: "Paste 是系统粘贴按钮、随系统语言"): one tap, no paste prompt
                    // (https://developer.apple.com/documentation/swiftui/pastebutton). Android: skip-ui's PasteButton
                    // fatalErrors (skip-ui System/Transferable.swift:475); the field's own paste is there.
                    PasteButton(payloadType: String.self) { strings in
                        let s = strings.joined(separator: "\n")
                        Task { @MainActor in pasteText = s }
                    }
                    #endif
                } footer: {
                    // whose key and what for (P12: the sheet says what to fill); the variable names are what the user
                    // copies, so they stay
                    Text("用来读鸣潮体力。把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行一起粘进来。")
                }
            }
            .navigationTitle("库街区密钥")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    pasteCancel
                        .accessibilityLabel("取消")
                }
                ToolbarItem(placement: .confirmationAction) {
                    pasteSave
                        .accessibilityLabel("存")
                        .disabled(pasteEmpty)
                }
            }
        }
    }

    @ViewBuilder private var pasteCancel: some View {
        #if os(Android)
        Button { pasteShown = false } label: { Image(systemName: "xmark") }
        #else
        Button(role: .cancel) { pasteShown = false }
        #endif
    }

    @ViewBuilder private var pasteSave: some View {
        #if os(Android)
        Button { savePaste() } label: { Image(systemName: "checkmark") }
        #else
        Button(role: .confirm) { savePaste() }
        #endif
    }

    private func savePaste() {
        let s = pasteText
        do { try actions.pasteTokens(s) } catch { heldPasteErr = errorMessage(error) }
        pasteShown = false
    }
}

/// A row title with its grey hint under it (the web's <label> + .hint); a switch's one line of what it does.
struct PhoneRowLabel: View {
    var title: String
    var hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// A read-only value on the right of a row (the web's .ro.short), as 0.4.4 drew it. Not LabeledContent: with the
/// two-line hint its adaptive layout put the value under the label (密钥 「没有」 dropped to a third line, replay
/// shot after-light-04, 10-13), moving a value the owner reads on the right.
struct PhoneValueRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
