import SwiftUI

struct BrowserMemorySettingsView: View {
    @State private var settings = BrowserMemorySettings.load()
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSettingsMetrics.rowSpacing) {
            Picker("存活分頁上限", selection: $settings.liveTabLimit) {
                ForEach(BrowserMemorySettings.limitOptions, id: \.self) { value in
                    Text(value == -1 ? "自動（\(BrowserMemoryPolicy.defaultLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)) 個）"
                         : value == 0 ? "不限制" : "\(value) 個").tag(value)
                }
            }
            .onChange(of: settings.liveTabLimit) { _, value in save(.liveTabLimit, value: value) }
            if settings.liveTabLimit == 0 {
                Text("不限制可能耗盡記憶體，導致系統終止 App；記憶體壓力保護仍會釋放背景分頁。")
                    .foregroundStyle(.orange)
            }
            Picker("背景分頁睡眠", selection: $settings.sleepMinutes) {
                ForEach(BrowserMemorySettings.sleepOptions, id: \.self) { value in
                    Text(value == -1 ? "自動（\(Int(BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory: ProcessInfo.processInfo.physicalMemory) / 60)) 分鐘）"
                         : value == 0 ? "不睡眠" : "\(value) 分鐘").tag(value)
                }
            }
            .onChange(of: settings.sleepMinutes) { _, value in save(.sleepMinutes, value: value) }
            Text("睡眠會釋放網頁並保留網址、標題與圖示；切回時重新載入，未送出的表單可能遺失。分頁上限立即生效，CEF 程序上限重開 App 後生效。")
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
