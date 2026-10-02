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
        // in-app update banner above the tabs (Logic/AppUpdate.swift); Android only, iOS keeps the bare TabView
        #if os(Android)
        VStack(spacing: 0) {
            if AppUpdate.shared.showsBanner {
                UpdateBanner()
            }
            tabs
        }
        #else
        tabs
        #endif
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                StatusTab()
            }
            .tabItem { Label("状态", systemImage: "chart.bar.xaxis") }
            .tag(ContentTab.status)

            NavigationStack {
                ArknightsTab()
            }
            .tabItem { Label("方舟", systemImage: "bookmark.fill") }
            .tag(ContentTab.arknights)

            NavigationStack {
                EndfieldTab()
            }
            .tabItem { Label("终末地", systemImage: "wrench.fill") }
            .tag(ContentTab.endfield)

            NavigationStack {
                WuwaTab()
            }
            .tabItem { Label("鸣潮", systemImage: "star.fill") }
            .tag(ContentTab.wuwa)

            NavigationStack {
                PhoneTab()
            }
            .tabItem { Label("手机", systemImage: "phone.fill") }
            .tag(ContentTab.phone)
        }
        // the no-input link opening the app: mailbox + PIN (#k=) and game tokens (&t=), view.js fromLink / Stamina.fromLink
        .onOpenURL { url in PhoneLink.open(url) }
    }
}
