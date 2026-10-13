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
             ("state", variant)        publish a machine state to the throwaway mailbox: base | dup | noef | farm | times
                                       (--offline: written into the app's cache ark-remote-cfg-snap, app relaunched)
             ("time", label, h, m)     iOS DatePicker: open the capsule, turn the wheels to h:m, close it by a tap outside
             ("dismiss",)              close a sheet / alert / notice (再想想, 取消, 好) and throw edits away (✕)
             ("receipt", action, queued, ok)  publish base + a receipt for the newest command of that action the app sent
             ("clear_receipts",)       forget the receipts added by ("receipt", ...)
             ("hb", n)                 heartbeat "hb n" (the app counts the machine on for 2n+30 s)
             ("remember", sel, key)    keep the element's centre for ("gate", ...)
             ("gate", key1, key2, gap_ms, hold_ms)   tap key1, after gap_ms press key2 for hold_ms (the 400 ms guard)
             ("gate_trials", n, gap_ms, hold_ms)     Android: n timed raw-touch trials of the guard (run.py gate_trials)
             ("app_posts", {step id: n})  the app's own send log (诊断记录 on): 0 = no POST to the mailbox during that
                                       step, n = at least n (the log must have been saved: open 分享诊断记录 first)
  expect   selectors that must be present (polled until timeout)
  absent   selectors that must be gone
  visible  selectors that must be on screen inside the content area (D39 scroll-to-top)
  keyboard True / False: the keyboard must be up / down
  cmd      command(s) the app must have sent to the throwaway mailbox during the step: a dict (body fields) or "~text"
  nocmd    seconds: nothing but refresh / watch may be sent during this many seconds
  timeout  seconds for expect (default --timeout)
  ios / android   overrides merged into the step on that platform
  offline  overrides merged with --offline (ntfy quota spent: no heartbeat, states injected into the app's cache).
           Without one, a step with cmd runs everything but its last tap, closes what is open (dismiss) and reads
           「跳过（额度）」
  skip     reason: the step is not judged, it only runs (「跳过（reason）」)
  nojudge / nojudge_fail   reason: never judged / judged 对 when it passes, 「不判（reason）」 when it fails
  below    [[upper sel, lower sel], ...]: the lower element starts under the upper one's bottom edge
  last_above sel / last_bottom [lo, hi]: the page's last line ends above sel's top edge / inside the range

Selectors: "exact text" | "~substring" | "re:regex" | [alternatives] |
           {"t": ..., "kind": "Switch", "region": "content", "nth": 1, "after": "<anchor text>", "count": 2}
On iOS the texts are accessibility labels / values; on Android uiautomator text and content-desc.
"""

# chrome controls (iOS accessibility label, Android content-desc as seen in pass 1)
SAVE = ["完成", "checkmark"]                 # the ✓ of the save bar (EWLive.swift:473) - also the picker pages' ✓
DISCARD = ["放弃", "xmark"]                  # the ✕ (EWLive.swift:463)
PLUS = ["Increment", "增加", "+", "re:, Increment$"]      # iOS 27 Stepper halves: 「充值了 1 次, Increment」
MINUS = ["Decrement", "减少", "-", "−", "re:, Decrement$"]
CLEAR = "不等了，清掉"
TAB_EF = {"t": "终末地", "region": "bottom"}
STATUS_ROOT = "现在跑一趟"
# a tab's root page (title, no back button). 现在跑一趟 is only in the tree near the top of the lazy list
HOME = {"t": "游戏机遥控", "kind": ["StaticText", "TextView"]}
BACK_BTN = {"t": "游戏机遥控", "kind": "Button"}
CONFIRM_WAIT = ("wait", 0.5)                 # confirm alerts / review sheets ignore a press in their first 400 ms
OFF_NOTE = "~所以这次没有发"                  # the 「机器关着」 notice (StatusCommands.swift:69, :102)
SEND_N = "re:^寄出 \\d+ 项$"

import mailbox as _mb                        # noqa: E402  (the injected farm's end, machine time)
FARM_HHMM = _mb.farm_until_hhmm()


def tap(sel, **opts):
    return ("tap", sel, opts) if opts else ("tap", sel)


S = []


def step(id, page, say, do=(), **kw):
    d = {"id": id, "page": page, "say": say, "do": list(do)}
    d.update(kw)
    S.append(d)


# ------------------------------------------------------------------ setup
step("setup.launch", "setup", "冷启动（一次性信箱已写好）→ 状态页数据齐、设备卡「开机中」",
     [("relaunch",)], expect=[STATUS_ROOT, "刷新", "停止一切", "这一趟", "~开机中"], timeout=45, always=True,
     offline={"say": "冷启动（一次性信箱 + 缓存注入的状态）→ 状态页数据齐、设备卡「关机」（离线没有心跳）",
              "expect": [STATUS_ROOT, "刷新", "停止一切", "这一趟", "~关机"]})

# ------------------------------------------------------------------ status page
step("status.refresh", "status", "状态 · 刷新 → 寄出 refresh，设备卡仍「开机中」",
     [tap("刷新")], expect=["~开机中"], cmd={"action": "refresh"})
step("status.runnow.ask", "status", "状态 · 现在跑一趟 → 弹「现在跑一趟？」",
     [tap(STATUS_ROOT)], expect=["现在跑一趟？", "跑一趟"])
step("status.runnow.go", "status", "弹窗 · 跑一趟（等过 400 ms 门）→ 寄出 run_now",
     [CONFIRM_WAIT, tap("跑一趟", last=True)], absent=["现在跑一趟？"], cmd={"action": "run_now"})
step("status.stop.ask", "status", "状态 · 停止一切 → 弹「停止一切？」",
     [tap("停止一切")], expect=["停止一切？"],
     offline={"say": "状态 · 停止一切（关机）→ 提示「机器关着…所以这次没有发」", "expect": [OFF_NOTE]})
step("status.stop.cancel", "status", "弹窗 · 取消 → 关掉，没寄出",
     [CONFIRM_WAIT, tap("取消", last=True)], absent=["停止一切？"], nocmd=3,
     offline={"say": "提示 · 好 → 关掉", "do": [CONFIRM_WAIT, tap("好", last=True)], "absent": [OFF_NOTE]})
step("status.4c.menu", "status", "刷 4C 声骸 · 打哪个（点当前值）→ 菜单列出 boss",
     [tap({"t": "re:^\\d\\. ", "kind": ["StaticText", "TextView"]})], expect=["re:^3\\. "])
step("status.4c.pick", "status", "菜单 · 选第 3 个 boss → 菜单收起，行显示第 3 个",
     [tap("re:^3\\. ", last=True)], expect=["re:^3\\. "], absent=[{"t": "re:^4\\. "}])
step("status.until.2330", "status", "刷到几点 · 点胶囊拨转盘 23 / 30 → 点外面关掉 → 胶囊「23:30」（796103b）",
     [("time", "刷到几点", 23, 30)], expect=["23:30"], absent=[{"t": "", "kind": "PickerWheel"}],
     android={"say": "刷到几点 · 点时间 → 系统时间对话框拨 23:30 → 返回 → 行上「11:30 PM」/「23:30」（跟手机 12/24 小时）",
              "expect": ["re:^(23:30|11:30 PM)$"], "absent": []})
step("status.until.0005", "status", "刷到几点 · 拨 0 / 05 → 胶囊「0:05」（系统按地区不补零，存进去是 00:05，已知存疑）",
     [("time", "刷到几点", 0, 5)], expect=["re:^0?0:05$"],
     android={"say": "刷到几点 · 拨 00:05 → 行上「12:05 AM」/「00:05」", "expect": ["re:^(00:05|12:05 AM)$"]})
step("status.echo.ask", "status", "开始刷 → 弹「开始刷？」（到 00:05）",
     [tap("开始刷", region="content")], expect=["开始刷？", "~00:05"],
     offline={"say": "开始刷（关机）→ 提示「机器关着…所以这次没有发」", "expect": [OFF_NOTE]})
step("status.echo.go", "status", "弹窗 · 开始刷（等过 400 ms 门）→ 寄出 echo_farm（第 3 个，到 00:05）",
     [CONFIRM_WAIT, tap("开始刷", last=True)], absent=["开始刷？"], cmd={"action": "echo_farm", "boss": 3, "until": "00:05"},
     offline={"say": "提示 · 好 → 关掉", "do": [CONFIRM_WAIT, tap("好", last=True)], "absent": [OFF_NOTE]})
step("status.keepon.discard", "status", "下次跑完不关机 打开 → 待保存 1 项 → ✕ 放弃 → 回原样、没寄出",
     [("retry", 2, [("toggle", "下次跑完不关机")], ("until", DISCARD, 5, {"region": "top"})), tap(DISCARD, region="top")],
     absent=["~待保存"], nocmd=2, switch={"下次跑完不关机": False})
step("status.keepon.think", "status", "下次跑完不关机 打开 → ✓ → 确认单 → 再想想 → ✕ → 开关回到关",
     [("retry", 2, [("toggle", "下次跑完不关机")], ("until", SAVE, 5, {"region": "top"})), tap(SAVE, region="top"),
      ("until", "再想想", 6), CONFIRM_WAIT, tap("再想想"), ("gone", "确认这次修改", 6),
      tap(DISCARD, region="top")], absent=["~待保存", "确认这次修改"], switch={"下次跑完不关机": False}, nocmd=2)
step("status.two.pending", "status", "下次跑完不关机 + 调试模式 打开 → 标题「待保存 2 项」",
     [("toggle", "下次跑完不关机"), ("toggle", "调试模式")], expect=["~待保存 2 项"])
step("status.two.review", "status", "✓ → 确认单两行、「寄出 2 项」",
     [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("status.two.send", "status", "寄出 2 项 → 寄出 skip_shutdown + debug_mode，行变「已寄出」",
     [CONFIRM_WAIT, tap("寄出 2 项")], absent=["确认这次修改"], expect=["~已寄出"],
     cmd=[{"action": "skip_shutdown"}, {"action": "debug_mode"}])
step("status.queued", "status", "D207：机器回「排队」回执 → 行下「排队中 · 跑完执行」",
     [("receipt", ["skip_shutdown", "debug_mode"], True)], expect=["~排队中 · 跑完执行"], timeout=25,
     offline={"do": [], "expect": [], "skip": "额度"})
step("status.queued.final", "status", "机器回最终回执 → 「排队中」消失",
     [("receipt", ["skip_shutdown", "debug_mode"], False)], absent=["~排队中 · 跑完执行"], timeout=25,
     offline={"do": [], "absent": [], "skip": "额度"})
step("status.clear", "status", "顶上条「不等了，清掉」→ 待回执全清",
     [("clear_receipts",), ("state", "base"), tap(CLEAR)], absent=[CLEAR, "~已寄出"], timeout=10,
     offline={"do": [], "absent": [], "skip": "额度"})
step("status.skip.pending", "status", "早班开关关掉 → 「今天跳过，明天照常」+ 待保存 1 项",
     [("toggle", "re:^早班 · \\d")], expect=["~今天跳过，明天照常", "~待保存 1 项"])
step("status.skip.review", "status", "✓ → 确认单红字「今天不跑：早班」",
     [("remember", SAVE, "save", {"region": "top"}), tap(SAVE, region="top")], expect=["确认这次修改", "~今天不跑：早班", "寄出 1 项"])
step("status.skip.think", "status", "再想想 → 关单，改动还在",
     [("remember", "寄出 1 项", "send"), ("wait", 0.3), tap("再想想")], absent=["确认这次修改"], expect=["~待保存 1 项"], nocmd=2)

# ------------------------------------------------------------------ 400 ms confirmation guard
# Android: judged by the app's own send log (诊断记录, turned on for this block only) and the mailbox; each early press is
# timed against the sheet window's first frame (gate_trials). iOS: 寄出 is .disabled for 400 ms, one early press; a sheet
# still up afterwards is 对; gone is 「不判（模拟器）」 (the press may have landed after the gate on a slow simulator).
step("gate.diag.on", "gate", "手机 · 诊断记录打开（门测试用 App 自己的发送记录判断）→ 回状态",
     [("tab", "手机"), ("toggle", "诊断记录"), ("tab", "状态")], expect=[STATUS_ROOT, "~待保存 1 项"], on="android")
step("gate.early", "gate", "400 ms 门：✓ 后 150 ms 按下「寄出」按住 0.9 秒 → 不寄出、单子还在",
     [("gate", "save", "send", 150, 900)], expect=["确认这次修改"], nocmd=3, nojudge_fail="模拟器",
     android={"say": "400 ms 门：✓ 后马上按住「寄出」1.5 秒（按下早于门开、松手晚于门开）× 2 → 一次都不寄出",
              "do": [("gate_trials", 2, 150, 1500)], "expect": ["~待保存 1 项"], "absent": ["确认这次修改"],
              "nocmd": 1, "timeout": 12, "nojudge": "模拟器"})
step("gate.close", "gate", "再想想 → 关单", [tap("再想想")], absent=["确认这次修改"], on="ios")
step("gate.late", "gate", "✓ 等单子停稳再点「寄出」→ 寄出 skip_today",
     [tap(SAVE, region="top"), tap("寄出 1 项", stable=True)], absent=["确认这次修改"], cmd={"action": "skip_today"},
     timeout=10)
step("gate.clear", "gate", "不等了，清掉 → 早班开关回到开",
     [tap(CLEAR)], absent=[CLEAR], expect=["~今天照常"],
     offline={"say": "（上一步已放弃改动）早班开关回到开、没有待保存", "do": [], "absent": ["~待保存"]})
step("gate.diag.check", "gate", "App 自己的发送记录（打开分享诊断记录让它存盘）：门测试 0 条、停稳后寄出 ≥1 条",
     [("tab", "手机"), tap("~分享诊断记录"), ("wait", 1.5), ("back",), ("app_posts", {"gate.early": 0, "gate.late": 1})],
     expect=["运行自检"], on="android", nojudge="模拟器")
step("gate.diag.off", "gate", "手机 · 诊断记录关掉 → 回状态",
     [("toggle", "诊断记录"), ("tab", "状态")], expect=[STATUS_ROOT], on="android")

# ------------------------------------------------------------------ heartbeat / machine off
step("status.off", "status", "心跳过期 → 设备卡「关机」",
     [("hb", 1), ("wait", 33), ("top", 5)], expect=["~关机"], timeout=25,
     offline={"say": "没有心跳 → 设备卡「关机」（离线：一次性信箱没有心跳）", "do": [("top", 5)]})
step("status.off.stop", "status", "关机时按停止一切 → 提示「所以这次没有发」，没寄出",
     [tap("停止一切")], expect=[OFF_NOTE], nocmd=2)
step("status.off.ok", "status", "好 → 关提示；心跳回来 → 「开机中」",
     [CONFIRM_WAIT, tap("好", last=True), ("hb", 300), ("state", "base"), tap("刷新")], expect=["~开机中"], timeout=20,
     offline={"say": "好 → 关提示（心跳回来那半步要 ntfy，离线不做）", "do": [CONFIRM_WAIT, tap("好", last=True)], "expect": [STATUS_ROOT],
              "absent": [OFF_NOTE]})

# ------------------------------------------------------------------ shifts
step("shift.night", "shift", "班次切「晚班」→ 只剩明日方舟，底栏没有终末地",
     [tap("晚班")], expect=["~晚班 · 下一趟"], absent=[TAB_EF])
step("shift.morning", "shift", "切回「早班」→ 五个标签回来", [tap("早班", region="content")], expect=[TAB_EF])

# ------------------------------------------------------------------ receipts + D39 on 状态
step("receipts.open", "receipts", "查看全部 → 回执页",
     [tap("~查看全部")], expect=["回执"], absent=[STATUS_ROOT])
step("receipts.tabpop", "d39", "D39：在回执页再点「状态」→ 回到状态根页",
     [("tab", "状态")], expect=[HOME, "~查看全部"], absent=[BACK_BTN, "回执"])
step("receipts.back", "receipts", "再进查看全部 → 返回键回来", [tap("~查看全部"), ("wait", 0.8), ("back",)],
     expect=[HOME, "~查看全部"], absent=[BACK_BTN, "回执"])
step("receipts.reenter", "d39", "回来后再进查看全部 → 进得去", [tap("~查看全部")], expect=["回执"], absent=[STATUS_ROOT])
step("receipts.leave", "receipts", "点「状态」回根页", [("tab", "状态")], expect=[HOME], absent=[BACK_BTN, "回执"])
step("d39.status.top", "d39", "D39：状态根页滑到底再点「状态」→ 回到顶",
     [("swipe", "up", 4), ("tab", "状态"), ("wait", 1.2)], visible=["~开机中"], timeout=6,
     offline={"visible": ["~关机"]})

# ------------------------------------------------------------------ 月卡
step("mc.open", "monthcard", "终末地月卡行 → 月卡页",
     [tap({"t": "终末地", "after": "调试模式"})], expect=["终末地月卡", "最后一次领取"])
step("mc.plus", "monthcard", "＋ → 充值了 2 次", [tap(PLUS)], expect=["充值了 2 次"])
step("mc.minus", "monthcard", "－ → 回到 1 次", [tap(MINUS)], expect=["充值了 1 次"])
step("mc.register.ask", "monthcard", "登记 → 弹「登记充值 1 次？」", [tap("登记", region="content")], expect=["登记充值 1 次？"])
step("mc.register.cancel", "monthcard", "取消 → 没寄出", [CONFIRM_WAIT, tap("取消", last=True)], absent=["登记充值 1 次？"], nocmd=2)
step("mc.align.empty", "monthcard", "天数空着按「对准」→ 提示「填 0–400 的整数」",
     [("retry", 2, [("nokb", 5), tap("对准", region="content")], ("until", "~填 0–400 的整数", 4))],
     expect=["~填 0–400 的整数"], timeout=5)
step("mc.days", "monthcard", "天数填 15 → 收键盘（iOS 完成键）",
     [("field", "游戏里显示还剩", "15"), ("hidekb",)], keyboard=False)
step("mc.align.ask", "monthcard", "对准 → 弹「对准为还剩 15 天？」", [tap("对准", region="content")], expect=["对准为还剩 15 天？"])
step("mc.align.go", "monthcard", "弹窗 · 对准 → 寄出 monthcard left 15，页面变 15 天",
     [CONFIRM_WAIT, tap("对准", last=True)], expect=["15 天"], absent=["对准为还剩 15 天？"],
     cmd={"action": "monthcard", "left": 15, "game": "终末地"})
step("mc.tabpop", "d39", "点「状态」→ 月卡页退掉、回根页", [("tab", "状态")], expect=[HOME], absent=[BACK_BTN, "终末地月卡"])

# ------------------------------------------------------------------ 方舟
step("ark.open", "arknights", "方舟标签 → 关卡 / 理智药 / 作战开关", [("tab", "方舟")], expect=["关卡", "理智药", "作战开关"])
step("ark.sanity.x", "arknights", "理智药改 1000（键盘开着）→ 点 ✕ → 回原值、键盘收起、没有待保存（0878f3b）",
     [("field", "理智药", "1000"), ("wait", 0.6), tap(DISCARD, region="top")], keyboard=False, absent=["~待保存"],
     expect=["理智药"], nocmd=2)
step("ark.sanity.bad", "arknights", "理智药填 1000 → ✓ → 寄出 → 挡下「一项都没寄出」「要填 0–999 的整数」（寄出前校验，什么也不发）",
     [("field", "理智药", "1000"), ("hidekb",), tap(SAVE, region="top"), ("wait", 1.0), tap(SEND_N)],
     expect=["~一项都没寄出", "~要填 0–999 的整数"], timeout=6, nocmd=2)
step("ark.sanity.bad.close", "arknights", "好 → 关提示，没寄出", [CONFIRM_WAIT, tap("好", last=True), ("wait", 0.5)],
     absent=["~一项都没寄出"], nocmd=1)
step("ark.edit4", "arknights", "理智药 2、关卡 CE-6、邮件开关、基建「赤金」→ 待保存 4 项",
     [("field", "理智药", "2"), ("field", "关卡", "CE-6"), ("hidekb",), ("toggle", "领取所有邮件奖励"),
      tap("无人机用在哪"), ("wait", 0.8), tap("~赤金", last=True)],
     expect=["~待保存 4 项"],
     android={"do": [("field", "理智药", "2"), ("field", "关卡", "CE-6"), ("hidekb",), ("toggle", "领取所有邮件奖励"),
                     tap("贸易站 · 龙门币"), ("wait", 0.8), tap("~赤金", last=True)]},
     ios={"do": [("field", "理智药", "2"), ("field", "关卡", "CE-6"), ("hidekb",), ("toggle", "领取所有邮件奖励"),
                 tap({"t": "~基建无人机用在哪", "kind": "Button"}, right=60), ("wait", 0.8), tap("~赤金", last=True)]})
step("ark.review", "arknights", "✓ → 确认单「寄出 4 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 4 项"])
step("ark.send", "arknights", "寄出 → set_master 赤金 / 邮件 + set_config 理智药 2 / CE-6",
     [CONFIRM_WAIT, tap("寄出 4 项")], absent=["确认这次修改"],
     cmd=["~PureGold", "~Mail", "~MedicineNumb", "~CE-6"])
step("ark.battle.discard", "arknights", "作战开关切换 → 待保存 → ✕ 放弃 → 回原值",
     [tap(CLEAR), ("toggle", "作战开关"), ("wait", 0.6), tap(DISCARD, region="top")], absent=["~待保存"], nocmd=2,
     offline={"do": [("toggle", "作战开关"), ("wait", 0.6), tap(DISCARD, region="top")]})
step("ark.menu.left", "arknights", "菜单行：点行左边的名字不出菜单（照原生，只有右边的值能点；已知存疑 D203 不改）",
     [tap("基建无人机用在哪"), ("wait", 0.8)], absent=["不使用"], on="ios")
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
     [tap({"t": "~刷取设置, ", "kind": "Button"}, right=60), ("wait", 0.8), tap("~地区模式", last=True)],
     expect=["~待保存 2 项"], android={"do": [tap("随机模式"), ("wait", 0.8), tap("~地区模式", last=True)]})
step("ef.review", "endfield", "✓ → 确认单「寄出 2 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("ef.send", "endfield", "寄出 → set_master 执行周期 / 刷取设置",
     [CONFIRM_WAIT, tap("寄出 2 项")], absent=["确认这次修改"], cmd=["~AutoEssence"])
step("ef.protocol", "endfield", "协议空间 选「武器养成」→ 待保存 → ✕ 放弃",
     [tap(CLEAR), tap({"t": "~干员养成", "kind": "Button"}, right=60), ("wait", 0.8),
      tap("~武器养成", last=True), ("wait", 0.6), tap(DISCARD, region="top")],
     absent=["~待保存"], nocmd=2,
     android={"do": [tap(CLEAR), tap("~干员养成"), ("wait", 0.8), tap("~武器养成", last=True), ("wait", 0.6),
                     tap(DISCARD, region="top")]},
     offline={"do": [tap({"t": "~干员养成", "kind": "Button"}, right=60), ("wait", 0.8),
                     tap("~武器养成", last=True), ("wait", 0.6), tap(DISCARD, region="top")],
              "android": {"do": [tap("~干员养成"), ("wait", 0.8), tap("~武器养成", last=True), ("wait", 0.6),
                                 tap(DISCARD, region="top")]}})
step("ef.collect.more", "endfield", "自动采集 · 更多设置 → 推入页 → 返回",
     [tap({"t": "更多设置", "after": "~自动采集"}), ("wait", 1.0), ("back",)], expect=[HOME, "~自动采集"],
     absent=[BACK_BTN], timeout=10)
step("ef.ticket.open", "endfield", "再进「更多设置」→ 执行周期「已选 7/7」、使用刻写券关（机器值）",
     [("tab", "终末地"), ("top", 3), tap("更多设置")], expect=["已选 7/7", "使用刻写券"], switch={"使用刻写券": False})
step("ef.ticket.on", "endfield", "打开「使用刻写券」→ 那行出现小字「待保存」",
     [("toggle", "使用刻写券")], expect=["待保存", "~待保存 1 项"], switch={"使用刻写券": True})
step("ef.ticket.days", "endfield", "执行周期去掉周日 → 「已选 6/7」「待保存 2 项」",
     [tap("~执行周期"), tap("周日"), tap(SAVE, region="top")], expect=["~6/7", "~待保存 2 项"])
step("ef.ticket.discard", "endfield", "保存条 ✕ → 控件回到机器值（7/7、刻写券关），还在更多设置页（e17db83）",
     [tap(DISCARD, region="top")], expect=["已选 7/7", "使用刻写券"], absent=["待保存", "~待保存 2 项", "库存"],
     switch={"使用刻写券": False}, nocmd=2)
step("ef.loop.x", "endfield", "循环执行改 20（键盘开着）→ 点 ✕ → 回原值、键盘收起、没有待保存、还在更多设置页（0878f3b）",
     [("field", "循环执行", "20"), ("wait", 0.6), tap(DISCARD, region="top")], keyboard=False,
     expect=[{"t": "99", "kind": ["TextField", "EditText"]}, "循环执行"], absent=["~待保存", "库存"], nocmd=2)
step("d39.ef.top", "d39", "D39：终末地根页滑到底再点「终末地」→ 回顶",
     [("tab", "终末地"), ("wait", 0.8), ("swipe", "up", 4), ("tab", "终末地"), ("wait", 1.2)], visible=["库存"])

# ------------------------------------------------------------------ 鸣潮
step("ww.open", "wuwa", "鸣潮标签 → 无音区 / 周本", [("tab", "鸣潮")], expect=["~无音区", "周本打第几个"])
step("ww.what", "wuwa", "刷什么（点右边的值）→ 菜单 无音区 / 凝素领域 / 模拟领域",
     [tap({"t": "~刷什么, ", "kind": "Button"}, right=50)], expect=["凝素领域", "模拟领域"],
     android={"do": [tap("无音区")]})
step("ww.what.same", "wuwa", "选回「无音区」→ 菜单收起、没有待保存",
     [tap("无音区", last=True), ("wait", 0.6)], absent=["凝素领域", "~待保存"])
step("ww.tacet", "wuwa", "刷第几个无音区（安卓旧闪退点）→ 选择页 7 行", [tap("~刷第几个无音区")], expect=["~雪落无声之愿", "~长路启航之星"])
step("ww.tacet.pick", "wuwa", "选第 5 个 → ✓ → 待保存 1 项",
     [tap("~雪落无声之愿"), ("wait", 0.4), tap(SAVE, region="top")], expect=["~待保存 1 项"])
step("ww.boss.bad", "wuwa", "周本填 251 → ✓ → 寄出 → 挡下「要填 1–20」（寄出前校验，什么也不发）",
     [("field", "周本打第几个", "251"), ("nokb", 5), tap(SAVE, region="top"), ("until", SEND_N, 6), CONFIRM_WAIT, tap(SEND_N)],
     expect=["~要填 1–20", "~一项都没寄出"], timeout=6, nocmd=2)
step("ww.boss.fix", "wuwa", "好 → 周本改 13 → 待保存 2 项",
     [CONFIRM_WAIT, tap("好", last=True), ("wait", 0.5), ("field", "周本打第几个", "13"), ("hidekb",)], expect=["~待保存 2 项"])
step("ww.review", "wuwa", "✓ → 确认单「寄出 2 项」", [tap(SAVE, region="top")], expect=["确认这次修改", "寄出 2 项"])
step("ww.send", "wuwa", "寄出 → set_master 无音区 + weekly_boss 13",
     [CONFIRM_WAIT, tap("寄出 2 项")], absent=["确认这次修改"], cmd=[{"action": "weekly_boss"}, {"action": "set_master"}])
step("ww.clear", "wuwa", "不等了，清掉", [tap(CLEAR)], absent=[CLEAR], offline={"do": [], "absent": [], "skip": "额度"})
step("ww.boss.x", "wuwa", "周本打第几个改 31（键盘开着）→ 点 ✕ → 回原值、键盘收起、没有待保存（0878f3b）",
     [("field", "周本打第几个", "31"), ("wait", 0.6), tap(DISCARD, region="top")], keyboard=False,
     absent=["~待保存"], nocmd=2)
step("d39.ww.top", "d39", "D39：鸣潮滑到底再点「鸣潮」→ 回顶",
     [("swipe", "up", 4), ("tab", "鸣潮"), ("wait", 1.2)], visible=["~无音区"])

# ------------------------------------------------------------------ 手机
step("ph.open", "phone", "手机标签 → 页面版本 / 诊断记录 / 「密钥」行",
     [("tab", "手机")], expect=["页面版本", "诊断记录", "复制免输入链接", "密钥"], absent=["已配置"],
     ios={"say": "手机标签 → 页面版本「x.y.z (n)」/ 诊断记录（说明写「收发消息、网络通断和机器状态」）/ 「密钥」行",
          "expect": ["页面版本", "re:^\\d+\\.\\d+\\.\\d+ \\(\\d+\\)$", "诊断记录", "~收发消息、网络通断和机器状态",
                     "复制免输入链接", "密钥"]})
step("ph.diag.on", "phone", "诊断记录打开 → 分享 / 清空 / 运行自检 / 就是这里",
     [("toggle", "诊断记录")], expect=["~分享诊断记录", "清空诊断记录", "运行自检", "就是这里"])
step("ph.selftest", "phone", "运行自检 → 结果单「通过 N / 6」",
     [tap("运行自检")], expect=["re:通过 \\d+ ?/ ?\\d+"], timeout=30)
step("ph.selftest.close", "phone", "关掉自检结果", [CONFIRM_WAIT, tap(["关闭", "好"], last=True)], absent=["re:通过 \\d+ ?/ ?\\d+"])
step("ph.clear.ask", "phone", "清空诊断记录 → 弹确认 → 取消", [tap("清空诊断记录"), ("wait", 0.8), tap("取消", last=True)],
     absent=["清空诊断记录？"])
step("ph.share", "phone", "分享诊断记录 → 「诊断记录已生成」单（复制 / 分享 / 关闭）",
     [tap("~分享诊断记录")], expect=["诊断记录已生成", "分享", "关闭"], timeout=10)
step("ph.share.sys", "phone", "单里「分享」→ 系统分享面板 → 取消 → 不闪退、单还在（62ba009）",
     [tap("分享", last=True), ("wait", 2.5), ("back",), ("wait", 5)], expect=["诊断记录已生成"], timeout=10,
     ios={"say": "单里「分享」→ 系统分享面板 → 点面板外面 → 「分享已取消」、不闪退、单还在（62ba009）",
          # while the share panel is up the app's tree hides the 诊断记录 sheet: its title gone = panel up, back = closed
          "do": [CONFIRM_WAIT, tap("分享", last=True), ("gone", "诊断记录已生成", 8), ("wait", 0.8),
                 ("retry", 3, [("point", 0.5, 0.44)], ("until", "诊断记录已生成", 4))],
          "expect": ["诊断记录已生成", "~分享已取消"]})
step("ph.share.close", "phone", "关闭 → 回手机页", [("until", "关闭", 6), tap("关闭", last=True)], absent=["诊断记录已生成"],
     expect=["运行自检"])
step("ph.copylink", "phone", "复制免输入链接 → 「链接已复制」", [tap("复制免输入链接")], expect=["~链接已复制"], timeout=5)
step("ph.paste.bad", "phone", "粘贴密钥串 填乱码 → 存 → 「没存上」",
     [tap("粘贴密钥串"), ("wait", 1.0), ("field", {"t": "", "kind": ["TextField", "TextView", "EditText"]}, "zzz"), tap("存")],
     expect=["没存上"], timeout=6,
     # iOS: the TextEditor shows in the tree only as its cell (the first one under the title)
     ios={"do": [tap("粘贴密钥串"), ("wait", 1.0), tap({"t": "", "kind": "Cell"}, scroll=False), ("wait", 0.8),
                 ("type", "zzz"), tap("存")]},
     # Android: an empty-text selector with kind TextView matches the sheet's 「取消」 first and closes the sheet
     android={"do": [tap("粘贴密钥串"), ("wait", 1.0), ("field", {"t": "", "kind": "EditText"}, "zzz"), tap("存")]})
step("ph.paste.close", "phone", "好 → 提示和粘贴单一起关掉，回手机页",
     [CONFIRM_WAIT, tap("好", last=True), ("wait", 0.8)], expect=["页面版本"], absent=["没存上"])
DIAG_BTN = "就是这里"
step("diag.bottom.phone", "diag", "诊断开 · 手机页滑到底 → 最后一行在红钮「就是这里」上面（ce8ebc3）",
     [("bottom", 4)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.status", "diag", "诊断开 · 状态根页滑到底 → 「查看全部」在红钮上面",
     [("tab", "状态"), ("wait", 0.8), ("bottom", 8)], last_above=DIAG_BTN, expect=["~查看全部"], on="ios")
step("diag.bottom.all", "diag", "诊断开 · 点「查看全部」→ 进回执页，不弹诊断单子",
     [tap("~查看全部", scroll=False)], expect=["回执"], absent=["诊断记录已生成", STATUS_ROOT], on="ios")
step("diag.bottom.receipts", "diag", "诊断开 · 回执页滑到底 → 最后一行在红钮上面",
     [("bottom", 8)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ark", "diag", "诊断开 · 方舟滑到底 → 最后一行在红钮上面",
     [("tab", "状态"), ("tab", "方舟"), ("wait", 0.8), ("bottom", 6)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ef", "diag", "诊断开 · 终末地根页滑到底 → 最后一行在红钮上面",
     [("tab", "终末地"), ("wait", 0.8), ("bottom", 8)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ww", "diag", "诊断开 · 鸣潮滑到底 → 最后一行在红钮上面",
     [("tab", "鸣潮"), ("wait", 0.8), ("bottom", 6)], last_above=DIAG_BTN, on="ios")
step("ph.diag.off", "phone", "诊断记录关掉 → 多出的行收起", [("tab", "手机"), ("top", 4), ("toggle", "诊断记录")],
     absent=["运行自检", "就是这里"])
step("diag.off.status", "diag", "诊断关 · 状态根页滑到底 → 最后一行贴着底栏（没有多出的空白）",
     [("tab", "状态"), ("wait", 0.8), ("bottom", 8)], last_bottom=[860, 880], absent=[DIAG_BTN], on="ios")
step("diag.off.ark", "diag", "诊断关 · 方舟滑到底 → 最后一行贴着底栏",
     [("tab", "方舟"), ("wait", 0.8), ("bottom", 6)], last_bottom=[860, 880], on="ios")
step("diag.off.ef", "diag", "诊断关 · 终末地根页滑到底 → 最后一行贴着底栏",
     [("tab", "终末地"), ("wait", 0.8), ("bottom", 8)], last_bottom=[860, 880], on="ios")
step("d39.ph.top", "d39", "D39：手机页滑到底再点「手机」→ 回顶",
     [("tab", "手机"), ("wait", 0.8), ("swipe", "up", 4), ("tab", "手机"), ("wait", 1.2)], visible=["页面版本"])

# ------------------------------------------------------------------ shift change while on a gone tab (pass-1 item 6, fix 5)
step("noef.jump", "layout", "人在终末地，机器发来早班不含终末地的状态（实时分片，不刷新）→ 终末地标签消失、跳到状态",
     [("tab", "终末地"), ("wait", 1.0), ("state", "noef")], expect=[STATUS_ROOT], absent=[TAB_EF], timeout=30,
     offline={"say": "人在终末地，缓存注入早班不含终末地的状态、冷启动 → 终末地标签没了、停在状态（记住的标签改回状态）"})
step("noef.back", "layout", "机器发回原状态 → 终末地标签回来，App 留在状态",
     [("state", "base"), ("wait", 6)], expect=[TAB_EF, STATUS_ROOT], timeout=30)

# ------------------------------------------------------------------ duplicate receipts (pass-1 item 5, fix 3)
step("dup.status", "receipts", "同一分钟两条一样的回执 → 状态页两行都在、不崩",
     [("state", "dup"), tap("刷新"), ("wait", 3), ("see", "周本：打第 2 个")], expect=[{"t": "周本：打第 2 个", "count": 2}],
     timeout=25,
     offline={"do": [("state", "dup"), ("see", "周本：打第 2 个")]})
step("dup.page", "receipts", "查看全部 → 回执页也有这两行（不是旧数据）",
     [tap("~查看全部")], expect=["回执", {"t": "周本：打第 2 个", "count": 2}], timeout=10)
step("dup.done", "receipts", "回状态，发回原状态", [("tab", "状态"), ("state", "base")], expect=[HOME], absent=[BACK_BTN])

# ------------------------------------------------------------------ 刷声骸 in progress (cache / state injection; 796103b)
FH, FM = FARM_HHMM.split(":")
step("farm.show", "farm", f"机器正在刷声骸（到机器时间 {FARM_HHMM}）→ 「正在刷」「改收工时刻」「提前收工」",
     [("tab", "状态"), ("state", "farm"), ("wait", 1.0), ("see", "~正在刷「回放Boss」")],
     expect=["~正在刷「回放Boss」", f"~机器时间 {FARM_HHMM}", "改收工时刻", "提前收工"], timeout=30)
step("farm.row", "farm", "4C 段只剩「改成刷到几点」：没有「打哪个」「刷到几点」「开始刷」",
     [("see", "改成刷到几点（机器时间）")], expect=["改成刷到几点（机器时间）"],
     absent=["刷到几点（机器时间）", "开始刷", "刷 4C 声骸 · 打哪个"])
step("farm.capsule", "farm", f"「改成刷到几点」胶囊显示机器时间的「到」{FARM_HHMM}（不随手机时区）",
     [], expect=[{"t": f"re:^0?{int(FH)}:{FM}$", "kind": "Button"}],
     android={"expect": [f"re:^(0?{int(FH)}:{FM}|{int(FH) % 12 or 12}:{FM} {'AM' if int(FH) < 12 else 'PM'})$"]})
step("farm.pick", "farm", "改成刷到几点 · 拨 23 / 30 → 点外面关掉 → 胶囊「23:30」，没进别的页",
     [("time", "改成刷到几点", 23, 30)], expect=["23:30", "改成刷到几点（机器时间）"], absent=["终末地月卡"],
     android={"expect": ["re:^(23:30|11:30 PM)$", "改成刷到几点（机器时间）"]})
step("farm.done", "farm", "发回原状态 → 「刷到几点」「开始刷」回来",
     [("state", "base"), ("wait", 1.0), ("see", "刷到几点（机器时间）"), ("see", "开始刷")],
     expect=["刷到几点（机器时间）", "开始刷"],
     absent=["~正在刷「回放Boss」", "改成刷到几点（机器时间）"], timeout=30)

# ------------------------------------------------------------------ two-time receipts (ce8ebc3)
TWO_T = "re:\\d\\d:\\d\\d 发出 · .*执行"
step("times.show", "receipts", "两条测试回执（单时间 / 发出≠执行）→ 状态页两行都在，两段时间那行时间在文字下面、不压字",
     [("state", "times"), ("wait", 1.0), ("see", "~回放两时间回执")],
     expect=["~回放单时间回执", "~回放两时间回执", TWO_T], below=[["~回放两时间回执", TWO_T]], timeout=30)
step("times.page", "receipts", "查看全部 → 回执页同样两行、时间在文字下面",
     [tap("~查看全部"), ("wait", 1.0), ("see", "~回放两时间回执")],
     expect=["回执", "~回放单时间回执", TWO_T], below=[["~回放两时间回执", TWO_T]], timeout=10)
step("times.done", "receipts", "回状态，发回原状态", [("tab", "状态"), ("state", "base")], expect=[HOME], absent=[BACK_BTN], timeout=30)

# ------------------------------------------------------------------ fluency (Android; the Mac must be idle)
step("flu.tabs", "fluency", "五个标签各切 3 次（间隔 1.5 秒）→ FluencyRec 记下的 long 次数和最长一帧（Mac 1 分钟负载 < 8）",
     [("tab", "状态"), ("wait", 2), ("fluency", 3)], expect=[STATUS_ROOT], on="android", timeout=10,
     nojudge_fail="Mac 负载")

# ------------------------------------------------------------------ clipboard on launch (iOS; fix b79c5d4)
# The old crash (detectPatterns' callback on a background queue) came 5-20 s after a launch with any string on the
# pasteboard, so each launch is watched 22 s. The link is a 免输入链接 for the THROWAWAY mailbox (run.py own_link).
CLIP_WAIT = 22
step("clip.after.link", "clip", "已配置：剪贴板里是免输入链接 → 冷启动 22 秒不闪退",
     [("clipboard", "@link"), ("relaunch",), ("allow_paste", 10), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.after.hello", "clip", "已配置：剪贴板里是「hello」→ 冷启动 22 秒不闪退",
     [("clipboard", "hello"), ("relaunch",), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.after.empty", "clip", "已配置：剪贴板是空的 → 冷启动 22 秒不闪退",
     [("clipboard", ""), ("relaunch",), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.first.empty", "clip", "没配置：剪贴板空 → 「第一次使用」页，22 秒不闪退",
     [("forget_config",), ("clipboard", ""), ("relaunch",), ("wait", CLIP_WAIT)],
     expect=["第一次使用", "开始使用", "粘贴免输入链接"], timeout=20, on="ios")
step("clip.first.pin", "clip", "第一次使用 · PIN 框弹数字键盘 → 键盘上的「完成」收起键盘",
     [("field", "PIN", "1234"), ("hidekb",)], expect=["第一次使用"], keyboard=False, timeout=6, on="ios")
step("clip.first.hello", "clip", "没配置：剪贴板里是「hello」→ 「第一次使用」页，22 秒不闪退",
     [("forget_config",), ("clipboard", "hello"), ("relaunch",), ("wait", CLIP_WAIT)],
     expect=["第一次使用", "开始使用"], timeout=20, on="ios")
step("clip.first.link", "clip", "没配置：剪贴板里是（一次性信箱的）免输入链接 → 自动配好进标签页，22 秒不闪退",
     [("forget_config",), ("clipboard", "@link"), ("relaunch",), ("allow_paste", 10), ("wait", CLIP_WAIT)],
     expect=[STATUS_ROOT], absent=["第一次使用"], timeout=20, on="ios")
step("clip.restore", "clip", "清剪贴板、写回一次性信箱 → 冷启动回状态页",
     [("clipboard", ""), ("restore_config",), ("relaunch",)], expect=[STATUS_ROOT], timeout=30, on="ios", always=True)

STEPS = S
