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
  offline  overrides merged with --offline (no runner traffic: no heartbeat, states injected into the app's cache).
           Without one, a step with cmd runs everything but its last tap, closes what is open (dismiss) and reads
           「跳过（额度）」. A change applies when made, so its last action IS the send: send steps carry offline={}
           (all actions run, cmd is dropped, the row's own 「已寄出」 line is judged)
  skip     reason: the step is not judged, it only runs (「跳过（reason）」)
  nojudge / nojudge_fail   reason: never judged / judged 对 when it passes, 「不判（reason）」 when it fails
  below    [[upper sel, lower sel], ...]: the lower element starts under the upper one's bottom edge
  last_above sel / last_bottom [lo, hi]: the page's last line ends above sel's top edge / inside the range

Selectors: "exact text" | "~substring" | "re:regex" | [alternatives] |
           {"t": ..., "kind": "Switch", "region": "content", "nth": 1, "after": "<anchor text>", "count": 2}
On iOS the texts are accessibility labels / values; on Android uiautomator text and content-desc.
"""

# The App applies a setting when it is changed (native-merge-1007, 29ad6cf): a switch / menu / pick goes out at once, a
# text or number field on submit. There is no save bar (✕ / ✓), no 「待保存 N 项」, no review sheet and no 400 ms gate any
# more; a row says its own state under its name (「正在寄出」, 「已寄出 HH:MM · …」, 「没寄出：…」 in red), 「再发一次」 / 「不改了」
# are the row's swipe actions and long-press menu, and the pending line above each tab ends in 「不再等待」 (confirmed).
# HIG Feedback: "Consider integrating status feedback into your interface." — so the table checks the row's own line.
#
# --offline (the default way to run this build on Android: the App ignores the local ntfy server, see README): the runner
# posts nothing, but the App's own send still goes to ntfy.sh on the throwaway topic. A send step therefore carries
# offline={} (run every action, judge the row's 「已寄出」 line instead of the mailbox); without it select_steps would drop
# the step's last action, which is the change itself.

TAB_EF = {"t": "终末地", "region": "bottom"}
STATUS_ROOT = "现在跑一趟"


def home(title):
    """A tab's root page: its title (large or inline) in the top fifth of the screen."""
    return {"t": title, "kind": ["StaticText", "TextView"], "region": "top"}


HOME = home("状态")
# a pushed page's back button: Android's arrow is content-desc 「Back」; iOS's carries the tab's title
BACK_BTN = {"t": ["Back", "状态", "方舟", "终末地", "鸣潮", "手机"], "kind": ["Button", "View"], "region": "top"}
CONFIRM_WAIT = ("wait", 0.5)                 # confirmation dialogs slide in; a press during the slide can miss
CLEAR = "不再等待"                            # PendingBarView.swift: the button and its confirmation
CLEAR_ASK = "不再等待这些改动的回执？"
SENT = "re:^已寄出 \\d{1,2}:\\d\\d · "         # a row's line after its change went out (Pending.swift:174)
BAR_SENT = "re:^\\d+ 项改动已寄出 · "          # the pending line above the tab (Pending.swift:224)
OFF_SUB = "机器关着，没有在跑的"               # 停止一切 disabled while the machine is off (StatusPage.swift:227)
FARM_OFF = "~机器关着，开机后才能开始。"        # 开始刷 disabled while the machine is off (StatusPage.swift:387)
PLUS = ["Increment", "增加", "+", "re:, Increment$"]      # iOS 27 Stepper halves: 「充值了 1 次, Increment」
MINUS = ["Decrement", "减少", "-", "−", "re:, Decrement$"]
CANCEL_TOP = {"t": ["Cancel", "取消", "Close", "关闭"], "region": "top"}   # a sheet's cancel (role .cancel, system label)
DONE_TOP = {"t": ["完成", "Done"], "region": "top"}
SHEET_CLOSE = ["Close", "关闭", "取消", "Cancel"]                       # the iOS share sheet's close button

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
step("setup.launch", "setup", "冷启动（一次性信箱已写好）→ 标题「状态」、数据齐、设备卡「开机中」",
     [("relaunch",)], expect=[HOME, STATUS_ROOT, "停止一切", "这一趟", "~开机中"], timeout=45, always=True,
     offline={"say": "冷启动（一次性信箱 + 缓存注入的状态）→ 标题「状态」、数据齐、设备卡「关机」（离线没有心跳）",
              "expect": [HOME, STATUS_ROOT, "停止一切", "这一趟", "~关机"]})

# ------------------------------------------------------------------ status page
step("status.runnow.ask", "status", "状态 · 现在跑一趟 → 确认框「现在跑一趟？」",
     [tap(STATUS_ROOT)], expect=["现在跑一趟？", "跑一趟"])
step("status.runnow.go", "status", "确认框 · 跑一趟 → 寄出 run_now，回执区那行写「已寄出，等机器回执」",
     [CONFIRM_WAIT, tap("跑一趟", last=True), ("see", "已寄出，等机器回执")], absent=["现在跑一趟？"],
     expect=["已寄出，等机器回执"], cmd={"action": "run_now"}, offline={})
step("status.stop.ask", "status", "状态 · 停止一切 → 确认框「停止一切？」",
     [("top", 5), tap("停止一切")], expect=["停止一切？"],
     offline={"say": "状态 · 关机时「停止一切」停用，行里写「机器关着，没有在跑的」，点了不弹框",
              "do": [("top", 5), ("until", OFF_SUB, 25), tap("停止一切"), ("wait", 1.0)],
              "expect": [OFF_SUB], "absent": ["停止一切？"]})
step("status.stop.cancel", "status", "确认框 · 取消 → 关掉，没寄出",
     [CONFIRM_WAIT, tap("取消", last=True)], absent=["停止一切？"], nocmd=3,
     offline={"do": [], "skip": "关机，没有确认框"})
step("status.4c.menu", "status", "刷 4C 声骸 · 打哪个（点当前值）→ 菜单列出 boss",
     [tap({"t": "re:^\\d\\. ", "kind": ["StaticText", "TextView"]})], expect=["re:^3\\. "])
step("status.4c.pick", "status", "菜单 · 选第 3 个 boss → 菜单收起，行显示第 3 个",
     [tap("re:^3\\. ", last=True)], expect=["re:^3\\. "], absent=[{"t": "re:^4\\. "}])
step("status.until.2330", "status", "刷到（机器时间）· 点胶囊拨转盘 23 / 30 → 点外面关掉 → 胶囊「23:30」",
     [("time", "刷到（机器时间）", 23, 30)], expect=["23:30"], absent=[{"t": "", "kind": "PickerWheel"}],
     android={"say": "刷到（机器时间）· 点时间 → 系统时间对话框拨 23:30 → 返回 → 行上「11:30 PM」/「23:30」（跟手机 12/24 小时）",
              "do": [("time", "刷到", 23, 30)], "expect": ["re:^(23:30|11:30 PM)$"], "absent": []})
step("status.until.0005", "status", "刷到（机器时间）· 拨 0 / 05 → 胶囊「0:05」（系统按地区不补零，存进去是 00:05）",
     [("time", "刷到（机器时间）", 0, 5)], expect=["re:^0?0:05$"],
     android={"say": "刷到（机器时间）· 拨 00:05 → 行上「12:05 AM」/「00:05」", "do": [("time", "刷到", 0, 5)],
              "expect": ["re:^(00:05|12:05 AM)$"]})
step("status.echo.ask", "status", "开始刷 → 确认框「开始刷？」（到 00:05）",
     [tap("开始刷", region="content")], expect=["开始刷？", "~00:05"],
     offline={"say": "关机时「开始刷」停用，说明里写「机器关着，开机后才能开始。」，点了不弹框",
              "do": [tap("开始刷", region="content"), ("wait", 1.0)], "expect": [FARM_OFF], "absent": ["开始刷？"]})
step("status.echo.go", "status", "确认框 · 开始刷 → 寄出 echo_farm（第 3 个，到 00:05）",
     [CONFIRM_WAIT, tap("开始刷", last=True)], absent=["开始刷？"], cmd={"action": "echo_farm", "boss": 3, "until": "00:05"},
     offline={"do": [], "skip": "关机，没有确认框"})
step("status.keepon.on", "status", "下次跑完不关机 打开 → 马上寄出 skip_shutdown，那行写「已寄出 HH:MM · …」，顶上「N 项改动已寄出」",
     [("toggle", "下次跑完不关机"), ("see", "下次跑完不关机")], switch={"下次跑完不关机": True},
     expect=[SENT, BAR_SENT, CLEAR], timeout=10, cmd={"action": "skip_shutdown"}, offline={})
step("status.keepon.off", "status", "再关掉 → 又寄出一次（带 off），开关回到关",
     [("wait", 1.5), ("toggle", "下次跑完不关机"), ("see", "下次跑完不关机")], switch={"下次跑完不关机": False},
     expect=[SENT], timeout=10, cmd={"action": "skip_shutdown", "off": True}, offline={})
step("status.debug.on", "status", "调试模式 打开 → 马上寄出 debug_mode，那行写「已寄出」",
     [("toggle", "调试模式"), ("see", "调试模式")], switch={"调试模式": True}, expect=[SENT], timeout=10,
     cmd={"action": "debug_mode"}, offline={})
step("status.queued", "status", "D207：机器回「排队」回执 → 行下「排队中 · 跑完执行」",
     [("receipt", ["skip_shutdown", "debug_mode"], True)], expect=["~排队中 · 跑完执行"], timeout=25,
     offline={"do": [], "expect": [], "skip": "额度"})
step("status.queued.final", "status", "机器回最终回执 → 「排队中」消失",
     [("receipt", ["skip_shutdown", "debug_mode"], False)], absent=["~排队中 · 跑完执行"], timeout=25,
     offline={"do": [], "absent": [], "skip": "额度"})
step("status.clear.ask", "status", "顶上「不再等待」→ 确认框「不再等待这些改动的回执？」（不再等待 / 取消）",
     [("top", 5), tap(CLEAR)], expect=[CLEAR_ASK, "取消"])
step("status.clear.cancel", "status", "确认框 · 取消 → 关框，顶上那行还在",
     [CONFIRM_WAIT, tap("取消", last=True), ("wait", 0.6)], absent=[CLEAR_ASK], expect=[CLEAR, BAR_SENT], nocmd=2)
step("status.clear.go", "status", "再点「不再等待」→ 确认框里点「不再等待」→ 顶上那行和各行的「已寄出」都清掉",
     [("clear_receipts",), tap(CLEAR), ("until", CLEAR_ASK, 5), CONFIRM_WAIT, tap(CLEAR, last=True), ("gone", CLEAR_ASK, 5)],
     absent=[CLEAR, BAR_SENT, SENT], timeout=10, nocmd=2)
step("status.skip.off", "status", "早班开关关掉 → 马上寄出 skip_today，那行写「已寄出」",
     [("toggle", "re:^早班 · \\d"), ("see", "re:^早班 · \\d")], switch={"re:^早班 · \\d": False}, expect=[SENT],
     timeout=10, cmd={"action": "skip_today", "queue": "早班"}, offline={})
step("status.skip.on", "status", "早班开关再打开 → 寄出 unskip_today，开关回到开",
     [("wait", 1.5), ("toggle", "re:^早班 · \\d"), ("see", "re:^早班 · \\d")], switch={"re:^早班 · \\d": True},
     expect=[SENT], timeout=10, cmd={"action": "unskip_today", "queue": "早班"}, offline={})

# ------------------------------------------------------------------ heartbeat / machine off
step("status.off", "status", "心跳过期 → 设备卡「关机」",
     [("hb", 1), ("wait", 33), ("top", 5)], expect=["~关机"], timeout=25,
     offline={"say": "没有心跳 → 设备卡「关机」（离线：一次性信箱没有心跳）", "do": [("top", 5)]})
step("status.off.stop", "status", "关机时「停止一切」停用，行里写「机器关着，没有在跑的」，点了不弹框、不寄出",
     [("until", OFF_SUB, 25), tap("停止一切"), ("wait", 1.0)], expect=[OFF_SUB], absent=["停止一切？"], nocmd=2)
step("status.off.back", "status", "心跳回来 → 「开机中」，停止一切恢复",
     [("hb", 300), ("state", "base")], expect=["~开机中", "脚本和游戏"], absent=[OFF_SUB], timeout=25,
     offline={"do": [], "expect": [], "absent": [], "skip": "离线没有心跳"})

# ------------------------------------------------------------------ shifts (HIG Tab bars: the tab stays, its page says why)
step("shift.night", "shift", "班次切「晚班」→ 终末地标签还在；进去是空页「这个班次没有终末地」+「去「状态」页」",
     [tap("晚班"), ("wait", 1.0), ("tab", "终末地"), ("wait", 1.0)],
     expect=[TAB_EF, "这个班次没有终末地", "去「状态」页"], absent=["库存"])
step("shift.tostatus", "shift", "空页 · 去「状态」页 → 回状态标签",
     [tap("去「状态」页")], expect=[HOME, STATUS_ROOT, "~晚班 · 下一趟"])
step("shift.morning", "shift", "回状态切回「早班」→ 终末地标签又是终末地的页（库存 / 更多设置）",
     [("tab", "状态"), ("top", 5), tap("早班", region="content"), ("wait", 1.0), ("tab", "终末地"), ("wait", 1.0)],
     expect=[home("终末地"), "库存", "更多设置"], absent=["这个班次没有终末地"])
step("shift.back", "shift", "回状态", [("tab", "状态")], expect=[HOME, STATUS_ROOT, "~早班 · 下一趟"])

# ------------------------------------------------------------------ receipts + D39 on 状态
step("receipts.open", "receipts", "查看全部 → 推入「回执」页（有返回键）",
     [tap("~查看全部")], expect=["回执", BACK_BTN], absent=[STATUS_ROOT])
step("receipts.tabpop", "d39", "D39：在回执页再点「状态」→ 回到状态根页",
     [("tab", "状态")], expect=[HOME, "~查看全部"], absent=[BACK_BTN, "回执"])
step("receipts.back", "receipts", "再进查看全部 → 系统返回键回来", [tap("~查看全部"), ("wait", 0.8), ("back",)],
     expect=[HOME, "~查看全部"], absent=[BACK_BTN, "回执"])
step("receipts.reenter", "d39", "回来后再进查看全部 → 进得去", [tap("~查看全部")], expect=["回执"], absent=[STATUS_ROOT])
step("receipts.leave", "receipts", "点「状态」回根页", [("tab", "状态")], expect=[HOME], absent=[BACK_BTN, "回执"])
step("d39.status.top", "d39", "D39：状态根页滑到底再点「状态」→ 回到顶",
     [("swipe", "up", 4), ("tab", "状态"), ("wait", 1.2)], visible=["~开机中"], timeout=6,
     offline={"visible": ["~关机"]})

# ------------------------------------------------------------------ 月卡
step("mc.open", "monthcard", "月卡区 · 终末地 → 推入「终末地月卡」页", [tap({"t": "终末地", "after": "调试模式"})],
     expect=["终末地月卡", "最后一次领取", "登记"])
step("mc.plus", "monthcard", "＋ → 充值了 2 次", [tap(PLUS)], expect=["充值了 2 次"])
step("mc.minus", "monthcard", "－ → 回到 1 次", [tap(MINUS)], expect=["充值了 1 次"])
step("mc.register", "monthcard", "登记（没有确认框）→ 马上寄出 monthcard add 1，次数回到 1",
     [tap("登记", region="content"), ("wait", 1.0)], expect=["充值了 1 次"], absent=["登记充值 1 次？"],
     cmd={"action": "monthcard", "add": 1, "game": "终末地"}, offline={})
step("mc.reopen", "monthcard", "（登记后）回状态再进月卡页 → 「终末地月卡」页，充值了 1 次",
     [("tab", "状态"), tap({"t": "终末地", "after": "调试模式"})], expect=["终末地月卡", "充值了 1 次", "对准"])
step("mc.align.empty", "monthcard", "天数空着 →「对准」停用，点了不寄出；下面写「照游戏里显示的「还剩 X 天」填」",
     [("nokb", 5), tap("对准", region="content"), ("wait", 1.0)], expect=["~第一次用或者日期对不上时"], nocmd=2)
step("mc.align.bad", "monthcard", "天数填 401 → 收键盘 → 下面红字「401 天超出范围：填 0–400。」，对准停用",
     [("field", "游戏里显示还剩", "401"), ("hidekb",), ("wait", 0.6)], expect=["~401 天超出范围：填 0–400"], keyboard=False)
step("mc.days", "monthcard", "天数改 15 → 收键盘（iOS 完成键）→ 红字消失",
     [("field", "游戏里显示还剩", "15"), ("hidekb",), ("wait", 0.6)], keyboard=False, absent=["~天超出范围"])
step("mc.align.go", "monthcard", "对准（没有确认框）→ 马上寄出 monthcard left 15，「还剩」变 15 天",
     [tap("对准", region="content")], expect=["15 天"], cmd={"action": "monthcard", "left": 15, "game": "终末地"}, offline={})
step("mc.tabpop", "d39", "点「状态」→ 月卡页退掉、回根页", [("tab", "状态")], expect=[HOME], absent=[BACK_BTN, "终末地月卡"])

# ------------------------------------------------------------------ 方舟
step("ark.open", "arknights", "方舟标签 → 标题「方舟」，关卡 / 理智药 / 作战开关",
     [("tab", "方舟")], expect=[home("方舟"), "关卡", "理智药", "作战开关"])
step("ark.sanity.bad", "arknights", "理智药填 1000 回车 → 行里红字「没寄出：…要填 0–999 的整数。」（寄出前校验，什么也不发）",
     [("field", "理智药", "1000"), ("enter",), ("wait", 1.2)], expect=["~要填 0–999 的整数"], timeout=6, nocmd=2)
step("ark.sanity.menu", "arknights", "长按理智药那行 → 菜单「再发一次」「不改了」",
     [tap("理智药", hold=900), ("wait", 0.8)], expect=["再发一次", "不改了"],
     ios={"do": [tap({"t": "理智药", "kind": "StaticText"}, hold=900), ("wait", 0.8)]})
step("ark.sanity.again", "arknights", "菜单 · 再发一次 → 还是挡下，红字还在，什么也不发",
     [tap("再发一次", last=True), ("wait", 1.0)], expect=["~要填 0–999 的整数"], absent=["不改了"], nocmd=2)
step("ark.sanity.drop", "arknights", "长按 → 不改了 → 红字消失，理智药回到机器的值",
     [tap("理智药", hold=900), ("until", "不改了", 4), tap("不改了", last=True), ("wait", 1.0)],
     absent=["~要填 0–999 的整数", "不改了"], expect=["理智药"], nocmd=2,
     ios={"do": [tap({"t": "理智药", "kind": "StaticText"}, hold=900), ("until", "不改了", 4), tap("不改了", last=True),
                 ("wait", 1.0)]})
step("ark.stage", "arknights", "关卡填 CE-6 回车 → 马上寄出 set_config（CE-6），那行写「已寄出」",
     [("field", "关卡", "CE-6"), ("enter",), ("wait", 1.2), ("see", "关卡")], expect=[SENT], timeout=10,
     cmd=["~CE-6"], offline={})
step("ark.mail", "arknights", "领取所有邮件奖励 开关 → 马上寄出 set_master（Mail）",
     [("toggle", "领取所有邮件奖励"), ("see", "领取所有邮件奖励")], expect=[SENT], timeout=10, cmd=["~Mail"], offline={})
step("ark.drone", "arknights", "基建无人机用在哪（点右边的值）→ 菜单选「赤金」→ 马上寄出 set_master（PureGold）",
     [tap("贸易站 · 龙门币"), ("wait", 0.8), tap("~赤金", last=True), ("wait", 0.8), ("see", "基建无人机用在哪")],
     expect=["~赤金", SENT], timeout=10, cmd=["~PureGold"], offline={},
     ios={"do": [tap({"t": "~基建无人机用在哪", "kind": "Button"}, right=60), ("wait", 0.8), tap("~赤金", last=True),
                 ("wait", 0.8), ("see", "~基建无人机用在哪")]})
step("ark.menu.left", "arknights", "菜单行：点行左边的名字不出菜单（照原生，只有右边的值能点；已知存疑 D203 不改）",
     [tap("基建无人机用在哪"), ("wait", 0.8)], absent=["不使用"], on="ios")
step("d39.ark.top", "d39", "D39：方舟滑到底再点「方舟」→ 回顶",
     [("swipe", "up", 4), ("tab", "方舟"), ("wait", 1.2)], visible=["关卡"])

# ------------------------------------------------------------------ 终末地
step("ef.open", "endfield", "终末地标签 → 标题「终末地」，库存 / 更多设置",
     [("tab", "终末地")], expect=[home("终末地"), "库存", "更多设置"])
step("ef.title", "endfield", "卡片标题是「终末地 · 另一个任务」（不是「另外两个」）",
     [("swipe", "up", 3)], expect=["~另一个任务"], absent=["~另外两个任务"])
step("ef.stock", "endfield", "库存 → 推入库存页（没配森空岛）",
     [("top", 4), tap("库存")], expect=["~森空岛"], timeout=10)
step("ef.stock.tophone", "endfield", "库存页「去手机页」→ 跳到手机标签", [tap("~去手机页")], expect=["页面版本"])
step("ef.stock.popped", "d39", "回终末地 → 库存页已退掉", [("tab", "终末地")], expect=["库存", "更多设置"])
step("ef.stock.tabpop", "d39", "再进库存 → 点「终末地」→ 回根页",
     [tap("库存"), ("wait", 1.0), ("tab", "终末地")], expect=["库存", "更多设置"], absent=["~去手机页"])
step("ef.more", "endfield", "回终末地根页 · 更多设置 → 推入「基质刷取」页，有「执行周期」",
     [("tab", "终末地"), ("wait", 0.8), ("top", 4), tap("更多设置")], expect=["~执行周期", BACK_BTN])
step("ef.days", "endfield", "执行周期 → 推入选择页 周一…周日", [tap("~执行周期")], expect=["周一", "周日"])
step("ef.days.untick", "endfield", "去掉周日（安卓旧闪退点）→ 不闪退，还在选择页", [tap("周日"), ("wait", 0.8)], expect=["周一", "周日"])
step("ef.days.back", "endfield", "系统返回 → 「已选 6/7」，那行写「已寄出」（点了就寄出 set_master）",
     [("back",), ("wait", 0.8)], expect=["~6/7", SENT], timeout=10, cmd={"action": "set_master"}, offline={})
step("ef.more.tabpop", "d39", "点「终末地」→ 更多设置页退掉、回根页", [("tab", "终末地")], expect=["库存"], absent=["周日", BACK_BTN])
step("ef.mode", "endfield", "回终末地根页 · 刷取设置菜单 → 地区模式 → 马上寄出 set_master（AutoEssence）",
     [("tab", "终末地"), ("wait", 0.8), tap({"t": "~刷取设置, ", "kind": "Button"}, right=60), ("wait", 0.8),
      tap("~地区模式", last=True), ("wait", 0.8), ("see", "刷取设置")],
     expect=["地区模式", SENT], timeout=10, cmd=["~AutoEssence"], offline={},
     android={"do": [("tab", "终末地"), ("wait", 0.8), tap("随机模式"), ("wait", 0.8), tap("~地区模式", last=True),
                     ("wait", 0.8), ("see", "刷取设置")]})
step("ef.protocol", "endfield", "协议空间 选「武器养成」→ 马上寄出 set_master，那行写「已寄出」",
     [tap({"t": "~干员养成", "kind": "Button"}, right=60), ("wait", 0.8), tap("~武器养成", last=True), ("wait", 0.8),
      ("see", "协议空间")],
     expect=["~武器养成", SENT], timeout=10, cmd={"action": "set_master"}, offline={},
     android={"do": [tap("~干员养成"), ("wait", 0.8), tap("~武器养成", last=True), ("wait", 0.8), ("see", "协议空间")]})
step("ef.collect.more", "endfield", "自动采集 · 更多设置 → 推入页 → 系统返回",
     [tap({"t": "更多设置", "after": "~自动采集"}), ("wait", 1.0), ("back",)], expect=[home("终末地"), "~自动采集"],
     absent=[BACK_BTN], timeout=10)
step("ef.ticket.open", "endfield", "再进「更多设置」→ 执行周期「已选 6/7」（上面寄出的）、使用刻写券关（机器值）",
     [("tab", "终末地"), ("top", 3), tap("更多设置")], expect=["~6/7", "使用刻写券"], switch={"使用刻写券": False})
step("ef.ticket.on", "endfield", "打开「使用刻写券」→ 马上寄出 set_master，那行写「已寄出」",
     [("toggle", "使用刻写券"), ("see", "使用刻写券")], expect=[SENT], switch={"使用刻写券": True}, timeout=10,
     cmd={"action": "set_master"}, offline={})
step("d39.ef.top", "d39", "D39：终末地根页滑到底再点「终末地」→ 回顶",
     [("tab", "终末地"), ("wait", 0.8), ("swipe", "up", 4), ("tab", "终末地"), ("wait", 1.2)], visible=["库存"])

# ------------------------------------------------------------------ 鸣潮
step("ww.open", "wuwa", "鸣潮标签 → 标题「鸣潮」，无音区 / 周本", [("tab", "鸣潮")],
     expect=[home("鸣潮"), "~无音区", "周本打第几个"])
step("ww.what", "wuwa", "刷什么（点右边的值）→ 菜单 无音区 / 凝素领域 / 模拟领域",
     [tap({"t": "~刷什么, ", "kind": "Button"}, right=50)], expect=["凝素领域", "模拟领域"],
     android={"do": [tap("无音区")]})
step("ww.what.same", "wuwa", "选回「无音区」→ 菜单收起、没寄出",
     [tap("无音区", last=True), ("wait", 0.6)], absent=["凝素领域"], nocmd=2)
step("ww.tacet", "wuwa", "刷第几个无音区（安卓旧闪退点）→ 推入选择页 7 行",
     [tap("~刷第几个无音区")], expect=["~雪落无声之愿", "~长路启航之星", BACK_BTN])
step("ww.tacet.pick", "wuwa", "选第 5 个 → 自动回鸣潮页，值变「雪落无声之愿 ＋ 剪心辑梦之影」，马上寄出 set_master",
     [tap("~雪落无声之愿"), ("wait", 1.0), ("see", "~刷第几个无音区")],
     expect=[home("鸣潮"), "~雪落无声之愿", SENT], absent=[BACK_BTN], timeout=10, cmd={"action": "set_master"}, offline={})
step("ww.boss.menu", "wuwa", "周本打第几个（点右边的数）→ 菜单 1…20",
     [("see", "周本打第几个"), tap({"t": "re:^\\d{1,2}$", "after": "周本打第几个"})], expect=["13", "2"],
     ios={"do": [("see", "周本打第几个"), tap({"t": "~周本打第几个", "kind": "Button"}, right=50)]})
step("ww.boss.pick", "wuwa", "菜单 · 选 13 → 行上 13，马上寄出 weekly_boss 13",
     [tap("13", last=True), ("wait", 0.8), ("see", "周本打第几个")],
     expect=[{"t": "13", "after": "周本打第几个"}, SENT], timeout=10, cmd={"action": "weekly_boss", "index": 13}, offline={},
     ios={"expect": ["~13", SENT]})
step("d39.ww.top", "d39", "D39：鸣潮滑到底再点「鸣潮」→ 回顶",
     [("swipe", "up", 4), ("tab", "鸣潮"), ("wait", 1.2)], visible=["~无音区"])

# ------------------------------------------------------------------ 手机
step("ph.open", "phone", "手机标签 → 标题「手机」，页面版本 / 分享免输入链接 / 诊断记录 / 「密钥」行",
     [("tab", "手机")], expect=[home("手机"), "页面版本", "诊断记录", "分享免输入链接", "密钥"],
     absent=["已配置", "复制免输入链接"],
     ios={"say": "手机标签 → 页面版本「x.y.z (n)」/ 诊断记录（说明写「收发消息、网络通断和机器状态」）/ 分享免输入链接 /「密钥」行",
          "expect": [home("手机"), "页面版本", "re:^\\d+\\.\\d+\\.\\d+ \\(\\d+\\)$", "诊断记录", "~收发消息、网络通断和机器状态",
                     "分享免输入链接", "密钥"]})
step("ph.diag.on", "phone", "诊断记录打开 → 分享诊断记录 / 运行自检 / 就是这里",
     [("toggle", "诊断记录")], expect=["~分享诊断记录", "运行自检", "就是这里"])
step("ph.selftest", "phone", "运行自检 → 「自检结果」行「通过 N / 6」（行里，不弹单子）",
     [tap("运行自检"), ("wait", 2.0), ("see", "自检结果")], expect=["自检结果", "re:通过 \\d+ ?/ ?\\d+"], timeout=30)
step("ph.selftest.share", "phone", "分享自检结果 → 系统分享面板 → 关掉 → 回手机页、不闪退",
     [tap("分享自检结果"), ("wait", 2.5), ("back",), ("wait", 1.5)], expect=["自检结果"], timeout=10,
     ios={"do": [tap("分享自检结果"), ("wait", 2.5), tap(SHEET_CLOSE, last=True), ("wait", 1.5)]})
step("ph.clear.ask", "phone", "清空诊断记录 → 确认框 → 取消", [tap("清空诊断记录"), ("until", "清空诊断记录？", 5), CONFIRM_WAIT,
                                                         tap("取消", last=True), ("wait", 0.6)],
     absent=["清空诊断记录？"])
step("ph.share", "phone", "分享诊断记录 → 推入「诊断记录」页（条数 / 大小 / 上传 / 分享诊断记录）",
     [tap("~分享诊断记录")], expect=["条数", "大小", "上传", "分享诊断记录", BACK_BTN], timeout=10)
step("ph.share.sys", "phone", "页里「分享诊断记录」→ 系统分享面板 → 关掉 → 不闪退、还在诊断记录页（62ba009）",
     [tap("分享诊断记录", region="content"), ("wait", 2.5), ("back",), ("wait", 2.0)], expect=["条数", "分享诊断记录"],
     timeout=10,
     ios={"do": [tap("分享诊断记录", region="content"), ("wait", 2.5), tap(SHEET_CLOSE, last=True), ("wait", 1.5)]})
step("ph.share.close", "phone", "系统返回 → 回手机页", [("back",), ("wait", 0.8)], expect=["运行自检"], absent=["条数"])
step("ph.sharelink", "phone", "分享免输入链接 → 系统分享面板 → 关掉 → 回手机页、不闪退",
     [("top", 4), tap("分享免输入链接"), ("wait", 2.5), ("back",), ("wait", 1.5)], expect=["页面版本"], timeout=8,
     ios={"do": [("top", 4), tap("分享免输入链接"), ("wait", 2.5), tap(SHEET_CLOSE, last=True), ("wait", 1.5)]})
step("ph.paste.bad", "phone", "粘贴密钥串 填乱码 → 完成 → 单里写「没存上」，单子还在",
     [tap("粘贴密钥串"), ("wait", 1.0), ("field", {"t": "", "kind": ["TextField", "TextView", "EditText"]}, "zzz"),
      tap(DONE_TOP)],
     expect=["没存上", "粘贴密钥串"], timeout=6,
     # Android: an empty-text selector with kind TextView could match a title first
     android={"do": [tap("粘贴密钥串"), ("wait", 1.0), ("field", {"t": "", "kind": "EditText"}, "zzz"), tap(DONE_TOP)]})
step("ph.paste.close", "phone", "取消 → 确认框「放弃粘贴的内容？」→ 放弃 → 回手机页",
     [tap(CANCEL_TOP), ("until", "放弃粘贴的内容？", 5), CONFIRM_WAIT, tap("放弃", last=True), ("wait", 0.8)],
     expect=["页面版本"], absent=["没存上", "放弃粘贴的内容？"])
DIAG_BTN = "就是这里"
step("diag.bottom.phone", "diag", "诊断开 · 手机页滑到底 → 最后一行在红钮「就是这里」上面（ce8ebc3）",
     [("bottom", 4)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.status", "diag", "诊断开 · 状态根页滑到底 → 「查看全部」在红钮上面",
     [("tab", "状态"), ("wait", 0.8), ("bottom", 8)], last_above=DIAG_BTN, expect=["~查看全部"], on="ios")
step("diag.bottom.all", "diag", "诊断开 · 点「查看全部」→ 进回执页",
     [tap("~查看全部", scroll=False)], expect=["回执"], absent=[STATUS_ROOT], on="ios")
step("diag.bottom.receipts", "diag", "诊断开 · 回执页滑到底 → 最后一行在红钮上面",
     [("bottom", 8)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ark", "diag", "诊断开 · 方舟滑到底 → 最后一行在红钮上面",
     [("tab", "状态"), ("tab", "方舟"), ("wait", 0.8), ("bottom", 6)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ef", "diag", "诊断开 · 终末地根页滑到底 → 最后一行在红钮上面",
     [("tab", "终末地"), ("wait", 0.8), ("bottom", 8)], last_above=DIAG_BTN, on="ios")
step("diag.bottom.ww", "diag", "诊断开 · 鸣潮滑到底 → 最后一行在红钮上面",
     [("tab", "鸣潮"), ("wait", 0.8), ("bottom", 6)], last_above=DIAG_BTN, on="ios")
step("ph.diag.off", "phone", "诊断记录关掉 → 多出的行和「就是这里」收起", [("tab", "手机"), ("top", 4), ("toggle", "诊断记录")],
     absent=["运行自检", DIAG_BTN])
step("diag.off.status", "diag", "诊断关 · 状态根页滑到底 → 最后一行贴着底栏（没有多出的空白）",
     [("tab", "状态"), ("wait", 0.8), ("bottom", 8)], last_bottom=[860, 880], absent=[DIAG_BTN], on="ios")
step("diag.off.ark", "diag", "诊断关 · 方舟滑到底 → 最后一行贴着底栏",
     [("tab", "方舟"), ("wait", 0.8), ("bottom", 6)], last_bottom=[860, 880], on="ios")
step("diag.off.ef", "diag", "诊断关 · 终末地根页滑到底 → 最后一行贴着底栏",
     [("tab", "终末地"), ("wait", 0.8), ("bottom", 8)], last_bottom=[860, 880], on="ios")
step("d39.ph.top", "d39", "D39：手机页滑到底再点「手机」→ 回顶",
     [("tab", "手机"), ("wait", 0.8), ("swipe", "up", 4), ("tab", "手机"), ("wait", 1.2)], visible=["页面版本"])

# ------------------------------------------------------------------ shift change while on a game tab (pass-1 item 6, fix 5)
step("noef.jump", "layout", "人在终末地，机器发来早班不含终末地的状态（实时分片，不刷新）→ 终末地标签还在，页面变空页「这个班次没有终末地」",
     [("tab", "终末地"), ("wait", 1.0), ("state", "noef")], expect=[TAB_EF, "这个班次没有终末地", "去「状态」页"],
     absent=["库存"], timeout=30,
     offline={"say": "人在终末地，缓存注入早班不含终末地的状态、冷启动 → 终末地标签还在，点进去是空页「这个班次没有终末地」",
              "do": [("tab", "终末地"), ("wait", 1.0), ("state", "noef"), ("wait", 2.0), ("tab", "终末地"), ("wait", 1.0)]})
step("noef.back", "layout", "机器发回原状态 → 终末地页回来（库存 / 更多设置）",
     [("state", "base"), ("wait", 6), ("tab", "终末地"), ("wait", 1.0)], expect=[TAB_EF, "库存"],
     absent=["这个班次没有终末地"], timeout=30)

# ------------------------------------------------------------------ duplicate receipts (pass-1 item 5, fix 3)
step("dup.status", "receipts", "同一分钟两条一样的回执 → 状态页两行都在、不崩",
     [("state", "dup"), ("tab", "状态"), ("wait", 3), ("see", "周本：打第 2 个")],
     expect=[{"t": "周本：打第 2 个", "count": 2}], timeout=25)
step("dup.page", "receipts", "查看全部 → 回执页也有这两行（不是旧数据）",
     [tap("~查看全部")], expect=["回执", {"t": "周本：打第 2 个", "count": 2}], timeout=10)
step("dup.done", "receipts", "回状态，发回原状态", [("tab", "状态"), ("state", "base")], expect=[HOME], absent=[BACK_BTN])

# ------------------------------------------------------------------ 刷声骸 in progress (cache / state injection; 796103b)
FH, FM = FARM_HHMM.split(":")
step("farm.show", "farm", f"机器正在刷声骸（到机器时间 {FARM_HHMM}）→ 「刷声骸」段：正在刷 回放Boss / 刷到（机器时间）/ 提前收工",
     [("state", "farm"), ("tab", "状态"), ("wait", 1.0), ("see", "提前收工")],
     expect=["正在刷", "回放Boss", "刷到（机器时间）", "提前收工"], timeout=30)
step("farm.row", "farm", "刷 4C 那段收起：没有「打哪个」「开始刷」",
     [("see", "提前收工")], absent=["开始刷", "打哪个", "刷 4C 声骸"])
step("farm.capsule", "farm", f"「刷到（机器时间）」胶囊显示机器时间的「到」{FARM_HHMM}（不随手机时区）",
     [], expect=[{"t": f"re:^0?{int(FH)}:{FM}$", "kind": "Button"}],
     android={"expect": [f"re:^(0?{int(FH)}:{FM}|{int(FH) % 12 or 12}:{FM} {'AM' if int(FH) < 12 else 'PM'})$"]})
step("farm.pick", "farm", "刷到（机器时间）· 拨 23 / 30 → 胶囊「23:30」，改了就寄出 echo_farm_until 23:30，没进别的页",
     [("time", "刷到（机器时间）", 23, 30)], expect=["23:30", "提前收工"], absent=["终末地月卡"],
     cmd={"action": "echo_farm_until", "until": "23:30"}, offline={},
     android={"do": [("time", "刷到", 23, 30)], "expect": ["re:^(23:30|11:30 PM)$", "提前收工"]})
step("farm.done", "farm", "发回原状态 → 「打哪个」「开始刷」回来、「提前收工」没了",
     [("state", "base"), ("wait", 1.0), ("see", "开始刷")],
     expect=["打哪个", "开始刷"], absent=["提前收工", "回放Boss"], timeout=30)

# ------------------------------------------------------------------ two-time receipts (ce8ebc3)
TWO_T = "re:\\d\\d:\\d\\d 发出 · .*执行"
step("times.show", "receipts", "两条测试回执（单时间 / 发出≠执行）→ 状态页两行都在，两段时间那行时间在文字下面、不压字",
     [("state", "times"), ("tab", "状态"), ("wait", 1.0), ("see", "~回放两时间回执")],
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
PASTE_BTN = ["粘贴免输入链接", "Paste", "粘贴"]   # SetupScreen.swift: iOS shows the system PasteButton
step("clip.after.link", "clip", "已配置：剪贴板里是免输入链接 → 冷启动 22 秒不闪退",
     [("clipboard", "@link"), ("relaunch",), ("allow_paste", 10), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.after.hello", "clip", "已配置：剪贴板里是「hello」→ 冷启动 22 秒不闪退",
     [("clipboard", "hello"), ("relaunch",), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.after.empty", "clip", "已配置：剪贴板是空的 → 冷启动 22 秒不闪退",
     [("clipboard", ""), ("relaunch",), ("wait", CLIP_WAIT)], expect=[STATUS_ROOT], timeout=20, on="ios")
step("clip.first.empty", "clip", "没配置：剪贴板空 → 「第一次使用」页（开始使用 + 系统粘贴按钮），22 秒不闪退",
     [("forget_config",), ("clipboard", ""), ("relaunch",), ("wait", CLIP_WAIT)],
     expect=["第一次使用", "开始使用", PASTE_BTN], timeout=20, on="ios")
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
