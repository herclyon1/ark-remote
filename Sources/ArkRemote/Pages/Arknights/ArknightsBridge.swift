import Foundation

/// One field of the 方舟 tab, located in `schema` the way view.js locate(id) does (view.js:1025-1031).
struct ArknightsFieldRef {
    let section: SchemaSection
    let field: SchemaField

    /// set_config script or set_master game.
    var owner: String { section.game ?? section.script ?? "" }
    /// view.js:455 `${g.src}|${g.game || g.script}|${f.path}`.
    var id: String { "\(section.src)|\(owner)|\(field.path)" }

    /// view.js valueNow(g, f) (view.js:1032-1034): master fields by path, mas fields by their Chinese key.
    /// A master field missing from `values` falls back to the master's read-only values (view.js:517
    /// `f.path in cur ? cur[f.path] : ro[f.path]`); a null in `values` stays null, as `in` is true for it.
    func rawValue(in snap: JSONValue?) -> JSONValue? {
        if section.src == "master" {
            let m = snap?["master"]?[owner]
            return m?["values"]?[field.path] ?? m?["readonly"]?[field.path]
        }
        return snap?["config"]?[section.sec ?? ""]?[field.key ?? ""]
    }

    /// view.js labelOf(g, f) (view.js:134-140): our own name, else the machine's, else the schema's.
    func rowLabel(in snap: JSONValue?) -> String {
        let own: String?
        if section.src == "master" {
            own = snap?["master"]?[owner]?["labels"]?[field.path]?.string
        } else {
            own = snap?["options"]?["_labels"]?["\(section.script ?? "")|\(field.path)"]?.string
        }
        return field.name ?? (own?.isEmpty == false ? own : nil) ?? field.label ?? field.key
            ?? String(field.path.split(separator: "/").last ?? "")
    }

    /// labelOf prefixed with the section title, as the edits list does (view.js:1041).
    func editLabel(in snap: JSONValue?) -> String {
        "\(section.title) · \(rowLabel(in: snap))"
    }
}

/// The 方舟 fields, in ArknightsPageData order.
enum ArknightsField: CaseIterable {
    case stage, medicineNumb, ifFight, ifActivityFirst, activityStageIndex
    case usesOfDrones
    case awardMail, awardOrundum, awardMining, awardSpecialAccess

    var src: String {
        switch self {
        case .stage, .medicineNumb, .ifFight, .ifActivityFirst, .activityStageIndex: return "mas"
        default: return "master"
        }
    }

    /// schema.js:116-141.
    var path: String {
        switch self {
        case .stage: return "Info.Stage"
        case .medicineNumb: return "Info.MedicineNumb"
        case .ifFight: return "Task.IfFight"
        case .ifActivityFirst: return "Task.IfActivityFirst"
        case .activityStageIndex: return "Task.ActivityStageIndex"
        case .usesOfDrones: return "Infrast/UsesOfDrones"
        case .awardMail: return "Award/Mail"
        case .awardOrundum: return "Award/Orundum"
        case .awardMining: return "Award/Mining"
        case .awardSpecialAccess: return "Award/SpecialAccess"
        }
    }

    var ref: ArknightsFieldRef? {
        for section in schema where section.src == src && (section.game ?? section.script) == "MAA" {
            if let field = section.fields.first(where: { $0.path == path }) {
                return ArknightsFieldRef(section: section, field: field)
            }
        }
        return nil
    }

    /// The page's value as the JSON the web would send, typed after the machine's current value
    /// (view.js:1094-1101: numbers go back as strings when the machine stores a string).
    func outgoing(_ data: ArknightsPageData, machine raw: JSONValue?, options: [String: JSONValue]) -> JSONValue? {
        // view.js:1097: an empty box goes out as null.
        func number(_ text: String?) -> JSONValue? {
            guard let text else { return nil }
            guard let n = Int(text) else { return .null }
            if case .string = raw { return .string(String(n)) }
            return .int(n)
        }
        switch self {
        case .stage: return data.stage.map { .string($0) }
        case .medicineNumb: return number(data.medicineNumb)
        case .ifFight: return data.ifFight.map { .bool($0) }
        case .ifActivityFirst: return data.ifActivityFirst.map { .bool($0) }
        case .activityStageIndex: return number(data.activityStageIndex)
        case .usesOfDrones: return data.usesOfDrones.map { options[$0] ?? .string($0) }
        case .awardMail: return data.awardMail.map { .bool($0) }
        case .awardOrundum: return data.awardOrundum.map { .bool($0) }
        case .awardMining: return data.awardMining.map { .bool($0) }
        case .awardSpecialAccess: return data.awardSpecialAccess.map { .bool($0) }
        }
    }

    /// Puts a JSON value (machine or pending) into the page's typed field.
    func apply(_ v: JSONValue, to data: inout ArknightsPageData) {
        // view.js:503: null shows as an empty box.
        let n = v.isNull ? "" : (v.number.map { String(Int($0)) } ?? v.jsString)
        switch self {
        case .stage: data.stage = v.isNull ? "" : v.jsString
        case .medicineNumb: data.medicineNumb = n
        case .ifFight: data.ifFight = v.truthy
        case .ifActivityFirst: data.ifActivityFirst = v.truthy
        case .activityStageIndex: data.activityStageIndex = n
        case .usesOfDrones: data.usesOfDrones = v.isNull ? "" : v.jsString
        case .awardMail: data.awardMail = v.truthy
        case .awardOrundum: data.awardOrundum = v.truthy
        case .awardMining: data.awardMining = v.truthy
        case .awardSpecialAccess: data.awardSpecialAccess = v.truthy
        }
    }
}

/// A change made on the page and not yet sent (view.js `edits[id]`, view.js:1041-1042).
struct ArknightsEdit: Equatable {
    let field: ArknightsField
    let ref: ArknightsFieldRef
    let label: String
    let from: JSONValue?
    let to: JSONValue

    static func == (a: ArknightsEdit, b: ArknightsEdit) -> Bool { a.ref.id == b.ref.id && a.to == b.to }

    /// The entry in the page's pool of unsaved changes (view.js:1290 `edits[id] = {label, src, owner, path, from, to}`);
    /// EWSave.send turns it into set_config / set_master (view.js:2964-2966) and its Pending entry.
    var poolEdit: EWEdit {
        EWEdit(label: label, src: ref.section.src, owner: ref.owner, path: ref.field.path, from: from, to: to)
    }
}

/// Builds the 方舟 tab's data from the relay snapshot and turns page edits back into commands.
struct ArknightsBridge {
    /// The relay snapshot with snap.master.MAA swapped for the last good copy when this one could not be read
    /// (view.js:415-422 `cur` ← `last.values`); every field read below goes through it, as the web's `cur` does.
    let snap: JSONValue?
    /// snap.master.MAA could not be read this time (view.js:415: no values and no readonly).
    let masterUnreadable: Bool
    /// …and the rows show the last good copy instead (view.js:421).
    let masterStale: Bool
    /// AUTO-MAS could not be read (view.js:309: config._错误 or no config at all).
    let configUnreadable: Bool
    /// …and snap.config is the last one read (view.js:310-311).
    let configStale: Bool
    /// The picked shift (view.js curQueue, stored as "ark-remote-cfg-queue"; chosen on the 状态 tab).
    let queue: String
    /// The yellow notes the web puts at the top of each master section from this read of snap.master.MAA (view.js:488-493):
    /// keys left untranslated, and tasks the script's definition file no longer has.
    let masterNotes: [String]

    init(snap given: JSONValue?, queue: String = "", lastGoodMaster: JSONValue? = nil, lastGoodConfig: JSONValue? = nil) {
        self.queue = queue
        // view.js:308-315: AUTO-MAS not running → the config falls back to the last one read.
        var live = given
        let cfg = given?["config"]?.object ?? [:]
        let cfgBad = given != nil && (cfg["_错误"] != nil || cfg.isEmpty)
        configUnreadable = cfgBad
        if cfgBad, let last = lastGoodConfig, last.object?.isEmpty == false, case .object(var top)? = given {
            top["config"] = last
            live = .object(top)
            configStale = true
        } else {
            configStale = false
        }
        let m = live?["master"]?["MAA"]
        let unreadable = (m?["values"]?.object ?? [:]).isEmpty && (m?["readonly"]?.object ?? [:]).isEmpty
        masterUnreadable = unreadable
        // view.js:488-493: read from this read's master (`M`), not the last good copy.
        var notes: [String] = []
        let untranslated = m?["untranslated"]?.array ?? []
        if !untranslated.isEmpty {
            notes.append("有 \(untranslated.count) 项的名字没翻译出来（脚本这一版换了定义文件的位置），显示的是原始键名")
        }
        let orphans = (m?["orphans"]?.array ?? []).map { $0.jsString }
        if !orphans.isEmpty {
            notes.append("这一版脚本的定义文件里没有这些任务，配置里却还留着：\(orphans.joined(separator: "、"))——这些设置改了不会有效果")
        }
        masterNotes = notes
        // view.js:416-417: no earlier copy with values → the warning instead of the rows.
        if unreadable, let last = lastGoodMaster, last["values"]?.object?.isEmpty == false,
           case .object(var top)? = live {
            var all = top["master"]?.object ?? [:]
            // view.js:483 takes only `last.values`; the read-only fallback `ro` stays this read's (empty here, view.js:471)
            var kept = last.object ?? [:]
            kept["readonly"] = nil
            all["MAA"] = .object(kept)
            top["master"] = .object(all)
            snap = .object(top)
            masterStale = true
        } else {
            snap = live
            masterStale = false
        }
    }

    /// The web's key for the last readable config (view.js:7 LS + "-config", view.js:127, 314).
    static let configKey = "ark-remote-cfg-config"

    /// The last readable snap.config (view.js:127).
    static func lastGoodConfig() -> JSONValue? {
        guard let raw = UserDefaults.standard.string(forKey: configKey),
              let v = try? JSONValue.parse(raw), v.object?.isEmpty == false else { return nil }
        return v
    }

    /// view.js:312-314: keep a readable config for the next time AUTO-MAS is off.
    static func saveConfig(snap: JSONValue?) {
        guard let c = snap?["config"], let o = c.object, !o.isEmpty, o["_错误"] == nil else { return }
        UserDefaults.standard.set(c.encodedString(), forKey: configKey)
    }

    /// The last readable snap.master.MAA, kept by EWLastGood.save under the web's key (view.js:423-426).
    static func lastGoodMaster() -> JSONValue? {
        guard let raw = UserDefaults.standard.string(forKey: EWLastGood.key),
              let all = try? JSONValue.parse(raw), let v = all["MAA"], !v.isNull else { return nil }
        return v
    }

    /// view.js:317-327: the shown shift is the picked one, else the first queue (view.js:321); no queue or an
    /// empty script list means every game is in.
    var inShift: Bool {
        let qs = snap?["queues"]?.array ?? []
        guard let q = qs.first(where: { $0["名"]?.string == queue }) ?? qs.first,
              let scripts = q["脚本"]?.array, !scripts.isEmpty else { return true }
        return scripts.contains { $0.string == "MAA" }
    }

    /// The shift names for the note when MAA is not in the picked shift.
    var shiftName: String {
        let qs = snap?["queues"]?.array ?? []
        return (qs.first(where: { $0["名"]?.string == queue }) ?? qs.first)?["名"]?.string ?? ""
    }

    var master: JSONValue? { snap?["master"]?["MAA"] }

    /// Raw option values by their string form, for writing the machine's own value back (view.js:1202).
    var droneOptionValues: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for pair in master?["options"]?[ArknightsField.usesOfDrones.path]?.array ?? [] {
            if let v = pair[1] { out[v.jsString] = v }
        }
        return out
    }

    var droneOptions: [ArknightsOption] {
        let path = ArknightsField.usesOfDrones.path
        return (master?["options"]?[path]?.array ?? []).compactMap { pair -> ArknightsOption? in
            guard let v = pair[1] else { return nil }
            let lb = pair[0]?.jsString ?? v.jsString
            return ArknightsOption(label: yieldLabel(path, lb, v), value: v.jsString)
        }
    }

    /// The machine's values (`withPending` = false) or what the page should show: the machine's values with
    /// sent-but-unconfirmed changes on top (pending.js applyPending; Pending.shownValue).
    /// `editing` = ids with an unsaved edit (view.js `key in edits`), for the row tags.
    @MainActor func pageData(withPending: Bool, editing: Set<String> = []) -> ArknightsPageData {
        var data = ArknightsPageData()
        guard snap != nil else { return data }
        data.shiftName = shiftName
        guard inShift else {
            data.notInShift = true
            return data
        }
        data.configUnreadable = configUnreadable
        data.configStale = configStale
        data.masterUnreadable = masterUnreadable && !masterStale
        data.masterStale = masterStale
        // view.js:476-481: when the warning replaces the section, the notes are not drawn either.
        data.masterNotes = data.masterUnreadable ? [] : masterNotes
        data.usesOfDronesOptions = droneOptions
        for f in ArknightsField.allCases {
            guard let ref = f.ref else { continue }
            if ref.section.src == "master" && data.masterUnreadable { continue }
            // view.js:459: a field the machine did not report is not drawn.
            guard let raw = ref.rawValue(in: snap) else { continue }
            data.labels[f.path] = ref.rowLabel(in: snap)
            f.apply((withPending ? Pending.shared.shownValue(for: ref.id) : nil) ?? raw, to: &data)
            // pending.js:47-67: 「已寄出 HH:MM · …」 / 「没生效 · …」 / 「已应用 HH:MM」 under the row.
            if withPending, let tag = Pending.shared.tag(for: ref.id, editing: editing.contains(ref.id)) {
                // pending.js:63: a sent row (sent or refused) sits on the green ground; 「已应用」 does not.
                switch tag {
                case .sent(let text):
                    // pending.js:59: past 10 h 「没回执 · 已寄出 HH:MM」 gets 「再发一次」 but stays grey (class "sent", not "sent bad")
                    data.tags[f.path] = ArknightsRowTag(text: text, resendKey: Pending.shared.staleResendKey(for: ref.id), posted: true)
                case .mismatch(let text, let key):
                    data.tags[f.path] = ArknightsRowTag(text: text, resendKey: key, bad: true, posted: true)
                case .applied(let text): data.tags[f.path] = ArknightsRowTag(text: text)
                }
            }
        }
        // view.js:510-523
        data.annihilationDoneThisWeek = snap?["relay"]?["周常"]?["剿灭"]?["本周已完成"]?.truthy ?? false
        return data
    }

    /// The machine's value of every 方舟 field, for Pending.reconcile (the web's render fills liveVals,
    /// from the last good copy too when that is what it draws: view.js:435 then :460).
    var liveVals: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for f in ArknightsField.allCases {
            if let ref = f.ref, let raw = ref.rawValue(in: snap) { out[ref.id] = raw }
        }
        return out
    }

    /// The edits between what the page shows and `base` (view.js note(): an edit back to the old value is dropped).
    func edits(from base: ArknightsPageData, to shown: ArknightsPageData) -> [ArknightsEdit] {
        let options = droneOptionValues
        var out: [ArknightsEdit] = []
        for f in ArknightsField.allCases {
            guard let ref = f.ref else { continue }
            let raw = ref.rawValue(in: snap)
            guard let to = f.outgoing(shown, machine: raw, options: options),
                  to != f.outgoing(base, machine: raw, options: options) else { continue }
            // view.js:1284 base(id, machine): the value before this change is the sent one while it waits, else the machine's
            // — what the row showed, so the review's 「旧 → 新」 reads as what the user saw change.
            out.append(ArknightsEdit(field: f, ref: ref, label: ref.editLabel(in: snap),
                                     from: f.outgoing(base, machine: raw, options: options) ?? raw, to: to))
        }
        return out
    }
}
