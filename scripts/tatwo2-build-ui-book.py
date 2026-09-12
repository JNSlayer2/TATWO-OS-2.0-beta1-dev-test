#!/usr/bin/env python3
"""把 docs/UI定位冊/截圖/manifest.tsv 組成 docs/UI定位冊.md（白話版，給使用者逐頁過目）。"""
import csv, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOT = os.path.join(ROOT, "docs", "UI定位冊", "截圖")
OUT = os.path.join(ROOT, "docs", "UI定位冊.md")

# 每個房間：標題、白話說明、這頁上有什麼、底下接的水電（1.0 現況）、截圖名稱前綴
ROOMS = [
    ("對話頁 chat 模式", "你每天用最多的頁。左邊是討論串列表，中間是對話，下面是輸入框。",
     ["左列：討論串清單、chat/cli/bot 三格切換、專案資料夾",
      "中間：對話串（你的話靠右、AI 的話靠左、工具執行顯示成一行）",
      "下面輸入框：＋附件、代我核准開關、模型與速度（5.5 fast）、ultrawork 膠囊、送出箭頭",
      "輸入框下方一行提示（例如「無額外提醒」）"],
     "1.0：總開關箱（ChatPageModel）→ 每輪新開子行程包 CLI。2.0：常駐 Claude sidecar / Codex app-server。",
     ["chat-send", "chat-stream", "chat-stop", "chat-resume", "chat-slash", "chat-plg", "chat-engine_switch",
      "chat-reattach", "chat-cold_start", "chat-orphan", "chat-queued_turn"]),
    ("右側資訊卡與浮動資訊卡", "對話頁右邊那張卡：這條討論串的資訊、issue 清單、GitHub repo 綁定。",
     ["討論串名稱、模型、工作目錄", "issue 清單區", "GitHub repo 綁定區", "可以收成浮動小卡"],
     "1.0：讀總開關箱的狀態。2.0：讀討論串檔（JSON）。",
     ["chat-右側資訊卡", "chat-浮動資訊卡"]),
    ("模型選單與 ultrawork 面板", "輸入框上那顆模型按鈕按下去的選單，以及 ultrawork 膠囊展開的面板。",
     ["品牌分區（Claude / Codex / Grok）", "每個模型的速度、額度", "ultrawork 協作等級"],
     "1.0：TeamRouting 目錄 + 額度快取。2.0：各引擎自己回報的模型清單 + 額度。",
     ["chat-模型選單", "chat-ultrawork面板"]),
    ("主題選擇浮層", "設定裡選主題的地方：極光玻璃 / Fable5 紀念。",
     ["兩張主題卡", "紙紋、玻璃強度"],
     "純本機設定，不需要水電。",
     ["chat-主題選擇"]),
    ("靈動島", "視窗頂端中間那顆會展開的島。",
     ["收合：目前狀態一行", "展開：進行中的工作、額度"],
     "1.0：讀 AppShell 狀態。2.0：讀 sidecar 狀態。",
     ["chat-靈動島展開"]),
    ("內建瀏覽器面板", "對話頁右側可以開出來的瀏覽器（擋廣告、WebMCP）。",
     ["網址列與工具列", "分頁", "安全設定"],
     "1.0：CEF 引擎 + 安全層。2.0：先原樣保留，最後一個房間才換。",
     ["chat-瀏覽器面板"]),
    ("對話頁 cli 模式（終端機）", "像 Terminal 一樣看 AI 跑指令的分頁，左列是 session 樹。",
     ["左列 session 樹", "中間真終端（PTY）", "loops 活動監看"],
     "1.0：NativeTerminalCore + PTY。2.0：同樣的 PTY，接到 sidecar 的工具輸出。",
     ["cli-終端機模式"]),
    ("對話頁 bot 模式", "bot 展示面：左列 rail、space、quick card、設定九列。",
     ["rail 樹 / 收合 / 空狀態", "討論串", "space 全/精簡/狀態", "新增 space", "quick card", "設定九列", "壓力測試小視窗"],
     "1.0：純假資料展示，沒接水電。2.0：接 sidecar 之後才有真資料。",
     ["bot-rail-tree", "bot-rail-collapsed", "bot-rail-empty", "bot-thread", "bot-group-sandbox", "bot-space-full",
      "bot-space-compact", "bot-space-status", "bot-add-space", "bot-quick-card", "bot-settings-9row", "bot-stress"]),
    ("額度用量頁", "各家訂閱的額度卡。", ["每個 provider 一張卡：已用、剩餘、重置時間"],
     "1.0：讀本機快取 + 各家用量 API。2.0：同上，簡化。", ["頁-usage"]),
    ("配置總覽頁（模式・情境・特質卡）", "模式、情境、特質卡收斂成的一頁。",
     ["模式卡", "情境卡", "特質卡（每個 AI 的性格與強項）"],
     "1.0：讀固定目錄檔。2.0：同上，不變。", ["頁-modes"]),
    ("外掛工具 / skillet 頁", "技能與 MCP 的登記表、skillet 詳情。",
     ["canonical skills 目錄", "MCP 清單", "skillet 詳情分頁"],
     "1.0：直接讀 skills 資料夾。2.0：同上，不變。", ["頁-plugins"]),
    ("設備頁（雙機同步）", "mini 與 MacBook 互傳設定、壓力監控。",
     ["跨裝置同步卡", "壓力監控卡"],
     "1.0：DeviceSyncOutbox + device-sync.sh。2.0：先原樣保留，最後才換。", ["頁-devices"]),
    ("Ultrawork 手冊頁", "工具原則、架構手冊章節。", ["章節清單", "Work OS live 證據區"],
     "1.0：靜態手冊 + WorkOS 狀態。2.0：靜態手冊留，WorkOS 狀態區進拆除提案。", ["頁-workflow"]),
]

LIVE = {  # 房間標題 → 真機截圖名（docs/UI定位冊/真機/<主題>/<名>.png）
    "對話頁 chat 模式": "chat-含左列",
    "右側資訊卡與浮動資訊卡": "chat-右側資訊卡",
    "模型選單與 ultrawork 面板": "chat-模型選單",
    "主題選擇浮層": "chat-主題選擇",
    "靈動島": "chat-靈動島",
    "對話頁 cli 模式（終端機）": "cli-含左列",
    "對話頁 bot 模式": "bot-討論串",
    "額度用量頁": "頁-usage",
    "配置總覽頁（模式・情境・特質卡）": "頁-modes",
    "外掛工具 / skillet 頁": "頁-plugins",
    "設備頁（雙機同步）": "頁-devices",
    "Ultrawork 手冊頁": "頁-workflow",
}

DECISIONS = [
    ("2026-09-03", "使用者", "房間全留、保全拆、水電重拉；拆之前一律先討論。"),
    ("2026-09-03", "使用者", "考試文件夾、4414 個自動檢查：先不動。"),
    ("2026-09-03", "使用者", "極光玻璃與 Fable5 紀念主題兩套都留。"),
    ("2026-09-03", "使用者", "/goal：2.0 UI 與分頁切換全部先做好（純 UI＋假資料），可派 sol 照搬重建，Fable 驗收。"),
    ("2026-09-03", "Fable", "goal 完成：2.0 薄殼全部房間照搬完成，72/72 金樣通過（docs/goal-ui-2.0/reports/regress-20260903-final.tsv）。"),
    ("2026-09-03", "使用者", "拆除提案第一批裁決：#1 Loops 軌拆併入討論串；#3 模式頁與情境頁拆；#6 設備同步收據留；#2 協作等級、#4 證據區、#5 skill 簽名、#7 PLG 進度卡先不動。"),
    ("2026-09-03", "使用者", "工具組裡的 loops 直接跟討論串合併（不再獨立一條軌）；像 bot 分頁和 tatwo island 一樣，2.0 先把 UI 架好再接水電。→ 待 M1 過目時確認呈現方式。"),
]

def main():
    status = {}
    with open(os.path.join(SHOT, "manifest.tsv"), encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            if len(row) >= 3:
                status[(row[0], row[1])] = row[2]
    L = []
    L.append("# UI 定位冊（2.0 的凍結目標）\n")
    L.append("每個房間先看「真機外觀」（真的開在桌面上、有桌布和玻璃折射），再看「假資料匯出」（1.0 金樣同款，背景透明所以偏灰白）。兩套主題：極光玻璃、Fable5 紀念。")
    L.append("請逐頁看，在「你的裁決」欄寫：照留 / 要改（寫哪裡） / 不要。沒寫的視同「照留」。\n")
    L.append("## 使用者裁決紀錄\n")
    L.append("| 日期 | 誰 | 裁決 |\n|---|---|---|")
    for d, who, what in DECISIONS:
        L.append(f"| {d} | {who} | {what} |")
    L.append("")
    L.append("## 房間總表\n")
    L.append("| 房間 | 極光 | Fable5 |\n|---|---|---|")
    for title, _, _, _, shots in ROOMS:
        a = sum(1 for s in shots if status.get(("aurora", s)) == "ok")
        b = sum(1 for s in shots if status.get(("fable5", s)) == "ok")
        L.append(f"| {title} | {a}/{len(shots)} 張 | {b}/{len(shots)} 張 |")
    L.append("")
    for title, blurb, items, wiring, shots in ROOMS:
        L.append(f"## {title}\n")
        L.append(blurb + "\n")
        L.append("這頁上有什麼：")
        for it in items:
            L.append(f"- {it}")
        L.append(f"\n底下接的水電：{wiring}\n")
        L.append("你的裁決：（照留 / 要改：＿＿ / 不要）\n")
        live = LIVE.get(title)
        if live:
            L.append("真機外觀（桌面上真的開起來的樣子）：\n")
            for theme, label in (("aurora", "極光"), ("fable5", "Fable5 紀念")):
                rel = f"UI定位冊/真機/{theme}/{live}.png"
                if os.path.exists(os.path.join(ROOT, "docs", rel)):
                    L.append(f"**{label}**\n\n![{live} {label}]({rel})\n")
            L.append("假資料匯出（1.0 金樣同款，背景透明所以偏灰白；M3 換水電時拿來逐像素比對）：\n")
        for s in shots:
            for theme, label in (("aurora", "極光"), ("fable5", "Fable5 紀念")):
                st = status.get((theme, s), "缺")
                rel = f"UI定位冊/截圖/{theme}/{s}.png"
                if st == "ok":
                    L.append(f"**{s}・{label}**\n\n![{s} {label}]({rel})\n")
                else:
                    L.append(f"**{s}・{label}**：假資料模式拍不出來（{st}），M3 換水電時補真機截圖。\n")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("wrote", OUT, "rooms", len(ROOMS), "ok", sum(1 for v in status.values() if v == "ok"), "blocked",
          sum(1 for v in status.values() if v != "ok"))

if __name__ == "__main__":
    main()
