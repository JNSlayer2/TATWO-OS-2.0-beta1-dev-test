import AppKit
import Foundation
import SwiftUI

// Typecheck the production settings view in isolation; no Island is presented by tests.
@MainActor
final class IslandNotice {
    static let shared = IslandNotice()
    func confirm(title: String, detail: String, confirmLabel: String, cancelLabel: String) async -> Bool {
        false
    }
}

enum FixtureError: Error { case denied, storage }

@MainActor
final class CountingAuthenticator: BrowserVaultAuthenticator {
    var reasons: [String] = []
    var denied = false
    func authenticate(reason: String) async throws {
        reasons.append(reason)
        if denied { throw FixtureError.denied }
    }
}

@MainActor
final class SuspendingAuthenticator: BrowserVaultAuthenticator {
    var continuation: CheckedContinuation<Void, Never>?
    func authenticate(reason: String) async throws {
        await withCheckedContinuation { continuation = $0 }
    }
}

final class RecordingSecrets: BrowserSecretStore {
    var values: [UUID: String] = [:]
    var reads = 0
    var failWrites = false
    var failRemoves = false
    func set(_ secret: String, for id: UUID) throws {
        if failWrites { throw FixtureError.storage }
        values[id] = secret
    }
    func get(_ id: UUID) throws -> String? { reads += 1; return values[id] }
    func remove(_ id: UUID) throws {
        if failRemoves { throw FixtureError.storage }
        values.removeValue(forKey: id)
    }
}

@main
struct BrowserPasswordVaultChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    @MainActor static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) } catch { checks += 1 }
    }

    @MainActor static func rejectsAsync(_ message: String, _ body: () async throws -> Void) async {
        do { try await body(); preconditionFailure(message) } catch { checks += 1 }
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments[1] == "--render" {
            try render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let index = root.appendingPathComponent("vault/passwords.json")
        let secrets = InMemorySecretStore()
        let vault = BrowserPasswordVault(indexURL: index, secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        check(vault.credentials.isEmpty && vault.storageError == nil, "missing index starts empty")
        let first = try vault.add(origin: "https://EXAMPLE.com:443/login?from=test", username: "alice",
                                  password: "SECRET-FIRST-雪", title: "Example", source: .manual)
        check(first.origin == "https://example.com", "origin normalized, path/query stripped")
        check(first.createdAt == first.updatedAt && first.lastUsedAt == nil, "initial dates")
        check(try secrets.get(first.id) == "SECRET-FIRST-雪", "password stored only in injected store")
        let duplicate = try vault.add(origin: "https://example.com", username: "alice", password: "SECRET-UPDATED",
                                      title: "New title", source: .saved)
        check(duplicate.id == first.id && vault.credentials.count == 1, "add performs upsert")
        check(duplicate.createdAt == first.createdAt && duplicate.source == .manual, "upsert preserves provenance")
        check(try await vault.revealPassword(first.id, reason: "fixture") == "SECRET-UPDATED", "updated password")
        check(vault.credentials[0].lastUsedAt != nil, "reveal records use")
        try vault.update(first.id, password: nil, username: "bob", title: "Renamed")
        check(vault.credentials[0].username == "bob" && vault.credentials[0].title == "Renamed", "metadata update")
        check(try secrets.get(first.id) == "SECRET-UPDATED", "metadata update retains password")
        try vault.update(first.id, password: "SECRET-THIRD", username: nil, title: nil)
        check(try secrets.get(first.id) == "SECRET-THIRD", "explicit password update")
        _ = try vault.add(origin: "https://example.com:8443", username: "port", password: "P-8443", title: "", source: .saved)
        _ = try vault.add(origin: "http://example.com", username: "http", password: "P-HTTP", title: "", source: .saved)
        _ = try vault.add(origin: "https://sub.example.com", username: "sub", password: "P-SUB", title: "", source: .saved)
        _ = try vault.add(origin: "https://example.com.evil.test", username: "suffix", password: "P-SUFFIX", title: "", source: .saved)
        check(vault.matches(origin: "https://EXAMPLE.com/path").count == 2, "same host matches across ports")
        check(vault.matches(origin: "http://example.com").count == 1, "schemes separate")
        check(vault.matches(origin: "https://other.test").isEmpty, "different host has no match")
        check(vault.matches(origin: "file:///tmp/test").isEmpty, "invalid scheme has no match")
        check(vault.matches(origin: "https://sub.example.com").count == 1, "no parent-domain match")
        for invalid in ["", "example.com", "javascript:alert(1)", "file:///test", "https://u:p@example.com",
                        "https://example.com:99999", "https://example.com:0", "https://"] {
            rejects("invalid origin accepted") {
                try vault.add(origin: invalid, username: "x", password: "x", title: "", source: .manual)
            }
        }
        rejects("empty password accepted") {
            try vault.add(origin: "https://example.com", username: "x", password: "", title: "", source: .manual)
        }
        let second = try vault.add(origin: first.origin, username: "second", password: "P-SECOND", title: "", source: .manual)
        rejects("rename collision accepted") { try vault.update(second.id, password: "changed", username: "bob", title: nil) }
        check(try secrets.get(second.id) == "P-SECOND", "collision does not change secret")
        let persisted = try Data(contentsOf: index)
        let text = String(decoding: persisted, as: UTF8.self)
        for value in ["SECRET-FIRST-雪", "SECRET-UPDATED", "SECRET-THIRD", "P-SECOND", "P-8443", "P-HTTP", "P-SUB", "P-SUFFIX"] {
            check(!text.contains(value), "index must not contain password")
        }
        let object = try JSONSerialization.jsonObject(with: persisted) as! [String: Any]
        check(object["schemaVersion"] as? Int == 1, "versioned index")
        let restored = BrowserPasswordVault(indexURL: index, secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        check(restored.credentials == vault.credentials, "roundtrip metadata and associated Source")
        check(try await restored.revealPassword(first.id, reason: "roundtrip") == "SECRET-THIRD", "roundtrip secret id")
        try vault.delete(first.id)
        check(try secrets.get(first.id) == nil, "delete removes secret")
        check(!vault.credentials.contains { $0.id == first.id }, "delete removes metadata")
        check(!String(decoding: try Data(contentsOf: index), as: UTF8.self).contains(first.id.uuidString), "delete persisted")
        rejects("unknown update") { try vault.update(UUID(), password: "x", username: nil, title: nil) }
        rejects("unknown delete") { try vault.delete(UUID()) }
        await rejectsAsync("unknown reveal") { _ = try await vault.revealPassword(UUID(), reason: "missing") }
        try await importAndCSV()
        try await authenticationAndClipboard()
        try await suspendedAuthentication()
        try failureAtomicity(root)
        try exportFilePermissions(root)
        planners(first)
        print("W50 vault fixture passed: \(checks) checks")
    }

    @MainActor static func exportFilePermissions(_ root: URL) throws {
        let url = root.appendingPathComponent("export.csv")
        let csv = Data("origin,username,password,title\r\n".utf8)
        func mode() throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        }
        try BrowserPasswordCSVFileWriter.write(csv, to: url)
        check(try mode() & 0o077 == 0, "new plaintext CSV is owner-only")
        check(try Data(contentsOf: url) == csv, "CSV file contents preserved")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let replacement = Data("replacement".utf8)
        try BrowserPasswordCSVFileWriter.write(replacement, to: url)
        check(try mode() & 0o077 == 0, "replacing an existing 0644 CSV stays owner-only")
        check(try Data(contentsOf: url) == replacement, "CSV replacement is complete")
        check(try !FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".tatwo-password-export-") }, "no plaintext staging file retained")
        let destinationDirectory = root.appendingPathComponent("export-directory")
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        rejects("CSV write over directory accepted") {
            try BrowserPasswordCSVFileWriter.write(csv, to: destinationDirectory)
        }
        check(try !FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".tatwo-password-export-") }, "failed export removes private staging file")
    }

    @MainActor static func importAndCSV() async throws {
        let store = InMemorySecretStore()
        let auth = CountingAuthenticator()
        let vault = BrowserPasswordVault(indexURL: nil, secrets: store, authenticator: auth)
        let counts = try vault.importCredentials([
            ("https://example.com", "a", "one", "A", "Chrome"),
            ("https://EXAMPLE.com:443/path", "a", "two", "B", "Arc"),
            ("https://example.com", "b", "three", "C", "Edge"),
            ("https://example.com", "", "four", "No username", "Brave"),
            ("file:///x", "skip", "five", "", "Arc"),
            ("https://example.com", "skip", "", "", "Arc")
        ])
        check(counts.added == 3 && counts.updated == 1 && counts.skipped == 2, "import counts")
        check(vault.credentials[0].source == .imported(browser: "Chrome"), "import provenance")
        check(try store.get(vault.credentials[0].id) == "two", "import updates existing password")
        check(try vault.importCredentials([]) == (0, 0, 0), "empty import")
        let csvVault = BrowserPasswordVault(indexURL: nil, secrets: InMemorySecretStore(), authenticator: auth)
        _ = try csvVault.add(origin: "https://example.com", username: "a,\"雪",
                             password: "p,\"word\r\nnext", title: "行\n尾", source: .manual)
        let csv = String(decoding: try await csvVault.exportCSV(reason: "csv-check"), as: UTF8.self)
        check(csv == "origin,username,password,title\r\n\"https://example.com\",\"a,\"\"雪\",\"p,\"\"word\r\nnext\",\"行\n尾\"\r\n",
              "CSV quotes commas, quotes, CRLF and Unicode losslessly")
        check(auth.reasons == ["csv-check"], "export authenticates exactly once")
        let empty = BrowserPasswordVault(indexURL: nil, secrets: InMemorySecretStore(), authenticator: auth)
        check(String(decoding: try await empty.exportCSV(reason: "empty"), as: UTF8.self)
              == "origin,username,password,title\r\n", "empty export still authenticates")
        check(auth.reasons.count == 2, "empty export auth count")
    }

    @MainActor static func authenticationAndClipboard() async throws {
        let secrets = RecordingSecrets()
        let auth = CountingAuthenticator()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let vault = BrowserPasswordVault(indexURL: nil, secrets: secrets, authenticator: auth,
                                          pasteboard: board, clipboardLifetime: .milliseconds(80))
        let entry = try vault.add(origin: "https://example.com", username: "alice", password: "COPY-SECRET",
                                  title: "", source: .manual)
        board.setString("unrelated clipboard", forType: .string)
        let initialGeneration = board.changeCount
        let reads = secrets.reads
        auth.denied = true
        await rejectsAsync("denied reveal disclosed") { _ = try await vault.revealPassword(entry.id, reason: "deny") }
        await rejectsAsync("denied copy disclosed") { try await vault.copyPassword(entry.id) }
        await rejectsAsync("denied export disclosed") { _ = try await vault.exportCSV(reason: "deny export") }
        check(auth.reasons.count == 3, "all three disclosure APIs authenticate")
        check(secrets.reads == reads, "denied auth must not access secrets at all")
        check(board.changeCount == initialGeneration, "denied copy does not touch clipboard")
        check(vault.credentials[0].lastUsedAt == nil, "denied auth does not mark used")
        auth.denied = false
        try await vault.copyPassword(entry.id)
        check(board.string(forType: .string) == "COPY-SECRET", "authenticated copy")
        check(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true, "concealed clipboard marker")
        try await Task.sleep(for: .milliseconds(180))
        check(board.string(forType: .string) == nil, "copied secret expires")
        try await vault.copyPassword(entry.id)
        board.clearContents()
        board.setString("newer user content", forType: .string)
        try await Task.sleep(for: .milliseconds(180))
        check(board.string(forType: .string) == "newer user content", "timer leaves later clipboard content untouched")
        secrets.values.removeValue(forKey: entry.id)
        await rejectsAsync("missing secret is not empty password") { _ = try await vault.revealPassword(entry.id, reason: "gone") }
        await rejectsAsync("missing secret must abort export") { _ = try await vault.exportCSV(reason: "gone export") }
    }

    @MainActor static func suspendedAuthentication() async throws {
        let secrets = RecordingSecrets()
        let auth = SuspendingAuthenticator()
        let vault = BrowserPasswordVault(indexURL: nil, secrets: secrets, authenticator: auth)
        let entry = try vault.add(origin: "https://example.com", username: "", password: "WAIT-SECRET",
                                  title: "", source: .manual)
        let request = Task { @MainActor in try await vault.revealPassword(entry.id, reason: "wait") }
        while auth.continuation == nil { await Task.yield() }
        try vault.delete(entry.id)
        let reads = secrets.reads
        auth.continuation?.resume()
        auth.continuation = nil
        await rejectsAsync("deleted during authentication was revealed") { _ = try await request.value }
        check(secrets.reads == reads, "lookup revalidates identity after authentication")
        let next = try vault.add(origin: "https://example.com", username: "", password: "CANCEL-SECRET",
                                 title: "", source: .manual)
        let cancelled = Task { @MainActor in try await vault.revealPassword(next.id, reason: "cancel") }
        while auth.continuation == nil { await Task.yield() }
        cancelled.cancel()
        auth.continuation?.resume()
        auth.continuation = nil
        await rejectsAsync("cancelled authentication disclosed") { _ = try await cancelled.value }
        check(secrets.reads == reads, "cancellation prevents secret reads")
    }

    @MainActor static func failureAtomicity(_ root: URL) throws {
        let badIndex = root.appendingPathComponent("bad-index.json")
        let corrupt = Data("{ broken fixture".utf8)
        try corrupt.write(to: badIndex)
        let secrets = RecordingSecrets()
        let broken = BrowserPasswordVault(indexURL: badIndex, secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        check(broken.storageError != nil, "corrupt index surfaced")
        rejects("corrupt index overwritten") {
            try broken.add(origin: "https://example.com", username: "", password: "x", title: "", source: .manual)
        }
        check(try Data(contentsOf: badIndex) == corrupt && secrets.values.isEmpty, "corrupt index retained")
        try Data("{\"schemaVersion\":99,\"credentials\":[]}".utf8).write(to: badIndex)
        let future = BrowserPasswordVault(indexURL: badIndex, secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        check(future.storageError != nil, "unsupported schema rejected")

        // Turn the parent into a regular file after init to force durable write failures.
        let parent = root.appendingPathComponent("blocked-parent")
        let index = parent.appendingPathComponent("passwords.json")
        let vault = BrowserPasswordVault(indexURL: index, secrets: secrets, authenticator: AlwaysAllowAuthenticator())
        try Data("blocker".utf8).write(to: parent)
        rejects("failed index add reported success") {
            try vault.add(origin: "https://example.com", username: "", password: "x", title: "", source: .manual)
        }
        check(vault.credentials.isEmpty && secrets.values.isEmpty, "failed add rolls back Keychain")
        try FileManager.default.removeItem(at: parent) // This fixture's own generated blocker.
        let entry = try vault.add(origin: "https://example.com", username: "original", password: "old",
                                  title: "", source: .manual)
        let backup = root.appendingPathComponent("preserved-index")
        try FileManager.default.moveItem(at: parent, to: backup)
        try Data("blocker".utf8).write(to: parent)
        rejects("failed update reported success") { try vault.update(entry.id, password: "new", username: "new", title: nil) }
        check(secrets.values[entry.id] == "old" && vault.credentials[0].username == "original", "failed update rolls back")
        rejects("failed delete reported success") { try vault.delete(entry.id) }
        check(secrets.values[entry.id] == "old" && vault.credentials.count == 1, "failed delete rolls back")
        secrets.failWrites = true
        rejects("failed Keychain update accepted") { try vault.update(entry.id, password: "new", username: nil, title: nil) }
        check(secrets.values[entry.id] == "old", "Keychain failure retains old state")
        secrets.failWrites = false
        secrets.failRemoves = true
        rejects("failed Keychain delete accepted") { try vault.delete(entry.id) }
        check(vault.credentials.count == 1, "failed Keychain delete retains index")
        rejects("failed add rollback accepted") {
            try vault.add(origin: "https://other.test", username: "", password: "x", title: "", source: .manual)
        }
        check(vault.storageError != nil, "rollback failure locks further mutations")
        rejects("mutation permitted after rollback failure") {
            try vault.update(entry.id, password: nil, username: nil, title: "changed")
        }
    }

    @MainActor static func planners(_ credential: BrowserCredential) {
        func form(password: Bool = true, origin: String? = "https://example.com", http: Bool = false,
                  cross: Bool = false, idn: Bool = false, mixed: Bool = false, confusable: Bool = false)
            -> EmbeddedBrowserPasswordFormMetadata {
            .init(hasPasswordField: password, actionOrigin: origin, isHTTP: http, isCrossOrigin: cross,
                  hasIDNHost: idn, hasMixedScriptHost: mixed, hasConfusableHost: confusable)
        }
        check(BrowserPasswordAutofillPlanner.decision(form: form(), matches: [credential]) == .offerFill([credential]),
              "safe form offers a user-initiated fill")
        check(BrowserPasswordAutofillPlanner.decision(form: form(), matches: []) == .none, "empty matches")
        for unsafe in [form(password: false), form(origin: nil), form(origin: "file:///x"),
                       form(origin: "http://example.com"), form(http: true), form(cross: true), form(idn: true),
                       form(mixed: true), form(confusable: true), form(origin: "https://other.test")] {
            check(BrowserPasswordAutofillPlanner.decision(form: unsafe, matches: [credential]) == .none,
                  "unsafe form must not offer credentials")
        }
        var other = credential
        other.origin = "https://example.com.evil.test"
        check(BrowserPasswordAutofillPlanner.decision(form: form(), matches: [other, credential]) == .offerFill([credential]),
              "planner filters unrelated matches")
        typealias Save = BrowserPasswordSavePlanner
        let existing: [Save.ExistingCredential] = [(credential, "stored")]
        check(Save.decision(origin: "https://example.com", username: credential.username,
                            password: "stored", existing: existing) == .none, "same secret is no-op")
        check(Save.decision(origin: "https://EXAMPLE.com:443/login", username: credential.username,
                            password: "changed", existing: existing) == .askUpdate(credential), "changed secret asks update")
        check(Save.decision(origin: "https://example.com", username: "different",
                            password: "stored", existing: existing) == .askSave, "different username asks save")
        check(Save.decision(origin: "https://example.com:8443", username: credential.username,
                            password: "stored", existing: existing) == .askSave, "save identity includes port")
        check(Save.decision(origin: "http://example.com", username: credential.username,
                            password: "stored", existing: existing) == .askSave, "save separates scheme")
        check(Save.decision(origin: "https://example.com", username: "", password: "new", existing: []) == .askSave,
              "password-only forms allowed")
        check(Save.decision(origin: "https://example.com", username: "", password: "", existing: []) == .none,
              "empty password not offered")
        check(Save.decision(origin: "file:///x", username: "", password: "new", existing: []) == .none,
              "invalid save origin rejected")
    }

    @MainActor static func render(to root: URL) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = BrowserPasswordVault(indexURL: nil, secrets: InMemorySecretStore(), authenticator: AlwaysAllowAuthenticator())
        for (origin, username) in [("https://example.com", "alice@example.com"),
                                    ("https://very-long-site-name.example.com", "很長的使用者名稱@example.com")] {
            try vault.add(origin: origin, username: username, password: "SYNTHETIC-NOT-REVEALED", title: "", source: .manual)
        }
        for (name, store) in [("populated", vault),
                               ("empty", BrowserPasswordVault(indexURL: nil, secrets: InMemorySecretStore(),
                                                               authenticator: AlwaysAllowAuthenticator()))] {
            let host = NSHostingView(rootView: ScrollView {
                BrowserPasswordsSettingsView(vault: store, aiVault: BrowserAIVault(indexURL: nil,
                    secrets: InMemorySecretStore(), authenticator: AlwaysAllowAuthenticator())).padding(22)
            }.frame(width: 579, height: 560).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 579, height: 560),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                preconditionFailure("native rendering unavailable")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("\(name).png"))
            window.close()
        }
        print("W50 isolated settings render: populated/empty, 579x560; synthetic data, no real Keychain/UI acceptance")
    }
}
