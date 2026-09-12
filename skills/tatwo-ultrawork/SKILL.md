---
name: tatwo-ultrawork
description: Use when the user invokes TATWO Ultrawork, asks how to split work between the lead and subs, wants a spec/tasks/converge cycle for a feature, or asks about TATWO OS dispatch, review policy, or model roles.
---

# TATWO Ultrawork（2.0，2026-09-12 重寫）

一份技能，一套工作邏輯。舊版的 contract、receipt、S/M/L/XL 分級、Loop Governor 全部退役，
原文封存在 `references/legacy-20260912/`，只供考古，不是現行規矩。
上游規矩仍是 TATWO OS 的 `os.md` 與 `os-upstream.md`；本技能只講「怎麼分工、怎麼驗收」。

## 1. 一句話

主導一個人看全局，能寫成規格的整批派出去，做完親自讀 diff、親自跑驗證；
審查只在高風險時開，而且只開一輪。

## 2. 角色（2026-09-12 使用者定案）

| 角色 | 預設模型 | 做什麼 | 不做什麼 |
|---|---|---|---|
| 主導 | Fable 5.1 | 翻使用者的話成施工單、讀 diff、親跑驗證、對使用者報告、設計判斷 | 不親寫可規格化的功能，除非同一件事 sub 做壞兩次 |
| loops | GPT-6（fast／priority） | 整批施工單、寫碼、寫測試、跑測試、commit 到自己的分支 | 不改施工單範圍外的檔；不推 remote；不自升格 |
| 細修 | Opus 5 | 來回討論、小範圍修改、對主導的方案提反例 | 不接整批施工單 |
| 機械工 | Grok 4.6 | 搬檔、轉檔、批次替換、跑既定腳本 | 不做需要判斷的事；不開 high effort |
| 審查 | 另一家引擎（GPT 系優先） | 高風險 diff 的一輪唯讀審查 | 不自審：Claude 系不審 Claude 系 |

GPT-5.6 系列不在預設名單。模型換代時只改這張表，不改流程。

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
- `references/legacy-20260912/` 是舊版封存，不再引用；要刪除時走第 7 節的封存流程。
