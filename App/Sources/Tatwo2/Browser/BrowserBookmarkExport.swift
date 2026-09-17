import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor
enum BrowserBookmarkExport {
    static func html(registry: BrowserTabRegistry) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>",
                     "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
                     "<TITLE>書籤</TITLE>", "<H1>書籤</H1>", "<DL><p>"]
        // Netscape links remain readable in other browsers; the metadata preserves IDs,
        // ordering and icon snapshots when imported back into TATWO.
        // An empty export is still a valid archive (a no-op on import).
        if let data = try? JSONEncoder().encode(registry.favorites) {
            lines.insert("<META NAME=\"TATWO_FAVORITES\" CONTENT=\"\(data.base64EncodedString())\">", at: 2)
        }
        if !registry.favorites.isEmpty {
            lines += ["<DT><H3>珍藏網頁</H3>", "<DL><p>"]
            for favorite in registry.favorites {
                let icon = favorite.faviconPNG.map { " ICON=\"data:image/png;base64,\($0.base64EncodedString())\"" } ?? ""
                lines.append("<DT><A HREF=\"\(escaped(favorite.url.absoluteString))\"\(icon)>\(escaped(favorite.title))</A>")
            }
            lines.append("</DL><p>")
        }
        for space in registry.spaces where !space.isSessionSpace {
            lines += ["<DT><H3>\(escaped(space.name))</H3>", "<DL><p>"]
            for folder in space.folders {
                lines += ["<DT><H3>\(escaped(folder.name))</H3>", "<DL><p>"]
                for bookmark in folder.bookmarks {
                    lines.append("<DT><A HREF=\"\(escaped(bookmark.url.absoluteString))\">\(escaped(bookmark.title))</A>")
                }
                lines.append("</DL><p>")
            }
            lines.append("</DL><p>")
        }
        lines.append("</DL><p>")
        return lines.joined(separator: "\n")
    }

    /// Only reads our own metadata, not scripts or remote resources in arbitrary HTML.
    @discardableResult
    static func importFavorites(html: String, registry: BrowserTabRegistry) throws -> Int {
        guard html.utf8.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let pattern = #"<META NAME="TATWO_FAVORITES" CONTENT="([A-Za-z0-9+/=]+)">"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = Data(base64Encoded: String(html[range])) else { throw CocoaError(.fileReadCorruptFile) }
        let favorites = try JSONDecoder().decode([BrowserFavorite].self, from: data)
        return registry.importFavorites(favorites)
    }

    static func presentFavoriteImport(registry: BrowserTabRegistry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let html = try await Task.detached(priority: .utility) {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        return try String(contentsOf: url, encoding: .utf8)
                    }.value
                    let count = try importFavorites(html: html, registry: registry)
                    let alert = NSAlert()
                    alert.messageText = "已匯入 \(count) 個珍藏"
                    alert.informativeText = "相同網址會保留既有珍藏；分頁與書籤不受影響。"
                    alert.runModal()
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "無法匯入珍藏"
                    alert.informativeText = "請選擇由 TATWO 匯出、包含珍藏的書籤 HTML。"
                    alert.runModal()
                }
            }
        }
    }
}
