import CryptoKit
import Foundation
import XCTest

@testable import TatwoUltraworkMac
import TatwoUltraworkCore

final class ChatProductionPromotionTrustTests: XCTestCase {
    func testDeveloperIDAndProductionIntentMarkersWithoutPromotionStayIsolated()
        throws
    {
        let fixture = try makeFixture("missing-promotion", writeEvidence: false)

        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.processClass(
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: fixture.info,
                bundleURL: fixture.bundleURL,
                expectedProductionBundleURL: fixture.bundleURL,
                productionSignatureTrustProvider: { _ in .trusted },
                applicationSupportBase: fixture.baseURL),
            .isolated)
    }

    func testNotarizationEvidenceMissingOrMismatchedIsRejected() throws {
        for status in [nil, "Invalid"] {
            let fixture = try makeFixture(
                "notary-\(status ?? "missing")",
                mutateManifest: { manifest in
                    var provenance =
                        manifest["provenance"] as! [String: Any]
                    provenance["notarizationStatus"] = status
                    manifest["provenance"] = provenance
                })

            XCTAssertEqual(
                promotionTrust(fixture),
                .rejected)
        }
    }

    func testSignedAppcastEvidenceMissingOrMismatchedFailsClosed() throws {
        let missing = try makeFixture("appcast-missing")
        try FileManager.default.removeItem(at: missing.appcastURL)
        XCTAssertNotEqual(promotionTrust(missing), .trusted)

        let mismatch = try makeFixture("appcast-mismatch")
        try Data("different-appcast".utf8).write(
            to: mismatch.appcastURL,
            options: .atomic)
        XCTAssertEqual(promotionTrust(mismatch), .rejected)
    }

    func testExactSignedPromotionElevatesProductionIntentToProduction() throws {
        let fixture = try makeFixture("exact")
        var promotionCalls = 0

        XCTAssertEqual(promotionTrust(fixture), .trusted)
        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.processClass(
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: fixture.info,
                bundleURL: fixture.bundleURL,
                expectedProductionBundleURL: fixture.bundleURL,
                productionSignatureTrustProvider: { _ in .trusted },
                productionPromotionTrustProvider: {
                    bundleURL,
                    info,
                    applicationSupportBase,
                    fileManager in
                    promotionCalls += 1
                    return TatwoChatProcessCompositionResolver
                        .productionPromotionTrust(
                            bundleURL: bundleURL,
                            infoDictionary: info,
                            applicationSupportBase: applicationSupportBase,
                            fileManager: fileManager,
                            bundleCDHashProvider: { _ in fixture.bundleCDHash })
                },
                applicationSupportBase: fixture.baseURL),
            .production)
        XCTAssertEqual(promotionCalls, 1)
    }

    func testLocalInternalCannotUseProductionPromotionEvidence() throws {
        var fixture = try makeFixture("local-internal")
        fixture.info[
            TatwoChatProcessCompositionResolver.buildClassInfoKey
        ] = TatwoChatProcessCompositionResolver.localInternalBuildClass
        var promotionCalls = 0
        var localInstallCalls = 0

        XCTAssertEqual(
            TatwoChatProcessCompositionResolver.processClass(
                bundleIdentifier: TatwoRuntimeLayout.bundleIdentifier,
                infoDictionary: fixture.info,
                bundleURL: fixture.bundleURL,
                expectedProductionBundleURL: fixture.bundleURL,
                productionSignatureTrustProvider: { _ in .currentAdHoc },
                productionPromotionTrustProvider: { _, _, _, _ in
                    promotionCalls += 1
                    return .trusted
                },
                localInternalInstallTrustProvider: {
                    _, _, _, _, _ in
                    localInstallCalls += 1
                    return .trusted
                },
                applicationSupportBase: fixture.baseURL),
            .localInternal)
        XCTAssertEqual(promotionCalls, 0)
        XCTAssertEqual(localInstallCalls, 1)
    }

    private struct Fixture {
        let baseURL: URL
        let bundleURL: URL
        let appcastURL: URL
        let bundleCDHash: String
        var info: [String: Any]
    }

    private func makeFixture(
        _ label: String,
        writeEvidence: Bool = true,
        mutateManifest: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tatwo-production-promotion-\(label)-\(UUID().uuidString)",
                isDirectory: true)
        let bundle = base.appendingPathComponent(
            "Applications/Tatwo Ultrawork.app",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true)

        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
            .base64EncodedString()
        let sourceCommit =
            "0123456789abcdef0123456789abcdef01234567"
        let sourceTree =
            "89abcdef0123456789abcdef0123456789abcdef"
        let helperSHA256 = String(repeating: "a", count: 64)
        let bundleCDHash = String(repeating: "b", count: 40)
        let feedURL =
            "https://updates.example.invalid/appcast-stable.xml"
        var info: [String: Any] = [
            "CFBundleExecutable": "TatwoUltraworkMac",
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "25",
            "SUPublicEDKey": publicKey,
            "SUFeedURL": feedURL,
            "TatwoUpdateChannel": "stable",
            TatwoChatProcessCompositionResolver.sourceCommitInfoKey:
                sourceCommit,
            TatwoChatProcessCompositionResolver.sourceTreeInfoKey:
                sourceTree,
            TatwoChatProcessCompositionResolver.productionHelperDigestInfoKey:
                helperSHA256,
            TatwoChatProcessCompositionResolver.buildClassInfoKey:
                TatwoChatProcessCompositionResolver
                    .formalProductionBuildClass,
            TatwoChatProcessCompositionResolver.distributionReadyInfoKey:
                false,
            TatwoChatProcessCompositionResolver.automaticUpdatesInfoKey:
                false,
        ]
        if !writeEvidence {
            return Fixture(
                baseURL: base,
                bundleURL: bundle,
                appcastURL: base.appendingPathComponent("missing-appcast"),
                bundleCDHash: bundleCDHash,
                info: info)
        }

        let stateRoot = TatwoProductionLayoutLock.osNativeStateRoot(
            applicationSupportBase: base)
        let promotionRoot = stateRoot.appendingPathComponent(
            TatwoChatProcessCompositionResolver
                .productionPromotionDirectoryName,
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: promotionRoot,
            withIntermediateDirectories: true)
        let appcastURL = promotionRoot.appendingPathComponent("appcast.xml")
        let appcastData = Data("<rss>signed-appcast</rss>\n".utf8)
        try appcastData.write(to: appcastURL, options: .atomic)
        let appcastSHA256 = sha256Hex(appcastData)
        var manifest: [String: Any] = [
            "schema": "TatwoSignedReleaseManifestV1",
            "createdAt": "2026-08-05T00:00:00Z",
            "version": "0.2.0",
            "build": "25",
            "channel": "stable",
            "feedURL": feedURL,
            "artifact": [
                "name": "Tatwo-Ultrawork-0.2.0-25.zip",
                "sha256": String(repeating: "c", count: 64),
                "bytes": 1024,
                "sparkleEdDSASignature":
                    Data(repeating: 7, count: 64).base64EncodedString(),
            ],
            "bundle": [
                "identifier": TatwoRuntimeLayout.bundleIdentifier,
                "executable": "TatwoUltraworkMac",
                "cdhash": bundleCDHash,
                "helperSHA256": helperSHA256,
            ],
            "updateEvidence": [
                "appcastSHA256": appcastSHA256,
            ],
            "provenance": [
                "sourceCommit": sourceCommit,
                "sourceTree": sourceTree,
                "developerIDTeamID":
                    TatwoChatProcessCompositionResolver
                        .expectedProductionTeamIdentifier,
                "notarizationStatus": "Accepted",
                "notarizationSubmissionID": "notary-submission-fixture",
            ],
        ]
        mutateManifest(&manifest)
        var manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys])
        manifestData.append(0x0a)
        let manifestURL = promotionRoot.appendingPathComponent(
            TatwoChatProcessCompositionResolver
                .productionPromotionManifestName)
        try manifestData.write(to: manifestURL, options: .atomic)
        let signature = try privateKey.signature(for: manifestData)
        let signatureURL = promotionRoot.appendingPathComponent(
            TatwoChatProcessCompositionResolver
                .productionPromotionSignatureName)
        try Data(
            "\(signature.base64EncodedString())\n".utf8
        ).write(to: signatureURL, options: .atomic)

        return Fixture(
            baseURL: base,
            bundleURL: bundle,
            appcastURL: appcastURL,
            bundleCDHash: bundleCDHash,
            info: info)
    }

    private func promotionTrust(
        _ fixture: Fixture
    ) -> TatwoProductionPromotionTrust {
        TatwoChatProcessCompositionResolver.productionPromotionTrust(
            bundleURL: fixture.bundleURL,
            infoDictionary: fixture.info,
            applicationSupportBase: fixture.baseURL,
            bundleCDHashProvider: { _ in fixture.bundleCDHash })
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
