import Foundation

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
}
