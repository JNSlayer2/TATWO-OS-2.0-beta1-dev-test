import Foundation
import XCTest
@testable import Tatwo2

final class PullRequestServiceTests: XCTestCase {
    private let repository = "tatwo214/TATWO-OS-2.0-beta1-dev-test"

    func testPendingPRIsThreadScopedAndClearedExactlyOnce() {
        var pending = PullRequestService.PendingPR()
        let first = UUID(), second = UUID()
        XCTAssertFalse(pending.contains(first))
        XCTAssertTrue(pending.begin(first))
        XCTAssertFalse(pending.begin(first))
        XCTAssertFalse(pending.contains(second))
        XCTAssertTrue(pending.begin(second))
        XCTAssertTrue(pending.finish(first))
        XCTAssertFalse(pending.finish(first))
        XCTAssertFalse(pending.contains(first))
        XCTAssertTrue(pending.contains(second))
        XCTAssertTrue(pending.begin(first)) // retry after failed/rejected/completed submission
    }

    func testReplyDraftUsesFirstLineAndWholeReply() throws {
        let reply = "修正登入畫面\n調整登入流程。\n相關測試通過。"
        let draft = try PullRequestService.replyDraft(" \n" + reply + "\n ")
        XCTAssertEqual(draft.title, "修正登入畫面")
        XCTAssertEqual(draft.description, reply)
        XCTAssertEqual(try PullRequestService.replyDraft("標題\r\n說明").title, "標題")
        XCTAssertEqual(try PullRequestService.replyDraft("單行標題").description, "單行標題")
        XCTAssertThrowsError(try PullRequestService.replyDraft(" \n\t"))
    }

    func testContributionPromptExplicitlyDefersCommitAndPush() {
        XCTAssertTrue(PullRequestService.contributionInstruction.contains("不要 commit、不要 push"))
        XCTAssertTrue(PullRequestService.contributionInstruction.contains("跑相關測試"))
        XCTAssertTrue(PullRequestService.contributionInstruction.contains("第一行是適合當 PR 標題"))
    }

    func testBranchNameHasDeterministicUTCDateAndSafeSlug() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(PullRequestService.branchName(title: " Fix: Login / UI! ", date: date), "pr/19700101-0000-fix-login-ui")
        XCTAssertEqual(PullRequestService.branchName(title: "修正登入", date: date), "pr/19700101-0000-changes")
        let name = PullRequestService.branchName(title: "../../@{\n --force ", date: date)
        XCTAssertFalse(name.contains("..")); XCTAssertFalse(name.contains("@{"))
        XCTAssertLessThanOrEqual(PullRequestService.branchName(title: String(repeating: "a", count: 500), date: date).count, 65)
    }

    func testOriginAllowsOnlyExactGitHubHostsAndRepositoryPaths() {
        for url in ["https://github.com/\(repository).git", "git@github.com:\(repository).git",
                    "ssh://git@github.com/\(repository).git", "https://github.com/\(repository)"] {
            XCTAssertEqual(PullRequestService.originRepository(url), repository)
        }
        for url in ["https://github.com.evil.test/\(repository)", "https://github.com/\(repository)/more",
                    "https://github.com/\(repository)?x=y", "https://a:secret@github.com/\(repository)",
                    "file:///tmp/repo", "https://github.com/../repo", "https://github.com:443/\(repository)"] {
            XCTAssertNil(PullRequestService.originRepository(url), url)
        }
        XCTAssertFalse(PullRequestService.validRepository("owner/repo\n"))
        XCTAssertFalse(PullRequestService.validRepository("owner/.."))
    }

    private func problem(isGit: Bool = true, origin: String? = nil, fork: Bool = false,
                         parent: String? = nil, loggedIn: Bool = true, dirty: Bool = false,
                         ahead: Int = 0) -> String? {
        PullRequestService.preflightProblem(isGit: isGit, origin: origin ?? repository,
            repository: repository, fork: fork, parent: parent, loggedIn: loggedIn, dirty: dirty, ahead: ahead)
    }
    func testPreflightAcceptsDirtyRepoOrAheadBranch() {
        XCTAssertNil(problem(dirty: true)); XCTAssertNil(problem(ahead: 1))
        XCTAssertNil(problem(origin: "tester/fork", fork: true, parent: repository, dirty: true))
        XCTAssertNil(problem(origin: repository.uppercased(), ahead: 2))
    }
    func testPreflightRejectsMissingGitLoginChangesAndUnrelatedFork() {
        XCTAssertNotNil(problem(isGit: false, dirty: true))
        XCTAssertNotNil(problem(loggedIn: false, dirty: true))
        XCTAssertNotNil(problem())
        XCTAssertNotNil(problem(origin: "tester/unrelated", dirty: true))
        XCTAssertNotNil(problem(origin: "tester/fork", fork: true, parent: "other/repo", ahead: 3))
        XCTAssertNotNil(problem(origin: "tester/fork", fork: false, parent: repository, ahead: 3))
    }
    func testBinaryMarkerDoesNotRejectCodeDiscussingBinaryPatches() {
        XCTAssertTrue(PullRequestService.hasBinaryPatch("diff --git a/a b/a\nGIT binary patch\nliteral 5"))
        XCTAssertFalse(PullRequestService.hasBinaryPatch("+let marker = \"GIT binary patch\""))
        XCTAssertFalse(PullRequestService.hasBinaryPatch("-GIT binary patch"))
    }

    func testBodyIncludesOnlyUserDescription() {
        XCTAssertEqual(PullRequestService.body(description: " \n修正登入\n\n測試通過\n"), "修正登入\n\n測試通過")
        XCTAssertEqual(PullRequestService.body(description: " \n"), "")
    }
    func testPRParserRequiresLeadingStandaloneCommand() {
        XCTAssertEqual(TatwoSlashCommandParser.prArgument(in: " /pr  修正登入\n"), "修正登入")
        XCTAssertEqual(TatwoSlashCommandParser.prArgument(in: "/pr\tTitle"), "Title")
        XCTAssertEqual(TatwoSlashCommandParser.prArgument(in: "/pr"), "")
        for value in ["/preview", "請用 /pr", "```\n/pr\n```", "hello\n/pr"] {
            XCTAssertNil(TatwoSlashCommandParser.prArgument(in: value))
        }
        XCTAssertTrue(ChatComposerSlashCatalog.commands.contains("/pr"))
    }
    func testSharedSecretScanChecksBeyondPreview() throws {
        let token = "ghp_" + String(repeating: "a", count: 36)
        XCTAssertThrowsError(try FeedbackService.scanSecrets(String(repeating: "safe\n", count: 201) + token))
        XCTAssertThrowsError(try FeedbackService.scanSecrets("-----BEGIN " + "PRIVATE KEY-----"))
        XCTAssertNoThrow(try FeedbackService.scanSecrets("password field; example placeholder"))
    }
    func testSnapshotBindsFullDiffNotOnlyPreview() {
        let prefix = String(repeating: "line\n", count: 201)
        let a = PullRequestService.Snapshot(head: "a", status: "M file", diff: prefix + "A", stat: "file", origin: repository)
        let b = PullRequestService.Snapshot(head: "a", status: "M file", diff: prefix + "B", stat: "file", origin: repository)
        XCTAssertEqual(a.preview, b.preview)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.preview.split(separator: "\n").count, 201)
    }
    func testAPIEncodesPayloadAndNeverPutsTokenInURL() async throws {
        let service = PullRequestService { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
            XCTAssertEqual(body["base"], "main"); XCTAssertEqual(body["head"], "tester:pr/test")
            return (Data("{\"number\":1}".utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await service.api("/repos/\(repository)/pulls", identity: FeedbackIdentity(username: "tester", token: "test-token"),
                    method: "POST", payload: ["title": "Title", "body": "Description", "base": "main", "head": "tester:pr/test"])
    }
    func testAPIRedactsErrorsAndAllowsOnlyExplicit404Polling() async throws {
        let service = PullRequestService { request in
            (Data("sensitive server body".utf8), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let identity = FeedbackIdentity(username: "tester", token: "secret")
        let missing = try await service.api("/repos/tester/fork", identity: identity, allowMissing: true)
        XCTAssertNil(missing)
        do {
            _ = try await service.api("/repos/tester/fork", identity: identity)
            XCTFail("must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sensitive server body"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }
    func testLocalSnapshotIncludesStagedUntrackedAndOutgoingChanges() async throws {
        // Local-only fixture, no fetch/push/PR. Retained for inspection; no direct deletion.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("w5-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await PullRequestService.git(["init", "-q"], at: directory)
        let tracked = directory.appendingPathComponent("tracked.txt")
        try "baseline\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await PullRequestService.git(["add", "-A"], at: directory)
        let commit = ["-c", "user.name=W5 Fixture", "-c", "user.email=w5@example.invalid",
                      "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "commit", "-qm"]
        _ = try await PullRequestService.git(commit + ["baseline"], at: directory)
        _ = try await PullRequestService.git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: directory)
        _ = try await PullRequestService.git(["remote", "add", "origin", "https://github.com/" + repository + ".git"], at: directory)
        try "outgoing change\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await PullRequestService.git(["add", "-A"], at: directory)
        _ = try await PullRequestService.git(commit + ["outgoing"], at: directory)
        try "staged change\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await PullRequestService.git(["add", "-A"], at: directory)
        let untracked = directory.appendingPathComponent("new.txt")
        try "untracked change\n".write(to: untracked, atomically: true, encoding: .utf8)
        let snapshot = try await PullRequestService.snapshot(at: directory)
        XCTAssertTrue(snapshot.diff.contains("outgoing change"))
        XCTAssertTrue(snapshot.diff.contains("staged change"))
        XCTAssertTrue(snapshot.diff.contains("untracked change"))
        XCTAssertTrue(snapshot.stat.contains("new.txt"))
        let secret = "ghp_" + String(repeating: "b", count: 36)
        try secret.write(to: untracked, atomically: true, encoding: .utf8)
        do {
            _ = try await PullRequestService.snapshot(at: directory)
            XCTFail("untracked credential must block before presentation")
        } catch { XCTAssertEqual(error as? FeedbackFailure, .credential) }
    }

}
