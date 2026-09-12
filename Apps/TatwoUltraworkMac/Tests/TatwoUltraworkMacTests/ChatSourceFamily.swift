import Foundation

/// Reads a Chat source "family" as one string for source-contract tests.
///
/// `ChatPageModel.swift` and `ChatRuntime.swift` were mechanically split into
/// topic files (2026-09-02). Tests that scan those sources keep asking for the
/// historical file name and receive the whole family, model body first, then
/// the `+Topic` extensions in name order.
enum ChatSourceFamily {
    static func read(_ historicalFileName: String, repoRoot: URL = ChatPageSourceScanner.repoRoot()) throws -> String {
        let directory = repoRoot.appendingPathComponent(ChatPageSourceScanner.sourcesDirectory, isDirectory: true)
        let urls = try familyURLs(for: historicalFileName, in: directory)
        return try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Read any source URL; files inside the Mac sources directory resolve to
    /// their split family (`X.swift` + `X+Topic.swift`), everything else is a
    /// plain single-file read.
    static func read(url: URL) throws -> String {
        let directory = url.deletingLastPathComponent().standardizedFileURL
        let macSources = ChatPageSourceScanner.repoRoot()
            .appendingPathComponent(ChatPageSourceScanner.sourcesDirectory, isDirectory: true)
            .standardizedFileURL
        guard directory.path == macSources.path else {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let urls = try familyURLs(for: url.lastPathComponent, in: directory)
        return try urls.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    static func familyURLs(for historicalFileName: String, in directory: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        let members: [String]
        switch historicalFileName {
        case "ChatPageModel.swift":
            members = names.filter { $0 == "ChatPageModel.swift" || $0.hasPrefix("ChatPageModel+") }
        case "ChatRuntime.swift":
            if names.contains("ChatRuntime.swift") {
                members = ["ChatRuntime.swift"]
            } else {
                members = names.filter { $0.hasPrefix("ChatCLI") || $0 == "ChatNativeAgentRunner.swift" }
            }
        case "EmbeddedBrowserView.swift":
            // 2026-09-02 split by view section (files are not `+Topic` named).
            let split = [
                "EmbeddedBrowserToolbar.swift", "EmbeddedBrowserRuntimePolicies.swift",
                "EmbeddedBrowserProfile.swift", "EmbeddedBrowserSessionLifecycle.swift",
                "EmbeddedBrowserSecurity.swift", "EmbeddedBrowserWebView.swift",
            ]
            members = names.filter { $0 == historicalFileName || split.contains($0) }
        default:
            // Generic split layout: `X.swift` plus `X+Topic.swift` extensions
            // (ChatPage, ChatPageLeafViews, EmbeddedBrowserView, ...).
            let stem = String(historicalFileName.dropLast(".swift".count))
            members = names.filter { $0 == historicalFileName || $0.hasPrefix(stem + "+") }
        }
        guard !members.isEmpty else {
            throw ChatPageSourceScannerError.noChatPageSources(directory.path)
        }
        let ordered = members.sorted { lhs, rhs in
            // Historical (main) file first, then the split files by name.
            let l = lhs == historicalFileName ? 0 : 1
            let r = rhs == historicalFileName ? 0 : 1
            if l != r { return l < r }
            return lhs < rhs
        }
        return ordered.map { directory.appendingPathComponent($0) }
    }
}
