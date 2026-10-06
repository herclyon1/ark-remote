// The 终末地 (MaaEnd) tab. Same cards and rows as the web page's 终末地 tab (view.js:753 TABS /^终末地/):
// the 库存 entry row (view.js:407), then 基质刷取, 协议空间, 另一个任务 (schema.js:143-218; the web's 「另外两个任务」 has one, 自动采集).
// Data, saving and the tab bar are wired by 验收 once the logic layer lands; this page only draws and reports edits.

import SwiftUI

/// Placeholder input for the page: snap.master["MaaEnd"] and the last good copy the web page keeps in localStorage.
struct EndfieldPageData {
    var master: EWMaster
    var lastGoodMaster: EWMaster? = nil
    /// path -> the small lines under that row (EWRowTag).
    var tags: [String: EWRowTag] = [:]

    static let sample = EndfieldPageData(master: .endfieldSample)
}

struct EndfieldPage: View {
    var data: EndfieldPageData
    var onChange: (String, EWValue) -> Void
    var onResend: (String) -> Void
    /// Reads the data afresh, for the 「更多设置」 pages (EndfieldTab.pageData); nil = they draw from `data`.
    var live: (() -> EndfieldPageData)?

    @State var values: [String: EWValue]
    /// A reselect of the 终末地 tab at its root (ContentView.reselect, D39): scroll to the top. Read in body, so the change
    /// redraws this page (Pages/Shell/TabReselect.swift).
    private var reselect: Int { TabReselect.shared.endfield }

    /// The cards whose 「更多设置」 row pushes EndfieldRoute.more(title); the titles differ (EndfieldSchema.swift:5, 26, 60).
    private static let cards = [EndfieldSchema.essence, EndfieldSchema.protocolSpace, EndfieldSchema.otherTasks]

    init(data: EndfieldPageData,
         live: (() -> EndfieldPageData)? = nil,
         onChange: @escaping (String, EWValue) -> Void = { _, _ in },
         onResend: @escaping (String) -> Void = { _ in }) {
        self.data = data
        self.live = live
        self.onChange = onChange
        self.onResend = onResend
        _values = State(initialValue: ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:])
    }

    var body: some View {
        List {
            // 库存: a single-row card with no header, first on the page (D72, inventory-plan.md §2).
            Section {
                // By value (EndfieldRoute, built in the navigationDestination below), so the tab's NavigationPath holds it
                // and a reselect of the tab can pop it (D39). Still not navigationDestination(isPresented:): the user
                // (10-03 01:11) could not get back in after returning once - a Bool that the pop did not reset leaves the
                // next tap with nothing to change.
                NavigationLink(value: EndfieldRoute.stockpile) {
                    Text("库存")
                }
            }
            card(EndfieldSchema.essence)
            card(EndfieldSchema.protocolSpace)
            card(EndfieldSchema.otherTasks)
        }
        // D39 on Android (the count only moves there, ContentView.reselect): a new List, whose new scroll state starts at
        // the real top. Not scrollTo(the first row): the top inset and the first section's top stay above the screen, the
        // first card's top edge cut under the title (StatusPage.swift explains, at its own .id(reselect)).
        .id(reselect)
        // On the List, not a Section or row (skip-ui's List finds its sections by type, MonthCardRows.swift; SwiftUI wants
        // navigationDestination outside lazy containers); in body so onChange, onResend and live stay in scope.
        .keyboardDone()
        .navigationDestination(for: EndfieldRoute.self) { route in
            switch route {
            case .stockpile:
                EndfieldStockpilePage()
            case .more(let title):
                if let g = Self.cards.first(where: { $0.title == title }) {
                    EndfieldMorePage(group: g, data: live ?? { [data] in data }, onChange: onChange, onResend: onResend)
                }
            }
        }
        .onChange(of: data.master.values) { _, _ in
            values = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:]
        }
    }

    @ViewBuilder
    private func card(_ g: EWGroupSpec) -> some View {
        if let c = ewCard(g, data, values: values) {
            let main = c.rows.filter { EndfieldSchema.firstLevel.contains($0.path) }
            let more = c.rows.contains { !EndfieldSchema.firstLevel.contains($0.path) }
            let foot = ewFoot(main, card: c.rows)   // view.js:976-995: the hints sit under the card, 「行名：」 in front
            // view.js:801-803, 826: a card with no rows this time is not drawn (listSection: a bare `if` leaves an empty
            // grey section on Android, Pages/Shell/SkipFixes.swift).
            listSection("endfield-\(g.title)", if: !c.rows.isEmpty) {
                Section {
                    ForEach(ewNoteRows(c.notes, "warn-\(g.title)") + main) { row in
                        EWRowView(row: row, values: $values, readonly: c.master.readonly, onChange: onChange,
                                  tag: data.tags[row.path], onResend: onResend, showHint: false)
                    }
                    // The rest of the card one level down, as Settings does (HIG-CHECKLIST.maa.md:55). By value, so a reselect
                    // can pop it (D39); not navigationDestination(isPresented:) - see the 库存 row above (7f89811).
                    if more {
                        NavigationLink(value: EndfieldRoute.more(g.title)) {
                            Text("更多设置")
                        }
                        .listRowBackground(rowBackground(nil))   // same row shape as the EWRowView rows beside it (SkipFixes.swift)
                    }
                } header: {
                    Text(g.title)
                } footer: {
                    if !foot.isEmpty { Text(verbatim: foot) }
                }
            }
        } else {
            Section {
                // Nothing readable and no earlier copy: say so instead of an empty card (view.js:414).
                warningLabel("这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改")
                    .foregroundStyle(.orange)
            } header: {
                Text(g.title)
            }
        }
    }
}

/// The pages the 终末地 tab pushes, as values on the tab's NavigationPath (ContentView), so a reselect of the tab can pop
/// them (D39). On Android an enum with a payload is a sealed class: the destination lookup keyed by EndfieldRoute.self finds
/// a case's subclass through its superclasses (skip-ui Navigation.swift:1163-1175).
enum EndfieldRoute: Hashable {
    /// 库存 → EndfieldStockpilePage.
    case stockpile
    /// A card's 「更多设置」 → EndfieldMorePage, by the card's title (EWGroupSpec.title).
    case more(String)
}

/// What one card draws (view.js:409-512): the master its rows read from, the warnings above them, and every row in page
/// order. nil = nothing readable and no earlier copy. Shared by the 终末地 page and its 「更多设置」 pages, so both draw
/// the same rows from the same last-good fallback.
func ewCard(_ g: EWGroupSpec, _ data: EndfieldPageData, values: [String: EWValue]) -> (master: EWMaster, notes: [String], rows: [EWRow])? {
    let (m, notes) = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster)
    guard let m else { return nil }
    // view.js:446: a tree this read did not carry is drawn from the last good read.
    let tm = g.tree.map { m.roots[$0] == nil } == true ? (data.lastGoodMaster ?? m) : m
    return (m, notes, ewRows(g, tm, values: values))
}

/// The warnings as rows; `prefix` keeps their ids apart between pages.
func ewNoteRows(_ notes: [String], _ prefix: String) -> [EWRow] {
    notes.enumerated().map { EWRow(id: "\(prefix)-\($0.offset)", kind: .warning, path: "", label: $0.element) }
}

/// A card's rows past its first level (EndfieldSchema.firstLevel), titled by the task. The rows are worked out here from
/// the page's own `values`, kept to the shown master (machine + 已寄出 + 待保存, ewShown) as the 终末地 page keeps its own,
/// so a mode changed on either page shows the rows it opens; edits go through the same `onChange` into EWEdits.
///
/// Its own state, not the 终末地 page's `$values`: on Android the 终末地 page's resync (its onChange of data.master.values)
/// did not reach this page while it was pushed - a binding captured by the navigationDestination closure skip-ui keeps
/// from its first registration (Navigation.swift:869-872) - so after ✕ here the rows kept the discarded values
/// (执行周期 「已选 6/7」 for 7/7, 使用刻写券 off for on) until a trip back to the root (0.4.4 second test pass).
struct EndfieldMorePage: View {
    var group: EWGroupSpec
    /// Read in `body`, not stored: on Android the pushed page is not redrawn with the 终末地 page's newer data.
    var data: () -> EndfieldPageData
    @State var values: [String: EWValue]
    var onChange: (String, EWValue) -> Void
    var onResend: (String) -> Void

    init(group: EWGroupSpec, data: @escaping () -> EndfieldPageData, onChange: @escaping (String, EWValue) -> Void,
         onResend: @escaping (String) -> Void) {
        self.group = group
        self.data = data
        self.onChange = onChange
        self.onResend = onResend
        let d = data()
        _values = State(initialValue: ewEffectiveMaster(d.master, lastGood: d.lastGoodMaster).0?.values ?? [:])
    }

    /// 「终末地 · 基质刷取」 → 「基质刷取」.
    private var name: String { group.title.components(separatedBy: " · ").last ?? group.title }

    var body: some View {
        let data = self.data()
        let c = ewCard(group, data, values: values)
        let rest = c?.rows.filter { !EndfieldSchema.firstLevel.contains($0.path) } ?? []
        let foot = ewFoot(rest, card: c?.rows ?? [])   // view.js:976-995, as on the 终末地 page
        List {
            // listSection: rows a mode opened can all go while this page is open (SkipFixes.swift)
            listSection("endfield-more-\(group.title)", if: !rest.isEmpty) {
                Section {
                    ForEach(ewNoteRows(c?.notes ?? [], "more-warn-\(group.title)") + rest) { row in
                        EWRowView(row: row, values: $values, readonly: c?.master.readonly ?? [:], onChange: onChange,
                                  tag: data.tags[row.path], onResend: onResend, showHint: false)
                    }
                } footer: {
                    if !foot.isEmpty { Text(verbatim: foot) }
                }
            }
        }
        .keyboardDone()
        // the ✕ / ✓ of 「待保存」 here too, so a change made on this page is saved from it
        .modifier(EWSaveBar(title: name))
        // ✕ (edits dropped), a send, a newer machine state: back to what the master now shows (EndfieldPage's own onChange)
        .onChange(of: data.master.values) { _, _ in
            let d = self.data()
            values = ewEffectiveMaster(d.master, lastGood: d.lastGoodMaster).0?.values ?? [:]
        }
    }
}
