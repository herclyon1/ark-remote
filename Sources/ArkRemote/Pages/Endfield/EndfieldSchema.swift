// The three 终末地 cards, copied from maa-automation/web/schema.js:143-218 (titles, paths, names, types, hints verbatim).
// 基质刷取 and 协议空间 are tree groups: the machine sends the whole option tree, these entries only add hint / name / type.

enum EndfieldSchema {
    static let essence = EWGroupSpec(title: "终末地 · 基质刷取", tree: "AutoEssence", fields: [
        EWFieldSpec(path: "AutoEssence/@enabled", type: .bool, label: "跑这个任务",
                    hint: "关掉后不再刷基质。下面的协议空间也开着时，协议空间先花理智，剩下的才刷基质"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceMenu",
                    hint: "三种都是刷基质。随机模式＝从勾选的地区里随机挑；地区模式＝固定一个地区并指定词条；目标选择＝按想要的武器找基质"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceDoOverride", type: .bool,
                    hint: "使用刻写券定向刷取词条。需事先在淤积点开始界面选定要刻写的属性；券不足时改为不刻写领取"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceObtainMode", type: .select,
                    hint: "每轮打完的结算方式。单倍＝一份理智一张券；双倍＝双倍理智两张券，奖励翻倍；不领取＝只刷素材"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceRepeatCount", type: .number,
                    hint: "一趟最多执行的轮数。单倍每轮 80 理智，双倍 160"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceChooseLocation", type: .pills,
                    hint: "从勾选的地区里随机挑一个。藏剑谷与清波寨成功率较高，试验园区较低"),
        EWFieldSpec(path: "AutoEssence/EssenceFilterAfterBattle", type: .bool,
                    hint: "每轮结束后立即筛选并锁定符合条件的基质"),
        EWFieldSpec(path: "AutoEssence/AutoUseSpMedication", type: .select,
                    hint: "刷基质时理智用完了怎么办：结束任务，或者吃应急理智加强剂接着刷"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceSpMedicationExpireWithinDays", type: .select,
                    hint: "只吃几天内会过期的加强剂。选「全部」则不看剩余天数；「3 天内」会把同一批到期的药攒到最后三天一起吃掉"),
    ])

    static let protocolSpace = EWGroupSpec(title: "终末地 · 协议空间", tree: "ProtocolSpace", fields: [
        EWFieldSpec(path: "ProtocolSpace/@enabled", type: .bool, label: "跑这个任务",
                    hint: "刷折金票、干员养成、武器养成、危境预演都在这里。和上面的基质刷取都开着时，协议空间先花理智，剩下的才刷基质；只想刷这个就把基质那栏关掉"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceSchedule", type: .pills,
                    hint: "只在勾选的星期执行，按游戏里的星期算。没勾的日子这个任务会立即结束"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceMode", type: .select,
                    hint: "按次数刷取＝按下面选的那一类刷；目标库存＝刷到下面「培养道具目标」每一格的数为止"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceTab", type: .select,
                    hint: "刷哪一类。干员养成＝干员经验（作战记录 / 认知载体）、干员进阶（协议圆盘）、钱币收集（折金票）、技能提升（协议棱柱）；武器养成＝武器经验（武器检查套组 / 装置）、武器进阶（强固模具）；危境预演＝高阶培养Ⅰ–Ⅴ（D96钢样品四、超距辉映管、快子遴捡晶格、象限拟合液、三相纳米片）。选了哪类，下面就只出现那一类的选项"),
        EWFieldSpec(path: "ProtocolSpace/OperatorProgression", type: .select,
                    hint: "刷折金票选「钱币收集（折金票）」"),
        EWFieldSpec(path: "ProtocolSpace/WeaponProgression", type: .select,
                    hint: "武器经验，或者武器进阶的材料"),
        EWFieldSpec(path: "ProtocolSpace/CrisisDrills", type: .select,
                    hint: "括号里是这一档的材料"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceLevel", type: .select,
                    hint: "打几级的协议空间"),
        // The four A/B are all 「可选奖励组」 in MaaEnd, so our own name wins (schema.js:183).
        EWFieldSpec(path: "ProtocolSpace/OperatorEXPRewardsSetOption", type: .select, name: "干员经验 · 可选奖励组", hint: "领奖励时拿 A 组还是 B 组"),
        EWFieldSpec(path: "ProtocolSpace/PromotionsRewardsSetOption", type: .select, name: "干员进阶 · 可选奖励组", hint: "领奖励时拿 A 组还是 B 组"),
        EWFieldSpec(path: "ProtocolSpace/SkillUpRewardsSetOption", type: .select, name: "技能提升 · 可选奖励组", hint: "领奖励时拿 A 组还是 B 组"),
        EWFieldSpec(path: "ProtocolSpace/WeaponTuneRewardsSetOption", type: .select, name: "武器进阶 · 可选奖励组", hint: "领奖励时拿 A 组还是 B 组"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceObtainMode", type: .select,
                    hint: "每次打完怎么领奖励：双倍领取、单倍领取，或者不领取"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceSuccessCount", type: .select,
                    hint: "打成功几次就收工。无限制＝一直打到理智用完"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceUseSpMedication", type: .select,
                    hint: "理智不够了怎么办：结束任务，或者吃应急理智加强剂接着刷"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceFailedCount", type: .select,
                    hint: "打输几次就收工"),
        EWFieldSpec(path: "ProtocolSpace/SupplyPlanLimits",
                    hint: "每种材料攒到多少就不再刷，只填数字"),
    ])

    static let otherTasks = EWGroupSpec(title: "终末地 · 另外两个任务", fields: [
        EWFieldSpec(path: "AutoCollect/@enabled", type: .bool,
                    hint: "按下面的线路和周期自动采集材料"),
        EWFieldSpec(path: "AutoCollect/AutoCollectSchedule", type: .pills,
                    hint: "只在勾选的星期执行。没勾的日子这个任务会立即结束"),
        EWFieldSpec(path: "AutoCollect/AutoCollectMode", type: .select,
                    hint: "按勾选路线＝下面勾上的都去采；按目标库存＝只采背包里还没攒够的"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIV", type: .bool, label: "四号谷地",
                    hint: "关掉后四号谷地的路线一条都不采"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIVRareRoutes", type: .pills, label: "四号谷地 · 稀有采集物",
                    hint: "勾上的路线才会去采"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIVCommonRoutes", type: .pills, label: "四号谷地 · 一般采集物",
                    hint: "勾上的路线才会去采"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWuling", type: .bool, label: "武陵",
                    hint: "关掉后武陵的路线一条都不采"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWulingRareRoutes", type: .pills, label: "武陵 · 稀有采集物",
                    hint: "勾上的路线才会去采"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWulingCommonRoutes", type: .pills, label: "武陵 · 一般采集物",
                    hint: "勾上的路线才会去采"),
    ])

    /// The rows a card keeps on the 终末地 page itself: the task's switch and its current mode, most-changed first
    /// (hig-kit/HIG-CHECKLIST.maa.md:55 progressive disclosure, :59 order by importance). Every other row of the card,
    /// including the ones a mode opens (ProtocolSpaceTab → OperatorProgression …), is one level down under 「更多设置」.
    /// Filters the rows ewRows draws, not `fields`: tree cards draw the machine's tree (EWModel.swift ewRows).
    static let firstLevel: Set<String> = [
        "AutoEssence/@enabled", "AutoEssence/AutoEssenceMenu",
        "ProtocolSpace/@enabled", "ProtocolSpace/ProtocolSpaceSchedule", "ProtocolSpace/ProtocolSpaceMode",
        "ProtocolSpace/ProtocolSpaceTab",
        "AutoCollect/@enabled", "AutoCollect/AutoCollectMode",
    ]

    /// Page order = schema.js order.
    static let groups: [EWGroupSpec] = [essence, protocolSpace, otherTasks]
}
