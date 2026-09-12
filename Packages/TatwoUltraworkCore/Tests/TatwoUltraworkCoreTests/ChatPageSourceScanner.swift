import Foundation

/// Core-package copy of the ChatPage multi-file source scanner.
/// Kept local so Core tests do not depend on the Mac test target.
enum ChatPageSourceScanner {
    static let sourcesDirectory =
        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac"

    static func repoRoot(fromCoreTestFile filePath: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    static func chatPageSourceURLs(repoRoot: URL) throws -> [URL] {
        let directory = repoRoot.appendingPathComponent(sourcesDirectory, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        let urls = contents
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix("ChatPage") }
        guard !urls.isEmpty else {
            throw ChatPageSourceScannerError.noChatPageSources(directory.path)
        }
        return urls.sorted { lhs, rhs in
            let l = sourceRank(lhs.lastPathComponent)
            let r = sourceRank(rhs.lastPathComponent)
            if l.0 != r.0 { return l.0 < r.0 }
            return l.1 < r.1
        }
    }

    private static func sourceRank(_ name: String) -> (Int, String) {
        if name == "ChatPageModel.swift" { return (0, name) }
        if name.hasPrefix("ChatPageModel+") { return (1, name) }
        if name == "ChatPage.swift" { return (2, name) }
        return (3, name)
    }

    static func combinedSource(repoRoot: URL) throws -> String {
        let urls = try chatPageSourceURLs(repoRoot: repoRoot)
        var parts: [String] = []
        parts.reserveCapacity(urls.count)
        for url in urls {
            parts.append(try String(contentsOf: url, encoding: .utf8))
        }
        return parts.joined(separator: "\n")
    }

    static func combinedSource(fromCoreTestFile filePath: String = #filePath) throws -> String {
        try combinedSource(repoRoot: repoRoot(fromCoreTestFile: filePath))
    }

    static func readRelative(_ relativePath: String, repoRoot: URL) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }
}

enum ChatPageSourceScannerError: Error, CustomStringConvertible {
    case noChatPageSources(String)

    var description: String {
        switch self {
        case .noChatPageSources(let path):
            return "No ChatPage*.swift sources under \(path)"
        }
    }
}

extension String {
    func slice(from start: String, through end: String) -> String? {
        guard
            let startRange = rangeOfSourceMarker(start),
            let endRange = rangeOfSourceMarker(end, searchRange: startRange.upperBound..<endIndex)
        else {
            return nil
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }

    func rangeOfSourceMarker(
        _ marker: String,
        searchRange: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        let range = searchRange ?? startIndex..<endIndex
        if let hit = self.range(of: marker, range: range) {
            return hit
        }
        for variant in Self.sourceMarkerVariants(of: marker) where variant != marker {
            if let hit = self.range(of: variant, range: range) {
                return hit
            }
        }
        return nil
    }

    static func sourceMarkerVariants(of marker: String) -> [String] {
        let prefixes = ["private ", "fileprivate ", "internal ", "public ", "open "]
        var base = marker
        for prefix in prefixes where base.hasPrefix(prefix) {
            base = String(base.dropFirst(prefix.count))
            break
        }
        var variants: [String] = []
        if base != marker {
            variants.append(base)
        }
        for prefix in prefixes {
            let candidate = prefix + base
            if candidate != marker {
                variants.append(candidate)
            }
        }
        return variants
    }
}
