import Foundation

/// Data for the 方舟 (Arknights) tab; filled from the relay snapshot by ArknightsBridge.
///
/// Mirrors the web remote: the tab shows every section whose title starts with
/// 明日方舟 (maa-automation/web/view.js:753). Field names follow the paths in
/// web/schema.js:116-141 and the weekly block in web/view.js:510-523.
/// A nil field means the machine did not report it; the web skips such rows
/// (view.js:459 "机器上没有这一项就别画"), and so does this page.
struct ArknightsPageData: Equatable {
    // Section 明日方舟 — src "mas", script "MAA", sec "MAA" (schema.js:116-127)
    /// Info.Stage — stage code, e.g. 1-7, CE-6, AT-4
    var stage: String?
    /// Info.MedicineNumb — sanity potions per run; 0 = none, 999 = unlimited
    var medicineNumb: Int?
    /// Task.IfFight
    var ifFight: Bool?
    /// Task.IfActivityFirst
    var ifActivityFirst: Bool?
    /// Task.ActivityStageIndex — 1-based position in the event stage list
    var activityStageIndex: Int?

    // Section 明日方舟 · 基建 — src "master", game "MAA" (schema.js:128-131)
    /// Infrast/UsesOfDrones — the selected option value
    var usesOfDrones: String?
    /// Options for Infrast/UsesOfDrones; sent by the machine (snap.master.MAA.options), not in schema.js
    var usesOfDronesOptions: [ArknightsOption] = []

    // Section 明日方舟 · 领取奖励 — src "master", game "MAA" (schema.js:132-141)
    /// Award/Mail
    var awardMail: Bool?
    /// Award/Orundum
    var awardOrundum: Bool?
    /// Award/Mining
    var awardMining: Bool?
    /// Award/SpecialAccess
    var awardSpecialAccess: Bool?

    /// The MAA master config could not be read and there is no earlier copy (view.js:415-419).
    /// When true the two master sections show a warning instead of rows.
    var masterUnreadable: Bool = false

    // Section 明日方舟 · 周常 — relay["周常"]["剿灭"]["本周已完成"] (view.js:510-523)
    /// This week's Annihilation is maxed out. nil = MAA not in this shift, section hidden.
    var annihilationDoneThisWeek: Bool?
}

/// One choice of a select field: the label shown and the value written back.
struct ArknightsOption: Hashable, Identifiable {
    var label: String
    var value: String
    var id: String { value }
}

extension ArknightsPageData {
    /// Sample values, copied from the web demo data (view.js:2356 DEMO_MASTER); the
    /// mas fields use the stage example from schema.js:118.
    static let sample = ArknightsPageData(
        stage: "1-7",
        medicineNumb: 0,
        ifFight: true,
        ifActivityFirst: false,
        activityStageIndex: 1,
        usesOfDrones: "Money",
        usesOfDronesOptions: [
            ArknightsOption(label: "贸易站 · 龙门币", value: "Money"),
            ArknightsOption(label: "贸易站 · 合成玉", value: "SyntheticJade"),
            ArknightsOption(label: "制造站 · 作战记录", value: "CombatRecord"),
            ArknightsOption(label: "制造站 · 赤金", value: "PureGold"),
            ArknightsOption(label: "制造站 · 源石碎片", value: "OriginStone"),
            ArknightsOption(label: "制造站 · 芯片", value: "Chip"),
        ],
        awardMail: true,
        awardOrundum: false,
        awardMining: true,
        awardSpecialAccess: false,
        annihilationDoneThisWeek: false
    )
}
