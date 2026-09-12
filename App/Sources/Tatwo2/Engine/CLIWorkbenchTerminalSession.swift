import Foundation

/// One durable tmux session, optionally attached to one App-owned PTY/display.
/// Display teardown/resize never owns the lifetime of the command.
@MainActor
final class CLIWorkbenchTerminalSession {
    let id: UUID
    let runtime: CLITmuxRuntime
    let store: CLISessionStore
    var onChange: (() -> Void)?
    var onFocus: (() -> Void)?
    private(set) var status: CLISessionStatus = .unknown
    private(set) var pid: Int32?
    private(set) var exitCode: Int32?
    private(set) var error: String?
    private(set) var isRunning = false
    private(set) var isStarting = false
    private var startup: Task<Void, Never>?
    private var client: TatwoNativePTYTerminalSession?
    private var lastOutputAt = Date.distantPast
    private var promptProbe = ""
    private var wantsAttachment = false
    private var lastSize = (columns: 120, rows: 40)
    private var pendingScrollLines = 0
    private var scrolling: Task<Void, Never>?
    // Owned here, not a process-global NSView cache. Historical sessions create this lazily.
    var display: NativeTerminalPTYNSView?
    var editingOptions = CLIWorkbenchEditingOptions() {
        didSet { display?.editingOptions = editingOptions }
    }

    init(id: UUID, runtime: CLITmuxRuntime, store: CLISessionStore) {
        self.id = id; self.runtime = runtime; self.store = store
        status = store.sessions.first { $0.id == id }?.status ?? .unknown
        exitCode = store.sessions.first { $0.id == id }?.exitCode
    }
    func start(launch: TatwoNativeTerminalLaunch) {
        guard startup == nil, !isRunning else { return }
        isStarting = true
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.create(id: id, launch: launch)
                let pane = try await runtime.list().first { $0.name == CLITmuxRuntime.name(id) }
                isStarting = false
                reconcile(pane)
                if wantsAttachment { attach() }
            } catch {
                isStarting = false
                self.error = error.localizedDescription
                setStatus(.exited, code: nil)
                onChange?()
            }
        }
    }
    func waitUntilReady() async { await startup?.value }
    func reconcile(_ pane: CLITmuxRuntime.Pane?) {
        // A failed list never reaches here; only a successful absent/dead result can mark exited.
        guard let pane, !pane.dead else {
            isRunning = false
            pid = nil
            if status != .exited {
                setStatus(.exited, code: pane?.exitCode)
                Task { [weak self] in _ = try? await self?.capture() }
            }
            return
        }
        let changed = pid != pane.pid || !isRunning
        pid = pane.pid; isRunning = true
        if status == .exited || (status == .running && Date().timeIntervalSince(lastOutputAt) > 1.5) {
            setStatus(.unknown, code: nil)
        }
        if changed { onChange?() }
        if wantsAttachment && client == nil { attach() }
    }
    private func setStatus(_ value: CLISessionStatus, code: Int32?) {
        guard status != value || exitCode != code else { return }
        status = value; exitCode = code
        store.update(id) { $0.status = value; $0.exitCode = code; $0.lastActiveAt = Date() }
        onChange?()
    }
    func attach() {
        wantsAttachment = true
        guard isRunning, client == nil else { return }
        let launch = TatwoNativeTerminalLaunch(executable: runtime.executable,
            arguments: runtime.arguments + ["attach-session", "-t", CLITmuxRuntime.name(id)],
            workingDirectory: store.root, environment: ["TERM": "xterm-256color", "TMUX": ""])
        let transport = TatwoNativePTYTerminalSession(launch: launch,
            columns: lastSize.columns, rows: lastSize.rows, transportOnly: true,
            onData: { [weak self] data in
                Task { @MainActor [weak self] in self?.receive(data) }
            }, onUpdate: { _ in }, onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    if case .failed(let message) = status { self?.error = message; self?.onChange?() }
                }
            })
        client = transport
        transport.start()
    }
    private func receive(_ data: Data) {
        display?.feed(data)
        guard isRunning else { return }
        lastOutputAt = Date()
        // OSC 133 prompt boundary is affirmative evidence. Quiet output alone is NOT waiting/success.
        promptProbe = String((promptProbe + String(decoding: data, as: UTF8.self)).suffix(256))
        let prompt = promptProbe.contains("\u{1b}]133;B\u{7}") || promptProbe.contains("\u{1b}]133;B\u{1b}\\")
        setStatus(prompt ? .waitingInput : .running, code: nil)
        if prompt { promptProbe = "" }
    }
    func detach() {
        wantsAttachment = false
        pendingScrollLines = 0
        scrolling?.cancel()
        client?.terminate() // Only the tmux attach client; the server's session is independent.
        client = nil
    }
    func scrollHistory(lines: Int) {
        guard isRunning, client != nil, lines != 0 else { return }
        pendingScrollLines = max(-5000, min(5000, pendingScrollLines + max(-256, min(256, lines))))
        guard scrolling == nil else { return }
        scrolling = Task { [weak self] in
            guard let self else { return }
            defer { scrolling = nil; pendingScrollLines = 0 }
            while !Task.isCancelled, isRunning, client != nil, pendingScrollLines != 0 {
                // Coalesce wheel/trackpad bursts; at most one bounded tmux request
                // in flight. Lifecycle detachment drops any remaining movement.
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { return }
                guard !Task.isCancelled, isRunning, client != nil else { return }
                let lines = max(-256, min(256, pendingScrollLines))
                pendingScrollLines -= lines
                do { try await runtime.scrollHistory(id, lines: lines) }
                catch {
                    self.error = error.localizedDescription
                    onChange?()
                    return
                }
            }
        }
    }
    func send(_ data: Data) {
        guard isRunning else { return }
        promptProbe = ""
        setStatus(.unknown, code: nil)
        client?.send(data)
    }
    func send(bytes: [UInt8]) { send(Data(bytes)) }
    func sendLine(_ text: String) {
        Task { [weak self] in
            do { try await self?.sendLineAwaited(text) }
            catch { self?.error = error.localizedDescription; self?.onChange?() }
        }
    }
    func sendLineAwaited(_ text: String) async throws {
        await waitUntilReady()
        reconcile(try await runtime.list().first { $0.name == CLITmuxRuntime.name(id) })
        guard isRunning else { throw NSError(domain: "CLI", code: 10, userInfo: [NSLocalizedDescriptionKey: "程序已結束或尚未接回"]) }
        try await runtime.sendLine(text, to: id)
    }
    @discardableResult func resize(columns: Int, rows: Int) -> Bool {
        lastSize = (columns, rows)
        return client?.resize(columns: columns, rows: rows) ?? false
    }
    func capture() async throws -> String {
        let data = try await runtime.capture(id)
        store.snapshot(data, for: id)
        return String(decoding: data, as: UTF8.self)
    }
    func terminate() {
        Task { [weak self] in try? await self?.terminateAwaited() }
    }
    func terminateAwaited() async throws {
        await waitUntilReady()
        _ = try? await capture()
        try await runtime.terminate(id)
        detach()
        isRunning = false; pid = nil
        setStatus(.exited, code: nil)
    }
}
