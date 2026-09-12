import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoSkilletBundleTransportTests: XCTestCase {
    func testRuntimeReadbackHashesExactTreeAndReportsAbsentRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let active = runtimeRoot.appendingPathComponent(
            "readback-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: active.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeSkill("runtime readback", to: active)
        try Data("receipt evidence\n".utf8).write(
            to: active.appendingPathComponent("notes/evidence.txt"),
            options: [.atomic]
        )

        let readback = try TatwoSkilletBundleTransport.readRuntimeRepository(
            runtimeRoot: runtimeRoot,
            repositoryID: "readback-skill"
        )
        XCTAssertEqual(readback.state, .present)
        XCTAssertEqual(readback.fileCount, 2)
        XCTAssertGreaterThan(readback.byteCount, 0)
        XCTAssertEqual(readback.contentDigest?.count, 64)

        let absent = try TatwoSkilletBundleTransport.readRuntimeRepository(
            runtimeRoot: runtimeRoot,
            repositoryID: "absent-skill"
        )
        XCTAssertEqual(absent.state, .absent)
        XCTAssertNil(absent.contentDigest)
        XCTAssertEqual(absent.fileCount, 0)
        XCTAssertEqual(absent.byteCount, 0)
    }

    func testRuntimeInvariantDetectsMutationInsteadOfClaimingUnchanged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let active = runtimeRoot.appendingPathComponent(
            "guarded-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: active,
            withIntermediateDirectories: true
        )
        try writeSkill("before", to: active)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.preservingRuntimeRepository(
                runtimeRoot: runtimeRoot,
                repositoryID: "guarded-skill"
            ) {
                try self.writeSkill("after", to: active)
            }
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .runtimeMutationDetected("guarded-skill")
            )
        }
    }

    func testExportsExactAncestorClosureAndImportsVerifiedBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceDirectory = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("source-store", isDirectory: true)
        )
        try writeSkill("one", to: sourceDirectory)
        let first = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: "bundle-skill",
            displayName: "Bundle Skill",
            summary: "Bundle fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try sourceStore.promoteRevision(
            repositoryID: "bundle-skill",
            revisionID: first.id,
            to: .stable
        )

        try writeSkill("two", to: sourceDirectory)
        let second = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: "bundle-skill",
            displayName: "Bundle Skill",
            summary: "Bundle fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try writeSkill("three", to: sourceDirectory)
        let third = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: "bundle-skill",
            displayName: "Bundle Skill",
            summary: "Bundle fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 3)
        )

        let bundleURL = fixture.appendingPathComponent("bundle", isDirectory: true)
        let exported = try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: "bundle-skill",
            revisionID: second.id,
            to: bundleURL,
            createdAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(exported.exportedRevisionID, second.id)
        XCTAssertEqual(exported.revisions.map(\.id), [first.id, second.id])
        XCTAssertFalse(exported.revisions.map(\.id).contains(third.id))
        XCTAssertEqual(exported.stableRevision, first.id)
        XCTAssertEqual(exported.objectDigests, [first.contentDigest, second.contentDigest])
        XCTAssertEqual(
            try TatwoSkilletBundleTransport.verifyBundle(at: bundleURL),
            exported
        )

        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("target-store", isDirectory: true)
        )
        let imported = try TatwoSkilletBundleTransport.importBundle(
            at: bundleURL,
            into: targetStore
        )
        XCTAssertEqual(imported.canonicalRevision, second.id)
        XCTAssertEqual(imported.stableRevision, first.id)
        XCTAssertEqual(imported.revisions.map(\.id), [first.id, second.id])
        XCTAssertTrue(
            try targetStore.verifyRevision(
                repositoryID: "bundle-skill",
                revisionID: second.id
            )
        )

        let materialized = fixture.appendingPathComponent("materialized", isDirectory: true)
        try targetStore.materializeRevision(
            repositoryID: "bundle-skill",
            revisionID: second.id,
            to: materialized
        )
        XCTAssertEqual(
            try String(
                contentsOf: materialized.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "---\nname: bundle-skill\n---\ntwo\n"
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).import-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testEphemeralStoreLockCleanupRejectsStableStoreAndPreservesItsLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let stableStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "stable-store",
                isDirectory: true
            )
        )

        try stableStore.withExclusiveMutationLock {}
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stableStore.mutationLockFileURL.path
            )
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport
                .removeEphemeralStoreMutationLock(for: stableStore)
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .unsafeRuntimePath(stableStore.rootURL.path)
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stableStore.mutationLockFileURL.path
            )
        )
    }

    func testVerifyBundleRejectsTamperedPayloadAndUnsafeManifestPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(in: fixture, repositoryID: "tamper-skill")
        let payload = setup.bundleURL
            .appendingPathComponent("objects/\(setup.revision.contentDigest)/payload/SKILL.md")
        try Data("tampered\n".utf8).write(to: payload)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyBundle(at: setup.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .corruptedObject(setup.revision.contentDigest)
            )
        }

        let safeSetup = try makeExportedBundle(
            in: fixture,
            repositoryID: "unsafe-path-skill",
            bundleName: "unsafe-path-bundle"
        )
        let manifestURL = safeSetup.bundleURL
            .appendingPathComponent(
                "objects/\(safeSetup.revision.contentDigest)/manifest.json"
            )
        var manifest = try decodeJSONObject(at: manifestURL)
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        files[0]["relativePath"] = "../escape"
        manifest["files"] = files
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL, options: [.atomic])

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyBundle(at: safeSetup.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .corruptedObject(safeSetup.revision.contentDigest)
            )
        }
    }

    func testVerifyBundleRejectsMissingAncestorObjectAndPayloadSymlink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceDirectory = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("store", isDirectory: true)
        )
        try writeSkill("ancestor", to: sourceDirectory)
        let ancestor = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "graph-skill",
            displayName: "Graph Skill",
            summary: "Graph fixture",
            sourceDirectory: sourceDirectory,
            channel: .draft
        )
        try writeSkill("head", to: sourceDirectory)
        let head = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "graph-skill",
            displayName: "Graph Skill",
            summary: "Graph fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging
        )
        let bundleURL = fixture.appendingPathComponent("graph-bundle", isDirectory: true)
        _ = try TatwoSkilletBundleTransport.exportBundle(
            from: store,
            repositoryID: "graph-skill",
            revisionID: head.id,
            to: bundleURL
        )
        try FileManager.default.removeItem(
            at: bundleURL.appendingPathComponent(
                "objects/\(ancestor.contentDigest)",
                isDirectory: true
            )
        )
        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyBundle(at: bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .missingObject(ancestor.contentDigest)
            )
        }

        let symlinkSetup = try makeExportedBundle(
            in: fixture,
            repositoryID: "symlink-bundle-skill",
            bundleName: "symlink-bundle"
        )
        let payload = symlinkSetup.bundleURL
            .appendingPathComponent(
                "objects/\(symlinkSetup.revision.contentDigest)/payload/SKILL.md"
            )
        let outside = fixture.appendingPathComponent("outside.txt")
        try Data("outside\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: outside)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyBundle(at: symlinkSetup.bundleURL)
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .corruptedObject(symlinkSetup.revision.contentDigest)
            )
        }
    }

    func testVerifyBundleRejectsSymbolicLinkAncestor() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let actualParent = fixture.appendingPathComponent(
            "actual-bundle-parent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: actualParent,
            withIntermediateDirectories: true
        )
        _ = try makeExportedBundle(
            in: actualParent,
            repositoryID: "ancestor-symlink-skill",
            bundleName: "trusted-bundle"
        )
        let linkedParent = fixture.appendingPathComponent(
            "linked-bundle-parent",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: actualParent
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyBundle(
                at: linkedParent.appendingPathComponent(
                    "trusted-bundle",
                    isDirectory: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .invalidBundle("bundle path contains a symbolic-link component")
            )
        }
    }

    func testImportFailureDoesNotLeavePartiallyImportedRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceDirectory = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("source-store", isDirectory: true)
        )
        try writeSkill("first", to: sourceDirectory)
        _ = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: "transaction-skill",
            displayName: "Transaction Skill",
            summary: "Transaction fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try writeSkill("second", to: sourceDirectory)
        let second = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: "transaction-skill",
            displayName: "Transaction Skill",
            summary: "Transaction fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let bundleURL = fixture.appendingPathComponent("transaction-bundle", isDirectory: true)
        _ = try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: "transaction-skill",
            revisionID: second.id,
            to: bundleURL
        )

        let targetRoot = fixture.appendingPathComponent("target-store", isDirectory: true)
        let collision = targetRoot
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(second.contentDigest, isDirectory: true)
        try FileManager.default.createDirectory(
            at: collision.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("pre-existing collision\n".utf8).write(to: collision)
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetRoot)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importBundle(
                at: bundleURL,
                into: targetStore
            )
        )
        XCTAssertThrowsError(
            try targetStore.loadRepository(id: "transaction-skill")
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .repositoryNotFound("transaction-skill")
            )
        }
        XCTAssertEqual(
            try String(contentsOf: collision, encoding: .utf8),
            "pre-existing collision\n"
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetRoot.lastPathComponent).import-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testAuthorityBindingRejectsAReassembledDifferentBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let trusted = try makeExportedBundle(
            in: fixture,
            repositoryID: "authority-skill",
            bundleName: "trusted-bundle"
        )
        let binding = try TatwoSkilletBundleTransport.makeAuthorityBinding(
            at: trusted.bundleURL,
            requestID: "request-authority",
            sourceDeviceID: "device-primary",
            targetDeviceID: "device-secondary",
            authorityEpoch: 9,
            ledgerSequence: 14,
            catalogRevision: "2026-07-23.1",
            createdAt: Date(timeIntervalSince1970: 15)
        )

        let forgedSource = fixture.appendingPathComponent("forged-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: forgedSource,
            withIntermediateDirectories: true
        )
        try writeSkill("forged but internally consistent", to: forgedSource)
        let forgedStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("forged-store", isDirectory: true)
        )
        let forgedRevision = try forgedStore.snapshotCanonicalSkillDirectory(
            repositoryID: "authority-skill",
            displayName: "Bundle Skill",
            summary: "Bundle fixture",
            sourceDirectory: forgedSource,
            channel: .staging
        )
        let forgedBundle = fixture.appendingPathComponent("forged-bundle", isDirectory: true)
        _ = try TatwoSkilletBundleTransport.exportBundle(
            from: forgedStore,
            repositoryID: "authority-skill",
            revisionID: forgedRevision.id,
            to: forgedBundle
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                at: forgedBundle,
                binding: binding,
                expectedRequestID: "request-authority",
                expectedSourceDeviceID: "device-primary",
                expectedTargetDeviceID: "device-secondary",
                expectedAuthorityEpoch: 9,
                expectedLedgerSequence: 14,
                expectedCatalogRevision: "2026-07-23.1"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .authorityBindingMismatch("bundle digest")
            )
        }
    }

    func testAuthorityBindingRejectsEveryRequestFenceMismatch() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let trusted = try makeExportedBundle(
            in: fixture,
            repositoryID: "fenced-authority-skill",
            bundleName: "fenced-bundle"
        )
        let binding = try TatwoSkilletBundleTransport.makeAuthorityBinding(
            at: trusted.bundleURL,
            requestID: "request-fenced",
            sourceDeviceID: "device-primary",
            targetDeviceID: "device-secondary",
            authorityEpoch: 9,
            ledgerSequence: 14,
            catalogRevision: "2026-07-23.1",
            createdAt: Date(timeIntervalSince1970: 15)
        )

        let mismatches: [(String, TatwoSkilletBundleError, () throws -> Void)] = [
            (
                "request",
                .authorityBindingMismatch("request id"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-other",
                        expectedSourceDeviceID: "device-primary",
                        expectedTargetDeviceID: "device-secondary",
                        expectedAuthorityEpoch: 9,
                        expectedLedgerSequence: 14,
                        expectedCatalogRevision: "2026-07-23.1"
                    )
                }
            ),
            (
                "source device",
                .authorityBindingMismatch("source device"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-fenced",
                        expectedSourceDeviceID: "device-other",
                        expectedTargetDeviceID: "device-secondary",
                        expectedAuthorityEpoch: 9,
                        expectedLedgerSequence: 14,
                        expectedCatalogRevision: "2026-07-23.1"
                    )
                }
            ),
            (
                "target device",
                .authorityBindingMismatch("target device"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-fenced",
                        expectedSourceDeviceID: "device-primary",
                        expectedTargetDeviceID: "device-other",
                        expectedAuthorityEpoch: 9,
                        expectedLedgerSequence: 14,
                        expectedCatalogRevision: "2026-07-23.1"
                    )
                }
            ),
            (
                "authority epoch",
                .authorityBindingMismatch("authority epoch"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-fenced",
                        expectedSourceDeviceID: "device-primary",
                        expectedTargetDeviceID: "device-secondary",
                        expectedAuthorityEpoch: 10,
                        expectedLedgerSequence: 14,
                        expectedCatalogRevision: "2026-07-23.1"
                    )
                }
            ),
            (
                "ledger sequence",
                .authorityBindingMismatch("ledger sequence"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-fenced",
                        expectedSourceDeviceID: "device-primary",
                        expectedTargetDeviceID: "device-secondary",
                        expectedAuthorityEpoch: 9,
                        expectedLedgerSequence: 15,
                        expectedCatalogRevision: "2026-07-23.1"
                    )
                }
            ),
            (
                "catalog revision",
                .authorityBindingMismatch("catalog revision"),
                {
                    _ = try TatwoSkilletBundleTransport.verifyAuthorityBoundBundle(
                        at: trusted.bundleURL,
                        binding: binding,
                        expectedRequestID: "request-fenced",
                        expectedSourceDeviceID: "device-primary",
                        expectedTargetDeviceID: "device-secondary",
                        expectedAuthorityEpoch: 9,
                        expectedLedgerSequence: 14,
                        expectedCatalogRevision: "2026-07-23.2"
                    )
                }
            ),
        ]

        for (label, expectedError, operation) in mismatches {
            XCTAssertThrowsError(try operation(), label) { error in
                XCTAssertEqual(error as? TatwoSkilletBundleError, expectedError, label)
            }
        }
    }

    func testImportSerializesConcurrentStoreMutationAcrossAtomicSwap() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let exported = try makeExportedBundle(
            in: fixture,
            repositoryID: "remote-skill",
            bundleName: "remote-bundle"
        )
        let targetRoot = fixture.appendingPathComponent("target-store", isDirectory: true)
        let seedSource = fixture.appendingPathComponent("seed-source", isDirectory: true)
        let concurrentSource = fixture.appendingPathComponent(
            "concurrent-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: seedSource,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: concurrentSource,
            withIntermediateDirectories: true
        )
        try writeSkill("seed", to: seedSource)
        try writeSkill("concurrent", to: concurrentSource)
        _ = try TatwoSkilletRepositoryStore(rootURL: targetRoot)
            .snapshotCanonicalSkillDirectory(
                repositoryID: "seed-skill",
                displayName: "Seed Skill",
                summary: "Existing target state",
                sourceDirectory: seedSource,
                channel: .staging
            )

        let importerAtCommit = DispatchSemaphore(value: 0)
        let releaseImporter = DispatchSemaphore(value: 0)
        let importerDone = DispatchSemaphore(value: 0)
        let mutationDone = DispatchSemaphore(value: 0)
        let importerError = LockedTestErrorBox()
        let mutationError = LockedTestErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { importerDone.signal() }
            do {
                _ = try TatwoSkilletBundleTransport.importBundle(
                    at: exported.bundleURL,
                    into: TatwoSkilletRepositoryStore(rootURL: targetRoot),
                    beforeStoreCommit: {
                        importerAtCommit.signal()
                        releaseImporter.wait()
                    }
                )
            } catch {
                importerError.set(error)
            }
        }

        XCTAssertEqual(
            importerAtCommit.wait(timeout: .now() + 5),
            .success,
            "import did not reach the atomic commit gate"
        )
        DispatchQueue.global(qos: .userInitiated).async {
            defer { mutationDone.signal() }
            do {
                _ = try TatwoSkilletRepositoryStore(rootURL: targetRoot)
                    .snapshotCanonicalSkillDirectory(
                        repositoryID: "concurrent-skill",
                        displayName: "Concurrent Skill",
                        summary: "Mutation racing store import",
                        sourceDirectory: concurrentSource,
                        channel: .staging
                    )
            } catch {
                mutationError.set(error)
            }
        }

        XCTAssertEqual(
            mutationDone.wait(timeout: .now() + 0.2),
            .timedOut,
            "concurrent mutation must wait for the whole-store import transaction"
        )
        releaseImporter.signal()
        XCTAssertEqual(importerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(mutationDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(importerError.get())
        XCTAssertNil(mutationError.get())

        let finalStore = TatwoSkilletRepositoryStore(rootURL: targetRoot)
        XCTAssertEqual(
            try finalStore.loadRepository(id: "remote-skill").canonicalRevision,
            exported.revision.id
        )
        XCTAssertNoThrow(try finalStore.loadRepository(id: "seed-skill"))
        XCTAssertNoThrow(try finalStore.loadRepository(id: "concurrent-skill"))
    }

    func testAtomicActivationRollsBackRuntimeWhenDeviceHeadCommitBecomesStale() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceDirectory = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("store", isDirectory: true)
        )
        try writeSkill("stable", to: sourceDirectory)
        let stable = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "activation-skill",
            displayName: "Activation Skill",
            summary: "Activation fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging
        )
        try writeSkill("candidate", to: sourceDirectory)
        let candidate = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "activation-skill",
            displayName: "Activation Skill",
            summary: "Activation fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging
        )

        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let stableHead = try TatwoSkilletBundleTransport.activateRevisionAtomically(
            in: store,
            repositoryID: "activation-skill",
            revisionID: stable.id,
            runtimeRoot: runtimeRoot,
            deviceID: "macbook",
            requestID: "request-stable",
            authorityEpoch: 7,
            ledgerSequence: 10,
            verifiedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(stableHead.revisionID, stable.id)
        XCTAssertEqual(
            try activeSkillText(runtimeRoot: runtimeRoot, repositoryID: "activation-skill"),
            "---\nname: bundle-skill\n---\nstable\n"
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.activateRevisionAtomically(
                in: store,
                repositoryID: "activation-skill",
                revisionID: candidate.id,
                runtimeRoot: runtimeRoot,
                deviceID: "macbook",
                requestID: "request-candidate",
                authorityEpoch: 7,
                ledgerSequence: 11,
                verifiedAt: Date(timeIntervalSince1970: 11),
                beforeDeviceHeadCommit: {
                    try store.upsertDeviceHead(
                        .init(
                            deviceID: "macbook",
                            repositoryID: "activation-skill",
                            revisionID: stable.id,
                            contentDigest: stable.contentDigest,
                            requestID: "request-fencing-wins",
                            authorityEpoch: 7,
                            ledgerSequence: 12,
                            activationState: .active,
                            lastVerifiedAt: Date(timeIntervalSince1970: 12)
                        )
                    )
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .staleDeviceHead("macbook")
            )
        }
        XCTAssertEqual(
            try activeSkillText(runtimeRoot: runtimeRoot, repositoryID: "activation-skill"),
            "---\nname: bundle-skill\n---\nstable\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeRoot
                    .appendingPathComponent(".failed/activation-skill", isDirectory: true)
                    .path
            )
        )

        let candidateHead = try TatwoSkilletBundleTransport.activateRevisionAtomically(
            in: store,
            repositoryID: "activation-skill",
            revisionID: candidate.id,
            runtimeRoot: runtimeRoot,
            deviceID: "macbook",
            requestID: "request-candidate-final",
            authorityEpoch: 7,
            ledgerSequence: 13,
            verifiedAt: Date(timeIntervalSince1970: 13)
        )
        XCTAssertEqual(candidateHead.revisionID, candidate.id)
        XCTAssertEqual(candidateHead.contentDigest, candidate.contentDigest)
        XCTAssertEqual(
            try activeSkillText(runtimeRoot: runtimeRoot, repositoryID: "activation-skill"),
            "---\nname: bundle-skill\n---\ncandidate\n"
        )

        let replay = try TatwoSkilletBundleTransport.activateRevisionAtomically(
            in: store,
            repositoryID: "activation-skill",
            revisionID: candidate.id,
            runtimeRoot: runtimeRoot,
            deviceID: "macbook",
            requestID: "request-candidate-final",
            authorityEpoch: 7,
            ledgerSequence: 13,
            verifiedAt: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(replay, candidateHead)
    }

    func testAuthorityBoundSetActivatesEveryRepositoryAndCommitsDeviceHeadsTogether() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-skill",
            bundleName: "alpha-bundle"
        )
        let second = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-skill",
            bundleName: "beta-bundle"
        )
        let requestID = "request-set-success"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: first,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 21,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: second,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 21,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("target-store", isDirectory: true)
        )
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)

        let heads = try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
            inputs,
            into: targetStore,
            runtimeRoot: runtimeRoot,
            deviceID: targetDeviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: 8,
            ledgerSequence: 21,
            catalogRevision: catalogRevision,
            verifiedAt: Date(timeIntervalSince1970: 21)
        )

        XCTAssertEqual(heads.map(\.repositoryID), ["alpha-skill", "beta-skill"])
        XCTAssertTrue(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: "alpha-skill"
            ).contains("safe")
        )
        XCTAssertTrue(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: "beta-skill"
            ).contains("safe")
        )
        for input in inputs {
            let repository = try targetStore.loadRepository(id: input.repositoryID)
            let head = try XCTUnwrap(
                repository.deviceHeads.first(where: {
                    $0.deviceID == targetDeviceID
                })
            )
            XCTAssertEqual(head.requestID, requestID)
            XCTAssertEqual(head.authorityEpoch, 8)
            XCTAssertEqual(head.ledgerSequence, 21)
            XCTAssertEqual(head.revisionID, input.revisionID)
            XCTAssertEqual(head.contentDigest, input.contentDigest)
        }
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testStagedActivationFailureAfterStoreMutationRemovesEphemeralLock()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "staged-runtime-conflict",
            bundleName: "staged-runtime-conflict-bundle"
        )
        let requestID = "request-staged-runtime-conflict"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-26.1"
        let input = try makeBoundInput(
            setup: setup,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: 15,
            ledgerSequence: 35,
            catalogRevision: catalogRevision
        )
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "staged-runtime-conflict-target-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "staged-runtime-conflict-runtime",
            isDirectory: true
        )
        let outside = fixture.appendingPathComponent(
            "staged-runtime-conflict-outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 15,
                ledgerSequence: 35,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 35),
                beforeRepositoryCommit: nil,
                afterStoreCommit: nil,
                testHooks: .init(
                    prepareStagedRuntime: { stagedRuntime in
                        try FileManager.default.createDirectory(
                            at: stagedRuntime,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.createSymbolicLink(
                            at: stagedRuntime.appendingPathComponent(
                                input.repositoryID,
                                isDirectory: true
                            ),
                            withDestinationURL: outside
                        )
                    }
                )
            )
        ) { error in
            switch error as? TatwoSkilletBundleError {
            case .unsafeRuntimePath:
                break
            default:
                XCTFail("expected unsafe staged runtime path, got \(error)")
            }
        }

        XCTAssertEqual(try targetStore.listRepositoryIDs(), [])
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testReceiveAuthorityBoundSetIntoAbsentStoreDoesNotCreateGhostRepository()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "first-sync-skill",
            bundleName: "first-sync-bundle"
        )
        let requestID = "request-first-sync"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-25.1"
        let input = try makeBoundInput(
            setup: setup,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: 9,
            ledgerSequence: 1,
            catalogRevision: catalogRevision
        )
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "absent-target-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "absent-target-runtime",
            isDirectory: true
        )

        let outcome = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 9,
                ledgerSequence: 1,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 1)
            )

        guard case .activated(let activation) = outcome else {
            return XCTFail("expected first sync to activate")
        }
        let heads = activation.heads
        XCTAssertEqual(heads.map(\.repositoryID), ["first-sync-skill"])
        XCTAssertEqual(try targetStore.listRepositoryIDs(), ["first-sync-skill"])
        XCTAssertTrue(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: "first-sync-skill"
            ).contains("safe")
        )
    }

    func testEmptyAuthorityBoundSetFailsClosedEvenWhenTargetIsAlsoEmpty() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "empty-target-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "empty-runtime",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                [],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "book-device",
                requestID: "request-empty-set",
                sourceDeviceID: "mini-device",
                authorityEpoch: 8,
                ledgerSequence: 22,
                catalogRevision: "2026-07-23.2",
                verifiedAt: Date(timeIntervalSince1970: 22)
            )
        ) {
            XCTAssertEqual(
                $0 as? TatwoSkilletBundleError,
                .invalidBundle("Skillet set must not be empty")
            )
        }
        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive(
                [],
                in: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "book-device",
                requestID: "request-empty-set",
                sourceDeviceID: "mini-device",
                authorityEpoch: 8,
                ledgerSequence: 22,
                catalogRevision: "2026-07-23.2"
            )
        ) {
            XCTAssertEqual(
                $0 as? TatwoSkilletBundleError,
                .invalidBundle("Skillet set must not be empty")
            )
        }
        XCTAssertEqual(try targetStore.listRepositoryIDs(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.path))
    }

    func testEmptyAuthorityBoundSetRejectsTargetOnlyRepositoryWithoutDeletingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "empty-conflict-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "empty-conflict-runtime",
            isDirectory: true
        )
        let targetOnlyRuntime = runtimeRoot.appendingPathComponent(
            "target-only-skill",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetOnlyRuntime,
            withIntermediateDirectories: true
        )
        try writeSkill("target-only branch", to: targetOnlyRuntime)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                [],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "book-device",
                requestID: "request-empty-conflict",
                sourceDeviceID: "mini-device",
                authorityEpoch: 8,
                ledgerSequence: 23,
                catalogRevision: "2026-07-23.2",
                verifiedAt: Date(timeIntervalSince1970: 23)
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .invalidBundle("Skillet set must not be empty")
            )
        }
        XCTAssertEqual(try targetStore.listRepositoryIDs(), [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetOnlyRuntime.appendingPathComponent("SKILL.md").path
            )
        )
    }

    func testForcedCompensatingExchangeUpdatesTwoExistingRuntimeRepositories() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-fallback-success",
            bundleName: "alpha-fallback-success-bundle"
        )
        let second = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-fallback-success",
            bundleName: "beta-fallback-success-bundle"
        )
        let requestID = "request-forced-fallback-success"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: first,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 11,
                ledgerSequence: 31,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: second,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 11,
                ledgerSequence: 31,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "forced-fallback-success-store",
                isDirectory: true
            )
        )
        for input in inputs {
            _ = try TatwoSkilletBundleTransport.importBundle(
                at: input.bundleURL,
                into: targetStore
            )
        }
        let runtimeRoot = fixture.appendingPathComponent(
            "forced-fallback-success-runtime",
            isDirectory: true
        )
        for input in inputs {
            let active = runtimeRoot.appendingPathComponent(
                input.repositoryID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: true
            )
            try writeSkill("old \(input.repositoryID)", to: active)
        }

        let heads = try TatwoSkilletBundleTransport
            .importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 11,
                ledgerSequence: 31,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 31),
                beforeRepositoryCommit: nil,
                afterStoreCommit: nil,
                testHooks: .init(forceCompensatingExchange: true)
            )

        XCTAssertEqual(
            heads.map(\.repositoryID),
            ["alpha-fallback-success", "beta-fallback-success"]
        )
        for input in inputs {
            XCTAssertEqual(
                try activeSkillText(
                    runtimeRoot: runtimeRoot,
                    repositoryID: input.repositoryID
                ),
                "---\nname: bundle-skill\n---\nsafe\n"
            )
        }
        XCTAssertTrue(
            try pathsNamedWithPrefix(".exchange-", below: fixture).isEmpty
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testForcedCompensatingExchangeFailureRollsBackAllRuntimeRepositories() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-fallback-failure",
            bundleName: "alpha-fallback-failure-bundle"
        )
        let second = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-fallback-failure",
            bundleName: "beta-fallback-failure-bundle"
        )
        let requestID = "request-forced-fallback-failure"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: first,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 32,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: second,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 32,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "forced-fallback-failure-store",
                isDirectory: true
            )
        )
        for input in inputs {
            _ = try TatwoSkilletBundleTransport.importBundle(
                at: input.bundleURL,
                into: targetStore
            )
        }
        let repositoriesBeforeFailure = try Dictionary(
            uniqueKeysWithValues: inputs.map { input in
                (
                    input.repositoryID,
                    try targetStore.loadRepository(id: input.repositoryID)
                )
            }
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "forced-fallback-failure-runtime",
            isDirectory: true
        )
        let oldRuntimeBodies = [
            "alpha-fallback-failure": "old alpha fallback runtime",
            "beta-fallback-failure": "old beta fallback runtime",
        ]
        for (repositoryID, body) in oldRuntimeBodies {
            let active = runtimeRoot.appendingPathComponent(
                repositoryID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: true
            )
            try writeSkill(body, to: active)
        }

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 32,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 32),
                beforeRepositoryCommit: nil,
                afterStoreCommit: nil,
                testHooks: .init(
                    forceCompensatingExchange: true,
                    beforeCompensatingExchangeStep: { step, source, _ in
                        if step == 2,
                           source.lastPathComponent == "beta-fallback-failure"
                        {
                            throw SetCommitFixtureError.injectedFailure
                        }
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? SetCommitFixtureError, .injectedFailure)
        }

        for input in inputs {
            XCTAssertEqual(
                try targetStore.loadRepository(id: input.repositoryID),
                repositoriesBeforeFailure[input.repositoryID]
            )
        }
        for (repositoryID, body) in oldRuntimeBodies {
            XCTAssertEqual(
                try activeSkillText(
                    runtimeRoot: runtimeRoot,
                    repositoryID: repositoryID
                ),
                "---\nname: bundle-skill\n---\n\(body)\n"
            )
        }
        XCTAssertTrue(
            try pathsNamedWithPrefix(".exchange-", below: fixture).isEmpty
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    func testForcedCompensatingExchangeRestoresBothDirectoriesAfterEachForwardFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        for failedStep in 1 ... 3 {
            let pairRoot = fixture.appendingPathComponent(
                "exchange-step-\(failedStep)",
                isDirectory: true
            )
            let first = pairRoot.appendingPathComponent("first", isDirectory: true)
            let second = pairRoot.appendingPathComponent("second", isDirectory: true)
            try FileManager.default.createDirectory(
                at: first,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: second,
                withIntermediateDirectories: true
            )
            try Data("first\n".utf8).write(
                to: first.appendingPathComponent("VALUE")
            )
            try Data("second\n".utf8).write(
                to: second.appendingPathComponent("VALUE")
            )

            XCTAssertThrowsError(
                try TatwoSkilletBundleTransport.testOnlyAtomicExchange(
                    first,
                    second,
                    hooks: .init(
                        forceCompensatingExchange: true,
                        beforeCompensatingExchangeStep: { step, _, _ in
                            if step == failedStep {
                                throw SetCommitFixtureError.injectedFailure
                            }
                        }
                    )
                )
            )
            XCTAssertEqual(
                try String(
                    contentsOf: first.appendingPathComponent("VALUE"),
                    encoding: .utf8
                ),
                "first\n"
            )
            XCTAssertEqual(
                try String(
                    contentsOf: second.appendingPathComponent("VALUE"),
                    encoding: .utf8
                ),
                "second\n"
            )
            XCTAssertTrue(
                try pathsNamedWithPrefix(".exchange-", below: pairRoot).isEmpty
            )
        }
    }

    func testForcedCompensatingExchangeReportsRollbackFailedWhenRecoveryFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = fixture.appendingPathComponent("rollback-first", isDirectory: true)
        let second = fixture.appendingPathComponent("rollback-second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.testOnlyAtomicExchange(
                first,
                second,
                hooks: .init(
                    forceCompensatingExchange: true,
                    beforeCompensatingExchangeStep: { step, _, _ in
                        if step == 2 {
                            throw SetCommitFixtureError.injectedFailure
                        }
                    },
                    beforeCompensatingRollbackStep: { _, _, _ in
                        throw SetCommitFixtureError.injectedRollbackFailure
                    }
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .rollbackFailed(first.path)
            )
        }
    }

    func testStoreCopyFailureArchivesRequestBoundPartialStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "store-copy-failure",
            bundleName: "store-copy-failure-bundle"
        )
        let requestID = "request-store-copy-enospc"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let input = try makeBoundInput(
            setup: setup,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: 13,
            ledgerSequence: 33,
            catalogRevision: catalogRevision
        )
        let targetStoreRoot = fixture.appendingPathComponent(
            "store-copy-failure-target",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        _ = try TatwoSkilletBundleTransport.importBundle(
            at: setup.bundleURL,
            into: targetStore
        )
        let repositoryBeforeFailure = try targetStore.loadRepository(
            id: input.repositoryID
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "store-copy-failure-runtime",
            isDirectory: true
        )
        let noSpace = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 13,
                ledgerSequence: 33,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 33),
                beforeRepositoryCommit: nil,
                afterStoreCommit: nil,
                testHooks: .init(
                    prepareStagedStore: { _, stagedStore, hadStore in
                        XCTAssertTrue(hadStore)
                        try FileManager.default.createDirectory(
                            at: stagedStore,
                            withIntermediateDirectories: true
                        )
                        try Data("partial\n".utf8).write(
                            to: stagedStore.appendingPathComponent("PARTIAL_STORE")
                        )
                        throw noSpace
                    }
                )
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, noSpace.code)
        }

        XCTAssertEqual(
            try targetStore.loadRepository(id: input.repositoryID),
            repositoryBeforeFailure
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                ".\(targetStoreRoot.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        let archiveRoot = fixture
            .appendingPathComponent(".skillet-set-failed", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
        let archives = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(archives.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archives[0].appendingPathComponent("PARTIAL_STORE").path
            )
        )
    }

    func testRuntimePreparationFailureArchivesRequestBoundPartialStaging() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "runtime-prepare-failure",
            bundleName: "runtime-prepare-failure-bundle"
        )
        let requestID = "request-runtime-prepare-enospc"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let input = try makeBoundInput(
            setup: setup,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: 14,
            ledgerSequence: 34,
            catalogRevision: catalogRevision
        )
        let targetStoreRoot = fixture.appendingPathComponent(
            "runtime-prepare-failure-target",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        _ = try TatwoSkilletBundleTransport.importBundle(
            at: setup.bundleURL,
            into: targetStore
        )
        let repositoryBeforeFailure = try targetStore.loadRepository(
            id: input.repositoryID
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "runtime-prepare-failure-runtime",
            isDirectory: true
        )
        let noSpace = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(POSIXErrorCode.ENOSPC.rawValue)
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 14,
                ledgerSequence: 34,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 34),
                beforeRepositoryCommit: nil,
                afterStoreCommit: nil,
                testHooks: .init(
                    prepareStagedRuntime: { stagedRuntime in
                        try FileManager.default.createDirectory(
                            at: stagedRuntime,
                            withIntermediateDirectories: true
                        )
                        try Data("partial\n".utf8).write(
                            to: stagedRuntime.appendingPathComponent("PARTIAL_RUNTIME")
                        )
                        throw noSpace
                    }
                )
            )
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, noSpace.code)
        }

        XCTAssertEqual(
            try targetStore.loadRepository(id: input.repositoryID),
            repositoryBeforeFailure
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                ".\(targetStoreRoot.lastPathComponent).set-staging-",
                below: fixture
            ).isEmpty
        )
        let runtimeArchiveRoot = runtimeRoot
            .appendingPathComponent(".set-failed", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
        let runtimeArchives = try FileManager.default.contentsOfDirectory(
            at: runtimeArchiveRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(runtimeArchives.count, 1)
        XCTAssertTrue(runtimeArchives[0].lastPathComponent.hasPrefix("staging-"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeArchives[0]
                    .appendingPathComponent("PARTIAL_RUNTIME")
                    .path
            )
        )
        let unmanagedRuntimeStaging = runtimeRoot.appendingPathComponent(
            ".set-staging",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: unmanagedRuntimeStaging.path) {
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: unmanagedRuntimeStaging,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
        let storeArchiveRoot = fixture
            .appendingPathComponent(".skillet-set-failed", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: storeArchiveRoot,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    func testAuthorityBoundSetActiveVerificationReconstructsEvidenceWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "active-verification",
            bundleName: "active-verification-bundle"
        )
        let requestID = "request-active-verification"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: setup,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 24,
                catalogRevision: catalogRevision
            )
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "active-verification-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "active-verification-runtime",
            isDirectory: true
        )

        let activated = try TatwoSkilletBundleTransport
            .importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 24,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 24)
            )
        let verified = try TatwoSkilletBundleTransport
            .verifyAuthorityBoundSetIsActive(
                inputs,
                in: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 24,
                catalogRevision: catalogRevision
            )

        XCTAssertEqual(verified, activated)

        try Data("tampered\n".utf8).write(
            to: runtimeRoot
                .appendingPathComponent("active-verification", isDirectory: true)
                .appendingPathComponent("SKILL.md")
        )
        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive(
                inputs,
                in: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 24,
                catalogRevision: catalogRevision
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .activeRuntimeMismatch("active-verification")
            )
        }
    }

    func testAuthorityBoundSetActiveVerificationRejectsRuntimeOnlySkillRepository() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let setup = try makeExportedBundle(
            in: fixture,
            repositoryID: "active-exact-set",
            bundleName: "active-exact-set-bundle"
        )
        let requestID = "request-active-exact-set"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: setup,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 25,
                catalogRevision: catalogRevision
            )
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "active-exact-set-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "active-exact-set-runtime",
            isDirectory: true
        )

        _ = try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
            inputs,
            into: targetStore,
            runtimeRoot: runtimeRoot,
            deviceID: targetDeviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: 8,
            ledgerSequence: 25,
            catalogRevision: catalogRevision,
            verifiedAt: Date(timeIntervalSince1970: 25)
        )
        let runtimeOnly = runtimeRoot.appendingPathComponent(
            "local-only-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeOnly,
            withIntermediateDirectories: true
        )
        try writeSkill("runtime-only repository must block convergence", to: runtimeOnly)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive(
                inputs,
                in: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 25,
                catalogRevision: catalogRevision
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .repositoryConflict("local-only-runtime")
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeOnly.appendingPathComponent("SKILL.md").path
            )
        )
    }

    func testAuthorityBoundSetRejectsUnsortedRepositorySetBeforeActivation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let alpha = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-unsorted",
            bundleName: "alpha-unsorted-bundle"
        )
        let beta = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-unsorted",
            bundleName: "beta-unsorted-bundle"
        )
        let requestID = "request-set-unsorted"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: beta,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 22,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: alpha,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 22,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "unsorted-target-store",
                isDirectory: true
            )
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "unsorted-runtime",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 22,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 22)
            )
        )
        XCTAssertEqual(try targetStore.listRepositoryIDs(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent("alpha-unsorted").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent("beta-unsorted").path
            )
        )
    }

    func testAuthorityBoundSetPreservesExtraManagedTargetRepositoryAndActiveRuntime() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let alpha = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-exact-set",
            bundleName: "alpha-exact-set-bundle"
        )
        let requestID = "request-set-extra-target"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: alpha,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 23,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "extra-target-store",
                isDirectory: true
            )
        )
        let localSource = fixture.appendingPathComponent(
            "extra-target-local-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localSource,
            withIntermediateDirectories: true
        )
        try writeSkill("local repository must not disappear", to: localSource)
        let localRevision = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: "local-only-repository",
            displayName: "Local Only Repository",
            summary: "Must remain local when another repository set converges",
            sourceDirectory: localSource,
            channel: .staging
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "extra-target-runtime",
            isDirectory: true
        )
        let localHead = try TatwoSkilletBundleTransport.activateRevisionAtomically(
            in: targetStore,
            repositoryID: "local-only-repository",
            revisionID: localRevision.id,
            runtimeRoot: runtimeRoot,
            deviceID: targetDeviceID,
            requestID: "request-local-only",
            authorityEpoch: 7,
            ledgerSequence: 22,
            verifiedAt: Date(timeIntervalSince1970: 22)
        )
        let localRuntimeBefore = try Data(
            contentsOf: runtimeRoot
                .appendingPathComponent(
                    "local-only-repository",
                    isDirectory: true
                )
                .appendingPathComponent("SKILL.md")
        )

        let activation = try TatwoSkilletBundleTransport
            .importAndActivateAuthorityBoundSetWithEvidence(
            inputs,
            into: targetStore,
            runtimeRoot: runtimeRoot,
            deviceID: targetDeviceID,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            authorityEpoch: 8,
            ledgerSequence: 23,
            catalogRevision: catalogRevision,
            verifiedAt: Date(timeIntervalSince1970: 23)
        )
        let heads = activation.heads
        XCTAssertEqual(
            try targetStore.listRepositoryIDs(),
            ["alpha-exact-set", "local-only-repository"]
        )
        XCTAssertEqual(heads.map(\.repositoryID), ["alpha-exact-set"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeRoot
                    .appendingPathComponent("alpha-exact-set")
                    .appendingPathComponent("SKILL.md").path
            )
        )
        XCTAssertEqual(
            try Data(
                contentsOf: runtimeRoot
                    .appendingPathComponent(
                        "local-only-repository",
                        isDirectory: true
                    )
                    .appendingPathComponent("SKILL.md")
            ),
            localRuntimeBefore
        )
        let preservedRepository = try targetStore.loadRepository(
            id: "local-only-repository"
        )
        XCTAssertEqual(
            preservedRepository.deviceHeads.first(where: {
                $0.deviceID == targetDeviceID
            }),
            localHead
        )
        XCTAssertEqual(
            try TatwoSkilletBundleTransport.verifyAuthorityBoundSetIsActive(
                inputs,
                in: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 8,
                ledgerSequence: 23,
                catalogRevision: catalogRevision
            ),
            heads
        )
        XCTAssertEqual(
            activation.targetPreservedRepositories,
            [
                TatwoSkilletTargetPreservedRepositoryV1(
                    repositoryID: "local-only-repository",
                    revisionID: localHead.revisionID,
                    contentDigest: localHead.contentDigest,
                    state: .runtimePreserved
                )
            ]
        )
    }

    func testAuthorityBoundSetLeavesTargetOnlyCanonicalStoreOnlyWithoutPromotion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let incoming = try makeExportedBundle(
            in: fixture,
            repositoryID: "incoming-no-promotion",
            bundleName: "incoming-no-promotion-bundle"
        )
        let requestID = "request-no-target-promotion"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-27.1"
        let inputs = try [
            makeBoundInput(
                setup: incoming,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 30,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "no-promotion-target-store",
                isDirectory: true
            )
        )
        let targetOnlySource = fixture.appendingPathComponent(
            "no-promotion-target-only-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetOnlySource,
            withIntermediateDirectories: true
        )
        try writeSkill("target only canonical", to: targetOnlySource)
        let targetOnlyRevision = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: "target-only-no-promotion",
            displayName: "Target Only",
            summary: "Must remain store-only without explicit promotion",
            sourceDirectory: targetOnlySource,
            channel: .staging
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "no-promotion-runtime",
            isDirectory: true
        )

        let activation = try TatwoSkilletBundleTransport
            .importAndActivateAuthorityBoundSetWithEvidence(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 30,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 30),
                beforeRepositoryCommit: nil
            )

        XCTAssertEqual(
            activation.targetPreservedRepositories,
            [
                TatwoSkilletTargetPreservedRepositoryV1(
                    repositoryID: "target-only-no-promotion",
                    revisionID: targetOnlyRevision.id,
                    contentDigest: targetOnlyRevision.contentDigest,
                    state: .storePreserved
                ),
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent(
                    "target-only-no-promotion",
                    isDirectory: true
                ).path
            )
        )
    }

    func testAuthorityBoundSetTargetPromotionFailsClosedWithoutCanonicalRevision() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let incoming = try makeExportedBundle(
            in: fixture,
            repositoryID: "incoming-canonical-required",
            bundleName: "incoming-canonical-required-bundle"
        )
        let requestID = "request-target-canonical-required"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-27.1"
        let inputs = try [
            makeBoundInput(
                setup: incoming,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 31,
                catalogRevision: catalogRevision
            ),
        ]
        let storeRoot = fixture.appendingPathComponent(
            "canonical-required-target-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let targetOnlySource = fixture.appendingPathComponent(
            "canonical-required-target-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetOnlySource,
            withIntermediateDirectories: true
        )
        try writeSkill("must not activate an unreviewed fallback", to: targetOnlySource)
        _ = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: "target-only-no-canonical",
            displayName: "No Canonical",
            summary: "Promotion must fail closed without a canonical revision",
            sourceDirectory: targetOnlySource,
            channel: .staging
        )
        let metadataURL = storeRoot
            .appendingPathComponent("repositories/target-only-no-canonical")
            .appendingPathComponent("repository.json")
        var metadata = try decodeJSONObject(at: metadataURL)
        metadata["canonicalRevision"] = NSNull()
        try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: metadataURL, options: [.atomic])
        let runtimeRoot = fixture.appendingPathComponent(
            "canonical-required-runtime",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport
                .importAndActivateAuthorityBoundSetWithEvidence(
                    inputs,
                    into: targetStore,
                    runtimeRoot: runtimeRoot,
                    deviceID: targetDeviceID,
                    requestID: requestID,
                    sourceDeviceID: sourceDeviceID,
                    authorityEpoch: 12,
                    ledgerSequence: 31,
                    catalogRevision: catalogRevision,
                    verifiedAt: Date(timeIntervalSince1970: 31),
                    activateTargetPreservedRuntime: true,
                    beforeRepositoryCommit: nil
                )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .repositoryConflict("target-only-no-canonical")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent(
                    "target-only-no-canonical",
                    isDirectory: true
                ).path
            )
        )
    }

    func testAuthorityBoundSetTargetPromotionRejectsNonSkillRuntimeDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let incoming = try makeExportedBundle(
            in: fixture,
            repositoryID: "incoming-unmanaged-runtime",
            bundleName: "incoming-unmanaged-runtime-bundle"
        )
        let requestID = "request-target-unmanaged-runtime"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-27.1"
        let inputs = try [
            makeBoundInput(
                setup: incoming,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 32,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "unmanaged-runtime-target-store",
                isDirectory: true
            )
        )
        let targetOnlySource = fixture.appendingPathComponent(
            "unmanaged-runtime-target-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetOnlySource,
            withIntermediateDirectories: true
        )
        try writeSkill("managed canonical", to: targetOnlySource)
        _ = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: "target-only-unmanaged-runtime",
            displayName: "Unmanaged Runtime",
            summary: "A non-SKILL runtime directory must never be replaced",
            sourceDirectory: targetOnlySource,
            channel: .staging
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "unmanaged-runtime-root",
            isDirectory: true
        )
        let unmanaged = runtimeRoot.appendingPathComponent(
            "target-only-unmanaged-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unmanaged,
            withIntermediateDirectories: true
        )
        try Data("do not replace\n".utf8).write(
            to: unmanaged.appendingPathComponent("KEEP.txt")
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport
                .importAndActivateAuthorityBoundSetWithEvidence(
                    inputs,
                    into: targetStore,
                    runtimeRoot: runtimeRoot,
                    deviceID: targetDeviceID,
                    requestID: requestID,
                    sourceDeviceID: sourceDeviceID,
                    authorityEpoch: 12,
                    ledgerSequence: 32,
                    catalogRevision: catalogRevision,
                    verifiedAt: Date(timeIntervalSince1970: 32),
                    activateTargetPreservedRuntime: true,
                    beforeRepositoryCommit: nil
                )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .activeRuntimeMismatch("target-only-unmanaged-runtime")
            )
        }
        XCTAssertEqual(
            try String(
                contentsOf: unmanaged.appendingPathComponent("KEEP.txt"),
                encoding: .utf8
            ),
            "do not replace\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: unmanaged.appendingPathComponent("SKILL.md").path
            )
        )
    }

    func testAuthorityBoundSetRollsBackTargetPromotionAfterStoreCommitFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let incoming = try makeExportedBundle(
            in: fixture,
            repositoryID: "incoming-target-rollback",
            bundleName: "incoming-target-rollback-bundle"
        )
        let requestID = "request-target-promotion-rollback"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-27.1"
        let inputs = try [
            makeBoundInput(
                setup: incoming,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 12,
                ledgerSequence: 33,
                catalogRevision: catalogRevision
            ),
        ]
        let storeRoot = fixture.appendingPathComponent(
            "target-promotion-rollback-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let targetOnlySource = fixture.appendingPathComponent(
            "target-promotion-rollback-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetOnlySource,
            withIntermediateDirectories: true
        )
        try writeSkill("rollback target canonical", to: targetOnlySource)
        let targetOnlyRevision = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: "target-only-rollback",
            displayName: "Rollback Target",
            summary: "Promotion and store commit must roll back together",
            sourceDirectory: targetOnlySource,
            channel: .staging
        )
        let metadataURL = storeRoot
            .appendingPathComponent("repositories/target-only-rollback")
            .appendingPathComponent("repository.json")
        let metadataBefore = try Data(contentsOf: metadataURL)
        let runtimeRoot = fixture.appendingPathComponent(
            "target-promotion-rollback-runtime",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport
                .importAndActivateAuthorityBoundSetWithEvidence(
                    inputs,
                    into: targetStore,
                    runtimeRoot: runtimeRoot,
                    deviceID: targetDeviceID,
                    requestID: requestID,
                    sourceDeviceID: sourceDeviceID,
                    authorityEpoch: 12,
                    ledgerSequence: 33,
                    catalogRevision: catalogRevision,
                    verifiedAt: Date(timeIntervalSince1970: 33),
                    activateTargetPreservedRuntime: true,
                    beforeRepositoryCommit: nil,
                    afterStoreCommit: {
                        throw SetCommitFixtureError.injectedFailure
                    }
                )
        ) { error in
            XCTAssertEqual(error as? SetCommitFixtureError, .injectedFailure)
        }
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadataBefore)
        XCTAssertEqual(
            try targetStore.loadRepository(
                id: "target-only-rollback"
            ).canonicalRevision,
            targetOnlyRevision.id
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent(
                    "target-only-rollback",
                    isDirectory: true
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent(
                    "incoming-target-rollback",
                    isDirectory: true
                ).path
            )
        )
    }

    func testAuthorityBoundSetRollsBackEarlierRuntimeCommitWhenLaterCommitFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-failure",
            bundleName: "alpha-failure-bundle"
        )
        let second = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-failure",
            bundleName: "beta-failure-bundle"
        )
        let requestID = "request-set-rollback"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: first,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 9,
                ledgerSequence: 22,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: second,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 9,
                ledgerSequence: 22,
                catalogRevision: catalogRevision
            ),
        ]
        let targetStoreRoot = fixture.appendingPathComponent(
            "rollback-target-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        let runtimeRoot = fixture.appendingPathComponent(
            "rollback-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeRoot.appendingPathComponent("unmanaged-sentinel"),
            withIntermediateDirectories: true
        )
        try Data("keep\n".utf8).write(
            to: runtimeRoot.appendingPathComponent("unmanaged-sentinel/KEEP")
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 9,
                ledgerSequence: 22,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 22),
                beforeRepositoryCommit: { _, index in
                    if index == 1 {
                        throw SetCommitFixtureError.injectedFailure
                    }
                }
            )
        ) { error in
            XCTAssertEqual(error as? SetCommitFixtureError, .injectedFailure)
        }

        XCTAssertEqual(try targetStore.listRepositoryIDs(), [])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent("alpha-failure").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot.appendingPathComponent("beta-failure").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: runtimeRoot.appendingPathComponent(
                    "unmanaged-sentinel/KEEP"
                ),
                encoding: .utf8
            ),
            "keep\n"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtimeRoot
                    .appendingPathComponent(
                        ".set-failed/\(requestID)/alpha-failure",
                        isDirectory: true
                    )
                    .path
            )
        )
    }

    func testAuthorityBoundSetRollsBackStoreAndExistingRuntimesAfterStoreCommitFailure() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let first = try makeExportedBundle(
            in: fixture,
            repositoryID: "alpha-post-commit",
            bundleName: "alpha-post-commit-bundle"
        )
        let second = try makeExportedBundle(
            in: fixture,
            repositoryID: "beta-post-commit",
            bundleName: "beta-post-commit-bundle"
        )
        let requestID = "request-set-post-commit-rollback"
        let sourceDeviceID = "mini-device"
        let targetDeviceID = "book-device"
        let catalogRevision = "2026-07-23.2"
        let inputs = try [
            makeBoundInput(
                setup: first,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 10,
                ledgerSequence: 23,
                catalogRevision: catalogRevision
            ),
            makeBoundInput(
                setup: second,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                targetDeviceID: targetDeviceID,
                authorityEpoch: 10,
                ledgerSequence: 23,
                catalogRevision: catalogRevision
            ),
        ]

        let targetStoreRoot = fixture.appendingPathComponent(
            "post-commit-target-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        for input in inputs {
            _ = try TatwoSkilletBundleTransport.importBundle(
                at: input.bundleURL,
                into: targetStore
            )
        }
        let repositoriesBeforeFailure = try Dictionary(
            uniqueKeysWithValues: inputs.map { input in
                (
                    input.repositoryID,
                    try targetStore.loadRepository(id: input.repositoryID)
                )
            }
        )

        let runtimeRoot = fixture.appendingPathComponent(
            "post-commit-runtime",
            isDirectory: true
        )
        let oldRuntimeBodies = [
            "alpha-post-commit": "old alpha runtime",
            "beta-post-commit": "old beta runtime",
        ]
        for (repositoryID, body) in oldRuntimeBodies {
            let active = runtimeRoot.appendingPathComponent(
                repositoryID,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: active,
                withIntermediateDirectories: true
            )
            try writeSkill(body, to: active)
        }

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.importAndActivateAuthorityBoundSet(
                inputs,
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: targetDeviceID,
                requestID: requestID,
                sourceDeviceID: sourceDeviceID,
                authorityEpoch: 10,
                ledgerSequence: 23,
                catalogRevision: catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 23),
                beforeRepositoryCommit: nil,
                afterStoreCommit: {
                    throw SetCommitFixtureError.injectedFailure
                }
            )
        ) { error in
            XCTAssertEqual(error as? SetCommitFixtureError, .injectedFailure)
        }

        XCTAssertEqual(
            try targetStore.listRepositoryIDs(),
            ["alpha-post-commit", "beta-post-commit"]
        )
        for input in inputs {
            XCTAssertEqual(
                try targetStore.loadRepository(id: input.repositoryID),
                repositoriesBeforeFailure[input.repositoryID]
            )
        }
        XCTAssertEqual(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: "alpha-post-commit"
            ),
            "---\nname: bundle-skill\n---\nold alpha runtime\n"
        )
        XCTAssertEqual(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: "beta-post-commit"
            ),
            "---\nname: bundle-skill\n---\nold beta runtime\n"
        )
        for repositoryID in oldRuntimeBodies.keys {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: runtimeRoot
                        .appendingPathComponent(
                            ".set-failed/\(requestID)/\(repositoryID)",
                            isDirectory: true
                        )
                        .path
                )
            )
        }
    }

    func testAtomicActivationRejectsRuntimeRootWithSymbolicLinkAncestor() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceDirectory = fixture.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try writeSkill("safe", to: sourceDirectory)
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("store", isDirectory: true)
        )
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "symlink-runtime-skill",
            displayName: "Symlink Runtime Skill",
            summary: "Runtime path fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging
        )

        let actualParent = fixture.appendingPathComponent("actual-parent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualParent,
            withIntermediateDirectories: true
        )
        let linkedParent = fixture.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: actualParent
        )
        let runtimeRoot = linkedParent.appendingPathComponent("runtime", isDirectory: true)

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.activateRevisionAtomically(
                in: store,
                repositoryID: "symlink-runtime-skill",
                revisionID: revision.id,
                runtimeRoot: runtimeRoot,
                deviceID: "macbook",
                requestID: "request-symlink-runtime",
                authorityEpoch: 1,
                ledgerSequence: 1,
                verifiedAt: Date(timeIntervalSince1970: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletBundleError,
                .unsafeRuntimePath(runtimeRoot.path)
            )
        }
    }

    func testDivergentBundlePersistsCleanMergeProposalWithoutAdvancingCanonical()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let repositoryID = "merge-transport"
        let targetSource = fixture.appendingPathComponent(
            "target-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nthree", to: targetSource)
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "target-store",
                isDirectory: true
            )
        )
        let base = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let baseBundle = fixture.appendingPathComponent(
            "base-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: base.id,
            to: baseBundle,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "source-store",
                isDirectory: true
            )
        )
        try TatwoSkilletBundleTransport.importBundle(
            at: baseBundle,
            into: sourceStore
        )

        try writeSkill("CANONICAL\ntwo\nthree", to: targetSource)
        let canonical = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let proposedSource = fixture.appendingPathComponent(
            "proposed-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: proposedSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nPROPOSED", to: proposedSource)
        let proposed = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: proposedSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let proposedBundle = fixture.appendingPathComponent(
            "proposed-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: repositoryID,
            revisionID: proposed.id,
            to: proposedBundle,
            createdAt: Date(timeIntervalSince1970: 5)
        )

        let outcome = try TatwoSkilletBundleTransport.receiveBundle(
            at: proposedBundle,
            into: targetStore,
            sourceDeviceID: "macbook",
            createdAt: Date(timeIntervalSince1970: 6)
        )
        guard case .mergeProposed(let proposal) = outcome else {
            return XCTFail("expected a merge proposal")
        }
        XCTAssertEqual(proposal.baseRevisionID, base.id)
        XCTAssertEqual(proposal.canonicalRevisionID, canonical.id)
        XCTAssertEqual(proposal.proposedRevisionID, proposed.id)
        XCTAssertNotNil(proposal.mergedRevisionID)
        XCTAssertTrue(proposal.conflictArtifactIDs.isEmpty)
        XCTAssertEqual(
            try targetStore.loadRepository(id: repositoryID).canonicalRevision,
            canonical.id
        )
        XCTAssertEqual(
            try targetStore.loadMergeProposals(repositoryID: repositoryID),
            [proposal]
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStore.rootURL.lastPathComponent).merge-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )

        let mergedRevisionID = try XCTUnwrap(proposal.mergedRevisionID)
        let materialized = fixture.appendingPathComponent(
            "merged-materialized",
            isDirectory: true
        )
        try targetStore.materializeRevision(
            repositoryID: repositoryID,
            revisionID: mergedRevisionID,
            to: materialized
        )
        XCTAssertEqual(
            try String(
                contentsOf: materialized.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "---\nname: bundle-skill\n---\nCANONICAL\ntwo\nPROPOSED\n"
        )

        _ = try targetStore.approveMergeProposal(
            repositoryID: repositoryID,
            proposalID: proposal.id,
            decidedBy: "test-lead",
            decidedAt: Date(timeIntervalSince1970: 7)
        )
        let approvedBundle = fixture.appendingPathComponent(
            "approved-merge-bundle",
            isDirectory: true
        )
        let approvedManifest = try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: mergedRevisionID,
            to: approvedBundle,
            createdAt: Date(timeIntervalSince1970: 8)
        )
        XCTAssertEqual(
            Set(approvedManifest.revisions.map(\.id)),
            Set([base.id, canonical.id, proposed.id, mergedRevisionID])
        )
        XCTAssertEqual(approvedManifest.revisions.last?.id, mergedRevisionID)
        let revisionIndex = Dictionary(
            uniqueKeysWithValues: approvedManifest.revisions.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        for revision in approvedManifest.revisions {
            if let parentRevisionID = revision.parentRevisionID {
                XCTAssertLessThan(
                    try XCTUnwrap(revisionIndex[parentRevisionID]),
                    try XCTUnwrap(revisionIndex[revision.id])
                )
            }
        }

        let convergedSource = try TatwoSkilletBundleTransport.importBundle(
            at: approvedBundle,
            into: sourceStore
        )
        XCTAssertEqual(convergedSource.canonicalRevision, mergedRevisionID)
        XCTAssertEqual(
            Set(convergedSource.revisions.map(\.id)),
            Set([base.id, canonical.id, proposed.id, mergedRevisionID])
        )
    }

    func testConflictRecheckFastForwardsWithoutLeavingMergeStagingLock() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let setup = try makeDivergentBundleFixture(
            in: fixture,
            repositoryID: "merge-fast-forward"
        )

        let outcome = try TatwoSkilletBundleTransport.receiveBundle(
            at: setup.proposedBundle,
            into: setup.targetStore,
            sourceDeviceID: "macbook",
            createdAt: Date(timeIntervalSince1970: 6),
            testHooks: .init(
                afterConflictDetected: {
                    try self.writeSkill(
                        "one\ntwo\nthree",
                        to: setup.targetSource
                    )
                    _ = try setup.targetStore.snapshotCanonicalSkillDirectory(
                        repositoryID: setup.repositoryID,
                        displayName: "Merge Transport",
                        summary: "Fixture",
                        sourceDirectory: setup.targetSource,
                        channel: .staging,
                        createdAt: Date(timeIntervalSince1970: 7)
                    )
                }
            )
        )
        guard case .imported(let imported) = outcome else {
            return XCTFail("expected conflict recheck to fast-forward")
        }

        XCTAssertEqual(imported.canonicalRevision, setup.proposed.id)
        XCTAssertEqual(
            try setup.targetStore.loadRepository(
                id: setup.repositoryID
            ).canonicalRevision,
            setup.proposed.id
        )
        XCTAssertTrue(
            try setup.targetStore.loadMergeProposals(
                repositoryID: setup.repositoryID
            ).isEmpty
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(setup.targetStore.rootURL.lastPathComponent).merge-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: setup.targetStore.mutationLockFileURL.path
            )
        )
    }

    func testDivergentStoreFailureRemovesMergeStagingLockAndPreservesStableStore()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let setup = try makeDivergentBundleFixture(
            in: fixture,
            repositoryID: "merge-catch-cleanup"
        )

        XCTAssertThrowsError(
            try TatwoSkilletBundleTransport.receiveBundle(
                at: setup.proposedBundle,
                into: setup.targetStore,
                sourceDeviceID: "macbook",
                createdAt: Date(timeIntervalSince1970: 6),
                testHooks: .init(
                    beforeDivergentStoreCommit: {
                        throw SetCommitFixtureError.injectedFailure
                    }
                )
            )
        ) { error in
            XCTAssertEqual(error as? SetCommitFixtureError, .injectedFailure)
        }
        XCTAssertEqual(
            try setup.targetStore.loadRepository(
                id: setup.repositoryID
            ).canonicalRevision,
            setup.canonical.id
        )
        XCTAssertTrue(
            try setup.targetStore.loadMergeProposals(
                repositoryID: setup.repositoryID
            ).isEmpty
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(setup.targetStore.rootURL.lastPathComponent).merge-staging-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: setup.targetStore.mutationLockFileURL.path
            )
        )
    }

    func testDivergentAuthorityBoundSetPersistsProposalAndDoesNotTouchRuntime()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let repositoryID = "merge-set"
        let targetSource = fixture.appendingPathComponent(
            "target-set-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nthree", to: targetSource)
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "target-set-store",
                isDirectory: true
            )
        )
        let base = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Set",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let baseBundle = fixture.appendingPathComponent(
            "set-base-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: base.id,
            to: baseBundle,
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "source-set-store",
                isDirectory: true
            )
        )
        try TatwoSkilletBundleTransport.importBundle(
            at: baseBundle,
            into: sourceStore
        )

        try writeSkill("CANONICAL\ntwo\nthree", to: targetSource)
        let canonical = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Set",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 12)
        )
        let proposedSource = fixture.appendingPathComponent(
            "proposed-set-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: proposedSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nPROPOSED", to: proposedSource)
        let proposed = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Set",
            summary: "Fixture",
            sourceDirectory: proposedSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 13)
        )
        let proposedBundle = fixture.appendingPathComponent(
            "set-proposed-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: repositoryID,
            revisionID: proposed.id,
            to: proposedBundle,
            createdAt: Date(timeIntervalSince1970: 14)
        )
        let input = try makeBoundInput(
            setup: (proposedBundle, proposed),
            requestID: "merge-set-request",
            sourceDeviceID: "macbook",
            targetDeviceID: "mini",
            authorityEpoch: 7,
            ledgerSequence: 9,
            catalogRevision: "catalog-v1"
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "runtime-must-stay-absent",
            isDirectory: true
        )

        let outcome = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "mini",
                requestID: "merge-set-request",
                sourceDeviceID: "macbook",
                authorityEpoch: 7,
                ledgerSequence: 9,
                catalogRevision: "catalog-v1",
                verifiedAt: Date(timeIntervalSince1970: 15)
            )
        guard case .mergeProposed(let pending) = outcome else {
            return XCTFail("expected aggregate merge proposal")
        }
        let proposals = pending.proposals
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(pending.repositoryCount, 1)
        XCTAssertTrue(pending.branchPreservedRevisions.isEmpty)
        XCTAssertEqual(proposals.first?.canonicalRevisionID, canonical.id)
        XCTAssertEqual(proposals.first?.proposedRevisionID, proposed.id)
        XCTAssertEqual(
            try targetStore.loadRepository(id: repositoryID).canonicalRevision,
            canonical.id
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeRoot.path))
    }

    func testOwnerInitiatedDivergentSetAutoAppliesAndArchivesDisplacedRevision()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let repositoryID = "owner-apply"
        let targetSource = fixture.appendingPathComponent(
            "owner-target-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nthree", to: targetSource)
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "owner-target-store",
                isDirectory: true
            )
        )
        let base = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Owner Apply",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let baseBundle = fixture.appendingPathComponent(
            "owner-base-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: base.id,
            to: baseBundle,
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "owner-source-store",
                isDirectory: true
            )
        )
        try TatwoSkilletBundleTransport.importBundle(
            at: baseBundle,
            into: sourceStore
        )

        try writeSkill("CANONICAL\ntwo\nthree", to: targetSource)
        let displaced = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Owner Apply",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 12)
        )
        let proposedSource = fixture.appendingPathComponent(
            "owner-proposed-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: proposedSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nPROPOSED", to: proposedSource)
        let proposed = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Owner Apply",
            summary: "Fixture",
            sourceDirectory: proposedSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 13)
        )
        let proposedBundle = fixture.appendingPathComponent(
            "owner-proposed-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: repositoryID,
            revisionID: proposed.id,
            to: proposedBundle,
            createdAt: Date(timeIntervalSince1970: 14)
        )
        let input = try makeBoundInput(
            setup: (proposedBundle, proposed),
            requestID: "owner-apply-request",
            sourceDeviceID: "book-primary",
            targetDeviceID: "mini",
            authorityEpoch: 7,
            ledgerSequence: 9,
            catalogRevision: "catalog-v1"
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "owner-runtime",
            isDirectory: true
        )

        let parked = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "mini",
                requestID: "owner-apply-request",
                sourceDeviceID: "book-primary",
                authorityEpoch: 7,
                ledgerSequence: 9,
                catalogRevision: "catalog-v1",
                ownerInitiatedApply: false,
                verifiedAt: Date(timeIntervalSince1970: 15)
            )
        guard case .mergeProposed = parked else {
            return XCTFail("non-owner path must still park in merge-pending")
        }
        XCTAssertEqual(
            try targetStore.loadRepository(id: repositoryID).canonicalRevision,
            displaced.id
        )

        let outcome = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                [input],
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: "mini",
                requestID: "owner-apply-request",
                sourceDeviceID: "book-primary",
                authorityEpoch: 7,
                ledgerSequence: 9,
                catalogRevision: "catalog-v1",
                ownerInitiatedApply: true,
                verifiedAt: Date(timeIntervalSince1970: 16)
            )
        guard case .activated(let activation) = outcome else {
            return XCTFail("owner-initiated conflict must auto-apply")
        }
        XCTAssertEqual(activation.heads.map(\.revisionID), [proposed.id])
        let repository = try targetStore.loadRepository(id: repositoryID)
        XCTAssertEqual(repository.canonicalRevision, proposed.id)
        XCTAssertEqual(repository.rollbackRevision, displaced.id)
        XCTAssertTrue(repository.revisions.contains(where: { $0.id == displaced.id }))
        XCTAssertTrue(repository.revisions.contains(where: { $0.id == proposed.id }))
        let archiveReceipts = try targetStore.loadReceipts(
            repositoryID: repositoryID
        ).filter { $0.kind == .archive }
        XCTAssertEqual(archiveReceipts.count, 1)
        XCTAssertEqual(archiveReceipts.first?.revisionID, displaced.id)
        XCTAssertEqual(archiveReceipts.first?.requestID, "owner-apply-request")
        XCTAssertTrue(
            try activeSkillText(
                runtimeRoot: runtimeRoot,
                repositoryID: repositoryID
            ).contains("PROPOSED")
        )
    }

    func testMixedAuthorityBoundSetReportsEveryPreservedBranchAndProposal()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let targetStoreRoot = fixture.appendingPathComponent(
            "mixed-target-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "mixed-source-store",
                isDirectory: true
            )
        )
        let requestID = "mixed-set-request"
        let shared = (
            requestID: requestID,
            sourceDeviceID: "macbook",
            targetDeviceID: "mini",
            authorityEpoch: UInt64(11),
            ledgerSequence: UInt64(17),
            catalogRevision: "catalog-mixed-v1"
        )
        let divergent = try makeBoundRepositoryPair(
            in: fixture,
            targetStore: targetStore,
            sourceStore: sourceStore,
            repositoryID: "alpha-divergent",
            targetBody: "target alpha\nshared",
            sourceBody: "shared\nsource alpha",
            operation: shared
        )
        let firstForward = try makeBoundRepositoryPair(
            in: fixture,
            targetStore: targetStore,
            sourceStore: sourceStore,
            repositoryID: "beta-forward",
            targetBody: nil,
            sourceBody: "shared\nsource beta",
            operation: shared
        )
        let secondForward = try makeBoundRepositoryPair(
            in: fixture,
            targetStore: targetStore,
            sourceStore: sourceStore,
            repositoryID: "gamma-forward",
            targetBody: nil,
            sourceBody: "shared\nsource gamma",
            operation: shared
        )
        let runtimeRoot = fixture.appendingPathComponent(
            "mixed-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeRoot,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(
            to: runtimeRoot.appendingPathComponent("KEEP"),
            options: [.atomic]
        )

        let outcome = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                [secondForward.input, divergent.input, firstForward.input]
                    .sorted { $0.repositoryID < $1.repositoryID },
                into: targetStore,
                runtimeRoot: runtimeRoot,
                deviceID: shared.targetDeviceID,
                requestID: shared.requestID,
                sourceDeviceID: shared.sourceDeviceID,
                authorityEpoch: shared.authorityEpoch,
                ledgerSequence: shared.ledgerSequence,
                catalogRevision: shared.catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 18)
            )
        guard case .mergeProposed(let pending) = outcome else {
            return XCTFail("expected a mixed pending merge set")
        }

        XCTAssertEqual(pending.repositoryCount, 3)
        XCTAssertEqual(
            pending.proposals.map(\.repositoryID),
            ["alpha-divergent"]
        )
        XCTAssertEqual(
            pending.branchPreservedRevisions.map(\.repositoryID),
            ["beta-forward", "gamma-forward"]
        )
        XCTAssertEqual(
            pending.branchPreservedRevisions.map(\.revisionID),
            [firstForward.sourceRevision.id, secondForward.sourceRevision.id]
        )
        XCTAssertEqual(
            try targetStore.loadRepository(
                id: divergent.input.repositoryID
            ).canonicalRevision,
            divergent.targetCanonical.id
        )
        XCTAssertEqual(
            try targetStore.loadRepository(
                id: firstForward.input.repositoryID
            ).canonicalRevision,
            firstForward.base.id
        )
        XCTAssertEqual(
            try targetStore.loadRepository(
                id: secondForward.input.repositoryID
            ).canonicalRevision,
            secondForward.base.id
        )
        XCTAssertEqual(
            try Data(contentsOf: runtimeRoot.appendingPathComponent("KEEP")),
            Data("keep".utf8)
        )
        for repositoryID in [
            divergent.input.repositoryID,
            firstForward.input.repositoryID,
            secondForward.input.repositoryID,
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: runtimeRoot
                        .appendingPathComponent(repositoryID, isDirectory: true)
                        .path
                )
            )
        }
    }

    func testThreeDivergentRepositoriesUseOneAggregateStoreArchive()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let targetStoreRoot = fixture.appendingPathComponent(
            "three-divergent-target-store",
            isDirectory: true
        )
        let targetStore = TatwoSkilletRepositoryStore(rootURL: targetStoreRoot)
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "three-divergent-source-store",
                isDirectory: true
            )
        )
        let requestID = "three-divergent-request"
        let shared = (
            requestID: requestID,
            sourceDeviceID: "macbook",
            targetDeviceID: "mini",
            authorityEpoch: UInt64(12),
            ledgerSequence: UInt64(19),
            catalogRevision: "catalog-three-divergent-v1"
        )
        let pairs = try ["alpha", "beta", "gamma"].map { repositoryID in
            try makeBoundRepositoryPair(
                in: fixture,
                targetStore: targetStore,
                sourceStore: sourceStore,
                repositoryID: repositoryID,
                targetBody: "target \(repositoryID)\nshared",
                sourceBody: "shared\nsource \(repositoryID)",
                operation: shared
            )
        }

        let outcome = try TatwoSkilletBundleTransport
            .receiveAndActivateAuthorityBoundSet(
                pairs.map(\.input).sorted { $0.repositoryID < $1.repositoryID },
                into: targetStore,
                runtimeRoot: fixture.appendingPathComponent(
                    "three-divergent-runtime",
                    isDirectory: true
                ),
                deviceID: shared.targetDeviceID,
                requestID: shared.requestID,
                sourceDeviceID: shared.sourceDeviceID,
                authorityEpoch: shared.authorityEpoch,
                ledgerSequence: shared.ledgerSequence,
                catalogRevision: shared.catalogRevision,
                verifiedAt: Date(timeIntervalSince1970: 20)
            )
        guard case .mergeProposed(let pending) = outcome else {
            return XCTFail("expected an aggregate pending merge set")
        }

        XCTAssertEqual(pending.repositoryCount, 3)
        XCTAssertEqual(
            pending.proposals.map(\.repositoryID),
            ["alpha", "beta", "gamma"]
        )
        XCTAssertTrue(pending.branchPreservedRevisions.isEmpty)
        let archiveRoot = fixture
            .appendingPathComponent(".skillet-import-archive", isDirectory: true)
            .appendingPathComponent(
                targetStoreRoot.lastPathComponent,
                isDirectory: true
            )
        let archives = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            archives.count,
            1,
            "aggregate divergence must copy/swap/archive the whole store once"
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                ".\(targetStoreRoot.lastPathComponent).pending-merge-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            try pathsNamedWithPrefix(
                "..\(targetStoreRoot.lastPathComponent).pending-merge-",
                below: fixture
            ).isEmpty
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: targetStore.mutationLockFileURL.path
            )
        )
    }

    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-skillet-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExportedBundle(
        in fixture: URL,
        repositoryID: String,
        bundleName: String = "bundle"
    ) throws -> (bundleURL: URL, revision: TatwoSkillRevisionV1) {
        let sourceDirectory = fixture
            .appendingPathComponent("\(repositoryID)-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try writeSkill("safe", to: sourceDirectory)
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent("\(repositoryID)-store", isDirectory: true)
        )
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Bundle Skill",
            summary: "Bundle fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging
        )
        let bundleURL = fixture.appendingPathComponent(bundleName, isDirectory: true)
        _ = try TatwoSkilletBundleTransport.exportBundle(
            from: store,
            repositoryID: repositoryID,
            revisionID: revision.id,
            to: bundleURL
        )
        return (bundleURL, revision)
    }

    private func makeDivergentBundleFixture(
        in fixture: URL,
        repositoryID: String
    ) throws -> (
        repositoryID: String,
        targetSource: URL,
        targetStore: TatwoSkilletRepositoryStore,
        base: TatwoSkillRevisionV1,
        canonical: TatwoSkillRevisionV1,
        proposed: TatwoSkillRevisionV1,
        proposedBundle: URL
    ) {
        let targetSource = fixture.appendingPathComponent(
            "\(repositoryID)-target-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: targetSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nthree", to: targetSource)
        let targetStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "\(repositoryID)-target-store",
                isDirectory: true
            )
        )
        let base = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let baseBundle = fixture.appendingPathComponent(
            "\(repositoryID)-base-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: base.id,
            to: baseBundle,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let sourceStore = TatwoSkilletRepositoryStore(
            rootURL: fixture.appendingPathComponent(
                "\(repositoryID)-source-store",
                isDirectory: true
            )
        )
        try TatwoSkilletBundleTransport.importBundle(
            at: baseBundle,
            into: sourceStore
        )

        try writeSkill("CANONICAL\ntwo\nthree", to: targetSource)
        let canonical = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: targetSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let proposedSource = fixture.appendingPathComponent(
            "\(repositoryID)-proposed-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: proposedSource,
            withIntermediateDirectories: true
        )
        try writeSkill("one\ntwo\nPROPOSED", to: proposedSource)
        let proposed = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: "Merge Transport",
            summary: "Fixture",
            sourceDirectory: proposedSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let proposedBundle = fixture.appendingPathComponent(
            "\(repositoryID)-proposed-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: repositoryID,
            revisionID: proposed.id,
            to: proposedBundle,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        return (
            repositoryID,
            targetSource,
            targetStore,
            base,
            canonical,
            proposed,
            proposedBundle
        )
    }

    private func writeSkill(_ body: String, to directory: URL) throws {
        try Data("---\nname: bundle-skill\n---\n\(body)\n".utf8)
            .write(to: directory.appendingPathComponent("SKILL.md"), options: [.atomic])
    }

    private func makeBoundInput(
        setup: (bundleURL: URL, revision: TatwoSkillRevisionV1),
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: UInt64,
        ledgerSequence: UInt64,
        catalogRevision: String
    ) throws -> TatwoSkilletBoundBundleInputV1 {
        let binding = try TatwoSkilletBundleTransport.makeAuthorityBinding(
            at: setup.bundleURL,
            requestID: requestID,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            catalogRevision: catalogRevision,
            createdAt: Date(timeIntervalSince1970: TimeInterval(ledgerSequence))
        )
        return TatwoSkilletBoundBundleInputV1(
            repositoryID: setup.revision.repositoryID,
            revisionID: setup.revision.id,
            contentDigest: setup.revision.contentDigest,
            bundleDigest: binding.bundleDigest,
            bundleURL: setup.bundleURL,
            binding: binding
        )
    }

    private func makeBoundRepositoryPair(
        in fixture: URL,
        targetStore: TatwoSkilletRepositoryStore,
        sourceStore: TatwoSkilletRepositoryStore,
        repositoryID: String,
        targetBody: String?,
        sourceBody: String,
        operation: (
            requestID: String,
            sourceDeviceID: String,
            targetDeviceID: String,
            authorityEpoch: UInt64,
            ledgerSequence: UInt64,
            catalogRevision: String
        )
    ) throws -> (
        input: TatwoSkilletBoundBundleInputV1,
        base: TatwoSkillRevisionV1,
        targetCanonical: TatwoSkillRevisionV1,
        sourceRevision: TatwoSkillRevisionV1
    ) {
        let baseSource = fixture.appendingPathComponent(
            "\(repositoryID)-base-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: baseSource,
            withIntermediateDirectories: true
        )
        try writeSkill("shared", to: baseSource)
        let base = try targetStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "Aggregate merge fixture",
            sourceDirectory: baseSource,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let baseBundle = fixture.appendingPathComponent(
            "\(repositoryID)-base-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: targetStore,
            repositoryID: repositoryID,
            revisionID: base.id,
            to: baseBundle,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        _ = try TatwoSkilletBundleTransport.importBundle(
            at: baseBundle,
            into: sourceStore
        )

        let targetCanonical: TatwoSkillRevisionV1
        if let targetBody {
            let targetSource = fixture.appendingPathComponent(
                "\(repositoryID)-target-source",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: targetSource,
                withIntermediateDirectories: true
            )
            try writeSkill(targetBody, to: targetSource)
            targetCanonical = try targetStore.snapshotCanonicalSkillDirectory(
                repositoryID: repositoryID,
                displayName: repositoryID,
                summary: "Aggregate merge fixture",
                sourceDirectory: targetSource,
                channel: .staging,
                createdAt: Date(timeIntervalSince1970: 3)
            )
        } else {
            targetCanonical = base
        }

        let sourceDirectory = fixture.appendingPathComponent(
            "\(repositoryID)-source-branch",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try writeSkill(sourceBody, to: sourceDirectory)
        let sourceRevision = try sourceStore.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "Aggregate merge fixture",
            sourceDirectory: sourceDirectory,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 4)
        )
        let bundleURL = fixture.appendingPathComponent(
            "\(repositoryID)-incoming-bundle",
            isDirectory: true
        )
        try TatwoSkilletBundleTransport.exportBundle(
            from: sourceStore,
            repositoryID: repositoryID,
            revisionID: sourceRevision.id,
            to: bundleURL,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        let input = try makeBoundInput(
            setup: (bundleURL, sourceRevision),
            requestID: operation.requestID,
            sourceDeviceID: operation.sourceDeviceID,
            targetDeviceID: operation.targetDeviceID,
            authorityEpoch: operation.authorityEpoch,
            ledgerSequence: operation.ledgerSequence,
            catalogRevision: operation.catalogRevision
        )
        return (input, base, targetCanonical, sourceRevision)
    }

    private func activeSkillText(runtimeRoot: URL, repositoryID: String) throws -> String {
        try String(
            contentsOf: runtimeRoot
                .appendingPathComponent(repositoryID, isDirectory: true)
                .appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
    }

    private func pathsNamedWithPrefix(
        _ prefix: String,
        below root: URL
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var matches: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(prefix) {
            matches.append(url)
        }
        return matches
    }

    private func decodeJSONObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}

private enum SetCommitFixtureError: Error {
    case injectedFailure
    case injectedRollbackFailure
}

private final class LockedTestErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
