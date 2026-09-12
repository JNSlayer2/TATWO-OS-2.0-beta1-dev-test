import Foundation
import XCTest
import TatwoModuleContracts
@testable import TatwoDeploymentPrimitives

final class TatwoBundleActivationTests: XCTestCase {
    func testStageUsesBundleFilesystemOnlyAndProducesZeroDomainWriteEvidence() throws {
        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let request = TatwoBundleStageRequestV1(
            boundary: try makeBoundary(),
            sourceBundle: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact),
            stagedBundle: TatwoBundlePathV1("/staging/Tatwo.app", role: .stagedBundle),
            correlationID: "update-1"
        )

        let receipt = try service.stage(request)

        XCTAssertEqual(fileSystem.events, [.stage("/downloads/Tatwo.app", "/staging/Tatwo.app")])
        XCTAssertEqual(receipt.operation, .stage)
        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(receipt.isolationEvidence.scope, .bundleOnly)
        XCTAssertEqual(receipt.isolationEvidence.userDataWriteCount, 0)
        XCTAssertEqual(receipt.isolationEvidence.domainLedgerWriteCount, 0)
    }

    func testProtectedUserDataOverlapFailsBeforeFilesystemMutation() throws {
        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let request = TatwoBundleStageRequestV1(
            boundary: try makeBoundary(),
            sourceBundle: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact),
            stagedBundle: TatwoBundlePathV1(
                "/Users/test/Library/Application Support/Tatwo/staging/Tatwo.app",
                role: .stagedBundle
            ),
            correlationID: "update-1"
        )

        XCTAssertThrowsError(try service.stage(request)) { error in
            XCTAssertEqual(
                error as? TatwoBundleActivationError,
                .protectedPathOverlap(
                    candidate: "/Users/test/Library/Application Support/Tatwo/staging/Tatwo.app",
                    protectedRoot: "/Users/test/Library/Application Support/Tatwo",
                    kind: .userData
                )
            )
        }
        XCTAssertTrue(fileSystem.events.isEmpty)
    }

    func testProtectedDomainLedgerOverlapFailsBeforeFilesystemMutation() throws {
        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let request = TatwoBundleStageRequestV1(
            boundary: try makeBoundary(),
            sourceBundle: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact),
            stagedBundle: TatwoBundlePathV1(
                "/Users/test/Library/Application Support/Tatwo/domain-ledger/Tatwo.app",
                role: .stagedBundle
            ),
            correlationID: "update-1"
        )

        XCTAssertThrowsError(try service.stage(request)) { error in
            XCTAssertEqual(
                error as? TatwoBundleActivationError,
                .protectedPathOverlap(
                    candidate: "/Users/test/Library/Application Support/Tatwo/domain-ledger/Tatwo.app",
                    protectedRoot: "/Users/test/Library/Application Support/Tatwo",
                    kind: .userData
                )
            )
        }
        XCTAssertTrue(fileSystem.events.isEmpty)
    }

    func testArchiveAtomicSwapAndRollbackUseNarrowBundleOperations() throws {
        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let boundary = try makeBoundary()

        let archiveReceipt = try service.archiveCurrent(
            TatwoBundleArchiveCurrentRequestV1(
                boundary: boundary,
                currentBundle: TatwoBundlePathV1("/Applications/Tatwo.app", role: .activeBundle),
                archivedBundle: TatwoBundlePathV1("/archives/Tatwo-previous.app", role: .archivedBundle),
                correlationID: "update-1"
            )
        )
        let swapReceipt = try service.atomicSwap(
            TatwoBundleAtomicSwapRequestV1(
                boundary: boundary,
                stagedBundle: TatwoBundlePathV1("/staging/Tatwo.app", role: .stagedBundle),
                activeBundle: TatwoBundlePathV1("/Applications/Tatwo.app", role: .activeBundle),
                correlationID: "update-1"
            )
        )
        let rollbackReceipt = try service.rollbackBundle(
            TatwoBundleRollbackRequestV1(
                boundary: boundary,
                archivedBundle: TatwoBundlePathV1("/archives/Tatwo-previous.app", role: .rollbackBundle),
                activeBundle: TatwoBundlePathV1("/Applications/Tatwo.app", role: .activeBundle),
                correlationID: "update-1"
            )
        )

        XCTAssertEqual(
            fileSystem.events,
            [
                .archive("/Applications/Tatwo.app", "/archives/Tatwo-previous.app"),
                .atomicSwap("/staging/Tatwo.app", "/Applications/Tatwo.app"),
                .rollback("/archives/Tatwo-previous.app", "/Applications/Tatwo.app")
            ]
        )
        for receipt in [archiveReceipt, swapReceipt, rollbackReceipt] {
            XCTAssertEqual(receipt.isolationEvidence.scope, .bundleOnly)
            XCTAssertEqual(receipt.isolationEvidence.userDataWriteCount, 0)
            XCTAssertEqual(receipt.isolationEvidence.domainLedgerWriteCount, 0)
        }
    }

    func testVerifyAndHealthCheckAreReadOnlyAndReturnTypedEvidence() throws {
        let fileSystem = RecordingBundleFileSystem()
        let verifier = StubVerifier(result: .init(isValid: true, observedDigest: "abc", detail: "signed"))
        let health = StubHealthChecker(result: .init(isHealthy: false, detail: "launch failed"))
        let service = TatwoBundleActivationService(
            fileSystem: fileSystem,
            verifier: verifier,
            healthChecker: health,
            receiptID: { "receipt-fixed" },
            now: { Date(timeIntervalSince1970: 1) }
        )
        let boundary = try makeBoundary()

        let verification = try service.verify(
            TatwoBundleVerifyRequestV1(
                boundary: boundary,
                stagedBundle: TatwoBundlePathV1("/staging/Tatwo.app", role: .stagedBundle),
                expectedArtifactDigest: "abc",
                correlationID: "update-1"
            )
        )
        let healthReceipt = try service.healthCheck(
            TatwoBundleHealthCheckRequestV1(
                boundary: boundary,
                activeBundle: TatwoBundlePathV1("/Applications/Tatwo.app", role: .activeBundle),
                policy: TatwoModuleHealthPolicyV1(kind: .executableProbe, timeoutSeconds: 5),
                correlationID: "update-1"
            )
        )

        XCTAssertTrue(fileSystem.events.isEmpty)
        XCTAssertEqual(verification.outcome, .succeeded)
        XCTAssertEqual(verification.detail, "signed")
        XCTAssertEqual(healthReceipt.outcome, .failed)
        XCTAssertEqual(healthReceipt.detail, "launch failed")
        XCTAssertEqual(verifier.requests.count, 1)
        XCTAssertEqual(health.requests.count, 1)
    }

    func testBundleActivationPortIsSpyInjectableWithPublicValueTypes() throws {
        let spy = BundleActivationSpy()
        let consumer = ExampleUpdaterConsumer(activation: spy)
        let boundary = try makeBoundary()

        let receipt = try consumer.stage(
            source: TatwoBundlePathV1("/download/Tatwo.app", role: .sourceArtifact),
            destination: TatwoBundlePathV1("/stage/Tatwo.app", role: .stagedBundle),
            boundary: boundary
        )

        XCTAssertEqual(spy.invocations.count, 1)
        XCTAssertEqual(spy.invocations.first?.operation, .stage)
        XCTAssertEqual(receipt.isolationEvidence.userDataWriteCount, 0)
    }

    func testBundleOnlyEvidenceRejectsDecodedNonBundleWrites() {
        let unsafeJSON = """
        {
          "scope": "bundleOnly",
          "bundlePaths": [],
          "userDataWriteCount": 1,
          "domainLedgerWriteCount": 0
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(TatwoBundleOnlyMutationEvidenceV1.self, from: unsafeJSON)
        )
    }

    func testStageRejectsSymlinkEscapeFromAllowedStagingRoot() throws {
        let fixture = try makeSymlinkFixture("allowed-root-escape")
        let allowedRoot = fixture.appendingPathComponent("allowed", isDirectory: true)
        let outsideRoot = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: allowedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: allowedRoot.appendingPathComponent("escape"),
            withDestinationURL: outsideRoot
        )

        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let request = TatwoBundleStageRequestV1(
            boundary: try makeBoundary(stagingRoots: [allowedRoot.path]),
            sourceBundle: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact),
            stagedBundle: TatwoBundlePathV1(
                allowedRoot.appendingPathComponent("escape/Tatwo.app").path,
                role: .stagedBundle
            ),
            correlationID: "symlink-escape"
        )

        XCTAssertThrowsError(try service.stage(request)) { error in
            XCTAssertEqual(
                error as? TatwoBundleActivationError,
                .pathOutsideAllowedRoots(
                    candidate: allowedRoot.appendingPathComponent("escape/Tatwo.app").path,
                    allowedRoots: [allowedRoot.path]
                )
            )
        }
        XCTAssertTrue(fileSystem.events.isEmpty)
    }

    func testStageRejectsSymlinkAliasIntoProtectedUserDataRoot() throws {
        let fixture = try makeSymlinkFixture("protected-root-alias")
        let allowedRoot = fixture.appendingPathComponent("allowed", isDirectory: true)
        let protectedRoot = fixture.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(
            at: allowedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: protectedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: allowedRoot.appendingPathComponent("protected-link"),
            withDestinationURL: protectedRoot
        )

        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let candidate = allowedRoot.appendingPathComponent("protected-link/Tatwo.app").path
        let request = TatwoBundleStageRequestV1(
            boundary: try makeBoundary(
                stagingRoots: [allowedRoot.path],
                protectedUserDataRoots: [protectedRoot.path]
            ),
            sourceBundle: TatwoBundlePathV1("/downloads/Tatwo.app", role: .sourceArtifact),
            stagedBundle: TatwoBundlePathV1(candidate, role: .stagedBundle),
            correlationID: "protected-symlink"
        )

        XCTAssertThrowsError(try service.stage(request)) { error in
            XCTAssertEqual(
                error as? TatwoBundleActivationError,
                .protectedPathOverlap(
                    candidate: candidate,
                    protectedRoot: protectedRoot.path,
                    kind: .userData
                )
            )
        }
        XCTAssertTrue(fileSystem.events.isEmpty)
    }

    func testActiveBundleRejectsSymlinkAliasThatDoesNotMatchCanonicalInstallRoot() throws {
        let fixture = try makeSymlinkFixture("active-root-alias")
        let configuredInstallRoot = fixture.appendingPathComponent("Applications/Tatwo.app")
        let outsideRoot = fixture.appendingPathComponent("outside", isDirectory: true)
        let aliasRoot = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configuredInstallRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideRoot.appendingPathComponent("Tatwo.app"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: aliasRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasRoot.appendingPathComponent("Tatwo.app"),
            withDestinationURL: outsideRoot.appendingPathComponent("Tatwo.app")
        )

        let fileSystem = RecordingBundleFileSystem()
        let service = makeService(fileSystem: fileSystem)
        let activeAlias = aliasRoot.appendingPathComponent("Tatwo.app").path
        let boundary = try makeBoundary(installRoot: configuredInstallRoot.path)

        XCTAssertThrowsError(
            try service.healthCheck(
                TatwoBundleHealthCheckRequestV1(
                    boundary: boundary,
                    activeBundle: TatwoBundlePathV1(activeAlias, role: .activeBundle),
                    policy: TatwoModuleHealthPolicyV1(kind: .executableProbe, timeoutSeconds: 5),
                    correlationID: "active-symlink"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? TatwoBundleActivationError,
                .activeBundleMismatch(
                    candidate: activeAlias,
                    installRoot: configuredInstallRoot.path
                )
            )
        }
        XCTAssertTrue(fileSystem.events.isEmpty)
    }

    private func makeService(
        fileSystem: RecordingBundleFileSystem
    ) -> TatwoBundleActivationService {
        TatwoBundleActivationService(
            fileSystem: fileSystem,
            verifier: StubVerifier(result: .init(isValid: true, observedDigest: "abc", detail: "ok")),
            healthChecker: StubHealthChecker(result: .init(isHealthy: true, detail: "ok")),
            receiptID: { "receipt-fixed" },
            now: { Date(timeIntervalSince1970: 1) }
        )
    }

    private func makeBoundary(
        installRoot: String = "/Applications/Tatwo.app",
        stagingRoots: [String] = ["/staging", "/downloads"],
        archiveRoots: [String] = ["/archives"],
        protectedUserDataRoots: [String] = ["/Users/test/Library/Application Support/Tatwo"],
        protectedDomainLedgerRoots: [String] = [
            "/Users/test/Library/Application Support/Tatwo/domain-ledger"
        ]
    ) throws -> TatwoBundleActivationBoundaryV1 {
        TatwoBundleActivationBoundaryV1(
            moduleID: try TatwoModuleIDV1("tatwo.app"),
            installRoot: installRoot,
            stagingRoots: stagingRoots,
            archiveRoots: archiveRoots,
            protectedUserDataRoots: protectedUserDataRoots,
            protectedDomainLedgerRoots: protectedDomainLedgerRoots
        )
    }

    private func makeSymlinkFixture(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-deployment-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}

private final class RecordingBundleFileSystem: TatwoBundleFileSystemPort {
    enum Event: Equatable {
        case stage(String, String)
        case archive(String, String)
        case atomicSwap(String, String)
        case rollback(String, String)
    }

    private(set) var events: [Event] = []

    func stageBundle(from source: TatwoBundlePathV1, to staged: TatwoBundlePathV1) throws {
        events.append(.stage(source.path, staged.path))
    }

    func archiveBundle(from current: TatwoBundlePathV1, to archive: TatwoBundlePathV1) throws {
        events.append(.archive(current.path, archive.path))
    }

    func atomicSwap(staged: TatwoBundlePathV1, active: TatwoBundlePathV1) throws {
        events.append(.atomicSwap(staged.path, active.path))
    }

    func rollbackBundle(from archive: TatwoBundlePathV1, to active: TatwoBundlePathV1) throws {
        events.append(.rollback(archive.path, active.path))
    }
}

private final class StubVerifier: TatwoBundleVerifierPort {
    let result: TatwoBundleVerificationResultV1
    private(set) var requests: [TatwoBundleVerifyRequestV1] = []

    init(result: TatwoBundleVerificationResultV1) {
        self.result = result
    }

    func verifyBundle(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleVerificationResultV1 {
        requests.append(request)
        return result
    }
}

private final class StubHealthChecker: TatwoBundleHealthCheckPort {
    let result: TatwoBundleHealthCheckResultV1
    private(set) var requests: [TatwoBundleHealthCheckRequestV1] = []

    init(result: TatwoBundleHealthCheckResultV1) {
        self.result = result
    }

    func healthCheckBundle(_ request: TatwoBundleHealthCheckRequestV1) throws -> TatwoBundleHealthCheckResultV1 {
        requests.append(request)
        return result
    }
}

private final class BundleActivationSpy: TatwoBundleActivationPort {
    private(set) var invocations: [TatwoBundleActivationInvocationV1] = []

    func stage(_ request: TatwoBundleStageRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        invocations.append(.stage(request))
        return .succeeded(
            operation: .stage,
            moduleID: request.boundary.moduleID,
            correlationID: request.correlationID,
            receiptID: "spy-stage",
            createdAt: Date(timeIntervalSince1970: 1),
            bundlePaths: [request.sourceBundle, request.stagedBundle],
            detail: "spy"
        )
    }

    func verify(_ request: TatwoBundleVerifyRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        fatalError("not used")
    }

    func archiveCurrent(_ request: TatwoBundleArchiveCurrentRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        fatalError("not used")
    }

    func atomicSwap(_ request: TatwoBundleAtomicSwapRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        fatalError("not used")
    }

    func healthCheck(_ request: TatwoBundleHealthCheckRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        fatalError("not used")
    }

    func rollbackBundle(_ request: TatwoBundleRollbackRequestV1) throws -> TatwoBundleOperationReceiptV1 {
        fatalError("not used")
    }
}

private struct ExampleUpdaterConsumer {
    let activation: any TatwoBundleActivationPort

    func stage(
        source: TatwoBundlePathV1,
        destination: TatwoBundlePathV1,
        boundary: TatwoBundleActivationBoundaryV1
    ) throws -> TatwoBundleOperationReceiptV1 {
        try activation.stage(
            TatwoBundleStageRequestV1(
                boundary: boundary,
                sourceBundle: source,
                stagedBundle: destination,
                correlationID: "updater-test"
            )
        )
    }
}
