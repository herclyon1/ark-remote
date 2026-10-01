import SwiftUI

/// The 手机 tab, carried over from the web page (maa-automation web/view.js, the 「这台手机」 and 「游戏账号」 sections;
/// the tab takes the sections whose title matches /^这台手机|^游戏账号/, view.js TABS).
/// Placeholder data for now: the real values and the actions are wired in once the logic (Net / Schema / Stamina) lands.
struct PhonePageData {
    /// 页面版本: the web page shows view.js's ?v= stamp; the app shows its own build version.
    var pageVersion: String = ""
    /// 诊断记录 switch (web: localStorage "ark-diag" == "1").
    var diagnosticsOn: Bool = false
    /// 游戏账号 · 已配置: Stamina.status() on the web; nil or empty = 「没有」, and the 清除密钥 button is hidden.
    var staminaStatus: String? = nil
}

/// What the page's controls do; empty closures until the logic is connected.
struct PhonePageActions {
    var setDiagnostics: (Bool) -> Void = { _ in }
    var runSelfCheck: () -> Void = {}
    var copyNoInputLink: () -> Void = {}
    var pasteTokens: () -> Void = {}
    var clearTokens: () -> Void = {}
}

struct PhonePage: View {
    var data: PhonePageData
    var actions: PhonePageActions = PhonePageActions()

    private var hasTokens: Bool { !(data.staminaStatus ?? "").isEmpty }

    var body: some View {
        List {
            Section {
                PhoneValueRow(title: "页面版本", hint: "App 的版本号", value: data.pageVersion)
                Toggle(isOn: Binding(get: { data.diagnosticsOn }, set: { actions.setDiagnostics($0) })) {
                    PhoneRowLabel(title: "诊断记录", hint: "开着时记录几何数，分段控件每次操作后弹出记录，可复制 / 分享给我们")
                }
                if data.diagnosticsOn {
                    Button("运行自检") { actions.runSelfCheck() }
                }
                Button("复制免输入链接") { actions.copyNoInputLink() }
            } header: {
                Text("这台手机")
            } footer: {
                Text("把这条链接存成书签或加到主屏幕，以后打开就直接是控制台，再也不用填信箱和 PIN。链接里带着这两样，别转发给别人")
            }

            Section {
                PhoneValueRow(title: "已配置", hint: "体力数字由这台手机直接问森空岛和库街区，密钥只存在这台手机里",
                              value: hasTokens ? (data.staminaStatus ?? "") : "没有")
                Button("粘贴密钥串") { actions.pasteTokens() }
                if hasTokens {
                    Button("清除密钥", role: .destructive) { actions.clearTokens() }
                }
            } header: {
                Text("游戏账号")
            } footer: {
                Text("免输入链接会把这里存着的密钥一起带上，换手机开一次那条链接就全有。森空岛的会话由机器交过来；库街区的：打开电脑上 scripts/mac/phone-link.py 打出来的链接，或把 ~/.config/ark/.env 里 KUROBBS_TOKEN 和 KUROBBS_DID 那两行粘贴进来")
            }
        }
        .navigationTitle("手机")
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
