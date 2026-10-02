import SwiftUI

/// The five tabs, in the web page's order (maa-automation web/view.js TABS: 状态 / 方舟 / 终末地 / 鸣潮 / 手机).
enum ContentTab: String, Hashable {
    case status, arknights, endfield, wuwa, phone
}

/// Icons are SF Symbol names that SkipUI maps to Material icons on Android (skip-ui Image.swift symbol table);
/// a name outside that table has no Android icon.
struct ContentView: View {
    @AppStorage("tab") var tab = ContentTab.status
    /// The shift picked on the 状态 tab (view.js curQueue, localStorage "ark-remote-cfg-queue").
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""

    /// view.js:317-327 inShift: only the games of the shown shift (the picked one, else the first queue) have a tab;
    /// no queue or an empty script list means every game is in. A tab whose game is out goes with its page
    /// (view.js:838 wantTabs = the tabs that still have a section); 状态 and 手机 always stay.
    private func inShift(_ owner: String) -> Bool {
        let qs = Relay.shared.snap?["queues"]?.array ?? []
        guard let q = qs.first(where: { $0["名"]?.string == storedQueue }) ?? qs.first,
              let scripts = q["脚本"]?.array, !scripts.isEmpty else { return true }
        return scripts.contains { $0.string == owner }
    }

    private func shown(_ t: ContentTab) -> Bool {
        switch t {
        case .arknights: return inShift("MAA")
        case .endfield: return inShift("MaaEnd")
        case .wuwa: return inShift("OK-WW")
        case .status, .phone: return true
        }
    }

    /// The selection: a tab that has just gone (the shift changed while it was open) reads as 状态, like the web
    /// page falling back to its first tab.
    private var selection: Binding<ContentTab> {
        Binding(get: { shown(tab) ? tab : .status }, set: { tab = $0 })
    }

    var body: some View {
        // no mailbox yet: only 「第一次使用」, no tab bar (web/view.js boot → setupScreen)
        if Relay.shared.config == nil {
            // the update banner shows here too: someone stuck on setup still gets a fixed version in one tap
            #if os(Android)
            VStack(spacing: 0) {
                if AppUpdate.shared.showsBanner { UpdateBanner() }
                SetupScreen()
            }
            #else
            SetupScreen()
            #endif
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
        TabView(selection: selection) {
            NavigationStack {
                StatusTab()
            }
            .tabItem { Label { Text("状态") } icon: { Image("tab-status", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.status)

            if inShift("MAA") {
            NavigationStack {
                ArknightsTab()
            }
            .tabItem { Label { Text("方舟") } icon: { Image("tab-arknights", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.arknights)
            }

            if inShift("MaaEnd") {
            NavigationStack {
                EndfieldTab()
            }
            .tabItem { Label { Text("终末地") } icon: { Image("tab-endfield", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.endfield)
            }

            if inShift("OK-WW") {
            NavigationStack {
                WuwaTab()
            }
            .tabItem { Label { Text("鸣潮") } icon: { Image("tab-wuwa", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.wuwa)
            }

            NavigationStack {
                PhoneTab()
            }
            .tabItem { Label { Text("手机") } icon: { Image("tab-phone", bundle: .module).resizable().scaledToFit() } }
            .tag(ContentTab.phone)
        }
        // the no-input link opening the app: mailbox + PIN (#k=) and game tokens (&t=), view.js fromLink / Stamina.fromLink
        .onOpenURL { url in PhoneLink.open(url) }
        .overlay { ToastLayer() }   // view.js toast(): one layer over all five tabs (Pages/Shell/ToastLayer.swift)
    }
}
