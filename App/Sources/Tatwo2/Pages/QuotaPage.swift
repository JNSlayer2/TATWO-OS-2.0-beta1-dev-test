// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/QuotaPage.swift；改動 2 行（原因：run A usage 照搬；移除舊 core import，資料由同名 Facade 提供）
import SwiftUI
import AppKit

struct UsagePage: View {
    let snapshot: TatwoAppSnapshot
    let initialLiveSnapshot: LiveQuotaDeckSnapshot?

    private var providers: [UsageProviderStatus] { snapshot.catalog.usageProviders }

    var body: some View {
        ModelQuotaTopDeck(providers: providers, initialLiveSnapshot: initialLiveSnapshot)
    }
}

