import Foundation
import XCTest

@testable import TatwoUltraworkMac

/// 2026-08-21「登入一直失效」根治的守門測試：profile 自有 setup-token
/// 憑證的載入與注入行為（病理見 ChatNativeClaudeProfileToken 註解）。
final class ChatNativeClaudeProfileTokenTests: XCTestCase {
    private func makeProfileDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testLoadTrimsWhitespaceAndRejectsEmptyOrMissing() throws {
        let dir = try makeProfileDir()
        XCTAssertNil(ChatNativeClaudeProfileToken.load(profileHomeURL: dir))

        let url = dir.appendingPathComponent(
            ChatNativeClaudeProfileToken.filename)
        try "  sk-ant-oat-demo \n".write(
            to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            ChatNativeClaudeProfileToken.load(profileHomeURL: dir),
            "sk-ant-oat-demo")

        try "   \n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(
            ChatNativeClaudeProfileToken.load(profileHomeURL: dir),
            "空白檔不得注入空 token")
    }

    func testInjectSetsEnvOnlyWhenProfileTokenExists() throws {
        let dir = try makeProfileDir()
        var env = ["HOME": dir.path]
        ChatNativeClaudeProfileToken.inject(
            into: &env, profileHomeURL: dir)
        XCTAssertNil(
            env["CLAUDE_CODE_OAUTH_TOKEN"],
            "無 token 檔必須維持原行為，不得注入任何值")

        try "sk-ant-oat-demo".write(
            to: dir.appendingPathComponent(
                ChatNativeClaudeProfileToken.filename),
            atomically: true, encoding: .utf8)
        ChatNativeClaudeProfileToken.inject(
            into: &env, profileHomeURL: dir)
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat-demo")
    }

    /// scrub 剝掉外部繼承的同名變數之後，注入才有意義——順序契約。
    func testScrubThenInjectYieldsProfileOwnedCredential() throws {
        let dir = try makeProfileDir()
        try "profile-token".write(
            to: dir.appendingPathComponent(
                ChatNativeClaudeProfileToken.filename),
            atomically: true, encoding: .utf8)
        var env = ChatNativeSubscriptionEnvironment.scrubbed(
            ["CLAUDE_CODE_OAUTH_TOKEN": "ambient-leak", "PATH": "/usr/bin"])
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
        ChatNativeClaudeProfileToken.inject(
            into: &env, profileHomeURL: dir)
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "profile-token")
    }

    /// 三個 claude 啟動面（帳號 runner／chat transport／governed runner）
    /// 都必須經過注入；chat/governed 已收斂到 ClaudeSpawnAuthority 單一真值，
    /// 帳號 runner 仍直接使用 App 相容 wrapper。
    func testAllClaudeLaunchSurfacesInjectProfileToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TatwoUltraworkMac")
        let runtime = try String(contentsOf: root.appendingPathComponent(
            "ChatNativeClaudeSubscriptionRuntime.swift"))
        XCTAssertEqual(
            runtime.components(
                separatedBy: "ChatNativeClaudeProfileToken.inject(")
                .count - 1, 1,
            "帳號 runner 必須直接注入 profile token")
        XCTAssertTrue(
            runtime.contains("ClaudeSpawnAuthority("),
            "chat transport 必須由 ClaudeSpawnAuthority 建立")
        XCTAssertTrue(
            runtime.contains("ClaudeSpawnAuthority.injectProfileToken("),
            "chat transport 的訂閱預檢也必須使用同一 token 真值")
        let governed = try String(contentsOf: root.appendingPathComponent(
            "GovernedDevSessionRunner.swift"))
        XCTAssertTrue(
            governed.contains("ClaudeSpawnAuthority("),
            "governed dev runner 的 claude lane 必須由 authority 注入")
    }
}
