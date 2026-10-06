import SwiftUI

/// The 手机 tab, carried over from the web page (maa-automation web/view.js, the 「这台手机」 and 「游戏账号」 sections;
/// the tab takes the sections whose title matches /^这台手机|^游戏账号/, view.js TABS). PhoneTab fills it from the stores.
struct PhonePageData {
    /// 页面版本: the web page shows view.js's ?v= stamp; the app shows its own version.
    var pageVersion: String = ""
    /// 游戏账号 · 密钥: Stamina.status() on the web; empty = 「没有」, and 清除密钥 is disabled.
    var staminaStatus: String = ""
    /// The 免输入链接 (PhoneLink.make()); nil while this phone has no mailbox and PIN to put in it.
    var noInputLink: String? = nil
}

/// What the page's controls do (view.js #tokpaste / #tokclear handlers).
struct PhonePageActions {
    /// Stamina.fromPaste(s); throws with the message shown in the paste sheet.
    var pasteTokens: (String) throws -> Void = { _ in }
    var clearTokens: () -> Void = {}
}

/// Settings-style page: LabeledContent rows, the share sheet for the link (it carries Copy, Add Bookmark and the apps:
/// HIG Activity views, https://developer.apple.com/design/human-interface-guidelines/activity-views), a sheet for the
/// paste, and confirmation dialogs for the clears (HIG Action sheets: "Use an action sheet — not an alert — to offer
/// choices related to an intentional action", https://developer.apple.com/design/human-interface-guidelines/action-sheets).
struct PhonePage: View {
    var data: PhonePageData
    var actions: PhonePageActions = PhonePageActions()

    @State var pasteShown = false
    @State var pasteText = ""
    @State var pasteErr = ""
    @State var discardAsk = false
    @State var clearAsk = false
    /// A reselect of the 手机 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.phone }

    private var hasTokens: Bool { !data.staminaStatus.isEmpty }
    private var pasteEmpty: Bool { pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        List {
            Section {
                LabeledContent {
                    Text(data.pageVersion)
                } label: {
                    PhoneRowLabel(title: "页面版本", hint: "这个安装包的版本号；App 里更新过就会变")
                }
                if let link = data.noInputLink, let url = URL(string: link) {
                    ShareLink("分享免输入链接", item: url)
                } else {
                    Button("分享免输入链接") {}
                        .disabled(true)
                }
            } header: {
                Text("这台手机")
            } footer: {
                Text(data.noInputLink == nil
                     ? "这台手机还没填信箱和 PIN，链接里没东西可带。"
                     : "用这条链接打开，就不用再填信箱和 PIN。链接里带着这两样和游戏密钥，别转发给别人。")
            }

            PhoneDiagRows(appVersion: data.pageVersion)

            Section {
                // 「密钥」, not the web's 「已配置」 (view.js:608): with none stored the row read 「已配置 … 没有」 (test pass 1, 问题 7)
                LabeledContent {
                    Text(hasTokens ? data.staminaStatus : "没有")
                } label: {
                    PhoneRowLabel(title: "密钥", hint: "体力数字由这台手机直接问森空岛和库街区，密钥只存在这台手机里")
                }
                Button("粘贴密钥串") {
                    pasteText = ""
                    pasteErr = ""
                    pasteShown = true
                }
                Button("清除密钥", role: .destructive) { clearAsk = true }
                    .disabled(!hasTokens)
                    // view.js #tokclear
                    .confirmationDialog("清除密钥？", isPresented: $clearAsk, titleVisibility: .visible) {
                        Button("清除密钥", role: .destructive) { actions.clearTokens() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("体力数字会消失，要再粘贴一次密钥串才回来。")
                    }
            } header: {
                Text("游戏账号")
            } footer: {
                Text("免输入链接会带上这里存着的密钥。森空岛的会话由机器交过来；库街区的用「粘贴密钥串」存进来。")
            }
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. Not scrollTo(the first row): the top inset and the first section's top stay above the screen, the
        // first card's top edge cut under the title (StatusPage.swift explains, at its own .id(reselect)).
        .id(reselect)
        // On the List, not a row: SwiftUI wants navigationDestination outside lazy containers (StatusPage does the same).
        .navigationDestination(for: PhoneRoute.self) { route in
            switch route {
            case .diagRecord: DiagRecordView()
            }
        }
        // this phone's own link: the clipboard check on the next open (AppGlue → PhoneLink.takeClipboardLink) skips it
        .onChange(of: data.noInputLink, initial: true) { _, link in
            if let link { PhoneLink.markTaken(link) }
        }
        // view.js #tokpaste: prompt("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：") — a multi-line field here,
        // so the two lines stay two lines (a one-line field would join them)
        .sheet(isPresented: $pasteShown) {
            pasteSheet
        }
    }

    /// Cancel leading, Done trailing and disabled until there is something to save; a failed save stays in the sheet
    /// with the reason (HIG Feedback: "display status information in a passive way",
    /// https://developer.apple.com/design/human-interface-guidelines/feedback).
    private var pasteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("免输入链接，或两行密钥", text: $pasteText, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)
                        .setupPlainInput()
                    #if !os(Android)
                    // The system paste control: one tap, no paste prompt (PasteButton docs,
                    // https://developer.apple.com/documentation/swiftui/pastebutton). Android: skip-ui's PasteButton
                    // fatalErrors (skip-ui System/Transferable.swift:475); the field's own paste is there.
                    PasteButton(payloadType: String.self) { strings in
                        let s = strings.joined(separator: "\n")
                        Task { @MainActor in pasteText = s }
                    }
                    #endif
                } footer: {
                    Text("粘贴网页「手机」页复制的免输入链接、电脑上 scripts/mac/phone-link.py 打出来的链接，或 ~/.config/ark/.env 里 KUROBBS_TOKEN 和 KUROBBS_DID 那两行。")
                }
                if !pasteErr.isEmpty {
                    Section {
                        Label(pasteErr, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } header: {
                        Text("没存上")
                    }
                }
            }
            .navigationTitle("粘贴密钥串")
            .onChange(of: pasteText) { _, _ in pasteErr = "" }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) {
                        if pasteEmpty { pasteShown = false } else { discardAsk = true }
                    }
                    .confirmationDialog("放弃粘贴的内容？", isPresented: $discardAsk, titleVisibility: .visible) {
                        Button("放弃", role: .destructive) { pasteShown = false }
                        Button("取消", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", role: .confirm) {
                        do {
                            try actions.pasteTokens(pasteText)
                            pasteShown = false
                        } catch {
                            pasteErr = errorMessage(error)
                        }
                    }
                    .disabled(pasteEmpty)
                }
            }
        }
        .interactiveDismissDisabled(!pasteEmpty)
    }
}

/// Pages pushed from the 手机 tab, by value so ContentView's phonePath holds them.
enum PhoneRoute: Hashable {
    /// 「分享诊断记录」 → DiagRecordView.
    case diagRecord
}

/// A row title with its explanation under it (the web's <label> + .hint), for a LabeledContent / Toggle label.
/// A VStack, not two bare Texts: skip-ui's LabeledContent composes the label builder into its Row as is
/// (skip-ui Text/LabeledContent.swift RenderLabel), so two Texts would sit side by side on Android.
struct PhoneRowLabel: View {
    var title: String
    var hint: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
