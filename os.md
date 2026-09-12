# tatwo2 憲法（2026-09-03，共六條，不得超過二十行）

1. Claude Code 或 Codex 已經有的功能，用它們的，不自己造。
2. 連續五個工作天不斷線、不報錯之前，禁止加任何治理、收據、閘門、簽章程式碼。
3. 新寫 Swift 上限 15,000 行（不含 Visual/ 搬運檔）。超過就先刪再加。
4. 第一個月單一寫手，不開平行 sub，不做三簽；sub 只做審查。
5. 每個落地的改動，使用者當天就能用到。
6. 事故寫進 `經驗.md`，不寫進程式碼。

骨架只有四塊：Claude 引擎（Agent SDK 常駐 sidecar）、Codex 引擎（app-server 常駐）、Grok（isolated 逐輪）、Swift 殼。沒有第五塊。
OS 1.0 凍結於 tag `os1-frozen-20260903`（GitHub tatwo214/tatwo-ultrawork），只作視覺層與經驗的來源池。
