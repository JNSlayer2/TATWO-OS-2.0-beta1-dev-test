import SwiftUI

struct BrowserMemorySettingsView: View {
    @State private var settings = BrowserMemorySettings.load()
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.settingsRowSpacing) {
            Picker("存活分頁上限", selection: $settings.liveTabLimit) {
                ForEach(BrowserMemorySettings.limitOptions, id: \.self) { value in
                    Text(value == -1 ? "自動（\(BrowserMemoryPolicy.defaultLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)) 個）"
                         : value == 0 ? "不限制" : "\(value) 個").tag(value)
                }
            }
            .onChange(of: settings.liveTabLimit) { _, value in save(.liveTabLimit, value: value) }
            if settings.liveTabLimit == 0 {
                Text("不限制可能耗盡記憶體；系統會優先釋放沒有進行中工作的背景分頁。")
                    .foregroundStyle(.orange)
            }
            Picker("背景分頁睡眠", selection: $settings.sleepMinutes) {
                ForEach(BrowserMemorySettings.sleepOptions, id: \.self) { value in
                    Text(value == -1 ? "自動（\(Int(BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory: ProcessInfo.processInfo.physicalMemory) / 60)) 分鐘）"
                         : value == 0 ? "不睡眠" : "\(value) 分鐘").tag(value)
                }
            }
            .onChange(of: settings.sleepMinutes) { _, value in save(.sleepMinutes, value: value) }
            Text("睡眠會釋放網頁，切回時重新載入。偵測到編輯、播放、下載或開啟中視窗的分頁會保留，必要時暫時超出分頁上限；記憶體吃緊時請先儲存並手動關頁。編輯保護會維持到重新載入網頁。")
                .font(.footnote).foregroundStyle(.secondary)
            if let saveError { Text(saveError).foregroundStyle(.red) }
        }
    }

    private func save(_ field: BrowserMemorySettings.Field, value: Int) {
        do {
            try BrowserMemorySettings.save(field, value: value)
            saveError = nil
        } catch {
            saveError = "無法儲存瀏覽器記憶體設定"
            settings = BrowserMemorySettings.load()
        }
    }
}
