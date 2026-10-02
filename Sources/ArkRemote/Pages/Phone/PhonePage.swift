import SwiftUI

/// The 手机 tab, carried over from the web page (maa-automation web/view.js, the 「这台手机」 and 「游戏账号」 sections;
/// the tab takes the sections whose title matches /^这台手机|^游戏账号/, view.js TABS). PhoneTab fills it from the stores.
struct PhonePageData {
    /// 页面版本: the web page shows view.js's ?v= stamp; the app shows its own version.
    var pageVersion: String = ""
    /// 游戏账号 · 已配置: Stamina.status() on the web; empty = 「没有」, and the 清除密钥 button is hidden.
    var staminaStatus: String = ""
}

/// What the page's controls do (view.js #tokpaste / #tokclear / #mklink handlers).
struct PhonePageActions {
    /// Stamina.fromPaste(s); throws with the message the web shows in 「没存上」.
    var pasteTokens: (String) throws -> Void = { _ in }
    var clearTokens: () -> Void = {}
    /// Copies the no-input link.
    var copyNoInputLink: () -> PhoneCopyResult = { .noConfig }
}

enum PhoneCopyResult {
    case copied
    /// No mailbox config to put in the link.
    case noConfig
    /// The clipboard did not take it; the link is shown for a long-press copy.
    case failed(String)
}

struct PhonePage: View {
    var data: PhonePageData
    var actions: PhonePageActions = PhonePageActions()

    @State var pasteShown = false
    @State var pasteText = ""
    @State var clearShown = false
    @State var manualLink = ""
    @State var manualShown = false

    private var hasTokens: Bool { !data.staminaStatus.isEmpty }

    var body: some View {
        List {
            Section {
                PhoneValueRow(title: "页面版本", hint: "这个安装包的版本号；App 里更新过就会变", value: data.pageVersion)
                PhoneDiagRows(appVersion: data.pageVersion)
                Button("复制免输入链接") {
                    // view.js #mklink: toast on success, prompt("长按复制这条链接：", url) when the clipboard refuses
                    switch actions.copyNoInputLink() {
                    case .copied: Relay.shared.showToast("链接已复制")   // view.js:1327
                    case .noConfig: Relay.shared.showToast("这台手机还没填信箱和 PIN，链接里没东西可带", ms: 4000)
                    case .failed(let link):
                        manualLink = link
                        manualShown = true
                    }
                }
            } header: {
                Text("这台手机")
            } footer: {
                Text("把这条链接存成书签或加到主屏幕，以后打开就直接是控制台，再也不用填信箱和 PIN。链接里带着这两样，别转发给别人")
            }

            Section {
                PhoneValueRow(title: "已配置", hint: "体力数字由这台手机直接问森空岛和库街区，密钥只存在这台手机里",
                              value: hasTokens ? data.staminaStatus : "没有")
                Button("粘贴密钥串") {
                    pasteText = ""
                    pasteShown = true
                }
                if hasTokens {
                    Button("清除密钥", role: .destructive) { clearShown = true }
                }
            } header: {
                Text("游戏账号")
            } footer: {
                Text("免输入链接会把这里存着的密钥一起带上，换手机开一次那条链接就全有。森空岛的会话由机器交过来；库街区的：打开电脑上 scripts/mac/phone-link.py 打出来的链接，或把 ~/.config/ark/.env 里 KUROBBS_TOKEN 和 KUROBBS_DID 那两行粘贴进来")
            }
        }
        .navigationTitle("游戏机遥控")   // every page of the web console is titled so (view.js:1283)
        // view.js #tokpaste: prompt("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：") — a multi-line editor here,
        // so the two lines stay two lines (a one-line field would join them)
        .sheet(isPresented: $pasteShown) {
            NavigationStack {
                Form {
                    Section {
                        TextEditor(text: $pasteText)
                            .frame(minHeight: 120)
                            .setupPlainInput()
                    } footer: {
                        Text("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：")
                    }
                }
                .navigationTitle("粘贴密钥串")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { pasteShown = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("存") {
                            let s = pasteText
                            pasteShown = false
                            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            // view.js: toast("没存：" + e.message, 5000)
                            do { try actions.pasteTokens(s) } catch { Relay.shared.showToast("没存：" + errorMessage(error), ms: 5000) }
                        }
                    }
                }
            }
        }
        // view.js #tokclear
        .alert("清除密钥？", isPresented: $clearShown) {
            Button("清除", role: .destructive) { actions.clearTokens() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除这台手机里的游戏密钥？体力数字会消失。")
        }
        .alert("长按复制这条链接：", isPresented: $manualShown) {
            TextField("", text: $manualLink)
            Button("好", role: .cancel) {}
        }
    }
}

/// A row title with its grey hint under it (the web's <label> + .hint).
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

/// A read-only value on the right of a row (the web's .ro.short).
struct PhoneValueRow: View {
    var title: String
    var hint: String
    var value: String

    var body: some View {
        HStack {
            PhoneRowLabel(title: title, hint: hint)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
