import XCTest
@testable import Tatwo2

private final class ReleaseURLProtocol: URLProtocol {
    static var responseCode = 200
    static var body = Data()
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ReleaseVersionCompareTests: XCTestCase {
    func testNumericComponentsNotLexicalOrder() {
        XCTAssertFalse(ReleaseVersionCompare.isNewer("1.2.0", than: "1.10.0"))
        XCTAssertTrue(ReleaseVersionCompare.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertTrue(ReleaseVersionCompare.isNewer("2.0.0", than: "1.99.99"))
        XCTAssertTrue(ReleaseVersionCompare.isNewer("1.2.10", than: "1.2.9"))
    }

    func testPrefixBundleVersionAndMetadata() {
        XCTAssertTrue(ReleaseVersionCompare.isNewer("v0.2.0", than: "0.1"))
        XCTAssertFalse(ReleaseVersionCompare.isNewer("v1.2.0", than: "1.2"))
        XCTAssertFalse(ReleaseVersionCompare.isNewer("1.2.0+build.2", than: "1.2.0+build.1"))
        XCTAssertFalse(ReleaseVersionCompare.isNewer("1.1.0", than: "1.2.0"))
    }

    func testSemverPrereleasePrecedence() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
                       "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(ReleaseVersionCompare.isNewer(newer, than: older))
            XCTAssertFalse(ReleaseVersionCompare.isNewer(older, than: newer))
        }
    }

    func testInvalidInputFailsClosed() {
        for invalid in ["", "v", "latest", "1", "1.2.3.4", "01.2.3", "1..3", "1.2.3-",
                        "1.2.3-01", "1.2.3+", "1.2.3+a+b", " 1.2.3", "1.2.3-beta!"] {
            XCTAssertFalse(ReleaseVersionCompare.isNewer(invalid, than: "0.0.0"), invalid)
            XCTAssertFalse(ReleaseVersionCompare.isNewer("9.9.9", than: invalid), invalid)
        }
    }

    func testLargeNumericComponentsDoNotOverflow() {
        XCTAssertTrue(ReleaseVersionCompare.isNewer("999999999999999999999999.0.0", than: "2.0.0"))
    }

    @MainActor
    func testPublicRepositoryRequestAndLaunchDismissal() async {
        let defaults = UserDefaults(suiteName: "W2-release-tests-\(UUID().uuidString)")!
        // Volatile values only; no durable preference or host config writes.
        defaults.setVolatileDomain(["tatwo2.feedback.repository": "example/public-beta"],
                                   forName: UserDefaults.argumentDomain)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let checker = GitHubReleaseUpdateChecker(defaults: defaults, session: session, installedVersion: "1.2.0")
        ReleaseURLProtocol.responseCode = 200
        ReleaseURLProtocol.body = Data(#"{"tag_name":"v1.10.0","name":"Beta release","draft":false,"prerelease":false}"#.utf8)
        await checker.check()
        XCTAssertEqual(checker.availableRelease?.tag_name, "v1.10.0")
        XCTAssertEqual(ReleaseURLProtocol.lastRequest?.url?.path, "/repos/example/public-beta/releases/latest")
        XCTAssertNil(ReleaseURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        checker.dismissForLaunch()
        await checker.check()
        XCTAssertTrue(checker.dismissed)
        XCTAssertFalse(checker.isChecking)
    }

    @MainActor
    func testNoReleaseRateLimitMalformedAndPrereleaseResponses() async {
        let defaults = UserDefaults(suiteName: "W2-release-tests-\(UUID().uuidString)")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let checker = GitHubReleaseUpdateChecker(defaults: defaults, session: session, installedVersion: "1.2.0")
        ReleaseURLProtocol.responseCode = 404
        ReleaseURLProtocol.body = Data()
        await checker.check()
        XCTAssertEqual(checker.status, "尚無可用版本")
        XCTAssertNil(checker.availableRelease)
        ReleaseURLProtocol.responseCode = 403
        await checker.check()
        XCTAssertTrue(checker.status.contains("HTTP 403"))
        ReleaseURLProtocol.responseCode = 200
        ReleaseURLProtocol.body = Data("not JSON".utf8)
        await checker.check()
        XCTAssertEqual(checker.status, "更新檢查失敗，請確認網路後重試")
        ReleaseURLProtocol.body = Data(#"{"tag_name":"v2.0.0","name":null,"draft":false,"prerelease":true}"#.utf8)
        await checker.check()
        XCTAssertNil(checker.availableRelease)
        XCTAssertFalse(checker.isChecking)
    }
}
