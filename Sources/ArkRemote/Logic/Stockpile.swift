// Ported from maa-automation/web/stockpile.js
//
// 库存 page (M4, user 2026-09-23 08:09), built to remote-mock/v4/inventory-plan.md: the pushed page behind
// the 终末地 tab's 「库存 ›」 row. For every material the newest six-star's full build uses: icon, name,
// 「库存 1,234 · 需 472」, and on the right how many builds the stock covers, 「2.6 人份」 (plan §4.3;
// user 2026-09-23 08:23 「2.6 人份也行，按原方案走」).
//
// Data: Inventory.refresh(force) (inventory.js, ported separately) — the app signs its own 森空岛 request;
// the game machine being off does not matter. Reads only on open and on 「刷新」; no timers.
//
// Sections = the rows' `group`, in games[].groups order, else the order the file first names them (plan
// §4.1); rows without a group are not shown. Inside a section: servings ascending, ties by stock ascending,
// rows without a need last (§4.3).
//
// M4i (user 2026-09-23 09:20): a row that covers one build drops 「需 N」 from its subtitle; only a short row
// keeps 「需 N」 and 「差 N」. Numbers from 10,000 up read in thousands, 22,639k (footnote 「k = 千」). The box
// row is a conversion note, not a 人份: 「133 个 · 换成缺的材料用了 131 个」, 「剩 2 个」.
//
// Self-select box (M4g; user 2026-09-23 09:05): Inventory.applyBox tops up the short rows; the right value
// reads the row's `short` (still short → 「差 N」, covered → 「x.x 人份」), a topped-up row's subtitle reads
// 「库存 6 + 箱 110 · 需 116」, and the box gets a last section of its own.
//
// How it is obtained: the subtitle ends with the first non-empty list of the row's `origin`
// (采集 / 理智关卡 / 其它), e.g. 「库存 354 · 需 136 · 采集」.
//
// Not ported: the stylesheet, the HTML strings, the measured row geometry (value width, wrapped-line
// heights — SwiftUI lays text out itself), the 刷新 button injected into the nav bar, Nav/back-button
// handling and toPhone() (the page does navigation; `EmptyAction.phone` tells it where to go).
// Inventory.refresh is reached through `loader`, set where the inventory port is wired in; the result is
// read as JSON in inventory.js's shape, so either a JSONValue or an encoded struct works.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported

/// One material row as the page shows it.
struct StockRow: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    /// Icon URL (bbs.hycdn.cn answers 403 to any off-site Referer: fetch it without one), or nil.
    let icon: String?
    /// 「库存 1,234」 / 「库存 6 + 箱 110 · 需 116」 / 「133 个 · 换成缺的材料用了 131 个」.
    let subtitle: String
    /// 「 · 采集」 etc. (kept apart: the page sets it with pre-wrap), or nil.
    let origin: String?
    /// Right value: 「2.6 人份」 / 「差 12」 / 「剩 2 个」, or nil.
    let value: String?
}

struct StockSection: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let rows: [StockRow]
}

/// What the 库存 page shows.
enum StockpileContent: Sendable, Equatable {
    /// One-line loading cell with a spinner: 「正在从森空岛读取…」.
    case loading
    /// The sections and the footnote lines (joined with line breaks under the last card).
    case list(sections: [StockSection], footnote: [String])
    /// 「森空岛没有返回仓库数据。」
    case zero(String)
    /// Empty state: title, caption, button label, and what the button does.
    case empty(title: String, text: String, button: String, action: StockpileEmptyAction)
}

enum StockpileEmptyAction: Sendable, Equatable {
    /// 「去手机页」: back out of 库存 and switch to the 手机 tab.
    case phone
    /// 「重试」: `load(force: true)`.
    case retry
}

@MainActor @Observable final class Stockpile {
    static let shared = Stockpile()

    static let title = "库存"
    static let refreshLabel = "刷新"
    static let loadingText = "正在从森空岛读取…"
    /// M4g: the box's own last section.
    static let boxSection = "资源箱"

    var content: StockpileContent = .loading
    /// The 刷新 button is disabled while a read runs.
    var busy = false

    /// Inventory.refresh(force) → inventory.js's result object ({取自, games: [...]}).
    @ObservationIgnored var loader: (@MainActor (Bool) async throws -> JSONValue)?

    @ObservationIgnored private var lastGood: JSONValue?
    @ObservationIgnored private var lastErr = ""

    /// Stockpile.open(): the page is pushed; read without forcing.
    func open() async {
        await load(force: false)
    }

    func load(force: Bool) async {
        if lastGood == nil { content = .loading }
        busy = true
        defer { busy = false }
        do {
            guard let loader else { throw AppError("库存还没接上") }
            paint(try await loader(force))
        } catch {
            paint(.object(["games": .array([.object(["错误": .string(errorMessage(error))])])]))
        }
    }

    /// Forget the last good read (the acceptance script walks the no-data states first; nothing on the page calls it).
    func reset() {
        lastGood = nil
        lastErr = ""
    }

    private func paint(_ d: JSONValue) {
        let g = d["games"]?[0]
        let err: String = g == nil ? "没有读数" : (g?["错误"].flatMap { $0.truthy ? $0.jsString : nil } ?? "")
        if g != nil && err.isEmpty {
            lastGood = d
            lastErr = ""
        } else {
            lastErr = err
        }
        if let good = lastGood, let gg = good["games"]?[0] {
            content = Self.list(gg, good, err: lastErr)
        } else if err == "没配森空岛" {
            content = .empty(title: "没配森空岛", text: "库存从森空岛读；在「手机」页填好密钥串再来。", button: "去手机页", action: .phone)
        } else {
            content = .empty(title: "读不到库存", text: err, button: "重试", action: .retry)
        }
    }

    // MARK: listHtml

    /// Number formatting for one page: 千分位 1,234 (plan §4.3); M4i: from 10,000 up, rounded to thousands
    /// with a k, 22,639,400 → 22,639k, and the footnote then says k = 千.
    private struct NumFormat {
        var usedK = false

        static func grouped(_ n: Int) -> String {
            let s = String(abs(n))
            var out = ""
            for (i, ch) in s.enumerated() {
                if i > 0 && (s.count - i) % 3 == 0 { out += "," }
                out.append(ch)
            }
            return n < 0 ? "-" + out : out
        }

        mutating func num(_ v: Double?) -> String {
            let x = v ?? 0
            if abs(x) < 10000 {
                if x == x.rounded() { return Self.grouped(Int(x)) }
                return jsNumberString(x)
            }
            usedK = true
            return Self.grouped(Int((x / 1000 + 0.5).rounded(.down))) + "k"   // Math.round
        }
    }

    /// x is already floored to one decimal (Inventory.servingsOf); toFixed(1).
    private static func mult(_ x: Double) -> String {
        let t = Int((x * 10).rounded())
        return "\(t / 10).\(abs(t % 10)) 人份"
    }

    /// plan §10 origin: {kind, 采集: [..], 理智关卡: [..], 其它: [..]}; the first non-empty of these.
    private static func originOf(_ r: JSONValue) -> String {
        guard let o = r["origin"], o.truthy else { return "" }
        return ["采集", "理智关卡", "其它"].first { !(o[$0]?.array ?? []).isEmpty } ?? ""
    }

    private static func iconOf(_ r: JSONValue) -> String? {
        guard let s = r["icon"]?.string, !s.isEmpty else { return nil }
        return s
    }

    private static func row(_ r: JSONValue, _ nf: inout NumFormat) -> StockRow {
        let have = r["have"]?.number ?? 0
        let boxN = r["box"]?.number ?? 0
        let haveText = boxN > 0 ? "库存 \(nf.num(have)) + 箱 \(nf.num(boxN))" : "库存 \(nf.num(have))"
        let from = originOf(r)
        // user 09-23 08:40: short of one build reads 「差 N」, not 「0.x 人份」; M4g: N = `short` (after the box)
        let needV = r["need"].flatMap { $0.isNull ? nil : $0.number }
        let short: Double
        if let s = r["short"], !s.isNull { short = s.number ?? 0 } else { short = max(0, (needV ?? 0) - have) }
        // M4i: 需 N only on a short row
        let sub = needV == nil || short <= 0 ? haveText : "\(haveText) · 需 \(nf.num(needV))"
        let servings = r["servings"].flatMap { $0.isNull ? nil : $0.number }
        let v: String? = servings == nil ? nil : short > 0 ? "差 \(nf.num(short))" : mult(servings ?? 0)
        return StockRow(id: r["id"]?.jsString ?? "", name: r["name"]?.jsString ?? "", icon: iconOf(r),
                        subtitle: sub, origin: from.isEmpty ? nil : " · \(from)", value: v)
    }

    /// M4i (user 09-23 09:20 「资源箱为什么也要算人数」): the box is no one's need, only what it was turned into.
    private static func boxRow(_ r: JSONValue, _ box: JSONValue, _ nf: inout NumFormat) -> StockRow {
        let name = box["name"].flatMap { $0.truthy ? $0.jsString : nil } ?? (r["name"]?.jsString ?? "")
        return StockRow(id: r["id"]?.jsString ?? "", name: name, icon: iconOf(r),
                        subtitle: "\(nf.num(r["have"]?.number)) 个 · 换成缺的材料用了 \(nf.num(r["boxUsed"]?.number)) 个",
                        origin: nil, value: "剩 \(nf.num(r["boxLeft"]?.number)) 个")
    }

    /// stockpile.js listHtml(g, d, err): sections and footnote for one game.
    static func list(_ g: JSONValue, _ d: JSONValue, err: String) -> StockpileContent {
        var nf = NumFormat()
        let rows = g["rows"]?.array ?? []
        var groups: [(name: String, rows: [JSONValue])] = []
        for r in rows {
            guard let gr = r["group"], gr.truthy else { continue }
            let name = gr.jsString
            if let i = groups.firstIndex(where: { $0.name == name }) { groups[i].rows.append(r) } else { groups.append((name, [r])) }
        }
        if groups.isEmpty { return .zero("森空岛没有返回仓库数据。") }
        let order = (g["groups"]?.array ?? []).map { $0.jsString }
        let rank = { (n: String) -> Int in order.firstIndex(of: n) ?? Int.max }
        // stable: unnamed ones keep file order
        groups = groups.enumerated().sorted { a, b in
            let ra = rank(a.element.name), rb = rank(b.element.name)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }

        func less(_ a: (Int, JSONValue), _ b: (Int, JSONValue)) -> Bool {
            let sa = a.1["servings"].flatMap { $0.isNull ? nil : $0.number }
            let sb = b.1["servings"].flatMap { $0.isNull ? nil : $0.number }
            if (sa == nil) != (sb == nil) { return sb == nil }
            if (sa ?? 0) != (sb ?? 0) { return (sa ?? 0) < (sb ?? 0) }
            let ha = a.1["have"]?.number ?? 0, hb = b.1["have"]?.number ?? 0
            if ha != hb { return ha < hb }
            return a.0 < b.0
        }
        var sections: [StockSection] = []
        for s in groups {
            let sorted = Array(s.rows.enumerated()).map { ($0.offset, $0.element) }.sorted(by: less).map { $0.1 }
            sections.append(StockSection(name: s.name, rows: sorted.map { row($0, &nf) }))
        }
        let box: JSONValue? = (g["box"]?["id"]?.truthy ?? false) ? g["box"] : nil
        if let box, let own = rows.first(where: { $0["id"]?.jsString == box["id"]?.jsString }),
           let used = own["boxUsed"], !used.isNull, (own["have"]?.number ?? 0) > 0 {
            sections.append(StockSection(name: boxSection, rows: [boxRow(own, box, &nf)]))
        }
        let boxed = rows.contains { ($0["group"]?.truthy ?? false) && ($0["box"]?.number ?? 0) > 0 }
        let taken = d["取自"]?.jsString ?? ""
        var foot: [String] = []
        foot.append(err.isEmpty ? "\(taken) 从森空岛读取" : "\(taken) 读取的数据；这次没读到：\(err)")
        // M4i: 人份 speaks of materials only; the box line (games[].box.note) does not
        foot.append("人份 = 材料库存 ÷ 一人所需" + (boxed ? "（缺的先用资源箱补）" : ""))
        if let c = g["caliber"], c.truthy { foot.append("一人所需 = \(c.jsString)") }
        foot.append("差 N = \(boxed ? "补箱后" : "库存")不够一人份，还差 N（需 − 库存\(boxed ? " − 箱" : "")）")
        if let note = box?["note"], note.truthy { foot.append(note.jsString) }
        if nf.usedK { foot.append("k = 千") }
        if let lag = g["lagNote"], lag.truthy { foot.append(lag.jsString) }
        return .list(sections: sections, footnote: foot)
    }
}
