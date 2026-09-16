import AppKit
import SwiftUI

@MainActor enum IslandExceptionsNavigation { static weak var shell: TatwoIslandShellState? }
@MainActor final class IslandNotice: ObservableObject {
    static let shared = IslandNotice()
    var hostAvailable = false
    struct Request { let id = UUID() }
    enum Decision { case cancel }
    @Published var current: Request?
    func resolve(_ decision: Decision, id: UUID) {}
}
struct IslandNoticeContent: View {
    let isExpanded: Bool
    var body: some View { Color.clear.allowsHitTesting(false) }
}

@main struct IslandControllerChecks {
    @MainActor static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let saved = CGEvent(source: nil)!.location
        defer { CGWarpMouseCursorPosition(saved) }
        var controller: TatwoIslandShellController? = TatwoIslandShellController()
        controller!.show(); pump(0.3)
        let state = IslandExceptionsNavigation.shell!
        let panel = app.windows.first { $0 is TatwoIslandShellPanel }!
        let screenTop = NSScreen.screens[0].frame.maxY
        func move(_ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: screenTop - point.y), mouseButton: .left)?.post(tap: .cghidEventTap)
            pump(0.3)
        }
        func leave() { move(CGPoint(x: panel.frame.midX, y: panel.frame.minY - 100)) }
        func enter() { move(CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 15)) }
        for _ in 0..<3 {
            leave(); enter()
            precondition(state.isExpanded, "native hover alone expands without any click")
            leave(); pump(3.4)
            precondition(!state.isExpanded, "native hover exit alone collapses without any click")
        }
        enter()
        precondition(state.isExpanded, "native pointer enter expands")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type,
                location: NSPoint(x: panel.frame.width / 2, y: panel.frame.height - 15),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            app.sendEvent(event)
        }
        leave(); pump(3.4)
        precondition(!state.isExpanded, "native click then exit collapses")
        // Suppress tracking callbacks to reproduce a lost mouseExited on rebuild.
        func suppressTracking(_ view: NSView) {
            if let tracker = view as? TatwoIslandHoverTrackingView.TrackingView { tracker.onHover = nil }
            view.subviews.forEach(suppressTracking)
        }
        state.setPointerInside(true)
        suppressTracking(panel.contentView!)
        pump(3.6)
        precondition(!state.isExpanded, "controller repairs stale pointer without mouseExited")
        state.expandForNavigation(); pump(3.4)
        precondition(!state.isExpanded, "programmatic open outside self-collapses")
        state.holdOpen(true); pump(3.4)
        precondition(state.isExpanded, "consent hold survives pointer reconciliation")
        state.holdOpen(false); pump(3.4)
        precondition(!state.isExpanded, "release outside self-collapses")
        panel.orderOut(nil); controller = nil
        print("ISLAND CONTROLLER PASS: real click/exit, lost exit, navigation, consent")
    }
}
