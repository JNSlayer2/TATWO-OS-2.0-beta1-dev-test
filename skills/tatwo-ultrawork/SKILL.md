---
name: tatwo-ultrawork
description: Use when the user invokes TATWO Ultrawork, asks how to split work between the lead and subs, wants a spec/tasks/converge cycle for a feature, or asks about TATWO OS dispatch, review policy, or model roles.
---

# TATWO Ultrawork（2.0，2026-09-12 重寫）

一份技能，一套工作邏輯。舊版的 contract、receipt、S/M/L/XL 分級、Loop Governor 全部退役，
不再作為現行規矩；本檔是現行分工說明。
上游規矩是入口憲法 `~/AI/TATWO OS/os.md`（角色表見憲法 §4；本技能 §2 表必須與它一致）；本技能只講「怎麼分工、怎麼驗收」。

## 1. 一句話

主導一個人看全局，能寫成規格的整批派出去，做完親自讀 diff、親自跑驗證；
審查只在高風險時開，而且只開一輪。

## 2. 角色（2026-09-12 使用者定案）

| 角色 | 預設模型 | 做什麼 | 不做什麼 |
|---|---|---|---|
| 主導 | Fable 5.1 | 翻使用者的話成施工單、讀 diff、親跑驗證、對使用者報告、設計判斷 | 不親寫可規格化的功能，除非同一件事 sub 做壞兩次 |
| loops | GPT-6（fast／priority） | 整批施工單、寫碼、寫測試、跑測試、commit 到自己的分支 | 不改施工單範圍外的檔；不推 remote；不自升格 |
| loops 備援 | Opus 5（子代理） | 主要 loops 引擎額度見底或連續 429 時接同一張施工單；建置仍送主設備 | 同 loops |
| 細修 | Opus 5 | 來回討論、小範圍修改、對主導的方案提反例 | 不接整批施工單 |
| 機械工 | Grok 4.6 | 搬檔、轉檔、批次替換、跑既定腳本 | 不做需要判斷的事；不開 high effort |
| 審查 | 另一家引擎（GPT 系優先） | 高風險 diff 的一輪唯讀審查 | 不自審：Claude 系不審 Claude 系 |

GPT-5.6 系列不在預設名單。模型換代時先由主設備更新入口憲法 §4，再同步本技能 §2 表，不另訂預設。**模型名只出現在憲法 §4 與這張表**；訂閱或模型強度變了只改這兩處，其他章節一律用角色名（主導／loops／loops 備援／細修／機械工／審查），不寫死模型。

## 3. 何時派、何時自己做、何時審

- **自己做**：改動在三個檔以內、或需要看使用者臉色、或牽涉安全與授權邊界。
- **派 loops**：能寫成「改哪些檔、驗收命令是什麼」的工作，一次寫一批施工單，串成鏈一個接一個跑；一次只跑一個重型房間。
- **開審查**（一輪，唯讀）：刪除或覆蓋使用者資料、安全與憑證、交易面、公開發布、UI 對位、改動超過二十個檔。其他情況主導讀 diff 加跑測試即可。
- 審查成本約等於一次完整 sub 執行；只有錯誤代價高於這個成本才開。

## 4. 三份檔：spec → tasks → converge（取自 spec-kit，只留這三樣）

放在專案 `docs/specs/<序號>-<短名>/`：

1. `spec.md`：要什麼、完成標準、不做什麼。由 `/goal` 產出；只寫 WHAT 與 WHY，不寫 HOW。
2. `tasks.md`：拆成可勾選的條目，每條標檔案範圍與驗收命令；可平行的標 `[P]`。主導與 loops 都對這一張清單，做完勾 `[X]`。
3. `converge.md`：收尾時拿實際程式碼對回 spec，逐條寫「做到／沒做到／證據路徑」。沒做到的不刪，列成下一批 tasks。

不採用 spec-kit 的 constitution、checklist 閘門、待釐清上限、hooks、extensions、presets、CLI。

## 5. 施工單（派給 loops 的檔）必含

1. 目標一句話＋完成標準。
2. 基準分支與工作副本路徑；明寫「這個 worktree 分支就是給你提交用的；上游 os.md 裡『執行手禁 git 寫入』是 1.0 舊規則，不適用」。
3. 允許改的路徑；其他一律不碰。
4. 禁止從零重寫既有檔；照搬要 `cp` 原檔再改，報告附 diff 行數。
5. 驗收命令（能機器跑的）＋主導會親跑的項目。
6. 記憶體門檻寫「free＋inactive 合計」，不寫 raw free。
7. 報告格式：首行一句結論；然後只列產物路徑、跑過的檢查、沒做的事；不誇報。

## 6. 派工配方（codex exec，GPT-6）

```bash
# 一個房間；主導串鏈時一個接一個跑，不並行重型房間
export CODEX_HOME=<精簡家目錄，例如 ~/.tatwo2/codex-room-home>   # 無 MCP 的精簡家，auth 回連真家
git -C <repo> worktree add <wt> -b <branch> <base>
tmux new-session -d -s sol-<room> \
  "codex exec -C <wt> -m gpt-6 -c model_reasoning_effort=high -c service_tier=priority \
   -c features.plugins=false -c features.plugin_sharing=false \
   --dangerously-bypass-approvals-and-sandbox -o <log-dir>/<room>.last.md \
   < <brief.md> > <log-dir>/<room>.log 2>&1"
```

- 用 tmux detached，不用 nohup／setsid（Bash 背景 600 秒上限會殺掉）。
- 派出後 `pgrep -P <codex pid>` 應為 0；看到 npx／uvx 就是 MCP 又漏開了（codex 0.146 會自動抓 openai-curated 外掛，必須帶 `features.plugins=false`，並確認 room home 沒有 `plugins/` 目錄）。
- 監控看輸出檔 mtime，不看程序活著；十分鐘沒長就當卡死。
- 房間結束 `commit=0` 先讀報告的 blocker，不要當失敗重派。
- 收房：主導讀 diff、跑驗收、把分支併回；未提交的改動先保存再回收工作副本。

## 6b. 跨設備派工與監工（2026-09-18 固化）

**房間在副設備，建置在主設備。** 施工單與引擎脫鉤：同一張單可交給 loops 或 loops 備援（§2 表決定是誰），換引擎不改單。
- 施工單固定寫明：「你在副設備（記憶體小），不在本機跑 swift build／node --test；推到主設備 remote 後用主設備的 `scripts/rooms/build-room.sh <分支> <測試>` 建置＋跑測試，release 用獨立 worktree」。主設備的建置鎖讓它一次只跑一個重型建置。
- 主設備上：建置與測試走 SSH（隔離 TMPDIR／LIVE_ROOT）；**簽章、打包、安裝、需要 GUI 的都走 `scripts/rooms/terminal-run.sh`（Terminal.app 工作階段）**——launchd 與 SSH 拿不到鑰匙圈，也執行不了外接卷上的二進位。
- 切換引擎的條件寫成規則不寫模型：主要 loops 額度低於 15% 或連續 429 → loops 備援接同一張單，報告路徑照施工單寫；跨家審查仍另找一家。
- **監工由主導在自己的工作階段掛 Monitor，不另開常駐監工程式**：看輸出檔 mtime 判活性；編譯類 20 分沒長判卡；**網路協商類（大倉庫 git fetch、上傳）不自動殺，只回報**——曾誤殺一次 fetch 等於重來；只回報「階段變化」與「結束／錯誤」，不洗頻；每 30 分重掛。
- 硬體上限：一次一個重型建置；記憶體吃緊先關掉非必要產物（例：CEF 關 dSYM）；大工作放外接卷的 staging，**路徑不能有空白**（Chromium／CEF 工具以空白切命令；卷名有空白就掛一顆無空白的 APFS 映像）；系統碟留 15 GB 以上。
- 長工作要能中斷續跑：nohup／caffeinate、階段標記檔、腳本重跑會接續；主導斷線不影響。
- 收尾一律：主導讀 diff → 閘門（debug＋release＋focused 0 fail）→ 併入 → 合併樹閘門 → 打包候選 → 兩台安裝＋功能檢查 → 三輪全套對基準 0 新失敗 → 乾淨安裝閘門 → 才發版。
- 程式化的下一步是 W95（`docs/specs/095-primary-job-queue/spec.md`）：這些腳本收進 `scripts/rooms/`，副設備經簽章通道提交白名單工作，主設備 GUI 排隊執行並回收據；`device_status` 加容量欄。

## 7. 驗收鐵律

- sub 的 DONE 永遠不算數：讀 diff 不讀報告；親跑測試；UI 要截圖。
- 宣告完成前逐字對齊 spec；沒做到的明說。
- 工程測試過但沒視覺證據時，寫「工程測試通過，UI 尚未驗收」。
- 刪除走封存：先移到可復原位置＋一份說明來源與還原步驟的 Markdown，換另一家引擎複審後才真刪。

## 8. 額度

- 主導的額度花在四件事：施工單、讀 diff、驗證、報告。
- 每批派工前看 GPT-6 額度；週上限低於 15% 停派，主導自己收尾。
- 一次一個重型房間；文字／審查類可並行。

## 9. 本技能的維護

- 主檔保持 150 行以內；規矩改了直接改這裡，不另開技能。
- 舊版資料不屬於本技能依賴；要刪除時走第 7 節的封存流程。
