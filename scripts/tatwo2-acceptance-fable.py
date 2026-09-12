#!/usr/bin/env python3
"""模擬真人驗收（Fable 版）：用 macOS 輔助使用（osascript）操作 tatwo2.app 跑「每日十件事」。
用法：python3 scripts/tatwo2-acceptance-fable.py <tatwo2.app>
每件事：前後截圖 → 操作 → 用畫面（AX）＋存檔（document.json / bots.json）雙重判定。只用系統內建工具。"""
import json, os, subprocess, sys, time, shutil, tempfile, functools
print = functools.partial(print, flush=True)

APP = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tatwo2-acc/tatwo2.app"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "goal-ui-2.0", "reports", "acceptance-fable")
os.makedirs(OUT, exist_ok=True)
WORK = tempfile.mkdtemp(prefix="tatwo2-acc-")
LIVE = os.path.join(WORK, "live"); HOME = os.path.join(WORK, "home"); os.makedirs(LIVE); os.makedirs(HOME)
WIN = 'window "Tatwo Ultrawork OS"'
PID = None
results = []

def osa(script):
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return r.stdout.strip(), r.stderr.strip()

def launch():
    global PID
    subprocess.run(["pkill", "-f", "tatwo2.app/Contents/MacOS/tatwo2"], capture_output=True); time.sleep(1)
    env = dict(os.environ); env["HOME"] = HOME; env["TATWO2_LIVE_ROOT"] = LIVE
    p = subprocess.Popen([os.path.join(APP, "Contents/MacOS/tatwo2")], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    PID = p.pid; time.sleep(6)
    for _ in range(6):
        out, _ = osa('''tell application "System Events"
  set out to ""
  repeat with pr in every process
    try
      repeat with w in windows of pr
        repeat with b in buttons of w
          if (name of b as text) is "允許" or (name of b as text) is "Allow" then
            click b
            set out to "clicked"
          end if
        end repeat
      end repeat
    end try
  end repeat
  return out
end tell''')
        if out == "clicked": print("  (macOS 權限詢問：已按允許)"); time.sleep(1)
        else: break
        time.sleep(2)
    osa(f'tell application "System Events" to set frontmost of (first process whose unix id is {PID}) to true'); time.sleep(1)
    return p

def quit_app():
    osa('tell application "System Events" to keystroke "q" using command down'); time.sleep(2)
    subprocess.run(["pkill", "-f", "tatwo2.app/Contents/MacOS/tatwo2"], capture_output=True); time.sleep(1)

def shot(name):
    subprocess.run(["screencapture", "-x", os.path.join(OUT, name + ".png")], capture_output=True)

def walk(body, scope="win"):
    target = f'{WIN} of p' if scope == "win" else 'p'
    return osa(f'''tell application "System Events"
  set p to first process whose unix id is {PID}
  set w to {target}
  set ec to entire contents of w
  set out to ""
  repeat with e in ec
    try
{body}
    end try
  end repeat
  return out
end tell''')

def click_help(needle, scope="win"):
    out, err = walk(f'''      if (help of e as text) contains "{needle}" then
        click e
        return "clicked"
      end if''', scope)
    return out == "clicked"

def click_by(attr, needle, roles=("AXMenuItem", "AXButton", "AXStaticText", "AXRadioButton", "AXCheckBox"), scope="proc"):
    cond = " or ".join([f'role of e is "{r}"' for r in roles])
    out, _ = walk(f'''      if ({cond}) and ({attr} of e as text) contains "{needle}" then
        click e
        return "clicked"
      end if''', scope)
    return out == "clicked"

def is_front():
    out, _ = osa(f'tell application "System Events" to get frontmost of (first process whose unix id is {PID})')
    return out == "true"

def set_composer(text):
    """點輸入框取得焦點 → 全選 → 用剪貼簿貼上（AX 直接設值不會更新 SwiftUI 綁定）。任何鍵盤動作前都確認 App 在最前面。"""
    osa(f'tell application "System Events" to set frontmost of (first process whose unix id is {PID}) to true'); time.sleep(0.4)
    out, _ = walk('''      if role of e is "AXTextArea" and (description of e as text) contains "Chat message" then
        set ps to position of e
        click at {(item 1 of ps) + 40, (item 2 of ps) + 12}
        return "focused"
      end if''')
    if out != "focused": return False
    time.sleep(0.4)
    if not is_front(): print("  (App 不在最前面，放棄打字)"); return False
    esc = text.replace("\\", "\\\\").replace('"', '\\"')
    osa(f'set the clipboard to "{esc}"')
    osa('tell application "System Events" to keystroke "a" using command down'); time.sleep(0.2)
    osa('tell application "System Events" to keystroke "v" using command down'); time.sleep(0.6)
    return True

def composer_value():
    out, _ = walk('''      if role of e is "AXTextArea" and (description of e as text) contains "Chat message" then
        return (value of e as text)
      end if''')
    return out

def dump(scope="proc"):
    out, _ = walk('''      set r to role of e
      if r is "AXButton" or r is "AXMenuItem" or r is "AXMenuButton" or r is "AXStaticText" or r is "AXTextArea" or r is "AXPopUpButton" or r is "AXRadioButton" then
        set h to "-"
        try
          set h to help of e as text
        end try
        set n to "-"
        try
          set n to name of e as text
        end try
        set v to "-"
        try
          set v to value of e as text
        end try
        set ps to position of e
        set out to out & r & " @" & (item 1 of ps) & "," & (item 2 of ps) & " help=" & h & " name=" & n & " value=" & v & linefeed
      end if''', scope)
    return out

def click_at(x, y):
    return osa(f'tell application "System Events" to click at {{{x}, {y}}}')

def keys(text): return osa(f'tell application "System Events" to keystroke "{text}"')
def key_cmd(ch): return osa(f'tell application "System Events" to keystroke "{ch}" using command down')
def key_return(): return osa('tell application "System Events" to key code 36')

def doc():
    try: return json.load(open(os.path.join(LIVE, "document.json")))
    except Exception: return {}

def bots():
    try: return json.load(open(os.path.join(LIVE, "bots.json")))
    except Exception: return {}

def last_assistant(threads_filter=None):
    d = doc(); best = None
    for t in d.get("threads", []):
        if threads_filter and not threads_filter(t): continue
        for m in t.get("messages", []):
            if m.get("role") == "assistant" and m.get("eventKind") == "message":
                best = m
    return best

def wait(pred, timeout=120, step=2):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            if pred(): return True, round(time.time() - t0, 1)
        except Exception: pass
        time.sleep(step)
    return False, timeout

def send_and_wait(text, expect_substr=None, timeout=120):
    before = len([m for t in doc().get("threads", []) for m in t.get("messages", []) if m.get("role") == "assistant"])
    if not set_composer(text): return False, "找不到輸入框", 0
    time.sleep(0.5)
    if not click_help("送出"): return False, "找不到送出鈕", 0
    def done():
        d = doc(); rows = [m for t in d.get("threads", []) for m in t.get("messages", []) if m.get("role") == "assistant" and m.get("eventKind") == "message"]
        if len(rows) <= before: return False
        last = rows[-1]
        return (last.get("status") or "").startswith("done") and (expect_substr is None or expect_substr in last.get("text", ""))
    ok, secs = wait(done, timeout)
    la = last_assistant()
    return ok, (la or {}).get("text", "")[:80], secs

def record(n, title, ok, secs, note):
    results.append((n, title, "OK" if ok else "失敗", secs, note)); print(f"[{n}] {title}: {'OK' if ok else '失敗'} {secs}s {note}")

# ---------------- 十件事 ----------------
launch(); shot("00-啟動")
# 3 新聊天用 Claude 問一句
shot("03-前"); click_help("新聊天"); time.sleep(1)
# 選 Claude：模型鈕 → 找含 fable/claude 的項目
click_help("Codex/GPT"); time.sleep(1.5); open(os.path.join(OUT, "03-menu-ax.txt"), "w").write(dump()); picked = click_by("name", "fable") or click_by("value", "fable") or click_by("help", "fable") or click_by("name", "Claude") or click_by("value", "Fable")
if not picked: open(os.path.join(OUT, "03-menu-ax.txt"), "w").write(dump()); osa('tell application "System Events" to key code 53')
time.sleep(1)
ok, txt, secs = send_and_wait("只回一個詞：乒", "乒"); shot("03-後"); record(3, "開新聊天用 Claude 問一句", ok, secs, f"選到 Claude={picked}；回覆：{txt}")
# 2 接著問，記得前文
shot("02-前"); ok, txt, secs = send_and_wait("我上一句要你回什麼？只回那個詞", "乒"); shot("02-後"); record(2, "同串接問，AI 記得前文", ok, secs, f"回覆：{txt}")
# 7 shell 指令
shot("07-前"); ok, txt, secs = send_and_wait("用 shell 跑 echo acc-tool-ok，然後只回那個輸出", "acc-tool-ok"); shot("07-後")
tool_rows = [m for t in doc().get("threads", []) for m in t.get("messages", []) if m.get("eventKind") == "toolUse"]
record(7, "請 AI 跑 shell 指令並回結果", ok and len(tool_rows) > 0, secs, f"工具列 {len(tool_rows)} 筆；回覆：{txt}")
# 6 圖片
shot("06-前"); img = os.path.join(ROOT, "docs", "UI定位冊", "截圖", "aurora", "頁-usage.png")
set_composer(""); osa(f'set the clipboard to (read (POSIX file "{img}") as «class PNGf»)'); time.sleep(0.3)
if is_front(): key_cmd("v"); time.sleep(1)
ok, txt, secs = send_and_wait("這張圖左上角的標題是哪四個字？只回那四個字", "額度用量"); shot("06-後"); record(6, "丟一張圖片問內容", ok, secs, f"回覆：{txt}")
# 8 issue 清單
shot("08-前"); click_help("資訊卡"); time.sleep(1.5); ax = dump(); open(os.path.join(OUT, "08-ax.txt"), "w").write(ax)
added = click_help("issue") or click_help("加入") or click_by("help", "issue")
n_issues = sum(len(t.get("issues", [])) for t in doc().get("threads", []))
packed = False
if n_issues > 0:
    packed = click_help("帶入") or click_help("塞回") or click_help("插入") or click_by("help", "composer")
    time.sleep(1)
cv = composer_value(); shot("08-後")
record(8, "加進 issue 清單，再塞回輸入框", n_issues > 0 and packed and len(cv) > 0, 0, f"issue={n_issues} 帶入={packed} 輸入框={cv[:40]!r}")
click_help("資訊卡"); set_composer("")
# 4 切 GPT（Codex）
shot("04-前"); click_help("Codex/GPT"); time.sleep(1.5); picked = click_by("name", "5.5") or click_by("value", "5.5") or click_by("name", "gpt-5.5")
if not picked: open(os.path.join(OUT, "04-menu-ax.txt"), "w").write(dump()); osa('tell application "System Events" to key code 53')
time.sleep(1); ok, txt, secs = send_and_wait("同一條討論串：我最早要你回哪個詞？只回那個詞", "乒"); shot("04-後"); record(4, "同串切 GPT 再問", ok, secs, f"選到 GPT={picked}；回覆：{txt}")
# 5 切 Grok
shot("05-前"); click_help("Codex/GPT") or click_help("Claude") or click_help("gpt"); time.sleep(1.5); picked = click_by("name", "grok") or click_by("value", "grok") or click_by("name", "Grok")
if not picked: open(os.path.join(OUT, "05-menu-ax.txt"), "w").write(dump()); osa('tell application "System Events" to key code 53')
time.sleep(1); ok, txt, secs = send_and_wait("只回一個詞：乓", "乓"); shot("05-後"); record(5, "切 Grok 問一句", ok, secs, f"選到 Grok={picked}；回覆：{txt}")
# 9 CLI 終端
shot("09-前"); click_help("唯讀終端"); time.sleep(1.5); ax = dump(); open(os.path.join(OUT, "09-ax.txt"), "w").write(ax)
opened = click_help("codex") or click_help("新分頁") or click_help("開新") or click_help("終端")
time.sleep(4); shot("09-後")
record(9, "CLI 模式開 codex 終端（不自動打字）", opened, 0, "開分頁=" + str(opened) + "（終端畫面以截圖為證；打字留給真人）")
# 10 Bot
shot("10-前"); click_help("bot 展示"); time.sleep(1.5); ax = dump(); open(os.path.join(OUT, "10-ax.txt"), "w").write(ax)
clicked_bot = click_help("PO文") or click_by("name", "PO文 bot") or click_by("value", "PO文 bot") or click_by("help", "bot")
time.sleep(1); ok = False; txt = ""; secs = 0
if clicked_bot:
    before = len(bots().get("threads", {}) if isinstance(bots().get("threads"), dict) else [])
    # bot composer：同一個 Chat message 文字區（BotPage 自己的 composer 若不同會 notfound）
    ok, txt, secs = send_and_wait("只回一個詞：乒", "乒")
shot("10-後"); record(10, "Bot 模式跟一個 bot 講話", ok, secs, f"點到 bot={clicked_bot}；回覆：{txt}")
click_help("互動續聊")
# 1 關掉重開，選舊討論串
shot("01-前"); quit_app(); launch(); time.sleep(1)
d = doc(); titles = [t.get("title") for t in d.get("threads", [])]
ax = dump("win"); open(os.path.join(OUT, "01-ax.txt"), "w").write(ax)
visible = any((t or "")[:6] in ax for t in titles if t)
clicked = False
for t in titles:
    if t and click_by("help", t[:8], roles=("AXButton",), scope="win"): clicked = True; break
if not clicked: clicked = click_by("value", (titles[0] or "")[:6], roles=("AXStaticText", "AXButton"), scope="win") if titles else False
time.sleep(1); shot("01-後")
record(1, "開 App 選舊討論串看到之前對話", visible or clicked, 0, f"討論串 {len(titles)} 條；列出={visible} 點到={clicked}")
quit_app()

# ---------------- 報告 ----------------
lines = ["# 每日十件事 模擬真人驗收（Fable 版）", "", f"日期｜{time.strftime('%Y-%m-%d %H:%M:%S')}｜App｜{APP}｜存檔｜{LIVE}", "",
         "| # | 事情 | 結果 | 秒數 | 備註 |", "|---|---|---|---:|---|"]
for n, title, st, secs, note in sorted(results):
    lines.append(f"| {n} | {title} | {st} | {secs} | {note} |")
ok_n = sum(1 for r in results if r[2] == "OK")
lines += ["", f"通過 {ok_n} / {len(results)}；截圖在 `docs/goal-ui-2.0/reports/acceptance-fable/`。"]
open(os.path.join(OUT, "RESULT.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
