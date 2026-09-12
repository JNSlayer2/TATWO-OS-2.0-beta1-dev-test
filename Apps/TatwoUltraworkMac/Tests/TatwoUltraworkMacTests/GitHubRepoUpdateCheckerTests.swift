import Foundation
import TatwoUltraworkCore
import XCTest
@testable import TatwoUltraworkMac

final class GitHubRepoUpdateCheckerTests: XCTestCase {
    func testCheckReportsCurrentThenRemoteUpdateUsingRealGitRepositories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-github-check-\(UUID().uuidString)", isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let updater = root.appendingPathComponent("updater", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init", "--bare", remote.path], cwd: root)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try runGit(["init"], cwd: local)
        try configureGitUser(cwd: local)
        try "first\n".write(
            to: local.appendingPathComponent("version.txt"),
            atomically: true,
            encoding: .utf8)
        try runGit(["add", "version.txt"], cwd: local)
        try runGit(["commit", "-m", "first"], cwd: local)
        try runGit(["remote", "add", "origin", remote.path], cwd: local)
        try runGit(["push", "-u", "origin", "HEAD"], cwd: local)

        let current = await GitHubRepoUpdateChecker.check(
            url: remote.path,
            workdir: local.path)
        XCTAssertEqual(current, .upToDate)

        try runGit(["clone", remote.path, updater.path], cwd: root)
        try configureGitUser(cwd: updater)
        try "second\n".write(
            to: updater.appendingPathComponent("version.txt"),
            atomically: true,
            encoding: .utf8)
        try runGit(["add", "version.txt"], cwd: updater)
        try runGit(["commit", "-m", "second"], cwd: updater)
        try runGit(["push"], cwd: updater)

        let updated = await GitHubRepoUpdateChecker.check(
            url: remote.path,
            workdir: local.path)
        XCTAssertEqual(updated, .updateAvailable)
    }

    func testAuthenticationFailureIsReportedWithoutExposingRawGitError() {
        let result = GitHubRepoUpdateChecker.classifyRemoteFailure(
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled")

        XCTAssertEqual(result, .credentialUnavailable)
    }

    func testLocalGitHubBindingSurvivesCodexProjectMirrorMerge() {
        let binding = TatwoGitHubRepoBinding(
            url: "https://github.com/studio/tatwo.git",
            accountLabel: "工作室帳號",
            visibility: .priv)
        let local = TatwoNativeChatStoreDocument(projects: [
            TatwoNativeChatProject(
                name: "Local",
                workdir: "/tmp/tatwo-project",
                githubRepo: binding)
        ])
        let mirrored = TatwoNativeChatStoreDocument(projects: [
            TatwoNativeChatProject(
                name: "Mirrored",
                workdir: "/tmp/tatwo-project")
        ])

        let merged = GitHubProjectBindingMerger.apply(
            localDocument: local,
            to: mirrored)

        XCTAssertEqual(merged.projects.first?.githubRepo, binding)
    }

    private func configureGitUser(cwd: URL) throws {
        try runGit(["config", "user.name", "Tatwo Tests"], cwd: cwd)
        try runGit(["config", "user.email", "tatwo-tests@example.invalid"], cwd: cwd)
    }

    @discardableResult
    private func runGit(_ arguments: [String], cwd: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        let error = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitHubRepoUpdateCheckerTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error])
        }
        return output
    }
}
