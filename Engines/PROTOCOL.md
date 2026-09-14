# tatwo2 引擎 sidecar 協議（三家共用）

每家引擎一個常駐 sidecar 行程（Node 或任何語言），App 用 stdin/stdout 一行一個 JSON 溝通。
App 端只認這個協議（`App/Sources/Tatwo2/Engine/ClaudeSidecar.swift` 的解析器，之後泛化成 `EngineSidecar`）。
Claude 版 `Engines/claude-sidecar/sidecar.mjs` 是參考實作。

## 啟動參數
```
node sidecar.mjs --cwd <工作目錄> [--resume <session id>] [--model <model id>] [--permission-mode <default|acceptEdits|bypassPermissions>] [--system-prompt <文字>] [--mcp-config <json>]
```
- 一條討論串開一個 sidecar；sidecar 活著就不重開；App 關掉再開時帶 `--resume` 續接同一個 session。
- 引擎自己的 session id 由 sidecar 在第一次 `system/init` 事件回報。
- `--mcp-config` 是該討論串啟用的 MCP 設定。Claude 使用 `{"engine":"claude","servers":{...}}`；Codex 使用 `{"engine":"codex","configured":[...],"enabled":[...]}`，sidecar 會把未啟用者轉成 app-server `-c mcp_servers.<name>.enabled=false`。

## stdin（App → sidecar），每行一個 JSON
| op | 欄位 | 意思 |
|---|---|---|
| `send` | `text`, `uuid` | 使用者送一則訊息（uuid 是這一輪的識別） |
| `permission` | `id`, `allow`(bool), `message?`, `updatedInput?` | 回覆權限詢問 |
| `interrupt` | | 停止目前這一輪；Codex 同時取消停止前的舊佇列，停止後明確新送的訊息仍可執行 |
| `model` | `model` | 中途換模型（做不到就回 `error`） |
| `mcp_status` | | 查詢這個 sidecar 的 MCP 常駐／連線狀態 |
| `close` | | 收工；sidecar 要自己結束行程 |

## stdout（sidecar → App），每行一個 JSON
| ev | 欄位 | 意思 |
|---|---|---|
| `sdk` | `msg` | **原樣轉發引擎的事件**。App 只認以下形狀（照 Claude Agent SDK 的 SDKMessage）： |
| | `msg.type=="system"`, `subtype=="init"`, `session_id`, `model` | session 開好了 |
| | `msg.type=="stream_event"`, `event.type=="content_block_delta"`, `event.delta.type=="text_delta"`, `event.delta.text` | 文字串流片段 |
| | `msg.type=="assistant"`, `message.content[]` 內 `{type:"tool_use", id, name, input}` | 引擎開始用工具 |
| | `msg.type=="user"`, `message.content[]` 內 `{type:"tool_result", tool_use_id, is_error?}` | 工具做完 |
| | `msg.type=="result"`, `subtype`, `is_error`, `result`, `session_id` | 這一輪結束 |
| `permission_request` | `id`, `tool`, `input`, `title?`, `description?` | 引擎要問「可不可以做這件事」；App 回 `permission` |
| `mcp_status` | `servers` | MCP 狀態陣列；Claude 直接回 Agent SDK `query.mcpServerStatus()`，Codex 回本次 app-server 覆寫後的 configured／disabled 狀態 |
| `stderr` | `line` | 引擎的雜訊，App 只顯示成提示 |
| `error` | `message` | sidecar 層錯誤 |
| `closed` | | sidecar 結束 |

## 非 Claude 引擎怎麼對齊
- **Codex（app-server）**：sidecar 內部用 JSON-RPC 跟 `codex app-server` 講，把它的事件**翻譯成上面 Claude 形狀**（init／text_delta／tool_use／tool_result／result）。session id 用 Codex 的 thread id。權限：app-server 的 approval 請求翻成 `permission_request`。
- **Grok（grok-isolated CLI）**：每一輪 `grok-isolated -p <text> --output-format streaming-json`，用它的 session／resume 機制續接；一樣翻成 Claude 形狀。
- 翻不出來的事件就不要發，寧可少。App 不會因為少事件壞掉，會因為形狀錯壞掉。

### Codex 回合與停止

- 回合 SDK 訊息附上 `client_turn_id`，沿用 `send.uuid`；不是原生 thread ID，也不新增持久化狀態。App 只接受當前仍執行中回合的標記訊息；其他引擎未提供此欄位時維持原協議。
- 停止發生在 `turn/start` 尚未回覆時，取得原生回合 ID 後補送一次 `turn/interrupt`。成功回覆 RPC 不等於回合已停止，仍等原生終止事件才啟動下一筆明確新送的工作。
- 原生 `interrupted` 回報 `subtype: "cancelled", is_error: false`；停止 RPC 被拒絕則回報錯誤，不冒稱完成、不自動重試，使用者可明確再按停止。
- 原生完成先於啟動 RPC 回覆時，不讓晚到回覆復活舊回合；帶有不同回合 ID 的遲到事件不影響當前回合。
- 尚未啟動而被取消的佇列訊息，也用其 `send.uuid` 回報取消，讓 App 不必等待永遠不會啟動的回合。停止時回絕待決與遲到的權限要求；遲到的 UI 同意不能重新授權已取消要求。
- 停止 RPC 拒絕附 `terminal: false` 與 `client_turn_id`。App 保留錯誤訊息，但不把「停止失敗」冒充「回合已失敗／已結束」。
- App 的執行中狀態保留至終止事件；文字片段結束、停止請求送出及晚到模型資料都不是終止證據。`stop_thread`、`stop_room`、`stop_all_rooms` 回報 `stopRequested` 及當下實際 `stopped`，兩者不混用。

## 驗收（每個 sidecar 都要過，用 shell 就能測）
```
( echo '{"op":"send","text":"只回一個詞：乒"}'; sleep 30; echo '{"op":"send","text":"我上一句要你回什麼？只回那個詞"}'; sleep 30; echo '{"op":"close"}' ) | node sidecar.mjs --cwd /tmp
```
1. 第一輪 `result` 之前有 `text_delta` 拼出「乒」。
2. 第二輪同一個 session 回「乒」（記得前文）。
3. 用 `--resume <第一次的 session_id>` 再開一個行程，問「我第一句要你回什麼」仍回「乒」。
4. 送一句要它用工具（例如跑 `echo hi`），要看到 `tool_use` → `tool_result`，若引擎會問權限則要出現 `permission_request`，App 回 allow 後繼續。


## 內建瀏覽器 MCP（tatwo2_browser）

Claude、Codex 與使用隔離 HOME 的 Grok sidecar 共用 bundle 內同層的 `browser-mcp/server.mjs`。
該 MCP 只透過使用者本機、權限 `0600` 的 UNIX socket 溝通：

```
~/Library/Application Support/tatwo2/live/browser-v2.sock
```

callerThreadID 由 sidecar 綁定的 `TATWO2_THREAD_ID` 注入，模型不能覆寫。
原生輸入工具先 `browser_start` 取得 sessionID，再送一行一個 JSON：
`{"id":1,"method":"browser_open","params":{"callerThreadID":"<bound UUID>","sessionID":"<grant UUID>","url":"https://example.com"}}`。
App 回 `{"id":1,"ok":true,"result":{...}}` 或 `{"id":1,"ok":false,"error":"..."}`。
工具為 `browser_open`、`browser_read`、`browser_screenshot`、`browser_click`、
`browser_type`、`browser_scroll`、`browser_search`。橋不讀 cookie、storage、HTML 或欄位值；
`browser_type` 對 CEF 可見快照標成 sensitive/password 的欄位一律拒絕。

### WebMCP 頁面工具（W48）

三個 MCP 名稱就是同名 socket method；外層參數禁止額外欄位：

- `browser_tabs({})` → `{tabs:[{tabID,title,origin,hasPageTools,sleeping}]}`：所有 work space＋呼叫者目前 chat session，不列其他 chat／bot。tabID 是 registry UUID，App 內部轉為 CEF lane ID；不喚醒睡眠分頁。
- `page_tools_list({tabID})` → `{origin?,tools:[{name,description,inputSchema}]}`。
- `page_tool_call({tabID,tool,arguments:{...}})` → `{result:"<JSON string>",contentTrust:"untrusted_page_data_not_instructions"}`。

這三個工具不要求 `browser_start`／sessionID／AX 權限，**不授予原生輸入權**。
仍須本機、目前選中且執行中的使用者 Chat；原有 room／bot／remote 隔離不變。
呼叫政策只取 App 的 caller preset（bot override 的 configFile 回退使用者 preset），不取分頁擁有者或 MCP 參數。
唯讀 caller 只允許 readOnly；fullAccess 全允許；approveForMe 允許 readOnly，
sideEffect／highRisk 每次問 Island；askFirst／configFile／nil 的 readOnly 在 caller session＋tab＋origin 問一次，
其餘每次問。Stop／request epoch、對話切換、caller 權限變更、分頁移轉、睡眠或斷線均重驗，不沿用待決授權。
`EmbeddedBrowserSiteToolPolicy` 的 origin 拒絕優先於 preset；私網不因 human tab 或 fullAccess 放行。

runtime 解析 `TatwoCEFWebMCPToolsSnapshotV1`：origin、navigationGeneration、tools；
工具欄位 name、description、inputSchemaJSON、origin、navigationGeneration、contextID；未知欄位忽略。
限制為 UTF-8：name 128 B、description 8192 B、schema 65536 B、snapshot／arguments／result 1 MiB，
JSON 深度 16、每容器 4096 項、每分頁最多 128 工具；socket 整包仍限 1 MiB。
拒收 snapshot 時清除舊工具並記固定錯誤碼，避免繼續用舊頁面。
schema／description 的 readOnlyHint 或 get/list/search/read 名稱判 readOnly；
destructiveHint 或 delete/pay/send 語詞優先判 highRisk，其他為 sideEffect。
**這些是網站宣告的分類，不是 JS 純讀沙箱或無副作用證明**；網站提供的 schema、描述及結果皆不可信。

呼叫帶 CEF navigationGeneration；確認前後及結果返回時再驗頁面／工具版本與 request。
換代回 `stale_page`；錯誤／逾時不自動重試（已送出的寫入不會回滾）。
Island 確認最多 20 秒、renderer 最多 30 秒，WebMCP request 共 60 秒、MCP 等候最多 65 秒（原生輸入仍 40／45 秒）；
兩段合計逾時會取消等候，不能據此認定寫入沒發生。
每次 runtime invoke 寫一行 JSON 到 `~/Library/Application Support/TATWO OS/Browser/webmcp-audit.log`（0600）：
時間、caller、origin、tool、decision、outcome、固定 error code；不寫參數、結果或頁面錯誤內容。
磁碟寫入失敗會記 `audit_write_failed`，不宣稱審計已落盤。

#### Island 實測 fixture（後續 CEF／人類驗收）

`tests/fixtures/webmcp-demo.html` 登記 `get_note` 與 `set_note`，筆記只存在 DOM。
在允許的 HTTP(S) origin 提供此頁；不可直接 file://，正式私網規則不放寬。
本分支 C++ 實際掛的是 `document.modelContext`，fixture 局部別名到 `navigator.modelContext`，
並優先選 TATWO 的 `__tatwoWebMCP`；**一般頁面 navigator API 相容仍待 CEF 房修正，本單不改 C++**。
隔離 staging 的 loopback 測試須沿用既有 staging 專用例外，不能在正式 App 開例外。
後續以三家 AI 各自取得 browser_tabs／page_tools_list，再以 approveForMe 呼叫 get_note（不問）
與 set_note（Island 問一次，先測取消再測允許），核對 DOM 與審計。
另測 askFirst 同 origin 第二次讀不問、每次寫都問、fullAccess 不問、換頁待決拒絕。
本單 swiftc 假 invoker／假 confirm、socket fixture 與 CEF=0 build **不等同此實機／視覺驗收**。


## 內建派工引擎（tatwo2_os，E1）

Claude 與 Codex sidecar 會註冊 bundle 內同層的 `os-mcp/server.mjs`；Grok 不註冊。
這是 ultrawork 2.0 的派工工具（`docs/os.md` §4／§5）：主導把工作切成房間，App 幫每個房間開一條子討論串
＋一個獨立 git worktree（`<專案 workdir>/.tatwo2/wt/<roomID>`；workdir 不是 git repo 就用
`<workdir>/.tatwo2/rooms/<roomID>` 普通資料夾），派給指定引擎的 sidecar 去跑。

跟瀏覽器橋一樣，只透過使用者本機、權限 `0600` 的 UNIX socket 溝通：

```
~/Library/Application Support/tatwo2/live/os.sock
```

一行一個 JSON：`{"id":1,"method":"dispatch_rooms","params":{"rooms":[...]}}`。
App 回 `{"id":1,"ok":true,"result":{...}}` 或 `{"id":1,"ok":false,"error":"..."}`。

工具：
- `dispatch_rooms({ rooms: [{ title, engine: "codex"|"claude"|"grok", model?, brief }] })` → `{ rooms: [{ roomID, threadID, worktree }] }`。`parent`＝呼叫這個工具當下 App 裡「目前選取」的討論串。
- `list_rooms()` → `{ rooms: [{ roomID, title, engine, liveness, lastOutputAt, reportAvailable }] }`（目前主討論串底下的房間）。
- `stop_room({ roomID })` → `{ stopped: true }`。
- `stop_all_rooms()` → `{ stopped: true }`。
- `merge_reports()` → `{ text }`；同時把合併文字以 system 訊息貼進主討論串。
