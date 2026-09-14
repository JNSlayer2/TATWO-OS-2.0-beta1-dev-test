import AppKit
import SwiftUI

struct BrowserDefaultBrowserRow: View {
    @State private var currentBrowser = "查詢中…"
    @State private var isSetting = false
    @State private var failure: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("預設瀏覽器：\(currentBrowser)")
                if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            }
            Spacer()
            Button("設為預設", action: setDefaultBrowser).disabled(isSetting)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else {
            currentBrowser = "尚未設定"
            return
        }
        let bundle = Bundle(url: url)
        currentBrowser = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func setDefaultBrowser() {
        guard !isSetting else { return }
        isSetting = true
        failure = nil
        // Request both schemes through the consent API, never write Launch Services preferences.
        Task { @MainActor in
            defer { isSetting = false; refresh() }
            for scheme in ["http", "https"] {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(
                        at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                } catch {
                    failure = "\(scheme) 設定失敗：\(error.localizedDescription)"
                    return
                }
            }
        }
    }
}
