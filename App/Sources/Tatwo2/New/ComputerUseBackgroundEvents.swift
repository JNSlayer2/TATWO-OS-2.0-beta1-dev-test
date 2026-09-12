import AppKit
import ApplicationServices
import os

/// Background pointer input that never touches the user's cursor or front App (2026-09-11).
///
/// macOS drops mouse events posted to a background App's pid. So, like Codex's
/// SyntheticAppFocusEnforcer ("applicationBelievesItIsActive"), the target first receives an AppKit
/// "application activated" event record — it now believes it is active while the window server's front
/// App stays the user's — then window-local mouse records, then "deactivated". Records are delivered
/// through SkyLight's per-process event channel (SLPSPostEventRecordTo). Real-machine probes: Calculator
/// button click, TextEdit caret click / double-click word select / text drag select / context menu, and a
/// Safari HTML5 drag-and-drop (trusted=true), all with the cursor and front App unchanged.
enum ComputerUseBackgroundEvents {
    private typealias PostRecord = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    private struct Symbols: @unchecked Sendable { let post: PostRecord; let psn: ProcessForPID }
    private static let symbols: Symbols? = {
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let post = dlsym(sky, "SLPSPostEventRecordTo"),
              let psn = dlsym(dlopen(nil, RTLD_NOW), "GetProcessForPID") else { return nil }
        return Symbols(post: unsafeBitCast(post, to: PostRecord.self), psn: unsafeBitCast(psn, to: ProcessForPID.self))
    }()
    static var available: Bool {
        symbols != nil && ProcessInfo.processInfo.environment["TATWO_CU_DISABLE_BACKGROUND_EVENTS"] != "1"
    }

    enum MouseType: UInt8 { case leftDown = 1, leftUp = 2, rightDown = 3, rightUp = 4, leftDragged = 6 }

    struct Target: Sendable {
        let psn: ProcessSerialNumber
        let windowID: UInt32
        let windowBounds: CGRect
    }

    private static let eventNumber = OSAllocatedUnfairLock(initialState: Int16(9000))
    private static let lastPointBox = OSAllocatedUnfairLock<CGPoint?>(initialState: nil)

    static func nextEventNumber() -> Int16 { eventNumber.withLock { $0 &+= 1; return $0 } }

    /// Where the last background pointer action landed, in AppKit (bottom-left) screen coordinates,
    /// for the on-screen TATWO pointer. Read once.
    static func takeLastPoint() -> CGPoint? { lastPointBox.withLock { let p = $0; $0 = nil; return p } }
    static func noteLastPoint(_ globalTopLeft: CGPoint) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        lastPointBox.withLock { $0 = CGPoint(x: globalTopLeft.x, y: height - globalTopLeft.y) }
    }

    /// The target App's front-most window (any layer: menus and popovers too) under a global top-left point.
    static func target(pid: pid_t, at point: CGPoint) throws -> Target {
        guard let symbols else { throw ComputerUseFailure("computer_input_unavailable") }
        var psn = ProcessSerialNumber()
        guard symbols.psn(pid, &psn) == 0 else { throw ComputerUseFailure("computer_target_closed") }
        for option in [CGWindowListOption.optionOnScreenOnly, .optionAll] {
            let list = CGWindowListCopyWindowInfo([option], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
                guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: dict), bounds.contains(point),
                      let number = info[kCGWindowNumber as String] as? Int else { continue }
                return Target(psn: psn, windowID: UInt32(number), windowBounds: bounds)
            }
        }
        throw ComputerUseFailure("computer_pointer_outside_observation")
    }

    static func activate(_ target: Target) { send(target, 0x0d, subtype: 1) }
    /// Makes the window key inside the App (left down/up records aimed at the window with an invalid
    /// location, so nothing is clicked). After activate + focus, key equivalents reach it: probed on a
    /// background TextEdit, ⌘S opened the save sheet with the user's front App unchanged (2026-09-11).
    static func focus(_ target: Target) {
        guard let symbols else { return }
        for type: UInt8 in [MouseType.leftDown.rawValue, MouseType.leftUp.rawValue] {
            var record = [UInt8](repeating: 0, count: 0xf8)
            record[0x04] = 0xf8
            record[0x08] = type
            record[0x3a] = 0x10
            withUnsafeBytes(of: target.windowID) { for (i, b) in $0.enumerated() { record[0x3c + i] = b } }
            for i in 0x20..<0x30 { record[i] = 0xff }
            var psn = target.psn
            _ = record.withUnsafeBufferPointer { symbols.post(&psn, $0.baseAddress!) }
        }
        usleep(150_000)
    }
    static func deactivate(_ target: Target) { send(target, 0x0d, subtype: 2) }

    /// Scroll-wheel record (type 22). NXEventData scroll: deltaAxis1/2 int16 @0x88/0x8a (lines),
    /// fixedDeltaAxis1/2 16.16 @0x90/0x94, pointDeltaAxis1/2 int32 @0x9c/0xa0 (pixels). Positive dy reveals
    /// content below (the wheel moves the other way). Probed on a background Finder window: bar 0 → 1 → 0.
    static func scroll(_ target: Target, at point: CGPoint, dx: Int32, dy: Int32) {
        guard let symbols else { return }
        let steps: Int32 = 4
        for _ in 0..<steps {
            var record = [UInt8](repeating: 0, count: 0xf8)
            record[0x04] = 0xf8
            record[0x08] = 22
            record[0x3a] = 0x10
            withUnsafeBytes(of: target.windowID) { for (i, b) in $0.enumerated() { record[0x3c + i] = b } }
            withUnsafeBytes(of: Double(point.x - target.windowBounds.minX)) { for (i, b) in $0.enumerated() { record[0x20 + i] = b } }
            withUnsafeBytes(of: Double(point.y - target.windowBounds.minY)) { for (i, b) in $0.enumerated() { record[0x28 + i] = b } }
            let pixelsY = -dy / steps, pixelsX = -dx / steps
            let linesY = Int16(max(-100, min(100, pixelsY / 10))), linesX = Int16(max(-100, min(100, pixelsX / 10)))
            withUnsafeBytes(of: linesY) { for (i, b) in $0.enumerated() { record[0x88 + i] = b } }
            withUnsafeBytes(of: linesX) { for (i, b) in $0.enumerated() { record[0x8a + i] = b } }
            withUnsafeBytes(of: Int32(linesY) << 16) { for (i, b) in $0.enumerated() { record[0x90 + i] = b } }
            withUnsafeBytes(of: Int32(linesX) << 16) { for (i, b) in $0.enumerated() { record[0x94 + i] = b } }
            withUnsafeBytes(of: pixelsY) { for (i, b) in $0.enumerated() { record[0x9c + i] = b } }
            withUnsafeBytes(of: pixelsX) { for (i, b) in $0.enumerated() { record[0xa0 + i] = b } }
            var psn = target.psn
            _ = record.withUnsafeBufferPointer { symbols.post(&psn, $0.baseAddress!) }
            usleep(30_000)
        }
    }

    static func mouse(_ target: Target, _ type: MouseType, at point: CGPoint, click: Int32 = 1, eventNumber: Int16) {
        let right = type == .rightDown || type == .rightUp
        send(target, type.rawValue, at: point, click: click, button: right ? 1 : 0, eventNumber: eventNumber)
    }

    /// Record layout (0xf8 bytes): type @0x08, window-local location (Double x, y) @0x20/0x28, flags @0x3a,
    /// window id @0x3c, NXEventData @0x88 — AppKit-defined subtype @0x8a; mouse eventNum @0x8a,
    /// click state @0x8c, pressure @0x90, button @0x91.
    private static func send(_ target: Target, _ type: UInt8, at point: CGPoint? = nil, subtype: UInt8 = 0,
                             click: Int32 = 1, button: UInt8 = 0, eventNumber: Int16 = 0) {
        guard let symbols else { return }
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x08] = type
        withUnsafeBytes(of: target.windowID) { for (i, b) in $0.enumerated() { record[0x3c + i] = b } }
        if type == 0x0d {
            record[0x8a] = subtype
        } else {
            record[0x3a] = 0x10
            if let point {
                withUnsafeBytes(of: Double(point.x - target.windowBounds.minX)) { for (i, b) in $0.enumerated() { record[0x20 + i] = b } }
                withUnsafeBytes(of: Double(point.y - target.windowBounds.minY)) { for (i, b) in $0.enumerated() { record[0x28 + i] = b } }
            }
            withUnsafeBytes(of: eventNumber) { for (i, b) in $0.enumerated() { record[0x8a + i] = b } }
            withUnsafeBytes(of: click) { for (i, b) in $0.enumerated() { record[0x8c + i] = b } }
            record[0x90] = (type == 1 || type == 3 || type == 6) ? 255 : 0
            record[0x91] = button
        }
        var psn = target.psn
        _ = record.withUnsafeBufferPointer { symbols.post(&psn, $0.baseAddress!) }
    }
}
