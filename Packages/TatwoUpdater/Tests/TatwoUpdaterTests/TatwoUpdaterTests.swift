import Foundation
import XCTest
import TatwoDeploymentPrimitives
import TatwoModuleContracts
@testable import TatwoUpdater

final class TatwoUpdaterTests: XCTestCase {
    func testTrustedChannelCandidateAndSixHourCheckPolicy() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let updater = makeUpdater(now: now)
        let request = TatwoUpdateCheckRequestV1(
            channel: .internalCanary,
            currentVersion: .init(major: 1, minor: 0, patch: 0),
            correlationID: "check"
        )

        let first = updater.check(request)
        let second = updater.check(request)

        XCTAssertEqual(first.status, .available)
        XCTAssertEqual(first.errorKind, .none)
        XCTAssertEqual(second.errorKind, .checkThrottled)
        XCTAssertEqual(updater.updateStatusSnapshot().candidateVersion, .init(major: 2, minor: 0, patch: 0))
    }

    func testWrongChannelAndInvalidSignatureFailClosed() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let wrongChannel = makeUpdater(
            now: now,
            entry: Self.makeEntry(channel: .stable)
        )
        let mismatch = wrongChannel.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "channel"
            )
        )
        XCTAssertEqual(mismatch.errorKind, .channelMismatch)

        let invalidSignature = makeUpdater(
            now: now,
            trust: Self.makeTrust(feedSignatureValid: false)
        )
        let untrusted = invalidSignature.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "signature"
            )
        )
        XCTAssertEqual(untrusted.errorKind, .untrustedFeed)
    }

    func testBackgroundDownloadStillRequiresUserApprovedActivation() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let activation = RecordingActivationPort()
        let updater = makeUpdater(now: now, activation: activation)
        _ = updater.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "check"
            )
        )
        let destination = TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact)
        let download = updater.download(
            .init(
                channel: .internalCanary,
                destination: destination,
                correlationID: "download"
            )
        )
        XCTAssertEqual(download.status, .downloaded)

        let approval = updater.requestUserApprovedInstall(
            .init(
                channel: .internalCanary,
                userApproved: false,
                activationPlan: try makeActivationPlan(source: destination),
                correlationID: "install"
            )
        )
        XCTAssertEqual(approval.status, .awaitingApproval)
        XCTAssertEqual(approval.errorKind, .userApprovalRequired)
        XCTAssertTrue(activation.invocations.isEmpty)
    }

    func testUserApprovedActivationUsesSafeOrderAndHealthFailureRollsBackBundleOnly() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let activation = RecordingActivationPort()
        activation.failedOperation = .healthCheck
        let updater = makeUpdater(now: now, activation: activation)
        let source = TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact)
        _ = updater.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "check"
            )
        )
        _ = updater.download(
            .init(channel: .internalCanary, destination: source, correlationID: "download")
        )

        let receipt = updater.requestUserApprovedInstall(
            .init(
                channel: .internalCanary,
                userApproved: true,
                activationPlan: try makeActivationPlan(source: source),
                correlationID: "install"
            )
        )

        XCTAssertEqual(receipt.status, .rolledBack)
        XCTAssertEqual(receipt.errorKind, .healthCheckFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck, .rollbackBundle]
        )
        XCTAssertEqual(receipt.safetyEvidence.userDataWriteCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainLedgerWriteCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.domainAuthorityMutationCount, 0)
        XCTAssertEqual(receipt.safetyEvidence.syncCallCount, 0)
    }

    func testManualRollbackRequiresApprovalAndNeverWritesDomainData() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let activation = RecordingActivationPort()
        let updater = makeUpdater(now: now, activation: activation)
        let rollback = try makeActivationPlan(
            source: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact)
        ).rollbackBundle

        let blocked = updater.rollbackBundle(
            .init(
                channel: .internalCanary,
                userApproved: false,
                automaticActivationHealthRecovery: false,
                rollbackRequest: rollback,
                correlationID: "rollback"
            )
        )
        XCTAssertEqual(blocked.errorKind, .userApprovalRequired)
        XCTAssertTrue(activation.invocations.isEmpty)

        let approved = updater.rollbackBundle(
            .init(
                channel: .internalCanary,
                userApproved: true,
                automaticActivationHealthRecovery: false,
                rollbackRequest: rollback,
                correlationID: "rollback"
            )
        )
        XCTAssertEqual(approved.status, .rolledBack)
        XCTAssertEqual(approved.safetyEvidence.userDataWriteCount, 0)
        XCTAssertEqual(approved.safetyEvidence.domainLedgerWriteCount, 0)
    }

    func testThrownHealthCheckRollsBackAndReportsRolledBackTruthfully() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let activation = RecordingActivationPort()
        activation.thrownOperation = .healthCheck
        let updater = makeUpdater(now: now, activation: activation)
        let source = TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact)
        _ = updater.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "check"
            )
        )
        _ = updater.download(
            .init(channel: .internalCanary, destination: source, correlationID: "download")
        )

        let receipt = updater.requestUserApprovedInstall(
            .init(
                channel: .internalCanary,
                userApproved: true,
                activationPlan: try makeActivationPlan(source: source),
                correlationID: "install"
            )
        )

        XCTAssertEqual(receipt.status, .rolledBack)
        XCTAssertEqual(receipt.errorKind, .healthCheckFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .healthCheck, .rollbackBundle]
        )
    }

    func testUncertainAtomicSwapThrowAttemptsRollbackAndSeparatesRollbackFailure() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let activation = RecordingActivationPort()
        activation.thrownOperation = .atomicSwap
        activation.failedOperation = .rollbackBundle
        let updater = makeUpdater(now: now, activation: activation)
        let source = TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact)
        _ = updater.check(
            .init(
                channel: .internalCanary,
                currentVersion: .init(major: 1, minor: 0, patch: 0),
                force: true,
                correlationID: "check"
            )
        )
        _ = updater.download(
            .init(channel: .internalCanary, destination: source, correlationID: "download")
        )

        let receipt = updater.requestUserApprovedInstall(
            .init(
                channel: .internalCanary,
                userApproved: true,
                activationPlan: try makeActivationPlan(source: source),
                correlationID: "install"
            )
        )

        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.errorKind, .rollbackFailed)
        XCTAssertEqual(
            activation.invocations.map(\.operation),
            [.stage, .verify, .archiveCurrent, .atomicSwap, .rollbackBundle]
        )
    }

    private func makeUpdater(
        now: Date,
        entry: TatwoSignedAppcastEntryV1 = makeEntry(),
        trust: TatwoUpdateTrustVerificationV1 = makeTrust(),
        activation: RecordingActivationPort = RecordingActivationPort()
    ) -> TatwoUpdater {
        TatwoUpdater(
            channel: .internalCanary,
            appcast: StubAppcast(entry: entry),
            trustVerifier: StubTrustVerifier(result: trust),
            downloader: StubDownloader(),
            activation: activation,
            receiptID: { "receipt-fixed" },
            now: { now }
        )
    }

    private static func makeEntry(
        channel: TatwoUpdateChannelV1 = .internalCanary
    ) -> TatwoSignedAppcastEntryV1 {
        TatwoSignedAppcastEntryV1(
            feedID: "feed",
            feedChannel: channel,
            feedSignature: "feed-signature",
            artifact: TatwoUpdateArtifactMetadataV1(
                version: .init(major: 2, minor: 0, patch: 0),
                channel: channel,
                artifactURL: "https://updates.invalid/Tatwo.zip",
                artifactSHA256: String(repeating: "a", count: 64),
                sparkleEdDSASignature: "eddsa",
                developerIDTeamID: "TEAMID",
                notarizationTicketID: "ticket",
                sourceCommit: String(repeating: "b", count: 40),
                schemaVersion: 1,
                protocolVersion: 1,
                rollbackTargetVersion: .init(major: 1, minor: 0, patch: 0),
                publishedAt: Date(timeIntervalSince1970: 900)
            )
        )
    }

    private static func makeTrust(
        feedSignatureValid: Bool = true
    ) -> TatwoUpdateTrustVerificationV1 {
        TatwoUpdateTrustVerificationV1(
            feedSignatureValid: feedSignatureValid,
            artifactHashValid: true,
            artifactEdDSAValid: true,
            developerIDValid: true,
            notarizationValid: true,
            sourceCommitValid: true,
            schemaCompatible: true,
            protocolCompatible: true,
            detail: feedSignatureValid ? "trusted" : "bad feed signature"
        )
    }

    private func makeActivationPlan(
        source: TatwoBundlePathV1
    ) throws -> TatwoUpdateActivationPlanV1 {
        let boundary = TatwoBundleActivationBoundaryV1(
            moduleID: try TatwoModuleIDV1("tatwo.app"),
            installRoot: "/Applications/Tatwo.app",
            stagingRoots: ["/staging"],
            archiveRoots: ["/archives"],
            protectedUserDataRoots: ["/data"],
            protectedDomainLedgerRoots: ["/data/domain-ledger"]
        )
        return TatwoUpdateActivationPlanV1(
            stage: .init(
                boundary: boundary,
                sourceBundle: source,
                stagedBundle: .init("/staging/Tatwo.app", role: .stagedBundle),
                correlationID: "install"
            ),
            verify: .init(
                boundary: boundary,
                stagedBundle: .init("/staging/Tatwo.app", role: .stagedBundle),
                expectedArtifactDigest: String(repeating: "a", count: 64),
                correlationID: "install"
            ),
            archiveCurrent: .init(
                boundary: boundary,
                currentBundle: .init("/Applications/Tatwo.app", role: .activeBundle),
                archivedBundle: .init("/archives/Tatwo-1.app", role: .archivedBundle),
                correlationID: "install"
            ),
            atomicSwap: .init(
                boundary: boundary,
                stagedBundle: .init("/staging/Tatwo.app", role: .stagedBundle),
                activeBundle: .init("/Applications/Tatwo.app", role: .activeBundle),
                correlationID: "install"
            ),
            healthCheck: .init(
                boundary: boundary,
                activeBundle: .init("/Applications/Tatwo.app", role: .activeBundle),
                policy: .init(kind: .executableProbe),
                correlationID: "install"
            ),
            rollbackBundle: .init(
                boundary: boundary,
                archivedBundle: .init("/archives/Tatwo-1.app", role: .rollbackBundle),
                activeBundle: .init("/Applications/Tatwo.app", role: .activeBundle),
                correlationID: "install"
            )
        )
    }
}

private struct StubAppcast: TatwoSignedAppcastPort {
    let entry: TatwoSignedAppcastEntryV1?

    func latestEntry(for channel: TatwoUpdateChannelV1) throws -> TatwoSignedAppcastEntryV1? {
        entry
    }
}

private struct StubTrustVerifier: TatwoUpdateTrustVerificationPort {
    let result: TatwoUpdateTrustVerificationV1

    func verify(_ entry: TatwoSignedAppcastEntryV1) -> TatwoUpdateTrustVerificationV1 {
        result
    }
}

private struct StubDownloader: TatwoUpdateDownloadPort {
    func download(
        artifact: TatwoUpdateArtifactMetadataV1,
        to destination: TatwoBundlePathV1
    ) throws -> TatwoBundlePathV1 {
        destination
    }
}

private final class RecordingActivationPort: TatwoBundleActivationPort {
    private(set) var invocations: [TatwoBundleActivationInvocationV1] = []
    var failedOperation: TatwoBundleOperationKindV1?
    var thrownOperation: TatwoBundleOperationKindV1?

    func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.stage(request))
    }

    func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        try record(.verify(request))
    }

    func archiveCurrent(
        _ request: TatwoBundleArchiveCurrentRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try record(.archiveCurrent(request))
    }

    func atomicSwap(
        _ request: TatwoBundleAtomicSwapRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try record(.atomicSwap(request))
    }

    func healthCheck(
        _ request: TatwoBundleHealthCheckRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try record(.healthCheck(request))
    }

    func rollbackBundle(
        _ request: TatwoBundleRollbackRequestV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try record(.rollbackBundle(request))
    }

    private func record(
        _ invocation: TatwoBundleActivationInvocationV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        invocations.append(invocation)
        if invocation.operation == thrownOperation {
            throw RecordingActivationError.forced(invocation.operation)
        }
        let outcome: TatwoBundleOperationOutcomeV1 =
            invocation.operation == failedOperation ? .failed : .succeeded
        let moduleID: TatwoModuleIDV1
        let correlationID: String
        switch invocation {
        case let .stage(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        case let .verify(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        case let .archiveCurrent(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        case let .atomicSwap(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        case let .healthCheck(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        case let .rollbackBundle(request):
            moduleID = request.boundary.moduleID
            correlationID = request.correlationID
        }
        return TatwoBundleOperationReceiptV1(
            receiptID: "bundle-\(invocations.count)",
            operation: invocation.operation,
            moduleID: moduleID,
            correlationID: correlationID,
            createdAt: Date(timeIntervalSince1970: Double(invocations.count)),
            outcome: outcome,
            isolationEvidence: TatwoBundleOnlyMutationEvidenceV1(
                bundlePaths: invocation.bundlePaths
            ),
            detail: outcome == .succeeded ? "ok" : "forced failure"
        )
    }
}

private enum RecordingActivationError: Error {
    case forced(TatwoBundleOperationKindV1)
}
