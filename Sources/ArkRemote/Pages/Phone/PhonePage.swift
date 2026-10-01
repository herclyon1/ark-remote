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
    /// Copies the no-input link; false when there is no mailbox config to put in it.
    var copyNoInputLink: () -> Bool = { false }
}

struct PhonePage: View {
    var data: PhonePageData
    var actions: PhonePageActions = PhonePageActions()

    @State var pasteShown = false
    @State var pasteText = ""
    @State var clearShown = false
    @State var failShown = false
    @State var failText = ""
    @State var copiedShown = false
    @State var copiedText = ""

    private var hasTokens: Bool { !data.staminaStatus.isEmpty }

    var body: some View {
        List {
            Section {
                PhoneValueRow(title: "页面版本", hint: "App 的版本号", value: data.pageVersion)
                // TODO: 诊断记录 switch and 运行自检 are not carried over. On the web the switch rewrites the URL to ?diag=1 and
                // injects the browser recorder (seg-frames-logger.js), and 自检 runs web/accept.js in the page; neither exists in the app.
                Button("复制免输入链接") {
                    if actions.copyNoInputLink() {
                        copiedText = "已复制。把这条链接存成书签或加到主屏幕，以后打开就直接是控制台"
                    } else {
                        copiedText = "这台手机还没填信箱和 PIN，链接里没东西可带"
                    }
                    copiedShown = true
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
        .navigationTitle("手机")
        // view.js #tokpaste: prompt("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：")
        .alert("粘贴密钥串", isPresented: $pasteShown) {
            TextField("KUROBBS_TOKEN=…", text: $pasteText)
            Button("存") {
                let s = pasteText
                guard !s.isEmpty else { return }
                do { try actions.pasteTokens(s) } catch {
                    failText = errorMessage(error)
                    failShown = true
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("把 KUROBBS_TOKEN=… 和 KUROBBS_DID=… 两行粘贴到这里：")
        }
        // view.js #tokclear
        .alert("清除密钥？", isPresented: $clearShown) {
            Button("清除", role: .destructive) { actions.clearTokens() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清除这台手机里的游戏密钥？体力数字会消失。")
        }
        .alert("没存上", isPresented: $failShown) {
            Button("好", role: .cancel) {}
        } message: {
            Text(failText)
        }
        .alert("免输入链接", isPresented: $copiedShown) {
            Button("好", role: .cancel) {}
        } message: {
            Text(copiedText)
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
