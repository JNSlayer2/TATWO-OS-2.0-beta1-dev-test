import Foundation
import XCTest
@testable import TatwoUltraworkCore

final class TatwoSyncCatalogDocumentTests: XCTestCase {
    func testVersionedRepositoryCatalogPassesValidator() throws {
        let catalogURL = repositoryRoot()
            .appendingPathComponent("config/tatwo-sync-catalog-v1.json")
        let document = try TatwoSyncCatalogDocumentV1.load(from: catalogURL)

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertFalse(document.catalogRevision.isEmpty)
        XCTAssertTrue(document.persistentSurfaceIDs.contains("os.constitution"))
        XCTAssertTrue(document.persistentSurfaceIDs.contains("os.issue"))
        XCTAssertTrue(document.persistentSurfaceIDs.contains("skills.skillet"))
        XCTAssertTrue(document.persistentSurfaceIDs.contains("machine.keychain"))
        XCTAssertEqual(
            document.systemPullItemIDs,
            ["os.constitution", "os.issue", "os.todo", "skills.skillet"]
        )
        XCTAssertTrue(document.deferredSystemPullItemIDs.contains("registry.models"))
        XCTAssertNoThrow(try document.validate())
    }

    func testBundledCatalogMatchesRepositoryCatalog() throws {
        let repositoryDocument = try TatwoSyncCatalogDocumentV1.load(
            from: repositoryRoot()
                .appendingPathComponent("config/tatwo-sync-catalog-v1.json")
        )
        let bundledDocument = try TatwoSyncCatalogDocumentV1.loadBundled()

        XCTAssertEqual(bundledDocument, repositoryDocument)
        XCTAssertEqual(
            bundledDocument.systemPullItemIDs,
            ["os.constitution", "os.issue", "os.todo", "skills.skillet"]
        )
    }

    func testDocumentFailsClosedWhenPersistentSurfaceIsNotRegistered() throws {
        let document = TatwoSyncCatalogDocumentV1(
            schemaVersion: 1,
            catalogRevision: "test-revision",
            persistentSurfaceIDs: ["os.issue", "os.todo"],
            entries: [
                .init(
                    id: "os.issue",
                    displayName: "issue.md",
                    kind: .osDocument,
                    scope: .shared,
                    relativePath: "os/issue.md",
                    mergePolicy: .markdownSections,
                    activationPolicy: .automaticAfterValidation,
                    requiredOnDevices: ["all-enrolled-devices"]
                )
            ]
        )

        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogError,
                .unregisteredPersistentSurface(["os.todo"])
            )
        }
    }

    func testIndependentInventoryCatchesSurfaceDeletedFromBothCatalogLists() throws {
        let document = TatwoSyncCatalogDocumentV1(
            schemaVersion: 1,
            catalogRevision: "test-revision",
            persistentSurfaceIDs: ["os.todo"],
            systemPullItemIDs: ["os.todo"],
            entries: [
                .init(
                    id: "os.todo",
                    displayName: "TODO.md",
                    kind: .osDocument,
                    scope: .shared,
                    relativePath: "os/TODO.md",
                    mergePolicy: .markdownSections,
                    activationPolicy: .automaticAfterValidation,
                    requiredOnDevices: ["all-enrolled-devices"]
                )
            ]
        )
        let inventory = TatwoDurableSurfaceInventoryDocumentV1(
            inventoryRevision: "inventory-test",
            surfaceIDs: ["os.issue", "os.todo"]
        )

        XCTAssertThrowsError(try document.validate(against: inventory)) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogDocumentError,
                .catalogInventoryMismatch(missing: ["os.issue"], unknown: [])
            )
        }
    }

    func testOSTodoMirrorPathKeepsCanonicalTODOFilenameCase() throws {
        let document = try TatwoSyncCatalogDocumentV1.load(
            from: repositoryRoot()
                .appendingPathComponent("config/tatwo-sync-catalog-v1.json")
        )
        let bundled = try TatwoSyncCatalogDocumentV1.loadBundled()
        let entry = try XCTUnwrap(document.entries.first { $0.id == "os.todo" })
        let bundledEntry = try XCTUnwrap(bundled.entries.first { $0.id == "os.todo" })
        let relativePath = try XCTUnwrap(entry.relativePath)
        let bundledRelativePath = try XCTUnwrap(bundledEntry.relativePath)

        // Source OS file is TODO.md; mirror relative path must preserve that case.
        XCTAssertEqual(relativePath, "os/TODO.md")
        XCTAssertEqual(bundledRelativePath, "os/TODO.md")
        XCTAssertEqual(relativePath, bundledRelativePath)
        XCTAssertFalse(relativePath.hasSuffix("todo.md"))
        XCTAssertTrue(relativePath.hasSuffix("TODO.md"))
    }

    func testDocumentRejectsUnsupportedSchemaVersion() {
        let document = TatwoSyncCatalogDocumentV1(
            schemaVersion: 2,
            catalogRevision: "future",
            persistentSurfaceIDs: [],
            entries: []
        )

        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogDocumentError,
                .unsupportedSchemaVersion(2)
            )
        }
    }

    func testDocumentRejectsTransferableSurfaceWithoutSystemPullDecision() {
        let document = TatwoSyncCatalogDocumentV1(
            catalogRevision: "test-revision",
            persistentSurfaceIDs: ["os.issue"],
            entries: [
                .init(
                    id: "os.issue",
                    displayName: "issue.md",
                    kind: .osDocument,
                    scope: .shared,
                    relativePath: "os/issue.md",
                    mergePolicy: .markdownSections,
                    activationPolicy: .automaticAfterValidation,
                    requiredOnDevices: ["all-enrolled-devices"]
                )
            ]
        )

        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(
                error as? TatwoSyncCatalogDocumentError,
                .unclassifiedTransferableSurface(["os.issue"])
            )
        }
    }

    private func repositoryRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["TATWO_REPOSITORY_ROOT"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
