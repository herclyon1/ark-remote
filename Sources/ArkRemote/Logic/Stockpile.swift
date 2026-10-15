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
// keeps 「需 N」 and 「差 N」. Numbers from 10,000 up read in thousands, 22,639k (footnote 「k = 千」; his 09-23 09:20
// 「你们难道不会用k去表示吗」, kept after the 10-13 review asked for whole numbers). The box
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
    /// Not enough for one build (the value reads 「差 N」): the page marks the row with an orange dot before the value
    /// (app-page-references P5; the value itself stays in the label colour for contrast, HIG review 0.5.2).
    var short = false
}

struct StockSection: Identifiable, Sendable, Equatable {
    var id: String { name }
    let name: String
    let rows: [StockRow]
}

/// One segment of the 库存 page's picker: a build standard of the need table (祀, 明河), by standardFor's key.
struct StockChoice: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
}

/// One essence term row: 「基础属性」 → 「智识提升」.
struct StockTerm: Identifiable, Sendable, Equatable {
    var id: String { slot + name }
    let slot: String
    let name: String
}

/// The essence advice for the signature weapon of the standard shown (need table standards[].weapon.essence).
struct StockEssence: Sendable, Equatable {
    /// 「基质刷取 · 玉中身」.
    let header: String
    let terms: [StockTerm]
    /// 「重度能量淤积点」 (what the places are), or 「掉落地点」 when the table does not say.
    let pointsTitle: String
    /// 「枢纽区、源石研究园、…」, nil when the table names none.
    let points: String?
    /// How MaaEnd's 基质刷取 farms it by itself (the table's `maaend` line), nil when it has none.
    let footer: String?
}

/// What the 库存 page shows above the materials: which standard (a picker when the table has more than one) and
/// that standard's essence advice.
struct StockTop: Sendable, Equatable {
    /// The picker's segments, in the table's order (newest released first); empty = no picker.
    var choices: [StockChoice] = []
    /// The key of the standard shown.
    var selected: String = ""
    /// Under the picker: who it is and when she came / comes, and the next one.
    var caption: String?
    var essence: StockEssence?
}

/// What the 库存 page shows.
enum StockpileContent: Sendable, Equatable {
    /// One-line loading cell with a spinner: 「正在从森空岛读取…」.
    case loading
    /// The sections and the footnote lines (joined with line breaks under the last card).
    case list(sections: [StockSection], footnote: [String])
    /// 「森空岛没有返回仓库数据。」, or the need table's rows carrying no group (Stockpile.ungrouped).
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
    /// Above the materials (only with a list): the standard picker and the essence advice; nil = nothing there.
    var top: StockTop?
    /// The 刷新 button is disabled while a read runs.
    var busy = false

    /// Inventory.refresh(force) → inventory.js's result object ({取自, games: [...]}).
    @ObservationIgnored var loader: (@MainActor (Bool) async throws -> JSONValue)?
    /// The picker: choose the standard with this key (Inventory.setStandard) and hand back the last read worked out
    /// again for it (Inventory.repick), or nil when there is none to reuse.
    @ObservationIgnored var picker: (@MainActor (String) async -> JSONValue?)?

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

    /// The picker was set to `key`: the same read for that standard at once, or a new read when there is none to reuse.
    func pick(_ key: String) async {
        guard !key.isEmpty, key != top?.selected else { return }
        if let picked = await picker?(key) { paint(picked) } else { await load(force: true) }
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
            top = Self.top(gg)
        } else if err == "没配森空岛" {
            content = .empty(title: "没配森空岛", text: "库存从森空岛读，在「手机」页填好密钥串后再来。", button: "去手机页", action: .phone)
            top = nil
        } else {
            content = .empty(title: "读不到库存", text: err, button: "重试", action: .retry)
            top = nil
        }
    }

    // MARK: who and the essence advice

    /// "2026-10-15" → "10-15"; anything else as is.
    static func monthDay(_ date: String) -> String {
        let p = date.split(separator: "-")
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2 else { return date }
        return "\(p[1])-\(p[2])"
    }

    /// 「下一位：明河（11-05 上线）」 in the footnote; 「下一位：明河（11-05）」 in the picker's caption, whose first half has
    /// just said 「10-15 上线」 (HIG review 0.5.2: the long form wrapped and left 「上线）」 alone on the caption's second line).
    static func nextLine(_ n: JSONValue, short: Bool = false) -> String {
        let name = n["name"]?.jsString ?? ""
        let day = monthDay(n["releasedAt"]?.string ?? "")
        return "下一位：\(name)" + (day.isEmpty ? "" : short ? "（\(day)）" : "（\(day) 上线）")
    }

    /// The part above the materials for game `g` of a reading (Inventory's shape): the picker when the table has two
    /// or more standards (the newest released six-star first, the announced one second: the table's order), and the
    /// essence advice of the standard shown - only that one's, since each advice names its own weapon to tick in MaaEnd.
    /// nil when there is neither (a table from before 2026-10-15).
    static func top(_ g: JSONValue) -> StockTop? {
        let std = g["standard"]
        let options = g["standards"]?.array ?? []
        var top = StockTop()
        if options.count >= 2 {
            top.choices = options.compactMap { o in
                let key = o["key"]?.string ?? ""
                let name = o["name"]?.jsString ?? ""
                return key.isEmpty || name.isEmpty ? nil : StockChoice(id: key, title: name)
            }
            if top.choices.count < 2 { top.choices = [] }
        }
        top.selected = std?["key"]?.string ?? ""
        if !top.choices.isEmpty {
            var parts: [String] = []
            if let l = std?["label"]?.string, !l.isEmpty { parts.append(l) }
            let day = monthDay(std?["releasedAt"]?.string ?? "")
            if !day.isEmpty { parts.append("\(day) 上线") }
            // 「专武「玉中身」」: Chinese runs a name on without a space; the brackets set the weapon's name apart
            if let w = std?["weapon"]?.string, !w.isEmpty { parts.append("专武「\(w)」") }
            var caption = parts.joined(separator: "，")
            // the next one named under the newest one; not under the next one herself
            if let n = g["next"], n.truthy, (n["name"]?.jsString ?? "") != (std?["name"]?.jsString ?? ""),
               (std?["role"]?.string ?? "current") != "next" {
                // on a line of its own: run on after 「。」 it wrapped mid-name at phone width, leaving 「（11-05）」 alone
                caption += (caption.isEmpty ? "" : "\n") + nextLine(n, short: true)
            }
            top.caption = caption.isEmpty ? nil : caption
        }
        if let e = std?["essence"], e.truthy, let terms = e["terms"]?.array, !terms.isEmpty {
            let weapon = e["weapon"]?.jsString ?? ""
            let points = (e["points"]?.array ?? []).map { $0.jsString }.filter { !$0.isEmpty }
            let kind = e["pointKind"]?.string ?? ""
            let maaend = e["maaend"]?.string ?? ""
            top.essence = StockEssence(
                header: weapon.isEmpty ? "基质刷取" : "基质刷取 · \(weapon)",
                terms: terms.map { StockTerm(slot: $0["slot"]?.jsString ?? "", name: $0["name"]?.jsString ?? "") },
                pointsTitle: kind.isEmpty ? "掉落地点" : kind,
                points: points.isEmpty ? nil : points.joined(separator: "、"),
                footer: maaend.isEmpty ? nil : maaend)
        }
        return top.choices.isEmpty && top.essence == nil ? nil : top
    }

    /// The last bracket of a standard's footnote when there are two at its end, e.g. 「上线前按客户端预览表，棱柱和折金票
    /// 含天赋树」 of 明河's (the table adds it to a standard whose numbers come from the client's preview table); nil else.
    static func caveat(_ footnote: String?) -> String? {
        guard let f = footnote, f.hasSuffix("）"), let r = f.range(of: "）（", options: .backwards) else { return nil }
        let inner = f[r.upperBound..<f.index(before: f.endIndex)]
        return inner.isEmpty ? nil : String(inner)
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
                        subtitle: sub, origin: from.isEmpty ? nil : " · \(from)", value: v,
                        short: servings != nil && short > 0)
    }

    /// M4i (user 09-23 09:20 「资源箱为什么也要算人数」): the box is no one's need, only what it was turned into.
    private static func boxRow(_ r: JSONValue, _ box: JSONValue, _ nf: inout NumFormat) -> StockRow {
        let name = box["name"].flatMap { $0.truthy ? $0.jsString : nil } ?? (r["name"]?.jsString ?? "")
        return StockRow(id: r["id"]?.jsString ?? "", name: name, icon: iconOf(r),
                        subtitle: "\(nf.num(r["have"]?.number)) 个 · 换成缺的材料用了 \(nf.num(r["boxUsed"]?.number)) 个",
                        origin: nil, value: "剩 \(nf.num(r["boxLeft"]?.number)) 个")
    }

    /// The day the need table was built, so a table that stopped being rebuilt shows its age: the relay rebuilds it every
    /// server day (maa-automation needtable.py), and `built` reads "2026-10-14 03:36 UTC+8" (older copies: "… JST").
    /// nil when there is no date at the start.
    static func builtLine(_ built: String?) -> String? {
        guard let b = built, b.count >= 10 else { return nil }
        let parts = b.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return "需求表 \(m)月\(d)日 核对过最新六星"
    }

    /// A section's title by what the materials are for. A standard counted from the client's preview table (明河 before
    /// she is out) has no build steps, so the table groups her rows by owner and names the groups after her
    /// (「明河」 / 「专武 唤月」 / 「明河 + 专武 唤月」): the first repeated the picker's segment just above it (HIG review
    /// 0.5.2). Such a group is titled by its rows' `owner` the way 祀's groups read (干员… / 武器… / 多处共用); any other
    /// group keeps the table's name.
    static func groupTitle(_ name: String, owner: String?, standard: JSONValue?) -> String {
        let who = standard?["name"]?.jsString ?? ""
        let weapon = standard?["weapon"]?.string ?? ""
        guard (!who.isEmpty && name.contains(who)) || (!weapon.isEmpty && name.contains(weapon)) else { return name }
        switch owner {
        case "干员": return "干员养成"
        case "专武": return "武器养成"
        case "干员 + 专武": return "多处共用"
        default: return name
        }
    }

    /// Rows came back but none has a group: the need table's grouping does not match, not 森空岛 (Inventory.needLacks wording).
    static let ungrouped = "需求表里终末地的材料都没有分组，和这次读到的库存对不上（不是森空岛回报的），列不出来"

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
        if groups.isEmpty { return .zero(rows.isEmpty ? "森空岛没有返回仓库数据。" : ungrouped) }
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
            var title = groupTitle(s.name, owner: s.rows.first?["owner"]?.string, standard: g["standard"])
            if sections.contains(where: { $0.name == title }) { title = s.name }   // ids stay unique
            sections.append(StockSection(name: title, rows: sorted.map { row($0, &nf) }))
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
        if let b = builtLine(g["built"]?.string) { foot.append(b) }
        foot.append("差 N = \(boxed ? "补箱后" : "库存")不够一人份，还差 N（需 − 库存\(boxed ? " − 箱" : "")）")
        if let note = box?["note"], note.truthy { foot.append(note.jsString) }
        if nf.usedK { foot.append("k = 千") }
        if let lag = g["lagNote"], lag.truthy { foot.append(lag.jsString) }
        let std = g["standard"]
        // a standard counted from the client's preview table (明河 before she is out) says so in its own footnote
        if let c = caveat(g["footnote"]?.string) {
            let who = std?["name"]?.string ?? ""
            foot.append(who.isEmpty ? c : "\(who)：\(c)")
        }
        // the next one: in the picker's caption when the table has her numbers; here when it has only her name
        let picker = (g["standards"]?.array ?? []).count >= 2
        let nextErr = g["nextError"]?.string ?? ""
        if let n = g["next"], n.truthy, !picker {
            foot.append(nextLine(n) + (nextErr.isEmpty ? "" : "，她的用量这次没算出来：\(nextErr)"))
        } else if !nextErr.isEmpty {
            foot.append("下一位六星的用量这次没算出来：\(nextErr)")
        }
        if let e = std?["essence"], e.truthy {
            let v = e["dataVersion"]?.string ?? ""
            foot.append("基质词条和掉落地点取自 MaaEnd 的数据" + (v.count >= 10 ? "（\(v.prefix(10)) 版）" : ""))
        } else if let r = std?["essenceReason"]?.string, !r.isEmpty {
            foot.append("基质刷取建议这次没有：\(r)")
        }
        return .list(sections: sections, footnote: foot)
    }
}
