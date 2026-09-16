import Foundation
import Darwin

enum PluginLiveness: String, Codable, Sendable, CaseIterable {
    case ready, probing, unreachable, disabled, unknown

    var pillText: String {
        switch self {
        case .ready: "已接"
        case .probing: "探測中"
        case .unreachable: "連不上"
        case .disabled: "已停用"
        case .unknown: "未探測"
        }
    }

    var pillColor: String {
        switch self {
        case .ready: "green"
        case .probing: "yellow"
        case .unreachable: "red"
        case .disabled, .unknown: "gray"
        }
    }
}

struct PluginLivenessResult: Codable, Equatable, Sendable {
    var state: PluginLiveness
    var detail: String? = nil
    var probedAt: Date? = nil
}

/// Memory only. Disk registry snapshots never assert that a previous process is still connected.
final class PluginLivenessCache: @unchecked Sendable {
    static let ttl: TimeInterval = 60
    private let lock = NSLock()
    private var values: [String: (Date, [String: PluginLivenessResult])] = [:]

    func value(for key: String, now: Date = Date()) -> [String: PluginLivenessResult]? {
        lock.lock(); defer { lock.unlock() }
        guard let (date, result) = values[key],
              now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < Self.ttl else { return nil }
        return result
    }

    func resolve(key: String, force: Bool, now: Date = Date(),
                 probe: () -> [String: PluginLivenessResult]) -> [String: PluginLivenessResult] {
        if !force, let cached = value(for: key, now: now) { return cached }
        let result = probe()
        lock.lock()
        // Bound contexts across config changes; never persist commands, env or tokens.
        if values.count >= 32 { values.removeAll() }
        values[key] = (now, result)
        lock.unlock()
        return result
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
    }
}

enum PluginProbe {
    static let timeout: TimeInterval = 8

    /// Do not run arbitrary configured commands for a lightweight check.
    /// A present binary is NOT a completed MCP handshake.
    static func executableCheck(command: String?, args: [String], path: String,
                                cwd: URL, enabled: Bool = true, now: Date = Date()) -> PluginLivenessResult {
        guard enabled else { return .init(state: .disabled, probedAt: now) }
        guard let command, !command.isEmpty else {
            return .init(state: .unknown, detail: "輕量檢查：未驗證連線（非 command 來源）", probedAt: now)
        }
        let manager = FileManager.default
        let candidates: [URL]
        if command.contains("/") {
            candidates = [URL(fileURLWithPath: command, relativeTo: cwd).standardizedFileURL]
        } else {
            candidates = path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), relativeTo: cwd).appendingPathComponent(command)
            }
        }
        guard candidates.contains(where: {
            var directory: ObjCBool = false
            return manager.fileExists(atPath: $0.path, isDirectory: &directory)
                && !directory.boolValue && manager.isExecutableFile(atPath: $0.path)
        }) else { return .init(state: .unreachable, detail: "執行檔不在 PATH", probedAt: now) }
        // Arguments are parsed but never evaluated as shell input.
        _ = args
        return .init(state: .unknown, detail: "輕量檢查：執行檔可用，未驗證連線", probedAt: now)
    }

    static func reported(_ status: String?, now: Date = Date()) -> PluginLivenessResult {
        switch status {
        case "connected": .init(state: .ready, detail: "SDK 完整連線探測", probedAt: now)
        case "pending": .init(state: .probing, probedAt: now)
        case "disabled": .init(state: .disabled, probedAt: now)
        case "needs-auth": .init(state: .unreachable, detail: "需要登入", probedAt: now)
        case "failed": .init(state: .unreachable, detail: "MCP 連線失敗", probedAt: now)
        default: .init(state: .unknown, detail: "sidecar 未回報連線狀態", probedAt: now)
        }
    }

    struct Reply {
        var servers: [[String: Any]] = []
        var failure: String? = nil
    }

    static func result(named name: String, in reply: Reply) -> PluginLivenessResult {
        let server = reply.servers.first { $0["name"] as? String == name }
        let status = server?["status"] as? String
        if let failure = reply.failure,
           !(failure == "探測逾時" && status != nil && status != "pending") {
            return .init(state: .unreachable, detail: failure, probedAt: Date())
        }
        var result = reported(status)
        if status == "failed" {
            // Classify known causes, never put raw provider stderr/credentials into a card/cache.
            let error = ((server?["error"] as? String) ?? "").lowercased()
            if error.contains("enoent") { result.detail = "執行檔不在 PATH" }
            else if error.contains("timeout") || error.contains("timed out") { result.detail = "啟動逾時" }
            else if error.contains("exit code") || error.contains("non-zero") { result.detail = "回 non-zero" }
        }
        return result
    }

    /// Dedicated, owned status process only; never attach to or terminate an active chat sidecar.
    static func sidecar(_ process: Process, timeout: TimeInterval = timeout) -> Reply {
        let input = Pipe(), output = Pipe()
        let signal = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var buffer = Data()
        var reply: Reply?
        var latestServers: [[String: Any]] = []
        var ownedGroup: pid_t?
        process.standardInput = input
        process.standardOutput = output
        // Do not capture or persist arbitrary provider errors/secrets; also cannot fill a stderr pipe.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in signal.signal() }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            guard reply == nil else { return }
            guard buffer.count + data.count <= 1_048_576 else {
                reply = Reply(failure: "探測回報過大"); signal.signal(); return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["ev"] as? String == "mcp_status",
                      let servers = object["servers"] as? [[String: Any]] else { continue }
                latestServers = servers
                // Pending is not terminal; the caller polls for a fresh SDK snapshot.
                guard !servers.contains(where: { $0["status"] as? String == "pending" }) else { continue }
                reply = Reply(servers: servers)
                signal.signal()
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data("{\"op\":\"close\"}\n".utf8))
            }
            try? input.fileHandleForWriting.close()
            // NSTask creates a process group on macOS; ownership is verified below,
            // never inferred from a configured server PID or another chat's receipt.
            if let group = ownedGroup {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                    guard kill(-group, 0) == 0 else { return }
                    _ = killpg(group, SIGTERM)
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                        if kill(-group, 0) == 0 { _ = killpg(group, SIGKILL) }
                    }
                }
            } else if process.isRunning {
                process.terminate()
            }
        }
        do {
            try process.run()
            let pid = process.processIdentifier
            guard pid > 1, getpgid(pid) == pid, pid != getpgrp() else {
                return Reply(failure: "探測程序未隔離")
            }
            ownedGroup = pid
            try input.fileHandleForWriting.write(contentsOf: Data("{\"op\":\"mcp_status\"}\n".utf8))
        } catch { return Reply(failure: "探測程序啟動失敗") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            _ = signal.wait(timeout: .now() + min(0.25, max(0, remaining)))
            lock.lock(); let result = reply; lock.unlock()
            if let result { return result }
            if !process.isRunning { break }
            if ProcessInfo.processInfo.systemUptime < deadline {
                try? input.fileHandleForWriting.write(contentsOf: Data("{\"op\":\"mcp_status\"}\n".utf8))
            }
        }
        lock.lock(); let latest = latestServers; lock.unlock()
        if process.isRunning { return Reply(servers: latest, failure: "探測逾時") }
        return Reply(failure: process.terminationStatus == 0 ? "未回報連線狀態" : "回 non-zero")
    }

    /// The shipped servers declare tools as tuples in `const tools = [ ... ].map`.
    /// Parse only that declaration, not examples, switch cases or parameter names.
    static func toolNames(in source: String) -> [String] {
        guard let start = source.range(of: "const tools = ["),
              let end = source.range(of: "].map(", range: start.upperBound..<source.endIndex) else { return [] }
        let declaration = String(source[start.upperBound..<end.lowerBound])
        let regex = try! NSRegularExpression(pattern: #"(?m)^\s*\[['"]([A-Za-z0-9_]+)['"]\s*,"#)
        return regex.matches(in: declaration, range: NSRange(declaration.startIndex..., in: declaration)).compactMap {
            Range($0.range(at: 1), in: declaration).map { String(declaration[$0]) }
        }
    }
}
