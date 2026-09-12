import AppKit

/// One AppKit modal (open/save panel, alert) at a time. Queued or repeated
/// triggers (double-clicks, accessibility-driven clicks) used to nest
/// `runModal()` and pile up dozens of stacked panels over the window — the
/// "破圖" cascade seen in 2026-09-02 photos. A request made while a modal is
/// already up is dropped and returns nil.
enum TatwoModalPanelGate {
    nonisolated(unsafe) private(set) static var isPresenting = false

    @discardableResult
    static func run(_ body: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse? {
        guard !isPresenting else { return nil }
        isPresenting = true
        defer { isPresenting = false }
        return body()
    }
}
