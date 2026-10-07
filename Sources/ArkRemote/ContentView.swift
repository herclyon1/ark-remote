import SwiftUI

/// The five tabs, in the web page's order (maa-automation web/view.js TABS: 状态 / 方舟 / 终末地 / 鸣潮 / 手机).
enum ContentTab: String, Hashable {
    case status, arknights, endfield, wuwa, phone
}

/// The tab bar: five `Tab`s that are always there. HIG Tab bars: "Don't disable or hide tab bar buttons, even when their
/// content is unavailable. … If a section is empty, explain why its content is unavailable." A game that is not in the
/// shown shift keeps its tab, and its page says so (`ShiftGate`).
struct ContentView: View {
    /// @AppStorage, not @SceneStorage: skip-ui's SceneStorage fatalErrors (Properties/SceneStorage.swift:33-47).
    @AppStorage("tab") var tab = ContentTab.status
    /// The shift picked on the 状态 tab (view.js curQueue, localStorage "ark-remote-cfg-queue").
    @AppStorage("ark-remote-cfg-queue") var storedQueue = ""

    /// view.js:317-327 inShift: the games of the shown shift (the picked one, else the first queue); no queue or an
    /// empty script list means every game is in.
    private func inShift(_ owner: String) -> Bool {
        let qs = Relay.shared.snap?["queues"]?.array ?? []
        guard let q = qs.first(where: { $0["名"]?.string == storedQueue }) ?? qs.first,
              let scripts = q["脚本"]?.array, !scripts.isEmpty else { return true }
        return scripts.contains { $0.string == owner }
    }

    /// Each tab's pushed pages, bound to its NavigationStack so a reselect can pop them (D39). One @State per tab rather
    /// than a dictionary of paths: a binding into a dictionary element is not one Skip is known to transpile safely.
    @State var statusPath = NavigationPath()
    @State var arknightsPath = NavigationPath()
    @State var endfieldPath = NavigationPath()
    @State var wuwaPath = NavigationPath()
    @State var phonePath = NavigationPath()

    /// D39, tapping the tab that is already selected: UITabBarController "User taps always display the root view of the
    /// tab, regardless of which tab was previously selected. This is true even if the tab was already selected." skip-ui
    /// does neither: TabView.swift:391-398 onItemClick only writes the tag back to the selection even for the tab already
    /// shown, so this `set` sees the same value and does it here. iOS scrolls a root page to its top natively, so the
    /// scroll is Android only; clearing the path stays on both.
    private var selection: Binding<ContentTab> {
        Binding(get: { tab }, set: { new in
            let current = tab
            tab = new
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
        // the scroll goes through TabReselect, which each root page reads itself (Pages/Shell/TabReselect.swift)
        let rs = TabReselect.shared
        switch t {
        case .status: if statusPath.isEmpty { rs.bump(t) } else { statusPath = NavigationPath() }
        case .arknights: if arknightsPath.isEmpty { rs.bump(t) } else { arknightsPath = NavigationPath() }
        case .endfield: if endfieldPath.isEmpty { rs.bump(t) } else { endfieldPath = NavigationPath() }
        case .wuwa: if wuwaPath.isEmpty { rs.bump(t) } else { wuwaPath = NavigationPath() }
        case .phone: if phonePath.isEmpty { rs.bump(t) } else { phonePath = NavigationPath() }
        }
        #endif
    }

    /// Which games the shown shift has; its change is when a game page can go.
    private var shiftTabs: String {
        "\(inShift("MAA"))|\(inShift("MaaEnd"))|\(inShift("OK-WW"))"
    }

    /// A game that leaves the shift drops the pages its tab had pushed: their destinations are registered by the game
    /// page, which `ShiftGate` no longer shows, and a tab that comes back would re-push what the path still holds.
    private func dropGonePages() {
        if !inShift("MAA") && !arknightsPath.isEmpty { arknightsPath = NavigationPath() }
        if !inShift("MaaEnd") && !endfieldPath.isEmpty { endfieldPath = NavigationPath() }
        if !inShift("OK-WW") && !wuwaPath.isEmpty { wuwaPath = NavigationPath() }
    }

    var body: some View {
        // the no-input link opening the app: mailbox + PIN (#k=) and game tokens (&t=), view.js fromLink / Stamina.fromLink.
        // On the whole body, so a link opened while still on 「第一次使用」 gets in.
        Group { gate }.onOpenURL { url in PhoneLink.open(url) }
    }

    @ViewBuilder private var gate: some View {
        // no mailbox yet: only 「第一次使用」, no tab bar (web/view.js boot → setupScreen)
        if Relay.shared.config == nil {
            SetupScreen()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: selection) {
            Tab(value: ContentTab.status) {
                NavigationStack(path: $statusPath) {
                    StatusTab().noticed()
                }
                .expandsTopBarOnReselect(.status)   // D39 on Android: the large title opens on a reselect (SkipFixes.swift)
                .modifier(DiagRoom())   // bottom room for DiagOverlay while 诊断记录 is on (Pages/Phone/PhoneDiagRows.swift)
            } label: {
                Label { Text("状态") } icon: { symbol("gauge.with.dots.needle.67percent", android: "Icons.Outlined.Info") }
            }

            Tab(value: ContentTab.arknights) {
                NavigationStack(path: $arknightsPath) {
                    ShiftGate(name: "方舟", inShift: inShift("MAA"), toStatus: { tab = .status }) { ArknightsTab() }
                }
                .expandsTopBarOnReselect(.arknights)
                .modifier(DiagRoom())
            } label: {
                Label { Text("方舟") } icon: { symbol("shield", android: "Icons.Outlined.Star") }
            }

            Tab(value: ContentTab.endfield) {
                NavigationStack(path: $endfieldPath) {
                    ShiftGate(name: "终末地", inShift: inShift("MaaEnd"), toStatus: { tab = .status }) { EndfieldTab() }
                }
                .expandsTopBarOnReselect(.endfield)
                .modifier(DiagRoom())
            } label: {
                Label { Text("终末地") } icon: { symbol("building.2", android: "Icons.Outlined.Build") }
            }

            Tab(value: ContentTab.wuwa) {
                NavigationStack(path: $wuwaPath) {
                    ShiftGate(name: "鸣潮", inShift: inShift("OK-WW"), toStatus: { tab = .status }) { WuwaTab() }
                }
                .expandsTopBarOnReselect(.wuwa)
                .modifier(DiagRoom())
            } label: {
                Label { Text("鸣潮") } icon: { symbol("water.waves", android: "Icons.Outlined.Explore") }
            }

            Tab(value: ContentTab.phone) {
                NavigationStack(path: $phonePath) {
                    PhoneTab()
                        .navigationTitle("手机")
                        .noticed()
                }
                .expandsTopBarOnReselect(.phone)
                .modifier(DiagRoom())
            } label: {
                Label { Text("手机") } icon: { symbol("iphone", android: "Icons.Outlined.Phone") }
            }
        }
        #if os(Android)
        // Apple's tab bar switches tabs at once; skip-ui's TabView cross-fades for 700 ms (Navigation 3 NavDisplay
        // defaults via NavDisplayTransitionOptions.tabViewDefaults), and a swipe during that fade is lost.
        // skip-ui README "tabViewTransitions": NavDisplayTransitionOptions(.none).
        .tabViewTransitions { _ in .init(.none) }   // SkipUI.NavDisplayTransitionOptions; importing SkipUI here clashes with SwiftUI.View
        #endif
        .onChange(of: shiftTabs, initial: true) { dropGonePages() }
        // seg-frames-logger.js #diagmark / #diagline on every tab: iOS the tab view's bottom accessory, Android an overlay
        // (Pages/Phone/PhoneDiagRows.swift)
        .modifier(DiagBottomAccessory())
    }
}

private extension View {
    /// The pending-receipt line (both platforms) and the update notice (Android) above the tab's content (topNotices).
    func noticed() -> some View {
        topNotices()
    }
}

/// A game tab's root: the game's page while the shown shift runs that game, else a page that says why it is empty
/// (HIG Tab bars: "If a section is empty, explain why its content is unavailable."; SwiftUI ContentUnavailableView:
/// "display when the content of your app is unavailable to users").
struct ShiftGate<Page: View>: View {
    let name: String
    let inShift: Bool
    let toStatus: () -> Void
    @ViewBuilder let page: () -> Page

    var body: some View {
        if inShift {
            page().noticed()
        } else {
            unavailable
                .navigationTitle(name)   // the game page's own title bar is not shown while it is out
                .noticed()
        }
    }

    private var title: String { "这个班次没有\(name)" }
    private var detail: String { "在「状态」页换到有\(name)的班次。" }

    @ViewBuilder private var unavailable: some View {
        #if os(Android)
        // skip-fuse-ui has no ContentUnavailableView, and skip-ui's (System/ContentUnavailableView.swift) is one comment
        // block (lines 3-183): the same three parts, centred.
        VStack(spacing: 12) {
            Image(systemName: "Icons.Outlined.DateRange").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.title3)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("去「状态」页") { toStatus() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ContentUnavailableView {
            Label(title, systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text(detail)
        } actions: {
            Button("去「状态」页") { toStatus() }
        }
        #endif
    }
}
