import CryptoKit
import Foundation
import TatwoDomainContracts
import TatwoUltraworkCore
import TatwoWorkReceiptContracts
import XCTest
@testable import TatwoUltraworkMac

final class ChatProductionRemoteTurnDispatcherTests: XCTestCase {
    func testLocalInternalTrustBindsAnchorToReceiptDeviceAndCanonicalRoots()
        throws
    {
        let fixture = try makeLocalInternalInstallFixture(
            "receipt-device-roots")

        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: {
                    try fixture.localAnchorStore.load()
                }),
            .trusted)
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { nil }),
            .rejected)
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: {
                    throw TatwoProductionLayoutError
                        .localInternalInstallAnchorRejected("fixture")
                }),
            .unknown)

        let anchor = try XCTUnwrap(fixture.localAnchorStore.load())
        let mismatchedAnchor = TatwoLocalInternalInstallAnchorV1(
            candidateID: anchor.candidateID,
            receiptID: anchor.receiptID,
            receiptFilename: anchor.receiptFilename,
            receiptSHA256: anchor.receiptSHA256,
            pointerSHA256: anchor.pointerSHA256,
            canonicalAppPath: anchor.canonicalAppPath,
            canonicalStateRoot: fixture.base.appendingPathComponent(
                "wrong-state",
                isDirectory: true).path,
            deviceID: anchor.deviceID,
            installGeneration: anchor.installGeneration,
            previousAnchorSHA256: anchor.previousAnchorSHA256,
            createdAt: anchor.createdAt)
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { mismatchedAnchor }),
            .rejected)

        let deviceIdentityURL =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: fixture.base)
            .appendingPathComponent("device-identity.json")
        try writeSentinel(
            Data(#"{"deviceId":"different-device"}"#.utf8),
            to: deviceIdentityURL)
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { anchor }),
            .rejected)
    }

    func testLocalInternalTrustPinsDeveloperIDReceiptTeam() throws {
        let fixture = try makeLocalInternalInstallFixture(
            "developer-id-team")
        let expectedIdentity =
            "Developer ID Application: TATWO (W47594XKQC)"
        try writeLocalInternalReceipt(
            fixture,
            signing: "developer-id \(expectedIdentity)",
            signingMode: "developer-id",
            signingIdentity: expectedIdentity,
            distribution: "local-internal-developer-id")

        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
            .trusted)

        let foreignIdentity =
            "Developer ID Application: Foreign (FOREIGN123)"
        try writeLocalInternalReceipt(
            fixture,
            signing: "developer-id \(foreignIdentity)",
            signingMode: "developer-id",
            signingIdentity: foreignIdentity,
            distribution: "local-internal-developer-id")
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
            .rejected)
    }

    func testLocalInternalTrustRejectsReceiptSourceMismatch() throws {
        let fixture = try makeLocalInternalInstallFixture(
            "receipt-source")
        try writeLocalInternalReceipt(
            fixture,
            signing: "ad-hoc",
            signingMode: "ad-hoc",
            signingIdentity: "-",
            distribution: "local-internal-ad-hoc",
            sourceTree: String(repeating: "0", count: 40))

        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
            .rejected)
    }

    func testLocalInternalTrustRejectsMissingSymlinkedOrMismatchedHelper()
        throws
    {
        func assertRejected(
            _ suffix: String,
            mutate: (LocalInternalInstallFixture) throws -> Void
        ) throws {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try mutate(fixture)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }

        try assertRejected("helper-missing") { fixture in
            try FileManager.default.removeItem(at: fixture.helperURL)
        }
        try assertRejected("helper-symlink") { fixture in
            try FileManager.default.removeItem(at: fixture.helperURL)
            let externalHelper = fixture.base.appendingPathComponent(
                "outside-helper",
                isDirectory: false)
            try writeSentinel(
                Data("trusted-production-helper".utf8),
                to: externalHelper)
            try FileManager.default.createSymbolicLink(
                at: fixture.helperURL,
                withDestinationURL: externalHelper)
        }
        try assertRejected("helper-digest") { fixture in
            try writeSentinel(
                Data("tampered-helper".utf8),
                to: fixture.helperURL)
        }
    }

    func testLocalInternalTrustRejectsMainNestedAndResourceMutationAfterSimulatedResign()
        throws
    {
        func assertRejected(
            _ suffix: String,
            mutate: (LocalInternalInstallFixture) throws -> Void
        ) throws {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try mutate(fixture)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                "\(suffix): currentAdHoc simulates a self-consistent re-sign")
        }

        try assertRejected("main-executable-mutated") { fixture in
            try writeSentinel(
                Data("tampered-main-executable".utf8),
                to: fixture.mainExecutableURL)
        }
        try assertRejected("nested-code-mutated") { fixture in
            try writeSentinel(
                Data("tampered-nested-code".utf8),
                to: fixture.nestedCodeURL)
        }
        try assertRejected("resource-mutated") { fixture in
            try writeSentinel(
                Data("tampered-resource".utf8),
                to: fixture.resourceURL)
        }
    }

    func testLocalInternalTrustRejectsMissingMalformedDriftedOrIncompleteBundleManifest()
        throws
    {
        func assertRejected(
            _ suffix: String,
            mutate: (LocalInternalInstallFixture) throws -> Void
        ) throws {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try mutate(fixture)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }

        try assertRejected("content-manifest-missing") { fixture in
            try FileManager.default.removeItem(
                at: fixture.bundleContentManifestURL)
        }
        try assertRejected("content-manifest-malformed") { fixture in
            try writeSentinel(
                Data("{".utf8),
                to: fixture.bundleContentManifestURL)
        }
        try assertRejected("content-manifest-digest-drift") { fixture in
            var data = try Data(contentsOf: fixture.bundleContentManifestURL)
            data.append(0x20)
            try writeSentinel(
                data,
                to: fixture.bundleContentManifestURL)
        }
        try assertRejected("content-manifest-unlisted-extra") { fixture in
            try writeSentinel(
                Data("unlisted".utf8),
                to: fixture.bundle.appendingPathComponent(
                    "Contents/Resources/unlisted.txt",
                    isDirectory: false))
        }
    }

    func testLocalInternalTrustRejectsMissingMalformedOrMismatchedBundlePins()
        throws
    {
        let cases: [
            (
                String,
                (LocalInternalInstallFixture) throws -> [String: Any]
            )
        ] = [
            ("manifest-pin-missing", { fixture in
                var info = fixture.infoDictionary
                info.removeValue(
                    forKey:
                        TatwoChatProcessCompositionResolver
                            .bundleContentManifestDigestInfoKey)
                return info
            }),
            ("main-pin-malformed", { fixture in
                var info = fixture.infoDictionary
                info[
                    TatwoChatProcessCompositionResolver
                        .mainExecutableDigestInfoKey
                ] = "not-a-sha256"
                return info
            }),
            ("main-pin-mismatch", { fixture in
                var info = fixture.infoDictionary
                info[
                    TatwoChatProcessCompositionResolver
                        .mainExecutableDigestInfoKey
                ] = String(repeating: "0", count: 64)
                return info
            }),
        ]

        for (suffix, makeInfo) in cases {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    infoDictionary: try makeInfo(fixture),
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }

        let receiptPinCases: [(String, String?, String?)] = [
            (
                "receipt-manifest-pin-mismatch",
                String(repeating: "0", count: 64),
                nil
            ),
            (
                "receipt-main-pin-mismatch",
                nil,
                String(repeating: "0", count: 64)
            ),
        ]
        for (suffix, manifestDigest, executableDigest) in receiptPinCases {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                bundleContentManifestDigest: manifestDigest,
                mainExecutableDigest: executableDigest)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }
    }

    func testLocalInternalTrustRejectsCandidateAndEmbeddedProvenanceDrift()
        throws
    {
        let candidateFixture = try makeLocalInternalInstallFixture(
            "candidate-id-drift")
        var candidateInfo = candidateFixture.infoDictionary
        candidateInfo[
            TatwoChatProcessCompositionResolver.candidateIDInfoKey
        ] = String(repeating: "0", count: 64)
        XCTAssertEqual(
            localInternalTrust(
                candidateFixture,
                infoDictionary: candidateInfo,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try candidateFixture.localAnchorStore.load() }),
            .rejected)

        let embeddedFixture = try makeLocalInternalInstallFixture(
            "embedded-provenance-bytes")
        try writeSentinel(
            Data("{\"tampered\":true}\n".utf8),
            to: embeddedFixture.embeddedProvenanceURL)
        XCTAssertEqual(
            localInternalTrust(
                embeddedFixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try embeddedFixture.localAnchorStore.load() }),
            .rejected)

        let receiptFixture = try makeLocalInternalInstallFixture(
            "receipt-embedded-pin")
        try writeLocalInternalReceipt(
            receiptFixture,
            signing: "ad-hoc",
            signingMode: "ad-hoc",
            signingIdentity: "-",
            distribution: "local-internal-ad-hoc",
            embeddedProvenanceDigest:
                String(repeating: "0", count: 64))
        XCTAssertEqual(
            localInternalTrust(
                receiptFixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try receiptFixture.localAnchorStore.load() }),
            .rejected)
    }

    func testLocalInternalTrustTreatsV3AndLegacyV2StageDigestsAsForensic()
        throws
    {
        for schema in [
            "TatwoLocalAppInstallReceiptV3",
            "TatwoLocalAppInstallReceiptV2",
        ] {
            let fixture = try makeLocalInternalInstallFixture(
                "forensic-\(schema)")
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                schema: schema,
                forensicStagedBundleManifestDigest:
                    String(repeating: "0", count: 64),
                forensicStagedBundleIdentityDigest:
                    String(repeating: "f", count: 64))
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .trusted,
                "\(schema) forensic digests are not launch authority")

            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                schema: schema,
                bundleContentManifestDigest:
                    String(repeating: "0", count: 64),
                forensicStagedBundleManifestDigest:
                    String(repeating: "0", count: 64),
                forensicStagedBundleIdentityDigest:
                    String(repeating: "f", count: 64))
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                "\(schema) true bundle-content authority must stay bound")
        }
    }

    func testLocalInternalTrustRejectsV2V3ForensicFieldNameMix()
        throws
    {
        for (schema, fieldSchema) in [
            (
                "TatwoLocalAppInstallReceiptV3",
                "TatwoLocalAppInstallReceiptV2"
            ),
            (
                "TatwoLocalAppInstallReceiptV2",
                "TatwoLocalAppInstallReceiptV3"
            ),
        ] {
            let fixture = try makeLocalInternalInstallFixture(
                "forensic-field-mix-\(schema)")
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                schema: schema,
                forensicFieldSchema: fieldSchema)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                "\(schema) must use its exact forensic field names")
        }
    }

    func testLocalInternalTrustIgnoresNestedCodeSignatureArtifactsOnly()
        throws
    {
        let fixture = try makeLocalInternalInstallFixture(
            "nested-code-signature-exclusion")
        try writeSentinel(
            Data("regenerated-signature-artifact".utf8),
            to: fixture.bundle.appendingPathComponent(
                "Contents/Frameworks/Nested.framework/_CodeSignature/CodeResources",
                isDirectory: false))

        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
            .trusted)
    }

    func testLocalInternalTrustRejectsReceiptFieldAndMalformedTimestamp()
        throws
    {
        func assertRejected(
            _ suffix: String,
            rewrite: (LocalInternalInstallFixture) throws -> Void
        ) throws {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try rewrite(fixture)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }

        try assertRejected("receipt-schema") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                schema: "TatwoLocalAppInstallReceiptV0")
        }
        try assertRejected("receipt-dry-run") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                dryRun: "1")
        }
        try assertRejected("receipt-version") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                appVersion: "0.1.11")
        }
        try assertRejected("receipt-build") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                appBuild: "25")
        }
        try assertRejected("receipt-source-commit") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                sourceCommit: String(repeating: "0", count: 40))
        }
        try assertRejected("receipt-source-tree") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                sourceTree: String(repeating: "0", count: 40))
        }
        try assertRejected("receipt-timestamp") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                generatedAt: "not-an-iso8601-date")
        }
    }

    func testLocalInternalTrustRequiresExactPointerBoundReceipt() throws {
        func assertRejected(
            _ suffix: String,
            mutate: (LocalInternalInstallFixture) throws -> Void
        ) throws {
            let fixture = try makeLocalInternalInstallFixture(suffix)
            try mutate(fixture)
            XCTAssertEqual(
                localInternalTrust(
                    fixture,
                    expectedSignatureTrust: .currentAdHoc,
                    localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
                .rejected,
                suffix)
        }

        func writePointer(
            _ fixture: LocalInternalInstallFixture,
            receiptID: String? = nil,
            receiptFilename: String? = nil,
            receiptDigest: String? = nil,
            candidateID: String? = nil,
            extraLine: String = ""
        ) throws {
            let data = try Data(contentsOf: fixture.receiptURL)
            try writeSentinel(
                Data(
                    """
                    schema=TatwoLocalAppInstallReceiptPointerV1
                    receipt_id=\(receiptID ?? fixture.receiptID)
                    receipt_filename=\(receiptFilename ?? fixture.receiptFilename)
                    receipt_sha256=\(receiptDigest ?? sha256Hex(data))
                    candidate_id=\(candidateID ?? fixture.candidateID)
                    \(extraLine)

                    """.utf8),
                to: fixture.receiptPointerURL)
        }

        try assertRejected("pointer-missing") { fixture in
            try FileManager.default.removeItem(
                at: fixture.receiptPointerURL)
        }
        try assertRejected("pointer-extra-field") { fixture in
            try writePointer(fixture, extraLine: "unexpected=value")
        }
        try assertRejected("pointer-path-escape") { fixture in
            try writePointer(
                fixture,
                receiptFilename: "../\(fixture.receiptFilename)")
        }
        try assertRejected("pointer-digest-drift") { fixture in
            try writePointer(
                fixture,
                receiptDigest: String(repeating: "0", count: 64))
        }
        try assertRejected("exact-receipt-missing") { fixture in
            try FileManager.default.removeItem(at: fixture.receiptURL)
        }
        try assertRejected("exact-receipt-symlink") { fixture in
            let data = try Data(contentsOf: fixture.receiptURL)
            try FileManager.default.removeItem(at: fixture.receiptURL)
            let external = fixture.base.appendingPathComponent(
                "outside-install-receipt.txt",
                isDirectory: false)
            try writeSentinel(data, to: external)
            try FileManager.default.createSymbolicLink(
                at: fixture.receiptURL,
                withDestinationURL: external)
        }
        try assertRejected("receipt-nonce-binding") { fixture in
            try writeLocalInternalReceipt(
                fixture,
                signing: "ad-hoc",
                signingMode: "ad-hoc",
                signingIdentity: "-",
                distribution: "local-internal-ad-hoc",
                receiptNonce: String(repeating: "b", count: 64))
        }

        let fixture = try makeLocalInternalInstallFixture(
            "unrelated-receipt-is-ignored")
        try writeSentinel(
            Data("unrelated".utf8),
            to: fixture.receiptURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "local-app-install-unrelated.txt",
                    isDirectory: false))
        XCTAssertEqual(
            localInternalTrust(
                fixture,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: { try fixture.localAnchorStore.load() }),
            .trusted)
    }

    func testSealedChannelFailsClosedWhenManifestIsMissing() throws {
        let root = temporaryDirectory("missing")
        let channel = ChatProductionRemoteDispatchManifestChannel(
            channelRootURL: root)

        XCTAssertThrowsError(
            try channel.load(
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5",
                now: Date())
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .manifestMissing)
        }
    }

    func testManifestURLUsesSealedChannelReadinessLayout() throws {
        let root = temporaryDirectory("layout")
        let url =
            try ChatProductionRemoteDispatchManifestChannel.manifestURL(
                channelRootURL: root,
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5")
        let digest = TatwoLoopJobDigest.sha256(Data("gpt-5.5".utf8))
            .replacingOccurrences(of: "sha256:", with: "")

        XCTAssertEqual(
            url.standardizedFileURL.path,
            root.standardizedFileURL
                .appendingPathComponent("readiness", isDirectory: true)
                .appendingPathComponent("manifests", isDirectory: true)
                .appendingPathComponent("target-device", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
                .appendingPathComponent("route-\(digest).json")
                .path)
        XCTAssertFalse(url.path.contains("remote-dispatch-readiness"))
        XCTAssertFalse(url.path.contains("/inbox/"))
    }

    func testSealedChannelRejectsStaleManifest() throws {
        let root = temporaryDirectory("stale")
        let now = Date(timeIntervalSince1970: 10_000)
        try writeManifest(
            makeManifest(
                issuedAt: now.addingTimeInterval(-900),
                expiresAt: now.addingTimeInterval(-1)),
            channelRoot: root,
            targetDeviceID: "target-device",
            agent: .codex,
            exactModelRouteID: "gpt-5.5")

        XCTAssertThrowsError(
            try ChatProductionRemoteDispatchManifestChannel(
                channelRootURL: root
            ).load(
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5",
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .manifestStale)
        }
    }

    func testSealedChannelRejectsSymlinkedManifest() throws {
        let root = temporaryDirectory("symlink")
        let now = Date(timeIntervalSince1970: 15_000)
        let expectedURL =
            try ChatProductionRemoteDispatchManifestChannel.manifestURL(
                channelRootURL: root,
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5")
        try FileManager.default.createDirectory(
            at: expectedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let realURL = root.appendingPathComponent("outside-manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300))
        ).write(to: realURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: expectedURL,
            withDestinationURL: realURL)

        XCTAssertThrowsError(
            try ChatProductionRemoteDispatchManifestChannel(
                channelRootURL: root
            ).load(
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5",
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .manifestNotRegularFile)
        }
    }

    func testSealedChannelRejectsEmptyOversizedAndMalformedManifest()
        throws
    {
        func assertRejected(
            _ suffix: String,
            data: Data,
            expected: ChatProductionRemoteTurnDispatcherError
        ) throws {
            let root = temporaryDirectory("manifest-\(suffix)")
            let url =
                try ChatProductionRemoteDispatchManifestChannel.manifestURL(
                    channelRootURL: root,
                    targetDeviceID: "target-device",
                    agent: .codex,
                    exactModelRouteID: "gpt-5.5")
            try writeSentinel(data, to: url)
            XCTAssertThrowsError(
                try ChatProductionRemoteDispatchManifestChannel(
                    channelRootURL: root
                ).load(
                    targetDeviceID: "target-device",
                    agent: .codex,
                    exactModelRouteID: "gpt-5.5",
                    now: Date(timeIntervalSince1970: 16_000))
            ) { error in
                XCTAssertEqual(
                    error as? ChatProductionRemoteTurnDispatcherError,
                    expected,
                    suffix)
            }
        }

        try assertRejected(
            "empty",
            data: Data(),
            expected: .manifestNotRegularFile)
        try assertRejected(
            "oversized",
            data: Data(
                repeating: 0x61,
                count:
                    ChatProductionRemoteDispatchManifestChannel
                        .maximumManifestBytes + 1),
            expected: .manifestNotRegularFile)
        try assertRejected(
            "malformed",
            data: Data("{".utf8),
            expected: .manifestUnreadable)
    }

    func testSealedChannelRejectsFutureLifetimeAndSignatureMismatch()
        throws
    {
        let now = Date(timeIntervalSince1970: 17_000)

        func assertRejected(
            _ suffix: String,
            manifest: TatwoRemoteDispatchReadinessManifestV1,
            expected: ChatProductionRemoteTurnDispatcherError
        ) throws {
            let root = temporaryDirectory("manifest-\(suffix)")
            try writeManifest(
                manifest,
                channelRoot: root,
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5")
            XCTAssertThrowsError(
                try ChatProductionRemoteDispatchManifestChannel(
                    channelRootURL: root
                ).load(
                    targetDeviceID: "target-device",
                    agent: .codex,
                    exactModelRouteID: "gpt-5.5",
                    now: now)
            ) { error in
                XCTAssertEqual(
                    error as? ChatProductionRemoteTurnDispatcherError,
                    expected,
                    suffix)
            }
        }

        let futureIssuedAt = now.addingTimeInterval(
            TatwoRemoteDispatchReadinessManifestV1.allowedClockSkew + 1)
        try assertRejected(
            "future",
            manifest: makeManifest(
                issuedAt: futureIssuedAt,
                expiresAt: futureIssuedAt.addingTimeInterval(300)),
            expected: .manifestMismatch("freshness-window"))
        try assertRejected(
            "lifetime",
            manifest: makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(
                    TatwoRemoteDispatchReadinessManifestV1.maximumLifetime + 1)),
            expected: .manifestMismatch("freshness-window"))
        try assertRejected(
            "signature-key",
            manifest: makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300),
                signatureKeyID: "other-target-key"),
            expected: .manifestMismatch("target-signature"))
        try assertRejected(
            "signature-generation",
            manifest: makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300),
                signatureKeyGeneration: 4),
            expected: .manifestMismatch("target-signature"))
        try assertRejected(
            "signature-device",
            manifest: makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300),
                signatureDeviceID: "other-target"),
            expected: .manifestMismatch("target-signature"))
        try assertRejected(
            "signature-time",
            manifest: makeManifest(
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300),
                signatureSignedAt: "1970-01-01T00:00:00Z"),
            expected: .manifestMismatch("target-signature"))
    }

    func testCoreProductionManifestVerifyRejectsForgedSignaturePayloadAndPinnedIdentityDrift()
        throws
    {
        let now = Date(timeIntervalSince1970: 18_000)
        let fixture = try makeCoreManifestTrustFixture(now: now)
        XCTAssertNoThrow(
            try fixture.manifest.verify(
                trust: fixture.originTrust,
                expectedTargetDeviceID: fixture.manifest.targetDeviceID,
                expectedAgent: .codex,
                expectedExactModelRouteID: "gpt-5.5",
                now: now,
                environment: [:]))

        let validSignature = fixture.manifest.targetSignature
        let forgedSignature = TatwoDeviceSignatureV1(
            purpose: validSignature.purpose,
            deviceID: validSignature.deviceID,
            keyID: validSignature.keyID,
            keyGeneration: validSignature.keyGeneration,
            payloadDigest: validSignature.payloadDigest,
            signedAt: validSignature.signedAt,
            signature: validSignature.signature + "A")
        let forgedManifest = fixture.payload.manifest(
            targetSignature: forgedSignature)
        assertCoreManifestSignatureRejected(
            forgedManifest,
            trust: fixture.originTrust,
            now: now,
            label: "forged-signature")

        let driftedDigestSignature = TatwoDeviceSignatureV1(
            purpose: validSignature.purpose,
            deviceID: validSignature.deviceID,
            keyID: validSignature.keyID,
            keyGeneration: validSignature.keyGeneration,
            payloadDigest: "sha256:\(String(repeating: "0", count: 64))",
            signedAt: validSignature.signedAt,
            signature: validSignature.signature)
        let digestDriftManifest = fixture.payload.manifest(
            targetSignature: driftedDigestSignature)
        assertCoreManifestSignatureRejected(
            digestDriftManifest,
            trust: fixture.originTrust,
            now: now,
            label: "payload-digest-drift")

        let identityDriftPayload = CoreManifestUnsignedPayload(
            targetDeviceID: fixture.payload.targetDeviceID,
            targetKeyID: fixture.payload.targetKeyID,
            targetKeyGeneration: fixture.payload.targetKeyGeneration + 1,
            registryGeneration: fixture.payload.registryGeneration,
            workspaceBindingID: fixture.payload.workspaceBindingID,
            workspaceBindingDigest: fixture.payload.workspaceBindingDigest,
            requestedAgent: fixture.payload.requestedAgent,
            exactModelRouteID: fixture.payload.exactModelRouteID,
            agentModelCapabilityDigest:
                fixture.payload.agentModelCapabilityDigest,
            activeSkillSetDigest: fixture.payload.activeSkillSetDigest,
            issuedAt: fixture.payload.issuedAt,
            expiresAt: fixture.payload.expiresAt)
        let identityDriftSignature = try fixture.targetTrust.sign(
            payload: try identityDriftPayload.canonicalData(),
            purpose: .loopTargetReadiness,
            signedAt: now)
        let identityDriftManifest = identityDriftPayload.manifest(
            targetSignature: identityDriftSignature)
        XCTAssertThrowsError(
            try identityDriftManifest.verify(
                trust: fixture.originTrust,
                expectedTargetDeviceID:
                    identityDriftManifest.targetDeviceID,
                expectedAgent: .codex,
                expectedExactModelRouteID: "gpt-5.5",
                now: now,
                environment: [:])
        ) { error in
            XCTAssertEqual(
                error as? TatwoRemoteDispatchReadinessRegistryError,
                .invalidField("manifest.targetIdentity"))
        }
    }

    func testSealedChannelRejectsTargetAgentAndRouteMismatch() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let mismatches: [TatwoRemoteDispatchReadinessManifestV1] = [
            makeManifest(
                targetDeviceID: "other-target",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300)),
            makeManifest(
                requestedAgent: "claude",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300)),
            makeManifest(
                exactModelRouteID: "gpt-5.6-sol",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300)),
        ]

        for (index, manifest) in mismatches.enumerated() {
            let root = temporaryDirectory("scope-\(index)")
            try writeManifest(
                manifest,
                channelRoot: root,
                targetDeviceID: "target-device",
                agent: .codex,
                exactModelRouteID: "gpt-5.5")
            XCTAssertThrowsError(
                try ChatProductionRemoteDispatchManifestChannel(
                    channelRootURL: root
                ).load(
                    targetDeviceID: "target-device",
                    agent: .codex,
                    exactModelRouteID: "gpt-5.5",
                    now: now)
            ) { error in
                guard case .manifestMismatch =
                    error as? ChatProductionRemoteTurnDispatcherError
                else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
    }

    func testDispatcherMapsChannelFailureWithoutInventingAcceptance() {
        let now = Date(timeIntervalSince1970: 30_000)
        let dispatcher = ChatProductionRemoteTurnDispatcher(
            materialProvider: StaticProductionMaterialProvider(
                material: makeMaterial(now: now)),
            runner: { _, _, _, _, _ in
                throw ChatProductionRemoteTurnDispatcherError.channelFailure
            },
            now: { now },
            uniqueID: { "attempt-fixed" })

        XCTAssertEqual(
            dispatcher.dispatch(makeRequest(contractMode: .xxl)),
            .blocked(.dispatchRejected))
    }

    func testDispatcherFailsClosedOnCanonicalContractModeMismatch() {
        let now = Date(timeIntervalSince1970: 31_000)
        let dispatcher = ChatProductionRemoteTurnDispatcher(
            materialProvider: ThrowingProductionMaterialProvider(
                error: .contractModeMismatch),
            runner: { _, _, job, _, _ in
                ChatProductionRemoteTurnRunnerReceipt(job: job)
            },
            now: { now },
            uniqueID: { "attempt-fixed" })

        XCTAssertEqual(
            dispatcher.dispatch(makeRequest(contractMode: .xxl)),
            .blocked(.contractModeMismatch))
    }

    func testMaterialProviderAcceptsInjectedCanonicalFixtures() throws {
        let now = Date(timeIntervalSince1970: 35_000)
        let request = makeRequest(contractMode: .xxl)
        let goal = makeStoredGoalRun(now: now)
        let lease = makeLease(now: now)
        let manifest = makeManifest(
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300))
        let channelRoot = temporaryDirectory("injected-material")
        let provider = ChatProductionRemoteDispatchMaterialProvider(
            issuedContractLoader: { contractID in
                guard contractID == goal.contractID else {
                    throw ChatProductionRemoteTurnDispatcherError
                        .contractModeMismatch
                }
                return goal
            },
            originAuthorityResolver: { observedAt in
                guard observedAt == now else {
                    throw ChatProductionRemoteTurnDispatcherError
                        .originAuthorityUnavailable
                }
                return .init(
                    originDeviceID: "origin-device",
                    lease: lease)
            },
            channelRootResolver: { originDeviceID in
                guard originDeviceID == "origin-device" else {
                    throw ChatProductionRemoteTurnDispatcherError
                        .originAuthorityUnavailable
                }
                return channelRoot
            },
            manifestLoader: {
                observedRoot,
                targetDeviceID,
                agent,
                exactModelRouteID,
                observedAt in
                guard observedRoot == channelRoot,
                      targetDeviceID == request.invocation.targetDeviceID,
                      agent == request.agent,
                      exactModelRouteID == request.exactModelRouteID,
                      observedAt == now
                else {
                    throw ChatProductionRemoteTurnDispatcherError
                        .manifestMismatch("injected-fixture")
                }
                return manifest
            })

        XCTAssertEqual(
            try provider.material(for: request, now: now),
            ChatProductionRemoteDispatchMaterial(
                originDeviceID: "origin-device",
                currentOriginLease: lease,
                contractMode: .xxl,
                targetReadinessManifest: manifest,
                readinessBinding: manifest.binding(
                    challengeNonce: request.readinessChallengeNonce)))
    }

    func testMaterialProviderInjectedFixturesFailClosedOnDrift() throws {
        let now = Date(timeIntervalSince1970: 36_000)
        let manifest = makeManifest(
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300))
        let lease = makeLease(now: now)
        let channelRoot = temporaryDirectory("injected-material-drift")

        func provider(
            goal: TatwoStoredGoalRun
        ) -> ChatProductionRemoteDispatchMaterialProvider {
            ChatProductionRemoteDispatchMaterialProvider(
                issuedContractLoader: { _ in goal },
                originAuthorityResolver: { _ in
                    .init(
                        originDeviceID: "origin-device",
                        lease: lease)
                },
                channelRootResolver: { _ in channelRoot },
                manifestLoader: { _, _, _, _, _ in manifest })
        }

        XCTAssertThrowsError(
            try provider(
                goal: makeStoredGoalRun(mode: .xl, now: now)
            ).material(
                for: makeRequest(contractMode: .xxl),
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .contractModeMismatch)
        }

        let mismatchedManifest = makeManifest(
            targetDeviceID: "other-target",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300))
        XCTAssertThrowsError(
            try provider(
                goal: makeStoredGoalRun(now: now)
            ).material(
                for: makeRequest(
                    contractMode: .xxl,
                    targetReadinessManifest: mismatchedManifest),
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .manifestMismatch("preloaded-manifest"))
        }

        let mismatchedBinding = manifest.binding(
            challengeNonce: "other-readiness-attempt")
        XCTAssertThrowsError(
            try provider(
                goal: makeStoredGoalRun(now: now)
            ).material(
                for: makeRequest(
                    contractMode: .xxl,
                    readinessBinding: mismatchedBinding),
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .manifestMismatch("preloaded-binding"))
        }

        XCTAssertThrowsError(
            try provider(
                goal: makeStoredGoalRun(now: now)
            ).material(
                for: makeRequest(
                    contractMode: .xxl,
                    readinessChallengeNonce: "../invalid"),
                now: now)
        ) { error in
            XCTAssertEqual(
                error as? ChatProductionRemoteTurnDispatcherError,
                .invalidIdentifier("readinessChallengeNonce"))
        }
    }

    func testSuccessfulXXLDispatchBuildsOnePathlessBoundProductionJob() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let capture = ProductionJobCapture()
        let material = makeMaterial(now: now)
        let dispatcher = ChatProductionRemoteTurnDispatcher(
            materialProvider: StaticProductionMaterialProvider(
                material: material),
            runner: { origin, target, job, lease, manifest in
                capture.append(job)
                XCTAssertEqual(origin, "origin-device")
                XCTAssertEqual(target, "target-device")
                XCTAssertEqual(lease, material.currentOriginLease)
                XCTAssertEqual(manifest, material.targetReadinessManifest)
                return ChatProductionRemoteTurnRunnerReceipt(job: job)
            },
            now: { now },
            uniqueID: { "attempt-fixed" })

        let request = makeRequest(contractMode: .xxl)
        let outcome = dispatcher.dispatch(request)
        let acceptance: ChatRemoteTurnDispatchAcceptance
        guard case .accepted(let value) = outcome else {
            return XCTFail("expected accepted, got \(outcome)")
        }
        acceptance = value

        let job = try XCTUnwrap(capture.jobs.first)
        XCTAssertEqual(capture.jobs.count, 1)
        XCTAssertEqual(job.logicalJobID, request.logicalJobID)
        XCTAssertEqual(job.remoteBorrowInvocation, request.invocation)
        XCTAssertEqual(job.remoteDispatchReadiness, material.readinessBinding)
        XCTAssertEqual(job.workPath, "")
        XCTAssertEqual(
            job.workspaceLocator,
            TatwoRemoteWorkspaceLocatorV1(
                workspaceBindingID: "workspace-binding",
                registryGeneration: 7))
        guard case .tatwoLoop(let payload) = job.payload else {
            return XCTFail("expected tatwoLoop payload")
        }
        XCTAssertEqual(payload.mode, .xxl)
        XCTAssertEqual(payload.agent, .codex)
        XCTAssertEqual(payload.exactModelRouteID, "gpt-5.5")
        XCTAssertEqual(payload.taskDescription, "run production tests")
        XCTAssertEqual(acceptance.logicalJobID, job.logicalJobID)
        XCTAssertEqual(acceptance.remoteJobID, job.jobID)
        XCTAssertEqual(acceptance.acceptedAt, now)
    }

    @MainActor
    func testSuccessfulProductionDispatcherCreatesOneDurableRemoteRow() async throws {
        let directory = temporaryDirectory("durable-row")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let now = Date()
        let thread = TatwoNativeChatThread(
            title: "production remote",
            workOSGoalID: "goal-production",
            workOSContractID: "contract-production")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "goal-production",
                contractID: "contract-production",
                mode: .xxl,
                scenario: "chat-production",
                objective: "one durable remote row",
                status: .planned,
                issuedAt: now,
                updatedAt: now),
            to: goalStore)
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent(
                "authorization",
                isDirectory: true))
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "target-device",
            contractID: "contract-production",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let pending = try pendingStore.arm(
            grant: grant,
            goalID: "goal-production",
            targetDisplayName: "Mac mini",
            now: now)
        let material = makeMaterial(
            now: now,
            contractMode: .xxl,
            contractID: "contract-production",
            goalID: "goal-production",
            sessionID: grant.sessionID,
            grantID: grant.id)
        let dispatcher = ChatProductionRemoteTurnDispatcher(
            materialProvider: StaticProductionMaterialProvider(
                material: material),
            runner: { _, _, job, _, _ in
                ChatProductionRemoteTurnRunnerReceipt(job: job)
            },
            now: { now },
            uniqueID: { "durable-attempt" })
        let model = ChatPageModel(
            environment: [
                "XCTestConfigurationFilePath":
                    "ChatProductionRemoteTurnDispatcherTests",
                "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
                "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
            ],
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: directory.appendingPathComponent("journal.json")),
            goalRunStore: goalStore,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher)
        try await waitForInitialStoreLoad(model)

        model.prompt = "run production tests"
        model.submitCurrentChatTurn()
        try await waitUntil {
            !model.isRunning
                && (try? pendingStore.pending(sessionID: grant.sessionID)) == nil
        }

        let remoteRows = model.chatTranscriptJournal
            .orderedItems(
                threadID: TatwoNativeChatSessionReference(
                    kind: .thread,
                    id: thread.id
                ).stableKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(remoteRows[0].eventIDs.count, 1)
        XCTAssertEqual(
            remoteRows[0].attributes["detail.logicalJobID"],
            pending.logicalJobID)
        XCTAssertEqual(
            remoteRows[0].attributes["detail.jobID"],
            "chat-durable-attempt")
    }

    @MainActor
    func testProductionDispatchRelaunchesUnknownThenFreshRegistryProjectionConvergesOneStableRow() async throws {
        let directory = temporaryDirectory("relaunch-convergence")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let now = Date()
        let thread = TatwoNativeChatThread(
            title: "production remote relaunch",
            workOSGoalID: "goal-production",
            workOSContractID: "contract-production")
        let nativeStore = TatwoNativeChatStore(
            url: directory.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(TatwoNativeChatStoreDocument(threads: [thread]))
        let journalStore = ChatTranscriptJournalDiskStore(
            fileURL: directory.appendingPathComponent("journal.json"))
        let goalStore = TatwoGoalRunStore(directoryURL: directory)
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "goal-production",
                contractID: "contract-production",
                mode: .xxl,
                scenario: "chat-production",
                objective: "relaunch remote projection convergence",
                status: .planned,
                issuedAt: now,
                updatedAt: now),
            to: goalStore)
        let authorizationStore = TatwoRemoteBorrowAuthorizationStore(
            rootURL: directory.appendingPathComponent(
                "authorization",
                isDirectory: true))
        let grant = try authorizationStore.issueSessionGrant(
            sessionID: thread.id.uuidString.lowercased(),
            targetDeviceID: "target-device",
            contractID: "contract-production",
            now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: directory.appendingPathComponent("pending.json"))
        let pending = try pendingStore.arm(
            grant: grant,
            goalID: "goal-production",
            targetDisplayName: "Mac mini",
            now: now)
        let material = makeMaterial(
            now: now,
            contractMode: .xxl,
            contractID: "contract-production",
            goalID: "goal-production",
            sessionID: grant.sessionID,
            grantID: grant.id)
        let dispatcher = ChatProductionRemoteTurnDispatcher(
            materialProvider: StaticProductionMaterialProvider(
                material: material),
            runner: { _, _, job, _, _ in
                ChatProductionRemoteTurnRunnerReceipt(job: job)
            },
            now: { now },
            uniqueID: { "relaunch-attempt" })
        let environment = [
            "XCTestConfigurationFilePath":
                "ChatProductionRemoteTurnDispatcherTests",
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
        ]
        let first = ChatPageModel(
            environment: environment,
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: goalStore,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher,
            remoteProjectionProcessID: "test-remote-projection-first")
        try await waitForInitialStoreLoad(first)

        first.prompt = "run production relaunch convergence"
        first.submitCurrentChatTurn()
        try await waitUntil {
            !first.isRunning
                && (try? pendingStore.pending(sessionID: grant.sessionID)) == nil
        }

        let threadID = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let accepted = try XCTUnwrap(
            first.chatTranscriptJournal
                .orderedItems(threadID: threadID)
                .first(where: { $0.kind == .remoteJob }))
        let stableItemID = accepted.id
        XCTAssertEqual(accepted.eventIDs.count, 1)
        XCTAssertEqual(
            accepted.attributes["remoteRuntimeTruth"],
            ChatRemoteJobRuntimeTruth.observedThisProcess.rawValue)

        let relaunched = ChatPageModel(
            environment: environment,
            store: nativeStore,
            transcriptJournalStore: journalStore,
            goalRunStore: goalStore,
            remoteBorrowAuthorizationStore: authorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher: dispatcher,
            remoteProjectionProcessID: "test-remote-projection-relaunched")
        try await waitForInitialStoreLoad(relaunched)

        let unknown = try XCTUnwrap(
            relaunched.chatTranscriptJournal
                .orderedItems(threadID: threadID)
                .first(where: { $0.kind == .remoteJob }))
        let unknownRow = try XCTUnwrap(
            relaunched.transcriptMessages.first(where: { $0.id == stableItemID }))
        let unknownPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: unknownRow.status))
        XCTAssertEqual(unknown.id, stableItemID)
        XCTAssertEqual(unknown.eventIDs.count, 2)
        XCTAssertEqual(
            unknown.attributes["remoteRuntimeTruth"],
            ChatRemoteJobRuntimeTruth.unknownAfterRelaunch.rawValue)
        XCTAssertEqual(unknownPayload.runtimeTruth, .unknownAfterRelaunch)
        XCTAssertNil(unknownPayload.terminalOutcome)
        XCTAssertEqual(
            relaunched.transcriptMessages.filter { $0.id == stableItemID }.count,
            1)

        relaunched.selectedDispatchRecords = [
            TatwoDispatchRecord(
                id: "dispatch-relaunch-observation",
                contractID: "contract-production",
                goalID: "goal-production",
                bindingID: "binding-production",
                sourceSlotID: "slot-production",
                identity: .sub,
                modelID: "gpt-5.5",
                subtask: "run production relaunch convergence",
                logicalDispatchID: pending.logicalJobID,
                attempt: 1,
                status: .running,
                startedAt: now,
                updatedAt: now.addingTimeInterval(1),
                receiptID: "receipt-relaunch-observation",
                outputRef: nil,
                errorMessage: nil,
                remoteJobID: "chat-relaunch-attempt",
                originDeviceID: "origin-device",
                targetDeviceID: "target-device",
                remoteStatus: .running,
                remoteJobDigest:
                    "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                remoteDispatchNonce: "nonce-relaunch-observation",
                consumedResultDigest: nil),
        ]
        try await waitUntil {
            guard let item = relaunched.chatTranscriptJournal
                .orderedItems(threadID: threadID)
                .first(where: { $0.kind == .remoteJob })
            else {
                return false
            }
            return item.id == stableItemID
                && item.eventIDs.count == 3
                && item.attributes["remoteRuntimeTruth"]
                    == ChatRemoteJobRuntimeTruth.observedThisProcess.rawValue
                && item.attributes["remotePublicState"]
                    == ChatRemoteJobPublicState.running.rawValue
        }

        let converged = try XCTUnwrap(
            relaunched.chatTranscriptJournal
                .orderedItems(threadID: threadID)
                .first(where: { $0.kind == .remoteJob }))
        let convergedRow = try XCTUnwrap(
            relaunched.transcriptMessages.first(where: { $0.id == stableItemID }))
        let convergedPayload = try XCTUnwrap(
            ChatRemoteJobInlinePresentation.payload(from: convergedRow.status))
        XCTAssertEqual(converged.id, stableItemID)
        XCTAssertEqual(converged.eventIDs.count, 3)
        XCTAssertEqual(convergedPayload.runtimeTruth, .observedThisProcess)
        XCTAssertEqual(convergedPayload.state, .running)
        XCTAssertNil(convergedPayload.terminalOutcome)
        XCTAssertNil(convergedPayload.blocker)
        XCTAssertEqual(
            relaunched.transcriptMessages.filter { $0.id == stableItemID }.count,
            1)
    }

    func testStaleContinuationHandleAutoFallbackSucceedsWithoutFailedRow() {
        var coordinator = ChatGatewayContinuationFallbackCoordinator()
        let request = makeGatewayResumeRequest()

        let first = coordinator.evaluateFailure(
            message: "continuation_handle_unknown_or_expired",
            request: request)
        XCTAssertEqual(first, .retryHandleless(notice: nil))
        XCTAssertTrue(coordinator.fallbackAttempted)
        XCTAssertTrue(coordinator.staleHandleCleared)

        let successIsNotAFailureRow =
            ChatGatewayContinuationFallbackPresentation.retryHandleless(
                notice: nil)
        XCTAssertNotEqual(
            successIsNotAFailureRow,
            .failedRow(message: "continuation_handle_unknown_or_expired"))
        XCTAssertFalse(
            ChatRuntimeTextHumanizer.projectedOutput(
                "Ordinary Grok answer after handle-less replay.")
            .isBlocker)
    }

    func testStaleContinuationHandleFallbackFailureSurfacesSingleRetryError() {
        var coordinator = ChatGatewayContinuationFallbackCoordinator()
        let request = makeGatewayResumeRequest()

        XCTAssertEqual(
            coordinator.evaluateFailure(
                message: "continuation_handle_unknown_or_expired",
                request: request),
            .retryHandleless(notice: nil))

        let retryError = "grok backend is temporarily unavailable"
        let handleless = request.handlelessFallbackRequest(
            rebuiltContextSHA256: Self.replayContextSHA256)
        XCTAssertEqual(
            coordinator.evaluateFailure(
                message: retryError,
                request: handleless),
            .notHandleError,
            "non-handle retry errors fall through to one failed row")
        XCTAssertEqual(
            coordinator.evaluateFailure(
                message: "continuation_handle_unknown_or_expired",
                request: handleless),
            .failedRow(message: "continuation_handle_unknown_or_expired"))
        XCTAssertTrue(coordinator.fallbackAttempted)
        XCTAssertEqual(
            ChatRuntimeContinuationErrorMapping.dispatchFailureMessage(
                retryError),
            retryError)
    }

    func testStaleContinuationHandleIsClearedAfterFallback() {
        var coordinator = ChatGatewayContinuationFallbackCoordinator()
        let request = makeGatewayResumeRequest()
        var document = TatwoNativeChatStoreDocument(
            threads: [
                TatwoNativeChatThread(
                    id: Self.gatewayThreadID,
                    title: "Grok",
                    gatewayConversationHandles: [
                        TatwoGatewayConversationHandleV1(
                            opaqueResponseHandle:
                                "stale-gateway-handle-01",
                            threadID: Self.gatewayThreadID.uuidString
                                .lowercased(),
                            runtimeAdapterID:
                                TatwoChatRuntimeAdapter.gatewayDirect
                                .rawValue,
                            canonicalModelID: "grok-4.6",
                            gatewayInstanceID: "gateway-instance-01"),
                    ]),
            ])

        let decision = coordinator.evaluateFailure(
            message: "continuation_handle_unknown_or_expired",
            request: request)
        XCTAssertEqual(decision, .retryHandleless(notice: nil))
        XCTAssertTrue(coordinator.staleHandleCleared)
        XCTAssertTrue(
            TatwoNativeSessionTree.clearGatewayConversationHandle(
                matching: request,
                in: &document))
        XCTAssertTrue(
            document.threads[0].gatewayConversationHandles.isEmpty)

        let second = coordinator.evaluateFailure(
            message: "continuation_handle_unknown_or_expired",
            request: request)
        XCTAssertEqual(
            second,
            .failedRow(message: "continuation_handle_unknown_or_expired"))
        XCTAssertTrue(coordinator.staleHandleCleared)
    }

    func testRuntimeMapsHandleUnknownClassOntoStableFallbackCode() {
        XCTAssertEqual(
            ChatRuntimeContinuationErrorMapping.dispatchFailureMessage(
                "continuation handle is unknown after restart"),
            "continuation_handle_unknown_or_expired: continuation handle is unknown after restart")
        XCTAssertEqual(
            ChatRuntimeContinuationErrorMapping.dispatchFailureMessage(
                "continuation_handle_unknown_or_expired"),
            "continuation_handle_unknown_or_expired")
        XCTAssertEqual(
            ChatRuntimeContinuationErrorMapping.dispatchFailureMessage(
                "quota exhausted"),
            "quota exhausted")
    }

    private func makeGatewayResumeRequest() -> TatwoGatewayContinuationRequestV1 {
        TatwoGatewayContinuationRequestV1(
            mode: .providerResume,
            threadID: Self.gatewayThreadID.uuidString.lowercased(),
            runtimeAdapterID: TatwoChatRuntimeAdapter.gatewayDirect.rawValue,
            canonicalModelID: "grok-4.6",
            previousResponseHandle: "stale-gateway-handle-01",
            previousGatewayInstanceID: "gateway-instance-01",
            contextSHA256: Self.resumeContextSHA256)
    }

    private static let gatewayThreadID = UUID(
        uuidString: "019f0000-0000-7000-8000-0000000000aa")!
    private static let resumeContextSHA256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let replayContextSHA256 =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func makeRequest(
        contractMode: WorkModeID,
        readinessChallengeNonce: String = "readiness-attempt-production",
        targetReadinessManifest:
            TatwoRemoteDispatchReadinessManifestV1? = nil,
        readinessBinding:
            TatwoRemoteDispatchReadinessBindingV1? = nil
    ) -> ChatRemoteTurnDispatchRequest {
        ChatRemoteTurnDispatchRequest(
            visibleTurn: "run production tests",
            invocation: TatwoRemoteBorrowInvocationV1(
                sessionID: "session-production",
                targetDeviceID: "target-device",
                contractID: "contract-production",
                goalID: "goal-production",
                mode: .manual,
                risk: .lowRisk,
                grantID: "grant-production"),
            claimID: "claim-production",
            logicalJobID: "logical-production",
            contractMode: contractMode,
            agent: .codex,
            exactModelRouteID: "gpt-5.5",
            readinessChallengeNonce: readinessChallengeNonce,
            targetReadinessManifest: targetReadinessManifest,
            readinessBinding: readinessBinding)
    }

    private func makeMaterial(
        now: Date,
        contractMode: TatwoLoopModeV1 = .xxl,
        contractID: String = "contract-production",
        goalID: String = "goal-production",
        sessionID: String = "session-production",
        grantID: String = "grant-production"
    ) -> ChatProductionRemoteDispatchMaterial {
        let manifest = makeManifest(
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300))
        return ChatProductionRemoteDispatchMaterial(
            originDeviceID: "origin-device",
            currentOriginLease: makeLease(now: now),
            contractMode: contractMode,
            targetReadinessManifest: manifest,
            readinessBinding: manifest.binding(
                challengeNonce: "readiness-attempt-production"))
    }

    private func makeStoredGoalRun(
        contractID: String = "contract-production",
        goalID: String = "goal-production",
        mode: WorkModeID = .xxl,
        now: Date
    ) -> TatwoStoredGoalRun {
        TatwoStoredGoalRun(
            goalID: goalID,
            contractID: contractID,
            mode: mode,
            scenario: "production-chat-remote-dispatch",
            objective: "exercise injected production material provider",
            status: .running,
            issuedAt: now,
            updatedAt: now)
    }

    private func makeManifest(
        targetDeviceID: String = "target-device",
        targetKeyID: String = "target-key",
        targetKeyGeneration: UInt64 = 3,
        requestedAgent: String = "codex",
        exactModelRouteID: String = "gpt-5.5",
        issuedAt: Date,
        expiresAt: Date,
        signatureDeviceID: String? = nil,
        signatureKeyID: String? = nil,
        signatureKeyGeneration: UInt64? = nil,
        signatureSignedAt: String? = nil
    ) -> TatwoRemoteDispatchReadinessManifestV1 {
        TatwoRemoteDispatchReadinessManifestV1(
            targetDeviceID: targetDeviceID,
            targetKeyID: targetKeyID,
            targetKeyGeneration: targetKeyGeneration,
            registryGeneration: 7,
            workspaceBindingID: "workspace-binding",
            workspaceBindingDigest: String(repeating: "a", count: 64),
            requestedAgent: requestedAgent,
            exactModelRouteID: exactModelRouteID,
            agentModelCapabilityDigest: String(repeating: "b", count: 64),
            activeSkillSetDigest: String(repeating: "c", count: 64),
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            targetSignature: TatwoDeviceSignatureV1(
                purpose: "loop-target-readiness",
                deviceID: signatureDeviceID ?? targetDeviceID,
                keyID: signatureKeyID ?? targetKeyID,
                keyGeneration:
                    signatureKeyGeneration ?? targetKeyGeneration,
                payloadDigest: "sha256:\(String(repeating: "d", count: 64))",
                signedAt:
                    signatureSignedAt
                    ?? TatwoLoopJobChannelTrust.iso8601(issuedAt),
                    signature: "test-signature"))
    }

    private func makeCoreManifestTrustFixture(
        now: Date
    ) throws -> CoreManifestTrustFixture {
        let originSeed = try TatwoLoopJobChannelTrust.enroll(
            deviceID: "origin-device",
            privateKeyStore: CoreManifestMemoryKeyStore(),
            environment: [:])
        let targetTrust = try TatwoLoopJobChannelTrust.enroll(
            deviceID: "target-device",
            privateKeyStore: CoreManifestMemoryKeyStore(),
            environment: [:])
        let targetIdentity = targetTrust.localIdentity
        let originTrust = TatwoLoopJobChannelTrust(
            authority: originSeed.authority,
            localIdentity: originSeed.localIdentity,
            pinnedIdentities: [
                targetIdentity.deviceID: targetIdentity,
            ])
        let payload = CoreManifestUnsignedPayload(
            targetDeviceID: targetIdentity.deviceID,
            targetKeyID: targetIdentity.keyID,
            targetKeyGeneration: targetIdentity.keyGeneration,
            registryGeneration: 7,
            workspaceBindingID: "workspace-binding",
            workspaceBindingDigest: String(repeating: "a", count: 64),
            requestedAgent: TatwoRemoteAgentKindV1.codex.rawValue,
            exactModelRouteID: "gpt-5.5",
            agentModelCapabilityDigest: String(repeating: "b", count: 64),
            activeSkillSetDigest: String(repeating: "c", count: 64),
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300))
        let signature = try targetTrust.sign(
            payload: try payload.canonicalData(),
            purpose: .loopTargetReadiness,
            signedAt: now)
        return CoreManifestTrustFixture(
            payload: payload,
            manifest: payload.manifest(targetSignature: signature),
            originTrust: originTrust,
            targetTrust: targetTrust)
    }

    private func assertCoreManifestSignatureRejected(
        _ manifest: TatwoRemoteDispatchReadinessManifestV1,
        trust: TatwoLoopJobChannelTrust,
        now: Date,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try manifest.verify(
                trust: trust,
                expectedTargetDeviceID: manifest.targetDeviceID,
                expectedAgent: .codex,
                expectedExactModelRouteID: "gpt-5.5",
                now: now,
                environment: [:]),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? TatwoRemoteDispatchReadinessRegistryError,
                .signatureRejected,
                label,
                file: file,
                line: line)
        }
    }

    private func writeManifest(
        _ manifest: TatwoRemoteDispatchReadinessManifestV1,
        channelRoot: URL,
        targetDeviceID: String,
        agent: TatwoRemoteAgentKindV1,
        exactModelRouteID: String
    ) throws {
        let url = try ChatProductionRemoteDispatchManifestChannel.manifestURL(
            channelRootURL: channelRoot,
            targetDeviceID: targetDeviceID,
            agent: agent,
            exactModelRouteID: exactModelRouteID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func makeLease(now: Date) -> TatwoAuthorityLeaseV1 {
        TatwoAuthorityLeaseV1(
            domainID: "tatwo-primary",
            holderDeviceID: "origin-device",
            epoch: 9,
            fencingToken: "fence-9",
            observedAt: now,
            expiresAt: now.addingTimeInterval(300),
            source: .humanConfirmed,
            receiptMetadata: TatwoWorkReceiptMetadataV1(
                receiptID: "lease-origin-9",
                schema: "TatwoAuthorityLeaseV1",
                version: 1,
                correlationID: "chat-production",
                createdAt: now,
                sourceDeviceID: "origin-device"))
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "chat-production-dispatch-\(suffix)-\(UUID().uuidString)",
                isDirectory: true)
    }

    private func makeLocalInternalInstallFixture(
        _ suffix: String
    ) throws -> LocalInternalInstallFixture {
        let base = temporaryDirectory("local-internal-\(suffix)")
        let bundle = base.appendingPathComponent(
            "Applications/Tatwo Ultrawork.app",
            isDirectory: true)
        let helperURL = bundle.appendingPathComponent(
            "Contents/Helpers/TatwoPLGAnchorHelper",
            isDirectory: false)
        let helperData = Data("trusted-production-helper".utf8)
        try writeSentinel(helperData, to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path)
        let helperDigest = SHA256.hash(data: helperData)
            .map { String(format: "%02x", $0) }
            .joined()
        let mainExecutableURL = bundle.appendingPathComponent(
            "Contents/MacOS/TatwoUltraworkMac",
            isDirectory: false)
        let mainExecutableData = Data("trusted-main-executable".utf8)
        try writeSentinel(mainExecutableData, to: mainExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mainExecutableURL.path)
        let mainExecutableDigest = sha256Hex(mainExecutableData)
        let nestedCodeURL = bundle.appendingPathComponent(
            "Contents/Frameworks/Nested.framework/Versions/A/Nested",
            isDirectory: false)
        let nestedCodeData = Data("trusted-nested-code".utf8)
        try writeSentinel(nestedCodeData, to: nestedCodeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nestedCodeURL.path)
        let resourceURL = bundle.appendingPathComponent(
            "Contents/Resources/base.txt",
            isDirectory: false)
        let resourceData = Data("trusted-resource".utf8)
        try writeSentinel(resourceData, to: resourceURL)
        let bundleContentManifestURL = bundle.appendingPathComponent(
            TatwoChatProcessCompositionResolver
                .bundleContentManifestRelativePath,
            isDirectory: false)
        let bundleContentManifestData =
            try makeBundleContentManifestData(
                mainExecutableData: mainExecutableData,
                nestedCodeData: nestedCodeData,
                helperData: helperData,
                resourceData: resourceData)
        try writeSentinel(
            bundleContentManifestData,
            to: bundleContentManifestURL)
        let bundleContentManifestDigest =
            sha256Hex(bundleContentManifestData)
        let appSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: base)
        let installerRoot = appSupport.appendingPathComponent(
            "local-app-install",
            isDirectory: true)
        let sourceCommit =
            "0123456789abcdef0123456789abcdef01234567"
        let sourceTree =
            "89abcdef0123456789abcdef0123456789abcdef"
        let sourceDirty = false
        let sourceSnapshotDigest = String(repeating: "1", count: 64)
        let sourceTreeManifestDigest =
            String(repeating: "2", count: 64)
        let buildInputManifestDigest =
            String(repeating: "3", count: 64)
        let buildOutputManifestDigest =
            String(repeating: "4", count: 64)
        let provenanceNodeDigest =
            String(repeating: "5", count: 64)
        let provenanceNodeCDHash =
            String(repeating: "6", count: 40)
        let provenanceNodeVersion = "v26.5.0"
        let candidateID = computedCandidateID(
            sourceCommit: sourceCommit,
            sourceTree: sourceTree,
            sourceSnapshotDigest: sourceSnapshotDigest,
            sourceTreeManifestDigest: sourceTreeManifestDigest,
            buildInputManifestDigest: buildInputManifestDigest,
            buildOutputManifestDigest: buildOutputManifestDigest,
            bundleContentManifestDigest: bundleContentManifestDigest,
            mainExecutableDigest: mainExecutableDigest,
            provenanceNodeDigest: provenanceNodeDigest,
            provenanceNodeCDHash: provenanceNodeCDHash,
            provenanceNodeVersion: provenanceNodeVersion,
            appVersion: "0.1.10",
            appBuild: "24")
        let embeddedProvenanceURL = bundle.appendingPathComponent(
            "Contents/Resources/TatwoCandidateProvenance.json",
            isDirectory: false)
        let embeddedProvenanceData = try JSONSerialization.data(
            withJSONObject: [
                "schema": "TatwoCandidateEmbeddedProvenanceV1",
                "candidateID": candidateID,
                "sourceCommit": sourceCommit,
                "sourceTree": sourceTree,
                "sourceDirty": sourceDirty,
                "sourceSnapshotSHA256": sourceSnapshotDigest,
                "sourceTreeManifestSHA256":
                    sourceTreeManifestDigest,
                "buildInputManifestSHA256":
                    buildInputManifestDigest,
                "buildOutputManifestSHA256":
                    buildOutputManifestDigest,
                "bundleContentManifestSHA256":
                    bundleContentManifestDigest,
                "mainExecutableSHA256": mainExecutableDigest,
                "provenanceNodeSHA256": provenanceNodeDigest,
                "provenanceNodeCDHash": provenanceNodeCDHash,
                "provenanceNodeVersion": provenanceNodeVersion,
            ],
            options: [.sortedKeys])
        try writeSentinel(
            embeddedProvenanceData,
            to: embeddedProvenanceURL)
        let embeddedProvenanceDigest =
            sha256Hex(embeddedProvenanceData)
        let forensicStagedBundleManifestDigest =
            String(repeating: "7", count: 64)
        let forensicStagedBundleIdentityDigest =
            String(repeating: "8", count: 64)
        let receiptNonce = String(repeating: "a", count: 64)
        let receiptID = computedReceiptID(
            candidateID: candidateID,
            nonce: receiptNonce)
        let receiptFilename =
            "local-app-install-\(receiptID).txt"
        let receiptDirectory = installerRoot.appendingPathComponent(
            "receipts",
            isDirectory: true)
        let receiptPointerURL = receiptDirectory.appendingPathComponent(
            "latest-local-app-install.txt",
            isDirectory: false)
        let receiptURL = receiptDirectory.appendingPathComponent(
            receiptFilename,
            isDirectory: false)
        let infoDictionary: [String: Any] = [
            "CFBundleExecutable": "TatwoUltraworkMac",
            "CFBundleShortVersionString": "0.1.10",
            "CFBundleVersion": "24",
            TatwoChatProcessCompositionResolver.sourceCommitInfoKey:
                sourceCommit,
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey:
                sourceTree,
            TatwoChatProcessCompositionResolver.sourceDirtyInfoKey:
                sourceDirty,
            TatwoChatProcessCompositionResolver.candidateIDInfoKey:
                candidateID,
            TatwoChatProcessCompositionResolver
                .sourceSnapshotDigestInfoKey:
                sourceSnapshotDigest,
            TatwoChatProcessCompositionResolver
                .sourceTreeManifestDigestInfoKey:
                sourceTreeManifestDigest,
            TatwoChatProcessCompositionResolver
                .buildInputManifestDigestInfoKey:
                buildInputManifestDigest,
            TatwoChatProcessCompositionResolver
                .buildOutputManifestDigestInfoKey:
                buildOutputManifestDigest,
            TatwoChatProcessCompositionResolver
                .embeddedProvenanceDigestInfoKey:
                embeddedProvenanceDigest,
            TatwoChatProcessCompositionResolver
                .provenanceNodeDigestInfoKey:
                provenanceNodeDigest,
            TatwoChatProcessCompositionResolver
                .provenanceNodeCDHashInfoKey:
                provenanceNodeCDHash,
            TatwoChatProcessCompositionResolver
                .provenanceNodeVersionInfoKey:
                provenanceNodeVersion,
            TatwoChatProcessCompositionResolver.productionHelperDigestInfoKey:
                helperDigest,
            TatwoChatProcessCompositionResolver
                .bundleContentManifestDigestInfoKey:
                bundleContentManifestDigest,
            TatwoChatProcessCompositionResolver.mainExecutableDigestInfoKey:
                mainExecutableDigest,
            TatwoChatProcessCompositionResolver.buildClassInfoKey:
                TatwoChatProcessCompositionResolver
                    .localInternalBuildClass,
            TatwoChatProcessCompositionResolver.distributionReadyInfoKey:
                false,
            TatwoChatProcessCompositionResolver.automaticUpdatesInfoKey:
                false,
        ]
        let deviceID = "host-fixture"
        try writeSentinel(
            Data(#"{"deviceId":"host-fixture"}"#.utf8),
            to: appSupport.appendingPathComponent(
                "device-identity.json",
                isDirectory: false))
        let localAnchorStore =
            TatwoLocalInternalInstallAnchorFileStore(
                installerRootURL: installerRoot)
        let fixture = LocalInternalInstallFixture(
            base: base,
            bundle: bundle,
            helperURL: helperURL,
            mainExecutableURL: mainExecutableURL,
            nestedCodeURL: nestedCodeURL,
            resourceURL: resourceURL,
            bundleContentManifestURL: bundleContentManifestURL,
            embeddedProvenanceURL: embeddedProvenanceURL,
            installerRoot: installerRoot,
            receiptPointerURL: receiptPointerURL,
            receiptURL: receiptURL,
            infoDictionary: infoDictionary,
            sourceCommit: sourceCommit,
            sourceTree: sourceTree,
            sourceDirty: sourceDirty,
            candidateID: candidateID,
            sourceSnapshotDigest: sourceSnapshotDigest,
            sourceTreeManifestDigest: sourceTreeManifestDigest,
            buildInputManifestDigest: buildInputManifestDigest,
            buildOutputManifestDigest: buildOutputManifestDigest,
            bundleContentManifestDigest: bundleContentManifestDigest,
            mainExecutableDigest: mainExecutableDigest,
            embeddedProvenanceDigest: embeddedProvenanceDigest,
            provenanceNodeDigest: provenanceNodeDigest,
            provenanceNodeCDHash: provenanceNodeCDHash,
            provenanceNodeVersion: provenanceNodeVersion,
            forensicStagedBundleManifestDigest:
                forensicStagedBundleManifestDigest,
            forensicStagedBundleIdentityDigest:
                forensicStagedBundleIdentityDigest,
            receiptID: receiptID,
            receiptNonce: receiptNonce,
            receiptFilename: receiptFilename,
            deviceID: deviceID,
            localAnchorStore: localAnchorStore)
        try writeLocalInternalReceipt(
            fixture,
            signing: "ad-hoc",
            signingMode: "ad-hoc",
            signingIdentity: "-",
            distribution: "local-internal-ad-hoc")
        return fixture
    }

    private func localInternalTrust(
        _ fixture: LocalInternalInstallFixture,
        infoDictionary: [String: Any]? = nil,
        expectedSignatureTrust: TatwoProductionCodeSignatureTrust,
        localInstallAnchorProvider:
            () throws -> TatwoLocalInternalInstallAnchorV1?
    ) -> TatwoLocalInternalInstallTrust {
        TatwoChatProcessCompositionResolver.localInternalInstallTrust(
            bundleURL: fixture.bundle,
            infoDictionary: infoDictionary ?? fixture.infoDictionary,
            applicationSupportBase: fixture.base,
            expectedProductionBundleURL: fixture.bundle,
            expectedSignatureTrust: expectedSignatureTrust,
            localInstallAnchorProvider: localInstallAnchorProvider,
            bundleContentDigestProvider: {
                fileURL,
                _,
                _ in
                guard let data = try? Data(contentsOf: fileURL) else {
                    return nil
                }
                return TatwoChatProcessCompositionResolver
                    .BundleContentDigestResult(
                        sha256: self.sha256Hex(data),
                        size: UInt64(data.count))
            })
    }

    private func writeLocalInternalReceipt(
        _ fixture: LocalInternalInstallFixture,
        signing: String,
        signingMode: String,
        signingIdentity: String,
        distribution: String,
        schema: String = "TatwoLocalAppInstallReceiptV3",
        dryRun: String = "0",
        appVersion: String = "0.1.10",
        appBuild: String = "24",
        sourceCommit: String? = nil,
        sourceTree: String? = nil,
        bundleContentManifestDigest: String? = nil,
        mainExecutableDigest: String? = nil,
        embeddedProvenanceDigest: String? = nil,
        forensicStagedBundleManifestDigest: String? = nil,
        forensicStagedBundleIdentityDigest: String? = nil,
        forensicFieldSchema: String? = nil,
        receiptNonce: String? = nil,
        generatedAt: String = "2026-08-05T01:02:03Z"
    ) throws {
        let forensicFields: String
        switch forensicFieldSchema ?? schema {
        case "TatwoLocalAppInstallReceiptV2":
            forensicFields = """
                staged_bundle_manifest_sha256=\(forensicStagedBundleManifestDigest ?? fixture.forensicStagedBundleManifestDigest)
                staged_bundle_identity_sha256=\(forensicStagedBundleIdentityDigest ?? fixture.forensicStagedBundleIdentityDigest)
                """
        default:
            forensicFields = """
                forensic_staged_bundle_manifest_sha256=\(forensicStagedBundleManifestDigest ?? fixture.forensicStagedBundleManifestDigest)
                forensic_staged_bundle_identity_sha256=\(forensicStagedBundleIdentityDigest ?? fixture.forensicStagedBundleIdentityDigest)
                """
        }
        let receiptData = Data(
            """
                schema=\(schema)
                receipt_id=\(fixture.receiptID)
                receipt_nonce=\(receiptNonce ?? fixture.receiptNonce)
                receipt_filename=\(fixture.receiptFilename)
                signing=\(signing)
                signing_mode=\(signingMode)
                signing_identity=\(signingIdentity)
                force_adhoc=0
                dry_run=\(dryRun)
                app_bundle=\(fixture.bundle.path)
                app_version=\(appVersion)
                app_build=\(appBuild)
                source_commit=\(sourceCommit ?? fixture.sourceCommit)
                source_tree=\(sourceTree ?? fixture.sourceTree)
                source_dirty=\(fixture.sourceDirty ? "true" : "false")
                candidate_id=\(fixture.candidateID)
                source_snapshot_sha256=\(fixture.sourceSnapshotDigest)
                source_tree_manifest_sha256=\(fixture.sourceTreeManifestDigest)
                build_input_manifest_sha256=\(fixture.buildInputManifestDigest)
                build_output_manifest_sha256=\(fixture.buildOutputManifestDigest)
                bundle_content_manifest_sha256=\(bundleContentManifestDigest ?? fixture.bundleContentManifestDigest)
                main_executable_sha256=\(mainExecutableDigest ?? fixture.mainExecutableDigest)
                embedded_provenance_sha256=\(embeddedProvenanceDigest ?? fixture.embeddedProvenanceDigest)
                provenance_node_sha256=\(fixture.provenanceNodeDigest)
                provenance_node_cdhash=\(fixture.provenanceNodeCDHash)
                provenance_node_version=\(fixture.provenanceNodeVersion)
                \(forensicFields)
                stage_only=0
                distribution=\(distribution)
                generated_at=\(generatedAt)

                """.utf8)
        try writeSentinel(receiptData, to: fixture.receiptURL)
        let pointerData = Data(
            """
            schema=TatwoLocalAppInstallReceiptPointerV1
            receipt_id=\(fixture.receiptID)
            receipt_filename=\(fixture.receiptFilename)
            receipt_sha256=\(sha256Hex(receiptData))
            candidate_id=\(fixture.candidateID)

            """.utf8)
        try writeSentinel(
            pointerData,
            to: fixture.receiptPointerURL)
        try writeLocalInternalAnchor(fixture)
    }

    private func writeLocalInternalAnchor(
        _ fixture: LocalInternalInstallFixture
    ) throws {
        let existing = try fixture.localAnchorStore.load()
        let previousDigest: String?
        if existing != nil {
            previousDigest = sha256Hex(
                try Data(contentsOf: fixture.localAnchorStore.url))
        } else {
            previousDigest = nil
        }
        let receiptData = try Data(contentsOf: fixture.receiptURL)
        let pointerData = try Data(contentsOf: fixture.receiptPointerURL)
        let anchor = TatwoLocalInternalInstallAnchorV1(
            candidateID: fixture.candidateID,
            receiptID: fixture.receiptID,
            receiptFilename: fixture.receiptFilename,
            receiptSHA256: sha256Hex(receiptData),
            pointerSHA256: sha256Hex(pointerData),
            canonicalAppPath: fixture.bundle.standardizedFileURL.path,
            canonicalStateRoot:
                TatwoProductionLayoutLock.osNativeStateRoot(
                    applicationSupportBase: fixture.base).path,
            deviceID: fixture.deviceID,
            installGeneration: (existing?.installGeneration ?? 0) + 1,
            previousAnchorSHA256: previousDigest,
            createdAt: "2026-08-05T01:02:03Z")
        try fixture.localAnchorStore.save(anchor)
    }

    private func makeBundleContentManifestData(
        mainExecutableData: Data,
        nestedCodeData: Data,
        helperData: Data,
        resourceData: Data
    ) throws -> Data {
        let mainDigest = sha256Hex(mainExecutableData)
        let entries: [[String: Any]] = [
            [
                "path":
                    "Contents/Frameworks/Nested.framework/Versions/A/Nested",
                "type": "file",
                "mode": "100755",
                "sha256": sha256Hex(nestedCodeData),
                "size": nestedCodeData.count,
                "digestMode": "macho-adhoc-resign-strip-v1",
            ],
            [
                "path": "Contents/Helpers/TatwoPLGAnchorHelper",
                "type": "file",
                "mode": "100755",
                "sha256": sha256Hex(helperData),
                "size": helperData.count,
                "digestMode": "macho-adhoc-resign-strip-v1",
            ],
            [
                "path": "Contents/MacOS/TatwoUltraworkMac",
                "type": "file",
                "mode": "100755",
                "sha256": mainDigest,
                "size": mainExecutableData.count,
                "digestMode": "macho-adhoc-resign-strip-v1",
            ],
            [
                "path": "Contents/Resources/base.txt",
                "type": "file",
                "mode": "100644",
                "sha256": sha256Hex(resourceData),
                "size": resourceData.count,
                "digestMode": "raw-sha256",
            ],
        ]
        let payload: [String: Any] = [
            "schema": "TatwoBundleContentManifestV1",
            "exclusions": [
                "Contents/Info.plist",
                "Contents/_CodeSignature/**",
                TatwoChatProcessCompositionResolver
                    .bundleContentManifestRelativePath,
                "Contents/Resources/TatwoCandidateProvenance.json",
            ],
            "mainExecutable": [
                "path": "Contents/MacOS/TatwoUltraworkMac",
                "sha256": mainDigest,
                "digestMode": "macho-adhoc-resign-strip-v1",
            ],
            "entries": entries,
        ]
        var data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func computedCandidateID(
        sourceCommit: String,
        sourceTree: String,
        sourceSnapshotDigest: String,
        sourceTreeManifestDigest: String,
        buildInputManifestDigest: String,
        buildOutputManifestDigest: String,
        bundleContentManifestDigest: String,
        mainExecutableDigest: String,
        provenanceNodeDigest: String,
        provenanceNodeCDHash: String,
        provenanceNodeVersion: String,
        appVersion: String,
        appBuild: String
    ) -> String {
        let payload = [
            sourceCommit,
            sourceTree,
            sourceSnapshotDigest,
            sourceTreeManifestDigest,
            buildInputManifestDigest,
            buildOutputManifestDigest,
            bundleContentManifestDigest,
            mainExecutableDigest,
            provenanceNodeDigest,
            provenanceNodeCDHash,
            provenanceNodeVersion,
            appVersion,
            appBuild,
        ].joined(separator: "\n") + "\n"
        return sha256Hex(Data(payload.utf8))
    }

    private func computedReceiptID(
        candidateID: String,
        nonce: String
    ) -> String {
        sha256Hex(Data("\(candidateID)\n\(nonce)\n".utf8))
    }

    private func writeSentinel(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func writeGoalRun(
        _ goal: TatwoStoredGoalRun,
        to store: TatwoGoalRunStore
    ) throws {
        let directory = store.directoryURL
            .appendingPathComponent("goals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(goal).write(
            to: directory.appendingPathComponent("\(goal.contractID).json"),
            options: .atomic)
    }

    @MainActor
    private func waitForInitialStoreLoad(
        _ model: ChatPageModel
    ) async throws {
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        _ condition: () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for production remote dispatch")
    }

}

private struct CoreManifestTrustFixture {
    let payload: CoreManifestUnsignedPayload
    let manifest: TatwoRemoteDispatchReadinessManifestV1
    let originTrust: TatwoLoopJobChannelTrust
    let targetTrust: TatwoLoopJobChannelTrust
}

private struct CoreManifestUnsignedPayload: Encodable {
    let schema = TatwoRemoteDispatchReadinessManifestV1.schemaName
    let targetDeviceID: String
    let targetKeyID: String
    let targetKeyGeneration: UInt64
    let registryGeneration: UInt64
    let workspaceBindingID: String
    let workspaceBindingDigest: String
    let requestedAgent: String
    let exactModelRouteID: String
    let agentModelCapabilityDigest: String
    let activeSkillSetDigest: String
    let issuedAt: Date
    let expiresAt: Date

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func manifest(
        targetSignature: TatwoDeviceSignatureV1
    ) -> TatwoRemoteDispatchReadinessManifestV1 {
        TatwoRemoteDispatchReadinessManifestV1(
            targetDeviceID: targetDeviceID,
            targetKeyID: targetKeyID,
            targetKeyGeneration: targetKeyGeneration,
            registryGeneration: registryGeneration,
            workspaceBindingID: workspaceBindingID,
            workspaceBindingDigest: workspaceBindingDigest,
            requestedAgent: requestedAgent,
            exactModelRouteID: exactModelRouteID,
            agentModelCapabilityDigest: agentModelCapabilityDigest,
            activeSkillSetDigest: activeSkillSetDigest,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            targetSignature: targetSignature)
    }
}

private final class CoreManifestMemoryKeyStore:
    TatwoDevicePrivateKeyStore,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func loadPrivateKey(
        deviceID: String,
        generation: UInt64
    ) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys["\(deviceID)#\(generation)"]
    }

    func storePrivateKey(
        _ key: Data,
        deviceID: String,
        generation: UInt64
    ) throws {
        guard key.count == 32 else {
            throw TatwoDeviceTrustError.invalidPrivateKey
        }
        lock.lock()
        defer { lock.unlock() }
        let account = "\(deviceID)#\(generation)"
        if let existing = keys[account], existing != key {
            throw TatwoDeviceTrustError.duplicatePrivateKeyMismatch
        }
        keys[account] = key
    }
}

private struct LocalInternalInstallFixture {
    let base: URL
    let bundle: URL
    let helperURL: URL
    let mainExecutableURL: URL
    let nestedCodeURL: URL
    let resourceURL: URL
    let bundleContentManifestURL: URL
    let embeddedProvenanceURL: URL
    let installerRoot: URL
    let receiptPointerURL: URL
    let receiptURL: URL
    let infoDictionary: [String: Any]
    let sourceCommit: String
    let sourceTree: String
    let sourceDirty: Bool
    let candidateID: String
    let sourceSnapshotDigest: String
    let sourceTreeManifestDigest: String
    let buildInputManifestDigest: String
    let buildOutputManifestDigest: String
    let bundleContentManifestDigest: String
    let mainExecutableDigest: String
    let embeddedProvenanceDigest: String
    let provenanceNodeDigest: String
    let provenanceNodeCDHash: String
    let provenanceNodeVersion: String
    let forensicStagedBundleManifestDigest: String
    let forensicStagedBundleIdentityDigest: String
    let receiptID: String
    let receiptNonce: String
    let receiptFilename: String
    let deviceID: String
    let localAnchorStore: TatwoLocalInternalInstallAnchorFileStore
}

private struct StaticProductionMaterialProvider:
    ChatProductionRemoteDispatchMaterialProviding
{
    let material: ChatProductionRemoteDispatchMaterial

    func material(
        for request: ChatRemoteTurnDispatchRequest,
        now: Date
    ) throws -> ChatProductionRemoteDispatchMaterial {
        ChatProductionRemoteDispatchMaterial(
            originDeviceID: material.originDeviceID,
            currentOriginLease: material.currentOriginLease,
            contractMode: material.contractMode,
            targetReadinessManifest: material.targetReadinessManifest,
            readinessBinding: material.targetReadinessManifest.binding(
                challengeNonce: request.readinessChallengeNonce))
    }
}

private struct ThrowingProductionMaterialProvider:
    ChatProductionRemoteDispatchMaterialProviding
{
    let error: ChatProductionRemoteTurnDispatcherError

    func material(
        for request: ChatRemoteTurnDispatchRequest,
        now: Date
    ) throws -> ChatProductionRemoteDispatchMaterial {
        throw error
    }
}

private final class ProductionJobCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedJobs: [TatwoLoopJobV1] = []

    var jobs: [TatwoLoopJobV1] {
        lock.lock()
        defer { lock.unlock() }
        return storedJobs
    }

    func append(_ job: TatwoLoopJobV1) {
        lock.lock()
        storedJobs.append(job)
        lock.unlock()
    }
}
