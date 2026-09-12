import Foundation
import CryptoKit

enum OSUpstreamRefresh {
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

    // Resolve the same SwiftPM resource without Bundle.module's fatalError when its bundle is absent.
    static var bundledURL: URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        return roots.compactMap { $0 }.compactMap {
            Bundle(url: $0.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle"))?.url(forResource: "os-upstream", withExtension: "md")
        }.first ?? Bundle.main.url(forResource: "os-upstream", withExtension: "md")
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
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try writeManaged(content, digest: digest, previous: nil, runtime: runtime, marker: marker)
                return .installed
            }
            let current = sha256(try Data(contentsOf: runtime))
            let markerText = fm.fileExists(atPath: marker.path)
                ? try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let installed = markerText?.split(separator: "\n").map(String.init)
            // 無標記但內容與 bundle 一致（例如手動放過同一版）：認領所有權，之後的 bundle 更新才有基準可比。
            if current == digest {
                try Data((digest + "\n").utf8).write(to: marker, options: .atomic)
                return .unchanged
            }
            guard let installed, installed.contains(current) else {
                // Hashes detect a changed bundle, not chronological version ordering.
                if digest != current && !(installed?.contains(digest) ?? false) {
                    let notice = directory.appendingPathComponent("os-upstream.update-available.md")
                    try Data("App 內建 OS 上游宣告內容不同；已保留自訂檔案，請手動比較後更新。\n".utf8).write(to: notice, options: .atomic)
                }
                return .keptUserEdited
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
            let backup = directory.appendingPathComponent("os-upstream.md.bak-\(formatter.string(from: now))")
            try fm.copyItem(at: runtime, to: backup)
            try writeManaged(content, digest: digest, previous: current, runtime: runtime, marker: marker)
            return .updated(backup: backup.path)
        } catch {
            let error = error as NSError
            return .failed("\(error.domain):\(error.code)")
        }
    }

    // Write-ahead ownership journal: either hash is system-owned if interrupted
    // before or after content replacement. A third hash remains a user edit.
    private static func writeManaged(_ content: Data, digest: String, previous: String?,
                                     runtime: URL, marker: URL) throws {
        let hashes = [previous, digest].compactMap { $0 }.joined(separator: "\n") + "\n"
        try Data(hashes.utf8).write(to: marker, options: .atomic)
        try content.write(to: runtime, options: .atomic)
        try Data((digest + "\n").utf8).write(to: marker, options: .atomic)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
