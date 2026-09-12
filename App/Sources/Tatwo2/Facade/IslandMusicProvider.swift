import AppKit
import Combine
import Foundation

protocol IslandScriptExecuting: AnyObject, Sendable {
    func run(_ script: String) async throws -> String
    func cancel()
}
final class IslandOSAScriptExecutor: IslandScriptExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "tatwo2.island.music", qos: .utility)
    private let lock = NSLock()
    private var process: Process?
    private var generation = 0
    func cancel() {
        lock.lock(); generation += 1
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        lock.unlock()
    }
    private func currentGeneration() -> Int { lock.lock(); defer { lock.unlock() }; return generation }
    func run(_ script: String) async throws -> String {
        let stamp = currentGeneration()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let p = Process(), pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                do {
                    self.lock.lock()
                    guard stamp == self.generation else { self.lock.unlock(); throw CancellationError() }
                    self.process = p; self.lock.unlock()
                    try p.run() // No process launch or wait while holding the cancellation lock.
                    if stamp != self.currentGeneration(), p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    let deadline = ProcessInfo.processInfo.systemUptime + 3
                    while p.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    p.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    self.lock.lock(); self.process = nil; self.lock.unlock()
                    guard p.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
                    continuation.resume(returning: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
struct IslandNowPlaying: Equatable {
    var app: String; var title: String; var artist: String; var isPlaying: Bool
    var position: Double; var duration: Double; var artworkPNG: Data? = nil
}
@MainActor final class IslandMusicProvider: ObservableObject, IslandSpaceProvider {
    enum Player: String, CaseIterable { case music = "com.apple.Music", spotify = "com.spotify.client"
        var title: String { self == .music ? "Music" : "Spotify" }
    }
    @Published private(set) var nowPlaying: IslandNowPlaying?
    @Published private(set) var available: [Player] = []
    @Published private(set) var message = "沒有在播"
    private let executor: any IslandScriptExecuting
    private var polling: Task<Void, Never>?
    private var command: Task<Void, Never>?
    private var generation = 0
    private var selected: Player = .music
    private let installed: @Sendable () -> [Player]
    init(executor: any IslandScriptExecuting = IslandOSAScriptExecutor(), installed: @escaping @Sendable () -> [Player] = {
        Player.allCases.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil }
    }) { self.executor = executor; self.installed = installed }
    var snapshot: IslandSpaceSnapshot { .init(lines: [nowPlaying?.title ?? message, nowPlaying?.artist ?? ""]) }
    static func script(_ app: Player, action: String? = nil) -> String {
        let actionBody = action ?? """
        if player state is stopped then return "NONE"
        set t to current track
        set n to name of t as text
        set a to artist of t as text
        if length of n > 500 then set n to text 1 thru 500 of n
        if length of a > 500 then set a to text 1 thru 500 of a
        return n & ASCII character 31 & a & ASCII character 31 & ((player state is playing) as text) & ASCII character 31 & (player position as text) & ASCII character 31 & (duration of t as text)
        """
        return """
        if application id "\(app.rawValue)" is not running then return "NONE"
        tell application id "\(app.rawValue)"
        \(actionBody)
        end tell
        """
    }
    static func parse(_ text: String, app: Player) -> IslandNowPlaying? {
        let fields = text.components(separatedBy: "\u{1f}")
        guard fields.count == 5, let position = Double(fields[3]), let duration = Double(fields[4]) else { return nil }
        return .init(app: app.title, title: fields[0], artist: fields[1], isPlaying: fields[2] == "true",
                     position: position, duration: duration / (app == .spotify ? 1000 : 1))
    }
    func activate() {
        guard polling == nil else { return }
        generation += 1; let stamp = generation
        polling = Task { [weak self, installed] in
            let apps = await Task.detached(priority: .utility) { installed() }.value
            guard let self, !Task.isCancelled, stamp == self.generation else { return }
            self.available = apps
            while !Task.isCancelled {
                self.message = "沒有在播"
                var candidate: IslandNowPlaying?
                var player = self.selected
                for app in apps {
                    do {
                        let text = try await self.executor.run(Self.script(app))
                        guard !Task.isCancelled, stamp == self.generation else { return }
                        if let parsed = Self.parse(text, app: app), candidate == nil || parsed.isPlaying {
                            candidate = parsed; player = app
                        }
                    } catch {
                        guard !Task.isCancelled, stamp == self.generation else { return }
                        self.message = "音樂自動化未授權或逾時"
                    }
                }
                self.nowPlaying = candidate; self.selected = player
                if candidate == nil && self.message != "音樂自動化未授權或逾時" { self.message = "沒有在播" }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    private func control(_ action: String) {
        guard polling != nil, nowPlaying != nil, command == nil else { return }
        command = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            _ = try? await self.executor.run(Self.script(self.selected, action: action))
            self.command = nil
        }
    }
    func playPause() { control("playpause") }
    func next() { control("next track") }
    func prev() { control("previous track") }
    func suspend() { generation += 1; polling?.cancel(); polling = nil; command?.cancel(); command = nil; executor.cancel() }
    func unload() { suspend(); nowPlaying = nil }
    deinit { polling?.cancel(); command?.cancel(); executor.cancel() }
}
