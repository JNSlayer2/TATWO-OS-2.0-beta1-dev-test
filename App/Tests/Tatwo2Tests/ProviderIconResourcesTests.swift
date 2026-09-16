import Foundation
import XCTest
@testable import Tatwo2

final class ProviderIconResourcesTests: XCTestCase {
    func testPackagedMacOSAppFindsResourceBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("App.app/Contents/Resources")
        let icon = resources.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle/ProviderIcon-codex.svg")
        try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: icon)
        XCTAssertEqual(ProviderIconResources.url(for: "ProviderIcon-codex", roots: [resources]), icon)
    }

    func testMissingBundleReturnsNilInsteadOfTrapping() {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(ProviderIconResources.url(for: "ProviderIcon-codex", roots: [absent]))
    }

    func testDevelopmentBundleWithProviderIconsSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let icon = root.appendingPathComponent("TatwoUltrawork_Tatwo2.bundle/ProviderIcons/ProviderIcon-claude.svg")
        try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<svg/>".utf8).write(to: icon)
        XCTAssertEqual(ProviderIconResources.url(for: "ProviderIcon-claude", roots: [root]), icon)
    }
}
