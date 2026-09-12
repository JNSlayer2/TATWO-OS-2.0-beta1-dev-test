# tatwo-engine：TATWO OS 的 headless 引擎入口

App 的派工要 `os.sock`，而那個 socket 只在 App 開著時存在。這支不需要 App，
用在 CLI session、`codex exec`、排程，把一則請求送給 OS 自己的引擎 sidecar，拿到回覆就結束。

它不是新的引擎接線，是 `Engines/PROTOCOL.md` 的一個 headless 客戶端：

```
spawn sidecar → {op:"send"} → 收 sdk 事件 → 等 msg.type=="result" → {op:"close"}
```

取代 `codex-claude-bridge` 的單向通道（Codex→Claude）。三家引擎都能當被問的一方。

## 用法

```sh
node Engines/cli/tatwo-engine.mjs ask      --engine claude --cwd DIR "問題"
node Engines/cli/tatwo-engine.mjs review   --engine claude --cwd DIR "審查請求"
node Engines/cli/tatwo-engine.mjs delegate --engine codex  --cwd DIR --yes "任務"
node Engines/cli/tatwo-engine.mjs doctor
```

| exit | 意思 |
|---|---|
| 0 | 成功 |
| 1 | 引擎回報錯誤、啟動失敗，或沒有回覆 |
| 2 | 參數錯誤或被安全規則擋下 |
| 124 | 逾時 |

沿用 `codex-claude-bridge` 的 exit code 慣例，兩邊的稽核紀錄可以接起來算成功率。

## 唯讀是怎麼強制的（重要）

`ask` / `review` 要求引擎不能寫入。**這件事只有 sidecar 原生支援唯讀的引擎才做得到**：

| 引擎 | 能不能強制唯讀 | 依據 |
|---|---|---|
| claude | 可以 | sidecar 有 `--permission-mode readOnly`：`tools` 限縮成 Read/Grep/Glob、`canUseTool` 直接 deny、不掛任何 MCP、關掉 hooks/plugins/skills/agents |
| codex | 不行 | sidecar 只有 `workspace-write` 與 `danger-full-access` 兩檔，沒有唯讀 |
| grok | 不行 | 每輪帶 `--always-approve` |

不能強制的引擎跑 `ask` / `review` 會**直接拒絕啟動**，除非明確帶 `--unsafe-no-readonly`；
帶了就會在稽核紀錄留下 `unsafe_no_readonly: true`。

> **這條規則是實測換來的（2026-09-09）。**
> 最初的版本只靠攔截 `permission_request` 事件來決定放不放行，假 sidecar 測試全過。
> 但真 claude 在 default 模式下**根本不發權限詢問**，直接就把檔案寫出來了——
> 攔截層是 fail-open 的。現在改成優先用 sidecar 的原生唯讀，攔截層只當第二層。
> 教訓：安全性的驗證不能只靠會配合你的假物件。

`delegate` 允許寫入，必須明確帶 `--yes`，否則拒絕啟動。

## sidecar 從哪裡找

claude 的 sidecar 需要 `@anthropic-ai/claude-agent-sdk`，而 repo 的 `Engines/` 沒有 `node_modules`，
所以解析順序是（照 App 的 `ClaudeSidecar.scriptPath`）：

1. `TATWO_ENGINE_SIDECAR_ROOT`
2. `TATWO2_RESOURCES_ROOT`
3. `~/Desktop/TATWO OS.app/Contents/Resources`
4. `/Applications/tatwo2.app/Contents/Resources`
5. `/Applications/TATWO OS.app/Contents/Resources`
6. repo 的 `Engines/`（只夠跑不吃相依套件的引擎與測試）

`doctor` 會印出實際挑到哪一份、有沒有 `node_modules`。

## 稽核紀錄

預設寫到 `~/.tatwo2/log/engine-cli.jsonl`，一行一筆，可用 `TATWO_ENGINE_CLI_LOG` 或 `--log` 改。
欄位刻意對齊 `codex-claude-bridge` 的格式（`ts`／`started_at`／`mode`／`cwd`／`exit_status`／
`prompt_preview`），另加 `engine`、`model_reported`、`read_only_enforced`、`unsafe_no_readonly`、
`denied_tools`。算成功率：

```sh
python3 -c "
import json
rows=[json.loads(l) for l in open('$HOME/.tatwo2/log/engine-cli.jsonl')]
ok=sum(1 for r in rows if r['exit_status']==0)
print(f'{len(rows)} 次，成功 {ok} 次 = {ok*100//max(len(rows),1)}%')"
```

## 測試

```sh
node --test Engines/cli/tatwo-engine.test.mjs
```

15 個案例，全部用假 sidecar 走同一份協議，**不呼叫真引擎**。
測試一律用 `TATWO_ENGINE_SIDECAR_ROOT` 釘死來源——不釘的話 CLI 會找到已安裝 App 裡的真 sidecar，
測試就變成在打真引擎（燒額度，而且驗到的不是我們要驗的東西）。

真引擎的端到端驗證要另外手動跑，2026-09-09 的結果：

| 引擎 | 結果 | 回報模型 | 耗時 |
|---|---|---|---|
| claude | 乒 | claude-opus-5 | 1.6s |
| codex | 乒 | gpt-6 | 23.8s |
| grok | 乒 | grok-4.6（要帶 `--model`） | 6.4s |

另外實測 `review --engine claude` 叫它寫檔：引擎回「我只有 Glob、Grep、Read」，目錄維持空的。
