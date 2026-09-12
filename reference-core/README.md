# TATWO OS 2.0 公開版

這是一份**重新整理、可攜、預設不執行主機操作**的公開參考核心，不是私人工作環境的鏡像，也不是完整桌面 App 的原始碼傾倒。

## 一句話

TATWO OS 2.0 把多個 AI 引擎視為可替換的執行介面；討論串保存目標與上下文，主導可把工作切成隔離房間，最後由主導親自驗收。

## 公開內容

- OS 2.0 的薄憲法與 sidecar 協議。
- 房間施工單、報告合併與路徑邊界的無依賴參考實作。
- 預設 `dry-run` 的命令列工具；不啟動模型、不讀登入 session、不執行 shell。
- 可攜版 `tatwo-ultrawork` skill 與自我檢查。
- 威脅模型、公開／私人邊界、OS 1.0 遷移方案與安全掃描器。

## 明確不包含

完整桌面 UI、供應商 SDK 包裝、憑證與登入 session、瀏覽器資料、裝置控制、私人收據、真實專案 fixture、內部路徑、歷史 Git 記錄，以及任何自動安裝或常駐服務。

## 快速檢查

需要 Node.js 20 或更新版本，不需安裝套件：

```sh
npm test
npm run audit
npm run check
```

預覽房間施工單：

```sh
node bin/tatwo-os-2-public.mjs preview examples/rooms.json
```

工具只會讀取明示的 JSON，輸出預覽；不會建立 worktree、呼叫模型或修改專案。

## 成熟度

`0.2.0-alpha.1` 是經公開邊界審查的參考核心，不代表完整 TATWO OS 2.0 App，也不宣稱生產穩定。任何後續版本仍須重做檔案審查、獨立秘密掃描與乾淨環境測試。

詳見：`docs/ARCHITECTURE.md`、`docs/THREAT_MODEL.md`、`docs/PUBLIC_PRIVATE_BOUNDARY.md`、`docs/MIGRATION_FROM_V1.md`。
