import SwiftUI
import AppKit
import TatwoUltraworkCore

struct UsagePage: View {
    let snapshot: TatwoAppSnapshot
    let initialLiveSnapshot: LiveQuotaDeckSnapshot?

    private var providers: [UsageProviderStatus] { snapshot.catalog.usageProviders }

    var body: some View {
        ModelQuotaTopDeck(providers: providers, initialLiveSnapshot: initialLiveSnapshot)
    }
}

