import Foundation
import Darwin

enum BrowserDiagnosticsAudit {
    static let aiLoginURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TATWO OS/Browser/ai-login-audit.log")

    // No password argument, arbitrary provider error, tool arguments or result object.
    static func aiLoginLine(caller: String, origin: String, username: String, decision: String) throws -> String {
        func clean(_ value: String) -> String {
            String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .map(String.init).joined().prefix(512))
        }
        let object = ["time": ISO8601DateFormatter().string(from: Date()), "event": "ai_login",
            "caller": clean(caller), "origin": BrowserDiagnosticsPrivacy.host(origin),
            "username": clean(username), "decision": clean(decision)]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func appendAILogin(caller: String, origin: String, username: String, decision: String,
                             to url: URL = aiLoginURL) throws {
        let line = try aiLoginLine(caller: caller, origin: origin, username: username, decision: decision)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try Data((line + "\n").utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }

    struct Snapshot: Sendable {
        var lines: [String] = []
        var status = "尚無審計"
        var lastCalledAt: Date? = nil
    }

    /// Fixed-size tail, no whole-file loading or raw-line fallback on malformed input.
    static func readTail(at url: URL) -> Snapshot {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            return Snapshot(status: errno == ENOENT ? "尚無審計" : "審計無法讀取")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            return Snapshot(status: "審計無法讀取")
        }
        let offset = max(0, info.st_size - 262_144)
        guard lseek(fd, offset, SEEK_SET) >= 0 else { return Snapshot(status: "審計無法讀取") }
        var buffer = [UInt8](repeating: 0, count: 262_144)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { return Snapshot(status: "審計無法讀取") }
        var lines = String(decoding: buffer.prefix(count), as: UTF8.self).components(separatedBy: "\n")
        if offset > 0, !lines.isEmpty { lines.removeFirst() } // May begin mid-record.
        if lines.last == "" { lines.removeLast() }
        else if !lines.isEmpty { lines.removeLast() } // Writer has not completed the last record.
        let recent = lines.suffix(50)
        var lastCalledAt: Date?
        let safe = recent.compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let date = object["time"] as? String,
                  let parsed = ISO8601DateFormatter().date(from: date) else { return nil }
            if object["event"] as? String == "ai_login" || object["tool"] as? String != nil {
                lastCalledAt = max(lastCalledAt ?? parsed, parsed)
            }
            func field(_ key: String) -> String { BrowserDiagnosticsPrivacy.text(object[key] as? String ?? "—") }
            let host = BrowserDiagnosticsPrivacy.host(object["origin"] as? String)
            if object["event"] as? String == "ai_login" {
                return "\(parsed.formatted(.iso8601)) | ai_login caller=\(field("caller")) origin=\(host) username=\(field("username")) decision=\(field("decision"))"
            }
            // Whitelisted fields only: no arguments, results, description, paths or arbitrary JSON.
            return "\(parsed.formatted(.iso8601)) | \(host) | \(field("caller")) | \(field("tool")) | \(field("decision")) | \(field("outcome")) | \(field("error"))"
        }
        return Snapshot(lines: safe, status: safe.count == recent.count ? "最近 \(safe.count) 條" : "最近 \(safe.count) 條；已略過無效紀錄",
                        lastCalledAt: lastCalledAt)
    }
}
