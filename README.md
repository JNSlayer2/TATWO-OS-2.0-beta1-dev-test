# TATWO OS 2.0 beta1

## 這是什麼
TATWO OS 是 macOS 上的 AI 工作介面，整合對話、模型引擎與工作流程。這是 beta1 開發測試版，功能與相容性仍在驗證中。

## 一行安裝
打開「終端機」，貼上這一行按 Enter（會下載最新 Release、驗證 SHA-256、放進 Applications 並開啟）：

```sh
curl -fsSL https://raw.githubusercontent.com/tatwo214/TATWO-OS-2.0-beta1-dev-test/main/install.sh | bash
```

想先看腳本內容再執行，可先開啟同一個網址閱讀。App 之後會自己檢查新版，設定頁會出現「有新版」與同一行指令。

## 回報與貢獻
在 App 使用 `/feedback` 回報問題（附重現步驟與版本，先移除個人資訊），使用 `/pr` 啟動貢獻流程。公開提交不得包含金鑰、帳號資料或私人紀錄。

## 授權與注意事項
本版採原始碼可閱覽的 beta 授權，並非無限制的開源授權；條款以根目錄 `LICENSE` 為準，安全問題請參閱 `SECURITY.md`。歷史測試產物可能使用 ad-hoc 簽名；目前建置與更新流程禁止 ad-hoc，並要求更新前後簽章身分相容。固定 Beta 簽章不代表 Apple 公證；首次自動安裝必須通過 macOS 安全檢查。詳見 [簽章與更新政策](docs/update-signing.md)。請確認來源、保留備份，勿用測試版處理唯一副本的重要資料。
