import SwiftUI
import AppKit
import Foundation
import TatwoUltraworkCore
import TatwoUltraworkCore

final class ChatSliderPointerCaptureView: LiquidGlassDashboardSliderPointerCaptureView {
    var onCancelled: (() -> Void)?
    private var lifecycle = TatwoChatSliderPointerLifecycle()
    private weak var attachedWindow: NSWindow?
    private var localEventMonitor: Any?
    private var appResignActiveObserver: NSObjectProtocol?
    private var windowWillCloseObserver: NSObjectProtocol?
    private var windowDidResignKeyObserver: NSObjectProtocol?
    private var isAttached = false
    private static let pointerDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["TATWO_SLIDER_POINTER_DEBUG"] == "1"

    init() {
        super.init(debugSource: "lgd-pointer-overlay")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if isAttached && (newWindow == nil || newWindow !== attachedWindow) {
            detachFromCurrentWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            attach(to: window)
        }
    }

    override func mouseDown(with _: NSEvent) {}

    override func mouseDragged(with _: NSEvent) {}

    override func mouseUp(with _: NSEvent) {}

    isolated deinit {
        removeInputInfrastructure()
    }

    func detachFromCurrentWindow() {
        guard isAttached ||
              localEventMonitor != nil ||
              appResignActiveObserver != nil ||
              windowWillCloseObserver != nil ||
              windowDidResignKeyObserver != nil ||
              lifecycle.infrastructureInstalled ||
              lifecycle.phase != .idle else {
            return
        }
        apply(lifecycle.detachFromWindow())
        isAttached = false
        attachedWindow = nil
    }

    func dismantleRepresentable() {
        apply(lifecycle.dismantleRepresentable())
        isAttached = false
        attachedWindow = nil
        onBegan = nil
        onChanged = nil
        onEnded = nil
        onCancelled = nil
        lifecycle.clearCallbacks()
    }

    func synchronizePendingSettle(_ isPending: Bool) {
        lifecycle.synchronizePendingSettle(isPending)
    }

    private func attach(to window: NSWindow) {
        if isAttached,
           attachedWindow === window,
           localEventMonitor != nil,
           appResignActiveObserver != nil,
           windowWillCloseObserver != nil,
           windowDidResignKeyObserver != nil,
           lifecycle.infrastructureInstalled {
            return
        }
        if isAttached ||
           localEventMonitor != nil ||
           appResignActiveObserver != nil ||
           windowWillCloseObserver != nil ||
           windowDidResignKeyObserver != nil ||
           lifecycle.infrastructureInstalled {
            detachFromCurrentWindow()
        }
        attachedWindow = window
        isAttached = true
        let attachTransition = lifecycle.attachInfrastructure()
        guard attachTransition.installInfrastructure else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalPointerEvent(event)
            }
            return event
        }
        guard localEventMonitor != nil else {
            lifecycle.infrastructureInstallationFailed()
            isAttached = false
            attachedWindow = nil
            return
        }
        installLifecycleObservers(for: window)
        debugPointerEvent("monitor-installed")
    }

    private func removeLocalEventMonitor() {
        guard let localEventMonitor else { return }
        NSEvent.removeMonitor(localEventMonitor)
        self.localEventMonitor = nil
        debugPointerEvent("monitor-removed")
    }

    private func installLifecycleObservers(for window: NSWindow) {
        removeLifecycleObservers()
        let center = NotificationCenter.default
        appResignActiveObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelAndDetachFromCurrentWindow()
            }
        }
        windowWillCloseObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelAndDetachFromCurrentWindow()
            }
        }
        windowDidResignKeyObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelAndDetachFromCurrentWindow()
            }
        }
    }

    private func removeLifecycleObservers() {
        let center = NotificationCenter.default
        if let appResignActiveObserver {
            center.removeObserver(appResignActiveObserver)
            self.appResignActiveObserver = nil
        }
        if let windowWillCloseObserver {
            center.removeObserver(windowWillCloseObserver)
            self.windowWillCloseObserver = nil
        }
        if let windowDidResignKeyObserver {
            center.removeObserver(windowDidResignKeyObserver)
            self.windowDidResignKeyObserver = nil
        }
    }

    private func removeInputInfrastructure() {
        removeLocalEventMonitor()
        removeLifecycleObservers()
    }

    private func cancelActiveInteractionOrPendingSettle() {
        apply(lifecycle.invalidateLifecycle())
    }

    private func cancelAndDetachFromCurrentWindow() {
        cancelActiveInteractionOrPendingSettle()
        detachFromCurrentWindow()
    }

    private func handleLocalPointerEvent(_ event: NSEvent) {
        debugObservedPointerEvent(event)
        switch event.type {
        case .leftMouseDown:
            guard let attachedWindow,
                  event.window === attachedWindow,
                  onBegan != nil || onChanged != nil || onEnded != nil else {
                return
            }
            guard let point = routedLocalPoint(for: event) else { return }
            guard bounds.contains(point) else { return }
            let x = clampedX(point.x)
            debugPointerEvent("monitor-down", x: x)
            apply(lifecycle.pointerDown(at: x))
        case .leftMouseDragged:
            let x = trackedX(for: event)
            if let x {
                debugPointerEvent("monitor-drag", x: x)
            }
            apply(lifecycle.pointerDragged(to: x))
        case .leftMouseUp:
            let x = trackedX(for: event)
            if let x {
                debugPointerEvent("monitor-up", x: x)
            } else if case let .tracking(lastKnownX) = lifecycle.phase {
                debugPointerEvent("monitor-up-last-known", x: lastKnownX)
            }
            apply(lifecycle.pointerUp(at: x))
        default:
            return
        }
    }

    private func apply(_ transition: TatwoChatSliderPointerTransition) {
        if transition.removeInfrastructure {
            removeInputInfrastructure()
        }
        for callback in transition.callbacks {
            guard lifecycle.callbacksActive else { return }
            switch callback {
            case let .began(x):
                onBegan?(x)
            case let .changed(x):
                onChanged?(x)
            case let .ended(x):
                onEnded?(x)
            case .cancelled:
                debugPointerEvent("monitor-cancelled")
                onCancelled?()
            }
        }
    }

    private func trackedX(for event: NSEvent) -> CGFloat? {
        guard let point = routedLocalPoint(for: event) else { return nil }
        return clampedX(point.x)
    }

    private func routedLocalPoint(for event: NSEvent) -> NSPoint? {
        guard let attachedWindow else { return nil }
        if let quartzPoint = event.cgEvent?.location {
            guard let screenPoint = Self.appKitScreenPoint(forQuartzPoint: quartzPoint) else {
                return nil
            }
            let pointInAttachedWindow = attachedWindow.convertPoint(fromScreen: screenPoint)
            return convert(pointInAttachedWindow, from: nil)
        }

        // Only native AppKit events without an underlying CGEvent may use
        // locationInWindow. Synthetic events with a CGEvent never fall back to
        // their known-invalid window coordinates.
        guard event.window === attachedWindow else { return nil }
        return convert(event.locationInWindow, from: nil)
    }

    private static func appKitScreenPoint(forQuartzPoint quartzPoint: NSPoint) -> NSPoint? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let quartzBounds = CGDisplayBounds(displayID)
            guard quartzBounds.width > 0,
                  quartzBounds.height > 0,
                  quartzBounds.contains(quartzPoint) else {
                continue
            }

            let relativeX = (quartzPoint.x - quartzBounds.minX) / quartzBounds.width
            let relativeY = (quartzPoint.y - quartzBounds.minY) / quartzBounds.height
            return NSPoint(
                x: screen.frame.minX + (relativeX * screen.frame.width),
                y: screen.frame.maxY - (relativeY * screen.frame.height)
            )
        }
        return nil
    }

    private func clampedX(_ x: CGFloat) -> CGFloat {
        min(max(x, 0), bounds.width)
    }

    private func debugObservedPointerEvent(_ event: NSEvent) {
        guard Self.pointerDiagnosticsEnabled else { return }
        let observedEvent: String
        switch event.type {
        case .leftMouseDown:
            observedEvent = "monitor-observed-down"
        case .leftMouseDragged:
            guard case .tracking = lifecycle.phase else { return }
            observedEvent = "monitor-observed-drag"
        case .leftMouseUp:
            guard case .tracking = lifecycle.phase else { return }
            observedEvent = "monitor-observed-up"
        default:
            return
        }

        let eventWindow = event.window
        let attachedWindow = attachedWindow
        let localPoint = convert(event.locationInWindow, from: nil)
        let eventWindowID = eventWindow.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        let eventWindowFrame = eventWindow.map { NSStringFromRect($0.frame) } ?? "nil"
        let attachedWindowID = attachedWindow.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
        let attachedWindowFrame = attachedWindow.map { NSStringFromRect($0.frame) } ?? "nil"
        let mouseLocation = NSEvent.mouseLocation
        let mouseAttachedPoint = attachedWindow.map { $0.convertPoint(fromScreen: mouseLocation) }
        let mouseLocalPoint = mouseAttachedPoint.map { convert($0, from: nil) }
        let cgEventLocation: NSPoint? = event.cgEvent?.location
        let cgScreenPoint = cgEventLocation.flatMap {
            Self.appKitScreenPoint(forQuartzPoint: $0)
        }
        let cgAttachedPoint = cgScreenPoint.flatMap { screenPoint in
            attachedWindow.map { $0.convertPoint(fromScreen: screenPoint) }
        }
        let cgLocalPoint = cgAttachedPoint.map { convert($0, from: nil) }
        let details =
            "eventWindowID=\(eventWindowID) eventWindowFrame=\(eventWindowFrame) " +
            "attachedWindowID=\(attachedWindowID) attachedWindowFrame=\(attachedWindowFrame) " +
            "eventLocation=\(NSStringFromPoint(event.locationInWindow)) " +
            "localPoint=\(NSStringFromPoint(localPoint)) bounds=\(NSStringFromRect(bounds)) " +
            "sameWindow=\(eventWindow != nil && eventWindow === attachedWindow) " +
            "boundsContains=\(bounds.contains(localPoint)) " +
            "mouseLocation=\(NSStringFromPoint(mouseLocation)) " +
            "mouseAttachedPoint=\(mouseAttachedPoint.map(NSStringFromPoint) ?? "nil") " +
            "mouseLocalPoint=\(mouseLocalPoint.map(NSStringFromPoint) ?? "nil") " +
            "mouseBoundsContains=\(mouseLocalPoint.map { String(bounds.contains($0)) } ?? "nil") " +
            "cgEventLocation=\(cgEventLocation.map(NSStringFromPoint) ?? "nil") " +
            "cgScreenPoint=\(cgScreenPoint.map(NSStringFromPoint) ?? "nil") " +
            "cgAttachedPoint=\(cgAttachedPoint.map(NSStringFromPoint) ?? "nil") " +
            "cgLocalPoint=\(cgLocalPoint.map(NSStringFromPoint) ?? "nil") " +
            "cgBoundsContains=\(cgLocalPoint.map { String(bounds.contains($0)) } ?? "nil")"
        debugPointerEvent(observedEvent, details: details)
    }

    private func debugPointerEvent(
        _ event: String,
        x: CGFloat? = nil,
        details: String? = nil
    ) {
        guard Self.pointerDiagnosticsEnabled else { return }
        let localX = x.map { String(format: " localX=%.2f", Double($0)) } ?? ""
        let detailSuffix = details.map { " \($0)" } ?? ""
        let captureID = String(describing: ObjectIdentifier(self))
        let line = "\(ISO8601DateFormatter().string(from: Date())) source=lgd-pointer-overlay event=\(event) capture=\(captureID)\(localX)\(detailSuffix)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/tatwo-slider-pointer.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

struct ChatSliderPointerOverlay: NSViewRepresentable {
    var onBegan: ((CGFloat) -> Void)?
    var onChanged: ((CGFloat) -> Void)?
    var onEnded: ((CGFloat) -> Void)?
    var onCancelled: (() -> Void)?
    var pendingSettleActive = false

    func makeNSView(context _: Context) -> ChatSliderPointerCaptureView {
        let captureView = ChatSliderPointerCaptureView()
        captureView.setAccessibilityElement(false)
        updateCallbacks(captureView)
        return captureView
    }

    func updateNSView(_ captureView: ChatSliderPointerCaptureView, context _: Context) {
        updateCallbacks(captureView)
    }

    static func dismantleNSView(_ captureView: ChatSliderPointerCaptureView, coordinator _: ()) {
        captureView.dismantleRepresentable()
    }

    private func updateCallbacks(_ captureView: ChatSliderPointerCaptureView) {
        captureView.onBegan = onBegan
        captureView.onChanged = onChanged
        captureView.onEnded = onEnded
        captureView.onCancelled = onCancelled
        captureView.synchronizePendingSettle(pendingSettleActive)
    }
}

enum SliderWindowRouteProbeLogger {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TATWO_SLIDER_WINDOW_ROUTE_PROBE"] == "1"
    }

    static func logAction(control: String, value: Double) {
        append(
            String(
                format: "source=window-route-probe control=%@ event=action value=%.4f\n",
                control,
                value
            )
        )
    }

    @MainActor
    @discardableResult
    static func logAttachEvidence(candidate: NSView) -> Bool {
        guard isEnabled,
              let window = candidate.window,
              let contentView = window.contentView,
              candidate.bounds.width > 0,
              candidate.bounds.height > 0,
              candidate === contentView || candidate.isDescendant(of: contentView) else {
            return false
        }

        let localCenter = NSPoint(x: candidate.bounds.midX, y: candidate.bounds.midY)
        let windowCenter = candidate.convert(localCenter, to: nil)
        let contentCenter = contentView.convert(localCenter, from: candidate)
        let screenCenter = window.convertPoint(toScreen: windowCenter)
        let target = contentView.hitTest(contentCenter)
        let targetRelation: String
        if target === candidate {
            targetRelation = "candidate"
        } else if let target, target.isDescendant(of: candidate) {
            targetRelation = "descendant"
        } else if let target, candidate.isDescendant(of: target) {
            targetRelation = "ancestor-hosting-root"
        } else if target != nil {
            targetRelation = "unrelated"
        } else {
            targetRelation = "nil"
        }

        var ancestorClasses: [String] = []
        var ancestor: NSView? = candidate
        while let current = ancestor {
            ancestorClasses.append(String(describing: type(of: current)))
            if current === contentView {
                break
            }
            ancestor = current.superview
        }

        let targetClass = target.map { String(describing: type(of: $0)) } ?? "nil"
        append(
            [
                "source=window-route-probe",
                "control=popover-native",
                "event=attach-layout",
                "candidateClass=\(String(describing: type(of: candidate)))",
                "ancestorClasses=\(ancestorClasses.joined(separator: ">"))",
                "windowClass=\(String(describing: type(of: window)))",
                "windowNumber=\(window.windowNumber)",
                "frame=\(rect(candidate.frame))",
                "bounds=\(rect(candidate.bounds))",
                "centerLocal=\(point(localCenter))",
                "centerWindow=\(point(windowCenter))",
                "centerContent=\(point(contentCenter))",
                "centerScreen=\(point(screenCenter))",
                "hitTargetClass=\(targetClass)",
                "targetRelation=\(targetRelation)"
            ].joined(separator: " ") + "\n"
        )
        return true
    }

    private static func append(_ line: String) {
        guard isEnabled, let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/tatwo-slider-window-route-probe.log")
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func point(_ point: NSPoint) -> String {
        String(format: "(%.2f,%.2f)", point.x, point.y)
    }

    private static func rect(_ rect: NSRect) -> String {
        String(
            format: "(x=%.2f,y=%.2f,w=%.2f,h=%.2f)",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }
}

struct SliderWindowRouteProbeButton: NSViewRepresentable {
    let title: String
    let onAction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeNSView(context: Context) -> HostView {
        let host = HostView()
        host.button.title = title
        host.button.target = context.coordinator
        host.button.action = #selector(Coordinator.performAction(_:))
        return host
    }

    func updateNSView(_ host: HostView, context: Context) {
        context.coordinator.onAction = onAction
        host.button.title = title
        host.button.target = context.coordinator
        host.button.action = #selector(Coordinator.performAction(_:))
        host.requestAttachEvidence()
    }

    final class Coordinator: NSObject {
        var onAction: () -> Void

        init(onAction: @escaping () -> Void) {
            self.onAction = onAction
        }

        @objc func performAction(_: NSButton) {
            onAction()
        }
    }

    final class HostView: NSView {
        let button: NSButton
        private var didLogAttachEvidence = false

        override init(frame frameRect: NSRect) {
            button = NSButton(title: "P · Native AppKit NSButton", target: nil, action: nil)
            super.init(frame: frameRect)
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.identifier = NSUserInterfaceItemIdentifier("window-route-probe-popover-native")
            button.setAccessibilityIdentifier("window-route-probe-popover-native")
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                didLogAttachEvidence = false
            } else {
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            button.frame = bounds
            guard !didLogAttachEvidence,
                  window != nil,
                  button.bounds.width > 0,
                  button.bounds.height > 0 else {
                return
            }
            didLogAttachEvidence = SliderWindowRouteProbeLogger.logAttachEvidence(candidate: button)
        }

        func requestAttachEvidence() {
            guard !didLogAttachEvidence else { return }
            needsLayout = true
        }
    }
}
