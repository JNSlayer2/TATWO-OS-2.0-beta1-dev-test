import CryptoKit
import Foundation
import XCTest

@testable import TatwoUltraworkMac
import TatwoUltraworkCore

final class ChatProcessCompositionIsolationTests: XCTestCase {
    func testProductionRequirementPinsAppleDeveloperIDTeamAndBundle() {
        let requirement =
            TatwoChatProcessCompositionResolver.productionDesignatedRequirement
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(
            requirement.contains(
                "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        XCTAssertTrue(
            requirement.contains(
                "certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        XCTAssertTrue(
            requirement.contains(
                "certificate leaf[subject.OU] = \"W47594XKQC\""))
        XCTAssertTrue(
            requirement.contains(
                "identifier \"\(TatwoRuntimeLayout.bundleIdentifier)\""))
    }

    func testExactProductionBundleUsesOSNativeRootsAndRejectsLayoutInfluence() {
        let base = temporaryDirectory("production-base")
        var signatureTrustCalls = 0
        let expectedState = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [
                TatwoProductionLayoutLock.appSupportEnvKey:
                    "/tmp/forbidden-production-app-support",
                TatwoProductionLayoutLock.stateDirEnvKey:
                    "/tmp/forbidden-production-state",
            ],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: productionInfoDictionary(),
            bundleURL: URL(
                fileURLWithPath:
                    "/Applications/Tatwo Ultrawork.app",
                isDirectory: true),
            productionSignatureTrustProvider: { _ in
                signatureTrustCalls += 1
                return .trusted
            },
            productionPromotionTrustProvider: {
                _, _, _, _ in .trusted
            },
            applicationSupportBase: base)

        XCTAssertEqual(signatureTrustCalls, 1)
        XCTAssertEqual(composition.processClass, .production)
        XCTAssertEqual(composition.stateRootURL, expectedState)
        XCTAssertEqual(
            composition.runnerAuthority.rootURL,
            expectedState.appendingPathComponent(
                "chat-runner-authority-v1",
                isDirectory: true))
        XCTAssertEqual(
            composition.remoteBorrowAuthorizationStore.rootURL,
            expectedState.appendingPathComponent(
                "remote-execution-authorization",
                isDirectory: true))
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatProductionRemoteTurnDispatcher)
    }

    func testCurrentAdHocWithTrustedLocalInstallUsesNativeDataWithoutProductionAuthority() {
        let base = temporaryDirectory("current-adhoc-local-internal")
        var localTrustCalls = 0
        var productionRunnerFactoryCalls = 0
        var productionAuthorizationFactoryCalls = 0
        var productionDispatcherFactoryCalls = 0
        let expectedState = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let expectedAppSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: base)
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: localInternalInfoDictionary(
                helperDigest: String(repeating: "a", count: 64)),
            bundleURL:
                TatwoChatProcessCompositionResolver
                    .canonicalProductionBundleURL,
            productionSignatureTrustProvider: { _ in .currentAdHoc },
            localInternalInstallTrustProvider: { _, _, _, _, trust in
                localTrustCalls += 1
                XCTAssertEqual(trust, .currentAdHoc)
                return .trusted
            },
            applicationSupportBase: base,
            productionRunnerAuthorityFactory: { stateRoot in
                productionRunnerFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionAuthorizationStoreFactory: { stateRoot in
                productionAuthorizationFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionRemoteDispatcherFactory: {
                productionDispatcherFactoryCalls += 1
                return ChatUnavailableRemoteTurnDispatcher()
            })

        XCTAssertEqual(localTrustCalls, 1)
        XCTAssertEqual(composition.processClass, .localInternal)
        XCTAssertEqual(composition.stateRootURL, expectedState)
        XCTAssertEqual(
            composition.storage.applicationSupportRootURL,
            expectedAppSupport)
        XCTAssertEqual(
            composition.runnerAuthority.rootURL,
            expectedState.appendingPathComponent(
                "chat-runner-authority-local-internal-v1",
                isDirectory: true))
        XCTAssertEqual(
            composition.remoteBorrowAuthorizationStore.rootURL,
            expectedState.appendingPathComponent(
                "remote-execution-authorization-local-internal",
                isDirectory: true))
        XCTAssertEqual(productionRunnerFactoryCalls, 0)
        XCTAssertEqual(productionAuthorizationFactoryCalls, 0)
        XCTAssertEqual(productionDispatcherFactoryCalls, 0)
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
        XCTAssertEqual(
            composition.remoteTurnDispatcher.dispatch(makeRequest()),
            .blocked(.adapterUnavailable))
    }

    func testCurrentAdHocWithRejectedOrUnknownInstallEvidenceFailsClosed() {
        for trust in [
            TatwoLocalInternalInstallTrust.rejected,
            .unknown,
        ] {
            var productionFactoryCalls = 0
            let composition = TatwoChatProcessCompositionResolver.resolve(
                environment: [:],
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: localInternalInfoDictionary(
                    helperDigest: String(repeating: "a", count: 64)),
                bundleURL:
                    TatwoChatProcessCompositionResolver
                        .canonicalProductionBundleURL,
                productionSignatureTrustProvider: { _ in .currentAdHoc },
                localInternalInstallTrustProvider: { _, _, _, _, _ in trust },
                applicationSupportBase: temporaryDirectory(
                    "adhoc-\(trust)"),
                productionRemoteDispatcherFactory: {
                    productionFactoryCalls += 1
                    return ChatUnavailableRemoteTurnDispatcher()
                })

            XCTAssertEqual(composition.processClass, .isolated)
            XCTAssertEqual(productionFactoryCalls, 0)
            XCTAssertTrue(
                composition.remoteTurnDispatcher
                    is ChatUnavailableRemoteTurnDispatcher)
        }
    }

    func testDeveloperIDSignedLocalInternalStillRequiresTrustedInstallEvidence() {
        for installTrust in [
            TatwoLocalInternalInstallTrust.trusted,
            .rejected,
        ] {
            var localTrustCalls = 0
            var productionRunnerFactoryCalls = 0
            var productionAuthorizationFactoryCalls = 0
            var productionDispatcherFactoryCalls = 0
            let composition = TatwoChatProcessCompositionResolver.resolve(
                environment: [:],
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: localInternalInfoDictionary(
                    helperDigest: String(repeating: "a", count: 64)),
                bundleURL:
                    TatwoChatProcessCompositionResolver
                        .canonicalProductionBundleURL,
                productionSignatureTrustProvider: { _ in .trusted },
                localInternalInstallTrustProvider: {
                    _, _, _, _, signatureTrust in
                    localTrustCalls += 1
                    XCTAssertEqual(signatureTrust, .trusted)
                    return installTrust
                },
                applicationSupportBase: temporaryDirectory(
                    "developer-id-local-\(installTrust)"),
                productionRunnerAuthorityFactory: { stateRoot in
                    productionRunnerFactoryCalls += 1
                    return .production(stateRoot: stateRoot)
                },
                productionAuthorizationStoreFactory: { stateRoot in
                    productionAuthorizationFactoryCalls += 1
                    return .production(stateRoot: stateRoot)
                },
                productionRemoteDispatcherFactory: {
                    productionDispatcherFactoryCalls += 1
                    return ChatUnavailableRemoteTurnDispatcher()
                })

            XCTAssertEqual(localTrustCalls, 1)
            XCTAssertEqual(
                composition.processClass,
                installTrust == .trusted ? .localInternal : .isolated)
            XCTAssertEqual(productionRunnerFactoryCalls, 0)
            XCTAssertEqual(productionAuthorizationFactoryCalls, 0)
            XCTAssertEqual(productionDispatcherFactoryCalls, 0)
            XCTAssertTrue(
                composition.remoteTurnDispatcher
                    is ChatUnavailableRemoteTurnDispatcher)
        }
    }

    func testCurrentAdHocInstallReceiptAndAnchorMustMatchBundle() throws {
        let base = temporaryDirectory("current-adhoc-evidence")
        let expectedBundle = base.appendingPathComponent(
            "Applications/Tatwo Ultrawork.app",
            isDirectory: true)
        let helperURL = expectedBundle.appendingPathComponent(
            "Contents/Helpers/TatwoPLGAnchorHelper")
        let helperData = Data("trusted-helper".utf8)
        try writeSentinel(
            String(decoding: helperData, as: UTF8.self),
            to: helperURL)
        let helperDigest = SHA256.hash(data: helperData)
            .map { String(format: "%02x", $0) }
            .joined()
        var info = localInternalInfoDictionary(
            helperDigest: helperDigest)
        let mainExecutableURL = expectedBundle.appendingPathComponent(
            "Contents/MacOS/TatwoUltraworkMac",
            isDirectory: false)
        let mainExecutableData = Data("trusted-main".utf8)
        try writeSentinel(
            String(decoding: mainExecutableData, as: UTF8.self),
            to: mainExecutableURL)
        let mainExecutableDigest = SHA256.hash(data: mainExecutableData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifestURL = expectedBundle.appendingPathComponent(
            TatwoChatProcessCompositionResolver
                .bundleContentManifestRelativePath,
            isDirectory: false)
        var manifestData = try JSONSerialization.data(
            withJSONObject: [
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
                    "sha256": mainExecutableDigest,
                    "digestMode": "macho-adhoc-resign-strip-v1",
                ],
                "entries": [
                    [
                        "path": "Contents/Helpers/TatwoPLGAnchorHelper",
                        "type": "file",
                        "mode": "100644",
                        "sha256": helperDigest,
                        "size": helperData.count,
                        "digestMode": "raw-sha256",
                    ],
                    [
                        "path": "Contents/MacOS/TatwoUltraworkMac",
                        "type": "file",
                        "mode": "100644",
                        "sha256": mainExecutableDigest,
                        "size": mainExecutableData.count,
                        "digestMode": "macho-adhoc-resign-strip-v1",
                    ],
                ],
            ],
            options: [.sortedKeys])
        manifestData.append(0x0a)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try manifestData.write(to: manifestURL, options: .atomic)
        let manifestDigest = SHA256.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
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
            bundleContentManifestDigest: manifestDigest,
            mainExecutableDigest: mainExecutableDigest,
            provenanceNodeDigest: provenanceNodeDigest,
            provenanceNodeCDHash: provenanceNodeCDHash,
            provenanceNodeVersion: provenanceNodeVersion,
            appVersion: "0.1.10",
            appBuild: "24")
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
                "bundleContentManifestSHA256": manifestDigest,
                "mainExecutableSHA256": mainExecutableDigest,
                "provenanceNodeSHA256": provenanceNodeDigest,
                "provenanceNodeCDHash": provenanceNodeCDHash,
                "provenanceNodeVersion": provenanceNodeVersion,
            ],
            options: [.sortedKeys])
        let embeddedProvenanceURL = expectedBundle
            .appendingPathComponent(
                "Contents/Resources/TatwoCandidateProvenance.json",
                isDirectory: false)
        try FileManager.default.createDirectory(
            at: embeddedProvenanceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try embeddedProvenanceData.write(
            to: embeddedProvenanceURL,
            options: .atomic)
        let embeddedProvenanceDigest =
            sha256Hex(embeddedProvenanceData)
        info[
            TatwoChatProcessCompositionResolver
                .bundleContentManifestDigestInfoKey
        ] = manifestDigest
        info[
            TatwoChatProcessCompositionResolver.mainExecutableDigestInfoKey
        ] = mainExecutableDigest
        info[
            TatwoChatProcessCompositionResolver.candidateIDInfoKey
        ] = candidateID
        info[
            TatwoChatProcessCompositionResolver.sourceDirtyInfoKey
        ] = sourceDirty
        info[
            TatwoChatProcessCompositionResolver
                .sourceSnapshotDigestInfoKey
        ] = sourceSnapshotDigest
        info[
            TatwoChatProcessCompositionResolver
                .sourceTreeManifestDigestInfoKey
        ] = sourceTreeManifestDigest
        info[
            TatwoChatProcessCompositionResolver
                .buildInputManifestDigestInfoKey
        ] = buildInputManifestDigest
        info[
            TatwoChatProcessCompositionResolver
                .buildOutputManifestDigestInfoKey
        ] = buildOutputManifestDigest
        info[
            TatwoChatProcessCompositionResolver
                .embeddedProvenanceDigestInfoKey
        ] = embeddedProvenanceDigest
        info[
            TatwoChatProcessCompositionResolver
                .provenanceNodeDigestInfoKey
        ] = provenanceNodeDigest
        info[
            TatwoChatProcessCompositionResolver
                .provenanceNodeCDHashInfoKey
        ] = provenanceNodeCDHash
        info[
            TatwoChatProcessCompositionResolver
                .provenanceNodeVersionInfoKey
        ] = provenanceNodeVersion
        let rawDigestProvider:
            TatwoChatProcessCompositionResolver.BundleContentDigestProvider = {
                url,
                _,
                _ in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return TatwoChatProcessCompositionResolver
                    .BundleContentDigestResult(
                        sha256: SHA256.hash(data: data)
                            .map { String(format: "%02x", $0) }
                            .joined(),
                        size: UInt64(data.count))
            }
        let appSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: base)
        let stateRoot =
            TatwoProductionLayoutLock.osNativeStateRoot(
                applicationSupportBase: base)
        let installerRoot = appSupport.appendingPathComponent(
            "local-app-install",
            isDirectory: true)
        let deviceID = "host-fixture"
        try writeSentinel(
            #"{"deviceId":"host-fixture"}"#,
            to: appSupport.appendingPathComponent(
                "device-identity.json",
                isDirectory: false))
        let localAnchorStore =
            TatwoLocalInternalInstallAnchorFileStore(
                installerRootURL: installerRoot)
        let receiptNonce = String(repeating: "a", count: 64)
        let receiptID = computedReceiptID(
            candidateID: candidateID,
            nonce: receiptNonce)
        let receiptFilename =
            "local-app-install-\(receiptID).txt"
        let receiptDirectory = installerRoot
            .appendingPathComponent("receipts", isDirectory: true)
        let receiptURL = receiptDirectory.appendingPathComponent(
            receiptFilename,
            isDirectory: false)
        let receiptPointerURL = receiptDirectory
            .appendingPathComponent(
                "latest-local-app-install.txt",
                isDirectory: false)
        let stagedBundleManifestDigest =
            String(repeating: "7", count: 64)
        let stagedBundleIdentityDigest =
            String(repeating: "8", count: 64)
        func writeBoundReceipt(
            signing: String,
            signingMode: String,
            signingIdentity: String,
            distribution: String
        ) throws {
            let receipt = """
                schema=TatwoLocalAppInstallReceiptV2
                receipt_id=\(receiptID)
                receipt_nonce=\(receiptNonce)
                receipt_filename=\(receiptFilename)
                signing=\(signing)
                signing_mode=\(signingMode)
                signing_identity=\(signingIdentity)
                force_adhoc=0
                dry_run=0
                app_bundle=\(expectedBundle.path)
                app_version=0.1.10
                app_build=24
                source_commit=\(sourceCommit)
                source_tree=\(sourceTree)
                source_dirty=false
                candidate_id=\(candidateID)
                source_snapshot_sha256=\(sourceSnapshotDigest)
                source_tree_manifest_sha256=\(sourceTreeManifestDigest)
                build_input_manifest_sha256=\(buildInputManifestDigest)
                build_output_manifest_sha256=\(buildOutputManifestDigest)
                bundle_content_manifest_sha256=\(manifestDigest)
                main_executable_sha256=\(mainExecutableDigest)
                embedded_provenance_sha256=\(embeddedProvenanceDigest)
                provenance_node_sha256=\(provenanceNodeDigest)
                provenance_node_cdhash=\(provenanceNodeCDHash)
                provenance_node_version=\(provenanceNodeVersion)
                staged_bundle_manifest_sha256=\(stagedBundleManifestDigest)
                staged_bundle_identity_sha256=\(stagedBundleIdentityDigest)
                stage_only=0
                distribution=\(distribution)
                generated_at=2026-08-04T17:35:46Z

                """
            try writeSentinel(receipt, to: receiptURL)
            let receiptDigest = sha256Hex(Data(receipt.utf8))
            let pointer = """
                schema=TatwoLocalAppInstallReceiptPointerV1
                receipt_id=\(receiptID)
                receipt_filename=\(receiptFilename)
                receipt_sha256=\(receiptDigest)
                candidate_id=\(candidateID)

                """
            try writeSentinel(
                pointer,
                to: receiptPointerURL)
            let previousAnchor = try localAnchorStore.load()
            let previousAnchorDigest: String?
            if previousAnchor != nil {
                previousAnchorDigest = sha256Hex(
                    try Data(contentsOf: localAnchorStore.url))
            } else {
                previousAnchorDigest = nil
            }
            try localAnchorStore.save(
                TatwoLocalInternalInstallAnchorV1(
                    candidateID: candidateID,
                    receiptID: receiptID,
                    receiptFilename: receiptFilename,
                    receiptSHA256: receiptDigest,
                    pointerSHA256: sha256Hex(Data(pointer.utf8)),
                    canonicalAppPath:
                        expectedBundle.standardizedFileURL.path,
                    canonicalStateRoot:
                        stateRoot.standardizedFileURL.path,
                    deviceID: deviceID,
                    installGeneration:
                        (previousAnchor?.installGeneration ?? 0) + 1,
                    previousAnchorSHA256: previousAnchorDigest,
                    createdAt: "2026-08-04T17:35:46Z"))
        }
        try writeBoundReceipt(
            signing: "ad-hoc",
            signingMode: "ad-hoc",
            signingIdentity: "-",
            distribution: "local-internal-ad-hoc")

        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: {
                    try localAnchorStore.load()
                },
                bundleContentDigestProvider: rawDigestProvider),
            .trusted)

        let developerIDIdentity =
            "Developer ID Application: TATWO (W47594XKQC)"
        try writeBoundReceipt(
            signing: "developer-id \(developerIDIdentity)",
            signingMode: "developer-id",
            signingIdentity: developerIDIdentity,
            distribution: "local-internal-developer-id")
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: {
                    try localAnchorStore.load()
                },
                bundleContentDigestProvider: rawDigestProvider),
            .trusted)
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .currentAdHoc,
                localInstallAnchorProvider: {
                    try localAnchorStore.load()
                },
                bundleContentDigestProvider: rawDigestProvider),
            .rejected)

        let anchor = try XCTUnwrap(localAnchorStore.load())
        let mismatchedStateAnchor =
            TatwoLocalInternalInstallAnchorV1(
                candidateID: anchor.candidateID,
                receiptID: anchor.receiptID,
                receiptFilename: anchor.receiptFilename,
                receiptSHA256: anchor.receiptSHA256,
                pointerSHA256: anchor.pointerSHA256,
                canonicalAppPath: anchor.canonicalAppPath,
                canonicalStateRoot: base.appendingPathComponent(
                    "wrong-state",
                    isDirectory: true).path,
                deviceID: anchor.deviceID,
                installGeneration: anchor.installGeneration,
                previousAnchorSHA256:
                    anchor.previousAnchorSHA256,
                createdAt: anchor.createdAt)
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: {
                    mismatchedStateAnchor
                },
                bundleContentDigestProvider: rawDigestProvider),
            .rejected)

        try writeSentinel(
            #"{"deviceId":"different-device"}"#,
            to: appSupport.appendingPathComponent(
                "device-identity.json",
                isDirectory: false))
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: { anchor },
                bundleContentDigestProvider: rawDigestProvider),
            .rejected)
        try writeSentinel(
            #"{"deviceId":"host-fixture"}"#,
            to: appSupport.appendingPathComponent(
                "device-identity.json",
                isDirectory: false))

        let foreignDeveloperIDIdentity =
            "Developer ID Application: Foreign (FOREIGN123)"
        try writeBoundReceipt(
            signing: "developer-id \(foreignDeveloperIDIdentity)",
            signingMode: "developer-id",
            signingIdentity: foreignDeveloperIDIdentity,
            distribution: "local-internal-developer-id")
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: info,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: {
                    try localAnchorStore.load()
                },
                bundleContentDigestProvider: rawDigestProvider),
            .rejected)

        try writeBoundReceipt(
            signing: "developer-id \(developerIDIdentity)",
            signingMode: "developer-id",
            signingIdentity: developerIDIdentity,
            distribution: "local-internal-developer-id")
        var mismatched = info
        mismatched[
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey
        ] = String(repeating: "0", count: 40)
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.localInternalInstallTrust(
                bundleURL: expectedBundle,
                infoDictionary: mismatched,
                applicationSupportBase: base,
                expectedProductionBundleURL: expectedBundle,
                expectedSignatureTrust: .trusted,
                localInstallAnchorProvider: {
                    try localAnchorStore.load()
                },
                bundleContentDigestProvider: rawDigestProvider),
            .rejected)
    }

    func testExactBundleWithoutProductionBuildMarkersFailsClosedIsolated() {
        let base = temporaryDirectory("missing-production-markers")
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: [
                "CFBundleExecutable": "TatwoUltraworkMac",
                "TatwoSourceCommit":
                    "0123456789abcdef0123456789abcdef01234567",
            ],
            bundleURL: URL(
                fileURLWithPath:
                    "/Applications/Tatwo Ultrawork.app",
                isDirectory: true),
            applicationSupportBase: base)

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
    }

    func testTrustedSignatureFailsClosedForMissingMalformedOrMixedBuildMarkers() {
        let sourceTreeKey =
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey
        let buildClassKey =
            TatwoChatProcessCompositionResolver.buildClassInfoKey
        let distributionKey =
            TatwoChatProcessCompositionResolver.distributionReadyInfoKey
        let updatesKey =
            TatwoChatProcessCompositionResolver.automaticUpdatesInfoKey
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("missing-source-tree", { $0.removeValue(forKey: sourceTreeKey) }),
            ("malformed-source-tree", {
                $0[sourceTreeKey] = String(repeating: "g", count: 40)
            }),
            ("whitespace-padded-source-tree", {
                $0[sourceTreeKey] =
                    " 89abcdef0123456789abcdef0123456789abcdef "
            }),
            ("missing-build-class", {
                $0.removeValue(forKey: buildClassKey)
            }),
            ("unknown-build-class", {
                $0[buildClassKey] = "release"
            }),
            ("missing-distribution-ready", {
                $0.removeValue(forKey: distributionKey)
            }),
            ("string-distribution-ready", {
                $0[distributionKey] = "true"
            }),
            ("integer-distribution-ready", {
                $0[distributionKey] = 1
            }),
            ("production-intent-claims-distribution-ready", {
                $0[distributionKey] = true
            }),
            ("missing-automatic-updates", {
                $0.removeValue(forKey: updatesKey)
            }),
            ("string-automatic-updates", {
                $0[updatesKey] = "true"
            }),
            ("integer-automatic-updates", {
                $0[updatesKey] = 1
            }),
            ("production-intent-claims-updates-enabled", {
                $0[updatesKey] = true
            }),
            ("mixed-local-internal-markers", {
                $0[buildClassKey] =
                    TatwoChatProcessCompositionResolver
                        .localInternalBuildClass
                $0[distributionKey] = false
                $0[updatesKey] = true
            }),
        ]

        for (label, mutate) in cases {
            var info = productionInfoDictionary()
            mutate(&info)
            var signatureTrustCalls = 0
            var localTrustCalls = 0
            let composition = TatwoChatProcessCompositionResolver.resolve(
                environment: [:],
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: info,
                bundleURL:
                    TatwoChatProcessCompositionResolver
                        .canonicalProductionBundleURL,
                productionSignatureTrustProvider: { _ in
                    signatureTrustCalls += 1
                    return .trusted
                },
                localInternalInstallTrustProvider: {
                    _, _, _, _, _ in
                    localTrustCalls += 1
                    return .trusted
                },
                applicationSupportBase: temporaryDirectory(label))

            XCTAssertEqual(
                composition.processClass,
                .isolated,
                label)
            XCTAssertEqual(
                signatureTrustCalls,
                0,
                "\(label) must fail before signature trust.")
            XCTAssertEqual(
                localTrustCalls,
                0,
                "\(label) must not inspect production install material.")
        }
    }

    func testFormalProductionMarkersRejectAdHocSignatureWithoutLocalFallback() {
        var localTrustCalls = 0
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: productionInfoDictionary(),
            bundleURL:
                TatwoChatProcessCompositionResolver
                    .canonicalProductionBundleURL,
            productionSignatureTrustProvider: { _ in .currentAdHoc },
            localInternalInstallTrustProvider: {
                _, _, _, _, _ in
                localTrustCalls += 1
                return .trusted
            },
            applicationSupportBase: temporaryDirectory(
                "formal-production-adhoc"))

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertEqual(localTrustCalls, 0)
    }

    func testProductionMarkersOutsideCanonicalBundlePathFailClosedIsolated() {
        let base = temporaryDirectory("noncanonical-production-path")
        var signatureTrustCalls = 0
        var productionMaterialFactoryCalls = 0
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: productionInfoDictionary(),
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork.app",
                isDirectory: true),
            productionSignatureTrustProvider: { _ in
                signatureTrustCalls += 1
                return .trusted
            },
            applicationSupportBase: base,
            productionRemoteDispatcherFactory: {
                productionMaterialFactoryCalls += 1
                return ChatUnavailableRemoteTurnDispatcher()
            })

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertEqual(
            signatureTrustCalls,
            0,
            "Noncanonical paths must fail before code-signature evaluation.")
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
        XCTAssertEqual(
            productionMaterialFactoryCalls,
            0,
            "A noncanonical App path must not construct production Keychain-backed material.")
    }

    func testSymlinkAtExpectedProductionPathFailsClosedBeforeSignatureTrust() throws {
        let base = temporaryDirectory("symlink-production-path")
        let realBundle = base.appendingPathComponent(
            "real/Tatwo Ultrawork.app",
            isDirectory: true)
        let expectedBundle = base.appendingPathComponent(
            "Applications/Tatwo Ultrawork.app",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: realBundle,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: expectedBundle.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: expectedBundle,
            withDestinationURL: realBundle)
        var signatureTrustCalls = 0

        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: productionInfoDictionary(),
            bundleURL: expectedBundle,
            expectedProductionBundleURL: expectedBundle,
            productionSignatureTrustProvider: { _ in
                signatureTrustCalls += 1
                return .trusted
            },
            applicationSupportBase: base)

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertEqual(signatureTrustCalls, 0)
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
    }

    func testRejectedOrUnknownProductionSignatureFailsClosedIsolated() {
        for trust in [
            TatwoProductionCodeSignatureTrust.rejected,
            .unknown,
        ] {
            let base = temporaryDirectory("signature-\(trust)")
            var productionRunnerFactoryCalls = 0
            var productionAuthorizationFactoryCalls = 0
            var productionDispatcherFactoryCalls = 0
            let composition = TatwoChatProcessCompositionResolver.resolve(
                environment: [:],
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: productionInfoDictionary(),
                bundleURL:
                    TatwoChatProcessCompositionResolver
                        .canonicalProductionBundleURL,
                productionSignatureTrustProvider: { _ in trust },
                applicationSupportBase: base,
                productionRunnerAuthorityFactory: { stateRoot in
                    productionRunnerFactoryCalls += 1
                    return .production(stateRoot: stateRoot)
                },
                productionAuthorizationStoreFactory: { stateRoot in
                    productionAuthorizationFactoryCalls += 1
                    return .production(stateRoot: stateRoot)
                },
                productionRemoteDispatcherFactory: {
                    productionDispatcherFactoryCalls += 1
                    return ChatUnavailableRemoteTurnDispatcher()
                })

            XCTAssertEqual(composition.processClass, .isolated)
            XCTAssertEqual(productionRunnerFactoryCalls, 0)
            XCTAssertEqual(productionAuthorizationFactoryCalls, 0)
            XCTAssertEqual(productionDispatcherFactoryCalls, 0)
            XCTAssertTrue(
                composition.remoteTurnDispatcher
                    is ChatUnavailableRemoteTurnDispatcher)
        }
    }

    func testStagingMarkerUsesExplicitIsolatedRootsAndUnavailableDispatcher() {
        let base = temporaryDirectory("staging-base")
        let stagingState = base.appendingPathComponent(
            "staging-state",
            isDirectory: true)
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [
                TatwoProductionLayoutLock.stateDirEnvKey: stagingState.path,
            ],
            bundleIdentifier: "com.tatwo.ultrawork.staging.fixture",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base)

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertEqual(composition.stateRootURL, stagingState)
        XCTAssertEqual(
            composition.runnerAuthority.rootURL,
            stagingState.appendingPathComponent(
                "chat-runner-authority-v1",
                isDirectory: true))
        XCTAssertEqual(
            composition.remoteBorrowAuthorizationStore.rootURL,
            stagingState.appendingPathComponent(
                "remote-execution-authorization",
                isDirectory: true))
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
        XCTAssertEqual(
            composition.remoteTurnDispatcher.dispatch(makeRequest()),
            .blocked(.adapterUnavailable))
    }

    @MainActor
    func testFinderStagingWithZeroTatwoEnvironmentKeepsAllChatStoresIsolated()
        async throws
    {
        let base = temporaryDirectory("finder-zero-env")
        let productionAppSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: base)
        let productionState =
            TatwoProductionLayoutLock.osNativeStateRoot(
                applicationSupportBase: base)
        try writeSentinel(
            "production-app-support",
            to: productionAppSupport.appendingPathComponent(
                "production-sentinel.txt"))
        try writeSentinel(
            "production-state",
            to: productionState.appendingPathComponent(
                "production-state-sentinel.txt"))
        let productionDigestBefore = try treeDigest(
            productionAppSupport)

        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: "com.tatwo.ultrawork.staging",
            infoDictionary: [
                "CFBundleExecutable": "TatwoUltraworkMacStaging",
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base,
            processID: 404)
        let isolatedRoot = composition.stateRootURL
        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertFalse(
            composition.storage.applicationSupportRootURL.path
                .hasPrefix(productionAppSupport.path + "/"))

        try composition.nativeChatStore.save(
            TatwoNativeChatStoreDocument(threads: [
                TatwoNativeChatThread(title: "isolated staging"),
            ]))
        try composition.preferenceStore.save(TatwoUserPreferences())
        try composition.pluginRegistryStore.save(
            TatwoPluginRegistryBookV1())
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "isolated-goal",
                contractID: "isolated-contract",
                mode: .m,
                scenario: "staging",
                objective: "stay isolated",
                status: .planned,
                issuedAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)),
            to: composition.goalRunStore)
        try composition.cancellationStateStore.upsert(
            ChatDurableCancellationRecord(
                identity: ChatRunnerAttemptIdentity(
                    runID: "isolated-run",
                    attempt: 1,
                    instanceID: UUID(),
                    revision: 1),
                assistantID: "assistant",
                threadID: nil,
                phase: .blocked,
                reason: "fixture",
                updatedAt: Date(timeIntervalSince1970: 1)))
        try writeSentinel(
            "isolated-runtime",
            to: composition.storage.chatRuntimeRootURL
                .appendingPathComponent("runtime-sentinel.txt"))
        let model = composition.makeChatPageModel()
        model.scheduleColdStartHydrationAfterFirstFrame()
        try await waitForInitialStoreLoad(model)

        for url in [
            composition.nativeChatStore.url,
            composition.preferenceStore.fileURL,
            composition.pluginRegistryStore.fileURL,
            composition.storage.cancellationStateStoreURL,
            composition.storage.chatRuntimeRootURL,
        ] {
            XCTAssertTrue(
                url.standardizedFileURL.path
                    .hasPrefix(isolatedRoot.standardizedFileURL.path + "/"))
        }
        XCTAssertEqual(
            model.processStorageLayout?.chatRuntimeRootURL,
            composition.storage.chatRuntimeRootURL)
        XCTAssertEqual(
            try treeDigest(productionAppSupport),
            productionDigestBefore)
    }

    func testStagingFallsBackToExplicitAppSupportStateRoot() {
        let base = temporaryDirectory("staging-app-support-base")
        let appSupport = base.appendingPathComponent(
            "runtime-app-support",
            isDirectory: true)
        let stateRoot = TatwoChatProcessCompositionResolver.stateRoot(
            environment: [
                TatwoProductionLayoutLock.appSupportEnvKey: appSupport.path,
            ],
            bundleIdentifier: "com.tatwo.ultrawork.staging.fixture",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base)

        XCTAssertEqual(
            stateRoot,
            appSupport.appendingPathComponent("state", isDirectory: true))
    }

    func testIsolatedProcessCannotSelectProductionAppSupportWithEnvironment() {
        let base = temporaryDirectory("protected-production-root")
        let productionAppSupport =
            TatwoProductionLayoutLock.osNativeApplicationSupportRoot(
                applicationSupportBase: base)
        let productionState = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let resolved = TatwoChatProcessCompositionResolver.stateRoot(
            environment: [
                TatwoProductionLayoutLock.stateDirEnvKey:
                    productionState.path,
                TatwoProductionLayoutLock.appSupportEnvKey:
                    productionAppSupport.path,
            ],
            bundleIdentifier: "com.tatwo.ultrawork.staging.fixture",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base,
            processID: 77)

        XCTAssertNotEqual(resolved, productionState)
        XCTAssertFalse(
            resolved.path == productionAppSupport.path
                || resolved.path.hasPrefix(productionAppSupport.path + "/"))
        XCTAssertTrue(
            resolved.path.contains("/Tatwo Ultrawork Isolated/"))
    }

    func testXCTestBundleNeverReceivesProductionComposition() {
        let base = temporaryDirectory("xctest-bundle")
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: [:],
            bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
            infoDictionary: productionInfoDictionary(),
            bundleURL: base.appendingPathComponent(
                "TatwoUltraworkMacTests.xctest",
                isDirectory: true),
            applicationSupportBase: base,
            processID: 91)

        XCTAssertEqual(composition.processClass, .isolated)
        XCTAssertTrue(
            composition.remoteTurnDispatcher
                is ChatUnavailableRemoteTurnDispatcher)
        XCTAssertNotEqual(
            composition.stateRootURL,
            TatwoProductionLayoutLock.osNativeStateRoot(
                applicationSupportBase: base))
    }

    @MainActor
    func testStagingStartupLeavesProductionRunnerAndAuthorizationDigestsUnchanged()
        async throws
    {
        let base = temporaryDirectory("staging-startup-digest")
        let productionState = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let productionRunnerRoot = productionState.appendingPathComponent(
            "chat-runner-authority-v1",
            isDirectory: true)
        let productionAuthorizationRoot =
            productionState.appendingPathComponent(
                "remote-execution-authorization",
                isDirectory: true)
        try writeSentinel(
            "production-runner-registry",
            to: productionRunnerRoot.appendingPathComponent(
                "registry-sentinel.json"))
        try writeSentinel(
            "production-authorization-material",
            to: productionAuthorizationRoot.appendingPathComponent(
                "authorization-sentinel.json"))
        let runnerDigestBefore = try treeDigest(productionRunnerRoot)
        let authorizationDigestBefore = try treeDigest(
            productionAuthorizationRoot)

        let stagingRoot = base.appendingPathComponent(
            "staging-runtime",
            isDirectory: true)
        let stagingState = stagingRoot.appendingPathComponent(
            "state",
            isDirectory: true)
        let environment = [
            "TATWO_ULTRAWORK_APP_SUPPORT":
                stagingRoot.appendingPathComponent(
                    "app-support",
                    isDirectory: true).path,
            "TATWO_ULTRAWORK_STATE_DIR": stagingState.path,
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
        ]
        var signatureTrustCalls = 0
        var productionRunnerFactoryCalls = 0
        var productionAuthorizationFactoryCalls = 0
        var productionMaterialFactoryCalls = 0
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: environment,
            bundleIdentifier: "com.tatwo.ultrawork.staging.fixture",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: stagingRoot.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            productionSignatureTrustProvider: { _ in
                signatureTrustCalls += 1
                return .trusted
            },
            applicationSupportBase: base,
            productionRunnerAuthorityFactory: { stateRoot in
                productionRunnerFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionAuthorizationStoreFactory: { stateRoot in
                productionAuthorizationFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionRemoteDispatcherFactory: {
                productionMaterialFactoryCalls += 1
                return ChatUnavailableRemoteTurnDispatcher()
            })
        XCTAssertEqual(signatureTrustCalls, 0)
        XCTAssertEqual(productionRunnerFactoryCalls, 0)
        XCTAssertEqual(productionAuthorizationFactoryCalls, 0)
        XCTAssertEqual(
            productionMaterialFactoryCalls,
            0,
            """
            The production dispatcher factory is the composition's only path \
            that constructs formal-production \
            TatwoProductionInstallAnchorKeychainStore-backed material; \
            local-internal trust uses its receipt-bound file anchor instead, \
            and staging must enter neither path.
            """)
        XCTAssertEqual(
            composition.remoteTurnDispatcher.dispatch(makeRequest()),
            .blocked(.adapterUnavailable))

        let isolatedRunnerDigestBefore =
            try treeDigest(composition.runnerAuthority.rootURL)
        let isolatedAuthorizationDigestBefore =
            try treeDigest(
                composition.remoteBorrowAuthorizationStore.rootURL)

        let model = ChatPageModel(
            environment: environment,
            remoteBorrowAuthorizationStore:
                composition.remoteBorrowAuthorizationStore,
            remoteTurnDispatcher:
                composition.remoteTurnDispatcher,
            runnerAuthorityDiscoverer:
                composition.runnerAuthority)
        model.scheduleColdStartHydrationAfterFirstFrame()
        for _ in 0..<200 where model.isLoadingStore {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isLoadingStore)
        XCTAssertEqual(
            model.remoteBorrowAuthorizationStore.rootURL,
            stagingState.appendingPathComponent(
                "remote-execution-authorization",
                isDirectory: true))
        XCTAssertEqual(
            composition.runnerAuthority.rootURL,
            stagingState.appendingPathComponent(
                "chat-runner-authority-v1",
                isDirectory: true))

        _ = try composition.runnerAuthority.claim(
            runID: "isolated-staging-run",
            attempt: 1)
        if case .unknown(let reason) =
            composition.runnerAuthority.discoverRunnerAuthority()
        {
            XCTAssertTrue(
                reason.contains("runner-attach-incomplete"),
                "Unexpected fail-closed authority reason: \(reason)")
        } else {
            XCTFail("A claimed but unattached runner must remain unknown.")
        }
        _ = try composition.remoteBorrowAuthorizationStore.issueSessionGrant(
            sessionID: "isolated-staging-session",
            targetDeviceID: "isolated-staging-target",
            contractID: "isolated-staging-contract")

        XCTAssertNotEqual(
            try treeDigest(composition.runnerAuthority.rootURL),
            isolatedRunnerDigestBefore)
        XCTAssertNotEqual(
            try treeDigest(
                composition.remoteBorrowAuthorizationStore.rootURL),
            isolatedAuthorizationDigestBefore)
        XCTAssertEqual(
            try treeDigest(productionRunnerRoot),
            runnerDigestBefore)
        XCTAssertEqual(
            try treeDigest(productionAuthorizationRoot),
            authorizationDigestBefore)
    }

    @MainActor
    func testStagingUIRemoteAttemptStaysUnavailableAndProductionTreesUnchanged()
        async throws
    {
        let base = temporaryDirectory("staging-ui-remote-attempt")
        let productionState = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let productionRunnerRoot = productionState.appendingPathComponent(
            "chat-runner-authority-v1",
            isDirectory: true)
        let productionAuthorizationRoot =
            productionState.appendingPathComponent(
                "remote-execution-authorization",
                isDirectory: true)
        try writeSentinel(
            "production-runner-ui-sentinel",
            to: productionRunnerRoot.appendingPathComponent(
                "registry-sentinel.json"))
        try writeSentinel(
            "production-authorization-ui-sentinel",
            to: productionAuthorizationRoot.appendingPathComponent(
                "authorization-sentinel.json"))
        let runnerDigestBefore = try treeDigest(productionRunnerRoot)
        let authorizationDigestBefore =
            try treeDigest(productionAuthorizationRoot)

        let stagingState = base.appendingPathComponent(
            "staging-state",
            isDirectory: true)
        let environment = [
            "XCTestConfigurationFilePath":
                "ChatProcessCompositionIsolationTests",
            TatwoProductionLayoutLock.stateDirEnvKey: stagingState.path,
            "TATWO_ULTRAWORK_CHAT_ENABLE_CLI_RUNTIME": "0",
            "TATWO_ULTRAWORK_CHAT_CODEX_MIRROR": "0",
        ]
        var productionRunnerFactoryCalls = 0
        var productionAuthorizationFactoryCalls = 0
        var productionDispatcherFactoryCalls = 0
        let composition = TatwoChatProcessCompositionResolver.resolve(
            environment: environment,
            bundleIdentifier: "com.tatwo.ultrawork.staging.fixture",
            infoDictionary: [
                TatwoChatProcessCompositionResolver.stagingMarkerInfoKey:
                    "staging-service|staging-account",
            ],
            bundleURL: base.appendingPathComponent(
                "Tatwo Ultrawork Staging.app",
                isDirectory: true),
            applicationSupportBase: base,
            productionRunnerAuthorityFactory: { stateRoot in
                productionRunnerFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionAuthorizationStoreFactory: { stateRoot in
                productionAuthorizationFactoryCalls += 1
                return .production(stateRoot: stateRoot)
            },
            productionRemoteDispatcherFactory: {
                productionDispatcherFactoryCalls += 1
                return ChatUnavailableRemoteTurnDispatcher()
            })
        XCTAssertEqual(productionRunnerFactoryCalls, 0)
        XCTAssertEqual(productionAuthorizationFactoryCalls, 0)
        XCTAssertEqual(productionDispatcherFactoryCalls, 0)

        let now = Date()
        let thread = TatwoNativeChatThread(
            title: "staging remote unavailable",
            workOSGoalID: "goal-staging-unavailable",
            workOSContractID: "contract-staging-unavailable")
        let nativeStore = TatwoNativeChatStore(
            url: stagingState.appendingPathComponent("native-chat.json"),
            fallbackURLs: [],
            mirrorsToUnifiedLedger: false)
        try nativeStore.save(
            TatwoNativeChatStoreDocument(threads: [thread]))
        let goalStore = TatwoGoalRunStore(directoryURL: stagingState)
        try writeGoalRun(
            TatwoStoredGoalRun(
                goalID: "goal-staging-unavailable",
                contractID: "contract-staging-unavailable",
                mode: .xxl,
                scenario: "staging-composition",
                objective: "prove staging UI cannot remote dispatch",
                status: .planned,
                issuedAt: now,
                updatedAt: now),
            to: goalStore)
        let grant =
            try composition.remoteBorrowAuthorizationStore.issueSessionGrant(
                sessionID: thread.id.uuidString.lowercased(),
                targetDeviceID: "target-staging-unavailable",
                contractID: "contract-staging-unavailable",
                now: now)
        let pendingStore = ChatPendingRemoteTargetDiskStore(
            fileURL: stagingState.appendingPathComponent(
                "pending-remote-target.json"))
        let pending = try pendingStore.arm(
            grant: grant,
            goalID: "goal-staging-unavailable",
            targetDisplayName: "Staging Mac mini",
            now: now)
        let model = ChatPageModel(
            environment: environment,
            store: nativeStore,
            transcriptJournalStore: ChatTranscriptJournalDiskStore(
                fileURL: stagingState.appendingPathComponent(
                    "chat-transcript-journal.json")),
            goalRunStore: goalStore,
            remoteBorrowAuthorizationStore:
                composition.remoteBorrowAuthorizationStore,
            pendingRemoteTargetStore: pendingStore,
            remoteTurnDispatcher:
                composition.remoteTurnDispatcher,
            runnerAuthorityDiscoverer:
                composition.runnerAuthority)
        try await waitForInitialStoreLoad(model)

        model.prompt = "attempt staging remote work"
        model.submitCurrentChatTurn()
        try await waitUntil {
            !model.isRunning
        }

        let released = try XCTUnwrap(
            pendingStore.pending(sessionID: grant.sessionID))
        XCTAssertEqual(released.state, .armed)
        XCTAssertEqual(released.claimID, pending.claimID)
        XCTAssertEqual(released.logicalJobID, pending.logicalJobID)
        XCTAssertNil(released.remoteJobID)
        let threadKey = TatwoNativeChatSessionReference(
            kind: .thread,
            id: thread.id
        ).stableKey
        let remoteRows = model.chatTranscriptJournal
            .orderedItems(threadID: threadKey)
            .filter { $0.kind == .remoteJob }
        XCTAssertEqual(remoteRows.count, 1)
        XCTAssertEqual(
            remoteRows.first?.attributes["remoteBlocker"],
            ChatRemoteTurnDispatchBlocker.adapterUnavailable.rawValue)
        XCTAssertEqual(
            try treeDigest(productionRunnerRoot),
            runnerDigestBefore)
        XCTAssertEqual(
            try treeDigest(productionAuthorizationRoot),
            authorizationDigestBefore)
    }

    private func productionInfoDictionary() -> [String: Any] {
        [
            "CFBundleExecutable": "TatwoUltraworkMac",
            TatwoChatProcessCompositionResolver.sourceCommitInfoKey:
                "0123456789abcdef0123456789abcdef01234567",
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey:
                "89abcdef0123456789abcdef0123456789abcdef",
            TatwoChatProcessCompositionResolver.productionHelperDigestInfoKey:
                String(repeating: "a", count: 64),
            TatwoChatProcessCompositionResolver.buildClassInfoKey:
                TatwoChatProcessCompositionResolver
                    .formalProductionBuildClass,
            TatwoChatProcessCompositionResolver.distributionReadyInfoKey:
                false,
            TatwoChatProcessCompositionResolver.automaticUpdatesInfoKey:
                false,
        ]
    }

    private func localInternalInfoDictionary(
        helperDigest: String
    ) -> [String: Any] {
        [
            "CFBundleExecutable": "TatwoUltraworkMac",
            "CFBundleShortVersionString": "0.1.10",
            "CFBundleVersion": "24",
            TatwoChatProcessCompositionResolver.sourceCommitInfoKey:
                "0123456789abcdef0123456789abcdef01234567",
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey:
                "89abcdef0123456789abcdef0123456789abcdef",
            TatwoChatProcessCompositionResolver.productionHelperDigestInfoKey:
                helperDigest,
            TatwoChatProcessCompositionResolver.buildClassInfoKey:
                TatwoChatProcessCompositionResolver
                    .localInternalBuildClass,
            TatwoChatProcessCompositionResolver.distributionReadyInfoKey:
                false,
            TatwoChatProcessCompositionResolver.automaticUpdatesInfoKey:
                false,
        ]
    }

    private func makeRequest() -> ChatRemoteTurnDispatchRequest {
        ChatRemoteTurnDispatchRequest(
            visibleTurn: "staging must stay dry-run",
            invocation: TatwoRemoteBorrowInvocationV1(
                sessionID: "session-staging-isolation",
                targetDeviceID: "target-device",
                contractID: "contract-staging-isolation",
                goalID: "goal-staging-isolation",
                mode: .manual,
                risk: .lowRisk,
                grantID: "grant-staging-isolation"),
            claimID: "claim-staging-isolation",
            logicalJobID: "logical-staging-isolation",
            contractMode: .xxl,
            agent: .codex,
            exactModelRouteID: "gpt-5.5",
            readinessChallengeNonce: "readiness-staging-isolation",
            targetReadinessManifest: nil,
            readinessBinding: nil)
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-chat-composition-\(label)-\(UUID().uuidString)",
                isDirectory: true)
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

    private func writeSentinel(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url, options: .atomic)
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
            to: directory.appendingPathComponent(
                "\(goal.contractID).json"),
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
        XCTFail("timed out waiting for staging remote attempt")
    }

    private func treeDigest(_ root: URL) throws -> String {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, _ in false })
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            urls.append(url)
        }
        var material = Data()
        for url in urls.sorted(by: { $0.path < $1.path }) {
            let relative = String(
                url.standardizedFileURL.path.dropFirst(
                    root.standardizedFileURL.path.count))
            material.append(Data(relative.utf8))
            material.append(0)
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            if values.isRegularFile == true {
                material.append(1)
                material.append(try Data(contentsOf: url))
            } else if values.isDirectory == true {
                material.append(2)
            } else if values.isSymbolicLink == true {
                material.append(3)
            } else {
                material.append(4)
            }
            material.append(0)
        }
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
