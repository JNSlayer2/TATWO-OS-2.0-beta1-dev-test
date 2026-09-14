import Foundation
import WebKit
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class EmbeddedBrowserSecurityPolicyTests: XCTestCase {
    func testAnnotationIngressRequiresMainFrameAndUsesNativeCommittedPage() throws {
        let profileKey = UUID()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertNil(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: false,
                text: "iframe payload",
                committedURLString: "https://native.example/page",
                currentNativeURLString: "https://native.example/page",
                nativeTitle: "Native title",
                profileKey: profileKey,
                createdAt: now))
        XCTAssertNil(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: "stale navigation",
                committedURLString: "https://committed.example/",
                currentNativeURLString: "https://new.example/",
                nativeTitle: "Native title",
                profileKey: profileKey,
                createdAt: now))

        let annotation = try XCTUnwrap(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: " selected text ",
                committedURLString: "https://native.example/page",
                currentNativeURLString: "https://native.example/page",
                nativeTitle: "Native title",
                profileKey: profileKey,
                createdAt: now))
        XCTAssertEqual(annotation.profileKey, profileKey)
        XCTAssertEqual(annotation.url, "https://native.example/page")
        XCTAssertEqual(annotation.title, "Native title")
        XCTAssertEqual(annotation.text, "selected text")
    }

    func testAnnotationStorePartitionsRecordsByProfile() throws {
        let root = temporaryProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let store = EmbeddedBrowserAnnotationStore(
            fileURL: root.appendingPathComponent("annotations.json"))
        let firstProfile = UUID()
        let secondProfile = UUID()
        let url = "https://example.com/page"
        let now = Date(timeIntervalSince1970: 100)
        let first = try XCTUnwrap(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: "first",
                committedURLString: url,
                currentNativeURLString: url,
                nativeTitle: "First",
                profileKey: firstProfile,
                createdAt: now))
        let second = try XCTUnwrap(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: "second",
                committedURLString: url,
                currentNativeURLString: url,
                nativeTitle: "Second",
                profileKey: secondProfile,
                createdAt: now))

        XCTAssertTrue(store.add(first, now: now))
        XCTAssertTrue(store.add(second, now: now))
        XCTAssertEqual(
            store.annotations(forURL: url, profileKey: firstProfile),
            [first])
        XCTAssertEqual(
            store.annotations(forURL: url, profileKey: secondProfile),
            [second])
    }

    func testAnnotationStoreInjectedInitializerLoadsPersistedRecords()
        async throws
    {
        let root = temporaryProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("annotations.json")
        let profileKey = UUID()
        let annotation = try XCTUnwrap(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: "persisted",
                committedURLString: "https://example.com/",
                currentNativeURLString: "https://example.com/",
                nativeTitle: "Persisted",
                profileKey: profileKey,
                createdAt: Date(timeIntervalSince1970: 10)))
        try JSONEncoder().encode([annotation]).write(to: fileURL)

        let reconstructed = EmbeddedBrowserAnnotationStore(fileURL: fileURL)
        for _ in 0..<100
        where reconstructed.annotations(
            forURL: annotation.url,
            profileKey: profileKey).isEmpty
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(
            reconstructed.annotations(
                forURL: annotation.url,
                profileKey: profileKey),
            [annotation])
    }

    func testAnnotationCapsRejectLengthCountFileSizeAndRateFloods() throws {
        let profileKey = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: String(
                    repeating: "x",
                    count:
                        EmbeddedBrowserAnnotationPolicy
                        .maximumTextCharacters + 1),
                committedURLString: "https://example.com/",
                currentNativeURLString: "https://example.com/",
                nativeTitle: "Title",
                profileKey: profileKey,
                createdAt: now))
        let candidate = try XCTUnwrap(
            EmbeddedBrowserAnnotationPolicy.candidate(
                isMainFrame: true,
                text: "bounded",
                committedURLString: "https://example.com/",
                currentNativeURLString: "https://example.com/",
                nativeTitle: "Title",
                profileKey: profileKey,
                createdAt: now))

        XCTAssertFalse(
            EmbeddedBrowserAnnotationPolicy.permitsAppend(
                candidate,
                to: Array(
                    repeating: candidate,
                    count:
                        EmbeddedBrowserAnnotationPolicy
                        .maximumAnnotationsPerProfile),
                recentAcceptedAt: [],
                now: now,
                encodedByteCount: 1))
        XCTAssertFalse(
            EmbeddedBrowserAnnotationPolicy.permitsAppend(
                candidate,
                to: [],
                recentAcceptedAt: [],
                now: now,
                encodedByteCount:
                    EmbeddedBrowserAnnotationPolicy
                    .maximumPersistedBytes + 1))
        XCTAssertFalse(
            EmbeddedBrowserAnnotationPolicy.permitsAppend(
                candidate,
                to: [],
                recentAcceptedAt: Array(
                    repeating: now,
                    count:
                        EmbeddedBrowserAnnotationPolicy
                        .maximumAddsPerRateWindow),
                now: now,
                encodedByteCount: 1))
        XCTAssertTrue(
            EmbeddedBrowserAnnotationPolicy.permitsAppend(
                candidate,
                to: [],
                recentAcceptedAt: Array(
                    repeating: now,
                    count:
                        EmbeddedBrowserAnnotationPolicy
                        .maximumAddsPerRateWindow - 1),
                now: now,
                encodedByteCount: 1))
    }

    func testBookmarkStorePartitionsRecordsByProfile() throws {
        let firstProfile = UUID()
        let secondProfile = UUID()
        let first = try XCTUnwrap(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: "https://developer.apple.com/",
                title: "Apple Developer",
                profileKey: firstProfile,
                createdAt: Date(timeIntervalSince1970: 10)))
        let second = try XCTUnwrap(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: "https://chatgpt.com/",
                title: "ChatGPT",
                profileKey: secondProfile,
                createdAt: Date(timeIntervalSince1970: 11)))
        let store = EmbeddedBrowserBookmarkStore(fileURL: nil)

        XCTAssertTrue(store.add(first))
        XCTAssertTrue(store.add(second))
        XCTAssertEqual(store.bookmarks(profileKey: firstProfile), [first])
        XCTAssertEqual(store.bookmarks(profileKey: secondProfile), [second])
    }

    func testBookmarkStoreReloadsBoundedJSON() async throws {
        let root = temporaryProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("bookmarks.json")
        let profileKey = UUID()
        let bookmark = try XCTUnwrap(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: "https://example.com/docs",
                title: "Example docs",
                profileKey: profileKey,
                createdAt: Date(timeIntervalSince1970: 12)))
        let store = EmbeddedBrowserBookmarkStore(fileURL: fileURL)
        XCTAssertTrue(store.add(bookmark))

        for _ in 0..<100
        where !FileManager.default.fileExists(atPath: fileURL.path)
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reconstructed = EmbeddedBrowserBookmarkStore(fileURL: fileURL)
        for _ in 0..<100
        where reconstructed.bookmarks(profileKey: profileKey).isEmpty
        {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            reconstructed.bookmarks(profileKey: profileKey),
            [bookmark])
    }

    func testBookmarkPolicyRejectsLengthCountDuplicateAndTotalBytes()
        throws
    {
        let profileKey = UUID()
        XCTAssertNil(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString:
                    "https://example.com/"
                    + String(
                        repeating: "x",
                        count:
                            EmbeddedBrowserBookmarkPolicy
                            .maximumURLCharacters),
                title: "Too long",
                profileKey: profileKey))
        XCTAssertNil(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: "https://example.com/",
                title: String(
                    repeating: "x",
                    count:
                        EmbeddedBrowserBookmarkPolicy
                        .maximumTitleCharacters + 1),
                profileKey: profileKey))

        let bookmark = try XCTUnwrap(
            EmbeddedBrowserBookmarkPolicy.candidate(
                urlString: "https://example.com/",
                title: "Example",
                profileKey: profileKey))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: [bookmark],
                encodedByteCount: 1))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: Array(
                    repeating: bookmark,
                    count:
                        EmbeddedBrowserBookmarkPolicy
                        .maximumBookmarksPerProfile),
                encodedByteCount: 1))
        XCTAssertFalse(
            EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: [],
                encodedByteCount:
                    EmbeddedBrowserBookmarkPolicy
                    .maximumPersistedBytes + 1))
        XCTAssertTrue(
            EmbeddedBrowserBookmarkPolicy.permitsAppend(
                bookmark,
                to: [],
                encodedByteCount: 1))
    }

    func testAnnotationBridgeUsesIsolatedWorldMainFrameAndTextOnlyPayload()
        throws
    {
        let source = try embeddedBrowserSource()
        XCTAssertTrue(source.contains(
            "WKContentWorld.world(\n        name: \"com.tatwo.browser.annotation\")"))
        XCTAssertTrue(source.contains("in: Self.annotationContentWorld"))
        XCTAssertTrue(source.contains(
            "message.frameInfo.isMainFrame"))
        XCTAssertTrue(source.contains(
            "contentWorld: Self.annotationContentWorld"))
        XCTAssertTrue(source.contains("body[\"text\"] as? String"))
        XCTAssertFalse(source.contains("body[\"url\"]"))
        XCTAssertFalse(source.contains("body[\"title\"]"))
        XCTAssertFalse(source.contains(
            "text: lastText, url: location.href, title: document.title"))
        XCTAssertTrue(source.contains(
            "if (e.isTrusted !== true) { return; }"))
        XCTAssertTrue(source.contains(
            "if (event.isTrusted !== true) { return; }"))
        let trustedClick = try XCTUnwrap(
            source.range(
                of: "if (event.isTrusted !== true) { return; }"))
        let postMessage = try XCTUnwrap(
            source.range(
                of: "tatwoAnnotate.postMessage",
                range: trustedClick.upperBound..<source.endIndex))
        XCTAssertLessThan(trustedClick.lowerBound, postMessage.lowerBound)
    }

    func testNavigationPolicyAllowsPublicHTTPAndHTTPS() {
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "https://example.com/path")),
            .allow)
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "http://8.8.8.8/")),
            .allow)
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "https://[2606:4700:4700::1111]/")),
            .allow)
    }

    func testNavigationPolicyBlocksLocalNamesAndNonPublicIPv4Ranges() {
        let localNames = [
            "http://localhost:8080/",
            "https://api.localhost/",
            "https://printer.local/",
            "https://service.internal/",
            "https://router.lan/",
            "https://device.home.arpa/",
        ]
        for rawURL in localNames {
            XCTAssertEqual(
                EmbeddedBrowserNavigationPolicy.decision(
                    for: URL(string: rawURL)),
                .block(.localHostname),
                rawURL)
        }

        let nonPublicAddresses = [
            "http://0.0.0.0/",
            "http://10.0.0.1/",
            "http://100.64.0.1/",
            "http://127.0.0.1/",
            "http://2130706433/",
            "http://127.1/",
            "http://0x7f000001/",
            "http://169.254.1.2/",
            "http://172.16.0.1/",
            "http://" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "/",
            "http://198.18.0.1/",
            "http://224.0.0.1/",
        ]
        for rawURL in nonPublicAddresses {
            XCTAssertEqual(
                EmbeddedBrowserNavigationPolicy.decision(
                    for: URL(string: rawURL)),
                .block(.nonPublicIPAddress),
                rawURL)
        }
    }

    func testNavigationPolicyBlocksNonPublicIPv6Ranges() {
        let nonPublicAddresses = [
            "http://[::]/",
            "http://[::1]/",
            "http://[fc00::1]/",
            "http://[fd12:3456::1]/",
            "http://[fe80::1]/",
            "http://[ff02::1]/",
            "http://[2001:db8::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "]/",
        ]
        for rawURL in nonPublicAddresses {
            XCTAssertEqual(
                EmbeddedBrowserNavigationPolicy.decision(
                    for: URL(string: rawURL)),
                .block(.nonPublicIPAddress),
                rawURL)
        }
    }

    func testNavigationPolicyBlocksMissingOrUnsupportedTargets() {
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(for: nil),
            .block(.missingURL))
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "file:///tmp/private")),
            .block(.unsupportedScheme))
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "javascript:alert(1)")),
            .block(.unsupportedScheme))
        XCTAssertEqual(
            EmbeddedBrowserNavigationPolicy.decision(
                for: URL(string: "https:///missing-host")),
            .block(.missingHost))
    }

    func testResponsePolicyFailsClosedForAttachmentsAndUnsupportedContent() {
        let publicURL = URL(string: "https://example.com/file")!

        XCTAssertEqual(
            EmbeddedBrowserResponsePolicy.visibleError(
                url: publicURL,
                canShowMIMEType: true,
                contentDisposition: "attachment; filename=report.pdf"),
            .downloadBlocked)
        XCTAssertEqual(
            EmbeddedBrowserResponsePolicy.visibleError(
                url: publicURL,
                canShowMIMEType: false,
                contentDisposition: nil),
            .unsupportedContent)
        XCTAssertNil(
            EmbeddedBrowserResponsePolicy.visibleError(
                url: publicURL,
                canShowMIMEType: true,
                contentDisposition: "inline"))
        XCTAssertEqual(
            EmbeddedBrowserResponsePolicy.visibleError(
                url: URL(string: "http://127.0.0.1/file"),
                canShowMIMEType: true,
                contentDisposition: nil),
            .blockedNavigation(.nonPublicIPAddress))
    }

    func testEveryBlockedRuntimePathHasVisibleUserFacingText() {
        let errors: [EmbeddedBrowserVisibleError] = [
            .blockedNavigation(.missingURL),
            .blockedNavigation(.unsupportedScheme),
            .blockedNavigation(.missingHost),
            .blockedNavigation(.localHostname),
            .blockedNavigation(.nonPublicIPAddress),
            .popupBlocked,
            .downloadBlocked,
            .unsupportedContent,
            .sensitivePermissionBlocked(.camera),
            .loadFailed,
        ]

        for error in errors {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
        }
    }

    func testSiteToolDiscoveryReturnsOnlyStructuredPublicMetadata() {
        let valid = EmbeddedBrowserSiteToolMetadata(
            identifier: "read-title",
            title: "Read title",
            origin: URL(string: "https://example.com")!,
            effect: .readOnly)
        let blankIdentifier = EmbeddedBrowserSiteToolMetadata(
            identifier: " ",
            title: "Invalid",
            origin: URL(string: "https://example.com")!,
            effect: .readOnly)
        let privateOrigin = EmbeddedBrowserSiteToolMetadata(
            identifier: "internal",
            title: "Internal",
            origin: URL(string: "http://127.0.0.1")!,
            effect: .readOnly)

        XCTAssertEqual(
            EmbeddedBrowserSiteToolPolicy.discoveryMetadata(
                from: [valid, blankIdentifier, privateOrigin]),
            [valid])
        XCTAssertEqual(
            EmbeddedBrowserSiteToolPolicy.decision(for: valid),
            .ask)
    }

    func testSiteToolSideEffectsAlwaysRequireHumanApproval() {
        for effect in [
            EmbeddedBrowserSiteToolEffect.sideEffect,
            .highRisk,
        ] {
            let metadata = EmbeddedBrowserSiteToolMetadata(
                identifier: "mutating-action",
                title: "Mutating action",
                origin: URL(string: "https://example.com")!,
                effect: effect)
            XCTAssertEqual(
                EmbeddedBrowserSiteToolPolicy.decision(for: metadata),
                .requiresHumanApproval)
        }
    }

    func testBrowserDoesNotExposeCDPOrChromiumWebMCP() {
        XCTAssertFalse(EmbeddedBrowserAutomationExposurePolicy.exposesCDPEndpoint)
        XCTAssertFalse(EmbeddedBrowserAutomationExposurePolicy.supportsChromiumWebMCP)

        let configuration = WKWebViewConfiguration.tatwoBrowserConfiguration(
            profile: .ephemeral(UUID()))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable =
            EmbeddedBrowserAutomationExposurePolicy.exposesCDPEndpoint

        XCTAssertFalse(webView.isInspectable)
        XCTAssertFalse(
            configuration.preferences.javaScriptCanOpenWindowsAutomatically)
    }

    func testSensitivePermissionPolicyAlwaysDenies() {
        for permission in [
            EmbeddedBrowserSensitivePermission.camera,
            .microphone,
            .cameraAndMicrophone,
            .deviceOrientationAndMotion,
            .geolocation,
        ] {
            XCTAssertEqual(
                EmbeddedBrowserSensitivePermissionPolicy.decision(
                    for: permission),
                .deny)
        }
    }

    func testSessionLifecycleDeclaresWebKitCountAndCEFBytePoliciesSeparately() {
        XCTAssertEqual(
            EmbeddedBrowserSessionPersistenceContract.history,
            .boundedProfileJournal(maximumEntries: 32))
        XCTAssertGreaterThan(
            EmbeddedBrowserSessionPersistenceContract.maximumCEFProfileBytes,
            0)
    }

    func testCloneCreatesASeparateProfileWithoutCopyingGenerationOrData() throws {
        let root = temporaryProfileRoot()
        let store = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root,
            maximumPersistentProfileCount: 8)
        let source = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(for: "source"))
        let clone = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.clonedProfile(
                from: "source", to: "clone"))
        try store.recordAccess(
            profile: source,
            storageKind: .cefAppOwned,
            generation: 7)

        XCTAssertNotEqual(source.dataStoreIdentifier, clone.dataStoreIdentifier)
        XCTAssertFalse(try store.snapshot().entries.contains {
            $0.profileIdentifier == clone.dataStoreIdentifier
                || ($0.profileIdentifier == clone.dataStoreIdentifier
                    && $0.generation == 7)
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                clone.dataStoreIdentifier!.uuidString.lowercased()).path))
    }

    func testWebKitCountCeilingRemovesOnlyArchivedAndProtectsCurrentActive()
        async throws
    {
        let root = temporaryProfileRoot()
        let store = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root,
            maximumPersistentProfileCount: 3)
        let current = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let active = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let archived = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let inactiveLive = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        try store.recordAccess(profile: current)
        try store.recordAccess(profile: active)
        try store.recordAccess(profile: inactiveLive)
        try store.recordAccess(profile: archived, archived: true)
        let removed = ThreadSafeUUIDRecorder()

        let report = try await store.enforceWebKitCapacity(
            currentProfile: current,
            activeProfiles: [active],
            remover: { identifier in
                removed.append(identifier)
            })

        XCTAssertEqual(report.persistentProfileCountBeforeEviction, 4)
        XCTAssertEqual(report.persistentProfileCountAfterEviction, 3)
        XCTAssertEqual(removed.values, [archived.dataStoreIdentifier!])
        XCTAssertTrue(try store.snapshot().entries.contains {
            $0.profileIdentifier == current.dataStoreIdentifier
        })
        XCTAssertTrue(try store.snapshot().entries.contains {
            $0.profileIdentifier == active.dataStoreIdentifier
        })
        XCTAssertTrue(try store.snapshot().entries.contains {
            $0.profileIdentifier == inactiveLive.dataStoreIdentifier
        })
    }

    func testWebKitIdentifierRemovalUnsupportedIsTypedFailure() async throws {
        let store = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: temporaryProfileRoot(),
            maximumPersistentProfileCount: 1)
        let current = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let archived = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        try store.recordAccess(profile: current)
        try store.recordAccess(profile: archived, archived: true)

        do {
            _ = try await store.enforceWebKitCapacity(
                currentProfile: current,
                activeProfiles: [],
                remover: { _ in
                    throw EmbeddedBrowserProfileCapacityError
                        .unsupportedWebKitIdentifierRemoval
                })
            XCTFail("unsupported identifier removal must fail closed")
        } catch {
            XCTAssertEqual(
                error as? EmbeddedBrowserProfileCapacityError,
                .unsupportedWebKitIdentifierRemoval)
        }
    }

    func testCEFFlatOrphanCountsTowardCeilingAndEvictsBeforeLedgerRow()
        throws
    {
        let root = temporaryProfileRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let orphanID = UUID()
        let archivedID = UUID()
        let orphanURL = try store.profileURL(
            for: orphanID,
            generation: 0)
        let archivedURL = try store.profileURL(
            for: archivedID,
            generation: 0)
        for url in [orphanURL, archivedURL] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64).write(
                to: url.appendingPathComponent("payload.bin"))
        }
        let ledger = EmbeddedBrowserProfileCapacityLedger(entries: [
            EmbeddedBrowserProfileCapacityEntry(
                profileIdentifier: archivedID,
                storageKind: .cefAppOwned,
                generation: 0,
                lastAccessedAt: .distantPast,
                isArchived: true),
        ])
        var disposed: [URL] = []

        let result = try TatwoCEFProfileCeilingController(store: store)
            .enforce(
                byteCeiling: allocatedBytes(at: archivedURL),
                currentIdentifier: nil,
                activeIdentifiers: [],
                ledger: ledger,
                leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                removeLedgerRecord: { _ in },
                disposer: { disposed.append($0) })

        XCTAssertGreaterThan(
            result.bytesBefore,
            try allocatedBytes(at: archivedURL))
        XCTAssertEqual(disposed.map(\.path), [orphanURL.path])
        XCTAssertEqual(
            result.evictedProfiles,
            [
                TatwoCEFProfileCapacityRowKey(
                    profileIdentifier: orphanID,
                    generation: 0,
                    storageKind: .cefAppOwned),
            ])
        XCTAssertTrue(result.evictedLedgerRows.isEmpty)
    }

    func testNavigationJournalIsBoundedAndStripsCredentialsQueryAndFragment() {
        let urls = (0 ..< 50).map {
            URL(
                string:
                    "https://user:password@example.com/page/\($0)?token=secret#private")!
        }
        let journal = EmbeddedBrowserNavigationJournal(
            urls: urls,
            currentIndex: 49)

        XCTAssertEqual(journal?.entries.count, 32)
        XCTAssertEqual(journal?.currentIndex, 31)
        XCTAssertEqual(
            journal?.currentURL?.absoluteString,
            "https://example.com/page/49")
        XCTAssertTrue(
            journal?.entries.allSatisfy {
                !$0.contains("password")
                    && !$0.contains("token")
                    && !$0.contains("#")
            } == true)
    }

    func testNavigationJournalSurvivesStoreReconstructionButCloneStartsEmpty()
        throws
    {
        let root = temporaryProfileRoot()
        let originalStore = EmbeddedBrowserNavigationJournalStore(
            profileRoot: root)
        let sourceProfile =
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: "journal-source")!
        let cloneProfile =
            EmbeddedBrowserSessionPersistenceContract.clonedProfile(
                from: "journal-source",
                to: "journal-clone")!
        let journal = EmbeddedBrowserNavigationJournal(
            urls: [
                URL(string: "https://example.com/one?private=1")!,
                URL(string: "https://openai.com/two#fragment")!,
            ],
            currentIndex: 0)!

        try originalStore.save(journal, profile: sourceProfile)
        let reconstructedStore = EmbeddedBrowserNavigationJournalStore(
            profileRoot: root)

        XCTAssertEqual(
            reconstructedStore.load(profile: sourceProfile),
            journal)
        XCTAssertNil(reconstructedStore.load(profile: cloneProfile))
        XCTAssertNotEqual(
            reconstructedStore.journalFileURL(for: sourceProfile),
            reconstructedStore.journalFileURL(for: cloneProfile))
        XCTAssertTrue(
            reconstructedStore.journalFileURL(for: sourceProfile)?
                .path.hasPrefix(root.path) == true)
    }

    func testOriginDataPolicyMatchesOnlyTheRequestedHost() {
        let origin = EmbeddedBrowserOrigin(
            url: URL(string: "https://accounts.example.com/private")!)!

        XCTAssertTrue(
            EmbeddedBrowserOriginDataPolicy.recordDisplayName(
                "accounts.example.com",
                matches: origin))
        XCTAssertFalse(
            EmbeddedBrowserOriginDataPolicy.recordDisplayName(
                "example.com",
                matches: origin))
        XCTAssertFalse(
            EmbeddedBrowserOriginDataPolicy.recordDisplayName(
                "other.example.com",
                matches: origin))
    }

    func testSiteClearTransactionRemainsOriginScopedAndNeverUsesGlobalClear()
        async
    {
        let sessionID = "origin-scoped-session"
        let expectedIdentifier =
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID)?.dataStoreIdentifier
        var receivedIdentifier: UUID?
        var receivedOrigin: EmbeddedBrowserOrigin?
        var result: Result<Int, Error>?
        var callCount = 0
        let finished = expectation(description: "origin-scoped clear completed")
        let registry = EmbeddedBrowserWebViewRegistry()

        EmbeddedBrowserSiteDataClearingHook.clear(
            originURL: URL(
                string: "https://accounts.example.com/private")!,
            for: sessionID,
            registry: registry,
            originDataRemover: { identifier, origin, completion in
                callCount += 1
                receivedIdentifier = identifier
                receivedOrigin = origin
                completion(.success(1))
            },
            completion: {
                result = $0
                finished.fulfill()
            })

        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(receivedIdentifier, expectedIdentifier)
        XCTAssertEqual(receivedOrigin?.scheme, "https")
        XCTAssertEqual(receivedOrigin?.host, "accounts.example.com")
        XCTAssertEqual(receivedOrigin?.port, nil)
        XCTAssertEqual(callCount, 1)
        guard case .success(1)? = result else {
            return XCTFail("expected one origin-scoped record removal")
        }
    }

    func testProductionSiteMaintenanceCoordinatorUsesWebKitOriginHook()
        async
    {
        let sessionID = "production-webkit-site-clear"
        var capturedOrigin: EmbeddedBrowserOrigin?
        let coordinator = EmbeddedBrowserSiteDataMaintenanceCoordinator(
            webKitRegistry: EmbeddedBrowserWebViewRegistry(),
            cefRegistry: TatwoCEFProfileLeaseRegistry(),
            cefStore: nil,
            webKitOriginDataRemover: { _, origin, completion in
                capturedOrigin = origin
                completion(.success(3))
            })

        let result = await coordinator.clear(
            originURL: URL(
                string: "https://accounts.example.com/private")!,
            sessionID: sessionID,
            engine: .webKitLegacy)

        XCTAssertEqual(capturedOrigin?.canonicalString, "https://accounts.example.com")
        XCTAssertEqual(result, .success(.webKit(removedRecordCount: 3)))
    }

    func testProductionSiteMaintenanceCoordinatorUsesCEFOriginHookAndReportsCacheCapability()
        async throws
    {
        let sessionID = "production-cef-site-clear"
        let profile = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID))
        let identifier = try XCTUnwrap(profile.dataStoreIdentifier)
        let store = TatwoCEFProfileStore(
            rootCacheURL: temporaryProfileRoot())
        let expectedProfileURL = try store.profileURL(for: identifier)
        try FileManager.default.createDirectory(
            at: expectedProfileURL,
            withIntermediateDirectories: true)
        let invocationRecorder =
            ThreadSafeOriginClearInvocationRecorder()
        let receipt = TatwoCEFOriginDataClearReceipt(
            cookiesCleared: true,
            originStorageCleared: true,
            httpResponseCacheStatus: .unsupported)
        let coordinator = EmbeddedBrowserSiteDataMaintenanceCoordinator(
            webKitRegistry: EmbeddedBrowserWebViewRegistry(),
            cefRegistry: TatwoCEFProfileLeaseRegistry(),
            cefStore: store,
            cefOriginDataClearer: { origin, profilePath, completion in
                invocationRecorder.record(
                    origin: origin,
                    profilePath: profilePath)
                completion(.success(receipt))
            })

        let result = await coordinator.clear(
            originURL: URL(
                string: "https://accounts.example.com/private")!,
            sessionID: sessionID,
            engine: .chromiumCEF)

        XCTAssertEqual(
            invocationRecorder.snapshot.origin,
            "https://accounts.example.com")
        XCTAssertEqual(
            invocationRecorder.snapshot.profilePath,
            expectedProfileURL.path)
        XCTAssertEqual(result, .success(.chromiumCEF(receipt)))
        XCTAssertTrue(receipt.siteDataCleared)
        XCTAssertEqual(receipt.httpResponseCacheStatus, .unsupported)
    }

    func testProductionResetAndDeleteUseDurableLifecycleTransactions()
        async throws
    {
        let root = temporaryProfileRoot()
        let intentStore = EmbeddedBrowserLifecycleIntentStore(
            root: root.appendingPathComponent("intents", isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent("ledger", isDirectory: true),
            maximumPersistentProfileCount: 8)
        let sessionID = "production-reset"
        var removalCount = 0
        let reset = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .reset,
            sessionID: sessionID,
            registry: EmbeddedBrowserWebViewRegistry(),
            cefProfileStore: nil,
            requiresCEFProfilePurge: false,
            persistentDataStoreRemover: { _, completion in
                removalCount += 1
                completion(nil)
            },
            capacityLedgerStore: ledgerStore,
            intentStore: intentStore)
        let prepared = await reset.prepare()
        guard case let .success(receipt) = prepared else {
            return XCTFail("reset production route must prepare")
        }
        let committed = reset.commitProfileOnly(receipt: receipt)
        guard case let .success(committedReceipt) = committed else {
            return XCTFail("reset production route must commit")
        }
        XCTAssertEqual(committedReceipt.stage, .committed)
        XCTAssertEqual(removalCount, 1)
        XCTAssertNil(try intentStore.load(intentID: receipt.intentID))

        let delete = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .delete,
            sessionID: "production-delete",
            registry: EmbeddedBrowserWebViewRegistry(),
            cefProfileStore: nil,
            requiresCEFProfilePurge: false,
            persistentDataStoreRemover: { _, completion in
                removalCount += 1
                completion(nil)
            },
            capacityLedgerStore: ledgerStore,
            intentStore: intentStore)
        let deletePrepared = await delete.prepare()
        guard case let .success(deleteReceipt) = deletePrepared else {
            return XCTFail("delete production route must prepare")
        }
        XCTAssertEqual(deleteReceipt.disposition, .delete)
        XCTAssertEqual(deleteReceipt.stage, .purgedCommitRequired)
        guard case let .success(deleteCommitted) =
            delete.commitDeletedProfile(receipt: deleteReceipt)
        else {
            return XCTFail("delete production route must verify and commit")
        }
        XCTAssertEqual(deleteCommitted.stage, .committed)
        XCTAssertEqual(removalCount, 2)
        XCTAssertNil(try intentStore.load(intentID: deleteReceipt.intentID))
    }

    func testLegacyDeleteHookCannotBypassFormalDeleteGate() throws {
        let registry = EmbeddedBrowserWebViewRegistry()
        let sessionID = "legacy-delete-bypass"
        let profile = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID))
        let ownerID = UUID()
        guard case let .success(lease) = registry.acquire(
            profile: profile,
            ownerID: ownerID,
            make: { WKWebView() })
        else {
            return XCTFail("expected active profile lease")
        }
        var result: Result<Void, Error>?

        EmbeddedBrowserSessionDeletionHook.purgeProfile(
            forDeletedSessionID: sessionID,
            registry: registry,
            completion: { result = $0 })

        guard let result,
              case let .failure(error) = result
        else {
            return XCTFail("legacy delete must fail closed")
        }
        XCTAssertEqual(
            error as? EmbeddedBrowserSessionLifecycleError,
            .unsupportedFormalMutation(disposition: .delete))
        XCTAssertEqual(registry.activeLeaseCount, 1)
        XCTAssertTrue(
            registry.release(
                profile: profile,
                ownerID: ownerID,
                webView: lease.webView))
    }

    func testFormalChatArchiveAwaitsLifecycleBeforeThreadMutation() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent(
                "Sources/TatwoUltraworkMac/ChatPageModel+Workflows.swift"),
            encoding: .utf8)
        let prepare = try XCTUnwrap(
            source.range(of: "let prepared = await transaction.prepare()"))
        let revoke = try XCTUnwrap(
            source.range(of: "remoteBorrowAuthorizationStore.revokeSession"))
        let commit = try XCTUnwrap(
            source.range(of: "let committed = transaction.commit("))
        let mutation = try XCTUnwrap(
            source.range(of: "archived.isArchived = true"))
        let persist = try XCTUnwrap(
            source.range(of: "guard self.persistStore() else"))
        let archiveIssues = try XCTUnwrap(
            source.range(of: "if archiveIssues"))
        XCTAssertLessThan(prepare.lowerBound, revoke.lowerBound)
        XCTAssertLessThan(revoke.lowerBound, commit.lowerBound)
        XCTAssertLessThan(commit.lowerBound, mutation.lowerBound)
        XCTAssertLessThan(mutation.lowerBound, persist.lowerBound)
        XCTAssertLessThan(persist.lowerBound, archiveIssues.lowerBound)
        XCTAssertTrue(source.contains("selectedThreadID == threadID"))
        XCTAssertTrue(source.contains("boundProjectID(for: finalLocation) == projectID"))
    }

    func testBrowserRequestPolicyAddsGPCMinimizesReferrerAndPreservesOrigin()
        throws
    {
        let decision = BrowserRequestPolicyEvaluator.evaluate(
            requestURL: try XCTUnwrap(
                URL(string: "https://cdn.example.net/script.js")),
            referrerURL: try XCTUnwrap(
                URL(string: "https://www.example.com/private/path?q=secret")),
            originHeader: "https://www.example.com")

        XCTAssertTrue(decision.isAllowed)
        XCTAssertEqual(decision.secGPC, "1")
        XCTAssertEqual(
            decision.referrer,
            "https://www.example.com")
        XCTAssertEqual(
            decision.originHeader,
            "https://www.example.com",
            "Origin is evidence, not a header Tatwo rewrites")

        let credentialed = BrowserRequestPolicyEvaluator.evaluate(
            requestURL: try XCTUnwrap(
                URL(string: "https://user:pass@example.com/")),
            referrerURL: nil,
            originHeader: nil)
        XCTAssertFalse(credentialed.isAllowed)
    }

    func testThirdPartyCookieSameSitePolicyIsSchemeful() throws {
        let top = try XCTUnwrap(URL(string: "https://www.example.com/"))
        XCTAssertTrue(
            BrowserSameSitePolicy.isSameSite(
                top,
                try XCTUnwrap(
                    URL(string: "https://static.example.com/image.png"))))
        XCTAssertFalse(
            BrowserSameSitePolicy.isSameSite(
                top,
                try XCTUnwrap(
                    URL(string: "http://static.example.com/image.png"))))
        XCTAssertFalse(
            BrowserSameSitePolicy.isSameSite(
                top,
                try XCTUnwrap(
                    URL(string: "https://tracker.example.net/pixel"))))
        XCTAssertTrue(
            BrowserNetworkSecurityPolicy.default.blocksThirdPartyCookies)
    }

    func testLocalHostDenyListSupportsExactSuffixAndFailClosedJSON()
        throws
    {
        let document = BrowserHostDenyList.Document(
            schema: BrowserHostDenyList.Document.schema,
            exactHosts: ["blocked.example"],
            suffixes: ["tracking.example"])
        let list = try BrowserHostDenyList(
            jsonData: JSONEncoder().encode(document))

        XCTAssertTrue(list.blocks(host: "blocked.example"))
        XCTAssertFalse(list.blocks(host: "sub.blocked.example"))
        XCTAssertTrue(list.blocks(host: "tracking.example"))
        XCTAssertTrue(list.blocks(host: "img.tracking.example"))
        XCTAssertFalse(list.blocks(host: "example.com"))
        XCTAssertTrue(list.blocks(host: "invalid host"))

        let invalidSchema = BrowserHostDenyList.Document(
            schema: "unexpected",
            exactHosts: [],
            suffixes: [])
        XCTAssertThrowsError(
            try BrowserHostDenyList(
                jsonData: JSONEncoder().encode(invalidSchema)))
        XCTAssertThrowsError(
            try BrowserHostDenyList(
                exactHosts: ["https://not-a-host.example"],
                suffixes: []))
    }

    func testBundledAdminAndUserHostListsMergeWithoutLosingLayers()
        throws
    {
        let root = temporaryProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)

        func write(
            _ name: String,
            exactHosts: [String] = [],
            suffixes: [String] = []
        ) throws -> URL {
            let url = root.appendingPathComponent(name)
            let document = BrowserHostDenyList.Document(
                schema: BrowserHostDenyList.Document.schema,
                exactHosts: exactHosts,
                suffixes: suffixes)
            try JSONEncoder().encode(document).write(to: url)
            return url
        }

        let bundled = try write(
            "bundled.json",
            suffixes: ["ads.example"])
        let admin = try write(
            "admin.json",
            exactHosts: ["malware.example"])
        let user = try write(
            "user.json",
            suffixes: ["personal.example", "ads.example"])
        let list = try BrowserHostDenyListLoader.load(
            bundledAdminURL: bundled,
            adminURL: admin,
            userURL: user)

        XCTAssertEqual(list.exactHosts, ["malware.example"])
        XCTAssertEqual(
            list.suffixes,
            ["ads.example", "personal.example"])
        XCTAssertTrue(list.blocks(host: "cdn.ads.example"))
        XCTAssertTrue(list.blocks(host: "malware.example"))
        XCTAssertTrue(list.blocks(host: "img.personal.example"))
        XCTAssertFalse(list.blocks(host: "allowed.example"))
    }

    func testBundledHostListManifestPinsDigestAndCounts() throws {
        let verifiedURL =
            try BrowserBundledHostDenyList.verifiedResourceURL()
        let data = try Data(
            contentsOf: verifiedURL,
            options: [.mappedIfSafe])
        let list = try BrowserHostDenyList(jsonData: data)
        XCTAssertGreaterThan(list.suffixes.count, 50_000)
        XCTAssertTrue(list.exactHosts.isEmpty)

        let root = temporaryProfileRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let tamperedList = root.appendingPathComponent(
            "browser-host-deny-list.json")
        try (data + Data([0x0A])).write(to: tamperedList)
        let manifestURL = verifiedURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "browser-blocklists-manifest.json")
        XCTAssertThrowsError(
            try BrowserBundledHostDenyList.verify(
                listURL: tamperedList,
                manifestURL: manifestURL)
        ) { error in
            XCTAssertEqual(
                error as? BrowserBundledHostDenyList.VerificationError,
                .digestMismatch)
        }
    }

    func testPasswordMetadataExtractorNeverReturnsValuesAndFlagsRisk()
        throws
    {
        let metadata =
            try EmbeddedBrowserPasswordFormMetadataExtractor.metadata(
                fromJavaScriptResult: [
                    [
                        "hasPasswordField": true,
                        "actionOrigin": "http://pаypal.example",
                        "documentOrigin": "https://shop.example",
                    ],
                    [
                        "hasPasswordField": false,
                        "actionOrigin": "https://ignored.example",
                        "documentOrigin": "https://shop.example",
                    ],
                ])

        XCTAssertEqual(metadata.count, 1)
        let form = try XCTUnwrap(metadata.first)
        XCTAssertTrue(form.hasPasswordField)
        XCTAssertTrue(form.isHTTP)
        XCTAssertTrue(form.isCrossOrigin)
        XCTAssertTrue(form.hasIDNHost)
        XCTAssertTrue(
            form.hasMixedScriptHost || form.hasConfusableHost)

        let script =
            EmbeddedBrowserPasswordFormMetadataExtractor.javaScript
        XCTAssertTrue(script.contains("hasPasswordField"))
        XCTAssertTrue(script.contains("action.origin"))
        XCTAssertFalse(script.contains(".value"))
        XCTAssertFalse(script.contains("FormData"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("outerHTML"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("cookie"))
    }

    func testNavigationEpochCommitsAndInvalidatesWithoutSanitizerOutput() {
        var state = BrowserNavigationEpochState()
        XCTAssertFalse(state.isValid)
        XCTAssertTrue(state.didCommitMainFrameNavigation())
        XCTAssertEqual(state.navigationGeneration, 1)
        XCTAssertEqual(state.documentEpoch, 1)
        XCTAssertTrue(state.isValid)

        state.invalidate()
        XCTAssertEqual(state.navigationGeneration, 1)
        XCTAssertEqual(state.documentEpoch, 2)
        XCTAssertFalse(state.isValid)
        XCTAssertTrue(state.didCommitMainFrameNavigation())
        XCTAssertEqual(state.navigationGeneration, 2)
        XCTAssertEqual(state.documentEpoch, 3)
        XCTAssertTrue(state.isValid)

        XCTAssertFalse(
            BrowserSecurityFailureDomain.advisoryTrackerRules.failsClosed)
        for domain in [
            BrowserSecurityFailureDomain.privateNetwork,
            .localDenyList,
            .invalidCertificate,
            .profileIsolation,
        ] {
            XCTAssertTrue(domain.failsClosed, domain.rawValue)
        }
    }

    func testRequestPolicyAndDenyMatcherWarmedP99StayBelowOneMillisecond()
        throws
    {
        let listURL =
            try BrowserBundledHostDenyList.verifiedResourceURL()
        let list = try BrowserHostDenyList(
            jsonData: Data(
                contentsOf: listURL,
                options: [.mappedIfSafe]))
        XCTAssertGreaterThan(list.suffixes.count, 50_000)
        let blockedSuffix = try XCTUnwrap(list.suffixes.first)
        let blockedHost = "asset.\(blockedSuffix)"
        let requestURL = try XCTUnwrap(
            URL(string: "https://cdn.example.com/resource.js"))
        let referrerURL = try XCTUnwrap(
            URL(string: "https://www.example.com/private/path"))
        for _ in 0..<1_000 {
            _ = list.blocks(host: blockedHost)
            _ = BrowserRequestPolicyEvaluator.evaluate(
                requestURL: requestURL,
                referrerURL: referrerURL,
                originHeader: "https://www.example.com")
        }

        var durations: [UInt64] = []
        durations.reserveCapacity(10_000)
        for _ in 0..<10_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = list.blocks(host: blockedHost)
            _ = BrowserRequestPolicyEvaluator.evaluate(
                requestURL: requestURL,
                referrerURL: referrerURL,
                originHeader: "https://www.example.com")
            durations.append(
                DispatchTime.now().uptimeNanoseconds - start)
        }
        durations.sort()
        let p99Nanoseconds = durations[
            min(durations.count - 1, durations.count * 99 / 100)]
        print(
            "B32 request-policy warmed p99_ns=\(p99Nanoseconds) "
                + "target_ns=1000000 samples=\(durations.count)")
        XCTAssertLessThan(
            p99Nanoseconds,
            1_000_000,
            "request callback policy must not perform disk, network, or list compilation")
    }

    private func temporaryProfileRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-browser-tests-\(UUID().uuidString)",
                isDirectory: true)
    }

    private func allocatedBytes(at directory: URL) throws -> UInt64 {
        let payload = directory.appendingPathComponent("payload.bin")
        let values = try payload.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ])
        return UInt64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 64)
    }

    private func embeddedBrowserSource() throws -> String {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try ChatSourceFamily.read("EmbeddedBrowserView.swift")
    }

    private func writeProfilePayload(
        bytes: Int,
        profile: EmbeddedBrowserRuntimeProfile,
        root: URL
    ) throws {
        let identifier = try XCTUnwrap(profile.dataStoreIdentifier)
        let directory = root.appendingPathComponent(
            identifier.uuidString.lowercased(),
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(
            to: directory.appendingPathComponent("payload.bin"),
            options: .atomic)
    }

    private enum TestLifecycleError: Error {
        case webKitPurgeFailed
    }
}

private final class ThreadSafeUUIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [UUID] = []

    var values: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func append(_ value: UUID) {
        lock.lock()
        defer { lock.unlock() }
        recordedValues.append(value)
    }
}

private final class ThreadSafeOriginClearInvocationRecorder:
    @unchecked Sendable
{
    struct Snapshot: Equatable, Sendable {
        let origin: String?
        let profilePath: String?
    }

    private let lock = NSLock()
    private var origin: String?
    private var profilePath: String?

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            origin: origin,
            profilePath: profilePath)
    }

    func record(origin: String, profilePath: String) {
        lock.lock()
        defer { lock.unlock() }
        self.origin = origin
        self.profilePath = profilePath
    }
}
