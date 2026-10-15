// Ported from maa-automation/web/inventory.js
//
// Inventory (库存): the app asks the game's official API itself, on the user's action only, and lays
// the answer next to the "one full build needs" table (the relay rebuilds it every server day,
// maa-automation relay/ark_relay/features/needtable/). Endfield only for now; the result is shaped per game so
// 明日方舟 / 鸣潮 can be added later without changing the shape. Field meanings are the ones in the
// header of inventory.js (section, group, owner, uses, origin, footnote, lagNote, have, need,
// standards, servings, box, short, boxUsed / boxLeft, virtual, icon).
//
// Credentials and signing are StaminaStore's (Stamina.swift): the 森空岛 session the machine handed
// over in the snapshot, and skRefresh / skGet - the signing code exists once. Reads happen only when
// the page asks (open / pull to refresh / 刷新); repeats within a minute reuse the last answer. No timers.
//
// The material-list (names, rarity, icons) is cached in UserDefaults for seven days and refetched
// early only when the inventory names an id the cache does not know.
//
// Not a straight port:
// - The page fetched the relative "data/need.json" from its own origin. The app reads the copy the relay
//   rebuilds every server day next to the phone state on COS (`Relay.needURL(topic:)`, maa-automation
//   needtable.py, since 2026-10-14), and the old deployed copy (`needURL`, last built 09-23) only when that is
//   not there (no topic yet, an older relay). Both reads skip the HTTP cache (the page used `no-cache` /
//   `reload`; both end up with the server's current file).
// - The "森空岛没给终末地的仓库：…" message lists the first six keys of an unordered dictionary, so
//   the order of the names may differ from the page's.

import Foundation
import Observation
import SkipFuse   // @Observable types only drive the Android UI with SkipFuse imported (skipstone warning)

// MARK: - Result shape

/// One step of the build that spends a material: `{use, need}`.
struct InventoryUse: Codable, Sendable, Equatable {
    var use: String
    var need: Int?
}

/// One material row of a game (see the inventory.js header for each field).
struct InventoryRow: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var rarity: Int?
    var icon: String
    /// What the account holds now (absent from the API = 0); for the two exp rows, Σ count × exp.
    var have: Int
    /// The full build's need; 0 = this build does not use it, nil = not a build material.
    var need: Int?
    /// (have + box) ÷ need, one decimal (floored); nil when there is no need.
    var servings: Double?
    /// Units the self-select box tops this row up with.
    var box: Int
    /// need − have − box when still short, 0 when covered, nil when there is no need.
    var short: Int?
    var group: String?
    var stage: String?
    var note: String?
    var virtual: Bool
    var sumInto: String?
    var exp: Int?
    /// The heading the row sits under; nil = folded into 干员经验 / 武器经验 and not shown.
    var section: String?
    var owner: String?
    var uses: [InventoryUse]
    /// `{kind, 采集, 理智关卡, 其它, wikiItemId}` from the official wiki, kept as is.
    var origin: JSONValue?
    /// On the box's own row only: boxes spent / boxes still spare.
    var boxUsed: Int?
    var boxLeft: Int?
}

/// need.json games[].box: the self-select box.
struct InventoryBox: Codable, Sendable, Equatable {
    var id: String
    var name: String
    /// Units one box opens into.
    var per: Int
    var picks: [String]
    var pickNames: [String]
    var note: String?
    var source: String?
    var rule: String?
}

/// games[].boxUse: `{held, used, left}` for this read.
struct BoxUse: Codable, Sendable, Equatable {
    var held: Int
    var used: Int
    var left: Int
}

/// One essence term of a weapon: the slot it sits in (基础属性 / 附加属性 / 技能属性) and its name.
struct EssenceTerm: Codable, Sendable, Equatable {
    var slot: String
    var name: String
}

/// standards[].weapon.essence (maa-automation needtable build.py essence_advice, since 2026-10-15): the signature
/// weapon's three essence terms, the energy points that drop all three, and how MaaEnd's 目标选择 farms it. Taken from
/// the table only when `terms` is a non-empty array; otherwise only `reason` (why there is no advice) is kept.
struct EssenceAdvice: Codable, Sendable, Equatable {
    var weapon: String
    var terms: [EssenceTerm]
    /// The points' short names (「枢纽区」), in the table's order.
    var points: [String]
    /// What every point is, when their full names share it (「重度能量淤积点」 of 「重度能量淤积点·枢纽区」), else "".
    var pointKind: String
    var engrave: String
    var maaend: String
    var dataVersion: String
    var reason: String
}

/// games[].standard: the build standard in force.
struct InventoryStandard: Codable, Sendable, Equatable {
    var charId: String?
    var name: String?
    var rarity: Int?
    var releasedAt: String?
    var status: String?
    var weapon: String?
    var sources: JSONValue?
    /// The key standardFor matches a choice by: charId, else wikiItemId (an announced six-star has no charId yet).
    var key: String?
    /// "current" | "next" | "named"; nil in tables built before 2026-10-15.
    var role: String?
    /// 「最新六星」 / 「下一位六星」 / 「指定干员」; nil in older tables.
    var label: String?
    var essence: EssenceAdvice?
    /// Why there is no essence advice (the table's `reason`), "" when there is advice or nothing was said.
    var essenceReason: String?
}

/// One entry of standards(): what a picker shows.
struct StandardOption: Codable, Sendable, Equatable, Identifiable {
    var charId: String?
    var name: String?
    var rarity: Int?
    var releasedAt: String?
    var status: String?
    var weapon: String?
    var caliber: String?
    /// standardFor's key (charId, else wikiItemId); "" only when the table names neither.
    var key: String = ""
    var role: String?
    var label: String?
    var id: String { key.isEmpty ? (name ?? "") : key }
}

/// The six-star after the one shown: coverage.next, else the table's `role: "next"` standard.
struct NextStandard: Codable, Sendable, Equatable {
    var name: String
    var releasedAt: String
    var status: String?
    var weapon: String?
}

/// One game of the reading.
struct InventoryGame: Codable, Sendable, Equatable {
    var game: String
    var gameId: String
    var error: String = ""
    var caliber: String?
    var footnote: String?
    var source: String?
    var built: String?
    var gameLevel: JSONValue?
    var sections: [String] = []
    var groups: [String] = []
    var useSource: String?
    var originSource: String?
    var lagMinutes: Int?
    var lagNote: String?
    var standard: InventoryStandard?
    var standards: [StandardOption] = []
    /// The announced six-star after the newest released one (coverage.next / the `role: "next"` standard), nil when the
    /// table names none (tables before 2026-10-15).
    var next: NextStandard?
    /// coverage.nextError: why the table could not build the next one's numbers, "" when it could.
    var nextError: String = ""
    var box: InventoryBox?
    var boxUse: BoxUse?
    var rows: [InventoryRow] = []

    enum CodingKeys: String, CodingKey {
        case game, gameId, error = "错误", caliber, footnote, source, built, gameLevel, sections, groups, useSource,
             originSource, lagMinutes, lagNote, standard, standards, next, nextError, box, boxUse, rows
    }
}

/// The whole reading: `{取自: "HH:MM", games: [...]}`.
struct InventoryReading: Codable, Sendable, Equatable {
    var takenAt: String
    var games: [InventoryGame]

    enum CodingKeys: String, CodingKey {
        case takenAt = "取自", games
    }
}

/// material-list, flattened: name, rarity, icon, exp, kind (charExpMaterials / weaponExpMaterials / materials).
struct MaterialInfo: Codable, Sendable, Equatable {
    var name: String
    var rarity: Int?
    var icon: String
    var exp: Int
    var kind: String
}

// MARK: - Small JSON helpers (JS semantics)

/// `x == null ? null : x` for a JSON value.
private func nonNull(_ v: JSONValue?) -> JSONValue? {
    guard let v, !v.isNull else { return nil }
    return v
}
/// `Number(x) || 0` as an integer.
private func intOrZero(_ v: JSONValue?) -> Int {
    guard let d = v?.number, d.isFinite else { return 0 }
    return Int(d)
}
/// A JSON number (or numeric string) as an integer; nil for null / missing / not a number.
private func intOrNil(_ v: JSONValue?) -> Int? {
    guard let v = nonNull(v), let d = v.number, d.isFinite else { return nil }
    return Int(d)
}
/// A JSON string field, nil when null / missing.
private func strOrNil(_ v: JSONValue?) -> String? {
    guard let v = nonNull(v) else { return nil }
    return v.jsString
}
private func strings(_ v: JSONValue?) -> [String] {
    (v?.array ?? []).compactMap { $0.isNull ? nil : $0.jsString }
}

// MARK: - Pure calculations

enum InventoryCalc {
    /// inventory.js servingsOf(have, need).
    static func servingsOf(_ have: Int, _ need: Int?) -> Double? {
        guard let need, need > 0 else { return nil }
        return (Double(have) / Double(need) * 10).rounded(.down) / 10
    }

    /// inventory.js shortOf(have, need).
    static func shortOf(_ have: Int, _ need: Int?) -> Int? {
        guard let need, need > 0 else { return nil }
        return Swift.max(0, need - have)
    }

    /// inventory.js flattenMaterials(d): `{id: MaterialInfo}` for all materials; names trimmed
    /// (they carried a trailing newline on 2026-08-28).
    static func flattenMaterials(_ d: JSONValue?) -> [String: MaterialInfo] {
        var out: [String: MaterialInfo] = [:]
        for kind in ["charExpMaterials", "weaponExpMaterials", "materials"] {
            for (id, m) in d?[kind]?.object ?? [:] {
                let rarity: Int? = (m["rarity"]?.truthy ?? false) ? intOrNil(m["rarity"]?["value"]) : nil
                out[id] = MaterialInfo(name: jsStr(m["name"]).trimmingCharacters(in: .whitespacesAndNewlines),
                                       rarity: rarity, icon: jsStr(m["icon"]), exp: intOrZero(m["exp"]), kind: kind)
            }
        }
        return out
    }

    /// inventory.js rowOf(base, have, mat).
    static func rowOf(_ base: JSONValue, _ have: Int, _ mat: [String: MaterialInfo]) -> InventoryRow {
        let id = jsStr(base["id"])
        let m = mat[id]
        let need = intOrNil(base["need"])
        let name = jsStr(base["name"]).isEmpty ? ((m?.name ?? "").isEmpty ? id : m!.name) : jsStr(base["name"])
        let uses: [InventoryUse] = (base["uses"]?.array ?? []).map { InventoryUse(use: jsStr($0["use"]), need: intOrNil($0["need"])) }
        return InventoryRow(
            id: id, name: name,
            rarity: intOrNil(base["rarity"]) ?? m?.rarity,
            icon: jsStr(base["icon"]).isEmpty ? (m?.icon ?? "") : jsStr(base["icon"]),
            have: have, need: need, servings: servingsOf(have, need),
            box: 0, short: shortOf(have, need),
            group: strOrNil(base["group"]), stage: strOrNil(base["stage"]), note: strOrNil(base["note"]),
            virtual: base["virtual"]?.truthy ?? false,
            sumInto: jsStr(base["sumInto"]).isEmpty ? nil : jsStr(base["sumInto"]),
            exp: intOrNil(base["exp"]),
            section: strOrNil(base["section"]), owner: strOrNil(base["owner"]),
            uses: uses, origin: nonNull(base["origin"]).flatMap { $0.truthy ? $0 : nil })
    }

    /// inventory.js rowsFor(needGame, counts, mat): need rows + live counts -> rows. Exp materials add
    /// count × exp into their virtual row; ids the need table does not know are appended with need nil.
    /// `needRows` is the `rows` array of the standard (or the game) in force.
    static func rowsFor(_ needRows: [JSONValue], _ counts: [String: JSONValue], _ mat: [String: MaterialInfo]) -> [InventoryRow] {
        var expSum: [String: Int] = [:]
        for b in needRows {
            let into = jsStr(b["sumInto"])
            if !into.isEmpty { expSum[into, default: 0] += intOrZero(counts[jsStr(b["id"])]) * intOrZero(b["exp"]) }
        }
        var rows: [InventoryRow] = []
        var known = Set<String>()
        for b in needRows {
            let id = jsStr(b["id"])
            known.insert(id)
            let have = (b["virtual"]?.truthy ?? false) ? (expSum[id] ?? 0) : intOrZero(counts[id])
            rows.append(rowOf(b, have, mat))
        }
        // The page walked the counts in the API's key order; a Swift dictionary has none, so sort by id
        // to keep the appended rows stable between reads.
        for id in counts.keys.sorted() where !known.contains(id) {
            let name = mat[id].map { $0.name.isEmpty ? id : $0.name } ?? id
            rows.append(rowOf(.object(["id": .string(id), "name": .string(name), "need": .null]), intOrZero(counts[id]), mat))
        }
        return rows
    }

    /// inventory.js applyBox(rows, box). The self-select box (user 2026-09-23 09:05): boxes only top up
    /// the materials the box opens into (box.picks) that are short of one build. One box at a time goes
    /// to the one with the fewest servings, (have + box) ÷ need - ties keep table order - as box.per
    /// units, until each is covered or the boxes run out. A row still short keeps its short; a covered
    /// row shows its servings as usual, box units included. Boxes left over stay unspent. Rows change in place.
    @discardableResult
    static func applyBox(_ rows: inout [InventoryRow], _ box: InventoryBox?) -> BoxUse? {
        guard let box, !box.id.isEmpty else { return nil }
        let ownIndex = rows.firstIndex { $0.id == box.id }
        let held = ownIndex.map { rows[$0].have } ?? 0
        let per = box.per
        let picks = Set(box.picks)
        let want = rows.indices.filter { i in
            let r = rows[i]
            guard picks.contains(r.id), let need = r.need, need > 0 else { return false }
            return r.have < need
        }
        var used = 0
        while used < held && per > 0 {
            var low: Int? = nil
            for i in want {
                let r = rows[i], need = Double(r.need ?? 0)
                if r.have + r.box >= r.need ?? 0 { continue }
                if let l = low {
                    let lr = rows[l]
                    if Double(r.have + r.box) / need < Double(lr.have + lr.box) / Double(lr.need ?? 0) { low = i }
                } else {
                    low = i
                }
            }
            guard let l = low else { break }
            rows[l].box += per
            used += 1
        }
        for i in want {
            rows[i].servings = servingsOf(rows[i].have + rows[i].box, rows[i].need)
            rows[i].short = shortOf(rows[i].have + rows[i].box, rows[i].need)
        }
        if let o = ownIndex {
            rows[o].boxUsed = used
            rows[o].boxLeft = held - used
        }
        return BoxUse(held: held, used: used, left: held - used)
    }

    /// need.json games[].box as a typed value; nil when absent.
    static func box(_ v: JSONValue?) -> InventoryBox? {
        guard let v = nonNull(v), v.truthy else { return nil }
        return InventoryBox(id: jsStr(v["id"]), name: jsStr(v["name"]), per: intOrZero(v["per"]),
                            picks: strings(v["picks"]), pickNames: strings(v["pickNames"]),
                            note: strOrNil(v["note"]), source: strOrNil(v["source"]), rule: strOrNil(v["rule"]))
    }
}

// MARK: - Store

@MainActor @Observable final class InventoryStore {
    static let shared = InventoryStore()

    static let zonaiInventory = "/web/v1/game/endfield/calculate/user-game-data"
    static let zonaiMaterials = "/web/v1/game/endfield/calculate/material-list"
    /// The page read "data/need.json" next to itself; this is that file on the deployed site. Since the relay
    /// rebuilds the table itself (`relayNeedURL`), this is the fallback: it was last built 2026-09-23.
    static let needURL = "https://herclyon1.github.io/maa/data/need.json"
    /// The replay test's own copy of the table (scripts/replay/skland_local.py), read before the others when this key
    /// names a loopback URL (loopbackOverride: no other host is taken). Nothing in the app writes it.
    static let needURLKey = "ark-need-url"
    static let matKey = "ark-remote-matlist"
    static let standardKey = "ark-remote-need-standard"
    static let minGapMs: Double = 60 * 1000
    static let matMaxAgeMs: Double = 7 * 24 * 3600 * 1000
    static let gameName = "终末地"
    static let gameIdEndfield = "endfield"

    /// The last reading (the object described at the top of inventory.js).
    var data: InventoryReading?
    /// When `data` was taken (ms since the epoch).
    var at: Double = 0
    var busy = false
    /// need.json as read, `{built, games: [...]}`.
    var need: JSONValue?
    /// This read's need.json error, "" when the table was read (cleared at the start of each read).
    var err = ""
    /// The GETs loadNeed makes; tests replace it so no request leaves the Mac.
    @ObservationIgnored var fetchNeed: (String) async throws -> (Data, Int) = { try await httpFetch($0, noStore: true) }

    /// Where the 森空岛 session and signing live.
    var stamina: StaminaStore { StaminaStore.shared }

    // MARK: need table

    /// The relay's daily copy of the table next to the phone state (Relay.needURL); nil without a topic.
    var relayNeedURL: String? {
        let t = (Relay.shared.config?.topic ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : Relay.needURL(topic: t)
    }

    /// inventory.js loadNeed(force): the need table, read fresh on every refresh - the relay's daily copy first, the old
    /// deployed one when that cannot be read. The error is the last one's.
    @discardableResult
    func loadNeed(force: Bool = false) async throws -> JSONValue {
        var last: Error = AppError("需求表拿不到")
        for url in [loopbackOverride(Self.needURLKey), relayNeedURL, Self.needURL].compactMap({ $0 }) {
            do {
                let (body, status) = try await fetchNeed(url)
                guard (200..<300).contains(status) else { throw AppError("需求表拿不到（\(status)）") }
                let j: JSONValue
                do { j = try JSONValue.parse(body) } catch { throw AppError("需求表格式不对") }
                guard j["games"]?.array != nil else { throw AppError("需求表格式不对") }
                need = j
                return j
            } catch {
                last = error
            }
        }
        throw last
    }

    /// inventory.js needFor(gameId).
    func needFor(_ gameId: String) -> JSONValue? {
        need?["games"]?.array?.first { jsStr($0["gameId"]) == gameId }
    }

    /// inventory.js standards(gameId): the build standards of a game, for a picker.
    func standards(_ gameId: String = InventoryStore.gameIdEndfield) -> [StandardOption] {
        (needFor(gameId)?["standards"]?.array ?? []).map { s in
            StandardOption(charId: strOrNil(s["charId"]), name: strOrNil(s["name"]), rarity: intOrNil(s["rarity"]),
                           releasedAt: strOrNil(s["releasedAt"]), status: strOrNil(s["status"]),
                           weapon: strOrNil(s["weapon"]?["name"]), caliber: strOrNil(s["caliber"]),
                           key: Self.standardKey(s) ?? "", role: strOrNil(s["role"]), label: strOrNil(s["label"]))
        }
    }

    /// The key a standard is chosen by: its charId, else its wikiItemId (an announced six-star has no charId until the
    /// calculator lists her: 明河 in the 2026-10-15 table); nil when it has neither.
    nonisolated static func standardKey(_ s: JSONValue) -> String? {
        let c = jsStr(s["charId"])
        if !c.isEmpty { return c }
        let w = jsStr(s["wikiItemId"])
        return w.isEmpty ? nil : w
    }

    /// standards[].weapon.essence as the page uses it: the advice when it has terms, else only its reason.
    nonisolated static func essence(_ v: JSONValue?) -> (advice: EssenceAdvice?, reason: String) {
        guard let e = nonNull(v), e.object != nil else { return (nil, "") }
        let reason = strOrNil(e["reason"]) ?? ""
        let terms: [EssenceTerm] = (e["terms"]?.array ?? []).compactMap { t in
            let name = jsStr(t["name"])
            return name.isEmpty ? nil : EssenceTerm(slot: jsStr(t["slot"]), name: name)
        }
        guard !terms.isEmpty else { return (nil, reason) }
        let pts = (e["points"]?.array ?? []).filter { !jsStr($0["name"]).isEmpty }
        let points = pts.map { jsStr($0["name"]) }
        let kinds = Set(pts.map { p -> String in
            let full = jsStr(p["full"])
            guard let dot = full.firstIndex(of: "·") else { return "" }
            return String(full[..<dot])
        })
        let kind = kinds.count == 1 ? (kinds.first ?? "") : ""
        return (EssenceAdvice(weapon: jsStr(e["weapon"]), terms: terms, points: points, pointKind: kind, engrave: jsStr(e["engrave"]),
                              maaend: jsStr(e["maaend"]), dataVersion: jsStr(e["dataVersion"]), reason: reason), reason)
    }

    /// The next six-star: coverage.next when the table says, else its `role: "next"` standard; nil for older tables.
    nonisolated static func nextStandard(_ ng: JSONValue?) -> NextStandard? {
        if let n = ng?["coverage"]?["next"], n.object != nil, !jsStr(n["name"]).isEmpty {
            return NextStandard(name: jsStr(n["name"]), releasedAt: jsStr(n["releasedAt"]), status: strOrNil(n["status"]),
                                weapon: strOrNil(n["weapon"]))
        }
        guard let s = (ng?["standards"]?.array ?? []).first(where: { jsStr($0["role"]) == "next" }),
              !jsStr(s["name"]).isEmpty else { return nil }
        return NextStandard(name: jsStr(s["name"]), releasedAt: jsStr(s["releasedAt"]), status: strOrNil(s["status"]),
                            weapon: strOrNil(s["weapon"]?["name"]))
    }

    /// inventory.js chosenStandard(gameId): the charId picked on this phone, "" for the file's default.
    func chosenStandard(_ gameId: String = InventoryStore.gameIdEndfield) -> String {
        UserDefaults.standard.string(forKey: Self.standardKey + ":" + gameId) ?? ""
    }

    /// inventory.js setStandard(charId, gameId): "" goes back to the file's default. Rows are
    /// recomputed on the next refresh(force: true).
    func setStandard(_ charId: String, _ gameId: String = InventoryStore.gameIdEndfield) {
        if charId.isEmpty { UserDefaults.standard.removeObject(forKey: Self.standardKey + ":" + gameId) }
        else { UserDefaults.standard.set(charId, forKey: Self.standardKey + ":" + gameId) }
    }

    /// inventory.js standardFor(g): the chosen standard if the file still has it, else the file's default, else the first.
    func standardFor(_ g: JSONValue?) -> JSONValue? {
        let list = g?["standards"]?.array ?? []
        let want = chosenStandard(jsStr(g?["gameId"]))
        let def = jsStr(g?["standard"])
        return list.first { Self.standardKey($0) == want } ?? list.first { Self.standardKey($0) == def } ?? list.first
    }

    // MARK: material-list cache

    func matFromStore() -> (at: Double, list: [String: MaterialInfo])? {
        guard let raw = UserDefaults.standard.string(forKey: Self.matKey), let c = try? JSONValue.parse(raw),
              let at = c["at"]?.number, let l = c["list"],
              let list = try? JSONDecoder().decode([String: MaterialInfo].self, from: l.encoded()) else { return nil }
        return (at, list)
    }

    func matToStore(_ list: [String: MaterialInfo]) {
        guard let l = try? JSONValue.parse(JSONEncoder().encode(list)) else { return }
        UserDefaults.standard.set(JSONValue.object(["at": .double(nowMs()), "list": l]).encodedString(), forKey: Self.matKey)
    }

    /// inventory.js materialList(sk, ts, force): cached for seven days unless forced.
    func materialList(_ sk: JSONValue, _ ts: SkTokenSkew, force: Bool = false) async throws -> [String: MaterialInfo] {
        if !force, let c = matFromStore(), nowMs() - c.at < Self.matMaxAgeMs { return c.list }
        let list = InventoryCalc.flattenMaterials(try await stamina.skGet(sk, ts, Self.zonaiMaterials))
        matToStore(list)
        return list
    }

    // MARK: one game

    /// The need-table half of the 终末地 game for the standard in force (standardFor): who the build is for, how the page
    /// words it, and the rows of that standard. Since 2026-10-15 a standard carries its own `groups` / `useSource` (明河's
    /// groups are per owner, 「明河」 / 「专武 唤月」, so the game-level list, a mirror of the first standard, would sort her
    /// sections wrong); a table without them falls back to the game's.
    func shell() -> (game: InventoryGame, needRows: [JSONValue], needGame: JSONValue?) {
        var g = InventoryGame(game: Self.gameName, gameId: Self.gameIdEndfield)
        let needGame = needFor(Self.gameIdEndfield)
        let std = standardFor(needGame)
        if let ng = needGame {
            g.caliber = strOrNil(std?["caliber"]).flatMap { $0.isEmpty ? nil : $0 } ?? strOrNil(ng["caliber"])
            g.footnote = strOrNil(std?["footnote"]).flatMap { $0.isEmpty ? nil : $0 } ?? (strOrNil(ng["footnote"]) ?? "")
            g.source = strOrNil(ng["source"])
            g.built = strOrNil(need?["built"])
            g.sections = strings(ng["sections"])
            // absent (a table before 2026-10-15) falls back to the game's list; present stays the standard's own
            g.groups = std?["groups"]?.array != nil ? strings(std?["groups"]) : strings(ng["groups"])
            g.useSource = (std?["useSource"].flatMap { $0.isNull ? nil : $0.jsString }) ?? (strOrNil(ng["useSource"]) ?? "")
            g.originSource = strOrNil(ng["originSource"]) ?? ""
            g.lagMinutes = intOrNil(ng["lagMinutes"])
            g.lagNote = strOrNil(ng["lagNote"]) ?? ""
            if let s = std {
                let e = Self.essence(s["weapon"]?["essence"])
                g.standard = InventoryStandard(charId: strOrNil(s["charId"]), name: strOrNil(s["name"]), rarity: intOrNil(s["rarity"]),
                                               releasedAt: strOrNil(s["releasedAt"]), status: strOrNil(s["status"]),
                                               weapon: strOrNil(s["weapon"]?["name"]), sources: nonNull(s["sources"]),
                                               key: Self.standardKey(s), role: strOrNil(s["role"]), label: strOrNil(s["label"]),
                                               essence: e.advice, essenceReason: e.reason)
            }
            g.standards = standards(Self.gameIdEndfield)
            g.next = Self.nextStandard(ng)
            g.nextError = strOrNil(ng["coverage"]?["nextError"]) ?? ""
        }
        return (g, (std ?? needGame)?["rows"]?.array ?? [], needGame)
    }

    /// The rows of `g`'s standard from one read's counts (rowsFor + the self-select box).
    private static func fill(_ g: inout InventoryGame, _ needRows: [JSONValue], _ needGame: JSONValue?, _ h: HeldRead) {
        var rows = InventoryCalc.rowsFor(needRows, h.counts, h.mat)
        g.box = InventoryCalc.box(needGame?["box"])
        g.boxUse = InventoryCalc.applyBox(&rows, g.box)
        g.rows = rows
        g.gameLevel = h.gameLevel
    }

    /// What the last good read of 森空岛 answered, so the page's picker can show another standard without asking again.
    struct HeldRead {
        var counts: [String: JSONValue]
        var mat: [String: MaterialInfo]
        var gameLevel: JSONValue?
    }
    @ObservationIgnored private(set) var held: HeldRead?

    /// The 库存 page's picker: `data` worked out again for the standard picked now (setStandard), from the counts of the
    /// last read - no request, so switching between 祀 and 明河 is at once and does not ask 森空岛 twice. nil when there is
    /// no good read to reuse (the page then reads again).
    func repick() -> InventoryReading? {
        guard var d = data, let h = held, need != nil, let first = d.games.first, first.error.isEmpty,
              first.gameId == Self.gameIdEndfield else { return nil }
        let sh = shell()
        var g = sh.game
        Self.fill(&g, sh.needRows, sh.needGame, h)
        d.games[0] = g
        data = d
        return d
    }

    /// inventory.js endfield(sk).
    func endfield(_ sk: JSONValue) async -> InventoryGame {
        let sh = shell()
        var g = sh.game
        let needRows = sh.needRows, needGame = sh.needGame
        do {
            let efRole = jsStr(sk["efRole"])
            if efRole.isEmpty { throw AppError("密钥串里没有终末地的角色") }
            let server = jsStr(sk["efServer"]).isEmpty ? "1" : jsStr(sk["efServer"])
            let ts = try await stamina.skRefresh(sk)
            let d = try await stamina.skGet(sk, ts, "\(Self.zonaiInventory)?roleId=\(encodeURIComponent(efRole))&serverId=\(encodeURIComponent(server))")
            let ugd = d["userGameData"]
            let counts = ugd?["itemCount"]?.object ?? [:]
            if counts.isEmpty {
                let src = (ugd?.truthy ?? false) ? ugd : d
                let keys = (src?.object.map { Array($0.keys) } ?? []).prefix(6)
                throw AppError("森空岛没给终末地的仓库：" + keys.joined(separator: "、"))
            }
            var mat = try await materialList(sk, ts)
            let known = Set(needRows.map { jsStr($0["id"]) })
            if counts.keys.contains(where: { !known.contains($0) && mat[$0] == nil }) {
                mat = try await materialList(sk, ts, force: true)
            }
            let h = HeldRead(counts: counts, mat: mat, gameLevel: nonNull(ugd?["gameLevel"]))
            held = h
            Self.fill(&g, needRows, needGame, h)
        } catch {
            held = nil
            g.error = errorMessage(error)
        }
        return g
    }

    // MARK: entry

    /// inventory.js refresh(force): one read; `force` skips the one-minute reuse.
    @discardableResult
    func refresh(force: Bool = false) async -> InventoryReading? {
        let t = stamina.tokens ?? stamina.loadTokens()
        if !force, let d = data, nowMs() - at < Self.minGapMs { return d }
        if busy { return data }
        busy = true
        defer { busy = false }
        var out = InventoryReading(takenAt: clockHHMM(ms: nowMs()), games: [])
        err = ""
        do { try await loadNeed(force: force) } catch { err = errorMessage(error) }
        if let sk = t?["sk"], sk.truthy {
            // no usable need table: the rows would carry no group and the page would blame 森空岛
            if need == nil { out.games.append(Self.needMissing(err)) }
            else if let gap = needGap() { out.games.append(Self.needLacks(gap)) }
            else { out.games.append(await endfield(sk)) }
        } else {
            out.games.append(InventoryGame(game: Self.gameName, gameId: Self.gameIdEndfield, error: "没配森空岛"))
        }
        data = out
        at = nowMs()
        return out
    }

    /// The game shown when no need table could be read (neither copy) and none is held from an earlier read: says the
    /// table is what is missing, not 森空岛 (森空岛 is not asked, since nothing could be worked out from its answer).
    static func needMissing(_ err: String) -> InventoryGame {
        InventoryGame(game: gameName, gameId: gameIdEndfield,
                      error: "这次是需求表没拿到（不是森空岛回报的），算不出人份：" + (err.isEmpty ? "原因不明" : err))
    }

    /// What the held need table lacks for 终末地, nil when it has the game and its rows.
    func needGap() -> String? {
        guard let ng = needFor(Self.gameIdEndfield) else { return "需求表拿到了，但里面没有终末地这一项" }
        let rows = (standardFor(ng) ?? ng)["rows"]?.array ?? []
        return rows.isEmpty ? "需求表里终末地这一项没有材料" : nil
    }

    /// The game shown when the need table is held but lacks 终末地 or its rows (森空岛 is not asked).
    static func needLacks(_ gap: String) -> InventoryGame {
        InventoryGame(game: gameName, gameId: gameIdEndfield, error: gap + "（不是森空岛回报的），算不出人份")
    }

    /// inventory.js status(): "森空岛" when a 森空岛 session is stored, else "".
    func status() -> String {
        let t = stamina.tokens ?? stamina.loadTokens()
        return (t?["sk"]?.truthy ?? false) ? "森空岛" : ""
    }
}
