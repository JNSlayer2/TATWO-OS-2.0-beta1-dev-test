import CryptoKit
import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoSkilletRepositoryStoreTests: XCTestCase {
    func testSnapshotsCanonicalSkillDirectoryAndMaterializesImmutableRevision() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("---\nname: skillet-test\n---\nfirst\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
        try Data("#!/bin/sh\necho first\n".utf8)
            .write(to: source.appendingPathComponent("scripts/run.sh"))

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let first = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "skillet-test",
            displayName: "Skillet Test",
            summary: "Fixture skill",
            sourceDirectory: source,
            channel: .draft,
            createdAt: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(first.contentDigest.count, 64)
        XCTAssertEqual(first.id, "rev-\(first.contentDigest)")
        XCTAssertTrue(try store.verifyRevision(repositoryID: "skillet-test", revisionID: first.id))
        let manifest = try store.loadSnapshotManifest(
            repositoryID: "skillet-test",
            revisionID: first.id
        )
        XCTAssertEqual(manifest.files.map(\.relativePath), ["SKILL.md", "scripts/run.sh"])
        let snapshotReceipts = try store.loadReceipts(repositoryID: "skillet-test")
        XCTAssertEqual(snapshotReceipts.map(\.kind), [.snapshot])
        XCTAssertEqual(snapshotReceipts.first?.revisionID, first.id)
        XCTAssertEqual(snapshotReceipts.first?.contentDigest, first.contentDigest)

        let duplicate = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "skillet-test",
            displayName: "Skillet Test",
            summary: "Fixture skill",
            sourceDirectory: source,
            channel: .draft,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(duplicate.id, first.id)
        XCTAssertEqual(try store.loadRepository(id: "skillet-test").revisions.count, 1)

        try Data("---\nname: skillet-test\n---\nsecond\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
        let second = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "skillet-test",
            displayName: "Skillet Test",
            summary: "Fixture skill",
            sourceDirectory: source,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertNotEqual(second.contentDigest, first.contentDigest)
        XCTAssertEqual(second.parentRevisionID, first.id)

        let restored = fixture.root.appendingPathComponent("restored", isDirectory: true)
        try store.materializeRevision(
            repositoryID: "skillet-test",
            revisionID: first.id,
            to: restored
        )
        XCTAssertEqual(
            try String(contentsOf: restored.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "---\nname: skillet-test\n---\nfirst\n"
        )
        XCTAssertEqual(
            try String(
                contentsOf: restored.appendingPathComponent("scripts/run.sh"),
                encoding: .utf8
            ),
            "#!/bin/sh\necho first\n"
        )
    }

    func testSnapshotManifestUsesPortableUTF8ByteOrdering() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# skill\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("combining\n".utf8).write(
            to: source.appendingPathComponent("e\u{301}.txt")
        )
        try Data("umlaut\n".utf8).write(to: source.appendingPathComponent("ä.txt"))

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "portable-order",
            displayName: "Portable Order",
            summary: "Cross-language digest ordering fixture",
            sourceDirectory: source,
            channel: .staging
        )
        let manifest = try store.loadSnapshotManifest(
            repositoryID: "portable-order",
            revisionID: revision.id
        )

        XCTAssertEqual(
            manifest.files.map(\.relativePath),
            ["SKILL.md", "ä.txt", "é.txt"]
        )
        XCTAssertEqual(
            revision.contentDigest,
            "1b41e70b0bd608ba78beec0102f64c06250b59d8469e7c7b193dc831eea87d7d"
        )
    }

    func testPersistsStableCanaryRollbackMetadataAndDeviceHeads() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("stable\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))

        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let stable = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "tatwo-ultrawork",
            displayName: "TATWO Ultrawork",
            summary: "Work OS",
            sourceDirectory: source,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try store.promoteRevision(
            repositoryID: "tatwo-ultrawork",
            revisionID: stable.id,
            to: .stable
        )

        try Data("canary\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let canary = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "tatwo-ultrawork",
            displayName: "TATWO Ultrawork",
            summary: "Work OS",
            sourceDirectory: source,
            channel: .staging,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try store.promoteRevision(
            repositoryID: "tatwo-ultrawork",
            revisionID: canary.id,
            to: .canary
        )
        try store.upsertDeviceHead(
            .init(
                deviceID: "macbook",
                repositoryID: "tatwo-ultrawork",
                revisionID: canary.id,
                contentDigest: canary.contentDigest,
                requestID: "request-canary",
                authorityEpoch: 1,
                ledgerSequence: 1,
                activationState: .canary,
                lastVerifiedAt: Date(timeIntervalSince1970: 3)
            )
        )

        var repository = try TatwoSkilletRepositoryStore(rootURL: storeRoot)
            .loadRepository(id: "tatwo-ultrawork")
        XCTAssertEqual(repository.stableRevision, stable.id)
        XCTAssertEqual(repository.canaryRevision, canary.id)
        XCTAssertNil(repository.rollbackRevision)
        XCTAssertEqual(repository.deviceHeads.map(\.deviceID), ["macbook"])
        XCTAssertEqual(repository.health, .canary)

        try store.promoteRevision(
            repositoryID: "tatwo-ultrawork",
            revisionID: canary.id,
            to: .stable
        )
        try store.upsertDeviceHead(
            .init(
                deviceID: "macbook",
                repositoryID: "tatwo-ultrawork",
                revisionID: canary.id,
                contentDigest: canary.contentDigest,
                requestID: "request-stable",
                authorityEpoch: 1,
                ledgerSequence: 2,
                activationState: .active,
                lastVerifiedAt: Date(timeIntervalSince1970: 4)
            )
        )

        repository = try TatwoSkilletRepositoryStore(rootURL: storeRoot)
            .loadRepository(id: "tatwo-ultrawork")
        XCTAssertEqual(repository.stableRevision, canary.id)
        XCTAssertNil(repository.canaryRevision)
        XCTAssertEqual(repository.rollbackRevision, stable.id)
        XCTAssertEqual(repository.health, .healthy)

        try store.rollbackStable(repositoryID: "tatwo-ultrawork")
        repository = try store.loadRepository(id: "tatwo-ultrawork")
        XCTAssertEqual(repository.stableRevision, stable.id)
        XCTAssertEqual(repository.rollbackRevision, canary.id)
    }

    func testDeviceHeadRejectsCorruptedRevisionObject() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))

        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "corruption-test",
            displayName: "Corruption Test",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging
        )
        let storedSkill = storeRoot
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent(revision.contentDigest, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try Data("tampered\n".utf8).write(to: storedSkill)

        XCTAssertThrowsError(
            try store.upsertDeviceHead(
                .init(
                    deviceID: "macbook",
                    repositoryID: "corruption-test",
                    revisionID: revision.id,
                    contentDigest: revision.contentDigest,
                    requestID: "request-corrupted",
                    authorityEpoch: 1,
                    ledgerSequence: 1,
                    activationState: .active,
                    lastVerifiedAt: Date()
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedRevision(revision.id)
            )
        }
    }

    func testSnapshotRejectsSymbolicLinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("private\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked-secret.txt"),
            withDestinationURL: outside
        )

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        XCTAssertThrowsError(
            try store.snapshotCanonicalSkillDirectory(
                repositoryID: "unsafe-skill",
                displayName: "Unsafe",
                summary: "Unsafe fixture",
                sourceDirectory: source,
                channel: .draft
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .unsupportedSnapshotEntry("linked-secret.txt")
            )
        }
    }

    func testSnapshotExcludesGitControlMetadataWithoutPersistingIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe manifest\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("gitdir: /private/worktree\n".utf8).write(
            to: source.appendingPathComponent(".git")
        )
        let nestedGit = source
            .appendingPathComponent("references", isDirectory: true)
            .appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedGit,
            withIntermediateDirectories: true
        )
        try Data("must not persist\n".utf8).write(
            to: nestedGit.appendingPathComponent("config")
        )
        try Data("tracked\n".utf8).write(
            to: source
                .appendingPathComponent("references", isDirectory: true)
                .appendingPathComponent("guide.md")
        )

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "git-worktree-skill",
            displayName: "Git worktree skill",
            summary: "VCS metadata is transport-local",
            sourceDirectory: source,
            channel: .staging
        )
        let manifestData = try Data(
            contentsOf: store.rootURL
                .appendingPathComponent("objects", isDirectory: true)
                .appendingPathComponent(revision.contentDigest, isDirectory: true)
                .appendingPathComponent("manifest.json")
        )
        let manifest = try JSONDecoder().decode(
            TatwoSkillSnapshotManifestV1.self,
            from: manifestData
        )

        XCTAssertEqual(
            manifest.files.map(\.relativePath),
            ["SKILL.md", "references/guide.md"]
        )
        XCTAssertFalse(manifest.files.contains { $0.relativePath.contains(".git") })
        XCTAssertTrue(
            try store.verifyRevision(
                repositoryID: "git-worktree-skill",
                revisionID: revision.id
            )
        )
    }

    func testSnapshotRejectsGitMetadataSymlinkBeforeExclusion() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        let external = fixture.root.appendingPathComponent("external-git", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("safe manifest\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("must not be traversed\n".utf8).write(
            to: external.appendingPathComponent("config")
        )
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent(".git"),
            withDestinationURL: external
        )

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        XCTAssertThrowsError(
            try store.snapshotCanonicalSkillDirectory(
                repositoryID: "git-symlink-skill",
                displayName: "Git Symlink",
                summary: "Must fail closed",
                sourceDirectory: source,
                channel: .draft
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .unsupportedSnapshotEntry(".git")
            )
        }
    }

    func testSnapshotRejectsSecretBearingPaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe manifest\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("must not sync\n".utf8).write(to: source.appendingPathComponent("api-token.txt"))

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        XCTAssertThrowsError(
            try store.snapshotCanonicalSkillDirectory(
                repositoryID: "secret-bearing-skill",
                displayName: "Unsafe",
                summary: "Contains token material",
                sourceDirectory: source,
                channel: .draft
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .prohibitedSnapshotEntry("api-token.txt")
            )
        }
    }

    func testSnapshotRejectsObviousSecretEmbeddedInsideSkillManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fakeCredential = "sk-proj-\(String(repeating: "A", count: 48))"
        try Data(
            """
            ---
            name: embedded-secret
            ---
            Never persist this fixture credential: \(fakeCredential)
            """.utf8
        ).write(to: source.appendingPathComponent("SKILL.md"))

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        XCTAssertThrowsError(
            try store.snapshotCanonicalSkillDirectory(
                repositoryID: "embedded-secret",
                displayName: "Embedded secret",
                summary: "Must fail closed",
                sourceDirectory: source,
                channel: .draft
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .prohibitedSnapshotContent("SKILL.md")
            )
        }
    }

    func testSnapshotRejectsExpandedProviderSecretsAndSensitiveKeyPaths() throws {
        let prohibitedContents = [
            "sk-ant-\(String(repeating: "A", count: 48))",
            "AIza\(String(repeating: "B", count: 36))",
            "-----BEGIN PGP PRIVATE KEY BLOCK-----\nfixture\n",
            "aws_secret_access_key=\(String(repeating: "C", count: 40))",
        ]
        for (index, prohibitedContent) in prohibitedContents.enumerated() {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let source = fixture.root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: true
            )
            try Data(prohibitedContent.utf8).write(
                to: source.appendingPathComponent("SKILL.md")
            )
            let store = TatwoSkilletRepositoryStore(
                rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
            )

            XCTAssertThrowsError(
                try store.snapshotCanonicalSkillDirectory(
                    repositoryID: "provider-secret-\(index)",
                    displayName: "Provider secret",
                    summary: "Must fail closed",
                    sourceDirectory: source,
                    channel: .draft
                )
            ) { error in
                XCTAssertEqual(
                    error as? TatwoSkilletRepositoryStoreError,
                    .prohibitedSnapshotContent("SKILL.md")
                )
            }
        }

        for fileName in ["api-keys.json", "api_keys.json", "apikeys.json"] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let source = fixture.root.appendingPathComponent("source", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: true
            )
            try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
            try Data("must not sync\n".utf8).write(
                to: source.appendingPathComponent(fileName)
            )
            let store = TatwoSkilletRepositoryStore(
                rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
            )

            XCTAssertThrowsError(
                try store.snapshotCanonicalSkillDirectory(
                    repositoryID: "sensitive-path-\(UUID().uuidString)",
                    displayName: "Sensitive path",
                    summary: "Must fail closed",
                    sourceDirectory: source,
                    channel: .draft
                )
            ) { error in
                XCTAssertEqual(
                    error as? TatwoSkilletRepositoryStoreError,
                    .prohibitedSnapshotEntry(fileName)
                )
            }
        }
    }

    func testSnapshotRejectsSymbolicLinkAsSourceRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let actual = fixture.root.appendingPathComponent("actual-source", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: actual.appendingPathComponent("SKILL.md"))
        let linked = fixture.root.appendingPathComponent("linked-source", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)

        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        XCTAssertThrowsError(
            try store.snapshotCanonicalSkillDirectory(
                repositoryID: "linked-source",
                displayName: "Linked",
                summary: "Must fail closed",
                sourceDirectory: linked,
                channel: .draft
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .unsupportedSnapshotEntry(".")
            )
        }
    }

    func testLoadRepositoryRejectsForgedMetadataRevisionIdentifier() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        _ = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "metadata-test",
            displayName: "Metadata",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .draft
        )

        let metadataURL = storeRoot
            .appendingPathComponent("repositories/metadata-test/repository.json")
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
                as? [String: Any]
        )
        metadata["revisionIDs"] = ["../../forged"]
        metadata["canonicalRevision"] = "../../forged"
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            .write(to: metadataURL, options: [.atomic])

        XCTAssertThrowsError(try store.loadRepository(id: "metadata-test")) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedRepositoryMetadata("metadata-test")
            )
        }
    }

    func testLoadRepositoryRejectsForgedDeviceHeadFilenameAndDigest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "head-test",
            displayName: "Head",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging
        )
        let forged = TatwoDeviceHeadV1(
            deviceID: "macbook",
            repositoryID: "head-test",
            revisionID: revision.id,
            contentDigest: String(repeating: "0", count: 64),
            requestID: "request-forged",
            authorityEpoch: 1,
            ledgerSequence: 1,
            activationState: .active,
            lastVerifiedAt: Date()
        )
        let headURL = storeRoot
            .appendingPathComponent("repositories/head-test/device-heads/wrong-name.json")
        try FileManager.default.createDirectory(
            at: headURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(forged).write(to: headURL)

        XCTAssertThrowsError(try store.loadRepository(id: "head-test")) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedDeviceHead("macbook")
            )
        }
    }

    func testLoadReceiptsRejectsFilenameOrDigestForgery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "receipt-test",
            displayName: "Receipt",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .draft
        )
        let forged = TatwoSkilletRepositoryReceiptV1(
            id: "promotion-forged",
            repositoryID: "receipt-test",
            revisionID: revision.id,
            kind: .promotion,
            contentDigest: String(repeating: "0", count: 64),
            message: "forged"
        )
        let forgedURL = storeRoot
            .appendingPathComponent("repositories/receipt-test/receipts/wrong-name.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(forged).write(to: forgedURL)

        XCTAssertThrowsError(try store.loadReceipts(repositoryID: "receipt-test")) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedReceipt("promotion-forged")
            )
        }
    }

    func testDeviceHeadRejectsAuthorityAndLedgerRegressionButAllowsExactReplay() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "head-order",
            displayName: "Head order",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging
        )
        let current = TatwoDeviceHeadV1(
            deviceID: "macbook",
            repositoryID: "head-order",
            revisionID: revision.id,
            contentDigest: revision.contentDigest,
            requestID: "request-current",
            authorityEpoch: 4,
            ledgerSequence: 9,
            activationState: .active,
            lastVerifiedAt: Date(timeIntervalSince1970: 10)
        )
        try store.upsertDeviceHead(current)
        try store.upsertDeviceHead(current)
        XCTAssertEqual(
            try store.loadRepository(id: "head-order").deviceHeads,
            [current]
        )

        for stale in [
            TatwoDeviceHeadV1(
                deviceID: current.deviceID,
                repositoryID: current.repositoryID,
                revisionID: current.revisionID,
                contentDigest: current.contentDigest,
                requestID: "request-old-epoch",
                authorityEpoch: 3,
                ledgerSequence: 99,
                activationState: .active,
                lastVerifiedAt: Date(timeIntervalSince1970: 20)
            ),
            TatwoDeviceHeadV1(
                deviceID: current.deviceID,
                repositoryID: current.repositoryID,
                revisionID: current.revisionID,
                contentDigest: current.contentDigest,
                requestID: "request-old-sequence",
                authorityEpoch: 4,
                ledgerSequence: 8,
                activationState: .active,
                lastVerifiedAt: Date(timeIntervalSince1970: 20)
            ),
            TatwoDeviceHeadV1(
                deviceID: current.deviceID,
                repositoryID: current.repositoryID,
                revisionID: current.revisionID,
                contentDigest: current.contentDigest,
                requestID: "request-conflict",
                authorityEpoch: 4,
                ledgerSequence: 9,
                activationState: .active,
                lastVerifiedAt: Date(timeIntervalSince1970: 20)
            ),
        ] {
            XCTAssertThrowsError(try store.upsertDeviceHead(stale)) { error in
                XCTAssertEqual(
                    error as? TatwoSkilletRepositoryStoreError,
                    .staleDeviceHead("macbook")
                )
            }
        }
    }

    func testVerifyRevisionRejectsDuplicateManifestPaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        try Data("echo safe\n".utf8)
            .write(to: source.appendingPathComponent("scripts/run.sh"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "duplicate-manifest",
            displayName: "Duplicate Manifest",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .draft
        )

        let manifestURL = storeRoot
            .appendingPathComponent("objects/\(revision.contentDigest)/manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        files.append(try XCTUnwrap(files.first))
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: [.atomic])

        XCTAssertFalse(
            try store.verifyRevision(
                repositoryID: "duplicate-manifest",
                revisionID: revision.id
            )
        )
    }

    func testVerifyRevisionRejectsNonHexPerFileDigest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("safe\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let revision = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "nonhex-manifest",
            displayName: "Non-hex Manifest",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .draft
        )

        let manifestURL = storeRoot
            .appendingPathComponent("objects/\(revision.contentDigest)/manifest.json")
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        var files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        files[0]["contentDigest"] = String(repeating: "a", count: 56) + "zzzzzzzz"
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL, options: [.atomic])

        XCTAssertFalse(
            try store.verifyRevision(
                repositoryID: "nonhex-manifest",
                revisionID: revision.id
            )
        )
    }

    func testLoadRepositoryRejectsParentRevisionCycle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let first = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "cycle-test",
            displayName: "Cycle",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .draft
        )
        try Data("second\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let second = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "cycle-test",
            displayName: "Cycle",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging
        )

        let firstRevisionURL = storeRoot
            .appendingPathComponent("repositories/cycle-test/revisions/\(first.id).json")
        var firstRevision = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: firstRevisionURL))
                as? [String: Any]
        )
        firstRevision["parentRevisionID"] = second.id
        try JSONSerialization.data(withJSONObject: firstRevision, options: [.sortedKeys])
            .write(to: firstRevisionURL, options: [.atomic])

        XCTAssertThrowsError(try store.loadRepository(id: "cycle-test")) { error in
            guard let storeError = error as? TatwoSkilletRepositoryStoreError,
                  case .corruptedRevision = storeError
            else {
                return XCTFail("expected corruptedRevision, got \(error)")
            }
        }
    }

    func testDetachedRevisionAndMergeProposalDoNotAdvanceCanonicalBeforeApproval()
        throws
    {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "merge-gate",
            displayName: "Merge Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        try Data("proposed\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-gate",
            displayName: "Merge Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try Data("merged\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let merged = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-gate",
            displayName: "Merge Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        XCTAssertEqual(
            try store.loadRepository(id: "merge-gate").canonicalRevision,
            base.id
        )

        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("proposal"))",
            repositoryID: "merge-gate",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: merged.id,
            conflictArtifactIDs: [],
            createdAt: Date(timeIntervalSince1970: 4)
        )
        _ = try store.persistMergeProposal(proposal, conflicts: [])
        XCTAssertEqual(try store.loadMergeProposals(repositoryID: "merge-gate"), [proposal])
        XCTAssertEqual(
            try store.loadRepository(id: "merge-gate").canonicalRevision,
            base.id
        )

        let receipt = try store.approveMergeProposal(
            repositoryID: "merge-gate",
            proposalID: proposal.id,
            decidedBy: "primary-human",
            decidedAt: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(receipt.status, .approved)
        XCTAssertEqual(receipt.resolvedRevisionID, merged.id)
        XCTAssertEqual(
            try store.loadRepository(id: "merge-gate").canonicalRevision,
            merged.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "merge-gate").first?.status,
            .approved
        )
        let replay = try store.approveMergeProposal(
            repositoryID: "merge-gate",
            proposalID: proposal.id,
            decidedBy: "recovery-operator",
            decidedAt: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(replay, receipt)
        XCTAssertEqual(
            try store.loadRepository(id: "merge-gate").canonicalRevision,
            merged.id
        )
    }

    func testApprovalRecoversEveryRecordedDecisionWriteBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for (repositoryID, canonicalAlreadyAdvanced) in [
            ("decision-only", false),
            ("decision-and-canonical", true),
        ] {
            let setup = try makePendingCleanProposal(
                root: fixture.root,
                repositoryID: repositoryID
            )
            let recorded = TatwoMergeDecisionReceiptV1(
                id: "decision-\(setup.proposal.id)",
                repositoryID: repositoryID,
                proposalID: setup.proposal.id,
                status: .approved,
                decidedBy: "original-human",
                decidedAt: Date(timeIntervalSince1970: 5),
                resolvedRevisionID: setup.merged.id,
                message: "Human approved the Skillet merge proposal"
            )
            let decisionURL = setup.storeRoot.appendingPathComponent(
                "repositories/\(repositoryID)/merge-proposals/\(setup.proposal.id)/decision.json"
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recorded).write(to: decisionURL, options: [.atomic])

            if canonicalAlreadyAdvanced {
                let metadataURL = setup.storeRoot.appendingPathComponent(
                    "repositories/\(repositoryID)/repository.json"
                )
                var metadata = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL))
                        as? [String: Any]
                )
                metadata["canonicalRevision"] = setup.merged.id
                try JSONSerialization.data(
                    withJSONObject: metadata,
                    options: [.prettyPrinted, .sortedKeys]
                ).write(to: metadataURL, options: [.atomic])
            }

            let replay = try setup.store.approveMergeProposal(
                repositoryID: repositoryID,
                proposalID: setup.proposal.id,
                decidedBy: "recovery-operator",
                decidedAt: Date(timeIntervalSince1970: 99)
            )
            XCTAssertEqual(replay, recorded)
            XCTAssertEqual(
                try setup.store.loadRepository(id: repositoryID).canonicalRevision,
                setup.merged.id
            )
            XCTAssertEqual(
                try setup.store.loadMergeProposals(repositoryID: repositoryID)
                    .first?.status,
                .approved
            )
        }
    }

    func testConflictedProposalFailsClosedUntilResolvedOrRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "merge-conflict",
            displayName: "Merge Conflict",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable
        )
        try Data("proposed\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-conflict",
            displayName: "Merge Conflict",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id
        )
        let conflict = TatwoSkilletMergeConflictArtifactV1(
            id: "conflict-\(digest("conflict"))",
            repositoryID: "merge-conflict",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            relativePath: "SKILL.md",
            kind: .overlappingTextEdits,
            baseContentDigest: base.contentDigest,
            canonicalContentDigest: base.contentDigest,
            proposedContentDigest: proposed.contentDigest
        )
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("conflicted-proposal"))",
            repositoryID: "merge-conflict",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: nil,
            conflictArtifactIDs: [conflict.id]
        )
        try store.persistMergeProposal(proposal, conflicts: [conflict])

        XCTAssertThrowsError(
            try store.approveMergeProposal(
                repositoryID: "merge-conflict",
                proposalID: proposal.id,
                decidedBy: "primary-human"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .unresolvedMergeConflicts(proposal.id)
            )
        }
        XCTAssertEqual(
            try store.loadRepository(id: "merge-conflict").canonicalRevision,
            base.id
        )
        let receipt = try store.rejectMergeProposal(
            repositoryID: "merge-conflict",
            proposalID: proposal.id,
            decidedBy: "primary-human"
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertEqual(
            try store.loadRepository(id: "merge-conflict").canonicalRevision,
            base.id
        )
    }

    func testStaleProposalCanBeRejectedButNotApproved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "stale-gate",
            displayName: "Stale Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try Data("proposed\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: "stale-gate",
            displayName: "Stale Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try Data("merged\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let merged = try store.snapshotDetachedSkillDirectory(
            repositoryID: "stale-gate",
            displayName: "Stale Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("stale-proposal"))",
            repositoryID: "stale-gate",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: merged.id,
            conflictArtifactIDs: [],
            createdAt: Date(timeIntervalSince1970: 4)
        )
        try store.persistMergeProposal(proposal, conflicts: [])

        try Data("moved-head\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let advanced = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "stale-gate",
            displayName: "Stale Gate",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable,
            createdAt: Date(timeIntervalSince1970: 5)
        )
        XCTAssertEqual(
            try store.loadRepository(id: "stale-gate").canonicalRevision,
            advanced.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "stale-gate"),
            [proposal]
        )

        XCTAssertThrowsError(
            try store.approveMergeProposal(
                repositoryID: "stale-gate",
                proposalID: proposal.id,
                decidedBy: "primary-human"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .staleMergeProposal(proposal.id)
            )
        }
        XCTAssertEqual(
            try store.loadRepository(id: "stale-gate").canonicalRevision,
            advanced.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "stale-gate").first?.status,
            .pending
        )

        let receipt = try store.rejectMergeProposal(
            repositoryID: "stale-gate",
            proposalID: proposal.id,
            decidedBy: "primary-human",
            decidedAt: Date(timeIntervalSince1970: 6)
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertNil(receipt.resolvedRevisionID)
        XCTAssertEqual(
            receipt.stalenessReason?.contains("canonical head moved past proposal"),
            true
        )
        XCTAssertEqual(
            try store.loadRepository(id: "stale-gate").canonicalRevision,
            advanced.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "stale-gate").first?.status,
            .rejected
        )
        let replay = try store.rejectMergeProposal(
            repositoryID: "stale-gate",
            proposalID: proposal.id,
            decidedBy: "recovery-operator",
            decidedAt: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(replay, receipt)
    }

    func testCorruptedConflictArtifactsCanBeRejectedButNotApproved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let storeRoot = fixture.root.appendingPathComponent("store", isDirectory: true)
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "merge-corrupt",
            displayName: "Merge Corrupt",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable
        )
        try Data("proposed\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-corrupt",
            displayName: "Merge Corrupt",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id
        )
        let conflict = TatwoSkilletMergeConflictArtifactV1(
            id: "conflict-\(digest("corrupt-artifact"))",
            repositoryID: "merge-corrupt",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            relativePath: "SKILL.md",
            kind: .overlappingTextEdits,
            baseContentDigest: base.contentDigest,
            canonicalContentDigest: base.contentDigest,
            proposedContentDigest: proposed.contentDigest
        )
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("corrupt-proposal"))",
            repositoryID: "merge-corrupt",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: nil,
            conflictArtifactIDs: [conflict.id]
        )
        try store.persistMergeProposal(proposal, conflicts: [conflict])

        let liveDirectory = storeRoot.appendingPathComponent(
            "repositories/merge-corrupt/merge-proposals/\(proposal.id)",
            isDirectory: true
        )
        let conflictURL = liveDirectory
            .appendingPathComponent("conflicts", isDirectory: true)
            .appendingPathComponent("\(conflict.id).json")
        try Data("{not-valid-conflict-json".utf8).write(to: conflictURL)
        try Data("orphan-remnant\n".utf8).write(
            to: liveDirectory
                .appendingPathComponent("conflicts", isDirectory: true)
                .appendingPathComponent("orphan.txt")
        )

        XCTAssertThrowsError(
            try store.approveMergeProposal(
                repositoryID: "merge-corrupt",
                proposalID: proposal.id,
                decidedBy: "primary-human"
            )
        ) { error in
            if error is DecodingError { return }
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedMergeProposal(proposal.id)
            )
        }
        XCTAssertEqual(
            try store.loadRepository(id: "merge-corrupt").canonicalRevision,
            base.id
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: liveDirectory.path)
        )

        let receipt = try store.rejectMergeProposal(
            repositoryID: "merge-corrupt",
            proposalID: proposal.id,
            decidedBy: "primary-human",
            decidedAt: Date(timeIntervalSince1970: 9)
        )
        XCTAssertEqual(receipt.status, .rejected)
        XCTAssertNil(receipt.resolvedRevisionID)
        XCTAssertEqual(receipt.corruptionReason?.isEmpty, false)
        XCTAssertEqual(
            try store.loadRepository(id: "merge-corrupt").canonicalRevision,
            base.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "merge-corrupt"),
            []
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: liveDirectory.path)
        )
        let archivedOriginal = storeRoot.appendingPathComponent(
            "repositories/merge-corrupt/rejected-merge-proposals/\(proposal.id)/original",
            isDirectory: true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archivedOriginal
                    .appendingPathComponent("proposal.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archivedOriginal
                    .appendingPathComponent("conflicts/\(conflict.id).json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: archivedOriginal
                    .appendingPathComponent("conflicts/orphan.txt").path
            )
        )
        let replay = try store.rejectMergeProposal(
            repositoryID: "merge-corrupt",
            proposalID: proposal.id,
            decidedBy: "recovery-operator",
            decidedAt: Date(timeIntervalSince1970: 99)
        )
        XCTAssertEqual(replay, receipt)
    }

    func testApprovalRejectsResolvedRevisionOutsideCanonicalAncestry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let source = fixture.root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = TatwoSkilletRepositoryStore(
            rootURL: fixture.root.appendingPathComponent("store", isDirectory: true)
        )
        try Data("base\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: "merge-ancestry",
            displayName: "Merge Ancestry",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .stable
        )
        try Data("proposed\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-ancestry",
            displayName: "Merge Ancestry",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id
        )
        try Data("merged\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let merged = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-ancestry",
            displayName: "Merge Ancestry",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: proposed.id
        )
        try Data("unrelated\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let unrelated = try store.snapshotDetachedSkillDirectory(
            repositoryID: "merge-ancestry",
            displayName: "Merge Ancestry",
            summary: "Fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: nil
        )
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("ancestry-proposal"))",
            repositoryID: "merge-ancestry",
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: merged.id,
            conflictArtifactIDs: [],
            createdAt: Date(timeIntervalSince1970: 10)
        )
        try store.persistMergeProposal(proposal, conflicts: [])

        XCTAssertThrowsError(
            try store.approveMergeProposal(
                repositoryID: "merge-ancestry",
                proposalID: proposal.id,
                resolvedRevisionID: unrelated.id,
                decidedBy: "primary-human"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoSkilletRepositoryStoreError,
                .corruptedMergeProposal(proposal.id)
            )
        }
        XCTAssertEqual(
            try store.loadRepository(id: "merge-ancestry").canonicalRevision,
            base.id
        )
        XCTAssertEqual(
            try store.loadMergeProposals(repositoryID: "merge-ancestry").first?.status,
            .pending
        )
    }

    private func makeFixture() throws -> (root: URL, id: String) {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-skillet-tests-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, id)
    }

    private func makePendingCleanProposal(
        root: URL,
        repositoryID: String
    ) throws -> (
        store: TatwoSkilletRepositoryStore,
        storeRoot: URL,
        proposal: TatwoMergeProposalV1,
        merged: TatwoSkillRevisionV1
    ) {
        let source = root.appendingPathComponent(
            "\(repositoryID)-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let storeRoot = root.appendingPathComponent(
            "\(repositoryID)-store",
            isDirectory: true
        )
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        try Data("base\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        let base = try store.snapshotCanonicalSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "Replay fixture",
            sourceDirectory: source,
            channel: .stable,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        try Data("proposed\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        let proposed = try store.snapshotDetachedSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "Replay fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 2)
        )
        try Data("merged\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        let merged = try store.snapshotDetachedSkillDirectory(
            repositoryID: repositoryID,
            displayName: repositoryID,
            summary: "Replay fixture",
            sourceDirectory: source,
            channel: .staging,
            parentRevisionID: base.id,
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let proposal = TatwoMergeProposalV1(
            id: "merge-\(digest("\(repositoryID)-proposal"))",
            repositoryID: repositoryID,
            sourceDeviceID: "macbook",
            baseRevisionID: base.id,
            canonicalRevisionID: base.id,
            proposedRevisionID: proposed.id,
            mergedRevisionID: merged.id,
            conflictArtifactIDs: [],
            createdAt: Date(timeIntervalSince1970: 4)
        )
        try store.persistMergeProposal(proposal, conflicts: [])
        return (store, storeRoot, proposal, merged)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
