import Foundation
import CryptoKit
import Darwin

/// OS-owned socket and bounded command transport. Never uses the user's/default/Seedmux server.
final class CLITmuxRuntime: @unchecked Sendable {
    struct Result {
        let status: Int32
        let data: Data
        var text: String { String(decoding: data, as: UTF8.self) }
    }
    struct Pane {
        let name: String
        let pid: Int32
        let dead: Bool
        let exitCode: Int32?
    }
    let executable: String
    let socket: String
    let configuration: String
    private let root: URL
    private let queue = DispatchQueue(label: "tatwo.cli.tmux", qos: .userInitiated)
    private var configured = false

    init(root: URL, executable: String) {
        self.root = root
        self.executable = executable
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        socket = "/tmp/tatwo2-cli-\(getuid())/\(digest).sock"
        configuration = root.appendingPathComponent("cli-runtime/tmux.conf").path
    }
    static func name(_ id: UUID) -> String { "os2-" + id.uuidString.lowercased() }
    var arguments: [String] { ["-S", socket, "-f", configuration] }

    private func configure() throws {
        guard !configured else { return }
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: socket).deletingLastPathComponent()
        if fm.fileExists(atPath: directory.path) {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "不安全的 CLI socket 目錄"])
            }
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let configURL = URL(fileURLWithPath: configuration)
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // No plugins, hooks, user config or external clipboard commands.
        let config = """
        set -g status off
        set -g mouse off
        set -g default-terminal "xterm-256color"
        set -g history-limit 5000
        set -g remain-on-exit on
        set -g exit-empty on
        set -g destroy-unattached off
        set -g set-clipboard off
        set -g focus-events on
        set -sg escape-time 10
        set -g allow-passthrough on
        set -g extended-keys on
        bind-key -T copy-mode C-u send-keys -X cancel \\; send-keys C-u
        bind-key -T copy-mode C-w send-keys -X cancel \\; send-keys C-w
        bind-key -T copy-mode-vi C-u send-keys -X cancel \\; send-keys C-u
        bind-key -T copy-mode-vi C-w send-keys -X cancel \\; send-keys C-w
        """
        try Data((config + "\n").utf8).write(to: configURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration)
        configured = true
    }

    func run(_ args: [String], input: Data? = nil) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try configure()
                    let process = Process(), output = Pipe(), stdin = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments + args
                    var env = ProcessInfo.processInfo.environment
                    env["TERM"] = "xterm-256color"
                    env["TMUX"] = nil
                    process.environment = env
                    process.standardOutput = output
                    process.standardError = output
                    process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
                    try process.run()
                    // Only this short-lived tmux client is eligible for timeout termination.
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
                    if let input {
                        DispatchQueue.global(qos: .utility).async {
                            try? stdin.fileHandleForWriting.write(contentsOf: input)
                            try? stdin.fileHandleForWriting.close()
                        }
                    }
                    var data = Data()
                    while let chunk = try output.fileHandleForReading.read(upToCount: 16384), !chunk.isEmpty {
                        data.append(chunk)
                        if data.count > CLISessionStore.limit { data = Data(data.suffix(CLISessionStore.limit)) }
                    }
                    process.waitUntilExit()
                    timeout.cancel()
                    try? output.fileHandleForReading.close()
                    continuation.resume(returning: Result(status: process.terminationStatus, data: data))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func create(id: UUID, launch: TatwoNativeTerminalLaunch) async throws {
        let result = try await run(["-V"])
        guard result.status == 0, result.text.trimmingCharacters(in: .whitespacesAndNewlines) == "tmux 3.6a" else {
            throw NSError(domain: "CLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "需要隨 App 打包的 tmux 3.6a"])
        }
        var args = ["new-session", "-d", "-s", Self.name(id), "-c", launch.workingDirectory.path,
                    "-x", "120", "-y", "40"]
        for key in launch.environment.keys.sorted() { args += ["-e", "\(key)=\(launch.environment[key]!)"] }
        // tmux >= 3.6 executes multiple argv directly, without a shell concatenation boundary.
        args += ["/usr/bin/env", launch.executable] + launch.arguments
        let created = try await run(args)
        guard created.status == 0 else {
            throw NSError(domain: "CLI", code: 3, userInfo: [NSLocalizedDescriptionKey: created.text])
        }
    }
    func list() async throws -> [Pane] {
        let result = try await run(["list-panes", "-a", "-F",
            "#{session_name}\t#{pane_pid}\t#{pane_dead}\t#{pane_dead_status}"])
        if result.status != 0 {
            if !FileManager.default.fileExists(atPath: socket) ||
                result.text.contains("no server running") || result.text.contains("Connection refused") { return [] }
            throw NSError(domain: "CLI", code: 4, userInfo: [NSLocalizedDescriptionKey: result.text])
        }
        return result.text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0].hasPrefix("os2-"), let pid = Int32(parts[1]) else { return nil }
            return Pane(name: parts[0], pid: pid, dead: parts[2] == "1", exitCode: Int32(parts[3]))
        }
    }
    func capture(_ id: UUID) async throws -> Data {
        let result = try await run(["capture-pane", "-p", "-J", "-t", Self.name(id), "-S", "-"])
        guard result.status == 0 else {
            throw NSError(domain: "CLI", code: 5, userInfo: [NSLocalizedDescriptionKey: result.text])
        }
        return result.data
    }
    func scrollHistory(_ id: UUID, lines: Int) async throws {
        guard lines != 0 else { return }
        let target = Self.name(id)
        let count = abs(max(-256, min(256, lines)))
        var args: [String] = []
        if lines > 0 {
            // -F evaluates a tmux format, never a shell. Only an OS-generated
            // UUID and bounded integer enter the nested tmux command strings.
            // Do not replace another mode (such as a chooser) or reset copy-mode.
            args += ["if-shell", "-F", "-t", target, "#{==:#{pane_mode},}",
                     "copy-mode -e -t \(target)", ";"]
        }
        let command = lines > 0 ? "scroll-up" : "scroll-down-and-cancel"
        args += ["if-shell", "-F", "-t", target, "#{==:#{pane_mode},copy-mode}",
                 "send-keys -X -N \(count) -t \(target) \(command)"]
        let result = try await run(args)
        guard result.status == 0 else {
            throw NSError(domain: "CLI", code: 11, userInfo: [NSLocalizedDescriptionKey: result.text])
        }
    }
    func sendLine(_ text: String, to id: UUID) async throws {
        let target = Self.name(id)
        // Literal UTF-8 via a private tmux buffer; text can never become a tmux option or shell argument.
        let buffer = "input-" + UUID().uuidString.lowercased()
        let loaded = try await run(["load-buffer", "-b", buffer, "-"], input: Data(text.utf8))
        guard loaded.status == 0 else { throw NSError(domain: "CLI", code: 6) }
        let pasted = try await run(["paste-buffer", "-d", "-b", buffer, "-t", target])
        guard pasted.status == 0 else {
            _ = try? await run(["delete-buffer", "-b", buffer])
            throw NSError(domain: "CLI", code: 7)
        }
        let entered = try await run(["send-keys", "-t", target, "Enter"])
        guard entered.status == 0 else { throw NSError(domain: "CLI", code: 8) }
    }
    func terminate(_ id: UUID) async throws {
        let result = try await run(["kill-session", "-t", Self.name(id)])
        guard result.status == 0 else { throw NSError(domain: "CLI", code: 9, userInfo: [NSLocalizedDescriptionKey: result.text]) }
    }
}
