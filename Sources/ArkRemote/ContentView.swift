import SwiftUI

/// The five tabs, in the web page's order (maa-automation web/view.js TABS: 状态 / 方舟 / 终末地 / 鸣潮 / 手机).
enum ContentTab: String, Hashable {
    case status, arknights, endfield, wuwa, phone
}

/// Icons are SF Symbol names that SkipUI maps to Material icons on Android (skip-ui Image.swift symbol table);
/// a name outside that table has no Android icon.
struct ContentView: View {
    @AppStorage("tab") var tab = ContentTab.status

    var body: some View {
        // no mailbox yet: only 「第一次使用」, no tab bar (web/view.js boot → setupScreen)
        if Relay.shared.config == nil {
            SetupScreen()
        } else {
            main
        }
    }

    @ViewBuilder private var main: some View {
        // in-app update banner above the tabs (Logic/AppUpdate.swift); Android only, iOS keeps the bare TabView
        #if os(Android)
        VStack(spacing: 0) {
            if AppUpdate.shared.showsBanner {
                UpdateBanner()
            }
            if let bar = Pending.shared.bar { PendingBarView(bar: bar) }   // web/pending.js #pendbar, on every tab
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        // Tab images are view.js TAB_ICONS / TAB_IMAGES exported as-is (Resources/Module.xcassets): the game icons keep
        // their colors; tab-status / tab-phone are template images. resizable() makes them fit the tab icon slot on Android.
        TabView(selection: $tab) {
            NavigationStack {
                StatusTab()
            }
            .tabItem { Label { Text("状态") } icon: { Image("tab-status", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.status)

            NavigationStack {
                ArknightsTab()
            }
            .tabItem { Label { Text("方舟") } icon: { Image("tab-arknights", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.arknights)

            NavigationStack {
                EndfieldTab()
            }
            .tabItem { Label { Text("终末地") } icon: { Image("tab-endfield", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.endfield)

            NavigationStack {
                WuwaTab()
            }
            .tabItem { Label { Text("鸣潮") } icon: { Image("tab-wuwa", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.wuwa)

            NavigationStack {
                PhoneTab()
            }
            .tabItem { Label { Text("手机") } icon: { Image("tab-phone", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.phone)
        }
        // the no-input link opening the app: mailbox + PIN (#k=) and game tokens (&t=), view.js fromLink / Stamina.fromLink
        .onOpenURL { url in PhoneLink.open(url) }
    }
}
