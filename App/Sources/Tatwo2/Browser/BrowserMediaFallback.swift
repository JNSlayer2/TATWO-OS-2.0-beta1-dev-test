import AppKit
#if canImport(TatwoCEFBridge)
import TatwoCEFBridge
#endif

/// Boolean-only fixture counterpart of the native bridge's media probe.
/// The probe reads no URL, text, media source, form value or page content.
enum BrowserMediaProbe {
    static let expression = #"""
    (() => {
      const video = document.querySelector('video');
      return !!video && document.createElement('video').canPlayType('video/mp4; codecs="avc1.42E01E"') === '';
    })()
    """#
}

@MainActor
enum BrowserMediaFallback {
    static let messageKind = "tatwo.media.codec_unsupported"

    static func isCodecMessage(_ message: String) -> Bool {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["kind", "host"],
              object["kind"] as? String == messageKind,
              let host = object["host"] as? String, !host.isEmpty else { return false }
        return true
    }

    static func receive(
        message: String, tabID: UUID, url: URL, registry: BrowserTabRegistry,
        isCurrent: @escaping @MainActor () -> Bool,
        notice: IslandNotice? = nil,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async {
        await receive(codecUnavailable: isCodecMessage(message), tabID: tabID, url: url,
                      registry: registry, isCurrent: isCurrent, notice: notice, open: open)
    }

#if canImport(TatwoCEFBridge)
    /// The host's existing callback has already checked selected tab + entry identity.
    /// Capture the mounted native browser synchronously, not after scheduling the Task.
    static func dispatch(
        message: String, tabID: UUID, host: NSView, registry: BrowserTabRegistry,
        isSelected: @escaping @MainActor () -> Bool
    ) {
        func visibleBrowser(_ view: NSView) -> TatwoCEFBrowserView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let browser = view as? TatwoCEFBrowserView { return browser }
            return view.subviews.lazy.compactMap { visibleBrowser($0) }.first
        }
        guard isCodecMessage(message), let browser = visibleBrowser(host),
              let value = browser.currentURLString, let url = URL(string: value) else { return }
        let generation = browser.navigationGeneration
        let isCurrent: @MainActor () -> Bool = { [weak browser, weak host] in
            guard let browser, let host else { return false }
            return isSelected() && browser.isDescendant(of: host) &&
                browser.window != nil && !browser.isHiddenOrHasHiddenAncestor &&
                browser.browserActor == .human && !browser.agentControlled &&
                browser.navigationGeneration == generation && browser.currentURLString == value
        }
        Task { @MainActor in
            await receive(message: message, tabID: tabID, url: url, registry: registry,
                          isCurrent: isCurrent, open: { BrowserWebFeatures.openInSystemBrowser($0) })
        }
    }
#endif

    /// The bridge adapter must bind isCurrent to browser identity + navigation generation
    /// + visible human actor, both before the prompt and after approval.
    static func receive(
        codecUnavailable: Bool, tabID: UUID, url: URL, registry: BrowserTabRegistry,
        isCurrent: @escaping @MainActor () -> Bool,
        notice: IslandNotice? = nil,
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) async {
        guard codecUnavailable, isCurrent(),
              registry.reserveCodecNotice(tabID: tabID, url: url) else { return }
        defer { registry.finishCodecNotice(url: url) }
        let notice = notice ?? .shared
        let decision = await notice.ask(
            title: "此頁影片用 H.264，OS 內建瀏覽器未含專有解碼器",
            detail: "可用系統瀏覽器接手；不會傳送內建瀏覽器的登入資料。",
            allowLabel: "用系統瀏覽器開此頁", timeout: 30)
        if decision == .cancel {
            registry.dismissCodecNotice(url: url)
        }
        guard decision == .allow, isCurrent(),
              let tab = registry.tabs.first(where: { $0.id == tabID && $0.url == url }),
              !tab.usesAgentContext else { return }
        if case .bot = tab.owner { return }
        if !open(url) {
            notice.info(title: "無法開啟系統瀏覽器", detail: "請稍後重試。")
        }
    }
}
