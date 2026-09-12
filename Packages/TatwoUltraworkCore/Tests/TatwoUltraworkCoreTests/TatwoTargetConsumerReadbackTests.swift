import CryptoKit
import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoTargetConsumerReadbackTests: XCTestCase {
    func testWorkOSConsumerRejectsDocumentItCannotActuallyLoad() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let documents: [(id: String, path: String, data: Data)] = [
            ("os.constitution", "os/os.md", Data("# OS\n".utf8)),
            ("os.issue", "os/issue.md", Data([0x23, 0x20, 0x49, 0x00, 0x73, 0x73, 0x75, 0x65])),
            ("os.todo", "os/TODO.md", Data("# TODO\n".utf8)),
        ]
        let manifest = try writeFixture(
            root: fixture,
            documents: documents,
            repositories: []
        )

        XCTAssertThrowsError(
            try TatwoTargetConsumerReadbackProbe.probe(
                manifestURL: manifest.manifestURL,
                mirrorRootURL: manifest.mirrorRoot,
                skilletSetManifestURL: manifest.setManifestURL,
                skilletActivationReceiptURL: manifest.activationReceiptURL,
                storeURL: fixture.appendingPathComponent("store", isDirectory: true),
                runtimeRootURL: fixture.appendingPathComponent("runtime", isDirectory: true),
                consumerRootURL: fixture.appendingPathComponent("consumer", isDirectory: true),
                codexSkillsLinkURL: fixture.appendingPathComponent("codex-skills"),
                claudeSkillsLinkURL: fixture.appendingPathComponent("claude-skills"),
                requestID: "request-consumer-load",
                target: "mini",
                sourceDeviceID: "book-device",
                targetDeviceID: "mini-device",
                authorityPrimary: "book",
                authorityEpoch: 2,
                ledgerSequence: 3,
                catalogRevision: "2026-07-25.1"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoTargetConsumerReadbackError,
                .consumerLoadFailed("work-os.bootstrap:os.issue")
            )
        }
    }

    func testEmptySkilletSetCannotProducePassingConsumerReadback() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let documents: [(id: String, path: String, data: Data)] = [
            ("os.constitution", "os/os.md", Data("# OS\n".utf8)),
            ("os.issue", "os/issue.md", Data("# Issue\n".utf8)),
            ("os.todo", "os/TODO.md", Data("# TODO\n".utf8)),
        ]
        let manifest = try writeFixture(
            root: fixture,
            documents: documents,
            repositories: []
        )

        XCTAssertThrowsError(
            try TatwoTargetConsumerReadbackProbe.probe(
                manifestURL: manifest.manifestURL,
                mirrorRootURL: manifest.mirrorRoot,
                skilletSetManifestURL: manifest.setManifestURL,
                skilletActivationReceiptURL: manifest.activationReceiptURL,
                storeURL: fixture.appendingPathComponent("store", isDirectory: true),
                runtimeRootURL: fixture.appendingPathComponent("runtime", isDirectory: true),
                consumerRootURL: fixture.appendingPathComponent("consumer", isDirectory: true),
                codexSkillsLinkURL: fixture.appendingPathComponent("codex-skills"),
                claudeSkillsLinkURL: fixture.appendingPathComponent("claude-skills"),
                requestID: "request-empty-skillet",
                target: "mini",
                sourceDeviceID: "book-device",
                targetDeviceID: "mini-device",
                authorityPrimary: "book",
                authorityEpoch: 2,
                ledgerSequence: 3,
                catalogRevision: "2026-07-25.1"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoTargetConsumerReadbackError,
                .consumerCoverageMismatch("skillet.runtime-loader")
            )
        }
    }

    func testWorkOSTodoRejectsLowercaseMirrorPathDrift() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        // Intentionally wrong basename case; expectedPath is os/TODO.md.
        let documents: [(id: String, path: String, data: Data)] = [
            ("os.constitution", "os/os.md", Data("# OS\n".utf8)),
            ("os.issue", "os/issue.md", Data("# Issue\n".utf8)),
            ("os.todo", "os/todo.md", Data("# TODO\n".utf8)),
        ]
        let manifest = try writeFixture(
            root: fixture,
            documents: documents,
            repositories: [
                [
                    "repositoryID": "alpha",
                    "revisionID": "rev-placeholder",
                    "contentDigest": String(repeating: "a", count: 64),
                    "bundleDigest": String(repeating: "b", count: 64),
                    "bundleRelativePath": "repositories/alpha/bundle",
                    "bindingRelativePath": "repositories/alpha/authority-binding.json",
                ],
            ]
        )

        XCTAssertThrowsError(
            try TatwoTargetConsumerReadbackProbe.probe(
                manifestURL: manifest.manifestURL,
                mirrorRootURL: manifest.mirrorRoot,
                skilletSetManifestURL: manifest.setManifestURL,
                skilletActivationReceiptURL: manifest.activationReceiptURL,
                storeURL: fixture.appendingPathComponent("store", isDirectory: true),
                runtimeRootURL: fixture.appendingPathComponent("runtime", isDirectory: true),
                consumerRootURL: fixture.appendingPathComponent("consumer", isDirectory: true),
                codexSkillsLinkURL: fixture.appendingPathComponent("codex-skills"),
                claudeSkillsLinkURL: fixture.appendingPathComponent("claude-skills"),
                requestID: "request-consumer",
                target: "mini",
                sourceDeviceID: "book-device",
                targetDeviceID: "mini-device",
                authorityPrimary: "book",
                authorityEpoch: 2,
                ledgerSequence: 3,
                catalogRevision: "2026-07-25.1"
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoTargetConsumerReadbackError,
                .consumerLoadFailed("work-os.bootstrap:os.todo")
            )
        }
    }

    func testNativeSkillConsumersReadEveryRepositoryThroughManagedLinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtime = fixture.appendingPathComponent("runtime", isDirectory: true)
        let repository = runtime.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try Data("# alpha\n".utf8).write(
            to: repository.appendingPathComponent("SKILL.md")
        )
        try Data("portable\n".utf8).write(
            to: repository.appendingPathComponent("café.md")
        )
        let runtimeReadback = try TatwoSkilletBundleTransport.readRuntimeRepository(
            runtimeRoot: runtime,
            repositoryID: "alpha"
        )
        let digest = try XCTUnwrap(runtimeReadback.contentDigest)
        let consumer = fixture.appendingPathComponent("consumer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: consumer,
            withIntermediateDirectories: true
        )
        let current = consumer.appendingPathComponent("current")
        let codex = fixture.appendingPathComponent("codex-skills")
        let claude = fixture.appendingPathComponent("claude-skills")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: runtime)
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: current)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: current)

        let readbacks = try TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers(
            runtimeRootURL: runtime,
            consumerRootURL: consumer,
            codexSkillsLinkURL: codex,
            claudeSkillsLinkURL: claude,
            repositories: [
                .init(
                    repositoryID: "alpha",
                    revisionID: "rev-\(digest)",
                    contentDigest: digest
                )
            ],
            requestID: "request-native-consumers",
            targetDeviceID: "mini-device",
            authorityPrimary: "book",
            authorityEpoch: 2,
            ledgerSequence: 3,
            catalogRevision: "2026-07-25.1",
            observedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            readbacks.map(\.consumerID),
            ["codex.native-skills", "claude.native-skills"]
        )
        XCTAssertTrue(readbacks.allSatisfy {
            $0.sourceItemID == "skills.skillet"
                && $0.expectedDigest == digest
                && $0.loadedDigest == digest
                && $0.loadedRevision == "rev-\(digest)"
        })
    }

    func testNativeSkillConsumerRejectsLinkThatBypassesManagedCurrent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtime = fixture.appendingPathComponent("runtime", isDirectory: true)
        let repository = runtime.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try Data("# alpha\n".utf8).write(
            to: repository.appendingPathComponent("SKILL.md")
        )
        let runtimeReadback = try TatwoSkilletBundleTransport.readRuntimeRepository(
            runtimeRoot: runtime,
            repositoryID: "alpha"
        )
        let digest = try XCTUnwrap(runtimeReadback.contentDigest)
        let consumer = fixture.appendingPathComponent("consumer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: consumer,
            withIntermediateDirectories: true
        )
        let current = consumer.appendingPathComponent("current")
        let codex = fixture.appendingPathComponent("codex-skills")
        let claude = fixture.appendingPathComponent("claude-skills")
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: runtime)
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: runtime)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: current)

        XCTAssertThrowsError(
            try TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers(
                runtimeRootURL: runtime,
                consumerRootURL: consumer,
                codexSkillsLinkURL: codex,
                claudeSkillsLinkURL: claude,
                repositories: [
                    .init(
                        repositoryID: "alpha",
                        revisionID: "rev-\(digest)",
                        contentDigest: digest
                    )
                ],
                requestID: "request-native-drift",
                targetDeviceID: "mini-device",
                authorityPrimary: "book",
                authorityEpoch: 2,
                ledgerSequence: 3,
                catalogRevision: "2026-07-25.1",
                observedAt: Date(timeIntervalSince1970: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoTargetConsumerReadbackError,
                .consumerLoadFailed("codex.native-skills:managed-link")
            )
        }
    }

    func testNativeSkillConsumersAcceptRuntimeRootWithSymlinkedAncestor() throws {
        let fixture = try makeFixture()
        let alias = fixture.deletingLastPathComponent().appendingPathComponent(
            "\(fixture.lastPathComponent)-alias",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: fixture)
        }
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture
        )

        let physicalRuntime = fixture.appendingPathComponent("runtime", isDirectory: true)
        let runtimeThroughAlias = alias.appendingPathComponent("runtime", isDirectory: true)
        let repository = physicalRuntime.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try Data("# alpha\n".utf8).write(
            to: repository.appendingPathComponent("SKILL.md")
        )
        let runtimeReadback = try TatwoSkilletBundleTransport.readRuntimeRepository(
            runtimeRoot: physicalRuntime,
            repositoryID: "alpha"
        )
        let digest = try XCTUnwrap(runtimeReadback.contentDigest)

        let consumer = fixture.appendingPathComponent("consumer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: consumer,
            withIntermediateDirectories: true
        )
        let current = consumer.appendingPathComponent("current")
        let codex = fixture.appendingPathComponent("codex-skills")
        let claude = fixture.appendingPathComponent("claude-skills")
        try FileManager.default.createSymbolicLink(
            at: current,
            withDestinationURL: runtimeThroughAlias
        )
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: current)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: current)

        let readbacks = try TatwoTargetConsumerReadbackProbe.probeNativeSkillsConsumers(
            runtimeRootURL: runtimeThroughAlias,
            consumerRootURL: consumer,
            codexSkillsLinkURL: codex,
            claudeSkillsLinkURL: claude,
            repositories: [
                .init(
                    repositoryID: "alpha",
                    revisionID: "rev-\(digest)",
                    contentDigest: digest
                )
            ],
            requestID: "request-symlinked-runtime",
            targetDeviceID: "mini-device",
            authorityPrimary: "book",
            authorityEpoch: 2,
            ledgerSequence: 3,
            catalogRevision: "2026-07-25.1",
            observedAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            readbacks.map(\.consumerID),
            ["codex.native-skills", "claude.native-skills"]
        )
        XCTAssertTrue(readbacks.allSatisfy {
            $0.loadedDigest == digest
                && $0.loadedRevision == "rev-\(digest)"
        })
    }

    private func writeFixture(
        root: URL,
        documents: [(id: String, path: String, data: Data)],
        repositories: [[String: Any]]
    ) throws -> (
        manifestURL: URL,
        mirrorRoot: URL,
        setManifestURL: URL,
        activationReceiptURL: URL
    ) {
        let requestID = repositories.isEmpty
            ? (documents[1].data.contains(0) ? "request-consumer-load" : "request-empty-skillet")
            : "request-consumer"
        let mirrorRoot = root.appendingPathComponent("mirror", isDirectory: true)
        for document in documents {
            let url = mirrorRoot.appendingPathComponent(document.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try document.data.write(to: url)
        }
        let setManifestURL = root.appendingPathComponent("set.json")
        let setObject: [String: Any] = [
            "schemaVersion": 1,
            "requestID": requestID,
            "catalogRevision": "2026-07-25.1",
            "authorityEpoch": 2,
            "ledgerSequence": 3,
            "sourceDeviceID": "book-device",
            "targetDeviceID": "mini-device",
            "repositories": repositories,
        ]
        let setData = try JSONSerialization.data(
            withJSONObject: setObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try setData.write(to: setManifestURL)
        var items = documents.map { document -> [String: Any] in
            [
                "id": document.id,
                "mirrorRelativePath": document.path,
                "sourceDigest": digest(document.data),
                "byteCount": document.data.count,
            ]
        }
        items.append([
            "id": "skills.skillet",
            "mirrorRelativePath": "skillet/repositories",
            "sourceDigest": digest(setData),
            "byteCount": setData.count,
            "repositoryCount": repositories.count,
        ])
        let manifestObject: [String: Any] = [
            "schemaVersion": 1,
            "requestID": requestID,
            "catalogRevision": "2026-07-25.1",
            "authorityEpoch": 2,
            "ledgerSequence": 3,
            "authorityPrimary": "book",
            "sourceDeviceID": "book-device",
            "targetDeviceID": "mini-device",
            "items": items,
        ]
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL)
        return (
            manifestURL,
            mirrorRoot,
            setManifestURL,
            root.appendingPathComponent("activation-receipt.json")
        )
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-target-consumer-readback-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
