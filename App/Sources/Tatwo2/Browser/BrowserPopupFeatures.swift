import AppKit
import ObjectiveC
import TatwoCEFBridge

/// UI for a real CEF popup. Keeping the original browser is necessary for
/// window.open's handle, inherited profile, opener, and postMessage to work.
@MainActor
final class BrowserPopupFeatures: NSObject, NSSearchFieldDelegate {
    private static var associationKey: UInt8 = 0
    private weak var browser: TatwoCEFBrowserView?
    private let features: BrowserWebFeatures
    private weak var layout: Layout?
    private let search = NSSearchField()
    private let matches = NSTextField(labelWithString: "")
    private weak var previousResponder: NSResponder?
    private struct MonitorCleanup: @unchecked Sendable {
        let monitor: Any?
        let observer: NSObjectProtocol
        @MainActor func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(observer)
        }
    }
    private var monitorCleanup: MonitorCleanup?

    deinit {
        // Native close detaches contentView before posting willClose, so the
        // controller may be released before its window observer can run.
        let cleanup = monitorCleanup
        Task { @MainActor in cleanup?.remove() }
    }

    private final class Layout: NSView {
        weak var browser: NSView?
        var findBar: NSView?
        var keyEquivalent: ((NSEvent) -> Bool)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if keyEquivalent?(event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }
        override func layout() {
            super.layout()
            let height: CGFloat = findBar?.isHidden == false ? 40 : 0
            // Fullscreen temporarily reparents CEF; its overlay owns geometry then.
            if let browser, browser.superview === self {
                browser.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
            }
        }
    }

    static func attach(to browser: TatwoCEFBrowserView) {
        guard browser.browserActor == .human, !browser.agentControlled,
              objc_getAssociatedObject(browser, &associationKey) == nil,
              let window = browser.window else { return }
        let responder = window.firstResponder
        window.contentMinSize = NSSize(width: 320, height: 200)
        let layout = Layout(frame: window.contentView?.bounds ?? browser.bounds)
        layout.browser = browser
        browser.removeFromSuperview()
        layout.addSubview(browser)
        window.contentView = layout
        let controller = BrowserPopupFeatures(browser: browser, layout: layout)
        objc_setAssociatedObject(browser, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let responder = responder as? NSView, responder.isDescendant(of: browser) {
            window.makeFirstResponder(responder)
        }
    }

    private init(browser: TatwoCEFBrowserView, layout: Layout) {
        self.browser = browser
        self.layout = layout
        self.features = BrowserWebFeatures(browser: browser, container: layout)
        super.init()
        search.placeholderString = "在網頁中尋找"
        search.delegate = self
        search.target = self
        search.action = #selector(nextMatch)
        let previous = NSButton(title: "上一個", target: self, action: #selector(previousMatch))
        let next = NSButton(title: "下一個", target: self, action: #selector(nextMatch))
        let close = NSButton(title: "關閉搜尋", target: self, action: #selector(closeFind))
        for (button, symbol) in [(previous, "chevron.up"), (next, "chevron.down"), (close, "xmark")] {
            button.setAccessibilityLabel(button.title)
            button.toolTip = button.title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
            button.imagePosition = .imageOnly
            button.bezelStyle = .inline
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        matches.lineBreakMode = .byTruncatingTail
        matches.widthAnchor.constraint(lessThanOrEqualToConstant: 90).isActive = true
        let bar = NSStackView(views: [search, matches, previous, next, close])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.distribution = .fill
        bar.setHuggingPriority(.defaultLow, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        layout.findBar = bar
        layout.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: layout.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: layout.trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: layout.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 40)
        ])
        browser.onFindResult = { [weak self] count, index in
            guard let self else { return }
            if count >= 0 { self.matches.stringValue = "\(max(0, index))／\(count)" }
        }
        browser.onDailyShortcut = { [weak self] kind in
            guard let self, self.isHuman else { return }
            switch kind {
            case "menu:printPage": self.browser?.printPage()
            case "menu:printPDF": self.features.requestPDF()
            case "menu:openPDF": self.features.requestPDF(download: true)
            case "escape":
                if self.layout?.findBar?.isHidden == false { self.closeFind() }
                else { self.browser?.stopLoading() }
            default: break
            }
        }
        browser.onBrowserKeyEquivalent = { [weak self] event in
            // CEF owns this dispatch target; its translated event need not keep
            // AppKit's window reference. The native handler already rejects agents.
            self?.handleKeyEquivalent(event, requiresEventWindow: false) ?? false
        }
        // The native search field receives AppKit keys instead of CEF events.
        layout.keyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        // SwiftUI menu equivalents and Chromium's first responder can claim a
        // shortcut before an ancestor view sees it. Scope this early route to
        // this exact key window; unrelated windows and unbound keys pass through.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.browser?.window?.isKeyWindow == true else { return false }
                return self.handleKeyEquivalent(event)
            }
            return handled ? nil : event
        }
        let windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: browser.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.removeKeyMonitor() }
            }
        monitorCleanup = MonitorCleanup(monitor: keyMonitor, observer: windowCloseObserver)
        browser.onContextMenuAction = { [weak self] kind, value in
            guard let self, self.isHuman, let browser = self.browser else { return }
            switch kind {
            case "cut", "copy", "paste", "selectAll":
                if kind == "copy", !value.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } else { browser.performContextEdit(kind) }
            case "copyURL":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            case "back": browser.goBack()
            case "forward": browser.goForward()
            case "reload": browser.reload()
            case "download": browser.downloadImageURL(value)
            case "open": browser.onPopupRequested?(value)
            case "search":
                browser.onPopupRequested?(BrowserGeneralSettings.load().searchEngine.queryURL(value).absoluteString)
            default: break
            }
        }
    }

    private var isHuman: Bool { browser?.browserActor == .human && browser?.agentControlled == false }

    private func removeKeyMonitor() {
        monitorCleanup?.remove()
        monitorCleanup = nil
    }

    private func handleKeyEquivalent(_ event: NSEvent, requiresEventWindow: Bool = true) -> Bool {
        guard isHuman, let window = browser?.window, window.isVisible, window.attachedSheet == nil,
              (!requiresEventWindow || event.window === window || (event.window == nil && window.isKeyWindow)),
              let action = BrowserKeyCombo.invocation(event: event, shortcuts: BrowserGeneralSettings.load().shortcuts)?.action else { return false }
        return perform(action)
    }

    private func perform(_ action: BrowserAction) -> Bool {
        guard let browser, browser.browserActor == .human, !browser.agentControlled else { return false }
        switch action {
        case .closeTab: browser.window?.performClose(nil)
        case .back: browser.goBack()
        case .forward: browser.goForward()
        case .reload: browser.reload()
        case .stopLoading: browser.stopLoading()
        case .findInPage:
            if layout?.findBar?.isHidden == true { previousResponder = browser.window?.firstResponder }
            layout?.findBar?.isHidden = false
            layout?.needsLayout = true
            browser.window?.makeFirstResponder(search)
        case .zoomIn: browser.setZoomLevel(min(5, browser.zoomLevel + 1))
        case .zoomOut: browser.setZoomLevel(max(-5, browser.zoomLevel - 1))
        case .zoomReset: browser.setZoomLevel(0)
        case .printPage: browser.printPage()
        case .printPDF: features.requestPDF()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) { nextMatch() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === search, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeFind()
        return true
    }
    @objc private func nextMatch() { browser?.findText(search.stringValue, forward: true, matchCase: false) }
    @objc private func previousMatch() { browser?.findText(search.stringValue, forward: false, matchCase: false) }
    @objc private func closeFind() {
        browser?.stopFinding()
        layout?.findBar?.isHidden = true
        layout?.needsLayout = true
        if let browser, let responder = previousResponder as? NSView,
           responder.isDescendant(of: browser) {
            browser.window?.makeFirstResponder(responder)
        }
        previousResponder = nil
    }
}
