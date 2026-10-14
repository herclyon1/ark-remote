// The three 终末地 cards, from maa-automation/web/schema.js:143-218 (titles, paths, names, types, hints). The hints of the
// rows on the 终末地 page itself (firstLevel) are one sentence each (app-1013 review 终末地 3, design rule 8).
// 基质刷取 and 协议空间 are tree groups: the machine sends the whole option tree, these entries only add hint / name / type.

enum EndfieldSchema {
    static let essence = EWGroupSpec(title: "终末地 · 基质刷取", tree: "AutoEssence", fields: [
        EWFieldSpec(path: "AutoEssence/@enabled", type: .bool, label: "跑这个任务",
                    hint: "关掉后不刷基质；和协议空间都开着时，协议空间先花理智。"),
        // 「哪几天跑」: the row says what it sets, the same on all three task cards (MaaEnd's 「执行周期(游戏时间)」)
        EWFieldSpec(path: "AutoEssence/AutoEssenceSchedule", type: .pills, name: "哪几天跑",
                    hint: "只在勾选的星期刷，按游戏里的星期算。"),
        // 「刷取方式」: MaaEnd's 「刷取设置」 read like the 「基质刷取设置」 link under it; the menu picks the mode
        EWFieldSpec(path: "AutoEssence/AutoEssenceMenu", name: "刷取方式",
                    hint: "随机模式从勾选的地区里挑，地区模式固定一个地区，目标选择按想要的武器找。"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceDoOverride", type: .bool,
                    hint: "使用刻写券定向刷取词条。需事先在淤积点开始界面选定要刻写的属性；券不足时改为不刻写领取。"),
        // one 「领取方式」 per mode: only one shows at a time, so no 「随机模式 · 」 in front (ewTreeFields adds it to
        // names the tree repeats)
        EWFieldSpec(path: "AutoEssence/AutoEssenceObtainMode", type: .select, name: "领取方式",
                    hint: "基质每轮打完的结算方式。单倍＝一份理智一张券；双倍＝双倍理智两张券，奖励翻倍；不领取＝只刷素材。"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceObtainModeClaimOnly", type: .select, name: "领取方式"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter", type: .select, name: "领取方式"),
        // MaaEnd's 「循环执行」 did not say what is counted
        EWFieldSpec(path: "AutoEssence/AutoEssenceRepeatCount", type: .number, name: "每趟最多几轮",
                    hint: "基质一趟最多刷几轮。单倍每轮 80 理智，双倍 160。"),
        EWFieldSpec(path: "AutoEssence/AutoEssenceChooseLocation", type: .pills,
                    hint: "随机模式从勾选的地区里挑一个。藏剑谷与清波寨成功率较高，试验园区较低。"),
        EWFieldSpec(path: "AutoEssence/EssenceFilterAfterBattle", type: .bool,
                    hint: "每轮结束后立即筛选并锁定符合条件的基质。"),
        // the three filters' hints follow MaaEnd v2.32.0's own descriptions (locales/interface/zh_cn.json: a match is
        // an essence whose skills fit a target weapon; the extra rules keep essences that match no weapon, at a lower
        // priority than a weapon match)
        EWFieldSpec(path: "AutoEssence/EssenceFilterAfterBattleSelectWeaponRarity", type: .bool,
                    hint: "武器稀有度开着时，只拿勾上星级的武器去配基质词条。"),
        EWFieldSpec(path: "AutoEssence/EssenceFilterAfterBattleSelectEssence", type: .bool,
                    hint: "基质类型开着时，只筛勾上的那几种基质。"),
        EWFieldSpec(path: "AutoEssence/EssenceFilterAfterBattleSelectExtraRules", type: .bool,
                    hint: "扩展规则把配不上武器、但词条好的基质也留下。"),
        EWFieldSpec(path: "AutoEssence/AutoUseSpMedication", type: .select,
                    hint: "刷基质时理智用完了，结束任务或者吃应急理智加强剂接着刷。"),
        // MaaEnd's 「使用几天内」 did not say of what
        EWFieldSpec(path: "AutoEssence/AutoEssenceSpMedicationExpireWithinDays", type: .select, name: "只吃几天内过期的",
                    hint: "只吃几天内会过期的加强剂。选「全部」则不看剩余天数；「3 天内」会把同一批到期的药攒到最后三天一起吃掉。"),
    ])

    static let protocolSpace = EWGroupSpec(title: "终末地 · 协议空间", tree: "ProtocolSpace", fields: [
        EWFieldSpec(path: "ProtocolSpace/@enabled", type: .bool, label: "跑这个任务",
                    hint: "关掉后不刷协议空间；和基质刷取都开着时，这里先花理智。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceSchedule", type: .pills, name: "哪几天跑",
                    hint: "只在勾选的星期跑，按游戏里的星期算。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceMode", type: .select,
                    hint: "按次数刷取刷下面选的那一类，目标库存刷到「培养道具目标」的数为止。"),
        // our own name: MaaEnd's 「协议空间」 repeated the card's header and its switch row (app-1013 review 终末地 4)
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceTab", type: .select, name: "刷哪一类",
                    hint: "选了哪一类，协议空间设置里就只出现那一类的选项。"),
        EWFieldSpec(path: "ProtocolSpace/OperatorProgression", type: .select,
                    hint: "刷折金票选「钱币收集（折金票）」。"),
        EWFieldSpec(path: "ProtocolSpace/WeaponProgression", type: .select,
                    hint: "武器养成刷武器经验，或者武器进阶的材料。"),
        EWFieldSpec(path: "ProtocolSpace/CrisisDrills", type: .select,
                    hint: "危境预演每一档括号里是这一档的材料。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceLevel", type: .select,
                    hint: "协议空间打几级。"),
        // The four A/B are all 「可选奖励组」 in MaaEnd, so our own name wins (schema.js:183).
        EWFieldSpec(path: "ProtocolSpace/OperatorEXPRewardsSetOption", type: .select, name: "干员经验 · 可选奖励组", hint: "可选奖励组决定领奖励时拿 A 组还是 B 组。"),
        EWFieldSpec(path: "ProtocolSpace/PromotionsRewardsSetOption", type: .select, name: "干员进阶 · 可选奖励组", hint: "可选奖励组决定领奖励时拿 A 组还是 B 组。"),
        EWFieldSpec(path: "ProtocolSpace/SkillUpRewardsSetOption", type: .select, name: "技能提升 · 可选奖励组", hint: "可选奖励组决定领奖励时拿 A 组还是 B 组。"),
        EWFieldSpec(path: "ProtocolSpace/WeaponTuneRewardsSetOption", type: .select, name: "武器进阶 · 可选奖励组", hint: "可选奖励组决定领奖励时拿 A 组还是 B 组。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceObtainMode", type: .select,
                    hint: "协议空间每次打完领双倍、领单倍，或者不领取。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceSuccessCount", type: .select,
                    hint: "协议空间打成功几次就收工。无限制＝一直打到理智用完。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceUseSpMedication", type: .select,
                    hint: "刷协议空间时理智不够了，结束任务或者吃应急理智加强剂接着刷。"),
        EWFieldSpec(path: "ProtocolSpace/ProtocolSpaceFailedCount", type: .select,
                    hint: "协议空间打输几次就收工。"),
        EWFieldSpec(path: "ProtocolSpace/SupplyPlanLimits",
                    hint: "每种材料攒到多少就不再刷，只填数字。"),
    ])

    // the web's 「另外两个任务」 (schema.js:207) holds one task, 自动采集, and is named after it: 「另一个任务」 told a first-time
    // reader nothing (it also reaches the review lines, EWLive ewLabel)
    static let otherTasks = EWGroupSpec(title: "终末地 · 自动采集", fields: [
        EWFieldSpec(path: "AutoCollect/@enabled", type: .bool,
                    hint: "按自动采集设置里的线路和周期自动采集材料。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectSchedule", type: .pills, name: "哪几天跑",
                    hint: "自动采集只在勾选的星期执行，没勾的日子立即结束。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectMode", type: .select,
                    hint: "按勾选路线采勾上的，按目标库存只采还没攒够的。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIV", type: .bool, label: "四号谷地",
                    hint: "关掉后四号谷地的路线一条都不采。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIVRareRoutes", type: .pills, label: "四号谷地 · 稀有采集物",
                    hint: "勾上的路线才会去采。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectValleyIVCommonRoutes", type: .pills, label: "四号谷地 · 一般采集物",
                    hint: "勾上的路线才会去采。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWuling", type: .bool, label: "武陵",
                    hint: "关掉后武陵的路线一条都不采。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWulingRareRoutes", type: .pills, label: "武陵 · 稀有采集物",
                    hint: "勾上的路线才会去采。"),
        EWFieldSpec(path: "AutoCollect/AutoCollectWulingCommonRoutes", type: .pills, label: "武陵 · 一般采集物",
                    hint: "勾上的路线才会去采。"),
    ])

    /// The rows a card keeps on the 终末地 page itself: the task's switch and its current mode, most-changed first
    /// (hig-kit/HIG-CHECKLIST.maa.md:55 progressive disclosure, :59 order by importance). Every other row of the card,
    /// including the ones a mode opens (ProtocolSpaceTab → OperatorProgression …), is one level down under 「更多设置」.
    /// Filters the rows ewRows draws, not `fields`: tree cards draw the machine's tree (EWModel.swift ewRows).
    /// Every task card shows its switch, its days and its mode in that order (HIG Writing: "use it consistently throughout
    /// your app"; 基质刷取 and 自动采集 had the days one level down, 协议空间 on the page).
    static let firstLevel: Set<String> = [
        "AutoEssence/@enabled", "AutoEssence/AutoEssenceSchedule", "AutoEssence/AutoEssenceMenu",
        "ProtocolSpace/@enabled", "ProtocolSpace/ProtocolSpaceSchedule", "ProtocolSpace/ProtocolSpaceMode",
        "ProtocolSpace/ProtocolSpaceTab",
        "AutoCollect/@enabled", "AutoCollect/AutoCollectSchedule", "AutoCollect/AutoCollectMode",
    ]

    /// The 基质刷取设置 page in cards (essenceCardOrder), each with its own short footer (one card of ~15 rows with every hint at its foot;
    /// HIG Layout: "Group related items to clearly express related information or functions"). A row is placed by its
    /// path, children with their parent; a row of no card (a newer MaaEnd) goes in a last card without a header.
    static let essenceCardOrder = ["刷哪里、刷几轮", "领奖", "战后筛选", "理智", "自动战斗"]

    static func essenceCard(_ p: String) -> String? {
        let k = String(p.dropFirst("AutoEssence/".count))
        if ["AutoEssenceChooseLocation", "AutoEssenceSelectLocation", "AutoEssenceLocation", "AutoEssenceWeapon",
            "AutoEssenceRepeatCount"].contains(where: { k.hasPrefix($0) }) { return "刷哪里、刷几轮" }
        if k.hasPrefix("AutoEssenceObtainMode") || k == "AutoEssenceDoOverride" { return "领奖" }
        if k.hasPrefix("EssenceFilterAfterBattle") { return "战后筛选" }
        if k == "AutoUseSpMedication" || k == "AutoEssenceSpMedicationExpireWithinDays" { return "理智" }
        if k.hasPrefix("AutoFight") { return "自动战斗" }
        return nil
    }

    /// `rows` (one card's rows past its first level) split into the cards of its 「…设置」 page: 基质刷取 by essenceCard,
    /// the others as one card.
    static func moreCards(_ title: String, _ rows: [EWRow]) -> [(header: String?, rows: [EWRow])] {
        guard title == essence.title else { return rows.isEmpty ? [] : [(nil, rows)] }
        var out: [(header: String?, rows: [EWRow])] = []
        var placed = Set<String>()
        for h in essenceCardOrder {
            let part = rows.filter { !placed.contains($0.id) && essenceCard($0.path) == h }
            placed.formUnion(part.map(\.id))
            if !part.isEmpty { out.append((h, part)) }
        }
        let rest = rows.filter { !placed.contains($0.id) }
        if !rest.isEmpty { out.append((nil, rest)) }
        return out
    }

    /// Page order = schema.js order.
    static let groups: [EWGroupSpec] = [essence, protocolSpace, otherTasks]
}
