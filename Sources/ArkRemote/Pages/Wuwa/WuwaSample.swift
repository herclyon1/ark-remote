// Demo data for the OK-WW page: the web page's DEMO_MASTER["OK-WW"]
// (maa-automation/web/view.js:2356, read from relay fixtures by mastercfg.read_maaend / OK-WW defaults).
// Same shape as snap.master["OK-WW"] in the relay's status packet, so the real feed decodes the same way.

import Foundation

extension EWMaster {
    static let wuwaSample: EWMaster = EWMaster(jsonString: wuwaSampleJSON) ?? EWMaster()
}

private let wuwaSampleJSON = #"""
{
 "values": {
  "DailyTask.json/Which to Farm": "Tacet Suppression",
  "DailyTask.json/Material Selection": "Shell Credit",
  "DailyTask.json/Which Forgery Challenge to Farm": 3,
  "DailyTask.json/Which Tacet Suppression to Farm": 2
 },
 "options": {
  "DailyTask.json/Which to Farm": [
   [
    "凝素领域",
    "Forgery Challenge"
   ],
   [
    "无音区",
    "Tacet Suppression"
   ],
   [
    "模拟领域",
    "Simulation Challenge"
   ]
  ],
  "DailyTask.json/Material Selection": [
   [
    "Resonator EXP",
    "Resonator EXP"
   ],
   [
    "Weapon EXP",
    "Weapon EXP"
   ],
   [
    "Shell Credit",
    "Shell Credit"
   ]
  ]
 },
 "labels": {},
 "readonly": {
  "NightmareNestTask.json/Only Farm These Nests": "落渊南丘"
 }
}
"""#
