import Foundation
import XCTest

@testable import TatwoUltraworkMac

@MainActor
final class ChromiumCEFSessionIsolationTests: XCTestCase {
    func testPersistentProfileLivesUnderRootCacheAndIsStable() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let canonicalRoot = root.resolvingSymlinksInPath()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let firstID = UUID()
        let secondID = UUID()

        let first = try store.profileURL(for: firstID)
        let reconstructed = try store.profileURL(for: firstID)
        let second = try store.profileURL(for: secondID)

        XCTAssertEqual(first, reconstructed)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.hasDirectoryPath)
        XCTAssertFalse(first.absoluteString.hasSuffix("/"))
        XCTAssertEqual(
            first.deletingLastPathComponent(),
            canonicalRoot,
            "CEF Chrome runtime requires every request-context cache_path to be an immediate child of root_cache_path")
        XCTAssertEqual(
            first.lastPathComponent,
            "tatwo-profile-\(firstID.uuidString.lowercased())-generation-0")
        XCTAssertFalse(first.pathComponents.contains("Default"))
        XCTAssertTrue(isDescendant(first, of: canonicalRoot))
    }

    func testCEFMountIdentityPreservesSessionIsolationAndEphemeralUnbound()
        throws
    {
        let first = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: "round62-session-a"))
        let reconstructed = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: "round62-session-a"))
        let second = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: "round62-session-b"))
        let unbound = EmbeddedBrowserRuntimeProfile.ephemeral(UUID())

        XCTAssertEqual(first, reconstructed)
        XCTAssertEqual(
            EmbeddedChromiumBrowserMountIdentity(profile: first),
            EmbeddedChromiumBrowserMountIdentity(profile: reconstructed))
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(
            EmbeddedChromiumBrowserMountIdentity(profile: first),
            EmbeddedChromiumBrowserMountIdentity(profile: second))
        XCTAssertNil(unbound.dataStoreIdentifier)
        XCTAssertNotEqual(unbound.registryKey, first.registryKey)
    }

    func testHumanAndAgentEphemeralProfilePolicyTagsCannotShare()
        throws
    {
        let profileID = UUID()
        let human = EmbeddedChromiumBrowserMountIdentity(
            profile: .persistent(profileID),
            profilePolicyTag: .humanPersistent)
        let agent = EmbeddedChromiumBrowserMountIdentity(
            profile: .ephemeral(UUID()),
            profilePolicyTag: .agentEphemeral)
        let secondHuman = EmbeddedChromiumBrowserMountIdentity(
            profile: .persistent(profileID),
            profilePolicyTag: .humanPersistent)

        XCTAssertTrue(human.mayShareRequestContext(with: secondHuman))
        XCTAssertFalse(human.mayShareRequestContext(with: agent))
        XCTAssertFalse(
            BrowserProfilePolicyTag.mayShareRequestContext(
                .humanEphemeral,
                .agentEphemeral))

        let root = temporaryRoot()
        let persistentLocation =
            try TatwoCEFProfileLocationResolver.resolve(
                profile: .persistent(profileID),
                rootCacheURL: root,
                helperExecutablePath: "/staging/Helper",
                logFilePath: root.appendingPathComponent("cef.log").path)
        let ephemeralLocation =
            try TatwoCEFProfileLocationResolver.resolve(
                profile: .ephemeral(UUID()),
                rootCacheURL: root,
                helperExecutablePath: "/staging/Helper",
                logFilePath: root.appendingPathComponent("cef.log").path)
        XCTAssertEqual(
            persistentLocation.profilePolicyTag,
            .humanPersistent)
        XCTAssertEqual(
            ephemeralLocation.profilePolicyTag,
            .humanEphemeral)
    }

    func testProfileURLIdentityDoesNotChangeWhenMissingRootIsCreated()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()
        let beforeRootExists = try store.profileURL(for: identifier)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let afterRootExists = try store.profileURL(for: identifier)

        XCTAssertEqual(beforeRootExists, afterRootExists)
        XCTAssertFalse(beforeRootExists.hasDirectoryPath)
        XCTAssertFalse(afterRootExists.hasDirectoryPath)
        XCTAssertFalse(beforeRootExists.absoluteString.hasSuffix("/"))
        XCTAssertFalse(afterRootExists.absoluteString.hasSuffix("/"))
        XCTAssertEqual(
            beforeRootExists.lastPathComponent,
            "tatwo-profile-\(identifier.uuidString.lowercased())-generation-0")
        XCTAssertEqual(
            beforeRootExists.deletingLastPathComponent().path,
            root.path)
    }

    func testProfileCeilingKeepsStableStoreLayoutAcrossRootCreation()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let controller = TatwoCEFProfileCeilingController(store: store)
        let identifier = UUID()
        let expectedBeforeRootExists = try store.profileURL(for: identifier)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path))
        let fixture = try capacityFixture(
            store: store,
            identifier: identifier,
            bytes: 2,
            accessedAt: Date(timeIntervalSince1970: 0),
            archived: true)
        let expectedAfterRootExists = try store.profileURL(for: identifier)
        var disposed: [URL] = []
        _ = try controller.enforce(
            byteCeiling: 1,
            currentIdentifier: nil,
            activeIdentifiers: [],
            ledger: EmbeddedBrowserProfileCapacityLedger(
                entries: [fixture.entry]),
            leaseRegistry: TatwoCEFProfileLeaseRegistry(),
            removeLedgerRecord: { _ in },
            disposer: { disposed.append($0) })

        XCTAssertEqual(expectedBeforeRootExists, expectedAfterRootExists)
        XCTAssertEqual(disposed, [expectedAfterRootExists])
        XCTAssertFalse(expectedAfterRootExists.hasDirectoryPath)
        XCTAssertFalse(expectedAfterRootExists.absoluteString.hasSuffix("/"))
        XCTAssertEqual(
            expectedAfterRootExists.lastPathComponent,
            "tatwo-profile-\(identifier.uuidString.lowercased())-generation-0")
        XCTAssertEqual(
            expectedAfterRootExists.deletingLastPathComponent().path,
            root.resolvingSymlinksInPath().path)
    }

    func testProfileURLRejectsSymlinkEscapeWhileLeafIsMissing() throws {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()
        let profileURL = root.appendingPathComponent(
            "tatwo-profile-\(identifier.uuidString.lowercased())-generation-0",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: profileURL,
            withDestinationURL: outside)

        XCTAssertThrowsError(try store.profileURL(for: identifier)) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .pathEscapesRootCache)
        }
    }

    func testPreparingPersistentProfileCreatesOnlyRootAndLeavesNewLeafForCEF()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()

        let profileURL = try store.prepareProfileParent(for: identifier)
        let profileParent = profileURL.deletingLastPathComponent()

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: profileParent.path,
                isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            profileParent.path,
            root.resolvingSymlinksInPath().path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileURL.path),
            "new direct-child cache_path stays absent until CreateContext initializes the profile")
    }

    func testPureResolveDoesNotCreateRuntimeDirectories() throws {
        let root = temporaryRoot()
        let identifier = UUID()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let profileURL = try store.profileURL(for: identifier)
        let logURL = root
            .appendingPathComponent("cef-logs", isDirectory: true)
            .appendingPathComponent("cef.log")

        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: logURL.path)

        XCTAssertEqual(location.persistentProfilePath, profileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: logURL.deletingLastPathComponent().path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: profileURL.deletingLastPathComponent().path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileURL.path))
    }

    func testRuntimeFacingPreparationRelocatesEmptyLegacyLeafAndReturnsExactCachePath()
        throws
    {
        let root = temporaryRoot()
        let identifier = UUID()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let profileURL = try store.profileURL(for: identifier)
        let legacyProfileURL = legacyNestedProfileURL(
            root: root,
            identifier: identifier,
            generation: 0)
        let logURL = root
            .appendingPathComponent("cef-logs", isDirectory: true)
            .appendingPathComponent("cef.log")
        try FileManager.default.createDirectory(
            at: legacyProfileURL,
            withIntermediateDirectories: true)

        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: logURL.path)

        let relocationRoot = root
            .appendingPathComponent(
                "legacy-empty-profile-relocations",
                isDirectory: true)
            .appendingPathComponent(
                identifier.uuidString.lowercased(),
                isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyProfileURL.path),
            "pure resolve must not relocate the legacy leaf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: relocationRoot.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: logURL.deletingLastPathComponent().path))

        let registry = TatwoCEFProfileLeaseRegistry()
        let lease = try XCTUnwrap(
            TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry))

        XCTAssertEqual(location.rootCachePath, root.path)
        XCTAssertEqual(location.persistentProfileIdentifier, identifier)
        XCTAssertEqual(location.persistentProfilePath, profileURL.path)
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: logURL.deletingLastPathComponent().path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: profileURL.deletingLastPathComponent().path))
        XCTAssertEqual(
            profileURL.deletingLastPathComponent().path,
            root.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileURL.path),
            "the new direct-child cache_path handed to CreateContext must remain absent")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyProfileURL.path))
        let relocationEntries = try FileManager.default.contentsOfDirectory(
            at: relocationRoot,
            includingPropertiesForKeys: nil,
            options: [])
        XCTAssertEqual(relocationEntries.count, 1)
        let relocation = try XCTUnwrap(relocationEntries.first)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: relocation
                    .appendingPathComponent(
                        "profile-leaf",
                        isDirectory: true)
                    .path))
        let receiptData = try Data(
            contentsOf: relocation.appendingPathComponent("receipt.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(
            TatwoCEFLegacyEmptyProfileRelocationReceipt.self,
            from: receiptData)
        XCTAssertEqual(
            receipt.originalRelativeLeaf,
            "profiles/\(identifier.uuidString.lowercased())/generation-0")
        XCTAssertEqual(
            receipt.relocatedRelativeLeaf,
            "legacy-empty-profile-relocations/"
                + "\(identifier.uuidString.lowercased())/"
                + "\(relocation.lastPathComponent)/profile-leaf")
        let receiptJSON = try XCTUnwrap(
            String(data: receiptData, encoding: .utf8))
        XCTAssertFalse(receiptJSON.contains(root.path))
        XCTAssertFalse(receiptJSON.contains(legacyProfileURL.path))
        XCTAssertFalse(receiptJSON.contains(relocation.path))
        XCTAssertTrue(registry.release(lease))
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 0)
    }

    func testPreparingProfileRelocatesOnlyEmptyLegacyLeafWithReceipt()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let legacyProfileURL = legacyNestedProfileURL(
            root: root,
            identifier: identifier,
            generation: 0)
        try FileManager.default.createDirectory(
            at: legacyProfileURL,
            withIntermediateDirectories: true)

        let preparedURL = try store.prepareProfileParent(for: identifier)

        XCTAssertEqual(preparedURL, profileURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: profileURL.path),
            "new direct-child profile must remain absent before CreateContext")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyProfileURL.path))
        let relocationRoot = root
            .appendingPathComponent(
                "legacy-empty-profile-relocations",
                isDirectory: true)
            .appendingPathComponent(
                identifier.uuidString.lowercased(),
                isDirectory: true)
        let relocationEntries = try FileManager.default
            .contentsOfDirectory(
                at: relocationRoot,
                includingPropertiesForKeys: nil,
                options: [])
        XCTAssertEqual(relocationEntries.count, 1)
        let relocation = try XCTUnwrap(relocationEntries.first)
        let relocatedLeaf = relocation
            .appendingPathComponent("profile-leaf", isDirectory: true)
        var relocatedIsDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: relocatedLeaf.path,
                isDirectory: &relocatedIsDirectory))
        XCTAssertTrue(relocatedIsDirectory.boolValue)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: relocatedLeaf.path).isEmpty)

        let receiptData = try Data(
            contentsOf: relocation.appendingPathComponent("receipt.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let receipt = try decoder.decode(
            TatwoCEFLegacyEmptyProfileRelocationReceipt.self,
            from: receiptData)
        XCTAssertEqual(
            receipt.schema,
            TatwoCEFLegacyEmptyProfileRelocationReceipt.schema)
        XCTAssertEqual(receipt.profileIdentifier, identifier)
        XCTAssertEqual(receipt.generation, 0)
        XCTAssertEqual(
            receipt.originalRelativeLeaf,
            "profiles/\(identifier.uuidString.lowercased())/generation-0")
        XCTAssertEqual(
            receipt.relocatedRelativeLeaf,
            "legacy-empty-profile-relocations/"
                + "\(identifier.uuidString.lowercased())/"
                + "\(relocation.lastPathComponent)/profile-leaf")
        let receiptJSON = try XCTUnwrap(
            String(data: receiptData, encoding: .utf8))
        XCTAssertFalse(receiptJSON.contains(root.path))
        XCTAssertFalse(receiptJSON.contains(legacyProfileURL.path))
        XCTAssertFalse(receiptJSON.contains(relocatedLeaf.path))
    }

    func testRuntimeFacingPreparationPreservesNonemptyLoginOrCookieState()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let cookieState = profileURL
            .appendingPathComponent("Cookies", isDirectory: false)
        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true)
        try Data("preserve-login-state".utf8).write(to: cookieState)

        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: root
                .appendingPathComponent("cef-logs", isDirectory: true)
                .appendingPathComponent("cef.log")
                .path)
        let registry = TatwoCEFProfileLeaseRegistry()
        let lease = try XCTUnwrap(
            TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry))

        XCTAssertEqual(location.persistentProfilePath, profileURL.path)
        XCTAssertEqual(
            try Data(contentsOf: cookieState),
            Data("preserve-login-state".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "legacy-empty-profile-relocations",
                    isDirectory: true).path))
        XCTAssertTrue(registry.release(lease))
    }

    func testRuntimePreparationFailsClosedWithoutMovingNonemptyLegacyLoginState()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let legacyProfileURL = legacyNestedProfileURL(
            root: root,
            identifier: identifier,
            generation: 0)
        let legacyCookieState = legacyProfileURL
            .appendingPathComponent("Cookies", isDirectory: false)
        try FileManager.default.createDirectory(
            at: legacyProfileURL,
            withIntermediateDirectories: true)
        try Data("preserve-legacy-login-state".utf8)
            .write(to: legacyCookieState)
        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: root
                .appendingPathComponent("cef-logs", isDirectory: true)
                .appendingPathComponent("cef.log")
                .path)

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .legacyProfileContainsData(path: legacyProfileURL.path))
        }

        XCTAssertEqual(location.persistentProfilePath, profileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        XCTAssertEqual(
            try Data(contentsOf: legacyCookieState),
            Data("preserve-legacy-login-state".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "legacy-empty-profile-relocations",
                    isDirectory: true).path))
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 0)
    }

    func testLegacyProfileSymlinkFailsClosedAfterLeaseAndPreservesLink()
        throws
    {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let legacyProfileURL = legacyNestedProfileURL(
            root: root,
            identifier: identifier,
            generation: 0)
        try FileManager.default.createDirectory(
            at: legacyProfileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: legacyProfileURL,
            withDestinationURL: outside)
        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: root
                .appendingPathComponent("cef-logs", isDirectory: true)
                .appendingPathComponent("cef.log")
                .path)

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .pathEscapesRootCache)
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: legacyProfileURL.path),
            outside.path)
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 0)
    }

    func testPureResolveRejectsAndPreservesSymlinkProfileLeaf()
        throws
    {
        let root = temporaryRoot()
        let outside = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profileURL,
            withDestinationURL: outside)

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.resolve(
                profile: .persistent(identifier),
                rootCacheURL: root,
                helperExecutablePath: "/staging/Helper",
                logFilePath: root
                    .appendingPathComponent("cef-logs", isDirectory: true)
                    .appendingPathComponent("cef.log")
                    .path)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .pathEscapesRootCache)
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: profileURL.path),
            outside.path)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "legacy-empty-profile-relocations",
                    isDirectory: true).path))
    }

    func testMaintenanceBlocksRuntimePreparationBeforeProfileMutation()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let legacyProfileURL = legacyNestedProfileURL(
            root: root,
            identifier: identifier,
            generation: 0)
        let logURL = root
            .appendingPathComponent("cef-logs", isDirectory: true)
            .appendingPathComponent("cef.log")
        try FileManager.default.createDirectory(
            at: legacyProfileURL,
            withIntermediateDirectories: true)
        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .persistent(identifier),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: logURL.path)
        let reservation = requireReservation(
            registry.reservePurge(identifier: identifier))

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileLeaseError,
                .profileBlockedForPurge)
        }

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacyProfileURL.path,
                isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: legacyProfileURL.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "legacy-empty-profile-relocations",
                    isDirectory: true).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: logURL.deletingLastPathComponent().path))
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 0)
        registry.cancelPurge(reservation)
    }

    func testPreparationFailureReleasesAcquiredLease() throws {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let actualProfileURL = try store.profileURL(for: identifier)
        let mismatchedPath = actualProfileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "tatwo-profile-\(identifier.uuidString.lowercased())-generation-999",
                isDirectory: true)
            .path
        let location = TatwoCEFProfileLocation(
            rootCachePath: root.path,
            authorityStagingRootPath: nil,
            persistentProfilePath: mismatchedPath,
            persistentProfileIdentifier: identifier,
            profilePolicyTag: .humanPersistent,
            helperExecutablePath: "/staging/Helper",
            logFilePath: root
                .appendingPathComponent("cef-logs", isDirectory: true)
                .appendingPathComponent("cef.log")
                .path)

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.prepareForRuntime(
                location,
                leaseRegistry: registry)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .preparedProfilePathMismatch(
                    expected: mismatchedPath,
                    actual: actualProfileURL.path))
        }
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: actualProfileURL.path))
    }

    func testEphemeralRuntimePreparationCreatesOnlyRootAndLogDirectories()
        throws
    {
        let root = temporaryRoot()
        let logURL = root
            .appendingPathComponent("cef-logs", isDirectory: true)
            .appendingPathComponent("cef.log")
        let registry = TatwoCEFProfileLeaseRegistry()
        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .ephemeral(UUID()),
            rootCacheURL: root,
            helperExecutablePath: "/staging/Helper",
            logFilePath: logURL.path)

        let lease = try TatwoCEFProfileLocationResolver.prepareForRuntime(
            location,
            leaseRegistry: registry)

        XCTAssertNil(location.persistentProfileIdentifier)
        XCTAssertNil(location.persistentProfilePath)
        XCTAssertNil(lease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: logURL.deletingLastPathComponent().path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "profiles",
                    isDirectory: true).path))
    }

    func testEpochRotationPreventsReusedSessionIDFromInheritingOldProfile()
        throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let identifier = UUID()
        let oldProfile = try store.profileURL(for: identifier)

        let returnedOldProfile = try store.rotateProfile(for: identifier)
        let newProfile = try store.profileURL(for: identifier)

        XCTAssertEqual(returnedOldProfile, oldProfile)
        XCTAssertNotEqual(newProfile, oldProfile)
        XCTAssertEqual(
            newProfile.lastPathComponent,
            "tatwo-profile-\(identifier.uuidString.lowercased())-generation-1")
        XCTAssertEqual(
            newProfile.deletingLastPathComponent().path,
            store.rootCacheURL.path)
        XCTAssertEqual(try store.currentGeneration(for: identifier), 1)
    }

    func testActiveCEFContextLeaseBlocksPurgeUntilReleased() throws {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let lease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))

        assertPurgeFailure(
            registry.reservePurge(identifier: identifier),
            equals: .profileInUse)
        XCTAssertTrue(registry.release(lease))

        let reservation = requireReservation(
            registry.reservePurge(identifier: identifier))
        XCTAssertTrue(registry.isBlocked(identifier))
        registry.cancelPurge(reservation)
        XCTAssertFalse(registry.isBlocked(identifier))
    }

    func testReturningSessionWaitsForPreviousCEFMountToClose() async throws {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let firstLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))

        assertLeaseFailure(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL),
            equals: .profileInUse)

        var resumed = false
        let waiter = Task { @MainActor in
            let outcome = await registry.waitUntilAvailable(
                identifier: identifier)
            resumed = true
            return outcome
        }
        await Task.yield()
        XCTAssertFalse(resumed)

        XCTAssertTrue(registry.release(firstLease))
        let outcome = await waiter.value
        XCTAssertEqual(outcome, .available)
        XCTAssertTrue(resumed)

        let returningLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 1)
        XCTAssertTrue(registry.release(returningLease))
    }

    func testCEFLeaseWaitTimesOutWhenPreviousMountNeverReleasesAndCanRetry()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let firstLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))

        let timedOut = await registry.waitUntilAvailable(
            identifier: identifier,
            timeoutNanoseconds: 5_000_000)

        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertEqual(registry.activeLeaseCount(for: identifier), 1)
        XCTAssertTrue(registry.release(firstLease))

        let retry = await registry.waitUntilAvailable(
            identifier: identifier,
            timeoutNanoseconds: 5_000_000)
        XCTAssertEqual(retry, .available)
        let returningLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))
        XCTAssertTrue(registry.release(returningLease))
    }

    func testCEFLeaseWaitTimeoutIsVisibleAndRetryRechecksAccess()
        async throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profile = EmbeddedBrowserRuntimeProfile.persistent(identifier)
        try FileManager.default.createDirectory(
            at: store.rootCacheURL,
            withIntermediateDirectories: true)
        let lease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: try store.profileURL(for: identifier)))
        let coordinator = EmbeddedBrowserProfileAccessCoordinator(
            ledgerStore: EmbeddedBrowserProfileCapacityLedgerStore(
                profileRoot: root.appendingPathComponent(
                    "ledger",
                    isDirectory: true),
                maximumPersistentProfileCount: 8),
            intentStore: EmbeddedBrowserLifecycleIntentStore(
                root: root.appendingPathComponent(
                    "intents",
                    isDirectory: true)),
            webKitRegistry: EmbeddedBrowserWebViewRegistry(),
            cefRegistry: registry,
            cefStore: store,
            cefLeaseWaitTimeoutNanoseconds: 5_000_000)

        let first = await coordinator.recordAccessAndEnforce(
            profile: profile,
            engine: .chromiumCEF)
        guard case let .failure(failure) = first else {
            return XCTFail("expected bounded CEF lease timeout")
        }
        XCTAssertEqual(
            failure,
            .cefLeaseWaitTimedOut(profileKey: identifier))
        XCTAssertTrue(failure.visibleMessage.contains("請重試"))

        XCTAssertTrue(registry.release(lease))
        let retry = await coordinator.recordAccessAndEnforce(
            profile: profile,
            engine: .chromiumCEF)
        if case let .failure(failure) = retry {
            XCTFail("expected retry to recheck access: \(failure)")
        }
    }

    func testCEFProfileCapacityEvictionRemovesProductionLedgerRow()
        async throws
    {
        let root = temporaryRoot()
        let cefStore = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let evictedIdentifier = UUID()
        let currentIdentifier = UUID()
        let evictedProfileURL = try cefStore.profileURL(
            for: evictedIdentifier)
        try FileManager.default.createDirectory(
            at: evictedProfileURL,
            withIntermediateDirectories: true)
        try Data([1, 2]).write(
            to: evictedProfileURL.appendingPathComponent("payload.bin"))
        try ledgerStore.recordAccess(
            profile: .persistent(evictedIdentifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true,
            at: Date(timeIntervalSince1970: 0))
        let coordinator = EmbeddedBrowserProfileAccessCoordinator(
            ledgerStore: ledgerStore,
            intentStore: EmbeddedBrowserLifecycleIntentStore(
                root: root.appendingPathComponent(
                    "intents",
                    isDirectory: true)),
            webKitRegistry: EmbeddedBrowserWebViewRegistry(),
            cefRegistry: TatwoCEFProfileLeaseRegistry(),
            cefStore: cefStore,
            cefProfileByteCeiling: 1)

        let result = await coordinator.recordAccessAndEnforce(
            profile: .persistent(currentIdentifier),
            engine: .chromiumCEF)

        if case let .failure(failure) = result {
            XCTFail("expected CEF capacity eviction: \(failure)")
        }
        let entries = try ledgerStore.snapshot().entries
        XCTAssertFalse(entries.contains {
            $0.profileIdentifier == evictedIdentifier
                && $0.storageKind == .cefAppOwned
        })
        XCTAssertTrue(entries.contains {
            $0.profileIdentifier == currentIdentifier
                && $0.storageKind == .cefAppOwned
        })
    }

    func testCEFLeaseWaitCancellationOnlyCancelsMatchingWaiter()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let firstLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))

        let staleWaiter = Task { @MainActor in
            await registry.waitUntilAvailable(
                identifier: identifier,
                timeoutNanoseconds: 1_000_000_000)
        }
        await Task.yield()
        staleWaiter.cancel()
        let staleOutcome = await staleWaiter.value
        XCTAssertEqual(staleOutcome, .cancelled)

        let currentWaiter = Task { @MainActor in
            await registry.waitUntilAvailable(
                identifier: identifier,
                timeoutNanoseconds: 1_000_000_000)
        }
        await Task.yield()
        XCTAssertTrue(registry.release(firstLease))

        let currentOutcome = await currentWaiter.value
        XCTAssertEqual(currentOutcome, .available)
        let returningLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))
        XCTAssertTrue(registry.release(returningLease))
    }

    func testCEFLeaseWaitResetCancelsStaleIdentityWithoutWakingReplacement()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        _ = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))

        let staleWaiter = Task { @MainActor in
            await registry.waitUntilAvailable(
                identifier: identifier,
                timeoutNanoseconds: 1_000_000_000)
        }
        await Task.yield()
        registry.resetForTesting()
        let staleOutcome = await staleWaiter.value
        XCTAssertEqual(staleOutcome, .cancelled)

        let replacementLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: profileURL))
        let replacementWaiter = Task { @MainActor in
            await registry.waitUntilAvailable(
                identifier: identifier,
                timeoutNanoseconds: 1_000_000_000)
        }
        await Task.yield()
        XCTAssertTrue(registry.release(replacementLease))
        let replacementOutcome = await replacementWaiter.value
        XCTAssertEqual(replacementOutcome, .available)
    }

    func testFailedDisposalRetryTargetsSameOldGeneration() async throws {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        var firstDisposedURL: URL?
        var retryDisposedURL: URL?
        let firstFinished = expectation(description: "first CEF purge failed")

        let firstReservation = requireReservation(
            registry.reservePurge(identifier: identifier))
        registry.commitPurge(
            firstReservation,
            store: store,
            disposer: { url, completion in
                firstDisposedURL = url
                completion(TestError.disposalFailed)
            }
        ) { result in
            guard case .failure = result else {
                return XCTFail("expected failed disposal")
            }
            firstFinished.fulfill()
        }
        await fulfillment(of: [firstFinished], timeout: 2)

        XCTAssertTrue(registry.isBlocked(identifier))
        XCTAssertEqual(try store.currentGeneration(for: identifier), 1)
        assertLeaseFailure(
            registry.acquire(
                identifier: identifier,
                profileURL: try store.profileURL(for: identifier)),
            equals: .profileBlockedForPurge)

        let retryFinished = expectation(description: "CEF purge retry succeeded")
        let retryReservation = requireReservation(
            registry.reservePurge(identifier: identifier))
        registry.commitPurge(
            retryReservation,
            store: store,
            disposer: { url, completion in
                retryDisposedURL = url
                completion(nil)
            }
        ) { result in
            guard case .success = result else {
                return XCTFail("expected successful retry")
            }
            retryFinished.fulfill()
        }
        await fulfillment(of: [retryFinished], timeout: 2)

        XCTAssertEqual(retryDisposedURL, firstDisposedURL)
        XCTAssertEqual(try store.currentGeneration(for: identifier), 1)
        XCTAssertFalse(registry.isBlocked(identifier))
    }

    func testResetPurgesWebKitThenCEFThenNavigationJournal() async throws {
        let webKitRegistry = EmbeddedBrowserWebViewRegistry()
        let cefRegistry = TatwoCEFProfileLeaseRegistry()
        let cefStore = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let journalStore = EmbeddedBrowserNavigationJournalStore(
            profileRoot: temporaryRoot())
        let sessionID = "cef-reset-session"
        let profile = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(for: sessionID))
        let journal = try XCTUnwrap(
            EmbeddedBrowserNavigationJournal(
                urls: [URL(string: "https://example.com/")!],
                currentIndex: 0))
        try journalStore.save(journal, profile: profile)
        var order: [String] = []
        var disposedURL: URL?
        let finished = expectation(description: "combined purge finished")

        EmbeddedBrowserSessionLifecycleHook.apply(
            .reset,
            to: sessionID,
            registry: webKitRegistry,
            cefProfileLeaseRegistry: cefRegistry,
            cefProfileStore: cefStore,
            persistentDataStoreRemover: { _, completion in
                order.append("webkit")
                completion(nil)
            },
            cefProfileDisposer: { url, completion in
                order.append("cef")
                disposedURL = url
                XCTAssertNotNil(journalStore.load(profile: profile))
                completion(nil)
            },
            navigationJournalStore: journalStore
        ) { result in
            order.append("journal")
            guard case .success = result else {
                return XCTFail("expected combined profile purge success")
            }
            XCTAssertNil(journalStore.load(profile: profile))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(order, ["webkit", "cef", "journal"])
        let identifier = try XCTUnwrap(profile.dataStoreIdentifier)
        XCTAssertEqual(
            disposedURL?.lastPathComponent,
            "tatwo-profile-\(identifier.uuidString.lowercased())-generation-0")
        XCTAssertEqual(
            try cefStore.currentGeneration(
                for: identifier),
            1)
    }

    func testWebKitPurgeFailureCancelsFreshCEFReservation() async throws {
        let webKitRegistry = EmbeddedBrowserWebViewRegistry()
        let cefRegistry = TatwoCEFProfileLeaseRegistry()
        let cefStore = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let sessionID = "webkit-failure-session"
        let identifier = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID)?.dataStoreIdentifier)
        let finished = expectation(description: "WebKit purge failed")

        EmbeddedBrowserSessionLifecycleHook.apply(
            .reset,
            to: sessionID,
            registry: webKitRegistry,
            cefProfileLeaseRegistry: cefRegistry,
            cefProfileStore: cefStore,
            persistentDataStoreRemover: { _, completion in
                completion(TestError.webKitRemovalFailed)
            },
            cefProfileDisposer: { _, _ in
                XCTFail("CEF disposer must not run after WebKit failure")
            },
            navigationJournalStore: EmbeddedBrowserNavigationJournalStore(
                profileRoot: temporaryRoot())
        ) { result in
            guard case .failure = result else {
                return XCTFail("expected WebKit purge failure")
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertFalse(cefRegistry.isBlocked(identifier))
        _ = requireLease(
            cefRegistry.acquire(
                identifier: identifier,
                profileURL: try cefStore.profileURL(for: identifier)))
    }

    func testActiveCEFLeaseFailsBeforeWebKitPurgeStarts() throws {
        let webKitRegistry = EmbeddedBrowserWebViewRegistry()
        let cefRegistry = TatwoCEFProfileLeaseRegistry()
        let cefStore = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let sessionID = "active-cef-context"
        let identifier = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID)?.dataStoreIdentifier)
        _ = requireLease(
            cefRegistry.acquire(
                identifier: identifier,
                profileURL: try cefStore.profileURL(for: identifier)))
        var webKitRemoverCalled = false
        var result: Result<Void, Error>?

        EmbeddedBrowserSessionLifecycleHook.apply(
            .reset,
            to: sessionID,
            registry: webKitRegistry,
            cefProfileLeaseRegistry: cefRegistry,
            cefProfileStore: cefStore,
            persistentDataStoreRemover: { _, _ in
                webKitRemoverCalled = true
            },
            navigationJournalStore: EmbeddedBrowserNavigationJournalStore(
                profileRoot: temporaryRoot()),
            completion: { result = $0 })

        XCTAssertFalse(webKitRemoverCalled)
        guard case let .failure(error)? = result else {
            return XCTFail("expected active CEF lease failure")
        }
        XCTAssertEqual(
            error as? TatwoCEFProfilePurgeError,
            .profileInUse)
    }

    func testOriginClearMaintenanceIsSessionSpecificAndReportsCacheUnsupported()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let targetID = UUID()
        let otherID = UUID()
        let targetURL = try store.profileURL(for: targetID)
        let otherURL = try store.profileURL(for: otherID)
        let activeTargetLease = requireLease(
            registry.acquire(
                identifier: targetID,
                profileURL: targetURL))

        assertOriginClearFailure(
            registry.reserveOriginDataClear(
                identifier: targetID,
                origin: "https://example.com",
                profileURL: targetURL),
            equals: .profileInUse)
        XCTAssertTrue(registry.release(activeTargetLease))

        let reservation = requireOriginClearReservation(
            registry.reserveOriginDataClear(
                identifier: targetID,
                origin: "https://EXAMPLE.com/",
                profileURL: targetURL))
        XCTAssertEqual(reservation.origin, "https://example.com")
        XCTAssertTrue(registry.isBlocked(targetID))

        let otherLease = requireLease(
            registry.acquire(
                identifier: otherID,
                profileURL: otherURL))
        XCTAssertEqual(registry.activeLeaseCount(for: otherID), 1)

        let finished = expectation(
            description: "origin site data clear completed")
        registry.commitOriginDataClear(
            reservation,
            store: store,
            clearer: { origin, profilePath, completion in
                XCTAssertEqual(origin, "https://example.com")
                XCTAssertEqual(profilePath, targetURL.path)
                completion(
                    .success(
                        TatwoCEFOriginDataClearReceipt(
                            cookiesCleared: true,
                            originStorageCleared: true,
                            httpResponseCacheStatus: .unsupported)))
            }
        ) { result in
            guard case let .success(receipt) = result else {
                return XCTFail("origin site data clear should succeed")
            }
            XCTAssertTrue(receipt.siteDataCleared)
            XCTAssertEqual(
                receipt.httpResponseCacheStatus,
                .unsupported)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertFalse(registry.isBlocked(targetID))
        XCTAssertTrue(registry.release(otherLease))
        _ = requireLease(
            registry.acquire(
                identifier: targetID,
                profileURL: targetURL))
    }

    func testOriginClearRejectsNonOriginURLAndMismatchedRetry()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)

        assertOriginClearFailure(
            registry.reserveOriginDataClear(
                identifier: identifier,
                origin: "https://example.com/account",
                profileURL: profileURL),
            equals: .invalidOrigin)

        let reservation = requireOriginClearReservation(
            registry.reserveOriginDataClear(
                identifier: identifier,
                origin: "https://example.com",
                profileURL: profileURL))
        let partialReceipt = TatwoCEFOriginDataClearReceipt(
            cookiesCleared: true,
            originStorageCleared: false,
            httpResponseCacheStatus: .unsupported)
        let finished = expectation(
            description: "origin storage clear returned partial receipt")
        registry.commitOriginDataClear(
            reservation,
            store: store,
            clearer: { _, _, completion in
                completion(
                    .failure(
                        .originStorageClearFailed(
                            code: 37,
                            receipt: partialReceipt)))
            },
            completion: { result in
                guard case let .failure(error) = result else {
                    return XCTFail("expected partial origin clear failure")
                }
                XCTAssertEqual(
                    error,
                    .originStorageClearFailed(
                        code: 37,
                        receipt: partialReceipt))
                finished.fulfill()
            })
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(registry.isBlocked(identifier))

        assertOriginClearFailure(
            registry.reserveOriginDataClear(
                identifier: identifier,
                origin: "https://other.example",
                profileURL: profileURL),
            equals: .maintenanceInProgress)
        let retry = requireOriginClearReservation(
            registry.reserveOriginDataClear(
                identifier: identifier,
                origin: "https://example.com",
                profileURL: profileURL))
        XCTAssertTrue(retry.retriesFailure)
        registry.cancelOriginDataClear(retry)
        XCTAssertTrue(registry.isBlocked(identifier))
    }

    func testOriginClearCrossExecutorCallbackCompletesExactlyOnce()
        async throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let reservation = requireOriginClearReservation(
            registry.reserveOriginDataClear(
                identifier: identifier,
                origin: "https://example.com",
                profileURL: profileURL))
        let receipt = TatwoCEFOriginDataClearReceipt(
            cookiesCleared: true,
            originStorageCleared: true,
            httpResponseCacheStatus: .unsupported)
        let callbacksIssued = CrossExecutorSignalProbe()
        let completionReceived = expectation(
            description: "registry delivered one terminal completion")
        let completionProbe = OriginClearCompletionProbe()

        registry.commitOriginDataClear(
            reservation,
            store: store,
            clearer: { _, _, completion in
                DispatchQueue.global().async {
                    completion(.success(receipt))
                    completion(.failure(.runtimeUnavailable))
                    callbacksIssued.signal()
                }
            },
            completion: { result in
                MainActor.preconditionIsolated()
                XCTAssertTrue(Thread.isMainThread)
                completionProbe.record(result)
                completionReceived.fulfill()
            })

        await fulfillment(of: [completionReceived], timeout: 2)
        let didIssueDuplicateCallbacks = await Task.detached {
            callbacksIssued.wait(timeoutSeconds: 2)
        }.value
        XCTAssertTrue(didIssueDuplicateCallbacks)
        await Task.yield()
        XCTAssertEqual(completionProbe.results, [.success(receipt)])
        XCTAssertFalse(registry.isBlocked(identifier))
    }

    func testProfileCeilingEvictsOnlyOldestEligibleArchivedProfile()
        throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let controller = TatwoCEFProfileCeilingController(store: store)
        let oldArchived = UUID()
        let recentArchived = UUID()
        let activeArchived = UUID()
        let currentArchived = UUID()
        let liveUnarchived = UUID()
        let now = Date()

        let fixtures = try [
            capacityFixture(
                store: store,
                identifier: oldArchived,
                bytes: 40,
                accessedAt: now.addingTimeInterval(-500),
                archived: true),
            capacityFixture(
                store: store,
                identifier: recentArchived,
                bytes: 40,
                accessedAt: now.addingTimeInterval(-100),
                archived: true),
            capacityFixture(
                store: store,
                identifier: activeArchived,
                bytes: 40,
                accessedAt: now.addingTimeInterval(-900),
                archived: true),
            capacityFixture(
                store: store,
                identifier: currentArchived,
                bytes: 40,
                accessedAt: now.addingTimeInterval(-1_000),
                archived: true),
            capacityFixture(
                store: store,
                identifier: liveUnarchived,
                bytes: 40,
                accessedAt: now.addingTimeInterval(-2_000),
                archived: false),
        ]
        let bytesBefore = fixtures.reduce(0) { $0 + $1.measuredBytes }
        let byteCeiling = bytesBefore - fixtures[0].measuredBytes

        var disposed: [URL] = []
        let result = try controller.enforce(
            byteCeiling: byteCeiling,
            currentIdentifier: currentArchived,
            activeIdentifiers: [activeArchived],
            ledger: EmbeddedBrowserProfileCapacityLedger(
                entries: fixtures.map(\.entry)),
            leaseRegistry: TatwoCEFProfileLeaseRegistry(),
            removeLedgerRecord: { _ in },
            disposer: { disposed.append($0) })

        XCTAssertEqual(result.bytesBefore, bytesBefore)
        XCTAssertEqual(result.bytesAfter, byteCeiling)
        XCTAssertEqual(
            result.evictedProfiles,
            [
                TatwoCEFProfileCapacityRowKey(
                    profileIdentifier: oldArchived,
                    generation: 0,
                    storageKind: .cefAppOwned),
            ])
        XCTAssertEqual(
            disposed,
            [try store.profileURL(for: oldArchived)])
    }

    func testProfileCeilingSkipsCandidateThatAcquiresLeaseAfterSnapshot()
        throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let controller = TatwoCEFProfileCeilingController(store: store)
        let registry = TatwoCEFProfileLeaseRegistry()
        let identifier = UUID()
        let fixture = try capacityFixture(
            store: store,
            identifier: identifier,
            bytes: 40,
            accessedAt: .distantPast,
            archived: true)
        let staleActiveSnapshot = registry.activeProfileIdentifiers
        let lease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: try store.profileURL(for: identifier)))
        var disposed: [URL] = []
        let byteCeiling = fixture.measuredBytes - 1

        XCTAssertThrowsError(
            try controller.enforce(
                byteCeiling: byteCeiling,
                currentIdentifier: nil,
                activeIdentifiers: staleActiveSnapshot,
                ledger: EmbeddedBrowserProfileCapacityLedger(
                    entries: [fixture.entry]),
                leaseRegistry: registry,
                removeLedgerRecord: { _ in },
                disposer: { disposed.append($0) })
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileCeilingError,
                .ceilingUnsatisfied(
                    totalBytes: fixture.measuredBytes,
                    byteCeiling: byteCeiling))
        }
        XCTAssertTrue(disposed.isEmpty)
        XCTAssertTrue(registry.release(lease))
    }

    func testProfileCeilingRemovesOnlyEvictedGenerationLedgerRow()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let identifier = UUID()
        let generationZeroURL = try store.profileURL(
            for: identifier,
            generation: 0)
        let generationOneURL = try store.profileURL(
            for: identifier,
            generation: 1)
        for url in [generationZeroURL, generationOneURL] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true)
            try Data(repeating: 1, count: 40).write(
                to: url.appendingPathComponent("payload.bin"))
        }
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true,
            at: .distantPast)
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 1,
            archived: false,
            at: Date())
        let generationOneBytes = try allocatedBytes(
            at: generationOneURL)
        let expectedKey = TatwoCEFProfileCapacityRowKey(
            profileIdentifier: identifier,
            generation: 0,
            storageKind: .cefAppOwned)

        let result = try TatwoCEFProfileCeilingController(store: store)
            .enforce(
                byteCeiling: generationOneBytes,
                currentIdentifier: nil,
                activeIdentifiers: [],
                ledger: try ledgerStore.snapshot(),
                leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                removeLedgerRecord: { row in
                    try ledgerStore.removeRecord(
                        profile: .persistent(row.profileIdentifier),
                        storageKind: row.storageKind,
                        generation: row.generation)
                },
                disposer: { _ in })

        XCTAssertEqual(result.evictedLedgerRows, [expectedKey])
        let remaining = try ledgerStore.snapshot().entries
        XCTAssertFalse(remaining.contains {
            $0.profileIdentifier == identifier && $0.generation == 0
        })
        XCTAssertTrue(remaining.contains {
            $0.profileIdentifier == identifier
                && $0.generation == 1
                && $0.storageKind == .cefAppOwned
        })
    }

    func testProfileCeilingPersistsFirstCleanupWhenSecondDisposerFails()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let firstID = UUID()
        let secondID = UUID()
        for (identifier, accessedAt) in [
            (firstID, Date(timeIntervalSince1970: 0)),
            (secondID, Date(timeIntervalSince1970: 1)),
        ] {
            let url = try store.profileURL(
                for: identifier,
                generation: 0)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true)
            try Data(repeating: 1, count: 40).write(
                to: url.appendingPathComponent("payload.bin"))
            try ledgerStore.recordAccess(
                profile: .persistent(identifier),
                storageKind: .cefAppOwned,
                generation: 0,
                archived: true,
                at: accessedAt)
        }
        let registry = TatwoCEFProfileLeaseRegistry()
        var disposalCount = 0

        XCTAssertThrowsError(
            try TatwoCEFProfileCeilingController(store: store)
                .enforce(
                    byteCeiling: 1,
                    currentIdentifier: nil,
                    activeIdentifiers: [],
                    ledger: try ledgerStore.snapshot(),
                    leaseRegistry: registry,
                    removeLedgerRecord: { row in
                        try ledgerStore.removeRecord(
                            profile: .persistent(
                                row.profileIdentifier),
                            storageKind: row.storageKind,
                            generation: row.generation)
                    },
                    disposer: { _ in
                        disposalCount += 1
                        if disposalCount == 2 {
                            throw TestError.disposalFailed
                        }
                    })
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileCeilingError,
                .reversibleDisposalFailed(
                    identifier: secondID,
                    generation: 0))
        }
        let remaining = try ledgerStore.snapshot().entries
        XCTAssertFalse(remaining.contains {
            $0.profileIdentifier == firstID
        })
        XCTAssertTrue(remaining.contains {
            $0.profileIdentifier == secondID
        })
        let postFailureLease = requireLease(
            registry.acquire(
                identifier: secondID,
                profileURL: try store.profileURL(
                    for: secondID,
                    generation: 0)))
        XCTAssertTrue(registry.release(postFailureLease))
    }

    func testProfileCeilingReconcilesMissingCEFDirectoryLedgerRow()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let identifier = UUID()
        try FileManager.default.createDirectory(
            at: store.rootCacheURL,
            withIntermediateDirectories: true)
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true)

        let result = try TatwoCEFProfileCeilingController(store: store)
            .enforce(
                byteCeiling: 1,
                currentIdentifier: nil,
                activeIdentifiers: [],
                ledger: try ledgerStore.snapshot(),
                leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                removeLedgerRecord: { row in
                    try ledgerStore.removeRecord(
                        profile: .persistent(row.profileIdentifier),
                        storageKind: row.storageKind,
                        generation: row.generation)
                })

        XCTAssertEqual(result.reconciledMissingLedgerRowCount, 1)
        XCTAssertTrue(try ledgerStore.snapshot().entries.isEmpty)
    }

    func testProfileCeilingLeavesLedgerUntouchedWhenRootReadFails()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let identifier = UUID()
        try FileManager.default.createDirectory(
            at: store.rootCacheURL,
            withIntermediateDirectories: true)
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true)
        let before = try ledgerStore.snapshot().entries
        var removalAttempted = false

        XCTAssertThrowsError(
            try TatwoCEFProfileCeilingController(store: store)
                .enforce(
                    byteCeiling: 1,
                    currentIdentifier: nil,
                    activeIdentifiers: [],
                    ledger: EmbeddedBrowserProfileCapacityLedger(
                        entries: before),
                    leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                    removeLedgerRecord: { _ in
                        removalAttempted = true
                    },
                    rootDirectoryContents: { _ in
                        throw POSIXError(.EACCES)
                    })
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertFalse(removalAttempted)
        XCTAssertEqual(try ledgerStore.snapshot().entries, before)
    }

    func testProfileCeilingRetainsLedgerRowWhenLeafProbeIsDenied()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(
            rootCacheURL: root.appendingPathComponent(
                "cef",
                isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let identifier = UUID()
        try FileManager.default.createDirectory(
            at: store.rootCacheURL,
            withIntermediateDirectories: true)
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true)
        let before = try ledgerStore.snapshot().entries
        var removalAttempted = false

        XCTAssertThrowsError(
            try TatwoCEFProfileCeilingController(store: store)
                .enforce(
                    byteCeiling: 1,
                    currentIdentifier: nil,
                    activeIdentifiers: [],
                    ledger: EmbeddedBrowserProfileCapacityLedger(
                        entries: before),
                    leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                    removeLedgerRecord: { _ in
                        removalAttempted = true
                    },
                    profileEntryProbe: { _ in
                        throw POSIXError(.EACCES)
                    })
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EACCES)
        }
        XCTAssertFalse(removalAttempted)
        XCTAssertEqual(try ledgerStore.snapshot().entries, before)
    }

    func testProfileCeilingReleasesReservationWhenLedgerRemovalFails()
        throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let identifier = UUID()
        let fixture = try capacityFixture(
            store: store,
            identifier: identifier,
            bytes: 40,
            accessedAt: .distantPast,
            archived: true)
        let registry = TatwoCEFProfileLeaseRegistry()

        XCTAssertThrowsError(
            try TatwoCEFProfileCeilingController(store: store)
                .enforce(
                    byteCeiling: 1,
                    currentIdentifier: nil,
                    activeIdentifiers: [],
                    ledger: EmbeddedBrowserProfileCapacityLedger(
                        entries: [fixture.entry]),
                    leaseRegistry: registry,
                    removeLedgerRecord: { _ in
                        throw TestError.ledgerRemovalFailed
                    },
                    disposer: { _ in })
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileCeilingError,
                .reversibleDisposalFailed(
                    identifier: identifier,
                    generation: 0))
        }
        let postFailureLease = requireLease(
            registry.acquire(
                identifier: identifier,
                profileURL: try store.profileURL(
                    for: identifier,
                    generation: 0)))
        XCTAssertTrue(registry.release(postFailureLease))
    }

    func testProfileCeilingRefusesActiveOrCurrentEvictionBeforeDisposal()
        throws
    {
        let store = TatwoCEFProfileStore(rootCacheURL: temporaryRoot())
        let controller = TatwoCEFProfileCeilingController(store: store)
        let activeID = UUID()
        let currentID = UUID()
        let archivedID = UUID()
        let now = Date()
        let fixtures = try [
            capacityFixture(
                store: store,
                identifier: activeID,
                bytes: 80,
                accessedAt: now.addingTimeInterval(-300),
                archived: true),
            capacityFixture(
                store: store,
                identifier: currentID,
                bytes: 80,
                accessedAt: now.addingTimeInterval(-200),
                archived: true),
            capacityFixture(
                store: store,
                identifier: archivedID,
                bytes: 20,
                accessedAt: now.addingTimeInterval(-100),
                archived: true),
        ]
        let totalBytes = fixtures.reduce(0) { $0 + $1.measuredBytes }
        let byteCeiling =
            totalBytes - fixtures.last!.measuredBytes - 1
        var disposerCalled = false

        XCTAssertThrowsError(
            try controller.enforce(
                byteCeiling: byteCeiling,
                currentIdentifier: currentID,
                activeIdentifiers: [activeID],
                ledger: EmbeddedBrowserProfileCapacityLedger(
                    entries: fixtures.map(\.entry)),
                leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                removeLedgerRecord: { _ in },
                disposer: { _ in disposerCalled = true })
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileCeilingError,
                .ceilingUnsatisfied(
                    totalBytes: totalBytes,
                    byteCeiling: byteCeiling))
        }
        XCTAssertFalse(disposerCalled)
    }

    func testProfileCeilingRejectsSymbolicLinkAtStoreDerivedProfilePath()
        throws
    {
        let root = temporaryRoot()
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let controller = TatwoCEFProfileCeilingController(store: store)
        let identifier = UUID()
        let profileURL = try store.profileURL(for: identifier)
        let linkTarget = root.appendingPathComponent(
            "link-target",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkTarget,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profileURL,
            withDestinationURL: linkTarget)
        let entry = EmbeddedBrowserProfileCapacityEntry(
            profileIdentifier: identifier,
            storageKind: .cefAppOwned,
            generation: 0,
            lastAccessedAt: Date(timeIntervalSince1970: 0),
            isArchived: true)
        var disposerCalled = false

        XCTAssertThrowsError(
            try controller.enforce(
                byteCeiling: 100,
                currentIdentifier: nil,
                activeIdentifiers: [],
                ledger: EmbeddedBrowserProfileCapacityLedger(
                    entries: [entry]),
                leaseRegistry: TatwoCEFProfileLeaseRegistry(),
                removeLedgerRecord: { _ in },
                disposer: { _ in disposerCalled = true })
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileCeilingError,
                .invalidProfilePath(
                    identifier: identifier,
                    generation: 0))
        }
        XCTAssertFalse(disposerCalled)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-cef-isolation-\(UUID().uuidString)",
                isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    func testAuthorityRootRejectsExistingRuntimeSymlink() throws {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try FileManager.default.createSymbolicLink(
            at: fixture.stagingRoot.appendingPathComponent(
                "runtime",
                isDirectory: true),
            withDestinationURL: fixture.outside)

        XCTAssertNil(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL))
    }

    func testAuthorityRootAcceptsMissingComponentsInsideStaging() throws {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }

        XCTAssertEqual(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL),
            fixture.stagingRoot
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("cef-root", isDirectory: true)
                .standardizedFileURL)
    }

    func testAuthorityRootRejectsDanglingCEFSymlink() throws {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let runtime = fixture.stagingRoot.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runtime.appendingPathComponent("cef-root", isDirectory: true),
            withDestinationURL: fixture.outside.appendingPathComponent(
                "missing",
                isDirectory: true))

        XCTAssertNil(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL))
    }

    func testAuthorityRootRejectsChainedCEFSymlink() throws {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let runtime = fixture.stagingRoot.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        let second = runtime.appendingPathComponent(
            "second-link",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: second,
            withDestinationURL: fixture.outside)
        try FileManager.default.createSymbolicLink(
            at: runtime.appendingPathComponent("cef-root", isDirectory: true),
            withDestinationURL: second)

        XCTAssertNil(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL))
    }

    func testAuthorityRootRejectsCEFLogsSymlink() throws {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let runtime = fixture.stagingRoot.appendingPathComponent(
            "runtime",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runtime.appendingPathComponent(
                "cef-logs",
                isDirectory: true),
            withDestinationURL: fixture.outside)

        XCTAssertNil(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL))
    }

    func testRuntimePreparationRevalidatesAuthorityAfterSymlinkReplacement()
        throws
    {
        let fixture = try authorityRootFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let rootCache = try XCTUnwrap(
            TatwoCEFProfileLocationResolver.rootCacheURL(
                stagingRootURL: fixture.stagingRoot,
                bundleURL: fixture.bundleURL))
        let location = try TatwoCEFProfileLocationResolver.resolve(
            profile: .ephemeral(UUID()),
            rootCacheURL: rootCache,
            authorityStagingRootURL: fixture.stagingRoot,
            helperExecutablePath: "/staging/Helper",
            logFilePath: fixture.stagingRoot
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("cef-logs", isDirectory: true)
                .appendingPathComponent("cef.log")
                .path)
        try FileManager.default.createSymbolicLink(
            at: fixture.stagingRoot.appendingPathComponent(
                "runtime",
                isDirectory: true),
            withDestinationURL: fixture.outside)

        XCTAssertThrowsError(
            try TatwoCEFProfileLocationResolver.prepareForRuntime(location)
        ) { error in
            XCTAssertEqual(
                error as? TatwoCEFProfileStoreError,
                .pathEscapesRootCache)
        }
    }

    func testProductionCapacityLedgerDoesNotPersistProfilePath() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TatwoCEFProfileStore(rootCacheURL: root)
        let ledgerRoot = root.appendingPathComponent(
            "ledger",
            isDirectory: true)
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: ledgerRoot,
            maximumPersistentProfileCount: 8)
        let identifier = UUID()
        try ledgerStore.recordAccess(
            profile: .persistent(identifier),
            storageKind: .cefAppOwned,
            generation: 0,
            archived: true,
            at: Date(timeIntervalSince1970: 0))

        let ledgerURL = ledgerRoot.appendingPathComponent(
            "profile-capacity-ledger-v2.json")
        let data = try Data(contentsOf: ledgerURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(
            json.contains(try store.profileURL(for: identifier).path))
        XCTAssertFalse(json.contains("\"profilePath\""))
        XCTAssertFalse(json.contains("\"profileLeaf\""))
        XCTAssertTrue(json.contains(identifier.uuidString.uppercased()))
    }

    private func authorityRootFixture() throws -> (
        container: URL,
        stagingRoot: URL,
        bundleURL: URL,
        outside: URL
    ) {
        let container = temporaryRoot()
        let stagingRoot = container.appendingPathComponent(
            "staging",
            isDirectory: true)
        let bundleURL = stagingRoot.appendingPathComponent(
            "Tatwo Ultrawork Staging.app",
            isDirectory: true)
        let outside = container.appendingPathComponent(
            "outside",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true)
        return (container, stagingRoot, bundleURL, outside)
    }

    private func legacyNestedProfileURL(
        root: URL,
        identifier: UUID,
        generation: UInt64
    ) -> URL {
        root
            .appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(
                identifier.uuidString.lowercased(),
                isDirectory: true)
            .appendingPathComponent(
                "generation-\(generation)",
                isDirectory: true)
            .standardizedFileURL
    }

    private func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents
        return childComponents.count > parentComponents.count
            && Array(childComponents.prefix(parentComponents.count))
                == parentComponents
    }

    func testFinalMutationSuccessCommittedSaveFailureRetriesWithoutRepeatingSideEffect()
        async throws
    {
        let root = temporaryRoot()
        let committedSaveFailure = OneShotIntentStoreFailure(
            operation: .save(stage: .committed))
        let intentStore = EmbeddedBrowserLifecycleIntentStore(
            root: root.appendingPathComponent("intents", isDirectory: true),
            failureInjector: committedSaveFailure.shouldFail)
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent("ledger", isDirectory: true),
            maximumPersistentProfileCount: 8)
        let journalStore = EmbeddedBrowserNavigationJournalStore(
            profileRoot: root.appendingPathComponent("journals", isDirectory: true))
        let sessionID = "purge-commit-retry"
        let transaction = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .reset,
            sessionID: sessionID,
            registry: EmbeddedBrowserWebViewRegistry(),
            cefProfileStore: nil,
            requiresCEFProfilePurge: false,
            persistentDataStoreRemover: { _, completion in completion(nil) },
            navigationJournalStore: journalStore,
            capacityLedgerStore: ledgerStore,
            intentStore: intentStore)

        let prepared = await transaction.prepare()
        guard case let .success(receipt) = prepared else {
            return XCTFail("purge should reach durable commit-required stage")
        }
        XCTAssertEqual(receipt.stage, .purgedCommitRequired)
        let mutation = FinalMutationProbe()
        let contract = EmbeddedBrowserFinalMutationContract(
            idempotencyKey:
                "reset-test:\(receipt.intentID.uuidString.lowercased())",
            alreadyApplied: { _ in mutation.applied },
            apply: { _ in
                mutation.applyCount += 1
                mutation.applied = true
            })

        let failed = transaction.commit(
            receipt: receipt,
            finalMutation: contract)
        guard case let .failure(.intentStoreFailed(stage, intentID)) = failed else {
            return XCTFail("committed save failure must retain typed recovery state")
        }
        XCTAssertEqual(intentID, receipt.intentID)
        XCTAssertEqual(stage, .committed)
        XCTAssertEqual(
            try intentStore.load(intentID: receipt.intentID)?.stage,
            .finalMutationApplied)
        XCTAssertEqual(mutation.applyCount, 1)

        let retriedPrepare = await transaction.prepare()
        guard case let .success(retryReceipt) = retriedPrepare else {
            return XCTFail("retry must recover final-mutation-applied intent")
        }
        XCTAssertEqual(retryReceipt.stage, .finalMutationApplied)
        let committed = transaction.commit(
            receipt: retryReceipt,
            finalMutation: contract)
        guard case let .success(committedReceipt) = committed else {
            return XCTFail("retry should commit without replaying side effect")
        }
        XCTAssertEqual(committedReceipt.stage, .committed)
        XCTAssertNil(try intentStore.load(intentID: receipt.intentID))
        XCTAssertEqual(mutation.applyCount, 1)
    }

    func testArchivePreparationPreservesProfileAndExpressesFinalMutationGate()
        async throws
    {
        let root = temporaryRoot()
        let intentStore = EmbeddedBrowserLifecycleIntentStore(
            root: root.appendingPathComponent("archive-intents", isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent("archive-ledger", isDirectory: true),
            maximumPersistentProfileCount: 8)
        let sessionID = "archive-preserve-gate"
        let profile = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(for: sessionID))
        try ledgerStore.recordAccess(profile: profile)
        let transaction = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .archive,
            sessionID: sessionID,
            registry: EmbeddedBrowserWebViewRegistry(),
            cefProfileStore: nil,
            requiresCEFProfilePurge: false,
            capacityLedgerStore: ledgerStore,
            intentStore: intentStore)

        let prepared = await transaction.prepare()
        guard case let .success(receipt) = prepared else {
            return XCTFail("archive ledger commit should prepare")
        }
        XCTAssertEqual(receipt.stage, .archivePrepared)
        XCTAssertTrue(receipt.profileWasPreserved)
        let pending = try XCTUnwrap(ledgerStore.snapshot().entries.first)
        XCTAssertFalse(pending.isArchived)
        XCTAssertEqual(pending.pendingArchiveIntentID, receipt.intentID)
        let mutation = FinalMutationProbe()
        let committed = transaction.commit(
            receipt: receipt,
            finalMutation: EmbeddedBrowserFinalMutationContract(
                idempotencyKey:
                    "archive-test:\(receipt.intentID.uuidString.lowercased())",
                alreadyApplied: { _ in mutation.applied },
                apply: { _ in
                    mutation.applyCount += 1
                    mutation.applied = true
                }))
        XCTAssertEqual(mutation.applyCount, 1)
        guard case let .success(finalReceipt) = committed else {
            return XCTFail("archive final mutation gate should commit")
        }
        XCTAssertEqual(finalReceipt.stage, .committed)
        let archived = try XCTUnwrap(ledgerStore.snapshot().entries.first)
        XCTAssertTrue(archived.isArchived)
        XCTAssertNil(archived.pendingArchiveIntentID)
    }

    func testArchiveEligibilityCommitAcrossWebKitAndCEFIsAtomic()
        throws
    {
        let root = temporaryRoot()
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent(
                "atomic-archive-ledger",
                isDirectory: true),
            maximumPersistentProfileCount: 8)
        let profile = EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let intentID = UUID()
        try ledgerStore.markPendingArchive(
            profile: profile,
            intentID: intentID,
            storageKind: .webKitPersistent,
            generation: 0)

        XCTAssertThrowsError(
            try ledgerStore.commitArchiveAtomically(
                profile: profile,
                intentID: intentID,
                cefGeneration: 0))

        let webKitEntry = try XCTUnwrap(
            ledgerStore.snapshot().entries.first(where: {
                $0.storageKind == .webKitPersistent
            }))
        XCTAssertFalse(webKitEntry.isArchived)
        XCTAssertEqual(webKitEntry.pendingArchiveIntentID, intentID)
    }

    func testArchiveSelectionDriftAbortCannotMakeLiveThreadAnEvictionCandidate()
        async throws
    {
        try await assertAbortedArchiveRemainsCapacityIneligible(
            scenario: "selection-drift",
            failFinalMutation: false)
    }

    func testArchiveRemoteRevokeAbortCannotMakeLiveThreadAnEvictionCandidate()
        async throws
    {
        try await assertAbortedArchiveRemainsCapacityIneligible(
            scenario: "remote-revoke",
            failFinalMutation: false)
    }

    func testArchiveFinalMutationFailureCannotMakeLiveThreadAnEvictionCandidate()
        async throws
    {
        try await assertAbortedArchiveRemainsCapacityIneligible(
            scenario: "final-mutation",
            failFinalMutation: true)
    }

    func testWebKitCapacityRemoverHopsToMainActorFromDetachedEnforcement()
        async throws
    {
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: temporaryRoot(),
            maximumPersistentProfileCount: 1)
        let archivedProfile =
            EmbeddedBrowserRuntimeProfile.persistent(UUID())
        let currentProfile =
            EmbeddedBrowserRuntimeProfile.persistent(UUID())
        try ledgerStore.recordAccess(
            profile: archivedProfile,
            archived: true,
            at: Date(timeIntervalSince1970: 0))
        try ledgerStore.recordAccess(
            profile: currentProfile,
            at: Date(timeIntervalSince1970: 1))
        let removed = LockedUUIDArray()

        let report = try await Task.detached {
            try await ledgerStore.enforceWebKitCapacity(
                currentProfile: currentProfile,
                activeProfiles: [currentProfile],
                remover: { identifier in
                    MainActor.preconditionIsolated()
                    XCTAssertTrue(Thread.isMainThread)
                    removed.append(identifier)
                })
        }.value

        XCTAssertEqual(
            removed.snapshot,
            [try XCTUnwrap(archivedProfile.dataStoreIdentifier)])
        XCTAssertEqual(
            report.evictedProfileIdentifiers,
            removed.snapshot)
        XCTAssertEqual(
            report.persistentProfileCountAfterEviction,
            1)
    }

    private func assertAbortedArchiveRemainsCapacityIneligible(
        scenario: String,
        failFinalMutation: Bool
    ) async throws {
        let root = temporaryRoot()
            .appendingPathComponent(scenario, isDirectory: true)
        let intentStore = EmbeddedBrowserLifecycleIntentStore(
            root: root.appendingPathComponent("intents", isDirectory: true))
        let ledgerStore = EmbeddedBrowserProfileCapacityLedgerStore(
            profileRoot: root.appendingPathComponent("ledger", isDirectory: true),
            maximumPersistentProfileCount: 1)
        let sessionID = "archive-abort-\(scenario)"
        let profile = try XCTUnwrap(
            EmbeddedBrowserSessionPersistenceContract.profile(
                for: sessionID))
        let previouslyArchived =
            EmbeddedBrowserRuntimeProfile.persistent(UUID())
        try ledgerStore.recordAccess(
            profile: previouslyArchived,
            archived: true,
            at: Date(timeIntervalSince1970: 1))
        try ledgerStore.recordAccess(
            profile: profile,
            at: Date(timeIntervalSince1970: 2))
        let transaction = EmbeddedBrowserSessionLifecycleTransaction(
            disposition: .archive,
            sessionID: sessionID,
            registry: EmbeddedBrowserWebViewRegistry(),
            cefProfileStore: nil,
            requiresCEFProfilePurge: false,
            capacityLedgerStore: ledgerStore,
            intentStore: intentStore)

        let prepared = await transaction.prepare()
        guard case let .success(receipt) = prepared else {
            return XCTFail("archive preparation should create pending intent")
        }
        if failFinalMutation {
            let failed = transaction.commit(
                receipt: receipt,
                finalMutation: EmbeddedBrowserFinalMutationContract(
                    idempotencyKey:
                        "archive-abort:\(receipt.intentID.uuidString.lowercased())",
                    alreadyApplied: { _ in false },
                    apply: { _ in throw ArchiveAbort.injected }))
            guard case .failure(.finalMutationFailed(_, _, _)) = failed else {
                return XCTFail("expected typed final mutation failure")
            }
        }

        let pending = try XCTUnwrap(
            ledgerStore.snapshot().entries.first(where: {
                $0.profileIdentifier == profile.dataStoreIdentifier
            }))
        XCTAssertFalse(pending.isArchived)
        XCTAssertEqual(pending.pendingArchiveIntentID, receipt.intentID)

        let removed = LockedUUIDArray()
        let report = try await ledgerStore.enforceWebKitCapacity(
            currentProfile: nil,
            activeProfiles: [],
            remover: { identifier in
                removed.append(identifier)
            })

        XCTAssertEqual(
            removed.snapshot,
            [try XCTUnwrap(previouslyArchived.dataStoreIdentifier)])
        XCTAssertEqual(
            report.evictedProfileIdentifiers,
            [try XCTUnwrap(previouslyArchived.dataStoreIdentifier)])
        let remaining = try ledgerStore.snapshot().entries
        XCTAssertTrue(remaining.contains {
            $0.profileIdentifier == profile.dataStoreIdentifier
                && !$0.isArchived
                && $0.pendingArchiveIntentID == receipt.intentID
        })
    }

    private enum ArchiveAbort: Error {
        case injected
    }

    private func requireLease(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.Lease,
            TatwoCEFProfileLeaseError
        >
    ) -> TatwoCEFProfileLeaseRegistry.Lease {
        switch result {
        case let .success(lease):
            return lease
        case let .failure(error):
            XCTFail("expected lease, got \(error)")
            fatalError("unreachable")
        }
    }

    private func requireReservation(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.PurgeReservation,
            TatwoCEFProfilePurgeError
        >
    ) -> TatwoCEFProfileLeaseRegistry.PurgeReservation {
        switch result {
        case let .success(reservation):
            return reservation
        case let .failure(error):
            XCTFail("expected purge reservation, got \(error)")
            fatalError("unreachable")
        }
    }

    private func assertLeaseFailure(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.Lease,
            TatwoCEFProfileLeaseError
        >,
        equals expected: TatwoCEFProfileLeaseError
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("expected lease failure")
        }
        XCTAssertEqual(error, expected)
    }

    private func assertPurgeFailure(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.PurgeReservation,
            TatwoCEFProfilePurgeError
        >,
        equals expected: TatwoCEFProfilePurgeError
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("expected purge failure")
        }
        XCTAssertEqual(error, expected)
    }

    private func requireOriginClearReservation(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.OriginClearReservation,
            TatwoCEFOriginDataClearError
        >
    ) -> TatwoCEFProfileLeaseRegistry.OriginClearReservation {
        switch result {
        case let .success(reservation):
            return reservation
        case let .failure(error):
            XCTFail("expected origin clear reservation, got \(error)")
            fatalError("unreachable")
        }
    }

    private func assertOriginClearFailure(
        _ result: Result<
            TatwoCEFProfileLeaseRegistry.OriginClearReservation,
            TatwoCEFOriginDataClearError
        >,
        equals expected: TatwoCEFOriginDataClearError
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("expected origin clear failure")
        }
        XCTAssertEqual(error, expected)
    }

    private func capacityFixture(
        store: TatwoCEFProfileStore,
        identifier: UUID,
        bytes: Int,
        accessedAt: Date,
        archived: Bool
    ) throws -> (
        entry: EmbeddedBrowserProfileCapacityEntry,
        measuredBytes: UInt64
    ) {
        let generation = try store.currentGeneration(for: identifier)
        let profileURL = try store.profileURL(
            for: identifier,
            generation: generation)
        try FileManager.default.createDirectory(
            at: profileURL,
            withIntermediateDirectories: true)
        let payloadURL = profileURL.appendingPathComponent("payload.bin")
        try Data(repeating: 1, count: bytes).write(to: payloadURL)
        let values = try payloadURL.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ])
        let measuredBytes = UInt64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? bytes)
        return (
            EmbeddedBrowserProfileCapacityEntry(
                profileIdentifier: identifier,
                storageKind: .cefAppOwned,
                generation: generation,
                lastAccessedAt: accessedAt,
                isArchived: archived),
            measuredBytes)
    }

    private func allocatedBytes(at directory: URL) throws -> UInt64 {
        let values = try directory
            .appendingPathComponent("payload.bin")
            .resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ])
        return UInt64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? 40)
    }
}

private enum TestError: Error {
    case disposalFailed
    case ledgerRemovalFailed
    case webKitRemovalFailed
}

@MainActor
private final class FinalMutationProbe {
    var applied = false
    var applyCount = 0
}

private final class OneShotIntentStoreFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: EmbeddedBrowserLifecycleIntentStoreOperation
    private var didFail = false

    init(operation: EmbeddedBrowserLifecycleIntentStoreOperation) {
        self.operation = operation
    }

    func shouldFail(
        _ candidate: EmbeddedBrowserLifecycleIntentStoreOperation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == operation, !didFail else { return false }
        didFail = true
        return true
    }
}

private final class LockedUUIDArray: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID] = []

    var snapshot: [UUID] {
        lock.withLock { values }
    }

    func append(_ value: UUID) {
        lock.withLock { values.append(value) }
    }
}

private final class CrossExecutorSignalProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(timeoutSeconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }
}

@MainActor
private final class OriginClearCompletionProbe {
    private(set) var results: [
        Result<
            TatwoCEFOriginDataClearReceipt,
            TatwoCEFOriginDataClearError
        >
    ] = []

    func record(
        _ result: Result<
            TatwoCEFOriginDataClearReceipt,
            TatwoCEFOriginDataClearError
        >
    ) {
        results.append(result)
    }
}
