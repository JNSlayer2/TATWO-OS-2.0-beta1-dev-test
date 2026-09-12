import Foundation
import CryptoKit
import ImageIO

/// Content-addressed local images make a failed submission safe to retry.
/// Unreferenced staged images remain retry cache; source files are never moved.
enum IssueImageAssets {
    /// Compatibility with older issue bodies that stored pasted screenshot paths.
    /// Only existing, decodable local image files are promoted; missing paths stay.
    static func extractingLegacyImages(from text: String) -> (text: String, paths: [String]) {
        let pattern = #"(?:file://)?/(?:Users|var|private|Volumes|tmp)/[^\r\n]+\.(?:png|jpe?g|heic|tiff?|gif|webp)(?=$|\s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return (text, []) }
        let source = text as NSString
        var result = text
        var paths: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let raw = source.substring(with: match.range)
            let path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : raw
            guard isImage(URL(fileURLWithPath: path)), let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
            paths.insert(path, at: 0)
        }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }
    static func displayName(_ name: String) -> String {
        let prefix = name.prefix(64)
        if prefix.count == 64, prefix.allSatisfy(\.isHexDigit),
           name.dropFirst(64).first == "-" { return String(name.dropFirst(65)) }
        return name
    }
    static func isImage(_ url: URL) -> Bool {
        url.isFileURL && CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) != nil
    }

    static func stage(paths: [String], root: URL) throws -> [String] {
        var seen = Set<String>()
        let urls = paths.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
        for url in urls {
            guard isImage(url),
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 32 * 1024 * 1024 else {
                throw BotLibraryError.invalid("issue 附件必須是可讀圖片，每張不超過 32 MB：\(url.lastPathComponent)")
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try urls.map { url in
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name = "\(digest)-\(displayName(url.lastPathComponent))"
            let destination = root.appendingPathComponent(name)
            guard destination.resolvingSymlinksInPath().deletingLastPathComponent() ==
                    root.resolvingSymlinksInPath() else {
                throw BotLibraryError.invalid("issue 圖片路徑不安全")
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .atomic)
            }
            guard try Data(contentsOf: destination, options: .mappedIfSafe) == data else {
                throw BotLibraryError.invalid("issue 圖片保存驗證失敗")
            }
            return name
        }
    }
}
