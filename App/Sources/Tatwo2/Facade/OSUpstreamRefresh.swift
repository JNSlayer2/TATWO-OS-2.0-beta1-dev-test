import Foundation
import CryptoKit
import Darwin

enum OSUpstreamRefresh {
    struct PendingUpdate: Equatable, Identifiable {
        let runtimeHash: String
        let bundledHash: String
        let runtimeText: String
        let bundledText: String
        // A decision applies to this pair, not just to a release/version label.
        var id: String { runtimeHash + "\n" + bundledHash }
    }

    enum ReviewError: Error { case contentChanged, invalidUTF8 }

    enum Outcome: Equatable {
        case installed, updated(backup: String), keptUserEdited, unchanged, failed(String)

        var logMessage: String {
            switch self {
            case .installed: return "installed"
            case .updated: return "updated"
            case .keptUserEdited: return "keptUserEdited"
            case .unchanged: return "unchanged"
            case .failed(let reason): return "failed \(reason)"
            }
        }
    }

    static var bundledURL: URL? {
        TatwoResources.url(forResource: "os-upstream", withExtension: "md")
    }

    static func applyOnLaunch(
        runtimePath: String = OSUpstream.overridePath,
        bundled: URL? = OSUpstreamRefresh.bundledURL,
        now: Date = Date()
    ) -> Outcome {
        guard let bundled else { return .failed("bundle_missing") }
        let fm = FileManager.default
        let runtime = URL(fileURLWithPath: runtimePath)
        let directory = runtime.deletingLastPathComponent()
        let marker = directory.appendingPathComponent("os-upstream.installed.sha256")
        do {
            let content = try Data(contentsOf: bundled)
            let digest = sha256(content)
            if !fm.fileExists(atPath: runtime.path) {
                guard (try? fm.destinationOfSymbolicLink(atPath: runtime.path)) == nil else {
                    return .failed("runtime_symlink_unreadable")
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try writeManaged(content, digest: digest, runtime: runtime, marker: marker)
                try clearNotice(in: directory)
                return .installed
            }
            let current = sha256(try Data(contentsOf: runtime))
            let markerText = fm.fileExists(atPath: marker.path)
                ? try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            // Equality is not consent to adopt an unmarked/custom file.
            if current == digest {
                try clearNotice(in: directory)
                return .unchanged
            }
            if keptChoice(in: directory) == current + "\n" + digest {
                try clearNotice(in: directory)
                return .keptUserEdited
            }
            // Only one exact last-installed hash grants automatic replacement.
            // Missing/empty/malformed/legacy multi-hash markers all fail closed.
            guard markerText == current else {
                try Data("App 內建 OS 上游宣告內容不同；已保留自訂檔案，請到設定 › OS 檢視差異。\n".utf8)
                    .write(to: noticeURL(in: directory), options: .atomic)
                return .keptUserEdited
            }
            return try replace(content, current: current, runtime: runtime, now: now)
        } catch {
            let error = error as NSError
            return .failed("\(error.domain):\(error.code)")
        }
    }

    /// Read the actual files, not the notice's existence (old notices may be stale).
    static func pendingUpdate(
        runtimePath: String = OSUpstream.overridePath,
        bundled: URL? = OSUpstreamRefresh.bundledURL
    ) throws -> PendingUpdate? {
        guard let bundled else { throw CocoaError(.fileNoSuchFile) }
        let runtime = URL(fileURLWithPath: runtimePath)
        let pending = try difference(runtime: runtime, bundled: bundled)
        guard let pending,
              keptChoice(in: runtime.deletingLastPathComponent()) != pending.id else { return nil }
        return pending
    }

    /// The user approved precisely the contents displayed by the diff.
    /// Re-read both files; an old sheet must not overwrite a newer external edit.
    static func applyBundledVersion(
        _ reviewed: PendingUpdate,
        runtimePath: String = OSUpstream.overridePath,
        bundled: URL? = OSUpstreamRefresh.bundledURL,
        now: Date = Date()
    ) throws -> Outcome {
        let runtime = URL(fileURLWithPath: runtimePath)
        try validate(reviewed, runtime: runtime, bundled: bundled)
        guard let bundled else { throw ReviewError.contentChanged }
        let content = try Data(contentsOf: bundled)
        guard sha256(content) == reviewed.bundledHash else { throw ReviewError.contentChanged }
        return try replace(content, current: reviewed.runtimeHash, runtime: runtime, now: now)
    }

    static func keepCustomVersion(
        _ reviewed: PendingUpdate,
        runtimePath: String = OSUpstream.overridePath,
        bundled: URL? = OSUpstreamRefresh.bundledURL
    ) throws {
        let runtime = URL(fileURLWithPath: runtimePath)
        try validate(reviewed, runtime: runtime, bundled: bundled)
        let directory = runtime.deletingLastPathComponent()
        try Data((reviewed.id + "\n").utf8).write(to: choiceURL(in: directory), options: .atomic)
        try clearNotice(in: directory)
        // Do not update the installed marker: this remains the user's custom file.
    }

    private static func difference(runtime: URL, bundled: URL) throws -> PendingUpdate? {
        let current = try Data(contentsOf: runtime), content = try Data(contentsOf: bundled)
        guard current != content else { return nil }
        guard let runtimeText = String(data: current, encoding: .utf8),
              let bundledText = String(data: content, encoding: .utf8) else { throw ReviewError.invalidUTF8 }
        return PendingUpdate(runtimeHash: sha256(current), bundledHash: sha256(content),
                             runtimeText: runtimeText, bundledText: bundledText)
    }

    private static func validate(_ reviewed: PendingUpdate, runtime: URL, bundled: URL?) throws {
        guard let bundled, try difference(runtime: runtime, bundled: bundled) == reviewed else {
            throw ReviewError.contentChanged
        }
    }

    private static func replace(_ content: Data, current: String, runtime: URL, now: Date) throws -> Outcome {
        let directory = runtime.deletingLastPathComponent()
        let marker = directory.appendingPathComponent("os-upstream.installed.sha256")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        let backup = directory.appendingPathComponent("os-upstream.md.bak-\(formatter.string(from: now))")
        let preimage = try Data(contentsOf: runtime)
        guard sha256(preimage) == current else { throw ReviewError.contentChanged }
        // Save private bytes, not a symlink to a mutable source. Exclusive 0600
        // creation preserves older backups and never broadens a custom file's
        // read access (Data.write alone would create a default 0644 backup).
        let descriptor = Darwin.open(backup.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: preimage)
        try handle.synchronize()
        // A racing edit observed during backup cancels replacement; keep the backup.
        guard sha256(try Data(contentsOf: backup)) == current,
              sha256(try Data(contentsOf: runtime)) == current else { throw ReviewError.contentChanged }
        try writeManaged(content, digest: sha256(content), runtime: runtime, marker: marker)
        try clearNotice(in: directory)
        return .updated(backup: backup.path)
    }

    private static func noticeURL(in directory: URL) -> URL {
        directory.appendingPathComponent("os-upstream.update-available.md")
    }

    private static func choiceURL(in directory: URL) -> URL {
        directory.appendingPathComponent("os-upstream.kept-custom.sha256")
    }

    private static func keptChoice(in directory: URL) -> String? {
        let url = choiceURL(in: directory)
        // An unreadable/invalid decision is not consent. Still expose the diff
        // so the user can apply it; a failed new decision write remains visible.
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clearNotice(in directory: URL) throws {
        let notice = noticeURL(in: directory)
        if FileManager.default.fileExists(atPath: notice.path) {
            // Only this generated notification is retired. Backups are never pruned.
            try FileManager.default.removeItem(at: notice)
        }
    }

    // Preflight marker writability, preserving its actual previous bytes (or an
    // untrusted empty marker). In particular, approving a custom file must NOT
    // claim its old hash if replacement fails. Only a successful write owns digest.
    private static func writeManaged(_ content: Data, digest: String, runtime: URL, marker: URL) throws {
        let previous = FileManager.default.fileExists(atPath: marker.path) ? try Data(contentsOf: marker) : Data()
        try previous.write(to: marker, options: .atomic)
        try content.write(to: runtime, options: .atomic)
        try Data((digest + "\n").utf8).write(to: marker, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
