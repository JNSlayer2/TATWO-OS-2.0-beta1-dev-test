# 分頁設計理念（供左下「設計說明」hover 小窗顯示）

> **真相源**：分頁存在邏輯的權威定義是 os.md §9.4（os-architecture-standard.md）。本檔＝該架構的**使用者面 UI 投影**（白話 hover 說明），非獨立真相源；若與 os.md §9.4 衝突以 os.md 為準，並回頭同步本檔（符 §9.5 單一真相源）。

使用者需求：左列底部 example 使用者列右邊加一個設計說明鈕（紅圈 `!`/`i`），滑鼠停留顯示小窗，說明該分頁的設計理念、Chat 的理解、以及 Chat 如何與 CLI 合作。CLI 分頁重點解釋其設計。Ultrawork 先擺 placeholder。

---

## Chat（對話式工作）
一般聊天，也能開**專案 thread（對話串）**。用來構思、討論、迭代想法。

**與 CLI 如何合作**：一個 thread 處理到某階段，可**接到 CLI session** 繼續（終端/引擎直接執行）；反過來 CLI 跑到一個階段，也能**回 Chat 讀取**。同一專案下 thread 與 session 並存、互相接力。

**共同記憶**：跨面的進度/結論寫進 **GBrain**（語義記憶），所以你在 CLI 喬的東西，Chat 與 Codex App 都找得到。

---

## CLI（終端/引擎執行）
專案底下的 **session**（不叫 thread）。可掛多引擎：codex / claude / openclaw / grok / sandbox。

**為什麼要有**：有時直接在專案裡開 CLI 跑命令、實作、除錯，體驗比對話更順。你可以直接在「刺青網頁專案」開一個 CLI session。

**與 Chat 對接**：session 與同專案的 chat thread 互通——CLI 做到一階段可送回 Chat 讀取，Chat 的 thread 也能接到 CLI session 續作。共同記憶一樣走 GBrain。

**session ≠ thread**：Chat 用 thread（對話串），CLI 用 session（執行階段），刻意區分。

---

## Ultrawork（設計中，先擺 placeholder）
目前留白後續發想。候選定位：**已確定架構標準的閉環可視化**（讀 os.md §9，防 AI 迭代亂/人忘）＋多面協作的觀測台。等你想清楚方向再定。

---

*註：本檔為 hover 說明的內容源，隨設計演進更新；對齊 os.md §9 tab 邏輯與 CLI-session 跨面願景（cli-session-crosstab-vision.md）。*
