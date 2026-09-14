import Foundation

/// Explicitly requested browser migration or user-selected CSV fallback.
/// This type is deliberately not Codable
/// and never enters progress, summaries, history, logs or a temporary disk copy.
struct BrowserImportedPassword: Sendable {
    let origin: String
    let username: String
    let password: String
    let title: String
}

typealias ImportedLogin = BrowserImportedPassword

enum BrowserPasswordCSVImport {
    static let maximumBytes = 10 * 1_024 * 1_024
    static let maximumRows = 20_000

    static func read(userSelectedFile url: URL) throws -> BrowserImportReadResult<BrowserImportedPassword> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maximumBytes else { throw BrowserImportError.tooLarge }
        return try parse(Data(contentsOf: url))
    }

    static func parse(_ data: Data) throws -> BrowserImportReadResult<BrowserImportedPassword> {
        guard data.count <= maximumBytes else { throw BrowserImportError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw BrowserImportError.invalidData }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try csvRows(text)
        guard let header = rows.first else { throw BrowserImportError.invalidData }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count,
              let origin = names.firstIndex(of: "url") ?? names.firstIndex(of: "origin"),
              let username = names.firstIndex(of: "username"),
              let password = names.firstIndex(of: "password") else { throw BrowserImportError.invalidData }
        let title = names.firstIndex(of: "name") ?? names.firstIndex(of: "title")
        var result = BrowserImportReadResult<BrowserImportedPassword>()
        for row in rows.dropFirst() {
            try Task.checkCancellation()
            if row == [""] { continue }
            guard row.count == names.count, ChromiumImporter.navigationURL(row[origin]) != nil,
                  !row[password].isEmpty else { result.skipped += 1; continue }
            result.items.append(BrowserImportedPassword(origin: row[origin], username: row[username],
                password: row[password], title: title.map { row[$0] } ?? ""))
        }
        return result
    }

    static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closedQuote = false, fieldStarted = false, skipLF = false
        var iterator = text.unicodeScalars.makeIterator()
        while let char = iterator.next() {
            try Task.checkCancellation()
            if skipLF { skipLF = false; if char == "\n" { continue } }
            if quoted {
                if char == "\"" { quoted = false; closedQuote = true }
                else { field.unicodeScalars.append(char) }
                continue
            }
            if closedQuote && char == "\"" {
                field.append("\""); quoted = true; closedQuote = false; continue
            }
            if char == "," {
                row.append(field); field = ""; fieldStarted = false; closedQuote = false
            } else if char == "\r" || char == "\n" {
                row.append(field); rows.append(row)
                guard rows.count <= maximumRows + 1 else { throw BrowserImportError.tooLarge }
                row = []; field = ""; fieldStarted = false; closedQuote = false; skipLF = char == "\r"
            } else if char == "\"" && !fieldStarted {
                quoted = true; fieldStarted = true
            } else {
                guard !closedQuote, char != "\"" else { throw BrowserImportError.invalidData }
                field.unicodeScalars.append(char); fieldStarted = true
            }
        }
        guard !quoted else { throw BrowserImportError.invalidData }
        if fieldStarted || !row.isEmpty { row.append(field); rows.append(row) }
        guard rows.count <= maximumRows + 1 else { throw BrowserImportError.tooLarge }
        return rows
    }
}
