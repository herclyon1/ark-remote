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
        // the no-input link opening the app: mailbox + PIN (#k=) and game tokens (&t=), view.js fromLink / Stamina.fromLink.
        // On the whole body, so a link opened while still on 「第一次使用」 gets in (it was only on the tabs before).
        Group { gate }.onOpenURL { url in PhoneLink.open(url) }
    }

    @ViewBuilder private var gate: some View {
        // no mailbox yet: only 「第一次使用」, no tab bar (web/view.js boot → setupScreen)
        if Relay.shared.config == nil {
            // the update notice shows here too (someone stuck on setup still gets a fixed version in one tap); on
            // Android it is inside SetupScreen, under its top bar (topNotices, Logic/AppUpdate.swift)
            SetupScreen()
        } else {
            main
        }
    }

    @ViewBuilder private var main: some View {
        // Android: the update notice and the #pendbar line (web/pending.js) sit in each tab under its top bar
        // (noticed() below → topNotices, Logic/AppUpdate.swift); iOS keeps the bare TabView
        tabs
    }

    private var tabs: some View {
        // Tab images are view.js TAB_ICONS / TAB_IMAGES exported as-is (Resources/Module.xcassets): the game icons keep
        // their colors; tab-status / tab-phone are template images. tabIconFrame() sizes them for the tab icon slot.
        TabView(selection: selection) {
            NavigationStack {
                StatusTab().noticed()
            }
            .tabItem { Label { Text("状态") } icon: { Image("tab-status", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.status)

            if inShift("MAA") {
            NavigationStack {
                ArknightsTab().noticed()
            }
            .tabItem { Label { Text("方舟") } icon: { Image("tab-arknights", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.arknights)
            }

            if inShift("MaaEnd") {
            NavigationStack {
                EndfieldTab().noticed()
            }
            .tabItem { Label { Text("终末地") } icon: { Image("tab-endfield", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.endfield)
            }

            if inShift("OK-WW") {
            NavigationStack {
                WuwaTab().noticed()
            }
            .tabItem { Label { Text("鸣潮") } icon: { Image("tab-wuwa", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.wuwa)
            }

            NavigationStack {
                PhoneTab().noticed()
            }
            .tabItem { Label { Text("手机") } icon: { Image("tab-phone", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.phone)
        }
        .overlay { ToastLayer() }   // view.js toast(): one layer over all five tabs (Pages/Shell/ToastLayer.swift)
    }
}

private extension View {
    /// Android: the update notice and the pending-receipt line above the tab's content (topNotices); iOS: unchanged.
    @ViewBuilder func noticed() -> some View {
        #if os(Android)
        topNotices()
        #else
        self
        #endif
    }
}

private extension Image {
    /// resizable + scaledToFit, and on Android a fixed 24 pt box (the Material navigation bar icon size): skip-ui's
    /// TabView icon slot (Containers/TabView.swift RenderImage) does not bound a resizable image's height, and an
    /// unbounded one stretched the bar over the whole screen.
    func tabIconFrame() -> some View {
        #if os(Android)
        resizable().scaledToFit().frame(width: 24, height: 24)
        #else
        resizable().scaledToFit()
        #endif
    }
}
