import AppKit
import SwiftUI

/// Observe only this transcript's input; pass every event through unchanged.
/// Wheel intent arrives before streaming/layout callbacks can pull the reader back.
struct ChatTranscriptScrollIntentObserver: NSViewRepresentable {
    var detach: () -> Void

    func makeNSView(context: Context) -> Observer {
        let view = Observer()
        view.detach = detach
        return view
    }
    func updateNSView(_ view: Observer, context: Context) { view.detach = detach }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    final class Observer: NSView {
        var detach: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .scrollWheel {
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point), event.scrollingDeltaY > 0 { self.detach?() }
                } else if event.type == .leftMouseDown || event.type == .leftMouseDragged {
                    if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.detach?() }
                } else if [115, 116].contains(event.keyCode), // Home / Page Up
                          let responder = window.firstResponder as? NSView,
                          !(responder is NSTextView) {
                    // Do not intercept caret navigation in the composer/editor.
                    let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                    if self.bounds.contains(point) { self.detach?() }
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
