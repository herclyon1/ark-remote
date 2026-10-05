"""The replay step table: every page and button of ark-remote, in the order of the manual passes.

Each step is a dict:
  id       unique id (for --from / --to)
  page     group for --only
  say      what the step does, in Chinese (printed as 「步骤 → 对 / 不对」)
  on       "both" (default) | "ios" | "android"
  do       list of actions (run in order):
             ("tap", sel[, opts])      tap the element; scrolls to find it.  opts: region any|content|top|bottom, nth,
                                        last (take the last match), right=<px from the right edge>, hold=<ms>, scroll=False
             ("tab", name)             tap the bottom tab
             ("toggle", sel)           tap the switch on the row whose text matches sel
             ("field", sel, text)      tap the text field on the row matching sel (or the field itself), clear it, type text
             ("enter",) / ("hidekb",)  submit / put the keyboard away (iOS: the keyboard toolbar's 完成; Android: back)
             ("swipe", "up"|"down", n) scroll the content (up = the content moves up)
             ("top", n) / ("back",) / ("wait", s) / ("relaunch",)
             ("state", variant)        publish a machine state to the throwaway mailbox: base | dup | noef
             ("receipt", action, queued, ok)  publish base + a receipt for the newest command of that action the app sent
             ("clear_receipts",)       forget the receipts added by ("receipt", ...)
             ("hb", n)                 heartbeat "hb n" (the app counts the machine on for 2n+30 s)
             ("remember", sel, key)    keep the element's centre for ("gate", ...)
             ("gate", key1, key2, gap_ms, hold_ms)   tap key1, after gap_ms press key2 for hold_ms (the 400 ms guard)
  expect   selectors that must be present (polled until timeout)
  absent   selectors that must be gone
  visible  selectors that must be on screen inside the content area (D39 scroll-to-top)
  keyboard True / False: the keyboard must be up / down
  cmd      command(s) the app must have sent to the throwaway mailbox during the step: a dict (body fields) or "~text"
  nocmd    seconds: nothing but refresh / watch may be sent during this many seconds
  timeout  seconds for expect (default --timeout)
  ios / android   overrides merged into the step on that platform

Selectors: "exact text" | "~substring" | "re:regex" | [alternatives] |
           {"t": ..., "kind": "Switch", "region": "content", "nth": 1, "after": "<anchor text>", "count": 2}
On iOS the texts are accessibility labels / values; on Android uiautomator text and content-desc.
"""

# chrome controls (iOS accessibility label, Android content-desc as seen in pass 1)
SAVE = ["完成", "checkmark"]                 # the ✓ of the save bar (EWLive.swift:473) - also the picker pages' ✓
DISCARD = ["放弃", "xmark"]                  # the ✕ (EWLive.swift:463)
PLUS = ["Increment", "增加", "+"]
MINUS = ["Decrement", "减少", "-", "−"]
CLEAR = "不等了，清掉"
TAB_EF = {"t": "终末地", "region": "bottom"}
STATUS_ROOT = "现在跑一趟"


def tap(sel, **opts):
    return ("tap", sel, opts) if opts else ("tap", sel)


S = []


def step(id, page, say, do=(), **kw):
    d = {"id": id, "page": page, "say": say, "do": list(do)}
    d.update(kw)
    S.append(d)


# ------------------------------------------------------------------ setup
step("setup.launch", "setup", "冷启动（一次性信箱已写好）→ 状态页数据齐、设备卡「开机中」",
     [("relaunch",)], expect=[STATUS_ROOT, "刷新", "停止一切", "这一趟", "~开机中"], timeout=45, always=True)

# ------------------------------------------------------------------ status page
step("status.refresh", "status", "状态 · 刷新 → 寄出 refresh，设备卡仍「开机中」",
     [tap("刷新"), ("state", "base")], expect=["~开机中"], cmd={"action": "refresh"})
step("status.runnow.ask", "status", "状态 · 现在跑一趟 → 弹「现在跑一趟？」",
     [tap(STATUS_ROOT)], expect=["现在跑一趟？", "跑一趟"])
step("status.runnow.go", "status", "弹窗 · 跑一趟 → 寄出 run_now",
     [tap("跑一趟", last=True)], absent=["现在跑一趟？"], cmd={"action": "run_now"})
step("status.stop.ask", "status", "状态 · 停止一切 → 弹「停止一切？」",
     [tap("停止一切")], expect=["停止一切？"])
step("status.stop.cancel", "status", "弹窗 · 取消 → 关掉，没寄出",
     [tap("取消", last=True)], absent=["停止一切？"], nocmd=3)
step("status.4c.menu", "status", "刷 4C 声骸 · 打哪个 → 菜单列出 boss",
     [tap("刷 4C 声骸 · 打哪个")], expect=["re:^3\\. "])
step("status.4c.pick", "status", "菜单 · 选第 3 个 boss → 菜单收起，行显示第 3 个",
     [tap("re:^3\\. ", last=True)], expect=["re:^3\\. "], absent=[{"t": "re:^4\\. "}])
step("status.until.bad", "status", "刷到几点 填 25:00 → 回车 → 提示「时刻填成 08:30 这种」、框退回 08:30",
     [("field", "刷到几点（机器时间）", "25:00"), ("enter",)], expect=["~时刻填成 08:30 这种"], timeout=6,
     android={"do": [("field", "刷到几点（机器时间）", "25:00"), ("hidekb",), tap(STATUS_ROOT, scroll=False)]})
step("status.until.reset", "status", "刷到几点 框是 08:30", [("hidekb",)], expect=["08:30"])
step("status.echo.ask", "status", "开始刷 → 弹「开始刷？」",
     [tap("开始刷", region="content")], expect=["开始刷？"])
step("status.echo.go", "status", "弹窗 · 开始刷 → 寄出 echo_farm（第 3 个，到 08:30）",
     [tap("开始刷", last=True)], absent=["开始刷？"], cmd={"action": "echo_farm"})
step("status.keepon.discard", "status", "下次跑完不关机 打开 → 待保存 1 项 → ✕ 放弃 → 回原样、没寄出",
     [("state", "base"), ("toggle", "下次跑完不关机"), ("wait", 0.6), tap(DISCARD, region="top")],
     absent=["~待保存"], nocmd=2)
step("status.two.pending", "status", "下次跑完不关机 + 调试模式 打开 → 标题「待保存 2 项」",
     [("toggle", "下次跑完不关机"), ("toggle", "调试模式")], expect=["~待保存 2 项"])
step("status.two.review", "status", "✓ → 确认单两行、「寄出 2 项」",
     [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("status.two.send", "status", "寄出 2 项 → 寄出 skip_shutdown + debug_mode，行变「已寄出」",
     [("wait", 0.5), tap("寄出 2 项")], absent=["确认这次修改"], expect=["~已寄出"],
     cmd=[{"action": "skip_shutdown"}, {"action": "debug_mode"}])
step("status.queued", "status", "D207：机器回「排队」回执 → 行下「排队中 · 跑完执行」",
     [("receipt", "skip_shutdown", True)], expect=["~排队中 · 跑完执行"], timeout=25)
step("status.queued.final", "status", "机器回最终回执 → 「排队中」消失",
     [("receipt", "skip_shutdown", False)], absent=["~排队中 · 跑完执行"], timeout=25)
step("status.clear", "status", "顶上条「不等了，清掉」→ 待回执全清",
     [("clear_receipts",), ("state", "base"), tap(CLEAR)], absent=[CLEAR, "~已寄出"], timeout=10)
step("status.skip.pending", "status", "早班开关关掉 → 「今天跳过，明天照常」+ 待保存 1 项",
     [("toggle", "re:^早班 · ")], expect=["~今天跳过，明天照常", "~待保存 1 项"])
step("status.skip.review", "status", "✓ → 确认单红字「今天不跑：早班」",
     [("remember", SAVE, "save"), tap(SAVE, region="top")], expect=["确认这次修改", "~今天不跑：早班", "寄出 1 项"])
step("status.skip.think", "status", "再想想 → 关单，改动还在",
     [("remember", "寄出 1 项", "send"), ("wait", 0.3), tap("再想想")], absent=["确认这次修改"], expect=["~待保存 1 项"], nocmd=2)

# ------------------------------------------------------------------ 400 ms confirmation guard
step("gate.early", "gate", "400 ms 门：✓ 后 150 ms 按下「寄出」按住 0.9 秒 → 不寄出、单子还在",
     [("gate", "save", "send", 150, 900)], expect=["确认这次修改"], nocmd=3)
step("gate.close", "gate", "再想想 → 关单", [tap("再想想")], absent=["确认这次修改"])
step("gate.late", "gate", "✓ 后 900 ms 再点「寄出」→ 寄出 skip_today",
     [("gate", "save", "send", 900, 60)], absent=["确认这次修改"], cmd={"action": "skip_today"}, timeout=6)
step("gate.clear", "gate", "不等了，清掉 → 早班开关回到开",
     [tap(CLEAR)], absent=[CLEAR], expect=["~今天照常"])

# ------------------------------------------------------------------ heartbeat / machine off
step("status.off", "status", "心跳过期 → 设备卡「关机」",
     [("hb", 1), ("wait", 33)], expect=["~关机"], timeout=25)
step("status.off.stop", "status", "关机时按停止一切 → 提示「所以这次没有发」，没寄出",
     [tap("停止一切")], expect=["~所以这次没有发"], nocmd=2)
step("status.off.ok", "status", "好 → 关提示；心跳回来 → 「开机中」",
     [tap("好", last=True), ("hb", 300), ("state", "base"), tap("刷新")], expect=["~开机中"], timeout=20)

# ------------------------------------------------------------------ shifts
step("shift.night", "shift", "班次切「晚班」→ 只剩明日方舟，底栏没有终末地",
     [tap("晚班")], expect=["~晚班 · 下一趟"], absent=[TAB_EF])
step("shift.morning", "shift", "切回「早班」→ 五个标签回来", [tap("早班", region="content")], expect=[TAB_EF])

# ------------------------------------------------------------------ receipts + D39 on 状态
step("receipts.open", "receipts", "查看全部 → 回执页",
     [tap("~查看全部")], expect=["回执"], absent=[STATUS_ROOT])
step("receipts.tabpop", "d39", "D39：在回执页再点「状态」→ 回到状态根页",
     [("tab", "状态")], expect=[STATUS_ROOT])
step("receipts.back", "receipts", "再进查看全部 → 返回键回来", [tap("~查看全部"), ("wait", 0.8), ("back",)], expect=[STATUS_ROOT])
step("receipts.reenter", "d39", "回来后再进查看全部 → 进得去", [tap("~查看全部")], expect=["回执"], absent=[STATUS_ROOT])
step("receipts.leave", "receipts", "点「状态」回根页", [("tab", "状态")], expect=[STATUS_ROOT])
step("d39.status.top", "d39", "D39：状态根页滑到底再点「状态」→ 回到顶",
     [("swipe", "up", 4), ("tab", "状态"), ("wait", 1.2)], visible=["~开机中"], timeout=6)

# ------------------------------------------------------------------ 月卡
step("mc.open", "monthcard", "终末地月卡行 → 月卡页",
     [tap({"t": "终末地", "after": "调试模式"})], expect=["终末地月卡", "最后一次领取"])
step("mc.plus", "monthcard", "＋ → 充值了 2 次", [tap(PLUS)], expect=["充值了 2 次"])
step("mc.minus", "monthcard", "－ → 回到 1 次", [tap(MINUS)], expect=["充值了 1 次"])
step("mc.register.ask", "monthcard", "登记 → 弹「登记充值 1 次？」", [tap("登记", region="content")], expect=["登记充值 1 次？"])
step("mc.register.cancel", "monthcard", "取消 → 没寄出", [tap("取消", last=True)], absent=["登记充值 1 次？"], nocmd=2)
step("mc.align.empty", "monthcard", "天数空着按「对准」→ 提示「填 0–400 的整数」",
     [tap("对准", region="content")], expect=["~填 0–400 的整数"], timeout=5)
step("mc.days", "monthcard", "天数填 15 → 收键盘（iOS 完成键）",
     [("field", "游戏里显示还剩", "15"), ("hidekb",)], keyboard=False)
step("mc.align.ask", "monthcard", "对准 → 弹「对准为还剩 15 天？」", [tap("对准", region="content")], expect=["对准为还剩 15 天？"])
step("mc.align.go", "monthcard", "弹窗 · 对准 → 寄出 monthcard left 15，页面变 15 天",
     [tap("对准", last=True)], expect=["15 天"], absent=["对准为还剩 15 天？"],
     cmd={"action": "monthcard", "left": 15, "game": "终末地"})
step("mc.tabpop", "d39", "点「状态」→ 月卡页退掉、回根页", [("tab", "状态")], expect=[STATUS_ROOT])

# ------------------------------------------------------------------ 方舟
step("ark.open", "arknights", "方舟标签 → 关卡 / 理智药 / 作战开关", [("tab", "方舟")], expect=["关卡", "理智药", "作战开关"])
step("ark.sanity.bad", "arknights", "理智药填 1000 → 提示「要填 0–999 的整数」",
     [("field", "理智药", "1000"), ("hidekb",)], expect=["~要填 0–999 的整数"], timeout=5,
     android={"do": [("field", "理智药", "1000"), ("hidekb",), tap(SAVE, region="top"), ("wait", 1.0), tap("~寄出")],
              "expect": ["~一项都没寄出"]})
step("ark.sanity.bad.close", "arknights", "关掉提示，没寄出", [], nocmd=1,
     android={"do": [tap("好", last=True), ("wait", 0.5)], "absent": ["~一项都没寄出"]})
step("ark.edit4", "arknights", "理智药 2、关卡 CE-6、邮件开关、基建「赤金」→ 待保存 4 项",
     [("field", "理智药", "2"), ("field", "关卡", "CE-6"), ("hidekb",), ("toggle", "领取所有邮件奖励"),
      tap("无人机用在哪"), ("wait", 0.8), tap("~赤金", last=True)],
     expect=["~待保存 4 项"])
step("ark.review", "arknights", "✓ → 确认单「寄出 4 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 4 项"])
step("ark.send", "arknights", "寄出 → set_master 赤金 / 邮件 + set_config 理智药 2 / CE-6",
     [("wait", 0.5), tap("寄出 4 项")], absent=["确认这次修改"],
     cmd=["~PureGold", "~Mail", "~MedicineNumb", "~CE-6"])
step("ark.battle.discard", "arknights", "作战开关切换 → 待保存 → ✕ 放弃 → 回原值",
     [tap(CLEAR), ("toggle", "作战开关"), ("wait", 0.6), tap(DISCARD, region="top")], absent=["~待保存"], nocmd=2)
step("d39.ark.top", "d39", "D39：方舟滑到底再点「方舟」→ 回顶",
     [("swipe", "up", 4), ("tab", "方舟"), ("wait", 1.2)], visible=["关卡"])

# ------------------------------------------------------------------ 终末地
step("ef.open", "endfield", "终末地标签 → 库存 / 更多设置 / 「另一个任务」",
     [("tab", "终末地")], expect=["库存", "更多设置"])
step("ef.title", "endfield", "卡片标题是「终末地 · 另一个任务」（不是「另外两个」）",
     [("swipe", "up", 3)], expect=["~另一个任务"], absent=["~另外两个任务"])
step("ef.stock", "endfield", "库存 → 推入库存页（没配森空岛）",
     [("top", 4), tap("库存")], expect=["~森空岛"], timeout=10)
step("ef.stock.tophone", "endfield", "库存页「去手机页」→ 跳到手机标签", [tap("~去手机页")], expect=["页面版本"])
step("ef.stock.popped", "d39", "回终末地 → 库存页已退掉", [("tab", "终末地")], expect=["库存", "更多设置"])
step("ef.stock.tabpop", "d39", "再进库存 → 点「终末地」→ 回根页",
     [tap("库存"), ("wait", 1.0), ("tab", "终末地")], expect=["库存", "更多设置"], absent=["~去手机页"])
step("ef.more", "endfield", "更多设置 → 推入页「执行周期」", [tap("更多设置")], expect=["~执行周期"])
step("ef.days", "endfield", "执行周期 → 选择页 周一…周日", [tap("~执行周期")], expect=["周一", "周日"])
step("ef.days.untick", "endfield", "去掉周日（安卓旧闪退点）→ 不闪退", [tap("周日")], expect=["周日"])
step("ef.days.done", "endfield", "✓ → 回推入页「已选 6/7」「待保存 1 项」",
     [tap(SAVE, region="top")], expect=["~6/7", "~待保存 1 项"])
step("ef.more.tabpop", "d39", "点「终末地」→ 更多设置页退掉、回根页", [("tab", "终末地")], expect=["库存"], absent=["周日"])
step("ef.mode", "endfield", "刷取设置菜单 → 地区模式 → 待保存 2 项",
     [tap("刷取设置"), ("wait", 0.8), tap("~地区模式", last=True)], expect=["~待保存 2 项"])
step("ef.review", "endfield", "✓ → 确认单「寄出 2 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("ef.send", "endfield", "寄出 → set_master 执行周期 / 刷取设置",
     [("wait", 0.5), tap("寄出 2 项")], absent=["确认这次修改"], cmd=["~AutoEssence"])
step("ef.protocol", "endfield", "协议空间 选「武器养成」→ 待保存 → ✕ 放弃",
     [tap(CLEAR), tap("~干员养成"), ("wait", 0.8), tap("~武器养成", last=True), ("wait", 0.6), tap(DISCARD, region="top")],
     absent=["~待保存"], nocmd=2)
step("ef.collect.more", "endfield", "自动采集 · 更多设置 → 推入页 → 返回",
     [tap({"t": "更多设置", "after": "自动采集"}), ("wait", 1.0), ("back",)], expect=["库存"], timeout=10)

# ------------------------------------------------------------------ 鸣潮
step("ww.open", "wuwa", "鸣潮标签 → 无音区 / 周本", [("tab", "鸣潮")], expect=["~无音区", "周本打第几个"])
step("ww.tacet", "wuwa", "刷第几个无音区（安卓旧闪退点）→ 选择页 7 行", [tap("~刷第几个无音区")], expect=["~雪落无声之愿", "~长路启航之星"])
step("ww.tacet.pick", "wuwa", "选第 5 个 → ✓ → 待保存 1 项",
     [tap("~雪落无声之愿"), ("wait", 0.4), tap(SAVE, region="top")], expect=["~待保存 1 项"])
step("ww.boss.bad", "wuwa", "周本填 251 → 提示「要填 1–20」",
     [("field", "周本打第几个", "251"), ("hidekb",)], expect=["~要填 1–20"], timeout=5,
     android={"do": [("field", "周本打第几个", "251"), ("hidekb",), tap(SAVE, region="top"), ("wait", 1.0), tap("~寄出")],
              "expect": ["~要填 1–20"]})
step("ww.boss.fix", "wuwa", "周本改 13 → 待保存 2 项",
     [("field", "周本打第几个", "13"), ("hidekb",)], expect=["~待保存 2 项"],
     android={"do": [tap("好", last=True), ("wait", 0.5), ("field", "周本打第几个", "13"), ("hidekb",)]})
step("ww.review", "wuwa", "✓ → 确认单「寄出 2 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("ww.send", "wuwa", "寄出 → set_master 无音区 + weekly_boss 13",
     [("wait", 0.5), tap("寄出 2 项")], absent=["确认这次修改"], cmd=[{"action": "weekly_boss"}, {"action": "set_master"}])
step("ww.clear", "wuwa", "不等了，清掉", [tap(CLEAR)], absent=[CLEAR])
step("d39.ww.top", "d39", "D39：鸣潮滑到底再点「鸣潮」→ 回顶",
     [("swipe", "up", 4), ("tab", "鸣潮"), ("wait", 1.2)], visible=["~无音区"])

# ------------------------------------------------------------------ 手机
step("ph.open", "phone", "手机标签 → 页面版本 / 诊断记录 / 「密钥」行",
     [("tab", "手机")], expect=["页面版本", "诊断记录", "复制免输入链接", "密钥"], absent=["已配置"])
step("ph.diag.on", "phone", "诊断记录打开 → 分享 / 清空 / 运行自检 / 就是这里",
     [("toggle", "诊断记录")], expect=["~分享诊断记录", "清空诊断记录", "运行自检", "就是这里"])
step("ph.selftest", "phone", "运行自检 → 结果单「通过 N / 6」",
     [tap("运行自检")], expect=["re:通过 \\d+ ?/ ?\\d+"], timeout=30)
step("ph.selftest.close", "phone", "关掉自检结果", [tap(["关闭", "好"], last=True)], absent=["re:通过 \\d+ ?/ ?\\d+"])
step("ph.clear.ask", "phone", "清空诊断记录 → 弹确认 → 取消", [tap("清空诊断记录"), ("wait", 0.8), tap("取消", last=True)],
     absent=["清空诊断记录？"])
step("ph.share", "phone", "分享诊断记录 → 系统分享面板 → 关掉",
     [tap("~分享诊断记录"), ("wait", 2.0), ("back",)], expect=["运行自检"], timeout=10,
     ios={"do": [tap("~分享诊断记录"), ("wait", 2.0), tap(["关闭", "Close"], last=True)]})
step("ph.copylink", "phone", "复制免输入链接 → 「链接已复制」", [tap("复制免输入链接")], expect=["~链接已复制"], timeout=5)
step("ph.paste.bad", "phone", "粘贴密钥串 填乱码 → 存 → 「没存上」",
     [tap("粘贴密钥串"), ("wait", 1.0), ("field", {"t": "", "kind": ["TextField", "EditText"]}, "zzz"), tap("存")],
     expect=["没存上"], timeout=6)
step("ph.paste.close", "phone", "关掉提示和粘贴单", [tap("好", last=True), ("wait", 0.6), tap("取消")], expect=["页面版本"])
step("ph.diag.off", "phone", "诊断记录关掉 → 多出的行收起", [("toggle", "诊断记录")], absent=["运行自检", "就是这里"])

# ------------------------------------------------------------------ shift change while on a gone tab (pass-1 item 6, fix 5)
step("noef.jump", "layout", "人在终末地，机器发来早班不含终末地的状态（实时分片，不刷新）→ 终末地标签消失、跳到状态",
     [("tab", "终末地"), ("wait", 1.0), ("state", "noef")], expect=[STATUS_ROOT], absent=[TAB_EF], timeout=30)
step("noef.back", "layout", "机器发回原状态 → 终末地标签回来，App 留在状态",
     [("state", "base"), ("wait", 6)], expect=[TAB_EF, STATUS_ROOT], timeout=30)

# ------------------------------------------------------------------ duplicate receipts (pass-1 item 5, fix 3)
step("dup.status", "receipts", "同一分钟两条一样的回执 → 状态页两行都在、不崩",
     [("state", "dup"), tap("刷新")], expect=[{"t": "周本：打第 2 个", "count": 2}], timeout=25)
step("dup.page", "receipts", "查看全部 → 回执页也有这两行（不是旧数据）",
     [tap("~查看全部")], expect=["回执", {"t": "周本：打第 2 个", "count": 2}], timeout=10)
step("dup.done", "receipts", "回状态，发回原状态", [("tab", "状态"), ("state", "base")], expect=[STATUS_ROOT])

STEPS = S
