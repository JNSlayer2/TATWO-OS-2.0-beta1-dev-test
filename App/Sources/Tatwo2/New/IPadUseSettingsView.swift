import SwiftUI

struct IPadUseSettingsView: View {
    let threadID: UUID?
    @ObservedObject private var controller = IPadUseController.shared
    @State private var showAuthorization = false
    @State private var showQuickConsent = false
    @State private var showBuildConsent = false
    @State private var quickDevice: IPadUseDevice?
    @State private var deviceToBuild: IPadUseDevice?
    @State private var localError = ""
    @State private var consentThreadID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("iPad USE", systemImage: "ipad").font(.title3.bold())
                    Spacer()
                    Text(controller.authorized ? "已授權" : "未授權 AI 控制")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("以 USB 連接自己的 iPad；授權裝置後，AI 可依任務選擇 App。")
                    .font(.callout).foregroundStyle(.secondary)
                Text(controller.state).font(.callout)
                    .accessibilityIdentifier("ipad-use-status")
                if !controller.connected { setup.disabled(controller.stopUnconfirmed) }
                else {
                    HStack {
                        Button(controller.authorized ? "重新授權目前討論串" : "授權目前討論串（畫面＋觸控）") {
                            consentThreadID = threadID
                            showAuthorization = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(threadID == nil || controller.busy)
                        Button("立即停止", role: .destructive) { controller.stop() }
                    }
                }
                if controller.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("處理中…").font(.caption)
                        Button("取消並停止") { controller.stop() }
                    }
                }
                if controller.stopUnconfirmed {
                    Button("再次停止設備", role: .destructive) { controller.stop() }
                }
                if controller.authorized, let threadID {
                    Button("擷取 iPad 畫面測試") {
                        Task {
                            do {
                                _ = try await controller.perform("ipad_screenshot", params: [:], caller: threadID)
                                localError = ""
                            } catch { localError = error.localizedDescription }
                        }
                    }
                }
                if let preview = controller.preview {
                    Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 300)
                        .accessibilityLabel("iPad 最新擷取畫面")
                }
                if !localError.isEmpty { Text(localError).font(.caption).foregroundStyle(.red) }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Apple Pencil 壓感").font(.headline)
                    Text("AI → iPad 真實 Pencil 壓感：目前 TATWO iPad USE 不支援。")
                    Text("手指觸控與模擬 pressure 不等於 Apple Pencil。實體 Pencil 的壓感仍由你在 iPad 上直接使用；本功能不宣稱能遠端注入。")
                }.font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("憑證留在自己的機器", systemImage: "lock.shield")
                    Text("TATWO 不接收帳號密碼、不儲存私鑰；開源包不附個人簽署設備、裝置位址或配對資料。")
                    Text("使用雲端 AI 時，授權擷取的畫面會送往該模型服務；自架控制不代表畫面完全離線。")
                    Text("停止會撤銷本次授權並終止 App 管理的設備；已送達的觸控可能已生效，請檢查 iPad。裝置信任不會自動撤銷。")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .tint(LiquidGlassTokens.brandAccent)
        .accessibilityIdentifier("ipad-use-settings")
        .task {
            if controller.devices.isEmpty && !controller.connected {
                await controller.discover()
            }
        }
        .confirmationDialog("連接並授權這台 iPad？", isPresented: $showQuickConsent) {
            Button("同意並連接") {
                guard let quickDevice, let consentThreadID, consentThreadID == threadID else { return }
                Task { await controller.connectAndAuthorize(quickDevice, threadID: consentThreadID) }
            }
        } message: {
            Text("一次完成連接與目前討論串授權，直到停止或連線中斷。AI 可選擇 App、擷取 iPad 畫面並執行觸控；雲端模型會接收截圖，觸控可能修改裝置上的內容。")
        }
        .confirmationDialog("授權目前討論串？", isPresented: $showAuthorization) {
            Button("同意授權") {
                guard let consentThreadID, consentThreadID == threadID else { return }
                Task { await controller.authorize(threadID: consentThreadID, allowTouch: true) }
            }
        } message: {
            Text("授權 App 選擇、畫面與觸控，直到停止或連線中斷。這次確認會直接綁定目前討論串；其他討論串不會因此取得控制權。雲端模型會接收截圖，觸控可能修改裝置上的內容。")
        }
        .confirmationDialog("建立 TATWO iPad use？", isPresented: $showBuildConsent) {
            Button("使用本機 Xcode 建立") {
                if let deviceToBuild { Task { await controller.buildDevice(deviceToBuild) } }
            }
        } message: {
            Text("只讀取此 Mac 由 Xcode 管理的有效簽署候選，直接交給 Xcode 簽署；不會把 Apple Team、裝置 ID、帳號、密碼或私鑰寫進專案。")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · 連接與信任").font(.subheadline.bold())
            Text("以 USB 連接、解鎖 iPad，親自確認信任並啟用開發者模式；Mac 需要完整 Xcode。")
                .font(.caption).foregroundStyle(.secondary)
            Button("重新尋找 USB iPad") { Task { await controller.discover() } }
                .disabled(controller.busy)
            Text("2 · TATWO iPad use").font(.subheadline.bold())
            Text("由 App 內建的 TATWO 裝置專案建立；Apple 登入與私鑰只由 Xcode 和鑰匙圈管理。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(controller.devices) { device in
                HStack {
                    Label(device.name, systemImage: "ipad")
                    Spacer()
                    Button("建立／更新設備") {
                        deviceToBuild = device
                        showBuildConsent = true
                    }.disabled(controller.busy)
                    Button("連接並授權") {
                        quickDevice = device
                        consentThreadID = threadID
                        showQuickConsent = true
                    }.disabled(controller.busy || controller.testBundle == nil || threadID == nil)
                }
            }
            DisclosureGroup("進階：使用自行建置的設備檔案") {
                HStack {
                    Button("選擇設備檔案") { controller.chooseTestBundle() }
                        .disabled(controller.busy)
                    Text(controller.testBundle?.lastPathComponent ?? "尚未建立")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("按一次「連接並授權」即可由目前討論串使用；不限定 App，工作與等待不因五分鐘限制中斷，可隨時按「立即停止」。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
