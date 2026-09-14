import AppKit
import Combine

/// One queue owns presentation, deadlines and the Island's open lease.
@MainActor
final class IslandNotice: ObservableObject {
    static let shared = IslandNotice()

    enum Decision: Equatable, Sendable { case allow, cancel, timeout }
    enum Kind: Equatable, Sendable { case ask, confirm, info }
    struct Request: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: Kind
        let title: String
        let detail: String
        let allowLabel: String
        let cancelLabel: String
        var deadline: Date
    }
    /// Returns a dismissal action; injected fixtures never create AppKit windows.
    typealias Fallback = @MainActor (Request, NSWindow?, @escaping (Decision) -> Void) -> (() -> Void)?

    @Published private(set) var current: Request?
    var hostAvailable = false {
        didSet {
            guard !hostAvailable, current != nil, let active else { return }
            current = nil
            presentFallback(active)
        }
    }
    private let fallback: Fallback
    private let holdOpen: (Bool) -> Void
    private let log: (String) -> Void
    private var queue: [Entry] = []
    private var active: Entry?
    private var blocking = false

    private final class Entry {
        var request: Request
        let duration: TimeInterval
        weak var window: NSWindow?
        let completion: (Decision) -> Void
        var timer: Timer?
        var dismiss: (() -> Void)?
        init(_ request: Request, window: NSWindow?, completion: @escaping (Decision) -> Void) {
            self.request = request
            self.duration = max(0, request.deadline.timeIntervalSinceNow)
            self.window = window
            self.completion = completion
        }
    }

    init(fallback: @escaping Fallback = IslandNotice.alertFallback,
         holdOpen: ((Bool) -> Void)? = nil,
         log: @escaping (String) -> Void = { NSLog("IslandNotice: %@", $0) }) {
        self.fallback = fallback
        // Default resolved inside the @MainActor init: a default-argument closure is
        // nonisolated and cannot touch the main-actor Island shell.
        self.holdOpen = holdOpen ?? { IslandExceptionsNavigation.shell?.holdOpen($0) }
        self.log = log
    }

    func ask(title: String, detail: String, allowLabel: String, timeout: TimeInterval,
             requestID: UUID = UUID()) async -> Decision {
        await wait(makeRequest(id: requestID, kind: .ask, title: title, detail: detail,
                               allow: allowLabel, cancel: "取消", timeout: timeout))
    }

    func confirm(title: String, detail: String, confirmLabel: String = "確認",
                 cancelLabel: String = "取消", timeout: TimeInterval = 20) async -> Bool {
        await wait(makeRequest(kind: .confirm, title: title, detail: detail,
                               allow: confirmLabel, cancel: cancelLabel, timeout: timeout)) == .allow
    }

    func info(title: String, detail: String, duration: TimeInterval = 7) {
        guard hostAvailable else { log("info skipped: Island host unavailable"); return }
        enqueue(makeRequest(kind: .info, title: title, detail: detail,
                            allow: "", cancel: "", timeout: duration), completion: { _ in })
    }

    /// Use the same callback-backed async operation, not a main-actor Task: a nested
    /// run loop cannot reliably drain Swift's main-executor jobs while its caller waits.
    func confirmBlocking(title: String, detail: String, confirmLabel: String = "確認",
                         cancelLabel: String = "取消", timeout: TimeInterval = 20,
                         window: NSWindow? = nil) -> Bool {
        guard !blocking else { return false } // nested close/Esc must never approve another action
        blocking = true
        defer { blocking = false }
        let request = makeRequest(kind: .confirm, title: title, detail: detail,
                                  allow: confirmLabel, cancel: cancelLabel, timeout: min(timeout, 20))
        var result: Decision?
        enqueue(request, window: window) { result = $0 }
        while result == nil, request.deadline > Date() {
            autoreleasepool {
                // AppKit's outer run() is suspended here. Dispatch native events as well
                // as timers so the Island buttons and fallback sheet remain clickable.
                if let app = NSApp,
                   let event = app.nextEvent(matching: .any, until: .distantPast,
                                             inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                RunLoop.main.run(until: min(request.deadline, Date().addingTimeInterval(0.01)))
            }
        }
        if result == nil { resolve(.timeout, id: request.id) }
        return result == .allow
    }

    func resolve(_ decision: Decision, id: UUID) {
        if let entry = active, entry.request.id == id {
            // A late click (or stale sheet callback) must not approve an expired request.
            let outcome: Decision = entry.request.deadline <= Date() ? .timeout : decision
            entry.timer?.invalidate()
            active = nil
            current = nil
            entry.dismiss?()
            entry.completion(outcome)
            presentNext()
        } else if decision != .allow, let index = queue.firstIndex(where: { $0.request.id == id }) {
            let entry = queue.remove(at: index)
            entry.timer?.invalidate()
            entry.completion(decision)
        }
    }

    private func makeRequest(id: UUID = UUID(), kind: Kind, title: String, detail: String,
                             allow: String, cancel: String, timeout: TimeInterval) -> Request {
        Request(id: id, kind: kind, title: title, detail: detail, allowLabel: allow,
                cancelLabel: cancel, deadline: Date().addingTimeInterval(timeout.isFinite ? max(0, timeout) : 20))
    }

    private func wait(_ request: Request) async -> Decision {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .cancel }
            return await withCheckedContinuation { continuation in
                enqueue(request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.cancel, id: request.id) }
        }
    }

    private func enqueue(_ request: Request, window: NSWindow? = nil,
                         completion: @escaping (Decision) -> Void) {
        let entry = Entry(request, window: window, completion: completion)
        queue.append(entry)
        if request.kind != .info { scheduleTimeout(entry) }
        presentNext()
    }

    private func scheduleTimeout(_ entry: Entry) {
        let request = entry.request
        let timer = Timer(fire: request.deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolve(.timeout, id: request.id) }
        }
        entry.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func presentNext() {
        guard active == nil else { return }
        guard !queue.isEmpty else { holdOpen(false); return }
        let entry = queue.removeFirst()
        active = entry
        // info.duration is reading time, not a request deadline: do not silently
        // discard a heads-up while it waits behind an interactive confirmation.
        if entry.request.kind == .info {
            entry.request.deadline = Date().addingTimeInterval(entry.duration)
            scheduleTimeout(entry)
        }
        let request = entry.request
        guard request.deadline > Date() else { resolve(.timeout, id: request.id); return }
        if hostAvailable {
            current = request
            holdOpen(true)
        } else {
            presentFallback(entry)
        }
    }

    private func presentFallback(_ entry: Entry) {
        holdOpen(false)
        let request = entry.request
        if request.kind == .info {
            log("info skipped: Island host unavailable")
            resolve(.cancel, id: request.id)
            return
        }
        let dismiss = fallback(request, entry.window) { [weak self] decision in
            self?.resolve(decision, id: request.id)
        }
        // An injected fallback may complete synchronously.
        if active === entry { entry.dismiss = dismiss } else { dismiss?() }
    }

    static func alertFallback(_ request: Request, window: NSWindow?,
                              completion: @escaping (Decision) -> Void) -> (() -> Void)? {
        guard let app = NSApp else { completion(.cancel); return nil }
        let parent = window.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? app.keyWindow.flatMap { $0.canBecomeMain ? $0 : nil }
            ?? app.mainWindow
            ?? app.windows.filter { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let parent, parent.attachedSheet == nil else {
            NSLog("IslandNotice: no available sheet host; cancelled")
            completion(.cancel)
            return nil
        }
        parent.orderFront(nil)
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.detail
        alert.addButton(withTitle: request.allowLabel)
        alert.addButton(withTitle: request.cancelLabel)
        alert.beginSheetModal(for: parent) { response in
            completion(response == .alertFirstButtonReturn ? .allow : .cancel)
        }
        return {
            if alert.window.sheetParent != nil { parent.endSheet(alert.window, returnCode: .abort) }
        }
    }
}
