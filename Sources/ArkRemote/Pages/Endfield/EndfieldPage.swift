// The 终末地 (MaaEnd) tab. Same cards and rows as the web page's 终末地 tab (view.js:753 TABS /^终末地/):
// the 库存 entry row (view.js:407), then 基质刷取, 协议空间, 另外两个任务 (schema.js:143-218).
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
    var onOpenStockpile: () -> Void
    var onResend: (String) -> Void

    @State var values: [String: EWValue]

    init(data: EndfieldPageData,
         onChange: @escaping (String, EWValue) -> Void = { _, _ in },
         onOpenStockpile: @escaping () -> Void = {},
         onResend: @escaping (String) -> Void = { _ in }) {
        self.data = data
        self.onChange = onChange
        self.onOpenStockpile = onOpenStockpile
        self.onResend = onResend
        _values = State(initialValue: ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:])
    }

    var body: some View {
        List {
            // 库存: a single-row card with no header, first on the page (D72, inventory-plan.md §2).
            Section {
                Button(action: onOpenStockpile) {
                    HStack {
                        Text("库存")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
            card(EndfieldSchema.essence)
            card(EndfieldSchema.protocolSpace)
            card(EndfieldSchema.otherTasks)
        }
        .onChange(of: data.master.values) { _, _ in
            values = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster).0?.values ?? [:]
        }
    }

    @ViewBuilder
    private func card(_ g: EWGroupSpec) -> some View {
        let (m, notes) = ewEffectiveMaster(data.master, lastGood: data.lastGoodMaster)
        if let m {
            // view.js:446: a tree this read did not carry is drawn from the last good read.
            let tm = g.tree.map { m.roots[$0] == nil } == true ? (data.lastGoodMaster ?? m) : m
            let drawn = ewRows(g, tm, values: values)
            // view.js:801-803, 826: a card with no rows this time is not drawn (listSection: a bare `if` leaves an empty
            // grey section on Android, Pages/Shell/SkipFixes.swift).
            listSection("endfield-\(g.title)", if: !drawn.isEmpty) {
                Section {
                    let rows = notes.enumerated().map { EWRow(id: "warn-\(g.title)-\($0.offset)", kind: .warning, path: "", label: $0.element) }
                        + drawn
                    ForEach(rows) { row in
                        EWRowView(row: row, values: $values, readonly: m.readonly, onChange: onChange,
                                  tag: data.tags[row.path], onResend: onResend)
                    }
                } header: {
                    Text(g.title)
                }
            }
        } else {
            Section {
                // Nothing readable and no earlier copy: say so instead of an empty card (view.js:414).
                Label("这一段的配置文件读不到（机器上那份母本不在或坏了），这次没法改", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } header: {
                Text(g.title)
            }
        }
    }
}
