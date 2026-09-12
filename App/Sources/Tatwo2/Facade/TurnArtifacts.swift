import Foundation
import CryptoKit
import Darwin

/// Store side-table keyed by discussion + turn, without changing ChatMessage.
/// Metadata is observation, never a lead verification or proof that this turn caused a git change.
struct TurnArtifact: Codable, Equatable, Sendable {
    var path: String
    var kind: String
    var claimed: Bool
    var exists: Bool
    var sizeBytes: Int64?
    var sha256: String?
    var verifiedBy: String? = nil
    var outside = false
    var hashState: String = "unavailable"

    private enum CodingKeys: String, CodingKey {
        case path, kind, claimed, exists, sizeBytes, sha256, verifiedBy, outside, hashState
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encode(kind, forKey: .kind)
        try values.encode(claimed, forKey: .claimed)
        try values.encode(exists, forKey: .exists)
        try values.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try values.encodeIfPresent(sha256, forKey: .sha256)
        try values.encode(verifiedBy, forKey: .verifiedBy)
        try values.encode(outside, forKey: .outside)
        try values.encode(hashState, forKey: .hashState)
    }
}

struct TurnArtifactIndex: Codable, Sendable {
    var threadID: UUID
    var turnID: String
    var messageID: String?
    var endedAt: Date
    var artifacts: [TurnArtifact]
    var truncated: Bool
}

actor TurnArtifacts {
    static let maxPaths = 200
    static let maxIndexBytes = 1024 * 1024
    static let maxHashBytes: Int64 = 64 * 1024 * 1024
    let root: URL

    init(root: URL) { self.root = root.appendingPathComponent("turn-artifacts", isDirectory: true) }

    /// Only structured write/edit tool paths count as engine claims. Do not parse shell/prose.
    static func claimedPaths(tool: String, input: [String: Any]) -> [String] {
        let name = tool.lowercased()
        guard ["write", "edit", "multiedit", "write_file", "edit_file", "apply_patch", "file_change"].contains(name) else { return [] }
        var paths = ["file_path", "path", "filename"].compactMap { input[$0] as? String }
        if let changes = input["changes"] as? [[String: Any]] {
            paths += changes.prefix(maxPaths + 1).compactMap { ($0["path"] ?? $0["filePath"] ?? $0["file_path"]) as? String }
        }
        // Native apply_patch header lines only; never interpret patch body as instructions.
        if let patch = (input["patch"] ?? input["input"]) as? String {
            for line in patch.prefix(65536).split(separator: "\n") {
                for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                    paths.append(String(line.dropFirst(prefix.count)))
                }
            }
        }
        return Array(paths.filter { !$0.isEmpty && $0.utf8.count <= 1024 }.prefix(maxPaths + 1))
    }

    /// Actor execution is off MainActor. Hashing is streaming (64 KiB reads), with a per-file
    /// 64 MiB ceiling and a per-turn 128 MiB budget. Persist before returning to consumers.
    func collect(threadID: UUID, turnID: String, messageID: String?, endedAt: Date,
                 cwd: String, claimed: [String], gitFiles: [String], truncated: Bool = false) throws -> TurnArtifactIndex {
        precondition(!Thread.isMainThread)
        let base = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var candidates: [(String, Bool)] = []
        var positions: [String: Int] = [:]
        for (paths, claim) in [(claimed, true), (gitFiles, false)] {
            for path in paths.prefix(Self.maxPaths + 1) {
                guard path.utf8.count <= 1024 else { continue }
                if let i = positions[path] { candidates[i].1 = candidates[i].1 || claim }
                else { positions[path] = candidates.count; candidates.append((path, claim)) }
            }
        }
        var budget = Int64(128 * 1024 * 1024)
        var rows: [TurnArtifact] = []
        for (path, claim) in candidates.prefix(Self.maxPaths) {
            rows.append(inspect(path, claimed: claim, base: base, budget: &budget))
        }
        // Merge aliases after normalization; an outside placeholder intentionally discloses no absolute path.
        var merged: [TurnArtifact] = []
        for row in rows {
            if let i = merged.firstIndex(where: { $0.path == row.path && $0.outside == row.outside }) {
                merged[i].claimed = merged[i].claimed || row.claimed
            } else { merged.append(row) }
        }
        let index = TurnArtifactIndex(threadID: threadID, turnID: turnID, messageID: messageID,
                                      endedAt: endedAt, artifacts: merged,
                                      truncated: truncated || candidates.count > Self.maxPaths)
        let folder = root.appendingPathComponent(threadID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        guard data.count <= Self.maxIndexBytes else { throw Failure.indexTooLarge }
        try data.write(to: file(threadID: threadID, turnID: turnID), options: .atomic)
        if let latest = try list(threadID: threadID), latest.endedAt > endedAt { return index }
        try data.write(to: folder.appendingPathComponent("latest.json"), options: .atomic)
        return index
    }

    func list(threadID: UUID, turnID: String? = nil) throws -> TurnArtifactIndex? {
        let url = turnID.map { file(threadID: threadID, turnID: $0) }
            ?? root.appendingPathComponent(threadID.uuidString).appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxIndexBytes + 1) ?? Data()
        guard data.count <= Self.maxIndexBytes else { throw Failure.indexTooLarge }
        let index = try JSONDecoder().decode(TurnArtifactIndex.self, from: data)
        guard index.threadID == threadID, index.artifacts.count <= Self.maxPaths,
              turnID == nil || index.turnID == turnID else { throw Failure.invalidIndex }
        return index
    }

    private func file(threadID: UUID, turnID: String) -> URL {
        let key = SHA256.hash(data: Data(turnID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(threadID.uuidString).appendingPathComponent(key + ".json")
    }

    private func inspect(_ path: String, claimed: Bool, base: URL, budget: inout Int64) -> TurnArtifact {
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL
            : base.appendingPathComponent(path).standardizedFileURL
        let prefix = base.path == "/" ? "/" : base.path + "/"
        guard !path.contains("\0"), candidate.path.hasPrefix(prefix) else {
            return TurnArtifact(path: "(outside)", kind: "file", claimed: claimed, exists: false, outside: true)
        }
        let relative = String(candidate.path.dropFirst(prefix.count))
        let resolved = candidate.resolvingSymlinksInPath()
        let kind = relative.hasSuffix(".log") ? "log" : (relative.hasSuffix(".md") ? "report" : "file")
        guard resolved.path.hasPrefix(prefix) else {
            return TurnArtifact(path: relative, kind: kind, claimed: claimed, exists: false, outside: true)
        }
        var row = TurnArtifact(path: relative, kind: kind, claimed: claimed, exists: false)
        // Walk with O_NOFOLLOW after resolution: a concurrently substituted symlink cannot escape.
        var fd = Darwin.open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return row }
        let components = String(resolved.path.dropFirst(prefix.count)).split(separator: "/")
        for (i, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (i < components.count - 1 ? O_DIRECTORY : 0)
            let next = openat(fd, String(component), flags)
            close(fd); fd = next
            if fd < 0 { return row }
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { return row }
        row.exists = true; row.sizeBytes = before.st_size
        guard before.st_size <= Self.maxHashBytes, before.st_size <= budget else {
            row.hashState = "size_limit"; return row
        }
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65536)
        var total: Int64 = 0
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            guard count >= 0 else { row.hashState = "read_failed"; return row }
            if count == 0 { break }
            total += Int64(count); budget -= Int64(count)
            guard total <= Self.maxHashBytes, budget >= 0 else { row.hashState = "size_limit"; return row }
            hash.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, total == before.st_size,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            row.hashState = "changed_during_read"; return row
        }
        row.sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        row.hashState = "complete"
        return row
    }

    enum Failure: Error { case indexTooLarge, invalidIndex }
}
