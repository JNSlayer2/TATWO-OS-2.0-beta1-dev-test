import SwiftUI
import TatwoDomainContracts

// 設備分頁視覺結構（2026-08-14 藍圖）：
// 頂部設備卡 → ①版本同步 → ②資料同步 → ③Loops 派送與壓力。
// 舊 Mac-mini→target 進度牆與證據讀取失敗區塊已移除。
// 資料模組列讀 registry + enablement + runtime hooks。

struct DevicesPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @ObservedObject private var chatModel: ChatPageModel
    private let deviceSnapshotProvider: any DomainDeviceSnapshotProvider

    init(
        chatModel: ChatPageModel,
        deviceSnapshotProvider: any DomainDeviceSnapshotProvider =
            TatwoDevicesCompositionRoot.makeProvider()
    ) {
        _chatModel = ObservedObject(wrappedValue: chatModel)
        self.deviceSnapshotProvider = deviceSnapshotProvider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceCrossSyncCard(
                chatModel: chatModel,
                deviceSnapshotProvider: deviceSnapshotProvider
            )
            DevicePressureMonitorCard(
                remoteAuthorizationStore: chatModel.remoteBorrowAuthorizationStore,
                deviceSnapshotProvider: deviceSnapshotProvider
            )
        }
    }
}
