import AppKit
import SwiftUI

/// Native tracking keeps the resize cursor and hit target independent of CEF.
struct ChatBrowserDivider: NSViewRepresentable {
    var onStart: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.onStart = onStart; view.onDrag = onDrag; view.onEnd = onEnd
    }

    final class DividerView: NSView {
        var onStart: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startX: CGFloat?
        private var previousMovable: Bool?
        private var tracking: NSTrackingArea?
        private var hovered = false
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityLabel("調整聊天與瀏覽器寬度")
            setAccessibilityIdentifier("chat.browser.divider")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
                owner: self, userInfo: nil)
            addTrackingArea(area); tracking = area
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) {
            hovered = true; needsDisplay = true; NSCursor.resizeLeftRight.set()
        }
        override func mouseExited(with event: NSEvent) {
            hovered = false; needsDisplay = true
            if startX == nil { NSCursor.arrow.set() }
        }
        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            previousMovable = window?.isMovable
            window?.isMovable = false
            onStart?(); NSCursor.resizeLeftRight.set()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag?(event.locationInWindow.x - startX); NSCursor.resizeLeftRight.set()
        }
        override func mouseUp(with event: NSEvent) {
            if let startX { onDrag?(event.locationInWindow.x - startX) }
            startX = nil
            if let previousMovable { window?.isMovable = previousMovable }
            previousMovable = nil
            (window as? TatwoWorkOSWindow)?.layoutTatwoTrafficLights()
            onEnd?()
        }
        override func draw(_ dirtyRect: NSRect) {
            // One physical pixel, aligned to the backing grid; hit area stays wide.
            NSColor.separatorColor.withAlphaComponent(hovered ? 0.8 : 0.5).setFill()
            let scale = window?.backingScaleFactor ?? 2
            let x = floor(bounds.midX * scale) / scale
            NSRect(x: x, y: bounds.minY, width: 1 / scale, height: bounds.height).fill()
        }
    }
}
