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
    func rawValue(in snap: JSONValue?) -> JSONValue? {
        if section.src == "master" {
            return snap?["master"]?[owner]?["values"]?[field.path]
        }
        return snap?["config"]?[section.sec ?? ""]?[field.key ?? ""]
    }

    /// view.js labelOf(g, f) (view.js:134-140), prefixed with the section title as the edits list does (view.js:1041).
    func editLabel(in snap: JSONValue?) -> String {
        let own: String?
        if section.src == "master" {
            own = snap?["master"]?[owner]?["labels"]?[field.path]?.string
        } else {
            own = snap?["options"]?["_labels"]?["\(section.script ?? "")|\(field.path)"]?.string
        }
        let name = field.name ?? (own?.isEmpty == false ? own : nil) ?? field.label ?? field.key
            ?? String(field.path.split(separator: "/").last ?? "")
        return "\(section.title) · \(name)"
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
        func number(_ n: Int?) -> JSONValue? {
            guard let n else { return nil }
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
        let n = v.number.map { Int($0) }
        switch self {
        case .stage: data.stage = v.isNull ? "" : v.jsString
        case .medicineNumb: data.medicineNumb = n ?? 0
        case .ifFight: data.ifFight = v.truthy
        case .ifActivityFirst: data.ifActivityFirst = v.truthy
        case .activityStageIndex: data.activityStageIndex = n ?? 0
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

    /// view.js:2415-2417.
    var body: JSONValue {
        if ref.section.src == "master" {
            return .object(["action": .string("set_master"), "confirmed": .bool(true), "game": .string(ref.owner),
                            "path": .string(ref.field.path), "value": to])
        }
        return .object(["action": .string("set_config"), "confirmed": .bool(true), "script": .string(ref.owner),
                        "path": .string(ref.field.path), "value": to])
    }

    /// view.js:2420-2421.
    var pending: PendingEdit {
        PendingEdit(label: label, src: ref.section.src, owner: ref.owner, path: ref.field.path,
                    from: from, to: to, sentAt: nowSec())
    }
}

/// Builds the 方舟 tab's data from the relay snapshot and turns page edits back into commands.
struct ArknightsBridge {
    let snap: JSONValue?

    /// view.js:317-327: the shown shift is the first queue (the web remembers a picked one; the app has no
    /// shift picker yet); no queue or an empty script list means every game is in.
    var inShift: Bool {
        guard let first = snap?["queues"]?.array?.first,
              let scripts = first["脚本"]?.array, !scripts.isEmpty else { return true }
        return scripts.contains { $0.string == "MAA" }
    }

    var master: JSONValue? { snap?["master"]?["MAA"] }

    /// view.js:412: no values and no readonly → the master copy could not be read.
    /// TODO: the web falls back to the last good master copy (lastGoodMaster, view.js:413-414); the app keeps none yet.
    var masterUnreadable: Bool {
        (master?["values"]?.object ?? [:]).isEmpty && (master?["readonly"]?.object ?? [:]).isEmpty
    }

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
    @MainActor func pageData(withPending: Bool) -> ArknightsPageData {
        var data = ArknightsPageData()
        guard snap != nil, inShift else { return data }
        data.masterUnreadable = masterUnreadable
        data.usesOfDronesOptions = droneOptions
        for f in ArknightsField.allCases {
            guard let ref = f.ref else { continue }
            if ref.section.src == "master" && data.masterUnreadable { continue }
            // view.js:459: a field the machine did not report is not drawn.
            guard let raw = ref.rawValue(in: snap) else { continue }
            f.apply((withPending ? Pending.shared.shownValue(for: ref.id) : nil) ?? raw, to: &data)
        }
        // view.js:510-523
        data.annihilationDoneThisWeek = snap?["relay"]?["周常"]?["剿灭"]?["本周已完成"]?.truthy ?? false
        return data
    }

    /// The machine's value of every 方舟 field, for Pending.reconcile (the web's render fills liveVals).
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
            out.append(ArknightsEdit(field: f, ref: ref, label: ref.editLabel(in: snap), from: raw, to: to))
        }
        return out
    }
}
