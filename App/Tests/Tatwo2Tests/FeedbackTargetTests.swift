import Foundation
import XCTest
@testable import Tatwo2

@MainActor
final class FeedbackTargetTests: XCTestCase {
    private let identity = FeedbackIdentity(username: "fixture-user", token: "fixture-token")
    private let environment = FeedbackEnvironment(appVersion: "2.0", appBuild: "42", macOS: "macOS fixture", engine: "codex")

    private func draftURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("W4-feedback-tests-" + UUID().uuidString)
            .appendingPathComponent("draft.json")
    }

    private func response(_ request: URLRequest, status: Int, body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testDefaultAndConfiguredRepository() {
        let defaults = UserDefaults(suiteName: "W4-feedback-tests-" + UUID().uuidString)!
        XCTAssertEqual(FeedbackSettings.repository(defaults: defaults), "tatwo214/TATWO-OS-2.0-beta1-dev-test")
        defaults.setVolatileDomain([FeedbackSettings.repositoryKey: "example/feedback"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(FeedbackSettings.repository(defaults: defaults), "example/feedback")
        defaults.setVolatileDomain([FeedbackSettings.repositoryKey: "owner/repo;echo bad"], forName: UserDefaults.argumentDomain)
        XCTAssertEqual(FeedbackSettings.repository(defaults: defaults), FeedbackSettings.defaultRepository)
        for value in ["owner/..", "https://github.com/a/b", "a/b/c", "a/b?x", "a/b\ncommand"] {
            XCTAssertFalse(FeedbackSettings.isValidRepository(value), value)
        }
    }

    func testBodySuffix() {
        XCTAssertEqual(environment.appending(to: "Original"),
                       "Original\n\n---\nApp: 2.0 (42)\nmacOS: macOS fixture\nEngine: codex")
        var none = environment; none.engine = ""
        XCTAssertTrue(none.appending(to: "Original").hasSuffix("Engine: none"))
    }

    func testPureDowngradePolicy() {
        XCTAssertTrue(FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: false))
        XCTAssertTrue(FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: true, failureCode: "tool_unavailable"))
        XCTAssertFalse(FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: true))
        for code in ["auth", "quota", "reviewUnavailable", "invalid_json", "permission_denied"] {
            XCTAssertFalse(FeedbackReviewPolicy.requiresManualConfirmation(hasLoggedInEngine: true, failureCode: code))
        }
    }

    func testNoEngineRequiresExplicitConfirmationAndPostsAugmentedBody() async throws {
        var calls: [URLRequest] = []
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in
            XCTFail("No engine must not call reviewer"); return ""
        }, http: { request in
            calls.append(request)
            return self.response(request, status: request.httpMethod == "POST" ? 201 : 200,
                                 body: request.httpMethod == "POST" ? #"{"number":7}"# : #"{"login":"fixture-user"}"#)
        }, repository: { "example/feedback" })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        let manual = try await service.review(identity: identity, hasLoggedInEngine: false, environment: environment)
        XCTAssertTrue(manual)
        do { _ = try await service.submit(identity: identity); XCTFail("Must require checkbox") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .changed) }
        XCTAssertTrue(calls.isEmpty)
        let number = try await service.submit(identity: identity, manualConfirmation: true)
        XCTAssertEqual(number, 7)
        XCTAssertEqual(calls.last?.url?.path, "/repos/example/feedback/issues")
        let payload = try JSONSerialization.jsonObject(with: calls.last!.httpBody!) as! [String: String]
        XCTAssertEqual(payload["body"], environment.appending(to: "Original"))
        XCTAssertEqual(service.draft.body, "Original")
    }

    func testToolUnavailableDowngradesButMalformedReviewDoesNot() async throws {
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in
            throw FeedbackFailure.toolUnavailable
        }, http: { _ in XCTFail("No network expected"); throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        let manual = try await service.review(identity: identity, environment: environment)
        XCTAssertTrue(manual)
        let malformed = try FeedbackService(draftURL: draftURL(), reviewer: { _ in "not JSON" },
                                            http: { _ in throw FeedbackFailure.requestRejected })
        try malformed.update(title: "Bug", body: "Original", account: identity.username)
        do { _ = try await malformed.review(identity: identity); XCTFail("Invalid response must block") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .reviewUnavailable) }
    }

    func testMetadataScannedBeforeReviewer() async throws {
        var metadata = environment
        metadata.engine = "ghp_" + String(repeating: "A", count: 36)
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in
            XCTFail("Metadata must be scanned first"); return ""
        }, http: { _ in throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        do { _ = try await service.review(identity: identity, environment: metadata); XCTFail("Must block") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .credential) }
    }

    func testRepositoryAndDraftChangesInvalidateConfirmation() async throws {
        var target = "example/first"
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in "" },
                                         http: { _ in XCTFail("No network expected"); throw FeedbackFailure.requestRejected },
                                         repository: { target })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        _ = try await service.review(identity: identity, hasLoggedInEngine: false)
        target = "example/second"
        do { _ = try await service.submit(identity: identity, manualConfirmation: true); XCTFail("Target changed") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .changed) }
        _ = try await service.review(identity: identity, hasLoggedInEngine: false)
        try service.update(title: "Bug", body: "Changed", account: identity.username)
        do { _ = try await service.submit(identity: identity, manualConfirmation: true); XCTFail("Draft changed") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .changed) }
    }

    func testManualPathStillBlocksCredentialsAndMissingGitHubLogin() async throws {
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in
            XCTFail("No engine must not call reviewer"); return ""
        }, http: { _ in XCTFail("No network expected"); throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "ghp_" + String(repeating: "A", count: 36), account: identity.username)
        do { _ = try await service.review(identity: identity, hasLoggedInEngine: false); XCTFail("Must scan") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .credential) }
        try service.update(title: "Bug", body: "Original", account: identity.username)
        do {
            _ = try await service.review(identity: FeedbackIdentity(username: identity.username, token: ""), hasLoggedInEngine: false)
            XCTFail("GitHub login is still required")
        } catch { XCTAssertEqual(error as? FeedbackFailure, .login) }
    }

    func testNativeRejectionCannotBeOverriddenByManualConfirmation() async throws {
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in
            #"{"decision":"block","reason":"privacy"}"#
        }, http: { _ in XCTFail("No network expected"); throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        do { _ = try await service.review(identity: identity); XCTFail("Must block") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .reviewRejected("含有明確私人敏感資訊，請移除後重審")) }
        do { _ = try await service.submit(identity: identity, manualConfirmation: true); XCTFail("No approval") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .changed) }
    }

    func testCanonicalEquivalentBodyEditInvalidatesReceipt() async throws {
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { _ in "" },
                                         http: { _ in XCTFail("No network expected"); throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "caf\u{00E9}", account: identity.username)
        _ = try await service.review(identity: identity, hasLoggedInEngine: false)
        try service.update(title: "Bug", body: "cafe\u{0301}", account: identity.username)
        do { _ = try await service.submit(identity: identity, manualConfirmation: true); XCTFail("Bytes changed") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .changed) }
    }

    func testNativeApprovalReviewsExactAugmentedPayload() async throws {
        let service = try FeedbackService(draftURL: draftURL(), reviewer: { text in
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: String]
            XCTAssertEqual(payload["body"], self.environment.appending(to: "Original"))
            return #"{"decision":"allow","reason":"none"}"#
        }, http: { _ in throw FeedbackFailure.requestRejected })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        let manual = try await service.review(identity: identity, environment: environment)
        XCTAssertFalse(manual)
    }

    func testSameIssueNumberAcrossRepositoriesDoesNotOverwriteArchive() async throws {
        let url = draftURL()
        var target = "example/first"
        let service = try FeedbackService(draftURL: url, reviewer: { _ in "" }, http: { request in
            self.response(request, status: request.httpMethod == "POST" ? 201 : 200,
                          body: request.httpMethod == "POST" ? #"{"number":1}"# : #"{"login":"fixture-user"}"#)
        }, repository: { target })
        for repository in ["example/first", "example/second"] {
            target = repository
            try service.update(title: "Bug", body: repository, account: identity.username)
            _ = try await service.review(identity: identity, hasLoggedInEngine: false)
            _ = try await service.submit(identity: identity, manualConfirmation: true)
            try service.beginNewDraft()
        }
        let archives = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("submitted-") }
        XCTAssertEqual(archives.count, 2)
    }

    func testLegacyDeliveryRecordsKeepHistoricalTarget() async throws {
        for pending in [true, false] {
            let url = draftURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var legacy: [String: Any] = ["title": "Legacy", "body": "Original", "account": identity.username,
                                         "deliveryPending": pending,
                                         "deliveryStartedAt": Date().timeIntervalSinceReferenceDate]
            if !pending { legacy["issueNumber"] = 3 }
            try JSONSerialization.data(withJSONObject: legacy).write(to: url)
            let service = try FeedbackService(draftURL: url, reviewer: { _ in "" }, http: { request in
                XCTAssertEqual(request.url?.path, "/repos/tatwo214/tatwo2/issues")
                return self.response(request, status: 200, body: "[]")
            }, repository: { "example/new" })
            XCTAssertEqual(service.draft.deliveryRepository, "tatwo214/tatwo2")
            XCTAssertEqual(service.draft.deliveryBody, "Original")
            let persisted = try JSONDecoder().decode(FeedbackDraft.self, from: Data(contentsOf: url))
            XCTAssertEqual(persisted.deliveryRepository, "tatwo214/tatwo2")
            if pending { _ = try await service.reconcile(identity: identity) }
        }
    }

    func testPendingDeliveryReconcilesOriginalRepositoryAndBodyAfterRestart() async throws {
        let url = draftURL()
        let service = try FeedbackService(draftURL: url, reviewer: { _ in "" }, http: { request in
            if request.httpMethod == "POST" { throw FeedbackFailure.uncertain }
            return self.response(request, status: 200, body: #"{"login":"fixture-user"}"#)
        }, repository: { "example/original" })
        try service.update(title: "Bug", body: "Original", account: identity.username)
        _ = try await service.review(identity: identity, hasLoggedInEngine: false, environment: environment)
        do { _ = try await service.submit(identity: identity, manualConfirmation: true); XCTFail("Uncertain POST") }
        catch { XCTAssertEqual(error as? FeedbackFailure, .uncertain) }
        let reloaded = try FeedbackService(draftURL: url, reviewer: { _ in "" }, http: { request in
            XCTAssertEqual(request.url?.path, "/repos/example/original/issues")
            let issue: [[String: Any]] = [["number": 9, "title": "Bug", "body": self.environment.appending(to: "Original"),
                                          "user": ["login": "fixture-user"], "created_at": ISO8601DateFormatter().string(from: Date())]]
            return (try JSONSerialization.data(withJSONObject: issue), self.response(request, status: 200, body: "").1)
        }, repository: { "example/new" })
        let number = try await reloaded.reconcile(identity: identity)
        XCTAssertEqual(number, 9)
    }
}
