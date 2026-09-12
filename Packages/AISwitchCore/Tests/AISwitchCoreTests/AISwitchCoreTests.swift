import XCTest
import AISwitchCore
import AISwitchProviders

final class AISwitchCoreTests: XCTestCase {
    func testDefaultProvidersExposeCodexClaudeAndAPI() async {
        let registry = ProviderRegistry()
        let providers = await registry.providers()
        XCTAssertEqual(providers.map(\.id), ["codex", "claude", "api"])
    }

    func testCodexProviderAddsTatwoOSModesWithoutRemovingExistingModels() async throws {
        let models = try await CodexProvider().models()
        let ids = Set(models.map(\.id))
        XCTAssertTrue(ids.contains("gpt-5.4"))
        XCTAssertTrue(ids.contains("gpt-5.4-mini"))
        XCTAssertTrue(ids.contains("tatwo-os-s"))
        XCTAssertTrue(ids.contains("tatwo-os-m"))
        XCTAssertTrue(ids.contains("tatwo-os-l"))
        XCTAssertTrue(ids.contains("tatwo-os-xl"))
        XCTAssertEqual(
            models.first { $0.id == "tatwo-os-xl" }?.displayName,
            "TATWO ULTRAWORK XL"
        )
    }

    func testBindingDoesNotExposeSecrets() async throws {
        let registry = ProviderRegistry()
        let binding = try await registry.createBinding(clientID: "demo", providerID: "codex", modelID: "gpt-5.4", scopes: ["model.invoke"])
        XCTAssertEqual(binding.clientID, "demo")
        XCTAssertEqual(binding.providerID, "codex")
        XCTAssertNil(binding.expiresAt)
    }

    func testCodexV3ImportCopiesAuthButDoesNotInheritV3RuntimeParameters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v3Base = root.appendingPathComponent("v3", isDirectory: true)
        let v4Base = root.appendingPathComponent("v4", isDirectory: true)
        let accountDir = v3Base.appendingPathComponent("accounts/demo@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)

        let registry = """
        {
          "version": 3,
          "active_email": "demo@example.com",
          "settings": {
            "auto_switch_enabled": true,
            "default_threshold_percent": 5,
            "monitor_interval_seconds": 120,
            "batch_relogin_mode": "recreate"
          },
          "accounts": [
            {
              "id": "demo@example.com",
              "email": "demo@example.com",
              "plan": "plus",
              "auth_mode": "chatgpt",
              "account_id": "account",
              "added_at": 1,
              "updated_at": 1,
              "threshold_override_percent": 99,
              "requires_relogin": true,
              "last_usage_message": "剩餘 42%"
            }
          ]
        }
        """
        try registry.data(using: .utf8)!.write(to: v3Base.appendingPathComponent("registry.json"))
        try Data(#"{"tokens":{"access_token":"secret"}}"#.utf8).write(to: accountDir.appendingPathComponent("auth.json"))

        let store = CodexV3ImportStore(v3BaseURL: v3Base, v4BaseURL: v4Base)
        let summary = try store.importFromV3()
        let snapshot = try store.loadSnapshot()

        XCTAssertEqual(summary.accountCount, 1)
        XCTAssertEqual(summary.copiedAuthCount, 1)
        XCTAssertFalse(snapshot.settings.autoSwitchEnabled)
        XCTAssertEqual(snapshot.settings.defaultThresholdPercent, 4)
        XCTAssertEqual(snapshot.settings.monitorIntervalSeconds, 60)
        XCTAssertEqual(snapshot.settings.batchReloginMode, "inplace")
        XCTAssertEqual(snapshot.accounts.first?.maskedEmail, "de********@e****.com")
        XCTAssertNil(snapshot.accounts.first?.thresholdOverridePercent)
        XCTAssertEqual(snapshot.accounts.first?.effectiveThresholdPercent, 4)
        XCTAssertNil(snapshot.accounts.first?.remainingPercent)
        XCTAssertFalse(snapshot.accounts.first?.requiresRelogin ?? true)
        XCTAssertFalse(snapshot.accounts.first?.v3RequiresRelogin ?? true)
        XCTAssertFalse(snapshot.accounts.first?.isActive ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v4Base.appendingPathComponent("accounts/demo@example.com/auth.json").path))
    }

    func testCodexV3ReimportPreservesOnlyExistingV4OwnedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v3Base = root.appendingPathComponent("v3", isDirectory: true)
        let v4Base = root.appendingPathComponent("v4", isDirectory: true)
        let v3AccountDir = v3Base.appendingPathComponent("accounts/demo@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: v3AccountDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v4Base, withIntermediateDirectories: true)

        let existingV4 = """
        {
          "version": 4,
          "active_email": "demo@example.com",
          "settings": {
            "auto_switch_enabled": true,
            "default_threshold_percent": 7,
            "monitor_interval_seconds": 45,
            "batch_relogin_mode": "recreate"
          },
          "accounts": [
            {
              "id": "demo@example.com",
              "email": "demo@example.com",
              "plan": "pro",
              "account_id": "v4-account",
              "threshold_override_percent": 8,
              "requires_relogin": true,
              "last_usage_message": "剩餘 1%"
            }
          ]
        }
        """
        try existingV4.data(using: .utf8)!.write(to: v4Base.appendingPathComponent("registry.json"))

        let v3Registry = """
        {
          "version": 3,
          "active_email": "other@example.com",
          "settings": {
            "auto_switch_enabled": false,
            "default_threshold_percent": 99,
            "monitor_interval_seconds": 999,
            "batch_relogin_mode": "inplace"
          },
          "accounts": [
            {
              "id": "demo@example.com",
              "email": "demo@example.com",
              "plan": "plus",
              "account_id": "v3-account",
              "threshold_override_percent": 77,
              "requires_relogin": true,
              "last_usage_message": "剩餘 2%"
            }
          ]
        }
        """
        try v3Registry.data(using: .utf8)!.write(to: v3Base.appendingPathComponent("registry.json"))
        try Data(#"{"tokens":{"access_token":"secret"}}"#.utf8).write(to: v3AccountDir.appendingPathComponent("auth.json"))

        let store = CodexV3ImportStore(v3BaseURL: v3Base, v4BaseURL: v4Base)
        _ = try store.importFromV3()
        let snapshot = try store.loadSnapshot()

        XCTAssertTrue(snapshot.settings.autoSwitchEnabled)
        XCTAssertEqual(snapshot.settings.defaultThresholdPercent, 7)
        XCTAssertEqual(snapshot.settings.monitorIntervalSeconds, 45)
        XCTAssertEqual(snapshot.settings.batchReloginMode, "recreate")
        XCTAssertEqual(snapshot.accounts.first?.thresholdOverridePercent, 8)
        XCTAssertEqual(snapshot.accounts.first?.effectiveThresholdPercent, 8)
        XCTAssertFalse(snapshot.accounts.first?.requiresRelogin ?? true)
        XCTAssertNil(snapshot.accounts.first?.remainingPercent)
        XCTAssertTrue(snapshot.accounts.first?.isActive ?? false)
    }

    func testLegacyImportedV4RegistryIsSanitizedOnRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v4Base = root.appendingPathComponent("v4", isDirectory: true)
        let accountDir = v4Base.appendingPathComponent("accounts/demo@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)

        let contaminatedRegistry = """
        {
          "version": 3,
          "active_email": "demo@example.com",
          "settings": {
            "auto_switch_enabled": true,
            "default_threshold_percent": 88,
            "monitor_interval_seconds": 999,
            "batch_relogin_mode": "recreate"
          },
          "accounts": [
            {
              "id": "legacy-id",
              "email": "demo@example.com",
              "plan": "plus",
              "account_id": "account",
              "threshold_override_percent": 66,
              "requires_relogin": true,
              "last_usage_message": "剩餘 1%"
            }
          ]
        }
        """
        try contaminatedRegistry.data(using: .utf8)!.write(to: v4Base.appendingPathComponent("registry.json"))
        try Data(#"{"tokens":{"access_token":"secret"}}"#.utf8).write(to: accountDir.appendingPathComponent("auth.json"))

        let store = CodexV3ImportStore(v3BaseURL: root.appendingPathComponent("v3", isDirectory: true), v4BaseURL: v4Base)
        let snapshot = try store.loadSnapshot()
        let persisted = try String(contentsOf: v4Base.appendingPathComponent("registry.json"), encoding: .utf8)

        XCTAssertFalse(snapshot.settings.autoSwitchEnabled)
        XCTAssertEqual(snapshot.settings.defaultThresholdPercent, 4)
        XCTAssertEqual(snapshot.settings.monitorIntervalSeconds, 60)
        XCTAssertEqual(snapshot.settings.batchReloginMode, "inplace")
        XCTAssertEqual(snapshot.accounts.first?.id, "demo@example.com")
        XCTAssertNil(snapshot.accounts.first?.thresholdOverridePercent)
        XCTAssertFalse(snapshot.accounts.first?.requiresRelogin ?? true)
        XCTAssertNil(snapshot.accounts.first?.remainingPercent)
        XCTAssertTrue(persisted.contains(#""version" : 4"#))
        XCTAssertFalse(persisted.contains("last_usage_message"))
    }

    func testCodexLoginStoresFreshAuthInV4Runtime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCodex = root.appendingPathComponent("codex")
        let v4Base = root.appendingPathComponent("v4", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let token = Self.jwt(payload: [
            "email": "fresh@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus"
            ]
        ])
        let script = """
        #!/bin/sh
        mkdir -p "$CODEX_HOME"
        cat > "$CODEX_HOME/auth.json" <<'JSON'
        {"auth_mode":"chatgpt","tokens":{"access_token":"\(token)","account_id":"account-fresh","id_token":"\(token)"}}
        JSON
        """
        try script.data(using: .utf8)!.write(to: fakeCodex)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: fakeCodex.path)

        setenv("AISWITCH_CODEX", fakeCodex.path, 1)
        defer { unsetenv("AISWITCH_CODEX") }

        let store = CodexV3ImportStore(v3BaseURL: root.appendingPathComponent("v3", isDirectory: true), v4BaseURL: v4Base)
        let result = try await store.addAccount()
        let snapshot = try store.loadSnapshot()

        XCTAssertTrue(result.ok)
        XCTAssertEqual(snapshot.accountCount, 1)
        XCTAssertEqual(snapshot.accounts.first?.maskedEmail, "fr********@e****.com")
        XCTAssertEqual(snapshot.accounts.first?.plan, "PLUS")
        XCTAssertFalse(snapshot.accounts.first?.requiresRelogin ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v4Base.appendingPathComponent("accounts/fresh@example.com/auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v3/registry.json").path))
    }

    func testCodexSwitchCopiesAuthAndCachesOnlyActiveAccountInV4Registry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let v3Base = root.appendingPathComponent("v3", isDirectory: true)
        let v4Base = root.appendingPathComponent("v4", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let accountDir = v3Base.appendingPathComponent("accounts/demo@example.com", isDirectory: true)
        try FileManager.default.createDirectory(at: accountDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

        let registry = """
        {
          "version": 3,
          "settings": {
            "auto_switch_enabled": false,
            "default_threshold_percent": 4,
            "monitor_interval_seconds": 60,
            "batch_relogin_mode": "inplace"
          },
          "accounts": [
            {
              "id": "demo@example.com",
              "email": "demo@example.com",
              "plan": "plus",
              "auth_mode": "chatgpt",
              "account_id": "account",
              "added_at": 1,
              "updated_at": 1,
              "requires_relogin": false,
              "last_usage_message": "剩餘 88%"
            }
          ]
        }
        """
        try registry.data(using: .utf8)!.write(to: v3Base.appendingPathComponent("registry.json"))
        try Data(#"{"tokens":{"access_token":"selected"}}"#.utf8).write(to: accountDir.appendingPathComponent("auth.json"))
        try Data(#"{"tokens":{"access_token":"previous"}}"#.utf8).write(to: codexHome.appendingPathComponent("auth.json"))

        let store = CodexV3ImportStore(v3BaseURL: v3Base, v4BaseURL: v4Base, codexHomeURL: codexHome)
        _ = try store.importFromV3()
        let result = try store.switchAccount(email: "demo@example.com")
        let snapshot = try store.loadSnapshot(resolveActiveEmail: false)
        let switchedAuth = try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8)
        let backupAuth = try String(contentsOf: codexHome.appendingPathComponent("auth.json.bak"), encoding: .utf8)

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.email, "demo@example.com")
        XCTAssertTrue(FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path))
        XCTAssertTrue(switchedAuth.contains("selected"))
        XCTAssertTrue(backupAuth.contains("previous"))
        XCTAssertTrue(snapshot.accounts.first?.isActive ?? false)
        XCTAssertNil(snapshot.accounts.first?.remainingPercent)
    }

    private static func jwt(payload: [String: Any]) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [
            Data(header.utf8).base64URLEncodedString(),
            payloadData.base64URLEncodedString(),
            "signature"
        ].joined(separator: ".")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
