// Demo data for the MaaEnd page: the web page's DEMO_MASTER["MaaEnd"]
// (maa-automation/web/view.js:2356, read from relay fixtures by mastercfg.read_maaend / OK-WW defaults).
// Same shape as snap.master["MaaEnd"] in the relay's status packet, so the real feed decodes the same way.

import Foundation

extension EWMaster {
    static let endfieldSample: EWMaster = EWMaster(jsonString: endfieldSampleJSON) ?? EWMaster()
}

private let endfieldSampleJSON = #"""
{
 "values": {
  "AutoCollect/@enabled": true,
  "AutoCollect/AutoCollectSchedule": [
   "AutoCollectScheduleMonday",
   "AutoCollectScheduleWednesday",
   "AutoCollectScheduleFriday"
  ],
  "ProtocolSpace/@enabled": false,
  "ProtocolSpace/ProtocolSpaceSchedule": [
   "ProtocolSpaceScheduleMonday",
   "ProtocolSpaceScheduleTuesday",
   "ProtocolSpaceScheduleWednesday",
   "ProtocolSpaceScheduleThursday",
   "ProtocolSpaceScheduleFriday",
   "ProtocolSpaceScheduleSaturday",
   "ProtocolSpaceScheduleSunday"
  ],
  "ProtocolSpace/AutoFightSetting": true,
  "ProtocolSpace/AutoFightHealthDangerousSwitch": true,
  "ProtocolSpace/AutoFightDodge": true,
  "ProtocolSpace/AutoFightDodgeCompat": false,
  "ProtocolSpace/AutoFightLockTarget": true,
  "ProtocolSpace/AutoFightAxis": false,
  "ProtocolSpace/AutoFightAxisData": "",
  "ProtocolSpace/AutoFightAxisSkipComboCooldown": false,
  "ProtocolSpace/AutoFightReserveSkillLevel": "1",
  "ProtocolSpace/AutoFightBreakAccumulatingPower": true,
  "ProtocolSpace/ProtocolSpaceTeamChoose": "ProtocolSpaceTeamChooseDefault",
  "ProtocolSpace/ProtocolSpaceMode": "ByCount",
  "ProtocolSpace/ProtocolSpaceObtainMode": "ObtainScaling2",
  "ProtocolSpace/ProtocolSpaceUseSpMedication": "UseMedication",
  "ProtocolSpace/ProtocolSpaceSpMedicationExpireWithinDays": "Days3",
  "ProtocolSpace/ProtocolSpaceSuccessCount": "ProtocolSpaceSuccessCountUnlimited",
  "ProtocolSpace/ProtocolSpaceFailedCount": "ProtocolSpaceFailedCount3",
  "ProtocolSpace/ProtocolSpaceTab": "OperatorProgression",
  "ProtocolSpace/OperatorProgression": "OperatorEXP",
  "ProtocolSpace/OperatorEXPRewardsSetOption": "CognitiveCarriers",
  "ProtocolSpace/PromotionsRewardsSetOption": "Protoset",
  "ProtocolSpace/SkillUpRewardsSetOption": "Protohedron",
  "ProtocolSpace/ProtocolSpaceLevel": "ProtocolSpaceLevel05",
  "ProtocolSpace/WeaponProgression": "WeaponEXP",
  "ProtocolSpace/WeaponTuneRewardsSetOption": null,
  "ProtocolSpace/CrisisDrills": "AdvancedProgression1",
  "ProtocolSpace/ProtocolSpaceObtainModeClaim": "ObtainScaling2",
  "ProtocolSpace/SupplyPlanLimits": {
   "SupplyPlanLimit_COGNITIVE_CARRIER_EXP": "2100000",
   "SupplyPlanLimit_COMBAT_RECORD_EXP": "1500000",
   "SupplyPlanLimit_PROTOSET": "120",
   "SupplyPlanLimit_PROTODISK": "65",
   "SupplyPlanLimit_TRIPHASIC_NANOFLAKE": "260",
   "SupplyPlanLimit_QUADRANT_FITTING_FLUID": "260",
   "SupplyPlanLimit_TACHYON_SCREENING_LATTICE": "260",
   "SupplyPlanLimit_D96_STEEL_SAMPLE_4": "260",
   "SupplyPlanLimit_METADIASTIMA_PHOTOEMISSION_TUBE": "40",
   "SupplyPlanLimit_PROTOHEDRON": "1100",
   "SupplyPlanLimit_PROTOPRISM": "920",
   "SupplyPlanLimit_T_CREDS": "3580000",
   "SupplyPlanLimit_WEAPON_EXP": "5000000",
   "SupplyPlanLimit_HEAVY_CAST_DIE": "100",
   "SupplyPlanLimit_CAST_DIE": "45"
  },
  "AutoEssence/@enabled": true,
  "AutoEssence/AutoEssenceSchedule": [
   "AutoEssenceScheduleMonday",
   "AutoEssenceScheduleTuesday",
   "AutoEssenceScheduleWednesday",
   "AutoEssenceScheduleThursday",
   "AutoEssenceScheduleFriday",
   "AutoEssenceScheduleSaturday",
   "AutoEssenceScheduleSunday"
  ],
  "AutoEssence/AutoEssenceMenu": "Random",
  "AutoEssence/AutoEssenceChooseLocation": [
   "WLSwordVaultDale",
   "WLQingboStockade"
  ],
  "AutoEssence/AutoEssenceObtainMode": "ObtainScaling1",
  "AutoEssence/AutoEssenceDoOverride": false,
  "AutoEssence/EssenceFilterAfterBattle": true,
  "AutoEssence/EssenceFilterAfterBattleSelectWeaponRarity": true,
  "AutoEssence/EssenceFilterAfterBattleRarity6Weapon": true,
  "AutoEssence/EssenceFilterAfterBattleRarity5Weapon": false,
  "AutoEssence/EssenceFilterAfterBattleRarity4Weapon": false,
  "AutoEssence/EssenceFilterAfterBattleSelectEssence": true,
  "AutoEssence/EssenceFilterAfterBattleFlawlessEssence": true,
  "AutoEssence/EssenceFilterAfterBattlePureEssence": false,
  "AutoEssence/EssenceFilterAfterBattleSelectExtraRules": false,
  "AutoEssence/EssenceFilterAfterBattleKeepFuturePromising": false,
  "AutoEssence/EssenceFilterAfterBattleFuturePromisingMinTotal": "6",
  "AutoEssence/EssenceFilterAfterBattleLockFuturePromising": false,
  "AutoEssence/EssenceFilterAfterBattleKeepSlot3Level3Practical": false,
  "AutoEssence/EssenceFilterAfterBattleSlot3MinLevel": "3",
  "AutoEssence/EssenceFilterAfterBattleLockSlot3Practical": false,
  "AutoEssence/EssenceFilterAfterBattleDiscardUnmatched": false,
  "AutoEssence/AutoUseSpMedication": "UseMedication",
  "AutoEssence/AutoEssenceSpMedicationExpireWithinDays": "All",
  "AutoEssence/AutoEssenceRepeatCount": "99",
  "AutoEssence/AutoEssenceSelectLocation": "VFTheHub",
  "AutoEssence/AutoEssenceLocationSlot1": [
   "s1_2",
   "s1_3",
   "s1_4"
  ],
  "AutoEssence/AutoEssenceLocationSecondary_VFTheHub": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginiumSciencePark": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginLodespring": "s2_9",
  "AutoEssence/AutoEssenceLocationSecondary_VFPowerPlateau": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_WLWulingCity": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_WLQingboStockade": "s2_9",
  "AutoEssence/AutoEssenceLocationSecondary_WLMarkerStone": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_WLTestArea": "s2_9",
  "AutoEssence/AutoEssenceLocationSecondary_WLSwordVaultDale": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_WLYinglungPass": "s2_2",
  "AutoEssence/AutoEssenceLocationSecondary_WLNorthWulingExclusionZone": "s2_9",
  "AutoEssence/AutoEssenceLocationSecondary_WLSnowyForest": "s2_2",
  "AutoEssence/AutoEssenceObtainModeClaimOnly": "ObtainScaling2",
  "AutoEssence/AutoEssenceWeaponTypeSword": true,
  "AutoEssence/AutoEssenceWeaponsSword": [
   "wpn_sword_0010",
   "wpn_sword_0014",
   "wpn_sword_0016",
   "wpn_sword_0011",
   "wpn_sword_0017",
   "wpn_sword_0021"
  ],
  "AutoEssence/AutoEssenceWeaponTypeClaymore": true,
  "AutoEssence/AutoEssenceWeaponsClaymore": [
   "wpn_claym_0017",
   "wpn_claym_0007",
   "wpn_claym_0004",
   "wpn_claym_0013",
   "wpn_claym_0016",
   "wpn_claym_0008"
  ],
  "AutoEssence/AutoEssenceWeaponTypePistol": true,
  "AutoEssence/AutoEssenceWeaponsPistol": [
   "wpn_pistol_0005",
   "wpn_pistol_0011",
   "wpn_pistol_0009",
   "wpn_pistol_0007",
   "wpn_pistol_0008",
   "wpn_pistol_0010"
  ],
  "AutoEssence/AutoEssenceWeaponTypeWand": true,
  "AutoEssence/AutoEssenceWeaponsWand": [
   "wpn_funnel_0008",
   "wpn_funnel_0013",
   "wpn_funnel_0015",
   "wpn_funnel_0018",
   "wpn_funnel_0010",
   "wpn_funnel_0011"
  ],
  "AutoEssence/AutoEssenceWeaponTypeLance": true,
  "AutoEssence/AutoEssenceWeaponsLance": [
   "wpn_lance_0007",
   "wpn_lance_0015",
   "wpn_lance_0012",
   "wpn_lance_0016",
   "wpn_lance_0010",
   "wpn_lance_0011"
  ],
  "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter": "ObtainScaling2",
  "AutoEssence/AutoFightSettingFull": true,
  "AutoEssence/AutoFightAttack": true,
  "AutoEssence/AutoFightDodge": true,
  "AutoEssence/AutoFightDodgeCompat": false,
  "AutoEssence/AutoFightLockTarget": true,
  "AutoEssence/AutoFightHealthDangerousSwitch": true,
  "AutoEssence/AutoFightAxisFullSetting": false,
  "AutoEssence/AutoFightAxisData": "",
  "AutoEssence/AutoFightAxisSkipComboCooldown": false,
  "AutoEssence/AutoFightCombo": true,
  "AutoEssence/AutoFightSkill": true,
  "AutoEssence/AutoFightReserveSkillLevel": "1",
  "AutoEssence/AutoFightBreakAccumulatingPower": true,
  "AutoEssence/AutoFightEndSkill": true
 },
 "options": {
  "AutoCollect/AutoCollectSchedule": [
   [
    "周一",
    "AutoCollectScheduleMonday"
   ],
   [
    "周二",
    "AutoCollectScheduleTuesday"
   ],
   [
    "周三",
    "AutoCollectScheduleWednesday"
   ],
   [
    "周四",
    "AutoCollectScheduleThursday"
   ],
   [
    "周五",
    "AutoCollectScheduleFriday"
   ],
   [
    "周六",
    "AutoCollectScheduleSaturday"
   ],
   [
    "周日",
    "AutoCollectScheduleSunday"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceSchedule": [
   [
    "周一",
    "ProtocolSpaceScheduleMonday"
   ],
   [
    "周二",
    "ProtocolSpaceScheduleTuesday"
   ],
   [
    "周三",
    "ProtocolSpaceScheduleWednesday"
   ],
   [
    "周四",
    "ProtocolSpaceScheduleThursday"
   ],
   [
    "周五",
    "ProtocolSpaceScheduleFriday"
   ],
   [
    "周六",
    "ProtocolSpaceScheduleSaturday"
   ],
   [
    "周日",
    "ProtocolSpaceScheduleSunday"
   ]
  ],
  "ProtocolSpace/AutoFightReserveSkillLevel": [
   [
    "0",
    "0"
   ],
   [
    "1",
    "1"
   ],
   [
    "2",
    "2"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceTeamChoose": [
   [
    "默认",
    "ProtocolSpaceTeamChooseDefault"
   ],
   [
    "01",
    "ProtocolSpaceTeamChoose01"
   ],
   [
    "02",
    "ProtocolSpaceTeamChoose02"
   ],
   [
    "03",
    "ProtocolSpaceTeamChoose03"
   ],
   [
    "04",
    "ProtocolSpaceTeamChoose04"
   ],
   [
    "05",
    "ProtocolSpaceTeamChoose05"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceMode": [
   [
    "按次数刷取",
    "ByCount"
   ],
   [
    "目标库存",
    "TargetInventory"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceObtainMode": [
   [
    "双倍领取",
    "ObtainScaling2"
   ],
   [
    "单倍领取",
    "ObtainScaling1"
   ],
   [
    "不领取",
    "Discard"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceUseSpMedication": [
   [
    "结束任务",
    "EndTask"
   ],
   [
    "使用药剂恢复",
    "UseMedication"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceSpMedicationExpireWithinDays": [
   [
    "全部",
    "All"
   ],
   [
    "10天内",
    "Days10"
   ],
   [
    "7天内",
    "Days7"
   ],
   [
    "3天内",
    "Days3"
   ],
   [
    "1天内",
    "Days1"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceSuccessCount": [
   [
    "1",
    "ProtocolSpaceSuccessCount1"
   ],
   [
    "2",
    "ProtocolSpaceSuccessCount2"
   ],
   [
    "3",
    "ProtocolSpaceSuccessCount3"
   ],
   [
    "4",
    "ProtocolSpaceSuccessCount4"
   ],
   [
    "5",
    "ProtocolSpaceSuccessCount5"
   ],
   [
    "无限制",
    "ProtocolSpaceSuccessCountUnlimited"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceFailedCount": [
   [
    "1",
    "ProtocolSpaceFailedCount1"
   ],
   [
    "2",
    "ProtocolSpaceFailedCount2"
   ],
   [
    "3",
    "ProtocolSpaceFailedCount3"
   ],
   [
    "4",
    "ProtocolSpaceFailedCount4"
   ],
   [
    "5",
    "ProtocolSpaceFailedCount5"
   ],
   [
    "无限制",
    "ProtocolSpaceFailedCountUnlimited"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceTab": [
   [
    "干员养成",
    "OperatorProgression"
   ],
   [
    "武器养成",
    "WeaponProgression"
   ],
   [
    "危境预演",
    "CrisisDrills"
   ]
  ],
  "ProtocolSpace/OperatorProgression": [
   [
    "干员经验",
    "OperatorEXP"
   ],
   [
    "干员进阶",
    "Promotions"
   ],
   [
    "钱币收集（折金票）",
    "T-Creds"
   ],
   [
    "技能提升",
    "SkillUp"
   ]
  ],
  "ProtocolSpace/OperatorEXPRewardsSetOption": [
   [
    "B.高级作战记录",
    "AdvancedCombatRecord"
   ],
   [
    "A.高级认知载体、初级认知载体",
    "CognitiveCarriers"
   ]
  ],
  "ProtocolSpace/PromotionsRewardsSetOption": [
   [
    "B.协议圆盘",
    "Protodisk"
   ],
   [
    "A.协议圆盘组",
    "Protoset"
   ]
  ],
  "ProtocolSpace/SkillUpRewardsSetOption": [
   [
    "B.协议棱柱",
    "Protoprism"
   ],
   [
    "A.协议棱柱组",
    "Protohedron"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceLevel": [
   [
    "一级",
    "ProtocolSpaceLevel01"
   ],
   [
    "二级",
    "ProtocolSpaceLevel02"
   ],
   [
    "三级",
    "ProtocolSpaceLevel03"
   ],
   [
    "四级",
    "ProtocolSpaceLevel04"
   ],
   [
    "五级",
    "ProtocolSpaceLevel05"
   ]
  ],
  "ProtocolSpace/WeaponProgression": [
   [
    "武器经验（武器检查套组、武器检查装置）",
    "WeaponEXP"
   ],
   [
    "武器进阶",
    "WeaponTune"
   ]
  ],
  "ProtocolSpace/WeaponTuneRewardsSetOption": [
   [
    "B.强固模具",
    "CastDie"
   ],
   [
    "A.重型强固模具",
    "HeavyCastDie"
   ]
  ],
  "ProtocolSpace/CrisisDrills": [
   [
    "高阶培养Ⅰ（D96钢样品四）",
    "AdvancedProgression1"
   ],
   [
    "高阶培养Ⅱ（超距辉映管）",
    "AdvancedProgression2"
   ],
   [
    "高阶培养Ⅲ（快子遴捡晶格）",
    "AdvancedProgression3"
   ],
   [
    "高阶培养Ⅳ（象限拟合液）",
    "AdvancedProgression4"
   ],
   [
    "高阶培养Ⅴ（三相纳米片）",
    "AdvancedProgression5"
   ]
  ],
  "ProtocolSpace/ProtocolSpaceObtainModeClaim": [
   [
    "双倍领取",
    "ObtainScaling2"
   ],
   [
    "单倍领取",
    "ObtainScaling1"
   ]
  ],
  "AutoEssence/AutoEssenceSchedule": [
   [
    "周一",
    "AutoEssenceScheduleMonday"
   ],
   [
    "周二",
    "AutoEssenceScheduleTuesday"
   ],
   [
    "周三",
    "AutoEssenceScheduleWednesday"
   ],
   [
    "周四",
    "AutoEssenceScheduleThursday"
   ],
   [
    "周五",
    "AutoEssenceScheduleFriday"
   ],
   [
    "周六",
    "AutoEssenceScheduleSaturday"
   ],
   [
    "周日",
    "AutoEssenceScheduleSunday"
   ]
  ],
  "AutoEssence/AutoEssenceMenu": [
   [
    "随机模式",
    "Random"
   ],
   [
    "地区模式",
    "Location"
   ],
   [
    "目标选择",
    "Target"
   ]
  ],
  "AutoEssence/AutoEssenceChooseLocation": [
   [
    "枢纽区",
    "VFTheHub"
   ],
   [
    "源石研究园",
    "VFOriginiumSciencePark"
   ],
   [
    "矿脉源区",
    "VFOriginLodespring"
   ],
   [
    "供能高地",
    "VFPowerPlateau"
   ],
   [
    "武陵城区",
    "WLWulingCity"
   ],
   [
    "清波寨",
    "WLQingboStockade"
   ],
   [
    "首墩",
    "WLMarkerStone"
   ],
   [
    "试验园区",
    "WLTestArea"
   ],
   [
    "藏剑谷",
    "WLSwordVaultDale"
   ],
   [
    "应龙关",
    "WLYinglungPass"
   ],
   [
    "北部禁区",
    "WLNorthWulingExclusionZone"
   ],
   [
    "雪松林",
    "WLSnowyForest"
   ]
  ],
  "AutoEssence/AutoEssenceObtainMode": [
   [
    "不领取（仅刷素材）",
    "Discard"
   ],
   [
    "单倍领取",
    "ObtainScaling1"
   ],
   [
    "双倍领取",
    "ObtainScaling2"
   ]
  ],
  "AutoEssence/AutoUseSpMedication": [
   [
    "结束任务",
    "EndTask"
   ],
   [
    "使用药剂恢复",
    "UseMedication"
   ]
  ],
  "AutoEssence/AutoEssenceSpMedicationExpireWithinDays": [
   [
    "全部",
    "All"
   ],
   [
    "10天内",
    "Days10"
   ],
   [
    "7天内",
    "Days7"
   ],
   [
    "3天内",
    "Days3"
   ],
   [
    "1天内",
    "Days1"
   ]
  ],
  "AutoEssence/AutoEssenceSelectLocation": [
   [
    "枢纽区",
    "VFTheHub"
   ],
   [
    "源石研究园",
    "VFOriginiumSciencePark"
   ],
   [
    "矿脉源区",
    "VFOriginLodespring"
   ],
   [
    "供能高地",
    "VFPowerPlateau"
   ],
   [
    "武陵城区",
    "WLWulingCity"
   ],
   [
    "清波寨",
    "WLQingboStockade"
   ],
   [
    "首墩",
    "WLMarkerStone"
   ],
   [
    "试验园区",
    "WLTestArea"
   ],
   [
    "藏剑谷",
    "WLSwordVaultDale"
   ],
   [
    "应龙关",
    "WLYinglungPass"
   ],
   [
    "北部禁区",
    "WLNorthWulingExclusionZone"
   ],
   [
    "雪松林",
    "WLSnowyForest"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSlot1": [
   [
    "主能力提升",
    "s1_1"
   ],
   [
    "力量提升",
    "s1_2"
   ],
   [
    "意志提升",
    "s1_3"
   ],
   [
    "敏捷提升",
    "s1_4"
   ],
   [
    "智识提升",
    "s1_5"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_VFTheHub": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "流转",
    "s3_10"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginiumSciencePark": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginLodespring": [
   [
    "生命提升",
    "s2_9"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "夜幕",
    "s3_4"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_VFPowerPlateau": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "生命提升",
    "s2_9"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "流转",
    "s3_10"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLWulingCity": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "生命提升",
    "s2_9"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "夜幕",
    "s3_4"
   ],
   [
    "流转",
    "s3_10"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLQingboStockade": [
   [
    "生命提升",
    "s2_9"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "夜幕",
    "s3_4"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLMarkerStone": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "夜幕",
    "s3_4"
   ],
   [
    "流转",
    "s3_10"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLTestArea": [
   [
    "生命提升",
    "s2_9"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "夜幕",
    "s3_4"
   ],
   [
    "流转",
    "s3_10"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLSwordVaultDale": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "生命提升",
    "s2_9"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "切骨",
    "s3_1"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLYinglungPass": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "寒冷伤害提升",
    "s2_1"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "巧技",
    "s3_5"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "流转",
    "s3_10"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLNorthWulingExclusionZone": [
   [
    "生命提升",
    "s2_9"
   ],
   [
    "物理伤害提升",
    "s2_8"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "自然伤害提升",
    "s2_12"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "源石技艺提升",
    "s2_6"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "压制",
    "s3_3"
   ],
   [
    "追袭",
    "s3_13"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "附术",
    "s3_14"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "效益",
    "s3_7"
   ]
  ],
  "AutoEssence/AutoEssenceLocationSecondary_WLSnowyForest": [
   [
    "攻击提升",
    "s2_2"
   ],
   [
    "生命提升",
    "s2_9"
   ],
   [
    "灼热伤害提升",
    "s2_7"
   ],
   [
    "电磁伤害提升",
    "s2_10"
   ],
   [
    "暴击率提升",
    "s2_3"
   ],
   [
    "终结技充能效率提升",
    "s2_11"
   ],
   [
    "法术伤害提升",
    "s2_5"
   ],
   [
    "治疗效率提升",
    "s2_4"
   ],
   [
    "强攻",
    "s3_6"
   ],
   [
    "粉碎",
    "s3_11"
   ],
   [
    "昂扬",
    "s3_8"
   ],
   [
    "残暴",
    "s3_9"
   ],
   [
    "医疗",
    "s3_2"
   ],
   [
    "迸发",
    "s3_12"
   ],
   [
    "夜幕",
    "s3_4"
   ],
   [
    "流转",
    "s3_10"
   ]
  ],
  "AutoEssence/AutoEssenceObtainModeClaimOnly": [
   [
    "单倍领取",
    "ObtainScaling1"
   ],
   [
    "双倍领取",
    "ObtainScaling2"
   ]
  ],
  "AutoEssence/AutoEssenceWeaponsSword": [
   [
    "★6 黯色火炬",
    "wpn_sword_0010"
   ],
   [
    "★6 白夜新星",
    "wpn_sword_0014"
   ],
   [
    "★6 不知归",
    "wpn_sword_0016"
   ],
   [
    "★6 扶摇",
    "wpn_sword_0011"
   ],
   [
    "★6 光荣记忆",
    "wpn_sword_0017"
   ],
   [
    "★6 宏愿",
    "wpn_sword_0021"
   ],
   [
    "★6 狼之绯",
    "wpn_sword_0022"
   ],
   [
    "★6 热熔切割器",
    "wpn_sword_0012"
   ],
   [
    "★6 熔铸火焰",
    "wpn_sword_0006"
   ],
   [
    "★6 显赫声名",
    "wpn_sword_0013"
   ],
   [
    "★6 遥望",
    "wpn_sword_0026"
   ],
   [
    "★5 钢铁余音",
    "wpn_sword_0005"
   ],
   [
    "★5 坚城铸造者",
    "wpn_sword_0007"
   ],
   [
    "★5 十二问",
    "wpn_sword_0018"
   ],
   [
    "★5 仰止",
    "wpn_sword_0015"
   ],
   [
    "★5 逐鳞3.0",
    "wpn_sword_0020"
   ],
   [
    "★5 O.B.J.轻芒",
    "wpn_sword_0019"
   ]
  ],
  "AutoEssence/AutoEssenceWeaponsClaymore": [
   [
    "★6 赤缨",
    "wpn_claym_0017"
   ],
   [
    "★6 大雷斑",
    "wpn_claym_0007"
   ],
   [
    "★6 典范",
    "wpn_claym_0004"
   ],
   [
    "★6 赫拉芬格",
    "wpn_claym_0013"
   ],
   [
    "★6 幻想苦痛",
    "wpn_claym_0016"
   ],
   [
    "★6 破碎君王",
    "wpn_claym_0008"
   ],
   [
    "★6 昔日精品",
    "wpn_claym_0006"
   ],
   [
    "★5 古渠",
    "wpn_claym_0014"
   ],
   [
    "★5 探骊",
    "wpn_claym_0011"
   ],
   [
    "★5 终点之声",
    "wpn_claym_0012"
   ],
   [
    "★5 O.B.J.重荷",
    "wpn_claym_0015"
   ]
  ],
  "AutoEssence/AutoEssenceWeaponsPistol": [
   [
    "★6 领航者",
    "wpn_pistol_0005"
   ],
   [
    "★6 落草",
    "wpn_pistol_0011"
   ],
   [
    "★6 同类相食",
    "wpn_pistol_0009"
   ],
   [
    "★6 望乡",
    "wpn_pistol_0007"
   ],
   [
    "★6 楔子",
    "wpn_pistol_0008"
   ],
   [
    "★6 艺术暴君",
    "wpn_pistol_0010"
   ],
   [
    "★5 理性告别",
    "wpn_pistol_0004"
   ],
   [
    "★5 作品：众生",
    "wpn_pistol_0006"
   ],
   [
    "★5 O.B.J.迅极",
    "wpn_pistol_0012"
   ]
  ],
  "AutoEssence/AutoEssenceWeaponsWand": [
   [
    "★6 爆破单元",
    "wpn_funnel_0008"
   ],
   [
    "★6 沧溟星梦",
    "wpn_funnel_0013"
   ],
   [
    "★6 孤舟",
    "wpn_funnel_0015"
   ],
   [
    "★6 联结点",
    "wpn_funnel_0018"
   ],
   [
    "★6 骑士精神",
    "wpn_funnel_0010"
   ],
   [
    "★6 使命必达",
    "wpn_funnel_0011"
   ],
   [
    "★6 四二式·肃阵",
    "wpn_funnel_0016"
   ],
   [
    "★6 雾中微光",
    "wpn_funnel_0017"
   ],
   [
    "★6 遗忘",
    "wpn_funnel_0009"
   ],
   [
    "★6 作品：蚀迹",
    "wpn_funnel_0006"
   ],
   [
    "★6 寒夜幽影",
    "wpn_funnel_0019"
   ],
   [
    "★6 苦难的尽头",
    "wpn_funnel_0020"
   ],
   [
    "★5 布道自由",
    "wpn_funnel_0012"
   ],
   [
    "★5 悼亡诗",
    "wpn_funnel_0005"
   ],
   [
    "★5 迷失荒野",
    "wpn_funnel_0004"
   ],
   [
    "★5 莫奈何",
    "wpn_funnel_0007"
   ]
  ],
  "AutoEssence/AutoEssenceWeaponsLance": [
   [
    "★6 灯火使命",
    "wpn_lance_0007"
   ],
   [
    "★6 镀红祝福",
    "wpn_lance_0015"
   ],
   [
    "★6 负山",
    "wpn_lance_0012"
   ],
   [
    "★6 黄金时代",
    "wpn_lance_0016"
   ],
   [
    "★6 骁勇",
    "wpn_lance_0010"
   ],
   [
    "★6 J.E.T.",
    "wpn_lance_0011"
   ],
   [
    "★6 曜夜的首演",
    "wpn_lance_0014"
   ],
   [
    "★5 嵌合正义",
    "wpn_lance_0004"
   ],
   [
    "★5 向心之引",
    "wpn_lance_0006"
   ],
   [
    "★5 O.B.J.尖峰",
    "wpn_lance_0013"
   ]
  ],
  "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter": [
   [
    "单倍领取",
    "ObtainScaling1"
   ],
   [
    "双倍领取",
    "ObtainScaling2"
   ]
  ],
  "AutoEssence/AutoFightReserveSkillLevel": [
   [
    "0",
    "0"
   ],
   [
    "1",
    "1"
   ],
   [
    "2",
    "2"
   ]
  ]
 },
 "labels": {
  "AutoCollect/@enabled": "🧺自动采集",
  "AutoCollect/AutoCollectSchedule": "执行周期(游戏时间)",
  "ProtocolSpace/@enabled": "⚔️协议空间",
  "ProtocolSpace/ProtocolSpaceSchedule": "执行周期(游戏时间)",
  "ProtocolSpace/AutoFightSetting": "自动战斗设置",
  "ProtocolSpace/AutoFightHealthDangerousSwitch": "自动切换低血量干员到后台",
  "ProtocolSpace/AutoFightDodge": "自动闪避",
  "ProtocolSpace/AutoFightDodgeCompat": "兼容模式",
  "ProtocolSpace/AutoFightLockTarget": "自动锁定目标",
  "ProtocolSpace/AutoFightAxis": "使用排轴",
  "ProtocolSpace/AutoFightAxisData": "排轴数据",
  "ProtocolSpace/AutoFightAxisSkipComboCooldown": "不等待连携技冷却",
  "ProtocolSpace/AutoFightReserveSkillLevel": "保留技能能量",
  "ProtocolSpace/AutoFightBreakAccumulatingPower": "自动打断敌人蓄力",
  "ProtocolSpace/ProtocolSpaceTeamChoose": "选择队伍",
  "ProtocolSpace/ProtocolSpaceMode": "刷取模式",
  "ProtocolSpace/ProtocolSpaceObtainMode": "领取方式",
  "ProtocolSpace/ProtocolSpaceUseSpMedication": "理智不足时",
  "ProtocolSpace/ProtocolSpaceSpMedicationExpireWithinDays": "使用几天内",
  "ProtocolSpace/ProtocolSpaceSuccessCount": "行动成功次数上限",
  "ProtocolSpace/ProtocolSpaceFailedCount": "行动失败次数上限",
  "ProtocolSpace/ProtocolSpaceTab": "协议空间",
  "ProtocolSpace/OperatorProgression": "干员养成",
  "ProtocolSpace/OperatorEXPRewardsSetOption": "可选奖励组",
  "ProtocolSpace/PromotionsRewardsSetOption": "可选奖励组",
  "ProtocolSpace/SkillUpRewardsSetOption": "可选奖励组",
  "ProtocolSpace/ProtocolSpaceLevel": "选择协议空间等级",
  "ProtocolSpace/WeaponProgression": "武器养成",
  "ProtocolSpace/WeaponTuneRewardsSetOption": "可选奖励组",
  "ProtocolSpace/CrisisDrills": "危境预演",
  "ProtocolSpace/ProtocolSpaceObtainModeClaim": "领取方式",
  "ProtocolSpace/SupplyPlanLimits": "培养道具目标",
  "AutoEssence/@enabled": "🎱基质刷取",
  "AutoEssence/AutoEssenceSchedule": "执行周期(游戏时间)",
  "AutoEssence/AutoEssenceMenu": "刷取设置",
  "AutoEssence/AutoEssenceChooseLocation": "随机地区",
  "AutoEssence/AutoEssenceObtainMode": "领取方式",
  "AutoEssence/AutoEssenceDoOverride": "使用刻写券",
  "AutoEssence/EssenceFilterAfterBattle": "战后基质筛选",
  "AutoEssence/EssenceFilterAfterBattleSelectWeaponRarity": "武器稀有度",
  "AutoEssence/EssenceFilterAfterBattleRarity6Weapon": "★6武器",
  "AutoEssence/EssenceFilterAfterBattleRarity5Weapon": "★5武器",
  "AutoEssence/EssenceFilterAfterBattleRarity4Weapon": "★4武器",
  "AutoEssence/EssenceFilterAfterBattleSelectEssence": "基质类型",
  "AutoEssence/EssenceFilterAfterBattleFlawlessEssence": "🟨无瑕基质",
  "AutoEssence/EssenceFilterAfterBattlePureEssence": "🟪高纯基质",
  "AutoEssence/EssenceFilterAfterBattleSelectExtraRules": "扩展规则",
  "AutoEssence/EssenceFilterAfterBattleKeepFuturePromising": "保留未来可期基质",
  "AutoEssence/EssenceFilterAfterBattleFuturePromisingMinTotal": "总等级最低要求",
  "AutoEssence/EssenceFilterAfterBattleLockFuturePromising": "未来可期命中后锁定",
  "AutoEssence/EssenceFilterAfterBattleKeepSlot3Level3Practical": "保留实用基质",
  "AutoEssence/EssenceFilterAfterBattleSlot3MinLevel": "词条3最低等级",
  "AutoEssence/EssenceFilterAfterBattleLockSlot3Practical": "实用基质命中后锁定",
  "AutoEssence/EssenceFilterAfterBattleDiscardUnmatched": "未匹配时废弃",
  "AutoEssence/AutoUseSpMedication": "理智不足时",
  "AutoEssence/AutoEssenceSpMedicationExpireWithinDays": "使用几天内",
  "AutoEssence/AutoEssenceRepeatCount": "循环执行",
  "AutoEssence/AutoEssenceSelectLocation": "选择地区",
  "AutoEssence/AutoEssenceLocationSlot1": "基础属性",
  "AutoEssence/AutoEssenceLocationSecondary_VFTheHub": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginiumSciencePark": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_VFOriginLodespring": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_VFPowerPlateau": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLWulingCity": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLQingboStockade": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLMarkerStone": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLTestArea": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLSwordVaultDale": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLYinglungPass": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLNorthWulingExclusionZone": "附加 / 技能属性",
  "AutoEssence/AutoEssenceLocationSecondary_WLSnowyForest": "附加 / 技能属性",
  "AutoEssence/AutoEssenceObtainModeClaimOnly": "领取方式",
  "AutoEssence/AutoEssenceWeaponTypeSword": "单手剑",
  "AutoEssence/AutoEssenceWeaponsSword": "选择武器",
  "AutoEssence/AutoEssenceWeaponTypeClaymore": "双手剑",
  "AutoEssence/AutoEssenceWeaponsClaymore": "选择武器",
  "AutoEssence/AutoEssenceWeaponTypePistol": "手铳",
  "AutoEssence/AutoEssenceWeaponsPistol": "选择武器",
  "AutoEssence/AutoEssenceWeaponTypeWand": "施术单元",
  "AutoEssence/AutoEssenceWeaponsWand": "选择武器",
  "AutoEssence/AutoEssenceWeaponTypeLance": "长柄武器",
  "AutoEssence/AutoEssenceWeaponsLance": "选择武器",
  "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter": "领取方式",
  "AutoEssence/AutoFightSettingFull": "自动战斗详细设置",
  "AutoEssence/AutoFightAttack": "自动普攻",
  "AutoEssence/AutoFightDodge": "自动闪避",
  "AutoEssence/AutoFightDodgeCompat": "兼容模式",
  "AutoEssence/AutoFightLockTarget": "自动锁定目标",
  "AutoEssence/AutoFightHealthDangerousSwitch": "自动切换低血量干员到后台",
  "AutoEssence/AutoFightAxisFullSetting": "使用排轴",
  "AutoEssence/AutoFightAxisData": "排轴数据",
  "AutoEssence/AutoFightAxisSkipComboCooldown": "不等待连携技冷却",
  "AutoEssence/AutoFightCombo": "自动触发连携技能",
  "AutoEssence/AutoFightSkill": "自动释放技能",
  "AutoEssence/AutoFightReserveSkillLevel": "保留技能能量",
  "AutoEssence/AutoFightBreakAccumulatingPower": "自动打断敌人蓄力",
  "AutoEssence/AutoFightEndSkill": "自动释放终结技"
 },
 "roots": {
  "ProtocolSpace": [
   "ProtocolSpace/ProtocolSpaceSchedule",
   "ProtocolSpace/AutoFightSetting",
   "ProtocolSpace/ProtocolSpaceTeamChoose",
   "ProtocolSpace/ProtocolSpaceMode"
  ],
  "AutoEssence": [
   "AutoEssence/AutoEssenceSchedule",
   "AutoEssence/AutoEssenceMenu",
   "AutoEssence/AutoFightSettingFull"
  ]
 },
 "children": {
  "ProtocolSpace/AutoFightSetting": {
   "true": [
    "ProtocolSpace/AutoFightHealthDangerousSwitch",
    "ProtocolSpace/AutoFightDodge",
    "ProtocolSpace/AutoFightLockTarget",
    "ProtocolSpace/AutoFightAxis"
   ]
  },
  "ProtocolSpace/AutoFightDodge": {
   "true": [
    "ProtocolSpace/AutoFightDodgeCompat"
   ]
  },
  "ProtocolSpace/AutoFightAxis": {
   "true": [
    "ProtocolSpace/AutoFightAxisData",
    "ProtocolSpace/AutoFightAxisSkipComboCooldown"
   ],
   "false": [
    "ProtocolSpace/AutoFightReserveSkillLevel"
   ]
  },
  "ProtocolSpace/AutoFightReserveSkillLevel": {
   "1": [
    "ProtocolSpace/AutoFightBreakAccumulatingPower"
   ],
   "2": [
    "ProtocolSpace/AutoFightBreakAccumulatingPower"
   ]
  },
  "ProtocolSpace/ProtocolSpaceMode": {
   "ByCount": [
    "ProtocolSpace/ProtocolSpaceObtainMode",
    "ProtocolSpace/ProtocolSpaceSuccessCount",
    "ProtocolSpace/ProtocolSpaceFailedCount",
    "ProtocolSpace/ProtocolSpaceTab"
   ],
   "TargetInventory": [
    "ProtocolSpace/ProtocolSpaceObtainModeClaim",
    "ProtocolSpace/SupplyPlanLimits"
   ]
  },
  "ProtocolSpace/ProtocolSpaceObtainMode": {
   "ObtainScaling2": [
    "ProtocolSpace/ProtocolSpaceUseSpMedication"
   ],
   "ObtainScaling1": [
    "ProtocolSpace/ProtocolSpaceUseSpMedication"
   ]
  },
  "ProtocolSpace/ProtocolSpaceUseSpMedication": {
   "UseMedication": [
    "ProtocolSpace/ProtocolSpaceSpMedicationExpireWithinDays"
   ]
  },
  "ProtocolSpace/ProtocolSpaceTab": {
   "OperatorProgression": [
    "ProtocolSpace/OperatorProgression",
    "ProtocolSpace/ProtocolSpaceLevel"
   ],
   "WeaponProgression": [
    "ProtocolSpace/WeaponProgression",
    "ProtocolSpace/ProtocolSpaceLevel"
   ],
   "CrisisDrills": [
    "ProtocolSpace/CrisisDrills"
   ]
  },
  "ProtocolSpace/OperatorProgression": {
   "OperatorEXP": [
    "ProtocolSpace/OperatorEXPRewardsSetOption"
   ],
   "Promotions": [
    "ProtocolSpace/PromotionsRewardsSetOption"
   ],
   "SkillUp": [
    "ProtocolSpace/SkillUpRewardsSetOption"
   ]
  },
  "ProtocolSpace/WeaponProgression": {
   "WeaponTune": [
    "ProtocolSpace/WeaponTuneRewardsSetOption"
   ]
  },
  "ProtocolSpace/ProtocolSpaceObtainModeClaim": {
   "ObtainScaling2": [
    "ProtocolSpace/ProtocolSpaceUseSpMedication"
   ],
   "ObtainScaling1": [
    "ProtocolSpace/ProtocolSpaceUseSpMedication"
   ]
  },
  "AutoEssence/AutoEssenceMenu": {
   "Random": [
    "AutoEssence/AutoEssenceChooseLocation",
    "AutoEssence/AutoEssenceObtainMode",
    "AutoEssence/AutoEssenceRepeatCount"
   ],
   "Location": [
    "AutoEssence/AutoEssenceSelectLocation",
    "AutoEssence/AutoEssenceObtainModeClaimOnly",
    "AutoEssence/AutoEssenceRepeatCount"
   ],
   "Target": [
    "AutoEssence/AutoEssenceWeaponTypeSword",
    "AutoEssence/AutoEssenceWeaponTypeClaymore",
    "AutoEssence/AutoEssenceWeaponTypePistol",
    "AutoEssence/AutoEssenceWeaponTypeWand",
    "AutoEssence/AutoEssenceWeaponTypeLance",
    "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter"
   ]
  },
  "AutoEssence/AutoEssenceObtainMode": {
   "ObtainScaling1": [
    "AutoEssence/AutoEssenceDoOverride",
    "AutoEssence/EssenceFilterAfterBattle",
    "AutoEssence/AutoUseSpMedication"
   ],
   "ObtainScaling2": [
    "AutoEssence/AutoEssenceDoOverride",
    "AutoEssence/EssenceFilterAfterBattle",
    "AutoEssence/AutoUseSpMedication"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattle": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleSelectWeaponRarity",
    "AutoEssence/EssenceFilterAfterBattleSelectEssence",
    "AutoEssence/EssenceFilterAfterBattleSelectExtraRules"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattleSelectWeaponRarity": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleRarity6Weapon",
    "AutoEssence/EssenceFilterAfterBattleRarity5Weapon",
    "AutoEssence/EssenceFilterAfterBattleRarity4Weapon"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattleSelectEssence": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleFlawlessEssence",
    "AutoEssence/EssenceFilterAfterBattlePureEssence"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattleSelectExtraRules": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleKeepFuturePromising",
    "AutoEssence/EssenceFilterAfterBattleKeepSlot3Level3Practical",
    "AutoEssence/EssenceFilterAfterBattleDiscardUnmatched"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattleKeepFuturePromising": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleFuturePromisingMinTotal",
    "AutoEssence/EssenceFilterAfterBattleLockFuturePromising"
   ]
  },
  "AutoEssence/EssenceFilterAfterBattleKeepSlot3Level3Practical": {
   "true": [
    "AutoEssence/EssenceFilterAfterBattleSlot3MinLevel",
    "AutoEssence/EssenceFilterAfterBattleLockSlot3Practical"
   ]
  },
  "AutoEssence/AutoUseSpMedication": {
   "UseMedication": [
    "AutoEssence/AutoEssenceSpMedicationExpireWithinDays"
   ]
  },
  "AutoEssence/AutoEssenceSelectLocation": {
   "VFTheHub": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_VFTheHub"
   ],
   "VFOriginiumSciencePark": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_VFOriginiumSciencePark"
   ],
   "VFOriginLodespring": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_VFOriginLodespring"
   ],
   "VFPowerPlateau": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_VFPowerPlateau"
   ],
   "WLWulingCity": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLWulingCity"
   ],
   "WLQingboStockade": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLQingboStockade"
   ],
   "WLMarkerStone": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLMarkerStone"
   ],
   "WLTestArea": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLTestArea"
   ],
   "WLSwordVaultDale": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLSwordVaultDale"
   ],
   "WLYinglungPass": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLYinglungPass"
   ],
   "WLNorthWulingExclusionZone": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLNorthWulingExclusionZone"
   ],
   "WLSnowyForest": [
    "AutoEssence/AutoEssenceLocationSlot1",
    "AutoEssence/AutoEssenceLocationSecondary_WLSnowyForest"
   ]
  },
  "AutoEssence/AutoEssenceObtainModeClaimOnly": {
   "ObtainScaling1": [
    "AutoEssence/AutoEssenceDoOverride",
    "AutoEssence/EssenceFilterAfterBattle",
    "AutoEssence/AutoUseSpMedication"
   ],
   "ObtainScaling2": [
    "AutoEssence/AutoEssenceDoOverride",
    "AutoEssence/EssenceFilterAfterBattle",
    "AutoEssence/AutoUseSpMedication"
   ]
  },
  "AutoEssence/AutoEssenceWeaponTypeSword": {
   "true": [
    "AutoEssence/AutoEssenceWeaponsSword"
   ]
  },
  "AutoEssence/AutoEssenceWeaponTypeClaymore": {
   "true": [
    "AutoEssence/AutoEssenceWeaponsClaymore"
   ]
  },
  "AutoEssence/AutoEssenceWeaponTypePistol": {
   "true": [
    "AutoEssence/AutoEssenceWeaponsPistol"
   ]
  },
  "AutoEssence/AutoEssenceWeaponTypeWand": {
   "true": [
    "AutoEssence/AutoEssenceWeaponsWand"
   ]
  },
  "AutoEssence/AutoEssenceWeaponTypeLance": {
   "true": [
    "AutoEssence/AutoEssenceWeaponsLance"
   ]
  },
  "AutoEssence/AutoEssenceObtainModeClaimOnlyForcedFilter": {
   "ObtainScaling1": [
    "AutoEssence/AutoUseSpMedication"
   ],
   "ObtainScaling2": [
    "AutoEssence/AutoUseSpMedication"
   ]
  },
  "AutoEssence/AutoFightSettingFull": {
   "true": [
    "AutoEssence/AutoFightAttack",
    "AutoEssence/AutoFightDodge",
    "AutoEssence/AutoFightLockTarget",
    "AutoEssence/AutoFightHealthDangerousSwitch",
    "AutoEssence/AutoFightAxisFullSetting"
   ]
  },
  "AutoEssence/AutoFightDodge": {
   "true": [
    "AutoEssence/AutoFightDodgeCompat"
   ]
  },
  "AutoEssence/AutoFightAxisFullSetting": {
   "true": [
    "AutoEssence/AutoFightAxisData",
    "AutoEssence/AutoFightAxisSkipComboCooldown"
   ],
   "false": [
    "AutoEssence/AutoFightCombo",
    "AutoEssence/AutoFightSkill",
    "AutoEssence/AutoFightEndSkill"
   ]
  },
  "AutoEssence/AutoFightSkill": {
   "true": [
    "AutoEssence/AutoFightReserveSkillLevel"
   ]
  },
  "AutoEssence/AutoFightReserveSkillLevel": {
   "1": [
    "AutoEssence/AutoFightBreakAccumulatingPower"
   ],
   "2": [
    "AutoEssence/AutoFightBreakAccumulatingPower"
   ]
  }
 },
 "inputs": {
  "ProtocolSpace/SupplyPlanLimits": [
   [
    "认知载体经验",
    "SupplyPlanLimit_COGNITIVE_CARRIER_EXP"
   ],
   [
    "作战记录经验",
    "SupplyPlanLimit_COMBAT_RECORD_EXP"
   ],
   [
    "协议圆盘组",
    "SupplyPlanLimit_PROTOSET"
   ],
   [
    "协议圆盘",
    "SupplyPlanLimit_PROTODISK"
   ],
   [
    "三相纳米片",
    "SupplyPlanLimit_TRIPHASIC_NANOFLAKE"
   ],
   [
    "象限拟合液",
    "SupplyPlanLimit_QUADRANT_FITTING_FLUID"
   ],
   [
    "快子遴捡晶格",
    "SupplyPlanLimit_TACHYON_SCREENING_LATTICE"
   ],
   [
    "D96钢样品四",
    "SupplyPlanLimit_D96_STEEL_SAMPLE_4"
   ],
   [
    "超距辉映管",
    "SupplyPlanLimit_METADIASTIMA_PHOTOEMISSION_TUBE"
   ],
   [
    "协议棱柱组",
    "SupplyPlanLimit_PROTOHEDRON"
   ],
   [
    "协议棱柱",
    "SupplyPlanLimit_PROTOPRISM"
   ],
   [
    "折金票",
    "SupplyPlanLimit_T_CREDS"
   ],
   [
    "武器经验",
    "SupplyPlanLimit_WEAPON_EXP"
   ],
   [
    "重型强固模具",
    "SupplyPlanLimit_HEAVY_CAST_DIE"
   ],
   [
    "强固模具",
    "SupplyPlanLimit_CAST_DIE"
   ]
  ]
 }
}
"""#
