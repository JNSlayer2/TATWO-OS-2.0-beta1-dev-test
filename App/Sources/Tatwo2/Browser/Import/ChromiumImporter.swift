import Foundation
import SQLite3
import Security
import CommonCrypto

struct ImportedBookmark: Equatable, Sendable {
    let folderPath: [String]
    let title: String
    let url: URL
}

struct ImportedExtension: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
}

struct BrowserImportReadResult<Item: Sendable>: Sendable {
    var items: [Item] = []
    var skipped = 0
}

enum BrowserImportError: Error, Equatable {
    case unreadable, invalidData, tooLarge, sourceChanging, database, destinationUnavailable
    case keychainDenied, keychainUnavailable
    var message: String {
        switch self {
        case .unreadable: "來源檔案不存在或無法讀取。"
        case .invalidData: "來源格式無法辨識；沒有取代既有資料。"
        case .tooLarge: "來源超過單次讀取上限；請先在來源瀏覽器縮小資料範圍。"
        case .sourceChanging: "來源瀏覽器正在更新資料，請關閉該瀏覽器後重新導入。"
        case .database: "無法讀取來源資料庫；請關閉來源瀏覽器後再試。"
        case .destinationUnavailable: "目的空間已不存在或無法儲存；已停止導入。"
        case .keychainDenied: "密碼保護金鑰存取被拒絕；已略過密碼，其它資料繼續。"
        case .keychainUnavailable: "找不到或無法讀取密碼保護金鑰；可改用 CSV 備援，其它資料繼續。"
        }
    }
}

/// Only reads copies in an owned, private temporary directory. No source path is
/// ever opened for writing. A changing source is rejected, rather than treating
/// a torn History/WAL copy as a successful snapshot.
enum BrowserImportSnapshot {
    static let maximumFileBytes = 256 * 1_024 * 1_024
    static let maximumJSONBytes = 32 * 1_024 * 1_024

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date
        let inode: UInt64
    }

    private static func stamp(_ url: URL, limit: Int) throws -> Stamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? UInt64 else { throw BrowserImportError.unreadable }
        guard size <= limit else { throw BrowserImportError.tooLarge }
        return Stamp(size: size, modified: modified, inode: inode)
    }

    static func withCopy<T>(_ source: URL, database: Bool = false, limit: Int = maximumFileBytes,
                            scratchRoot: URL = FileManager.default.temporaryDirectory,
                            _ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let directory = scratchRoot.appendingPathComponent("browser-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // This directory contains only this call's temporary copies; never user originals.
        defer { try? fm.removeItem(at: directory) }
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let hadWAL = database && fm.fileExists(atPath: wal.path)
        let sources = hadWAL ? [source, wal] : [source]
        let before = try sources.map { try stamp($0, limit: limit) }
        for file in sources {
            try Task.checkCancellation()
            let copy = directory.appendingPathComponent(file.lastPathComponent)
            try fm.copyItem(at: file, to: copy)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        }
        guard before == (try sources.map { try stamp($0, limit: limit) }),
              !database || fm.fileExists(atPath: wal.path) == hadWAL else { throw BrowserImportError.sourceChanging }
        try Task.checkCancellation()
        return try body(directory.appendingPathComponent(source.lastPathComponent))
    }

    static func read(_ source: URL, scratchRoot: URL = FileManager.default.temporaryDirectory) throws -> Data {
        try withCopy(source, limit: maximumJSONBytes, scratchRoot: scratchRoot) { try Data(contentsOf: $0) }
    }
}

/// Uses the system's normal Keychain authorization. Never changes ACLs, suppresses
/// prompts, retries a denial, or caches the browser key between import runs.
struct BrowserSafeStorage: Sendable {
    typealias Query = @Sendable (_ service: String, _ account: String?) -> (OSStatus, Data?)
    var query: Query = { service, account in
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { attributes[kSecAttrAccount as String] = account }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        return (status, result as? Data)
    }

    func read(source: BrowserImportSource) throws -> Data {
        guard let name = source.safeStorageName else { throw BrowserImportError.invalidData }
        try Task.checkCancellation()
        let service = "\(name) Safe Storage"
        var (status, data) = query(service, name)
        // An absent account is not a refusal. Only this status permits fallback.
        if status == errSecItemNotFound {
            try Task.checkCancellation()
            (status, data) = query(service, nil)
        }
        try Task.checkCancellation()
        switch status {
        case errSecSuccess:
            guard let data, !data.isEmpty else { throw BrowserImportError.keychainUnavailable }
            return data
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw BrowserImportError.keychainDenied
        default: throw BrowserImportError.keychainUnavailable
        }
    }
}

struct ChromiumImporter: Sendable {
    var scratchRoot: URL = FileManager.default.temporaryDirectory
    var keychainReader: @Sendable (BrowserImportSource) throws -> Data = {
        try BrowserSafeStorage().read(source: $0)
    }
    private static let maximumTreeDepth = 64
    private static let maximumTreeNodes = 100_000

    /// Imported navigation never executes javascript:, file:, data: or a URL with
    /// embedded credentials. Nothing is fetched while parsing.
    static func navigationURL(_ string: String?) -> URL? {
        guard let string, let parts = URLComponents(string: string),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return parts.url
    }

    func bookmarks(profile: BrowserImportProfile) throws -> BrowserImportReadResult<ImportedBookmark> {
        let data = try BrowserImportSnapshot.read(profile.directory.appendingPathComponent("Bookmarks"), scratchRoot: scratchRoot)
        return try Self.parseBookmarks(data)
    }

    static func parseBookmarks(_ data: Data) throws -> BrowserImportReadResult<ImportedBookmark> {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = object["roots"] as? [String: Any] else { throw BrowserImportError.invalidData }
        var result = BrowserImportReadResult<ImportedBookmark>()
        var nodes = 0
        func walk(_ node: [String: Any], path: [String], depth: Int) throws {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= maximumTreeDepth, nodes <= maximumTreeNodes else { throw BrowserImportError.tooLarge }
            let title = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                guard let url = navigationURL(node["url"] as? String) else { result.skipped += 1; return }
                result.items.append(ImportedBookmark(folderPath: path, title: title, url: url))
            } else if let children = node["children"] as? [[String: Any]] {
                for child in children { try walk(child, path: path + (title.isEmpty ? [] : [title]), depth: depth + 1) }
            } else { result.skipped += 1 }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let root = roots[key] as? [String: Any] { try walk(root, path: [], depth: 0) }
        }
        return result
    }

    func safariBookmarks(profile: BrowserImportProfile) throws -> BrowserImportReadResult<ImportedBookmark> {
        try Self.parseSafariBookmarks(BrowserImportSnapshot.read(
            profile.directory.appendingPathComponent("Bookmarks.plist"), scratchRoot: scratchRoot))
    }

    static func parseSafariBookmarks(_ data: Data) throws -> BrowserImportReadResult<ImportedBookmark> {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BrowserImportError.invalidData
        }
        var result = BrowserImportReadResult<ImportedBookmark>()
        var nodes = 0
        func walk(_ node: [String: Any], path: [String], depth: Int) throws {
            try Task.checkCancellation()
            nodes += 1
            guard depth <= maximumTreeDepth, nodes <= maximumTreeNodes else { throw BrowserImportError.tooLarge }
            let type = node["WebBookmarkType"] as? String
            if type == "WebBookmarkTypeLeaf" {
                guard let url = navigationURL(node["URLString"] as? String) else { result.skipped += 1; return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                    ?? node["Title"] as? String ?? ""
                result.items.append(ImportedBookmark(folderPath: path, title: title, url: url))
            } else if let children = node["Children"] as? [[String: Any]],
                      type == nil || type == "WebBookmarkTypeList" {
                let name = node["Title"] as? String ?? ""
                for child in children { try walk(child, path: path + (name.isEmpty ? [] : [name]), depth: depth + 1) }
            } else { result.skipped += 1 }
        }
        try walk(root, path: [], depth: 0)
        return result
    }

    // WebKit timestamps are microseconds since 1601-01-01 UTC.
    static let webKitEpochOffset: TimeInterval = 11_644_473_600
    static func date(webKitMicroseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(webKitMicroseconds) / 1_000_000 - webKitEpochOffset)
    }

    func readLogins(profile: BrowserImportProfile) throws -> [ImportedLogin] {
        var skipped = 0
        return try readLogins(profile: profile, skipped: &skipped)
    }

    /// The reporting overload retains the row count on denial/fatal read failure,
    /// so the coordinator can skip passwords without aborting other categories.
    func readLogins(profile: BrowserImportProfile, skipped: inout Int) throws -> [ImportedLogin] {
        skipped = 0
        guard let source = profile.source, source.safeStorageName != nil else {
            throw BrowserImportError.invalidData
        }
        let result = try BrowserImportSnapshot.withCopy(
            profile.directory.appendingPathComponent("Login Data"), database: true, scratchRoot: scratchRoot
        ) { copy -> BrowserImportReadResult<ImportedLogin> in
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                throw BrowserImportError.database
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 500)
            sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            var count: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM logins", -1, &count, nil) == SQLITE_OK else {
                throw BrowserImportError.database
            }
            defer { sqlite3_finalize(count) }
            guard sqlite3_step(count) == SQLITE_ROW else {
                try Task.checkCancellation()
                throw BrowserImportError.database
            }
            skipped = Int(sqlite3_column_int64(count, 0))
            guard skipped > 0 else { return BrowserImportReadResult() }
            guard skipped <= 100_000 else { throw BrowserImportError.tooLarge }
            var statement: OpaquePointer?
            let sql = "SELECT origin_url, username_value, password_value FROM logins"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw BrowserImportError.database
            }
            defer { sqlite3_finalize(statement) }
            // Exactly one key read per selected source, not one per password.
            var password = try keychainReader(source)
            defer { password.resetBytes(in: 0..<password.count) }
            try Task.checkCancellation()
            var key = try Self.loginKey(password: password)
            defer { key.resetBytes(in: 0..<key.count) }
            var read = BrowserImportReadResult<ImportedLogin>()
            func text(_ column: Int32) -> String? {
                let length = Int(sqlite3_column_bytes(statement, column))
                guard length <= 1_024 * 1_024, let bytes = sqlite3_column_text(statement, column) else { return nil }
                return String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
            }
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    try Task.checkCancellation()
                    throw BrowserImportError.database
                }
                let length = Int(sqlite3_column_bytes(statement, 2))
                guard let url = Self.navigationURL(text(0)), let username = text(1),
                      sqlite3_column_type(statement, 2) == SQLITE_BLOB,
                      length > 3, length <= 1_024 * 1_024,
                      let bytes = sqlite3_column_blob(statement, 2),
                      let plain = Self.decryptLogin(Data(bytes: bytes, count: length), key: key),
                      !plain.isEmpty else { read.skipped += 1; continue }
                read.items.append(ImportedLogin(origin: url.absoluteString, username: username, password: plain, title: ""))
            }
            return read
        }
        skipped = result.skipped
        return result.items
    }

    private static func loginKey(password: Data) throws -> Data {
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBufferPointer { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBytes.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003, keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else {
            key.resetBytes(in: 0..<key.count)
            throw BrowserImportError.invalidData
        }
        return key
    }

    private static func decryptLogin(_ value: Data, key: Data) -> String? {
        guard value.starts(with: [0x76, 0x31, 0x30]) else { return nil } // v10 only
        let encrypted = value.dropFirst(3)
        guard !encrypted.isEmpty, encrypted.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = Data(count: encrypted.count + kCCBlockSizeAES128)
        defer { plaintext.resetBytes(in: 0..<plaintext.count) }
        let capacity = plaintext.count
        var written = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                encrypted.withUnsafeBytes { input in
                    iv.withUnsafeBufferPointer { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, input.baseAddress, encrypted.count,
                            output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: plaintext.prefix(written), encoding: .utf8)
    }

    func history(profile: BrowserImportProfile, now: Date = Date()) throws -> BrowserImportReadResult<BrowserHistoryEntry> {
        try BrowserImportSnapshot.withCopy(profile.directory.appendingPathComponent("History"), database: true,
                                           scratchRoot: scratchRoot) { copy in
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }
                throw BrowserImportError.database
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 500)
            sqlite3_progress_handler(db, 1_000, { _ in Task<Never, Never>.isCancelled ? 1 : 0 }, nil)
            var statement: OpaquePointer?
            let sql = """
                SELECT url, title, last_visit_time, visit_count FROM urls
                WHERE last_visit_time >= ? AND last_visit_time <= ?
                ORDER BY last_visit_time DESC, url ASC LIMIT 5000
                """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw BrowserImportError.database }
            defer { sqlite3_finalize(statement) }
            let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
            sqlite3_bind_int64(statement, 1, Int64((cutoff.timeIntervalSince1970 + Self.webKitEpochOffset) * 1_000_000))
            sqlite3_bind_int64(statement, 2, Int64((now.timeIntervalSince1970 + Self.webKitEpochOffset) * 1_000_000))
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            var result = BrowserImportReadResult<BrowserHistoryEntry>()
            while true {
                try Task.checkCancellation()
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    try Task.checkCancellation()
                    throw BrowserImportError.database
                }
                guard let url = Self.navigationURL(text(0)) else { result.skipped += 1; continue }
                result.items.append(BrowserHistoryEntry(url: url, title: text(1) ?? "",
                    lastVisitTime: Self.date(webKitMicroseconds: sqlite3_column_int64(statement, 2)),
                    visitCount: max(0, Int(sqlite3_column_int64(statement, 3)))))
            }
            return result
        }
    }

    func pinnedTabs(profile: BrowserImportProfile) throws -> BrowserImportReadResult<URL> {
        let data = try BrowserImportSnapshot.read(profile.directory.appendingPathComponent("Preferences"), scratchRoot: scratchRoot)
        guard let preferences = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserImportError.invalidData
        }
        guard let raw = preferences["pinned_tabs"] else { return BrowserImportReadResult() }
        guard let tabs = raw as? [Any] else { throw BrowserImportError.invalidData }
        var result = BrowserImportReadResult<URL>()
        for tab in tabs {
            try Task.checkCancellation()
            if let url = Self.navigationURL((tab as? [String: Any])?["url"] as? String ?? tab as? String) {
                result.items.append(url)
            } else { result.skipped += 1 }
        }
        return result
    }

    /// Inventory only: never copy an extension directory or install anything.
    func extensions(profile: BrowserImportProfile) throws -> BrowserImportReadResult<ImportedExtension> {
        let root = profile.directory.appendingPathComponent("Extensions", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return BrowserImportReadResult() }
        let ids = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var result = BrowserImportReadResult<ImportedExtension>()
        for id in ids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard (try? id.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard id.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                  let versions = try? fm.contentsOfDirectory(at: id, includingPropertiesForKeys: [.isDirectoryKey]),
                  let version = versions.filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
                    .sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }).first,
                  version.resolvingSymlinksInPath().deletingLastPathComponent() == id.resolvingSymlinksInPath() else {
                result.skipped += 1; continue
            }
            do {
                let data = try BrowserImportSnapshot.read(version.appendingPathComponent("manifest.json"), scratchRoot: scratchRoot)
                guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      var name = manifest["name"] as? String,
                      let number = manifest["version"] as? String else { throw BrowserImportError.invalidData }
                if name.hasPrefix("__MSG_"), name.hasSuffix("__"),
                   let locale = manifest["default_locale"] as? String,
                   !locale.isEmpty, locale.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                    let key = String(name.dropFirst(6).dropLast(2))
                    if let bytes = try? BrowserImportSnapshot.read(
                        version.appendingPathComponent("_locales/\(locale)/messages.json"), scratchRoot: scratchRoot),
                       let messages = try? JSONSerialization.jsonObject(with: bytes) as? [String: [String: Any]],
                       let localized = messages[key]?["message"] as? String { name = localized }
                }
                result.items.append(ImportedExtension(id: id.lastPathComponent, name: name, version: number))
            } catch is CancellationError { throw CancellationError() }
            catch { result.skipped += 1 }
        }
        return result
    }
}
