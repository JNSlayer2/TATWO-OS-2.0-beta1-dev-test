import AppKit
import WebKit
import Combine

@MainActor final class IslandQuotesNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    var openExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "tradingview.com" || host.hasSuffix(".tradingview.com")
            || host == "tradingview-widget.com" || host.hasSuffix(".tradingview-widget.com")
    }
    func policy(for url: URL) -> WKNavigationActionPolicy {
        if Self.allowed(url) { return .allow }
        if IslandQuotesTestPolicy.isEnabled(), IslandQuotesTestPolicy.isExactAboutBlank(url) { return .allow }   // DEBUG 測試 flag＋exact about:blank 才放行；production allowlist 不動
        // File, custom schemes and data URLs must never reach an external handler.
        if ["https", "http"].contains(url.scheme ?? "") { openExternal(url) }
        return .cancel
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(policy(for: url))
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { _ = policy(for: url); if Self.allowed(url) { openExternal(url) } }
        return nil
    }
}
@MainActor final class IslandQuotesProvider: ObservableObject, IslandSpaceProvider {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var memoryPaused = false
    let settings: [String: String]
    let navigation = IslandQuotesNavigation()
    init(settings: [String: String]) { self.settings = settings }
    var symbols: [String] {
        (settings["symbols"] ?? "BINANCE:BTCUSDT,BINANCE:ETHUSDT").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && $0.range(of: "^[A-Z0-9_:.\\-]+$", options: .regularExpression) != nil }.prefix(20).map { $0 }
    }
    // TradingView official legacy iframe widget, no API key or custom script bridge.
    var widgetURL: URL {
        var components = URLComponents(string: "https://s.tradingview.com/embed-widget/ticker-tape/")!
        let configuration: [String: Any] = ["symbols": symbols.map { ["proName": $0] }, "colorTheme": "dark", "locale": "en", "isTransparent": true, "displayMode": "adaptive"]
        let data = (try? JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])) ?? Data()
        components.fragment = String(decoding: data, as: UTF8.self)
        return components.url!
    }
    var snapshot: IslandSpaceSnapshot { .init(lines: memoryPaused ? ["行情暫停（記憶體）"] : symbols) }
    func activate() {
        guard webView == nil, !memoryPaused else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = navigation; view.uiDelegate = navigation
        webView = view
        if IslandQuotesTestPolicy.isEnabled() {
            view.loadHTMLString(IslandQuotesTestPolicy.staticHTML, baseURL: nil)   // 固定靜態 HTML、base about:blank、無外連；同一條建立／delegate／release 路徑
        } else {
            view.load(URLRequest(url: widgetURL))
        }
    }
    // Unload on page switches as well: WebKit exposes no reliable suspension of remote JS timers.
    func suspend() { releaseWebView() }
    func unload() { releaseWebView() }
    private func releaseWebView() {
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView?.removeFromSuperview(); webView = nil
    }
    func pauseForMemory() { memoryPaused = true; unload() }
}
