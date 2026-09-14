import AppKit
import Combine
import CommonCrypto
import Foundation
import Security
import SQLite3
import SwiftUI

// Standalone typecheck substitutes only palette dependencies; the full app build
// uses real LiquidGlassTokens. These are not a Codex/Dia visual acceptance baseline.
enum LiquidGlassTokens {
    static let brandAccent = Color.accentColor
    static let tintOpacity = 0.18
    static let subtleFillOpacity = 0.045
}

enum ImportFixtureError: Error { case denied }
final class DeniedImportSecrets: BrowserSecretStore {
    func set(_ secret: String, for id: UUID) throws { throw ImportFixtureError.denied }
    func get(_ id: UUID) throws -> String? { throw ImportFixtureError.denied }
    func remove(_ id: UUID) throws { throw ImportFixtureError.denied }
}

// Only synthetic replies; even tests of refusal/fallback never call host Keychain.
final class ImportKeychainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(String, String?)] = []
    let statuses: [OSStatus]
    let data: Data
    init(statuses: [OSStatus] = [errSecSuccess], data: Data) {
        self.statuses = statuses; self.data = data
    }
    var queries: [(String, String?)] { lock.withLock { calls } }
    func query(service: String, account: String?) -> (OSStatus, Data?) {
        lock.withLock {
            let status = statuses[min(calls.count, statuses.count - 1)]
            calls.append((service, account))
            return (status, status == errSecSuccess ? data : nil)
        }
    }
}

@main struct BrowserImportChecks {
    @MainActor static var checks = 0
    @MainActor static var renderWindows: [NSWindow] = []
    @MainActor static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }
    @MainActor static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch { checks += 1 }
    }
    static func json(_ value: Any, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: .sortedKeys).write(to: url)
    }
    static func sqlite(_ url: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "synthetic sqlite setup")
    }
    static func webKit(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + ChromiumImporter.webKitEpochOffset) * 1_000_000)
    }

    // Independent encryption fixture: production only implements decryption.
    static func encryptedLogin(_ plaintext: Data, password: Data) throws -> Data {
        let salt: [UInt8] = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let derivation = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                bytes.bindMemory(to: Int8.self).baseAddress, password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
        }
        precondition(derivation == kCCSuccess, "fixture PBKDF2")
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: plaintext.count + 16)
        let capacity = output.count
        var written = 0
        let encrypted = plaintext.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128),
                CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                input.baseAddress, plaintext.count, &output, capacity, &written)
        }
        precondition(encrypted == kCCSuccess, "fixture AES-CBC")
        return Data("v10".utf8) + Data(output.prefix(written))
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let home = root.appendingPathComponent("synthetic-home")
        let scratch = root.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let chromeRoot = home.appendingPathComponent(BrowserImportSource.chrome.relativeDirectory)
        let chrome = chromeRoot.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chromeRoot.appendingPathComponent("Profile 2"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: chromeRoot.appendingPathComponent("Profile 9"), withDestinationURL: root)
        try json(["profile": ["info_cache": ["Default": ["name": "個人"], "Profile 2": ["name": "工作"]]]],
                 to: chromeRoot.appendingPathComponent("Local State"))
        let opera = home.appendingPathComponent(BrowserImportSource.opera.relativeDirectory)
        try json([:], to: opera.appendingPathComponent("Preferences"))
        let discovered = BrowserImportSources.discover(home: home)
        let chromeInfo = discovered.first { $0.source == .chrome }!
        check(chromeInfo.profiles.map(\.name) == ["個人", "工作"], "real directories + Local State names, symlink escape rejected")
        check(chromeInfo.isInstalled && chromeInfo.canSelect, "Chrome installed")
        check(discovered.first { $0.source == .opera }!.profiles.first?.directory.path == opera.path, "Opera root profile")
        check(discovered.first { $0.source == .safari }!.canSelect, "Safari guidance reachable even with hidden directory")
        check(!discovered.first { $0.source == .firefox }!.canSelect, "Firefox disabled")
        check(!discovered.first { $0.source == .brave }!.isInstalled, "missing browser")
        check(BrowserImportSource.arc.availableData == [.bookmarks, .passwords, .history], "Arc limits")
        check(BrowserImportSource.safari.availableData == [.bookmarks], "Safari only bookmarks")
        check(BrowserImportSource.chrome.availableData.count == 5, "Chromium data kinds")

        let bookmarkJSON: [String: Any] = ["roots": [
            "bookmark_bar": ["type": "folder", "name": "書籤列", "children": [
                ["type": "folder", "name": "工作", "children": [
                    ["type": "url", "name": "Fixture", "url": "https://fixture.example/page"],
                    ["type": "url", "name": "Rejected", "url": "javascript:alert(1)"]]],
                ["type": "url", "name": "Second", "url": "https://second.example"]]],
            "other": ["type": "folder", "name": "其他", "children": [
                ["type": "url", "name": "Third", "url": "https://third.example"]]],
            "synced": ["type": "folder", "name": "行動", "children": [
                ["type": "url", "name": "Fourth", "url": "https://fourth.example"]]]]]
        try json(bookmarkJSON, to: chrome.appendingPathComponent("Bookmarks"))
        let profile = BrowserImportProfile(directory: chrome, name: "個人", source: .chrome)
        let storagePassword = Data("SYNTHETIC-safe-storage-\u{0}-金鑰".utf8)
        let keychainProbe = ImportKeychainProbe(data: storagePassword)
        let safeStorage = BrowserSafeStorage(query: keychainProbe.query)
        let importer = ChromiumImporter(scratchRoot: scratch, keychainReader: { try safeStorage.read(source: $0) })
        let bookmarks = try importer.bookmarks(profile: profile)
        check(bookmarks.items.count == 4 && bookmarks.skipped == 1, "all three bookmark roots and invalid URL")
        check(bookmarks.items[0].folderPath == ["書籤列", "工作"], "recursive folder paths")
        check(bookmarks.items[0].title == "Fixture", "bookmark title")
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "copied JSON deleted")
        rejects("corrupt JSON rejected") { _ = try ChromiumImporter.parseBookmarks(Data("no".utf8)) }
        let mutable = root.appendingPathComponent("mutable.json")
        try Data("test".utf8).write(to: mutable)
        rejects("body failure still cleans owned scratch") {
            try BrowserImportSnapshot.withCopy(mutable, scratchRoot: scratch) { copy in
                check(copy != mutable, "read is a different file")
                throw BrowserImportError.invalidData
            }
        }
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "failure cleanup")

        let now = Date()
        let historyURL = chrome.appendingPathComponent("History")
        try sqlite(historyURL, """
            CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER, visit_count INTEGER);
            INSERT INTO urls VALUES
            ('https://recent.example','Recent',\(webKit(now.addingTimeInterval(-3600))),8),
            ('https://old.example','Old',\(webKit(now.addingTimeInterval(-91*86400))),2),
            ('https://future.example','Future',\(webKit(now.addingTimeInterval(86400))),1),
            ('javascript:bad','Bad',\(webKit(now.addingTimeInterval(-120))),1);
            """)
        let historyBytes = try Data(contentsOf: historyURL)
        let history = try importer.history(profile: profile, now: now)
        check(history.items.count == 1 && history.skipped == 1, "history last 90 days and no future rows")
        check(history.items[0].visitCount == 8 && abs(history.items[0].lastVisitTime.timeIntervalSince(now.addingTimeInterval(-3600))) < 0.01,
              "WebKit epoch and visit count")
        check(try Data(contentsOf: historyURL) == historyBytes, "source History unchanged")
        // Keep WAL open/uncheckpointed to prove records in the sidecar are included.
        var walDB: OpaquePointer?
        check(sqlite3_open(historyURL.path, &walDB) == SQLITE_OK, "fixture WAL connection")
        check(sqlite3_exec(walDB, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO urls VALUES ('https://wal.example','WAL',\(webKit(now.addingTimeInterval(-60))),3);",
                           nil, nil, nil) == SQLITE_OK, "synthetic WAL row")
        let walRead = try importer.history(profile: profile, now: now)
        check(walRead.items.contains { $0.url.host == "wal.example" }, "snapshot includes WAL")
        sqlite3_close(walDB)
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "DB + WAL copies cleaned")

        let cappedProfile = BrowserImportProfile(directory: root.appendingPathComponent("capped"), name: "Capped")
        try FileManager.default.createDirectory(at: cappedProfile.directory, withIntermediateDirectories: true)
        try sqlite(cappedProfile.directory.appendingPathComponent("History"), """
            CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER, visit_count INTEGER);
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<5100)
            INSERT INTO urls SELECT 'https://cap.example/'||x,'cap',\(webKit(now.addingTimeInterval(-60))),1 FROM n;
            """)
        check(try importer.history(profile: cappedProfile, now: now).items.count == 5000, "history 5000 cap")

        let safariDir = home.appendingPathComponent(BrowserImportSource.safari.relativeDirectory)
        try FileManager.default.createDirectory(at: safariDir, withIntermediateDirectories: true)
        let safariObject: [String: Any] = ["Children": [
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "收藏", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://safari.example",
                 "URIDictionary": ["title": "Safari fixture"]]]]]]
        let safariData = try PropertyListSerialization.data(fromPropertyList: safariObject, format: .binary, options: 0)
        try safariData.write(to: safariDir.appendingPathComponent("Bookmarks.plist"))
        let safari = try importer.safariBookmarks(profile: BrowserImportProfile(directory: safariDir, name: "Safari"))
        check(safari.items.count == 1 && safari.items[0].folderPath == ["收藏"], "Safari list/leaf")
        check(safari.items[0].title == "Safari fixture", "Safari URIDictionary title")

        try json(["pinned_tabs": [["url": "https://pin.example"], ["url": "file:///etc/passwd"]]], to: chrome.appendingPathComponent("Preferences"))
        let pins = try importer.pinnedTabs(profile: profile)
        check(pins.items.count == 1 && pins.skipped == 1, "pinned tabs validated")
        try json(["name": "Old", "version": "2"], to: chrome.appendingPathComponent("Extensions/fixture/2/manifest.json"))
        try json(["name": "__MSG_name__", "version": "10", "default_locale": "en"],
                 to: chrome.appendingPathComponent("Extensions/fixture/10/manifest.json"))
        try json(["name": ["message": "Fixture Extension"]], to: chrome.appendingPathComponent("Extensions/fixture/10/_locales/en/messages.json"))
        let extensions = try importer.extensions(profile: profile)
        check(extensions.items.count == 1 && extensions.items[0].version == "10", "one inventory item per extension latest numeric version")
        check(extensions.items[0].name == "Fixture Extension", "localized manifest name")

        let passwordURL = root.appendingPathComponent("user-selected-export.csv")
        let secret = "SYNTHETIC,\"only\"\r\nsecret"
        let csv = "name,url,username,password\r\n\"Fixture\",\"https://login.example/path\",\"test\",\"SYNTHETIC,\"\"only\"\"\r\nsecret\"\r\nBad,javascript:no,test,secret\r\n"
        try Data(csv.utf8).write(to: passwordURL)
        let passwords = try BrowserPasswordCSVImport.read(userSelectedFile: passwordURL)
        check(passwords.items.count == 1 && passwords.skipped == 1, "explicit CSV accepted, invalid origin skipped")
        check(passwords.items[0].password == secret, "quoted multiline password preserved")
        check(try BrowserPasswordCSVImport.parse(Data("\u{FEFF}origin,username,password,title\nhttps://bom.example,u,p,t".utf8)).items.count == 1, "BOM/vault CSV")
        rejects("unclosed quote") { _ = try BrowserPasswordCSVImport.parse(Data("url,username,password\nhttps://x.example,u,\"bad".utf8)) }
        rejects("trailing text after quote") { _ = try BrowserPasswordCSVImport.parse(Data("url,username,password\nhttps://x.example,u,\"bad\"text".utf8)) }
        rejects("duplicate headers") { _ = try BrowserPasswordCSVImport.parse(Data("url,username,password,password\nx,u,p,p".utf8)) }

        let loginURL = chrome.appendingPathComponent("Login Data")
        let ciphertext = try encryptedLogin(Data(secret.utf8), password: storagePassword)
        try sqlite(loginURL, """
            CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB);
            INSERT INTO logins VALUES
            ('https://login.example/path','test',X'\(hex(ciphertext))'),
            ('https://unsupported.example','test',X'763230010203'),
            ('https://broken.example','test',X'76313000');
            """)
        let loginBytes = try Data(contentsOf: loginURL)
        var loginSkipped = 0
        let logins = try importer.readLogins(profile: profile, skipped: &loginSkipped)
        check(logins.count == 1 && logins[0].password == secret && logins[0].username == "test",
              "CommonCrypto encrypted v10 roundtrips through real Login Data reader")
        check(logins[0].origin == "https://login.example/path", "login origin retained")
        check(loginSkipped == 2, "unsupported version and malformed ciphertext counted as skipped")
        check(keychainProbe.queries.count == 1, "one source authorization, not one per row")
        check(keychainProbe.queries[0].0 == "Chrome Safe Storage" && keychainProbe.queries[0].1 == "Chrome",
              "Chrome service and account")
        check(try importer.readLogins(profile: profile).count == 1, "requested array API")
        check(try Data(contentsOf: loginURL) == loginBytes, "source Login Data unchanged")
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "Login Data copy deleted")
        for (source, name) in [(BrowserImportSource.chrome, "Chrome"), (.brave, "Brave"), (.edge, "Microsoft Edge"),
                               (.arc, "Arc"), (.vivaldi, "Vivaldi"), (.opera, "Opera")] {
            let probe = ImportKeychainProbe(statuses: [errSecItemNotFound, errSecSuccess], data: storagePassword)
            check(try BrowserSafeStorage(query: probe.query).read(source: source) == storagePassword, "service fallback key")
            check(probe.queries.count == 2 && probe.queries[0].0 == "\(name) Safe Storage"
                  && probe.queries[0].1 == name && probe.queries[1].0 == "\(name) Safe Storage"
                  && probe.queries[1].1 == nil, "browser service/account then service-only fallback")
        }
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            let probe = ImportKeychainProbe(statuses: [status], data: storagePassword)
            let reader = ChromiumImporter(scratchRoot: scratch, keychainReader: {
                try BrowserSafeStorage(query: probe.query).read(source: $0)
            })
            var skipped = 0
            do {
                _ = try reader.readLogins(profile: profile, skipped: &skipped)
                preconditionFailure("denial must throw")
            } catch BrowserImportError.keychainDenied { checks += 1 }
            check(skipped == 3 && probe.queries.count == 1, "denial reports rows, never retries service-only")
            check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "denial cleans snapshot")
        }
        let missingKey = ImportKeychainProbe(statuses: [errSecItemNotFound], data: storagePassword)
        do {
            _ = try BrowserSafeStorage(query: missingKey.query).read(source: .chrome)
            preconditionFailure("missing key")
        } catch BrowserImportError.keychainUnavailable { checks += 1 }
        let invalidProfile = BrowserImportProfile(directory: chrome, name: "Unbound")
        let queriesBeforeUnbound = keychainProbe.queries.count
        rejects("unbound profile cannot read keys") { _ = try importer.readLogins(profile: invalidProfile) }
        check(keychainProbe.queries.count == queriesBeforeUnbound, "unbound profile has no Keychain side effect")

        let edgeCases = BrowserImportProfile(directory: root.appendingPathComponent("login-edge-cases"), name: "Fixture", source: .chrome)
        try FileManager.default.createDirectory(at: edgeCases.directory, withIntermediateDirectories: true)
        let edgeURL = edgeCases.directory.appendingPathComponent("Login Data")
        try sqlite(edgeURL, "CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, date_last_used INTEGER);")
        let queriesBeforeEmpty = keychainProbe.queries.count
        check(try importer.readLogins(profile: edgeCases).isEmpty, "empty database returns no passwords")
        check(keychainProbe.queries.count == queriesBeforeEmpty, "empty database does not ask for authorization")
        let invalidUTF8 = try encryptedLogin(Data([0xff, 0xfe]), password: storagePassword)
        let emptyPassword = try encryptedLogin(Data(), password: storagePassword)
        var badPadding = ciphertext
        badPadding[badPadding.count - 17] ^= 0xff // Corrupt the final padding byte deterministically.
        try sqlite(edgeURL, """
            INSERT INTO logins VALUES
            ('javascript:bad','u',X'\(hex(ciphertext))',0),
            ('https://invalid-utf8.example','u',X'\(hex(invalidUTF8))',0),
            ('https://empty.example','u',X'\(hex(emptyPassword))',0),
            ('https://null.example','u',NULL,0),
            ('https://padding.example','u',X'\(hex(badPadding))',0);
            """)
        var edgeSkipped = 0
        check(try importer.readLogins(profile: edgeCases, skipped: &edgeSkipped).isEmpty && edgeSkipped == 5,
              "invalid URL, UTF8, empty, NULL, padding failures skipped")
        var loginWAL: OpaquePointer?
        check(sqlite3_open(edgeURL.path, &loginWAL) == SQLITE_OK, "login WAL connection")
        check(sqlite3_exec(loginWAL, """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
            INSERT INTO logins VALUES ('https://wal-login.example','u',X'\(hex(ciphertext))',0);
            """, nil, nil, nil) == SQLITE_OK, "login WAL row")
        check(try importer.readLogins(profile: edgeCases).first?.password == secret, "Login Data includes WAL")
        sqlite3_close(loginWAL)
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "login WAL cleaned")

        let historyStore = BrowserHistoryStore(storageURL: root.appendingPathComponent("destination/history.json"))
        _ = try await historyStore.append(history.items)
        let duplicate = try await historyStore.append(history.items)
        check(duplicate.stored == 0, "append deduplicates repeated history import")
        let storedHistory = try await historyStore.entries()
        check(storedHistory.count == 1 && storedHistory[0].visitCount == 8, "history not double counted")
        let newer = BrowserHistoryEntry(url: history.items[0].url, title: "Newer", lastVisitTime: now, visitCount: 9)
        let upsert = try await historyStore.append([newer])
        check(upsert.added == 0 && upsert.updated == 1, "upserts reported as updated, not new")
        let corruptURL = root.appendingPathComponent("corrupt-history.json")
        let corrupt = Data("unreadable".utf8)
        try corrupt.write(to: corruptURL)
        do { _ = try await BrowserHistoryStore(storageURL: corruptURL).append(history.items); preconditionFailure("corrupt history must fail closed") }
        catch { checks += 1 }
        check(try Data(contentsOf: corruptURL) == corrupt, "corrupt history preserved")
        let cappedStore = BrowserHistoryStore(storageURL: root.appendingPathComponent("bounded-history.json"))
        let many = (0..<20_005).map { i in BrowserHistoryEntry(url: URL(string: "https://bounded.example/\(i)")!,
            title: "Fixture", lastVisitTime: now.addingTimeInterval(Double(i)), visitCount: 1) }
        let cappedResult = try await cappedStore.append(many)
        check(cappedResult.stored == 20_000 && cappedResult.skipped == 5, "history store 20000 cap")
        check(try await cappedStore.entries().count == 20_000, "history cap durable")

        let registry = BrowserTabRegistry(storageURL: root.appendingPathComponent("destination/tabs.json"))
        let space = registry.spaces.first { !$0.isSessionSpace }!.id
        let secrets = InMemorySecretStore()
        let vault = BrowserPasswordVault(indexURL: root.appendingPathComponent("destination/passwords.json"),
                                        secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        func coordinator(vault targetVault: BrowserPasswordVault? = nil, reader: ChromiumImporter? = nil) -> BrowserImportCoordinator {
            BrowserImportCoordinator(spaceID: space, registry: registry, vault: targetVault ?? vault,
                historyStore: historyStore, importer: reader ?? importer, sources: discovered)
        }
        let flow = coordinator()
        check(flow.state == .idle, "idle")
        await flow.begin()
        check(flow.state == .chooseSource, "chooseSource")
        flow.selectSource(.chrome)
        try render(flow, name: "01-source")
        flow.advance()
        check(flow.state == .chooseData, "chooseData")
        for kind in ImportData.allCases { flow.setData(kind, selected: true) }
        try render(flow, name: "02-data")
        let queriesBeforeNotice = keychainProbe.queries.count
        flow.advance()
        check(flow.state == .keychainNotice && flow.canAdvance && !flow.hasPasswordFile, "direct import needs no CSV")
        check(keychainProbe.queries.count == queriesBeforeNotice, "no Keychain read before explicit start")
        try render(flow, name: "03-password-notice")
        var updates: [Int] = []
        let observation = flow.$progress.sink { updates.append($0.counts[.bookmarks]?.imported ?? 0) }
        flow.advance()
        check(flow.isRunning, "running")
        try render(flow, name: "04-progress")
        await flow.waitUntilFinished()
        observation.cancel()
        guard case let .done(summary) = flow.state else { preconditionFailure("flow completion") }
        check(!summary.cancelled, "done")
        check(summary.progress.counts[.bookmarks]?.imported == 4, "bookmark success counts")
        check(summary.progress.counts[.history]?.reason?.contains("格式不支援") == true
              && summary.progress.counts[.history]?.reason?.contains("重複") == true, "summary preserves multiple skipped reasons")
        check(Set(updates).isSuperset(of: [1, 2, 3, 4]), "per-bookmark updates")
        check(registry.spaces.first { $0.id == space }!.folders.contains { $0.name == "Chrome 書籤/書籤列/工作" }, "flattened folder in registry")
        check(registry.tabs(ownedBy: .workSpace(spaceID: space)).filter(\.isPinned).count == 1, "destination pinned tab")
        check(vault.credentials.count == 1, "vault credential")
        check(try secrets.get(vault.credentials[0].id) == secret, "secret is only in injected secret store")
        check(summary.progress.counts[.passwords]?.imported == 1, "password count")
        check(summary.progress.counts[.passwords]?.skipped == 2, "decryption skipped count in coordinator")
        check(keychainProbe.queries.count == queriesBeforeNotice + 1, "one source key read in coordinator")
        check(summary.extensions.count == 1 && summary.progress.counts[.extensions]?.imported == 0, "extensions inventory not imported")
        check(summary.progress.counts[.extensions]?.reason?.contains("2.0.7 尚未支援") == true, "extension limitation summary")
        try render(flow, name: "05-summary")
        let destinationText = try String(contentsOf: root.appendingPathComponent("destination/history.json"), encoding: .utf8)
        check(!destinationText.contains("password") && !destinationText.contains("SYNTHETIC") && !destinationText.contains("username"), "history has no password data")
        check(try String(contentsOf: passwordURL, encoding: .utf8) == csv, "user export untouched")
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "no retained source copies")
        let reloaded = BrowserTabRegistry(storageURL: root.appendingPathComponent("destination/tabs.json"))
        check(reloaded.tabs.filter(\.isPinned).count == 1, "registry durable")

        let noPassword = coordinator()
        await noPassword.begin(); noPassword.selectSource(.chrome); noPassword.advance()
        noPassword.advance()
        check(noPassword.isRunning, "without passwords bypass notice")
        await noPassword.waitUntilFinished()
        check(registry.spaces.first { $0.id == space }!.folders.flatMap(\.bookmarks).count == 4, "repeat bookmark import no duplicates")

        let rejectedVault = BrowserPasswordVault(indexURL: nil, secrets: DeniedImportSecrets(), authenticator: AlwaysAllowAuthenticator())
        let denied = coordinator(vault: rejectedVault)
        await denied.begin(); denied.selectSource(.chrome); denied.advance()
        denied.setData(.passwords, selected: true); denied.setData(.pinned, selected: true)
        denied.selectPasswordFile(passwordURL); denied.advance(); denied.advance()
        await denied.waitUntilFinished()
        guard case let .done(deniedSummary) = denied.state else { preconditionFailure("denied category must not fail whole import") }
        check(deniedSummary.progress.counts[.passwords]?.skipped == 2, "denial skips all password rows including invalid")
        check(deniedSummary.progress.counts[.pinned]?.finished == true, "other categories continue after vault denial")

        let csvFlow = coordinator()
        await csvFlow.begin(); csvFlow.selectSource(.chrome); csvFlow.advance()
        csvFlow.setData(.passwords, selected: true); csvFlow.selectPasswordFile(passwordURL)
        check(csvFlow.hasPasswordFile, "CSV secondary choice is in scene two")
        let queriesBeforeCSV = keychainProbe.queries.count
        try render(csvFlow, name: "06-csv-data")
        csvFlow.advance()
        try render(csvFlow, name: "07-csv-notice")
        csvFlow.advance(); await csvFlow.waitUntilFinished()
        guard case let .done(csvSummary) = csvFlow.state else { preconditionFailure("CSV fallback done") }
        check(csvSummary.progress.counts[.passwords]?.updated == 1 && csvSummary.progress.counts[.passwords]?.skipped == 1,
              "CSV fallback imports through vault")
        check(keychainProbe.queries.count == queriesBeforeCSV, "CSV never accesses browser key")

        let refusedProbe = ImportKeychainProbe(statuses: [errSecUserCanceled], data: storagePassword)
        let refusedReader = ChromiumImporter(scratchRoot: scratch, keychainReader: {
            try BrowserSafeStorage(query: refusedProbe.query).read(source: $0)
        })
        let sourceDenied = coordinator(reader: refusedReader)
        await sourceDenied.begin(); sourceDenied.selectSource(.chrome); sourceDenied.advance()
        for kind in ImportData.allCases { sourceDenied.setData(kind, selected: true) }
        sourceDenied.advance(); sourceDenied.advance(); await sourceDenied.waitUntilFinished()
        guard case let .done(sourceDeniedSummary) = sourceDenied.state else { preconditionFailure("source denial is category only") }
        check(sourceDeniedSummary.progress.counts[.passwords]?.skipped == 3
              && sourceDeniedSummary.progress.counts[.passwords]?.reason == BrowserImportError.keychainDenied.message,
              "Keychain refusal skips full category with precise reason")
        check([ImportData.bookmarks, .history, .extensions, .pinned].allSatisfy {
            sourceDeniedSummary.progress.counts[$0]?.finished == true
        }, "categories before and after refusal complete")
        check(refusedProbe.queries.count == 1, "coordinator refusal no retry")
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "refused coordinator cleans copies")

        let cancel = coordinator()
        await cancel.begin(); cancel.selectSource(.chrome); cancel.advance(); cancel.advance()
        cancel.cancel()
        await cancel.waitUntilFinished()
        guard case let .done(cancelled) = cancel.state else { preconditionFailure("cancel produces partial summary") }
        check(cancelled.cancelled, "Task cancellation")
        check(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty, "cancel leaves no source copies")

        let partialRegistry = BrowserTabRegistry(storageURL: root.appendingPathComponent("partial/tabs.json"))
        let partialSpace = partialRegistry.spaces.first { !$0.isSessionSpace }!.id
        let partial = BrowserImportCoordinator(spaceID: partialSpace, registry: partialRegistry, vault: vault,
            historyStore: historyStore, importer: importer, sources: discovered)
        await partial.begin(); partial.selectSource(.chrome); partial.advance(); partial.setData(.history, selected: false)
        let partialObservation = partial.$progress.sink { value in
            if value.counts[.bookmarks]?.imported == 1 { partial.cancel() }
        }
        partial.advance()
        await partial.waitUntilFinished()
        partialObservation.cancel()
        guard case let .done(partialSummary) = partial.state else { preconditionFailure("partial cancellation") }
        check(partialSummary.cancelled && partialSummary.progress.counts[.bookmarks]?.imported == 1, "mid-bookmark cancellation retains exact progress")
        let partialReload = BrowserTabRegistry(storageURL: root.appendingPathComponent("partial/tabs.json"))
        check(partialReload.spaces.flatMap(\.folders).flatMap(\.bookmarks).count == 1, "partial import durable, not rolled back")

        let lastCategory = BrowserImportCoordinator(spaceID: space, registry: registry, vault: vault,
            historyStore: BrowserHistoryStore(storageURL: root.appendingPathComponent("last-category/history.json")),
            importer: importer, sources: discovered)
        await lastCategory.begin(); lastCategory.selectSource(.chrome); lastCategory.advance()
        lastCategory.setData(.bookmarks, selected: false)
        let lastObservation = lastCategory.$progress.sink { value in
            if (value.counts[.history]?.imported ?? 0) > 0 { lastCategory.cancel() }
        }
        lastCategory.advance()
        await lastCategory.waitUntilFinished()
        lastObservation.cancel()
        guard case let .done(lastSummary) = lastCategory.state else { preconditionFailure("cancel during final history publication") }
        check(lastSummary.cancelled && lastSummary.progress.counts[.history]?.processed == 3,
              "last-category cancellation not misreported as full completion; atomic history counts retained")

        let skippedPasswords = coordinator()
        await skippedPasswords.begin(); skippedPasswords.selectSource(.chrome); skippedPasswords.advance()
        skippedPasswords.setData(.passwords, selected: true)
        let queriesBeforeSkip = keychainProbe.queries.count
        skippedPasswords.advance(); skippedPasswords.skipPasswordsAndStart()
        await skippedPasswords.waitUntilFinished()
        guard case let .done(skippedSummary) = skippedPasswords.state else { preconditionFailure("skip password notice") }
        check(skippedSummary.progress.counts[.passwords]?.reason?.contains("使用者選擇略過") == true, "explicit password skip is explained")
        check(keychainProbe.queries.count == queriesBeforeSkip, "explicit skip never reads browser key")

        let missingSafari = BrowserImportCoordinator(spaceID: space, registry: registry, vault: vault,
            historyStore: historyStore, importer: importer,
            sources: [BrowserImportSourceInfo(source: .safari, isInstalled: false,
                profiles: [BrowserImportProfile(directory: root.appendingPathComponent("hidden-safari"), name: "Safari")])])
        await missingSafari.begin(); missingSafari.advance(); missingSafari.advance()
        await missingSafari.waitUntilFinished()
        guard case let .done(safariSummary) = missingSafari.state else { preconditionFailure("Safari failure is reported") }
        check(safariSummary.progress.counts[.bookmarks]?.reason?.contains("完整磁碟取用權") == true, "Safari failure permission guidance")
        for window in renderWindows { window.close() }
        print("W49 import fixture passed: \(checks) checks (synthetic data; injected Keychain only)")
    }

    @MainActor static func render(_ coordinator: BrowserImportCoordinator, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["W49_IMPORT_UI_EVIDENCE_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: BrowserImportFlowView(coordinator: coordinator))
        let size = NSSize(width: BrowserSidebarMetrics.importSheetWidth, height: BrowserSidebarMetrics.importSheetHeight)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            preconditionFailure("native fixture rendering unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { preconditionFailure("PNG unavailable") }
        try data.write(to: root.appendingPathComponent("\(name).png"))
        // Closing a running flow is cancellation. Retain snapshot hosts until the
        // fixture completes; never pump the run loop to manufacture a fake state.
        renderWindows.append(window)
    }
}
