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

    /// Each tab's pushed pages, bound to its NavigationStack so a reselect can pop them (D39). One @State per tab rather
    /// than a dictionary of paths: a binding into a dictionary element is not one Skip is known to transpile safely.
    @State private var statusPath = NavigationPath()
    @State private var arknightsPath = NavigationPath()
    @State private var endfieldPath = NavigationPath()
    @State private var wuwaPath = NavigationPath()
    @State private var phonePath = NavigationPath()
    /// Bumped by a reselect of a tab at its root; the root page scrolls to its top on the change (\.tabReselect).
    @State private var statusTop = 0
    @State private var arknightsTop = 0
    @State private var endfieldTop = 0
    @State private var wuwaTop = 0
    @State private var phoneTop = 0

    /// The selection: a tab that has just gone (the shift changed while it was open) reads as 状态, like the web
    /// page falling back to its first tab (view.js:998; the stored tab is set back in `dropGoneTabs`).
    ///
    /// D39, tapping the tab that is already selected: view.js:2626-2632 reselectTab (called at :2742) pops the tab's pushed
    /// page if one is up, else scrolls its root page to the top - one of the two per tap - after UITabBarController: "User
    /// taps always display the root view of the tab, regardless of which tab was previously selected. This is true even if
    /// the tab was already selected." skip-ui does neither: TabView.swift:391-398 onItemClick only writes the tag back to
    /// the selection even for the tab already shown, so this `set` sees the same value and does it here. iOS scrolled the
    /// 状态 root to the top natively on the iOS 27 simulator (scrolled down, tapped 状态: back at the top), so the scroll is
    /// Android only: a second scrollTo(first row) on iOS could land after the native one and push a first section's
    /// header out of sight. Clearing the path stays on both.
    private var selection: Binding<ContentTab> {
        Binding(get: { shown(tab) ? tab : .status }, set: { new in
            let current = shown(tab) ? tab : .status
            tab = new   // first: a tap on 状态 while the stored tab is a gone one must stick
            if new == current { reselect(new) }
        })
    }

    /// The pushed page goes (the path back to empty pops skip-ui's back stack: Navigation.swift:1111-1161 navigateToPath,
    /// run from didCompose :947-956 on every recompose), else the root page is told to scroll to its top.
    private func reselect(_ t: ContentTab) {
        #if !os(Android)
        switch t {
        case .status: statusPath = NavigationPath()
        case .arknights: arknightsPath = NavigationPath()
        case .endfield: endfieldPath = NavigationPath()
        case .wuwa: wuwaPath = NavigationPath()
        case .phone: phonePath = NavigationPath()
        }
        #else
        switch t {
        case .status: if statusPath.isEmpty { statusTop += 1 } else { statusPath = NavigationPath() }
        case .arknights: if arknightsPath.isEmpty { arknightsTop += 1 } else { arknightsPath = NavigationPath() }
        case .endfield: if endfieldPath.isEmpty { endfieldTop += 1 } else { endfieldPath = NavigationPath() }
        case .wuwa: if wuwaPath.isEmpty { wuwaTop += 1 } else { wuwaPath = NavigationPath() }
        case .phone: if phonePath.isEmpty { phoneTop += 1 } else { phonePath = NavigationPath() }
        }
        #endif
    }

    /// Which game tabs the shown shift has; its change is when a tab can go.
    private var shiftTabs: String {
        "\(inShift("MAA"))|\(inShift("MaaEnd"))|\(inShift("OK-WW"))"
    }

    /// view.js:997-998 after every render: `dropTabPages(present)` drops the pages a gone tab had pushed, and
    /// `if (!present.has(curTab)) curTab = "状态"` makes 状态 the remembered tab. Without the second line the App only
    /// showed 状态 for the time being and went back to the old tab on its own when its game came back to the shift.
    /// The first keeps a tab that comes back from re-pushing the page it had (NavigationStack(path:) pushes what the path holds).
    private func dropGoneTabs() {
        if !shown(.arknights) && !arknightsPath.isEmpty { arknightsPath = NavigationPath() }
        if !shown(.endfield) && !endfieldPath.isEmpty { endfieldPath = NavigationPath() }
        if !shown(.wuwa) && !wuwaPath.isEmpty { wuwaPath = NavigationPath() }
        if !shown(tab) { tab = .status }
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
        // the #pendbar line (web/pending.js:76-88), and on Android the update notice, sit in each tab under its top bar
        // (noticed() below → topNotices, Logic/AppUpdate.swift)
        tabs
    }

    private var tabs: some View {
        // Tab images are view.js TAB_ICONS / TAB_IMAGES exported as-is (Resources/Module.xcassets): the game icons keep
        // their colors; tab-status / tab-phone are template images. tabIconFrame() sizes them for the tab icon slot.
        TabView(selection: selection) {
            NavigationStack(path: $statusPath) {
                StatusTab().noticed().environment(\.tabReselect, statusTop)
            }
            .tabItem { Label { Text("状态") } icon: { Image("tab-status", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.status)

            if inShift("MAA") {
            NavigationStack(path: $arknightsPath) {
                ArknightsTab().noticed().environment(\.tabReselect, arknightsTop)
            }
            .tabItem { Label { Text("方舟") } icon: { Image("tab-arknights", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.arknights)
            }

            if inShift("MaaEnd") {
            NavigationStack(path: $endfieldPath) {
                EndfieldTab().noticed().environment(\.tabReselect, endfieldTop)
            }
            .tabItem { Label { Text("终末地") } icon: { Image("tab-endfield", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.endfield)
            }

            if inShift("OK-WW") {
            NavigationStack(path: $wuwaPath) {
                WuwaTab().noticed().environment(\.tabReselect, wuwaTop)
            }
            .tabItem { Label { Text("鸣潮") } icon: { Image("tab-wuwa", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.wuwa)
            }

            NavigationStack(path: $phonePath) {
                PhoneTab()
                    .environment(\.tabReselect, phoneTop)
                    // the pull to refresh (view.js:1150-1153 pullRefresh → ping) is on PhonePage's List, so the
                    // 「粘贴密钥串」 sheet does not inherit it
                    // the one top bar of the web page (index.html:921, view.js:1551-1556 updateBar) is over 手机 as well:
                    // ✕ / 「待保存 N 项」 / ✓ for the changes left on the other tabs
                    .modifier(EWSaveBar(title: "游戏机遥控"))
                    .noticed()
            }
            .tabItem { Label { Text("手机") } icon: { Image("tab-phone", bundle: assetBundle).tabIconFrame() } }
            .tag(ContentTab.phone)
        }
        #if os(Android)
        // Apple's tab bar switches tabs at once; skip-ui's TabView cross-fades for 700 ms (Navigation 3 NavDisplay
        // defaults via NavDisplayTransitionOptions.tabViewDefaults), and a swipe during that fade is lost.
        // skip-ui README "tabViewTransitions": NavDisplayTransitionOptions(.none).
        .tabViewTransitions { _ in .init(.none) }   // SkipUI.NavDisplayTransitionOptions; importing SkipUI here clashes with SwiftUI.View
        #endif
        // on a shift change, and once at the start for a stored tab that is already out of the shift (view.js:998)
        .onChange(of: shiftTabs, initial: true) { dropGoneTabs() }
        .overlay { DiagOverlay() }   // seg-frames-logger.js #diagmark / #diagline over every tab (Pages/Phone/PhoneDiagRows.swift)
        .overlay { ToastLayer() }   // view.js toast(): one layer over all five tabs (Pages/Shell/ToastLayer.swift)
        // view.js ask(title, why, "好", false, { single: true }) for a note raised outside a page's own flow:
        // Pending.resend's 「发不出去」 (pending.js:118). One alert at a time (Relay.showAlert).
        .alert(Relay.shared.alert?.title ?? "", isPresented: Binding(get: { Relay.shared.alert != nil },
                                                                     set: { if !$0 { Relay.shared.alert = nil } })) {
            Button("好") {}
        } message: {
            Text(verbatim: Relay.shared.alert?.message ?? "")
        }
    }
}

/// The reselect count of the tab a root page is in (ContentView.reselect): a change means "scroll to your top". Shaped as
/// skip-ui's own custom-key test (Tests/SkipUITests/SkipUITests.swift:1126-1135); EnvironmentValues.swift:145 reads
/// `defaultValue` from the key's companion object.
struct TabReselectKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var tabReselect: Int {
        get { self[TabReselectKey.self] }
        set { self[TabReselectKey.self] = newValue }
    }
}

private extension View {
    /// The pending-receipt line (both platforms) and the update notice (Android) above the tab's content (topNotices).
    func noticed() -> some View {
        topNotices()
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
