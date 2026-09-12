import Foundation
import XCTest
@testable import Tatwo2

final class NativeStagingIsolationTests: XCTestCase {
    private func environment() throws -> [String: String] {
        // Retained test artifacts; no host auth, config, or user files are used.
        // Foundation's temporaryDirectory may ignore the passed TMPDIR and
        // shorten /private/var to /var. Use the runner's explicit owned root;
        // never silently fall back to the user's system temporary directory.
        guard let temporaryPath = ProcessInfo.processInfo.environment["TMPDIR"],
              temporaryPath.hasPrefix("/") else {
            throw NSError(domain: "NativeStagingIsolationTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Set an explicit candidate-owned TMPDIR"])
        }
        let root = URL(fileURLWithPath: temporaryPath, isDirectory: true)
            .appendingPathComponent("tsi-\(UUID().uuidString)", isDirectory: true)
        guard root.appendingPathComponent("browser.sock").path.utf8.count < 104 else {
            throw NSError(domain: "NativeStagingIsolationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Set a candidate-owned short TMPDIR for socket-path tests"])
        }
        for subdirectory in ["home", "live", "engines/codex", "engines/claude", "resources"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(subdirectory), withIntermediateDirectories: true)
        }
        return [
            "TATWO_STAGING_ROOT": root.path,
            "TATWO_STAGING_SCRATCH_HOME": root.appendingPathComponent("home").path,
            "HOME": root.appendingPathComponent("home").path,
            "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "TATWO2_LIVE_ROOT": root.appendingPathComponent("live").path,
            "TATWO2_ENGINES_ROOT": root.appendingPathComponent("engines").path,
            "CODEX_HOME": root.appendingPathComponent("engines/codex").path,
            "TATWO2_CODEX_SOURCE_HOME": root.appendingPathComponent("engines/codex").path,
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("engines/claude").path,
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": root.appendingPathComponent("engines/claude").path,
            "TATWO2_OS_SOCKET": root.appendingPathComponent("os.sock").path,
            "TATWO2_BROWSER_SOCKET": root.appendingPathComponent("browser.sock").path,
            "TATWO2_OS_ROOT": root.appendingPathComponent("os").path,
            "TATWO2_DOCS_ROOT": root.appendingPathComponent("docs").path,
            "TATWO2_OS_UPSTREAM_PATH": root.appendingPathComponent("docs/os-upstream.md").path,
            "TATWO2_SKILLET_PATH": root.appendingPathComponent("os/skillet.md").path,
            "TATWO2_RESOURCES_ROOT": root.appendingPathComponent("resources").path,
            "PATH": "/usr/bin:/bin",
        ]
    }

    func testProductionBehaviorAndEmptyMarkerRemainUnchanged() {
        let env = ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "existing"]
        XCTAssertFalse(NativeStagingIsolation.isEnabled(env))
        XCTAssertNil(NativeStagingIsolation.validationError(env))
        XCTAssertFalse(NativeStagingIsolation.isEnabled(["TATWO_STAGING_SCRATCH_HOME": " \n"]))
        XCTAssertEqual(NativeStagingIsolation.sidecarClaudeNamespace(
            environment: env, configDirectory: "/chosen"), "")
        XCTAssertEqual(NativeStagingIsolation.isolateClaude(
            env, configDirectory: "/chosen")["CLAUDE_SECURESTORAGE_CONFIG_DIR"], "existing")
    }

    func testStagingRequiresExplicitConsistentContainedHomes() throws {
        let env = try environment()
        XCTAssertNil(NativeStagingIsolation.validationError(env))
        for key in ["TATWO_STAGING_ROOT", "HOME", "TATWO2_LIVE_ROOT", "TATWO2_ENGINES_ROOT",
                    "CODEX_HOME", "TATWO2_CODEX_SOURCE_HOME", "CLAUDE_CONFIG_DIR",
                    "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CFFIXED_USER_HOME",
                    "TATWO2_OS_SOCKET", "TATWO2_BROWSER_SOCKET", "TATWO2_OS_ROOT",
                    "TATWO2_DOCS_ROOT", "TATWO2_OS_UPSTREAM_PATH", "TATWO2_SKILLET_PATH"] {
            var missing = env
            missing.removeValue(forKey: key)
            XCTAssertNotNil(NativeStagingIsolation.validationError(missing), key)
        }
        var escaped = env
        escaped["TATWO2_CODEX_SOURCE_HOME"] = "/outside"
        XCTAssertNotNil(NativeStagingIsolation.validationError(escaped))
        var inconsistent = env
        inconsistent["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = env["HOME"]
        XCTAssertNotNil(NativeStagingIsolation.validationError(inconsistent))
        var sharedSocket = env
        sharedSocket["TATWO2_BROWSER_SOCKET"] = env["TATWO2_OS_SOCKET"]
        XCTAssertNotNil(NativeStagingIsolation.validationError(sharedSocket))
        sharedSocket["TATWO2_BROWSER_SOCKET"] = env["TATWO_STAGING_ROOT"]! + "/./os.sock"
        XCTAssertNotNil(NativeStagingIsolation.validationError(sharedSocket))
    }

    func testStagingOverridesEmptySharedClaudeNamespace() throws {
        var env = try environment()
        let config = env["CLAUDE_CONFIG_DIR"]!
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
        XCTAssertEqual(NativeStagingIsolation.sidecarClaudeNamespace(
            environment: env, configDirectory: config), config)
        XCTAssertEqual(NativeStagingIsolation.isolateClaude(
            env, configDirectory: config)["CLAUDE_SECURESTORAGE_CONFIG_DIR"], config)
    }

    func testMissingSocketLeavesWithAliasedParentsCannotShareEndpoint() throws {
        var env = try environment()
        let root = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!)
        let alias = root.appendingPathComponent("a")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: root.appendingPathComponent("live"))
        env["TATWO2_OS_SOCKET"] = root.appendingPathComponent("live/x.sock").path
        env["TATWO2_BROWSER_SOCKET"] = alias.appendingPathComponent("x.sock").path
        XCTAssertNotNil(NativeStagingIsolation.validationError(env))
        env["TATWO2_BROWSER_SOCKET"] = alias.appendingPathComponent("y.sock").path
        XCTAssertNil(NativeStagingIsolation.validationError(env))
    }

    func testReadBoundaryRejectsSiblingAndSymlinkEscape() throws {
        let env = try environment()
        let root = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!)
        let allowed = root.appendingPathComponent("engines")
        let outside = root.appendingPathComponent("resources")
        XCTAssertTrue(NativeStagingIsolation.allowsRead(allowed.appendingPathComponent("codex/config.toml"), within: allowed))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(root.appendingPathComponent("engines-other/config.toml"), within: allowed))
        let link = allowed.appendingPathComponent("escaped")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertFalse(NativeStagingIsolation.allowsRead(link.appendingPathComponent("config.toml"), within: allowed))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(link.appendingPathComponent("missing/config.toml"), within: allowed))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(link, within: link))
    }

    func testReadBoundaryRetainsContainedLinksAndRejectsUnresolvableParents() throws {
        let env = try environment()
        let root = URL(fileURLWithPath: env["TATWO2_ENGINES_ROOT"]!)
        let link = root.appendingPathComponent("inside")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("codex"))
        XCTAssertTrue(NativeStagingIsolation.allowsRead(
            link.appendingPathComponent("missing/config.toml"), within: root))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(
            link.appendingPathComponent("config.toml"), within: link))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(
            URL(fileURLWithPath: link.path + "/../claude/config.toml"), within: root))
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
        XCTAssertFalse(NativeStagingIsolation.allowsRead(
            dangling.appendingPathComponent("config.toml"), within: root))
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)
        XCTAssertFalse(NativeStagingIsolation.allowsRead(
            loop.appendingPathComponent("config.toml"), within: root))
        let regular = root.appendingPathComponent("not-a-directory")
        try "synthetic".write(to: regular, atomically: true, encoding: .utf8)
        XCTAssertFalse(NativeStagingIsolation.allowsRead(
            regular.appendingPathComponent("config.toml"), within: root))
    }

    func testEmptyStagingDoesNotListHostPluginsOrFixtures() throws {
        let env = try environment()
        XCTAssertEqual(PluginsSource.mcpNames(for: .codex, environment: env), [])
        XCTAssertEqual(PluginsSource.mcpNames(for: .claude, environment: env), [])
        XCTAssertTrue(PluginsSource.scanNow(environment: env).isEmpty)
    }

    func testPluginDiscoveryUsesOnlyInjectedEngineRoots() throws {
        let env = try environment()
        let codex = URL(fileURLWithPath: env["CODEX_HOME"]!)
        let claude = URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"]!)
        try "[mcp_servers.candidate_only]\ncommand = \"unused\"\n"
            .write(to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "{\"mcpServers\":{\"candidate_claude\":{\"command\":\"unused\"}}}"
            .write(to: claude.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let skill = codex.appendingPathComponent("skills/candidate-skill")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: candidate-skill\ndescription: test only\n---\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // A decoy home config must not be merged into the selected engine home.
        try "{\"mcpServers\":{\"home_decoy\":{\"command\":\"unused\"}}}"
            .write(to: URL(fileURLWithPath: env["HOME"]!).appendingPathComponent(".claude.json"),
                   atomically: true, encoding: .utf8)
        XCTAssertEqual(PluginsSource.mcpNames(for: .codex, environment: env), ["candidate_only"])
        XCTAssertEqual(PluginsSource.mcpNames(for: .claude, environment: env), ["candidate_claude"])
        XCTAssertEqual(Set(PluginsSource.scanNow(environment: env).map(\.name)),
                       Set(["candidate_only", "candidate_claude", "candidate-skill"]))
    }

    func testConfigSymlinkOutsideEngineRootIsNotRead() throws {
        let env = try environment()
        let root = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!)
        let decoy = root.appendingPathComponent("resources/decoy.toml")
        try "[mcp_servers.do_not_read]\n".write(to: decoy, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: env["CODEX_HOME"]!).appendingPathComponent("config.toml"),
            withDestinationURL: decoy)
        XCTAssertEqual(PluginsSource.mcpNames(for: .codex, environment: env), [])
    }

    func testInvalidStagingDoesNotScanOrStartStatus() throws {
        let env = try environment()
        let (script, record) = try statusRecorder(environment: env)
        var invalid = env
        invalid.removeValue(forKey: "TATWO2_LIVE_ROOT")
        XCTAssertTrue(PluginsSource.scanNow(environment: invalid).isEmpty)
        XCTAssertTrue(PluginsSource.load(environment: invalid).isEmpty)
        XCTAssertNil(PluginsSource.sidecarMCPConfig(engine: .claude, stored: [], environment: invalid))
        XCTAssertNil(EngineLogin.claudeCLIStatus(
            executable: script.path, configDir: env["CLAUDE_CONFIG_DIR"]!, environment: invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    private func statusRecorder(environment: [String: String]) throws -> (URL, URL) {
        let root = URL(fileURLWithPath: environment["TATWO_STAGING_ROOT"]!)
        let script = root.appendingPathComponent("invocation-probe")
        let record = root.appendingPathComponent("invoked")
        try """
        #!/bin/sh
        printf 'invoked' > '\(record.path)'
        printf '%s\\n' '{"loggedIn":true}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, record)
    }

    func testMismatchedEffectiveConfigCannotStartStatus() throws {
        let env = try environment()
        let (script, record) = try statusRecorder(environment: env)
        XCTAssertNil(EngineLogin.claudeCLIStatus(
            executable: script.path, configDir: env["HOME"]!, environment: env))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testMismatchedInjectedPathsDoNotCreateEngineHomes() throws {
        let env = try environment()
        var wrong = env
        let otherEngines = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!).appendingPathComponent("wrong-engines")
        wrong["TATWO2_ENGINES_ROOT"] = otherEngines.path
        let login = EngineLogin(paths: EnginePaths(environment: wrong), environment: env, openURL: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherEngines.path))
        XCTAssertFalse(login.status(for: .claude).isLoggedIn)
        XCTAssertTrue(login.status(for: .claude).detail.contains("inconsistent"))
    }

    func testClaudeStatusUsesPassedEnvironmentAndStagingNamespace() throws {
        var env = try environment()
        env["NATIVE_STAGING_PROBE"] = "provided"
        let root = URL(fileURLWithPath: env["TATWO_STAGING_ROOT"]!)
        let script = root.appendingPathComponent("status-probe")
        let report = root.appendingPathComponent("status-probe-booleans")
        try """
        #!/bin/sh
        provided=false; namespace=false; pwdString=false; pwdIdentity=false
        [ "$NATIVE_STAGING_PROBE" = "provided" ] && provided=true
        [ "$CLAUDE_SECURESTORAGE_CONFIG_DIR" = "$CLAUDE_CONFIG_DIR" ] && namespace=true
        [ "$PWD" = "$HOME" ] && pwdString=true
        [ . -ef "$HOME" ] && pwdIdentity=true
        printf 'provided=%s namespace=%s pwdString=%s pwdIdentity=%s\\n' \
            "$provided" "$namespace" "$pwdString" "$pwdIdentity" > '\(report.path)'
        if [ "$NATIVE_STAGING_PROBE" = "provided" ] &&
           [ "$CLAUDE_SECURESTORAGE_CONFIG_DIR" = "$CLAUDE_CONFIG_DIR" ] &&
           [ "$PWD" = "$HOME" ]; then
            printf '%s\\n' '{"loggedIn":true,"email":"synthetic@example.invalid"}'
        else
            printf '%s\\n' '{"loggedIn":false}'
        fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = ProcessInfo.processInfo.systemUptime
        let result = EngineLogin.claudeCLIStatus(
            executable: script.path, configDir: env["CLAUDE_CONFIG_DIR"]!, environment: env)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let booleans = (try? String(contentsOf: report, encoding: .utf8)) ?? "probe_report_missing"
        // Log the bounded status call before XCTest performs failure symbolication.
        print("NativeStagingIsolation synthetic status seconds=\(elapsed) \(booleans)")
        XCTAssertEqual(result?.loggedIn, true)
        XCTAssertEqual(result?.email, "synthetic@example.invalid")
    }
}
