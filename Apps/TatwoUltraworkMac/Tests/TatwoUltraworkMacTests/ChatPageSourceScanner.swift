import Foundation

/// Source fixture for governance / contract tests that scan Chat page sources.
/// After the ChatPage god-file split, markers live across `ChatPage*.swift`;
/// tests should read the whole family instead of hardcoding one path.
enum ChatPageSourceScanner {
    static let sourcesDirectory =
        "Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac"

    /// Climb from a test `#filePath` under
    /// `Apps/TatwoUltraworkMac/Tests/TatwoUltraworkMacTests/` to the repo root.
    static func repoRoot(fromTestFile filePath: String = #filePath) -> URL {
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
        // Model body before +extensions so historical MARK fences that moved
        // into extension files still appear after the body they used to follow.
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

    /// Concatenated UTF-8 of every `ChatPage*.swift` (stable structural order).
    static func combinedSource(repoRoot: URL) throws -> String {
        let urls = try chatPageSourceURLs(repoRoot: repoRoot)
        var parts: [String] = []
        parts.reserveCapacity(urls.count)
        for url in urls {
            parts.append(try String(contentsOf: url, encoding: .utf8))
        }
        return parts.joined(separator: "\n")
    }

    static func combinedSource(fromTestFile filePath: String = #filePath) throws -> String {
        try combinedSource(repoRoot: repoRoot(fromTestFile: filePath))
    }

    /// Prefer a same-file hit, then fall back to the ordered combined source.
    static func slice(
        from start: String,
        through end: String,
        repoRoot: URL
    ) throws -> String? {
        for url in try chatPageSourceURLs(repoRoot: repoRoot) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if let section = text.slice(from: start, through: end) {
                return section
            }
        }
        return try combinedSource(repoRoot: repoRoot).slice(from: start, through: end)
    }

    static func readRelative(
        _ relativePath: String,
        repoRoot: URL
    ) throws -> String {
        try ChatSourceFamily.read(url: repoRoot.appendingPathComponent(relativePath))
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
    /// Slice between markers. Tolerates access-control prefix drift
    /// (`private`/`fileprivate`/…) introduced when symbols move across files.
    func slice(from start: String, through end: String) -> String? {
        guard let startRange = rangeOfSourceMarker(start) else { return nil }
        if let endRange = rangeOfSourceMarker(end, searchRange: startRange.upperBound..<endIndex) {
            return String(self[startRange.lowerBound..<endRange.lowerBound])
        }
        // After the 2026-09-02 file splits the historical "next declaration"
        // marker may live in another file. Fall back to the declaration body
        // that starts at `start`: up to the next member declared at the same
        // indentation, or the closing brace of the enclosing type.
        return declarationBody(startingAt: startRange)
    }

    private func declarationBody(startingAt startRange: Range<String.Index>) -> String? {
        let lineStart = self[..<startRange.lowerBound].lastIndex(of: "\n").map { index(after: $0) } ?? startIndex
        let indent = self[lineStart..<startRange.lowerBound].prefix { $0 == " " }.count
        let memberPattern = try! NSRegularExpression(
            pattern: "^ {\(indent)}(?:@[A-Za-z]+(?:\\([^)]*\\))? +)*(?:private |fileprivate |internal |public |package |nonisolated |static |final |override |convenience |mutating |lazy |weak |unowned )*(?:func|var|let|init|deinit|enum|struct|class|actor|typealias|subscript|case|extension)\\b")
        let closingPattern = try! NSRegularExpression(pattern: "^ {\(max(indent - 4, 0))}\\}\\s*$")
        var cursor = startRange.upperBound
        while let nextLineBreak = self[cursor...].firstIndex(of: "\n") {
            let lineStart = index(after: nextLineBreak)
            guard lineStart < endIndex else { break }
            let lineEnd = self[lineStart...].firstIndex(of: "\n") ?? endIndex
            let line = String(self[lineStart..<lineEnd])
            let ns = NSRange(location: 0, length: line.utf16.count)
            if memberPattern.firstMatch(in: line, range: ns) != nil
                || closingPattern.firstMatch(in: line, range: ns) != nil {
                return String(self[startRange.lowerBound..<lineStart])
            }
            cursor = lineStart
        }
        return String(self[startRange.lowerBound..<endIndex])
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

    /// Access-control variants of a source marker used by slice/contains helpers.
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
