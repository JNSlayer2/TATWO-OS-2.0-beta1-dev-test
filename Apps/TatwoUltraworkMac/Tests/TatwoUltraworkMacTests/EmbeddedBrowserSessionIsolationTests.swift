import Foundation
import WebKit
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class EmbeddedBrowserSessionIsolationTests: XCTestCase {
    func testCheckingAndBlockedPreNavigationGateCreatesNoRuntimeAndDispatchesNoCommands()
    {
        let profileKey = UUID()
        let intentID = UUID()
        let states: [EmbeddedBrowserProfileAccessState] = [
            .checking(profileKey: profileKey),
            .blocked(
                profileKey: profileKey,
                failure: .pendingLifecycleIntent(
                    intentID: intentID,
                    stage: .archivePrepared)),
        ]

        for state in states {
            var webKitMakeNSViewCount = 0
            var webKitInitialLoadCount = 0
            var cefMakeNSViewCount = 0
            var cefInitialLoadCount = 0
            var commandCount = 0

            let webKitRuntime: Int? =
                EmbeddedBrowserRuntimeMountPolicy.makeRuntimeIfAuthorized(
                    state: state,
                    profileKey: profileKey)
                {
                    webKitMakeNSViewCount += 1
                    webKitInitialLoadCount += 1
                    return 1
                }
            let cefRuntime: Int? =
                EmbeddedBrowserRuntimeMountPolicy.makeRuntimeIfAuthorized(
                    state: state,
                    profileKey: profileKey)
                {
                    cefMakeNSViewCount += 1
                    cefInitialLoadCount += 1
                    return 1
                }

            for action in [
                EmbeddedBrowserCommand.Action.load(
                    URL(string: "https://example.com")!),
                .goBack,
                .goForward,
                .reload,
            ] {
                XCTAssertFalse(
                    EmbeddedBrowserCommandDispatchPolicy.dispatch(
                        action,
                        state: state,
                        profileKey: profileKey,
                        sink: { _ in commandCount += 1 }))
            }

            XCTAssertNil(webKitRuntime)
            XCTAssertNil(cefRuntime)
            XCTAssertEqual(webKitMakeNSViewCount, 0)
            XCTAssertEqual(webKitInitialLoadCount, 0)
            XCTAssertEqual(cefMakeNSViewCount, 0)
            XCTAssertEqual(cefInitialLoadCount, 0)
            XCTAssertEqual(commandCount, 0)
        }
    }

    func testReadyPreNavigationGateCreatesOnlyRequestedRuntimeAndDispatchesCommand()
    {
        let profileKey = UUID()
        let state = EmbeddedBrowserProfileAccessState.ready(
            profileKey: profileKey)
        var runtimeFactoryCount = 0
        var commandCount = 0

        let runtime: String? =
            EmbeddedBrowserRuntimeMountPolicy.makeRuntimeIfAuthorized(
                state: state,
                profileKey: profileKey)
            {
                runtimeFactoryCount += 1
                return "mounted"
            }
        XCTAssertTrue(
            EmbeddedBrowserCommandDispatchPolicy.dispatch(
                .reload,
                state: state,
                profileKey: profileKey,
                sink: { _ in commandCount += 1 }))

        XCTAssertEqual(runtime, "mounted")
        XCTAssertEqual(runtimeFactoryCount, 1)
        XCTAssertEqual(commandCount, 1)
    }

    func testPendingIntentWinsBeforeCapacityAndReturnsAuthoritativeBlockedState()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-browser-access-\(UUID().uuidString)",
                isDirectory: true)
        let intentStore = EmbeddedBrowserLifecycleIntentStore(
            root: root.appendingPathComponent("intents", isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent("ledger", isDirectory: true),
            maximumPersistentProfileCount: 1)
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let identifier = try XCTUnwrap(profile.dataStoreIdentifier)
        let intent = EmbeddedBrowserLifecycleIntent(
            intentID: UUID(),
            disposition: .archive,
            sessionID: "blocked-preflight",
            profileIdentifier: identifier,
            generation: 0,
            stage: .archivePrepared,
            createdAt: Date(),
            updatedAt: Date())
        try intentStore.save(intent)
        let coordinator = EmbeddedBrowserProfileAccessCoordinator(
            ledgerStore: ledgerStore,
            intentStore: intentStore,
            webKitRegistry: EmbeddedBrowserWebViewRegistry(),
            cefRegistry: TatwoCEFProfileLeaseRegistry(),
            cefStore: nil)

        let result = await coordinator.recordAccessAndEnforce(
            profile: profile,
            engine: .webKitLegacy)

        guard case let .failure(failure) = result else {
            return XCTFail("pending lifecycle intent must block access")
        }
        XCTAssertEqual(
            failure,
            .pendingLifecycleIntent(
                intentID: intent.intentID,
                stage: .archivePrepared))
        XCTAssertTrue(try ledgerStore.snapshot().entries.isEmpty)
    }

    func testSameSessionReconstructionUsesNewWebViewWithSamePersistentDataStore() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let identifier = UUID()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(identifier)
        let firstOwner = UUID()

        let first = requireLease(
            from: registry.acquire(profile: profile, ownerID: firstOwner) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })
        XCTAssertTrue(
            registry.release(
                profile: profile,
                ownerID: firstOwner,
                webView: first.webView))
        XCTAssertEqual(registry.retainedWebViewCount, 0)

        let second = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })

        XCTAssertTrue(first.isNew)
        XCTAssertTrue(second.isNew)
        XCTAssertFalse(first.webView === second.webView)
        XCTAssertEqual(first.webView.configuration.websiteDataStore.identifier, identifier)
        XCTAssertEqual(second.webView.configuration.websiteDataStore.identifier, identifier)
    }

    func testDifferentSessionsReceiveDifferentWebViewsAndDataStores() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let firstID = UUID()
        let secondID = UUID()
        let firstProfile = EmbeddedBrowserRuntimeProfile.persistent(firstID)
        let secondProfile = EmbeddedBrowserRuntimeProfile.persistent(secondID)

        let first = requireLease(
            from: registry.acquire(profile: firstProfile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: firstProfile))
            })
        let second = requireLease(
            from: registry.acquire(profile: secondProfile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: secondProfile))
            })

        XCTAssertFalse(first.webView === second.webView)
        XCTAssertEqual(first.webView.configuration.websiteDataStore.identifier, firstID)
        XCTAssertEqual(second.webView.configuration.websiteDataStore.identifier, secondID)
        XCTAssertNotEqual(
            first.webView.configuration.websiteDataStore.identifier,
            second.webView.configuration.websiteDataStore.identifier)
    }

    func testUnboundBrowserUsesNonPersistentDataStore() {
        let profile = EmbeddedBrowserRuntimeProfile.ephemeral(UUID())
        let configuration = WKWebViewConfiguration.tatwoBrowserConfiguration(profile: profile)

        XCTAssertFalse(configuration.websiteDataStore.isPersistent)
        XCTAssertNil(configuration.websiteDataStore.identifier)
    }

    func testConcurrentPanesForSameSessionNeverShareNSView() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let first = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })
        let second = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })

        let firstHost = NSView()
        let secondHost = NSView()
        firstHost.addSubview(first.webView)
        secondHost.addSubview(second.webView)

        XCTAssertFalse(first.webView === second.webView)
        XCTAssertTrue(first.webView.superview === firstHost)
        XCTAssertTrue(second.webView.superview === secondHost)
        XCTAssertEqual(
            first.webView.configuration.websiteDataStore.identifier,
            second.webView.configuration.websiteDataStore.identifier)
        XCTAssertEqual(registry.activeLeaseCount, 2)
    }

    func testRegistryRejectsAFactoryThatReturnsAnAlreadyLeasedWebView() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let first = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })

        let duplicate = registry.acquire(profile: profile, ownerID: UUID()) {
            first.webView
        }

        assertLeaseFailure(duplicate, equals: .duplicateWebView)
        XCTAssertEqual(registry.activeLeaseCount, 1)
    }

    func testStaleReleaseCannotDetachAnotherLease() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let owner = UUID()
        let lease = requireLease(
            from: registry.acquire(profile: profile, ownerID: owner) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })

        XCTAssertFalse(
            registry.release(
                profile: profile,
                ownerID: UUID(),
                webView: lease.webView))
        XCTAssertEqual(registry.activeLeaseCount, 1)
        XCTAssertTrue(
            registry.release(
                profile: profile,
                ownerID: owner,
                webView: lease.webView))
        XCTAssertEqual(registry.retainedWebViewCount, 0)
    }

    func testReleasedPersistentAndEphemeralViewsAreNeverRetained() {
        let registry = EmbeddedBrowserWebViewRegistry()

        for profile in [
            EmbeddedBrowserRuntimeProfile.persistent(UUID()),
            EmbeddedBrowserRuntimeProfile.ephemeral(UUID()),
        ] {
            let owner = UUID()
            let lease = requireLease(
                from: registry.acquire(profile: profile, ownerID: owner) {
                    WKWebView(
                        frame: .zero,
                        configuration: .tatwoBrowserConfiguration(profile: profile))
                })
            XCTAssertTrue(
                registry.release(
                    profile: profile,
                    ownerID: owner,
                    webView: lease.webView))
            XCTAssertEqual(registry.retainedWebViewCount, 0)
        }
    }

    func testPersistentDataStoreIdentitySurvivesConfigurationReconstruction() {
        let identifier = UUID()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(identifier)
        let first = WKWebViewConfiguration.tatwoBrowserConfiguration(profile: profile)
        let reconstructed = WKWebViewConfiguration.tatwoBrowserConfiguration(profile: profile)

        XCTAssertTrue(first.websiteDataStore.isPersistent)
        XCTAssertTrue(reconstructed.websiteDataStore.isPersistent)
        XCTAssertEqual(first.websiteDataStore.identifier, identifier)
        XCTAssertEqual(reconstructed.websiteDataStore.identifier, identifier)
    }

    func testNavigationPolicyAllowsOnlyHTTPAndHTTPSRedirectTargets() {
        XCTAssertTrue(EmbeddedBrowserNavigationPolicy.allows(URL(string: "https://example.com")))
        XCTAssertFalse(EmbeddedBrowserNavigationPolicy.allows(URL(string: "http://localhost:8080")))
        XCTAssertFalse(EmbeddedBrowserNavigationPolicy.allows(URL(string: "custom://redirect")))
        XCTAssertFalse(EmbeddedBrowserNavigationPolicy.allows(URL(string: "file:///tmp/private")))
        XCTAssertFalse(EmbeddedBrowserNavigationPolicy.allows(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(EmbeddedBrowserNavigationPolicy.allows(nil))
    }

    func testPurgeFailsClosedWhileProfileHasActiveLease() {
        let registry = EmbeddedBrowserWebViewRegistry()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        _ = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })
        var removerCalled = false
        var result: Result<Void, Error>?

        registry.purge(
            profile: profile,
            persistentDataStoreRemover: { _, _ in removerCalled = true },
            completion: { result = $0 })

        XCTAssertFalse(removerCalled)
        guard case let .failure(error)? = result else {
            return XCTFail("expected profile-in-use failure")
        }
        XCTAssertEqual(error as? EmbeddedBrowserProfilePurgeError, .profileInUse)
    }

    func testAcquireFailsClosedForEntireAsyncPurgeWindow() async {
        let registry = EmbeddedBrowserWebViewRegistry()
        let identifier = UUID()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(identifier)
        var removalCallback: (@Sendable (Error?) -> Void)?
        var removedIdentifier: UUID?
        var completionCount = 0
        let finished = expectation(description: "purge finished")

        registry.purge(
            profile: profile,
            persistentDataStoreRemover: { identifier, completion in
                removedIdentifier = identifier
                removalCallback = completion
            },
            completion: { result in
                completionCount += 1
                guard case .success = result else {
                    return XCTFail("expected successful purge")
                }
                finished.fulfill()
            })

        XCTAssertEqual(removedIdentifier, identifier)
        XCTAssertTrue(registry.isProfileBlocked(profile))
        assertLeaseFailure(
            registry.acquire(profile: profile, ownerID: UUID()) {
                XCTFail("purging profile must not construct a WKWebView")
                return WKWebView()
            },
            equals: .profileBlockedForPurge)

        var duplicateResult: Result<Void, Error>?
        registry.purge(
            profile: profile,
            persistentDataStoreRemover: { _, _ in
                XCTFail("duplicate purge must not invoke a second remover")
            },
            completion: { duplicateResult = $0 })
        guard case let .failure(duplicateError)? = duplicateResult else {
            return XCTFail("expected duplicate purge failure")
        }
        XCTAssertEqual(
            duplicateError as? EmbeddedBrowserProfilePurgeError,
            .purgeInProgress)

        let callback = try! XCTUnwrap(removalCallback)
        let callbackBox = RemovalCallbackBox(callback)
        DispatchQueue.global(qos: .userInitiated).async {
            callbackBox.callback(nil)
        }
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(registry.isProfileBlocked(profile))
        _ = requireLease(
            from: registry.acquire(profile: profile, ownerID: UUID()) {
                WKWebView(
                    frame: .zero,
                    configuration: .tatwoBrowserConfiguration(profile: profile))
            })

        callback(nil)
        await Task.yield()
        XCTAssertEqual(completionCount, 1)
    }

    func testFailedPurgeRemainsBlockedAndStaleCallbackCannotFinishRetry() async {
        let registry = EmbeddedBrowserWebViewRegistry()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        var firstCallback: (@Sendable (Error?) -> Void)?
        var secondCallback: (@Sendable (Error?) -> Void)?
        let firstFinished = expectation(description: "first purge failed")
        let retryFinished = expectation(description: "retry succeeded")
        var retryCompletionCount = 0

        registry.purge(
            profile: profile,
            persistentDataStoreRemover: { _, completion in
                firstCallback = completion
            },
            completion: { result in
                guard case .failure = result else {
                    return XCTFail("expected failed purge")
                }
                firstFinished.fulfill()
            })
        let staleCallback = try! XCTUnwrap(firstCallback)
        staleCallback(TestPurgeError.removalFailed)
        await fulfillment(of: [firstFinished], timeout: 2)

        XCTAssertTrue(registry.isProfileBlocked(profile))
        assertLeaseFailure(
            registry.acquire(profile: profile, ownerID: UUID()) { WKWebView() },
            equals: .profileBlockedForPurge)

        registry.purge(
            profile: profile,
            persistentDataStoreRemover: { _, completion in
                secondCallback = completion
            },
            completion: { result in
                retryCompletionCount += 1
                guard case .success = result else {
                    return XCTFail("expected successful retry")
                }
                retryFinished.fulfill()
            })

        staleCallback(nil)
        await Task.yield()
        XCTAssertTrue(registry.isProfileBlocked(profile))

        let currentCallback = try! XCTUnwrap(secondCallback)
        currentCallback(nil)
        await fulfillment(of: [retryFinished], timeout: 2)
        XCTAssertFalse(registry.isProfileBlocked(profile))

        currentCallback(TestPurgeError.removalFailed)
        await Task.yield()
        XCTAssertEqual(retryCompletionCount, 1)
    }

    func testPendingLifecycleIntentDurableRoundTripAndArchivePreserve()
        throws
    {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = EmbeddedBrowserLifecycleIntentStore(root: root)
        let intent = EmbeddedBrowserLifecycleIntent(
            intentID: UUID(),
            disposition: .archive,
            sessionID: "archive-roundtrip",
            profileIdentifier: UUID(),
            generation: 3,
            stage: .archivePrepared,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2))

        try store.save(intent)

        XCTAssertEqual(try store.load(intentID: intent.intentID), intent)
        XCTAssertEqual(
            try store.pendingIntent(
                profileIdentifier: intent.profileIdentifier),
            intent)
        XCTAssertEqual(intent.disposition, .archive)
        XCTAssertEqual(intent.stage, .archivePrepared)
    }

    private func requireLease(
        from result: Result<EmbeddedBrowserWebViewRegistry.Lease, EmbeddedBrowserLeaseError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EmbeddedBrowserWebViewRegistry.Lease {
        guard case let .success(lease) = result else {
            XCTFail("expected browser lease, received \(result)", file: file, line: line)
            return EmbeddedBrowserWebViewRegistry.Lease(webView: WKWebView(), isNew: true)
        }
        return lease
    }

    private func assertLeaseFailure(
        _ result: Result<EmbeddedBrowserWebViewRegistry.Lease, EmbeddedBrowserLeaseError>,
        equals expected: EmbeddedBrowserLeaseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("expected lease failure, received \(result)", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private enum TestPurgeError: Error {
        case removalFailed
    }

    private final class RemovalCallbackBox: @unchecked Sendable {
        let callback: @Sendable (Error?) -> Void

        init(_ callback: @escaping @Sendable (Error?) -> Void) {
            self.callback = callback
        }
    }
}
