// Ported from maa-automation/web/schema.js
//
// The field table and option lists: where each setting is read from in the snapshot (sec/key or
// master path) and where it is written (set_config script/path or set_master game/path), the
// Chinese value names, the 鸣潮 index tables, the yield notes, and the relay's own switches.
//
// Not ported: SET_ICONS (eight base64 PNG icons of the 声骸 sets, about 50 KB). They are images
// for the page; the page step adds them as asset files. `TacetChoice.names` keeps the set names
// they are keyed by.

import Foundation

/// Value → Chinese. Sources are in the repo: Fixed = 固定 from plan.py's schedule wording;
/// 剿灭 Close means "done this week" or "switched off by hand" (docs/CONFIG.md).
let valueZh: [String: [String: String]] = [
    "Info.StageMode": ["Fixed": "固定关卡"],
    "Info.Annihilation": ["Close": "关闭 / 本周已完成"],
    "Info.SeriesNumb": ["0": "0（不指定，用游戏里的设置）"],
]

/// One labelled option: what the page shows and the value written back.
struct Choice: Sendable, Equatable {
    let label: String
    let value: JSONValue
}

/// A 无音区 entry: the two 声骸 sets it drops (the page draws their icons) and the index OK-WW stores.
struct TacetChoice: Sendable, Equatable {
    let names: [String]
    let value: Int
}

/// 无音区 index = position in the F2 「素材获取 → 无音清剿」 list, checked set by set in game
/// (docs/WUWA-TACET-INDEX.md). Every tacet field drops exactly two sets.
/// Wuthering Waves 3.7 (2026-09-30) put 沉心域 / 烬心域 at the top and moved every older index down by 2;
/// copied row for row from relay/ark_relay/wuwa_tacet.py TACET (web schema.js TACET, 05499e9e).
let tacet: [TacetChoice] = [
    TacetChoice(names: ["衔梦照世之心", "茜染怀想之花"], value: 1),
    TacetChoice(names: ["衔梦照世之心", "镜影流电之瞬"], value: 2),
    TacetChoice(names: ["羽落空尘之歌", "冥途夜行之灯"], value: 3),
    TacetChoice(names: ["羽落空尘之歌", "清邪荡煞之心"], value: 4),
    TacetChoice(names: ["雪落无声之愿", "剪心辑梦之影"], value: 5),
    TacetChoice(names: ["听唤语义之愿", "长路启航之星"], value: 6),
    TacetChoice(names: ["长路启航之星", "斑驳粉饰之沫"], value: 7),
]

/// 讨伐强敌 list position → boss name; source relay/ark_relay/wuwa_boss.py, pinned by
/// relay/tests/test_boss_table_matches.py (the state packet has no room for it).
let bosses: [(index: Int, name: String)] = [
    (1, "天傀劫煞"),
    (2, "万囿牢·朽躯"),
    (3, "梦魇亚当·重锤"),
    (4, "无铭探索者"),
]

/// 凝素领域 index (梦州 group; full table in docs/WUWA-TACET-INDEX.md).
let forge: [Choice] = [
    Choice(label: "1 · 迅刀（陨翼云渊）", value: .int(1)),
    Choice(label: "2 · 音感仪（静灭云渊）", value: .int(2)),
    Choice(label: "3 · 长刃（裂斩云渊）", value: .int(3)),
    Choice(label: "4 · 臂铠（碎蚀云渊）", value: .int(4)),
    Choice(label: "5 · 佩枪（沉熄云渊）", value: .int(5)),
]

/// Fixed option lists by path; the pending list names the change, so 无音区 gives the set names here.
let choices: [String: [Choice]] = [
    "DailyTask.json/Which Tacet Suppression to Farm":
        tacet.map { Choice(label: $0.names.joined(separator: " ＋ "), value: .int($0.value)) },
    "DailyTask.json/Which Forgery Challenge to Farm": forge,
]

/// What an option farms (user 09-25 15:19). Sources: docs/ENDFIELD-SANITY-YIELD.md 36-47,
/// AUTO-MAS constants.py. Labels that already carry a bracket are left alone.
let yields: [String: [String: String]] = [
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

/// schema.js yieldLabel(path, lb, v): the option label with its yield appended.
func yieldLabel(_ path: String, _ label: String, _ value: JSONValue) -> String {
    guard let y = yields[path]?[value.jsString] else { return label }
    return label.contains("（") ? label : "\(label)（\(y)）"
}

/// One setting row. `type`: text / number / bool / select / pills / icons, or nil when the
/// machine's option tree supplies it (`tree` sections).
struct SchemaField: Sendable {
    var key: String? = nil
    let path: String
    var type: String? = nil
    var label: String? = nil
    /// Overrides the script's own name in the confirm list.
    var name: String? = nil
    var choices: [Choice]? = nil
    var tacet: [TacetChoice]? = nil
    var ro: Bool = false
    let hint: String
}

/// One settings card. src "mas" → value at snap.config[sec][key], written with set_config(script, path);
/// src "master" → value at snap.master[game].values[path], written with set_master(game, path).
struct SchemaSection: Sendable {
    let title: String
    let owner: String
    let src: String
    var script: String? = nil
    var sec: String? = nil
    var game: String? = nil
    /// The machine sends this task's whole option tree (view.js treeFields); the fields below only add text.
    var tree: String? = nil
    let fields: [SchemaField]
}

/// Which settings the page shows (2026-09-03 rules): nothing that does not take effect, nothing
/// that never needs changing.
let schema: [SchemaSection] = [
    SchemaSection(title: "明日方舟", owner: "MAA", src: "mas", script: "MAA", sec: "MAA", fields: [
        SchemaField(key: "关卡", path: "Info.Stage", type: "text",
                    hint: "游戏内的关卡号。例如 1-7（常规）、CE-6（龙门币）、AT-4（活动关）"),
        SchemaField(key: "理智药", path: "Info.MedicineNumb", type: "number",
                    hint: "一趟最多使用几瓶理智药。0＝不使用；999＝不限量"),
        SchemaField(key: "作战开关", path: "Task.IfFight", type: "bool",
                    hint: "关掉后不刷关卡，只做基建、公招等日常"),
        SchemaField(key: "活动关优先", path: "Task.IfActivityFirst", type: "bool",
                    hint: "开着＝有活动就刷活动关，活动结束后自动回到上面那个固定关。开着时下面的序号才生效"),
        SchemaField(key: "活动关序号", path: "Task.ActivityStageIndex", type: "number",
                    hint: "刷活动里的第几关，数的是活动关卡列表从上往下的位置，第一关填 1。只在上面那项开着时才有用"),
    ]),
    SchemaSection(title: "明日方舟 · 基建", owner: "MAA", src: "master", game: "MAA", fields: [
        SchemaField(path: "Infrast/UsesOfDrones", type: "select", label: "无人机用在哪",
                    hint: "贸易站＝加速龙门币或合成玉订单，制造站＝加速对应产物"),
    ]),
    SchemaSection(title: "明日方舟 · 领取奖励", owner: "MAA", src: "master", game: "MAA", fields: [
        SchemaField(path: "Award/Mail", type: "bool", label: "领取所有邮件奖励",
                    hint: "开着＝每趟顺手把邮箱里的奖励全收了。关着邮件会一直躺着，到期作废"),
        SchemaField(path: "Award/Orundum", type: "bool", label: "领取幸运墙的每日合成玉",
                    hint: "开着＝每天去幸运墙领那份合成玉"),
        SchemaField(path: "Award/Mining", type: "bool", label: "领取限时开采许可的合成玉",
                    hint: "开着＝有限时开采许可时每天领它的合成玉"),
        SchemaField(path: "Award/SpecialAccess", type: "bool", label: "领取周年赠送月卡",
                    hint: "开着＝周年送的月卡每天的那份也领"),
    ]),
    SchemaSection(title: "终末地 · 基质刷取", owner: "MaaEnd", src: "master", game: "MaaEnd", tree: "AutoEssence", fields: [
        SchemaField(path: "AutoEssence/@enabled", type: "bool", label: "跑这个任务",
                    hint: "关掉后不再刷基质。下面的协议空间也开着时，协议空间先花理智，剩下的才刷基质"),
        SchemaField(path: "AutoEssence/AutoEssenceMenu",
                    hint: "三种都是刷基质。随机模式＝从勾选的地区里随机挑；地区模式＝固定一个地区并指定词条；目标选择＝按想要的武器找基质"),
        SchemaField(path: "AutoEssence/AutoEssenceDoOverride", type: "bool",
                    hint: "使用刻写券定向刷取词条。需事先在淤积点开始界面选定要刻写的属性；券不足时改为不刻写领取"),
        SchemaField(path: "AutoEssence/AutoEssenceObtainMode", type: "select",
                    hint: "每轮打完的结算方式。单倍＝一份理智一张券；双倍＝双倍理智两张券，奖励翻倍；不领取＝只刷素材"),
        SchemaField(path: "AutoEssence/AutoEssenceRepeatCount", type: "number",
                    hint: "一趟最多执行的轮数。单倍每轮 80 理智，双倍 160"),
        SchemaField(path: "AutoEssence/AutoEssenceChooseLocation", type: "pills",
                    hint: "从勾选的地区里随机挑一个。藏剑谷与清波寨成功率较高，试验园区较低"),
        SchemaField(path: "AutoEssence/EssenceFilterAfterBattle", type: "bool",
                    hint: "每轮结束后立即筛选并锁定符合条件的基质"),
        SchemaField(path: "AutoEssence/AutoUseSpMedication", type: "select",
                    hint: "刷基质时理智用完了怎么办：结束任务，或者吃应急理智加强剂接着刷"),
        SchemaField(path: "AutoEssence/AutoEssenceSpMedicationExpireWithinDays", type: "select",
                    hint: "只吃几天内会过期的加强剂。选「全部」则不看剩余天数；「3 天内」会把同一批到期的药攒到最后三天一起吃掉"),
    ]),
    SchemaSection(title: "终末地 · 协议空间", owner: "MaaEnd", src: "master", game: "MaaEnd", tree: "ProtocolSpace", fields: [
        SchemaField(path: "ProtocolSpace/@enabled", type: "bool", label: "跑这个任务",
                    hint: "刷折金票、干员养成、武器养成、危境预演都在这里。和上面的基质刷取都开着时，协议空间先花理智，剩下的才刷基质；只想刷这个就把基质那栏关掉"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceSchedule", type: "pills",
                    hint: "只在勾选的星期执行，按游戏里的星期算。没勾的日子这个任务会立即结束"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceMode", type: "select",
                    hint: "按次数刷取＝按下面选的那一类刷；目标库存＝刷到下面「培养道具目标」每一格的数为止"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceTab", type: "select",
                    hint: "刷哪一类。干员养成＝干员经验（作战记录 / 认知载体）、干员进阶（协议圆盘）、钱币收集（折金票）、技能提升（协议棱柱）；武器养成＝武器经验（武器检查套组 / 装置）、武器进阶（强固模具）；危境预演＝高阶培养Ⅰ–Ⅴ（D96钢样品四、超距辉映管、快子遴捡晶格、象限拟合液、三相纳米片）。选了哪类，下面就只出现那一类的选项"),
        SchemaField(path: "ProtocolSpace/OperatorProgression", type: "select",
                    hint: "刷折金票选「钱币收集（折金票）」"),
        SchemaField(path: "ProtocolSpace/WeaponProgression", type: "select",
                    hint: "武器经验，或者武器进阶的材料"),
        SchemaField(path: "ProtocolSpace/CrisisDrills", type: "select",
                    hint: "括号里是这一档的材料"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceLevel", type: "select",
                    hint: "打几级的协议空间"),
        SchemaField(path: "ProtocolSpace/OperatorEXPRewardsSetOption", type: "select", name: "干员经验 · 可选奖励组",
                    hint: "领奖励时拿 A 组还是 B 组"),
        SchemaField(path: "ProtocolSpace/PromotionsRewardsSetOption", type: "select", name: "干员进阶 · 可选奖励组",
                    hint: "领奖励时拿 A 组还是 B 组"),
        SchemaField(path: "ProtocolSpace/SkillUpRewardsSetOption", type: "select", name: "技能提升 · 可选奖励组",
                    hint: "领奖励时拿 A 组还是 B 组"),
        SchemaField(path: "ProtocolSpace/WeaponTuneRewardsSetOption", type: "select", name: "武器进阶 · 可选奖励组",
                    hint: "领奖励时拿 A 组还是 B 组"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceObtainMode", type: "select",
                    hint: "每次打完怎么领奖励：双倍领取、单倍领取，或者不领取"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceSuccessCount", type: "select",
                    hint: "打成功几次就收工。无限制＝一直打到理智用完"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceUseSpMedication", type: "select",
                    hint: "理智不够了怎么办：结束任务，或者吃应急理智加强剂接着刷"),
        SchemaField(path: "ProtocolSpace/ProtocolSpaceFailedCount", type: "select",
                    hint: "打输几次就收工"),
        SchemaField(path: "ProtocolSpace/SupplyPlanLimits",
                    hint: "每种材料攒到多少就不再刷，只填数字"),
    ]),
    SchemaSection(title: "终末地 · 另外两个任务", owner: "MaaEnd", src: "master", game: "MaaEnd", fields: [
        SchemaField(path: "AutoCollect/@enabled", type: "bool",
                    hint: "按下面的线路和周期自动采集材料"),
        SchemaField(path: "AutoCollect/AutoCollectSchedule", type: "pills",
                    hint: "只在勾选的星期执行。没勾的日子这个任务会立即结束"),
        SchemaField(path: "AutoCollect/AutoCollectMode", type: "select",
                    hint: "按勾选路线＝下面勾上的都去采；按目标库存＝只采背包里还没攒够的"),
        SchemaField(path: "AutoCollect/AutoCollectValleyIV", type: "bool", label: "四号谷地",
                    hint: "关掉后四号谷地的路线一条都不采"),
        SchemaField(path: "AutoCollect/AutoCollectValleyIVRareRoutes", type: "pills", label: "四号谷地 · 稀有采集物",
                    hint: "勾上的路线才会去采"),
        SchemaField(path: "AutoCollect/AutoCollectValleyIVCommonRoutes", type: "pills", label: "四号谷地 · 一般采集物",
                    hint: "勾上的路线才会去采"),
        SchemaField(path: "AutoCollect/AutoCollectWuling", type: "bool", label: "武陵",
                    hint: "关掉后武陵的路线一条都不采"),
        SchemaField(path: "AutoCollect/AutoCollectWulingRareRoutes", type: "pills", label: "武陵 · 稀有采集物",
                    hint: "勾上的路线才会去采"),
        SchemaField(path: "AutoCollect/AutoCollectWulingCommonRoutes", type: "pills", label: "武陵 · 一般采集物",
                    hint: "勾上的路线才会去采"),
    ]),
    SchemaSection(title: "鸣潮", owner: "OK-WW", src: "master", game: "OK-WW", fields: [
        SchemaField(path: "DailyTask.json/Which to Farm", type: "text", label: "体力刷什么",
                    hint: "每天的体力花在哪"),
        SchemaField(path: "DailyTask.json/Material Selection", type: "text", label: "刷哪种材料",
                    hint: "只在上面选「模拟领域」时才有用"),
        SchemaField(path: "DailyTask.json/Which Forgery Challenge to Farm", type: "select", label: "凝素领域打哪个", choices: forge,
                    hint: "按想要的武器材料挑。只在上面选「凝素领域」时才有用"),
        SchemaField(path: "DailyTask.json/Which Tacet Suppression to Farm", type: "icons", label: "无音区打哪个", tacet: tacet,
                    hint: "按想要的声骸套装挑。只在上面选「无音区」时才有用"),
        SchemaField(path: "NightmareNestTask.json/Only Farm These Nests", type: "text", label: "残象聚落点位", ro: true,
                    hint: "只刷落渊南丘，这是定好的。要换点位在电脑上改"),
    ]),
]

/// A relay switch (not in any config file): drawn like a setting row, with the same sent / acked receipt.
struct RelaySwitch: Sendable {
    let id: String
    let key: String
    let tab: String
    let label: String
    let hint: String
    let on: JSONValue
    let off: JSONValue
    var hintOn: (@Sendable (String) -> String)? = nil
}

let relaySwitches: [RelaySwitch] = [
    RelaySwitch(id: "relay|skip_shutdown", key: "下次别关机", tab: "状态", label: "下次跑完不关机",
                hint: "只跳过下一次关机，再下一趟照常关",
                on: .object(["action": .string("skip_shutdown")]),
                off: .object(["action": .string("skip_shutdown"), "off": .bool(true)])),
    RelaySwitch(id: "relay|debug_mode", key: "调试模式", tab: "状态", label: "调试模式",
                hint: "开着的 90 分钟里跑完不关机，到点自动关掉",
                on: .object(["action": .string("debug_mode"), "minutes": .int(90), "confirmed": .bool(true)]),
                off: .object(["action": .string("debug_mode"), "off": .bool(true), "confirmed": .bool(true)]),
                hintOn: { v in "开着，到 \(v)——这期间跑完不关机" }),
    RelaySwitch(id: "relay|tacet_shots", key: "无音区截图", tab: "OK-WW", label: "无音区结算截图",
                hint: "开着：日报后面带上无音区打完的两张结算图",
                on: .object(["action": .string("tacet_shots"), "on": .bool(true)]),
                off: .object(["action": .string("tacet_shots"), "on": .bool(false)])),
]
