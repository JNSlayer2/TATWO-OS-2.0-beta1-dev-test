import Foundation

/// Ephemeral, non-Codable preview. Passwords, Notes and OTPAuth never enter a metadata index.
struct AIICloudImportItem: Identifiable {
    let id = UUID()
    let origin: String
    let username: String
    let password: String
    let label: String
    let totpSecret: String?
}

struct AIICloudImportPreview: Identifiable {
    let id = UUID()
    var items: [AIICloudImportItem]
    var skipped: Int

    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= BrowserPasswordCSVImport.maximumBytes else {
            throw BrowserImportError.tooLarge
        }
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= BrowserPasswordCSVImport.maximumBytes,
              var text = String(data: data, encoding: .utf8) else { throw BrowserImportError.invalidData }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let rows = try BrowserPasswordCSVImport.csvRows(text)
        guard let header = rows.first else { throw BrowserImportError.invalidData }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count, let title = names.firstIndex(of: "title"),
              let url = names.firstIndex(of: "url"), let username = names.firstIndex(of: "username"),
              let password = names.firstIndex(of: "password") else { throw BrowserImportError.invalidData }
        // Notes are deliberately ignored: they may contain personal data/recovery codes.
        let otp = names.firstIndex(of: "otpauth")
        var result = Self(items: [], skipped: 0)
        for row in rows.dropFirst() where row != [""] {
            guard row.count == names.count, let origin = BrowserPasswordOrigin.normalized(row[url]),
                  !row[password].isEmpty, row[password].utf8.count <= 16_384,
                  row[username].utf8.count <= 4096 else { result.skipped += 1; continue }
            do {
                let raw = otp.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                let secret = raw.isEmpty ? nil : try TOTP.secret(from: raw)
                result.items.append(AIICloudImportItem(origin: origin, username: row[username],
                    password: row[password], label: row[title], totpSecret: secret))
            } catch { result.skipped += 1 } // Never import an account while silently dropping invalid OTPAuth.
        }
        return result
    }
}
