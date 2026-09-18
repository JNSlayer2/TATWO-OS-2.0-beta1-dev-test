import AppKit
import SwiftUI

/// Blur the webpage behind the floating Chat toolbar, rather than the desktop.
struct BrowserToolbarGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = GlassView()
        view.material = .popover
        view.alphaValue = 1.0
        view.isEmphasized = false
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    final class GlassView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Observe without consuming events, including the full-size titlebar band.
struct BrowserToolbarHoverRegion: NSViewRepresentable {
    var onHover: (Bool) -> Void
    func makeNSView(context: Context) -> HoverView { HoverView() }
    func updateNSView(_ view: HoverView, context: Context) { view.onHover = onHover }
    final class HoverView: NSView {
        private static let regions = NSHashTable<HoverView>.weakObjects()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            Self.regions.add(self)
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            Self.regions.add(self)
        }
        static func containsInteractionPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
            regions.allObjects.contains { region in
                region.window === window && !region.isHiddenOrHasHiddenAncestor
                    && region.bounds.contains(region.convert(point, from: nil))
            }
        }
        var onHover: ((Bool) -> Void)?
        private var monitor: Any?
        private var tracking: NSTrackingArea?
        private var hovered = false
        private var hideWork: DispatchWorkItem?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .leftMouseDown && UserDefaults.standard.bool(forKey: "tatwo.browser.hitTestDiagnostics") {
                    NSLog("BrowserHit event=%@ local=%@ bounds=%@ window=%@", NSStringFromPoint(event.locationInWindow), NSStringFromPoint(self.convert(event.locationInWindow, from: nil)), NSStringFromRect(self.bounds), String(describing: type(of: event.window!)))
                }
                self.publish(self.bounds.contains(self.convert(event.locationInWindow, from: nil)))
                return event
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { publish(true) }
        override func mouseExited(with event: NSEvent) { publish(false) }
        private func publish(_ value: Bool) {
            hideWork?.cancel()
            hideWork = nil
            if !value {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hovered else { return }
                    self.hovered = false
                    self.onHover?(false)
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            } else if !hovered {
                hovered = true
                DispatchQueue.main.async { [weak self] in self?.onHover?(true) }
            }
        }
        deinit { hideWork?.cancel(); if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// The CEF child must yield mouse hits to SwiftUI chrome drawn above it.
final class BrowserChromeAwareContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, let superview,
           BrowserToolbarHoverRegion.HoverView.containsInteractionPoint(superview.convert(point, to: nil), in: window) {
            return nil
        }
        return super.hitTest(point)
    }
}

struct BrowserToolbarMaterial: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle()).allowsHitTesting(false)
        } else {
            BrowserToolbarGlass().allowsHitTesting(false)
        }
    }
}
