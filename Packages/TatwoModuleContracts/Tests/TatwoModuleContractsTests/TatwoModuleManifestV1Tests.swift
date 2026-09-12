import Foundation
import XCTest
@testable import TatwoModuleContracts

final class TatwoModuleManifestV1Tests: XCTestCase {
    func testManifestCarriesEveryBootstrapContractWithoutEffectfulCapabilities() throws {
        let manifest = try makeManifest(
            id: "tatwo.app",
            dependencies: [
                TatwoModuleDependencyV1(
                    moduleID: try TatwoModuleIDV1("tatwo.runtime"),
                    minimumVersion: TatwoModuleVersionV1(major: 1, minor: 2, patch: 0)
                )
            ]
        )

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.moduleID.rawValue, "tatwo.app")
        XCTAssertEqual(manifest.version, TatwoModuleVersionV1(major: 2, minor: 1, patch: 3))
        XCTAssertEqual(manifest.dependencies.map(\.moduleID.rawValue), ["tatwo.runtime"])
        XCTAssertEqual(manifest.locations.install.path, "/Applications/Tatwo.app")
        XCTAssertEqual(manifest.locations.data.path, "/Users/test/Library/Application Support/Tatwo")
        XCTAssertEqual(manifest.locations.cache.path, "/Users/test/Library/Caches/Tatwo")
        XCTAssertEqual(manifest.health.kind, .executableProbe)
        XCTAssertEqual(manifest.migration.mode, .explicitUserApproval)
        XCTAssertEqual(manifest.rollback.scope, .bundleOnly)
        XCTAssertEqual(manifest.reset.resettableArtifacts, [.cache, .stagedBundle, .generatedState])
        XCTAssertTrue(manifest.reset.preservesUserData)
        XCTAssertTrue(manifest.reset.preservesDomainLedger)
    }

    func testResetPolicyCannotRepresentUserDataOrDomainLedgerDeletion() {
        let policy = TatwoModuleResetPolicyV1(
            resettableArtifacts: [.cache, .stagedBundle, .generatedState]
        )

        XCTAssertEqual(Set(policy.resettableArtifacts), Set(TatwoResettableArtifactV1.allCases))
        XCTAssertTrue(policy.preservesUserData)
        XCTAssertTrue(policy.preservesDomainLedger)
    }

    func testResetPolicyRejectsDecodedPayloadThatClaimsDestructiveReset() {
        let unsafeJSON = """
        {
          "resettableArtifacts": ["cache"],
          "preservesUserData": false,
          "preservesDomainLedger": true
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(TatwoModuleResetPolicyV1.self, from: unsafeJSON)
        )
    }

    func testManifestRejectsDuplicateDependenciesAndSelfDependency() throws {
        let runtime = try TatwoModuleIDV1("tatwo.runtime")

        XCTAssertThrowsError(
            try makeManifest(
                id: "tatwo.app",
                dependencies: [
                    TatwoModuleDependencyV1(moduleID: runtime),
                    TatwoModuleDependencyV1(moduleID: runtime)
                ]
            )
        ) { error in
            XCTAssertEqual(error as? TatwoModuleManifestValidationError, .duplicateDependency(runtime))
        }

        let app = try TatwoModuleIDV1("tatwo.app")
        XCTAssertThrowsError(
            try makeManifest(
                id: "tatwo.app",
                dependencies: [TatwoModuleDependencyV1(moduleID: app)]
            )
        ) { error in
            XCTAssertEqual(error as? TatwoModuleManifestValidationError, .selfDependency(app))
        }
    }

    func testManifestAndHealthSnapshotRoundTripAsImmutableCodableValues() throws {
        let manifest = try makeManifest(id: "tatwo.app")
        let manifestData = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(TatwoModuleManifestV1.self, from: manifestData), manifest)

        let snapshot = TatwoModuleHealthSnapshotV1(
            moduleID: manifest.moduleID,
            version: manifest.version,
            status: .healthy,
            observedAt: Date(timeIntervalSince1970: 10),
            detail: "verified"
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(TatwoModuleHealthSnapshotV1.self, from: snapshotData), snapshot)
    }

    private func makeManifest(
        id: String,
        dependencies: [TatwoModuleDependencyV1] = []
    ) throws -> TatwoModuleManifestV1 {
        try TatwoModuleManifestV1(
            moduleID: TatwoModuleIDV1(id),
            version: TatwoModuleVersionV1(major: 2, minor: 1, patch: 3),
            dependencies: dependencies,
            locations: TatwoModuleLocationsV1(
                install: TatwoModuleLocationDescriptorV1(
                    kind: .install,
                    path: "/Applications/Tatwo.app"
                ),
                data: TatwoModuleLocationDescriptorV1(
                    kind: .userData,
                    path: "/Users/test/Library/Application Support/Tatwo"
                ),
                cache: TatwoModuleLocationDescriptorV1(
                    kind: .cache,
                    path: "/Users/test/Library/Caches/Tatwo"
                )
            ),
            health: TatwoModuleHealthPolicyV1(
                kind: .executableProbe,
                timeoutSeconds: 5,
                successThreshold: 1
            ),
            migration: TatwoModuleMigrationPolicyV1(
                mode: .explicitUserApproval,
                currentSchemaVersion: 2
            ),
            rollback: TatwoModuleRollbackPolicyV1(
                scope: .bundleOnly,
                retainedVerifiedArchives: 2
            ),
            reset: TatwoModuleResetPolicyV1(
                resettableArtifacts: [.cache, .stagedBundle, .generatedState]
            )
        )
    }
}
