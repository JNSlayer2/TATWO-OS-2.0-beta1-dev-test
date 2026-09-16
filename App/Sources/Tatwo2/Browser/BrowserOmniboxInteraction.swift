import AppKit
import SwiftUI

/// Pure presentation policy shared by the real toolbar and native regression probe.
enum BrowserOmniboxPresentation {
    enum Event { case click, focusRequested, escape, focusLost, submit }

    static func isExpanded(after event: Event) -> Bool {
        switch event {
        case .click, .focusRequested: true
        case .escape, .focusLost, .submit: false
        }
    }

    static func domain(for urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString) else { return "搜尋或輸入網址" }
        if let host = url.host, !host.isEmpty { return host }
        return url.isFileURL ? "本機檔案" : "搜尋或輸入網址"
    }

    static func symbol(for urlString: String?) -> String {
        URL(string: urlString ?? "")?.scheme?.lowercased() == "https" ? "lock.fill" : "globe"
    }
}

/// Observe only while the editor is open. Native web views don't always update
/// SwiftUI FocusState on a mouse click. Never consume their event or install a
/// global monitor; suggestion clicks inside this panel must finish normally.
struct BrowserOmniboxDismissMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(onDismiss: onDismiss) }
    func updateNSView(_ view: MonitorView, context: Context) { view.onDismiss = onDismiss }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var onDismiss: () -> Void
        private var eventMonitor: Any?
        private var resignObserver: NSObjectProtocol?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                let inside = event.window === self.window
                    && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if !inside {
                    // Preserve the destination click (menu, annotation, CEF).
                    DispatchQueue.main.async { [weak self] in self?.onDismiss() }
                }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDismiss() }
            }
        }

        func stop() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            eventMonitor = nil
            resignObserver = nil
        }
    }
}
