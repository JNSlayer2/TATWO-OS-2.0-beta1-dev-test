{
  "schema": "TatwoOsManifestV1",
  "sourceId": "TATWO-ULTRAWORKos/os.md",
  "sourceSHA256": "9e66a56577bdc6437d1f8bf8f3e4b1594375dbbc8e7dad6f2331e5161a211f55",
  "generatedAt": "2026-07-30T20:16:06.010Z",
  "sections": [
    {
      "id": "meta-rule",
      "title": "元規則（防漂移）",
      "items": [
        "架構標準的唯一真相源是本 os.md。Ultra 分頁（UltraPage.swift）目前 hardcode 8 條架構＝漂移風險；高優先底層任務＝改為讀 os.md／衍生 manifest，使人與 AI 依循單一源。已確定＝進本節；未做/不確定＝進 TODO.md，不進 Ultra 分頁。"
      ]
    },
    {
      "id": "9.1",
      "title": "Plugin/能力三類框架（定案）",
      "items": [
        "plugins 依可攜性分三類，處理方式不同：",
        "**① 可攜 MCP**（協定標準，任何 client 可接：gitnexus/codebase-memory/gbrain/web-check/product-design/chatgpt-pro）→ OS 真正擁有統一；plugin 控制器（登記一次→OS 寫各原生 config）適用。",
        "**② 供應商原生能力**（綁引擎不可攜：computer-use Codex 版 vs Claude 版、apply_patch、native vision）→ **不可搬移，OS 開能力車道路由到當下最優實作**，多供應商雙掛不押一邊；隨供應商進步自動切換。",
        "**③ App 原生**（OS 自己做：右側面板檔案/瀏覽器/註解 UI、CLI session 管理）→ 不需供應商；僅「AI 讀內容」步驟路由到模型。",
        "registry 必須標記每項 type；②存「多實作＋路由規則」；③標為 App 內建非外部 plugin。"
      ]
    },
    {
      "id": "9.2",
      "title": "OS 上游＝分層（定案）",
      "items": [
        "「OS 是所有 AI 上游」的精確版＝分層，非物理全拔進 app：",
        "**憲法上游**＝os.md（已是，靠原生檔 bootstrap 指向）。",
        "**可攜工具中樞**＝OS 擁有①類 MCP。",
        "**能力路由器**＝OS 對②類原生能力路由最優供應商。",
        "**App 功能本體**＝OS 原生做③類。",
        "**引擎在底下當肌肉**：OS 自身非 LLM/非 computer-use 引擎；智能仍由 Codex/Claude/Grok 提供。",
        "「不再仰賴 Codex/Claude」＝不再用其 App/CLI 當介面（可達），非不用其引擎（不可能且不該）。",
        "9.2.1 品牌原生 MD 的上游綁定（2026-07-15，定案）",
        "`os.md` 是唯一持續迭代的 Work OS 憲法；OS 身份組、human gate、收據、路由與安全規則只在此處修正。",
        "各品牌原生 MD 只保存該品牌自己的長期記憶、工具習慣、路徑、橋接方式與操作眉角；不得複製整份 OS 憲法。",
        "每個已驗證的原生 MD 只安裝一段受標記管理的穩定宣告：目前 `os.md` 是上游，非平凡工作需同時讀取 active Work OS contract；若衝突，以 `os.md` 為準。",
        "正常 OS 迭代只改 `os.md`，不重寫 Codex `AGENTS.md`、Claude `CLAUDE.md`、OpenClaw workspace `AGENTS.md` 或其他品牌記憶。只有 OS root、binding protocol、品牌原生路徑改變，或偵測到 marker drift 時才重跑 installer。",
        "初始接入面：Codex `~/.codex/AGENTS.md`、Claude `~/.claude/CLAUDE.md`、active OpenClaw workspace `AGENTS.md`；Gemini 只在既有 `~/.gemini/GEMINI.md` 被證實時接入。Grok 尚未證實原生 MD，維持 `route_scope_unclear`，不得猜建 `~/.grok/AGENTS.md`。",
        "模型跑在哪個 runtime，就讀哪個 runtime 的原生記憶。Claude 模型若由 OpenClaw 啟動，仍是 OpenClaw agent lane，不因此取得 Claude-native `CLAUDE.md` 權限。"
      ]
    },
    {
      "id": "9.3",
      "title": "記憶分層＋GBrain 定位（定案）",
      "items": [
        "不物理全拔記憶進 OS app（破壞原生調校、TCC 風險）。分層：",
        "原生系統（~/.claude、~/.codex）保留各自工作記憶。",
        "**GBrain＝OS 原生 curated 記憶層**（raw→curated→truth）；經驗蒸餾往上。使用者 2026-07-11 授權 GBrain 做成 OS 原生。",
        "2026-07-15 live health：embedding coverage 已修復至 100%、missing embeddings 0、stale pages 0；但 orphan pages 仍為 623，代表「可語意搜尋」已恢復，不代表跨頁連結拓撲已整理完成。GBrain 升為完整 curated 上游前，仍需處理 orphan-link topology 與 OS↔GBrain 同步契約。",
        "Skills：canonical 根 ~/Library/Application Support/Tatwo Ultrawork/skills（mini 橋接既有 <your-volume>/skills，東西不搬）；Claude/Codex 入口仍是 runtime 投影。"
      ]
    },
    {
      "id": "9.4",
      "title": "分頁存在邏輯（定案）",
      "items": [
        "Chat＝對話＋下協作指令（ultrawork pill 開關協作）。",
        "Ultrawork 分頁＝**已確定架構標準的閉環紀錄**（本節內容的可視化）；非第三聊天面、非藍圖。",
        "CLI＝多引擎 session 管理器（persistent/多開/分類 codex-claude-openclaw-grok-sandbox）。",
        "唯三 delta（Chat/Ultrawork/CLI tabs、composer ultrawork pill、右 Thread 卡）為僅允許的 Tatwo 差異；其餘 chat 視窗高度還原 Codex App。",
        "討論串（＝Codex side-conversation/側邊任務同家族）：專案→thread→#討論串；不對稱三段式（快照繼承→進行中只看指標→收工壓縮摘要注入），`#`不可移除。"
      ]
    },
    {
      "id": "9.5",
      "title": "記錄機制（防人忘/防 AI 亂）",
      "items": [
        "已確定架構→本節（os.md §9）＝標準，人與 AI 依循。",
        "未做/不確定/分階段→TODO.md。",
        "每個閉環決定要標日期＋授權來源；重做架構前先讀本節。"
      ]
    },
    {
      "id": "9.6",
      "title": "本地驗證與 macOS 沙盒標準（2026-07-20，使用者授權）",
      "items": [
        "**GitHub 定位固定為私人備份**：GitHub 只保存 private branch、commit、tag 與 rollback anchor，不負責日常測試、Promotion 裁決或正式 App 更新推播。GitHub-hosted macOS runner 不再是 Gate，GitHub Actions Billing 也不得再阻擋 TATWO 的本地 Candidate 收斂。",
        "**來源 Candidate 的主 Gate 在使用者自己的兩台 Mac**：每次先在 clean worktree 與隔離 runtime roots 執行完整 Node、Swift、staging bundle、safe rollback 與 fake HOME／CODEX_HOME Host rehearsal；Mac mini 與 MacBook 必須各自產出 `TatwoLocalValidationReceiptV1`，不得拿其中一台的 PASS 代替另一台。",
        "**macOS VM 是發行沙盒，不是每次寫碼都要啟動的負擔**：一般 source candidate 不強制跑 VM；但 stable installer Promotion 前，必須在乾淨 macOS VM 驗證 clean install、版本更新、資料 migration、安裝中斷與 App rollback。VM 映像與資料必須放在空間足夠的隔離磁碟，不得擠壓正式系統資料卷。",
        "**App Sandbox 與測試沙盒分工不同**：App Sandbox 是正式 App 的權限邊界，不等於乾淨安裝／升級測試環境。TATWO 仍需要 CLI、Host Executor 與受控外部工具能力，因此不得在未拆出 helper、XPC／命令埠與權限契約前，直接把整個主 App 硬開 App Sandbox。",
        "**單一主 App 不因測試而分叉**：正式產品只有 `Tatwo Ultrawork`／`com.tatwo.ultrawork`；`internal-canary`、`stable` 是同一 App 的更新頻道。staging bundle、VM 安裝與 rollback bundle 都是隔離驗證物，不是第二個正式 App。",
        "**模組與權限維持分離**：主 App、Host Executor、Updater、Data Sync 各自保有模組、資料根、health、migration 與 rollback 邊界；本地驗證不可觸碰 `/Applications`、正式 App Support、LaunchAgent、auth/session/token 或 domain authority。",
        "**三層發行證據**：source candidate 需要 Mac mini clean local receipt＋MacBook clean local receipt；production signed build 另需 Developer ID／notarization／signed appcast；stable installer 再加 macOS VM clean-install／update／migration／rollback receipt。三層不可互相冒充。",
        "**單機 PASS 不等於雙機 Candidate PASS**：每台 Mac 的 `TatwoLocalValidationReceiptV1` 只能證明該實體設備，結果必須維持 `candidateOutcome=pending_peer_device`。只有 `tatwo-local-validation-pair.mjs` 驗證兩份 receipt 為相同 commit／tree、相同 validation pair、不同硬體 fingerprint、各自 anchor 正確且保護面 counters 全為零後，才能產生 `TatwoDualDeviceValidationReceiptV1` 並升格為雙機 source Candidate PASS。任一設備離線時只能保留已完成的單機證據，不得以舊 receipt、遠端可達性或另一台的 PASS 代替。",
        "**首筆雙機標準落地證據（2026-07-20）**：`fusion/single-main-app-20260720` 的 commit `63587b5e6a4ebb0b7630f7526c7b7dd3a8a5585e`／tree `991ca618b302632e59fd29a146a1719c0e3472b9` 已由 Mac mini 與 MacBook 各自完成 clean local validation，並以 pair `3099ab551b6314d8f3ebc172` 產生 `TatwoDualDeviceValidationReceiptV1`，receipt SHA-256 `c94480077a9a7f40cb9298e63d799f1cef692e96340b9e7ffb6cbfe46dd554a5`。此證據只升格 source Candidate，不授權正式 App 安裝、簽章發行、資料同步 production deploy 或 domain authority transfer。",
        "**Xcode 的角色**：Xcode／SwiftPM 負責編譯、測試、staging 與簽章工具鏈；Xcode 沒有可取代完整 macOS VM 的「Mac Simulator」。乾淨 macOS 驗證使用 Apple `Virtualization.framework` 或其受控 runner，App Sandbox 只處理 App 權限。"
      ]
    },
    {
      "id": "9.7",
      "title": "雙機唯一正式主 App（2026-07-20，使用者明確批准）",
      "items": [
        "Mac mini 與 MacBook 的唯一正式入口已統一為 `/Applications/Tatwo Ultrawork.app`；名稱 `Tatwo Ultrawork`、Bundle ID `com.tatwo.ultrawork`、Version／Build `0.1.3 / 3`、來源 commit `63587b5e6a4ebb0b7630f7526c7b7dd3a8a5585e`、tree `991ca618b302632e59fd29a146a1719c0e3472b9`。兩台即時重驗皆只有一個正式 Tatwo process，舊 `Tatwo OS.app` process 為 0。",
        "此次安裝是 **local-internal 本地最新版**，不是對外正式發行版。`TatwoDistributionReady=false`、`TatwoAutomaticUpdatesEnabled=false`；沒有 Developer ID Application、notarization、Sparkle signed appcast 或 production feed，不得把「已裝最新版」說成「已具備全使用者自動更新」。",
        "Mac mini 使用本機 Apple Development 簽章，只供本機；MacBook 沒有可用簽章身分，採 ad-hoc 本機簽章。兩者皆通過 `codesign --verify --deep --strict`，但都不等於 Developer ID 發行簽章。",
        "MacBook 首次啟動曾因 ad-hoc hardened runtime 的 library validation 拒絕不同 Team ID 的 Sparkle framework 而崩潰；系統先完整 rollback。之後只對 top-level App 重新 ad-hoc 簽章並移除 hardened-runtime flag，沒有改 source、Sparkle nested targets 或 PLG helper；第二次啟動成功且不需 retry rollback。",
        "舊 App 與 rollback bundle 均以 archive 保存而非永久刪除；App rollback 沒有覆蓋使用者資料。正式 dirty checkout 也維持原狀，沒有 clean、stash、切分支或改檔。",
        "雙機整合收據：`receipts/20260720-dual-device-local-internal-app-install.json`。它只證明兩台目前安裝並執行同一 local-internal 最新版；Signed Update、24 小時 bake、stable installer VM、production Data Sync 與正式主權切換仍是後續 Gate。"
      ]
    },
    {
      "id": "9.8",
      "title": "觀測正確性（2026-07-31，PLG XXL 實證後定案）",
      "items": [
        "觀測工具說謊比指標難看更危險——它讓人有理由停止追問。本節為硬規則：",
        "**重導向順序寫死**：`> log 2>&1`；`2>&1 > log` 讓 stderr 走終端（XCTest 寫 stderr），已造成過假綠燈。",
        "**禁以 `tail`／`head` 過濾後的輸出判斷成敗**；先驗 log 大小與套數，再讀結論。",
        "**計數樣式必須 anchored**：`^Test Suite .* passed at` 與 `^Test Suite .* failed at` 分開計。舊模式 `\"Test Suite .* passed\\|failed\"` 會誤吃測試名中的 \"failed\"（實測把 185 膨脹成 233）。",
        "**全集必須含失敗項**：任何從 log 推導測試全集的工具（分片器等）必須同時納入 failed suite，並排除 aggregate label；解析不一致即非零退出，不得只因有一個 passed 就回 0。",
        "**skip 必須可見且不得計為 passed**；能力缺席以能力探測驅動的 `XCTSkip` 表達，不得靜默通過，也不得誤報為失敗。",
        "**分散式結論**：任一分片 failed>0、缺分片、重複分片或 partition 不完整＝整體 FAIL；有 skip 用 `PASS_WITH_SKIPS` 並逐項列出缺席能力；toolchain 不一致加註 `DEGRADED`。結論字串必須自明「不等於通過」。"
      ]
    },
    {
      "id": "9.9",
      "title": "審查與修復契約（2026-07-31 定案）",
      "items": [
        "**審查報告綁 revision**：每份報告內嵌 stamp（commit／tree／branch／dirty 範圍／驗證深度／受審 artifact hash）。未綁或 commit 不符的報告無效，不得引用。",
        "**修復契約三擔保**：patch 只在獨立審查者能擔保 ①確實解決該發現 ②未引入新漏洞 ③其餘行為不變 時才產出；擔保不了就回書面說明。",
        "**覆蓋率取代「收斂到上限」**：掃描不確定，沒有終點，只有覆蓋率與頻率；用「面向×深度×最後掃描 revision」矩陣追蹤。",
        "**審查派不同身份**：複審者與封存/實作者必須不同（刪除鐵律的複審關卡亦然——換一個 AI 複審即滿足，不必然是人類）。"
      ]
    },
    {
      "id": "9.10",
      "title": "userland 授權極限（2026-07-31 定案）",
      "items": [
        "同進程／同權限的程式碼可以直接建構通過任何 in-process gate 的合法物件、替換記憶體、跳過驗證器。**這是 userland 的結構極限，不是可修的漏洞**；根治需 kernel/ACL 保護的儲存或外部 quorum。",
        "凡屬此類殘餘，一律標 `structural-limit-documented` 並引 `docs/protocol/USERLAND_AUTHORITY_LIMITS.md`，**不得假裝已封堵**。",
        "可修的邊界仍必須修：可信物件不得有 public 直建路徑；關鍵驗證不得可用 nil 預設省略（要顯式表達「無此域」而非隱含放行）；durable 記錄需完整性鏈＋授權綁定，且驗證發生在任何 mutation 之前。"
      ]
    },
    {
      "id": "9.11",
      "title": "跨設備語彙與工具鏈差異（2026-07-31 定案）",
      "items": [
        "**五狀態語彙固定**：已送達／已啟動／執行中／已完成／已驗收，各有獨立實體與證據；**process 存活不得當完成證據**。設計語彙與 wire enum 若不同名，必須提供單一對照（`designSemanticLabel`），不得讓兩套語彙各自散落。",
        "**主權單點**：跨設備主責轉移是顯式單點事件（create-only、epoch 單調、舊 origin 立即 fail-closed），不得出現雙 origin 窗口；transfer 不提供 CLI 捷徑，屬 human gate。",
        "**工具鏈差異三處置**：accept-and-label（預設，標 DEGRADED）／strict（不符即 FAIL）／linter-lane（較嚴格機器當第二意見）。DEGRADED 狀態下不得作為雙機 candidate PASS 的唯一證據。"
      ]
    }
  ]
}
