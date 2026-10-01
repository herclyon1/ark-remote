// Placeholder data model shared by the 终末地 (MaaEnd) and 鸣潮 (OK-WW) pages.
// "EW" = Endfield / Wuwa; every type here is prefixed so it cannot collide with the other pages' placeholders.
// Shapes and rules are ported from maa-automation/web: schema.js (field table) and view.js
// (render loop :441-514, treeFields :1165, treeVisible :1193, labelOf :134, yieldLabel in schema.js).

import Foundation

/// One config value as the relay reports it. `key` is the value as JS `String(v)` writes it,
/// which is how the web page compares values and keys the option tree.
enum EWValue: Hashable, Sendable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case text(String)
    case list([String])
    case boxes([String: String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let a = try? c.decode([EWValue].self) { self = .list(a.map { $0.key }); return }
        if let d = try? c.decode([String: EWValue].self) { self = .boxes(d.mapValues { $0.key }); return }
        self = .null
    }

    var key: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .text(let s): return s
        case .list(let a): return a.joined(separator: ",")
        case .boxes: return "[object Object]"
        }
    }

    var isOn: Bool {
        if case .bool(let b) = self { return b }
        return false
    }

    var items: [String] {
        switch self {
        case .list(let a): return a
        case .null: return []
        default: return [key]
        }
    }

    var boxValues: [String: String] {
        if case .boxes(let d) = self { return d }
        return [:]
    }

    /// The web page's fmt(): empty for null, the plain value otherwise.
    var display: String {
        if case .null = self { return "" }
        return key
    }
}

/// One `[label, value]` pair from an option table (or `[label, key]` from an inputs table).
struct EWChoice: Hashable, Sendable, Decodable {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lb = try c.decode(EWValue.self)
        let v = try c.decode(EWValue.self)
        label = lb.key
        value = v.key
    }
}

/// Mirror of `snap.master[game]` in the web page: the relay's read of the game's master config.
struct EWMaster: Sendable, Decodable {
    var values: [String: EWValue] = [:]
    var options: [String: [EWChoice]] = [:]
    var labels: [String: String] = [:]
    var roots: [String: [String]] = [:]
    var children: [String: [String: [String]]] = [:]
    var inputs: [String: [EWChoice]] = [:]
    var readonly: [String: EWValue] = [:]
    var subs: [String: [String]] = [:]
    var untranslated: [String] = []
    var orphans: [String] = []

    init() {}

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let m = try? JSONDecoder().decode(EWMaster.self, from: data) else { return nil }
        self = m
    }

    private enum CodingKeys: String, CodingKey {
        case values, options, labels, roots, children, inputs, readonly, subs, untranslated, orphans
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        values = (try? c.decode([String: EWValue].self, forKey: .values)) ?? [:]
        options = (try? c.decode([String: [EWChoice]].self, forKey: .options)) ?? [:]
        labels = (try? c.decode([String: String].self, forKey: .labels)) ?? [:]
        roots = (try? c.decode([String: [String]].self, forKey: .roots)) ?? [:]
        children = (try? c.decode([String: [String: [String]]].self, forKey: .children)) ?? [:]
        inputs = (try? c.decode([String: [EWChoice]].self, forKey: .inputs)) ?? [:]
        readonly = (try? c.decode([String: EWValue].self, forKey: .readonly)) ?? [:]
        subs = (try? c.decode([String: [String]].self, forKey: .subs)) ?? [:]
        untranslated = (try? c.decode([String].self, forKey: .untranslated)) ?? []
        orphans = (try? c.decode([String].self, forKey: .orphans)) ?? []
    }

    var isEmpty: Bool { values.isEmpty && readonly.isEmpty }
}

/// How a field is drawn (schema.js `type`, or derived from the value as treeFields does).
enum EWFieldType: Sendable {
    case bool, select, number, text, pills, icons, boxes
}

/// One hand-written field of schema.js. In tree groups it only overrides the machine's field.
struct EWFieldSpec: Sendable {
    var path: String
    var type: EWFieldType? = nil
    var label: String? = nil
    var name: String? = nil
    var hint: String? = nil
    var readOnly = false
    var choices: [EWChoice]? = nil
    /// icons fields: the two set names behind each choice, shown as "A ＋ B".
    var iconNames: [String: [String]]? = nil
}

/// One card of schema.js (`title`, `tree`, `fields`).
struct EWGroupSpec: Sendable {
    var title: String
    var tree: String? = nil
    var fields: [EWFieldSpec]
}

/// What a drawn row is.
enum EWRowKind: Sendable {
    case warning
    case readOnly
    case toggle
    case select
    case icons
    case pills
    case boxesHeader
    case box
    case number
    case text
}

/// One drawn row. `id` is unique within the page (path, or path#key for a box).
struct EWRow: Identifiable, Sendable {
    var id: String
    var kind: EWRowKind
    var path: String
    var label: String
    var hint: String?
    var choices: [EWChoice] = []
    var boxKey: String? = nil
}

/// The products after an option name (schema.js YIELDS / yieldLabel; user 09-25 15:19).
let ewYields: [String: [String: String]] = [
    "ProtocolSpace/ProtocolSpaceTab": [
        "OperatorProgression": "作战记录、协议圆盘、折金票、协议棱柱",
        "WeaponProgression": "武器检查、强固模具",
        "CrisisDrills": "五种高阶素材",
    ],
    "ProtocolSpace/OperatorProgression": [
        "OperatorEXP": "作战记录 / 认知载体",
        "Promotions": "协议圆盘 / 协议圆盘组",
        "SkillUp": "协议棱柱 / 协议棱柱组",
    ],
    "ProtocolSpace/WeaponProgression": [
        "WeaponTune": "强固模具 / 重型强固模具",
    ],
]

func ewYieldLabel(_ path: String, _ label: String, _ value: String) -> String {
    guard let y = ewYields[path]?[value], !label.contains("（") else { return label }
    return "\(label)（\(y)）"
}

/// treeFields (view.js:1165): the machine's whole option tree, parents before children, each once;
/// schema.js fields only add hint / name / type. Duplicate names get the opening choice's name in front.
func ewTreeFields(_ g: EWGroupSpec, _ m: EWMaster) -> [EWFieldSpec] {
    guard let tree = g.tree, let roots = m.roots[tree] else { return g.fields }
    var over: [String: EWFieldSpec] = [:]
    for f in g.fields where over[f.path] == nil { over[f.path] = f }
    var order: [String] = []
    var seen = Set<String>()
    var parent: [String: (String, String)] = [:]
    // Depth-first walk, same visiting order as the recursive JS (choices sorted: Swift dictionaries keep no order).
    func walk(_ p: String) {
        if seen.contains(p) { return }
        seen.insert(p)
        order.append(p)
        let kids = m.children[p] ?? [:]
        for c in kids.keys.sorted() {
            for q in kids[c] ?? [] {
                if parent[q] == nil { parent[q] = (p, c) }
                walk(q)
            }
        }
    }
    for p in ["\(tree)/@enabled"] + roots { walk(p) }
    var count: [String: Int] = [:]
    for p in order { if let l = m.labels[p] { count[l, default: 0] += 1 } }
    return order.compactMap { p -> EWFieldSpec? in
        guard let v = m.values[p] else { return nil }
        var f = over[p] ?? EWFieldSpec(path: p)
        if f.type == nil {
            if case .bool = v { f.type = .bool }
            else if m.inputs[p] != nil { f.type = .boxes }
            else if case .list = v { f.type = .pills }
            else if m.options[p] != nil { f.type = .select }
            else { f.type = .text }
        }
        if f.name == nil, let l = m.labels[p], (count[l] ?? 0) > 1, let pc = parent[p] {
            let (pp, c) = pc
            let hit = (m.options[pp] ?? []).first { $0.value == c }
            let head = hit?.label ?? m.labels[pp] ?? String(pp.split(separator: "/").last ?? "")
            f.name = "\(head) · \(l)"
        }
        return f
    }
}

/// treeVisible (view.js:1193): the master switch and top items always; the rest only while the choice that opens them is selected.
func ewTreeVisible(_ g: EWGroupSpec, _ m: EWMaster, _ eff: (String) -> String) -> [String] {
    guard let tree = g.tree else { return [] }
    var vis: [String] = []
    var seen = Set<String>()
    func walk(_ p: String) {
        if seen.contains(p) { return }
        seen.insert(p)
        vis.append(p)
        for q in m.children[p]?[eff(p)] ?? [] { walk(q) }
    }
    for p in ["\(tree)/@enabled"] + (m.roots[tree] ?? []) { walk(p) }
    return vis
}

/// labelOf (view.js:134): our own name where the script's is ambiguous, else the script's own translation.
func ewLabel(_ f: EWFieldSpec, _ m: EWMaster) -> String {
    f.name ?? m.labels[f.path] ?? f.label ?? String(f.path.split(separator: "/").last ?? "")
}

/// The master to draw and the warnings above the rows (view.js:409-432).
/// nil master = nothing readable and no earlier copy: the card is only a warning.
func ewEffectiveMaster(_ m: EWMaster, lastGood: EWMaster?) -> (EWMaster?, [String]) {
    var notes: [String] = []
    var use = m
    if m.isEmpty {
        guard let last = lastGood, !last.values.isEmpty else { return (nil, notes) }
        notes.append("配置文件这次读不到——下面是上次读到的，改了要等它能读到才生效")
        use = last
    }
    if !m.untranslated.isEmpty {
        notes.append("有 \(m.untranslated.count) 项的名字没翻译出来（脚本这一版换了定义文件的位置），显示的是原始键名")
    }
    if !m.orphans.isEmpty {
        notes.append("这一版脚本的定义文件里没有这些任务，配置里却还留着：\(m.orphans.joined(separator: "、"))——这些设置改了不会有效果")
    }
    return (use, notes)
}

/// The rows of one card (view.js render loop :441-512): which fields show, in what order, drawn as what.
func ewRows(_ g: EWGroupSpec, _ m: EWMaster, values: [String: EWValue], hidden: Set<String> = []) -> [EWRow] {
    let fields = g.tree != nil ? ewTreeFields(g, m) : g.fields
    let drawn: [EWFieldSpec]
    if g.tree != nil {
        let vis = ewTreeVisible(g, m) { values[$0]?.key ?? "" }
        drawn = vis.compactMap { p in fields.first { $0.path == p } }
    } else {
        drawn = fields
    }
    var rows: [EWRow] = []
    for f in drawn where !hidden.contains(f.path) {
        guard values[f.path] != nil || m.readonly[f.path] != nil else { continue }   // not on the machine: not drawn
        let live = f.choices ?? (m.options[f.path] ?? []).map { EWChoice(ewYieldLabel(f.path, $0.label, $0.value), $0.value) }
        let label = ewLabel(f, m)
        var row = EWRow(id: f.path, kind: .text, path: f.path, label: label, hint: f.hint, choices: live)
        if f.readOnly {
            row.kind = .readOnly
        } else if f.type == .bool {
            row.kind = .toggle
        } else if f.type == .icons {
            row.kind = .icons
        } else if f.type == .pills {
            row.kind = .pills
        } else if f.type == .boxes {
            row.kind = .boxesHeader
            row.choices = m.inputs[f.path] ?? []
            rows.append(row)
            for b in m.inputs[f.path] ?? [] {
                rows.append(EWRow(id: "\(f.path)#\(b.value)", kind: .box, path: f.path, label: b.label, hint: nil, boxKey: b.value))
            }
            continue
        } else if !live.isEmpty {
            row.kind = .select
        } else if f.type == .number {
            row.kind = .number
        } else {
            row.kind = .text
        }
        rows.append(row)
    }
    return rows
}
