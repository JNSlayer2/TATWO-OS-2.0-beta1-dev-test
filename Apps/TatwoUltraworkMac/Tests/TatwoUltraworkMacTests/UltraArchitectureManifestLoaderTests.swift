import Foundation
import XCTest
@testable import TatwoUltraworkMac

final class UltraArchitectureManifestLoaderTests: XCTestCase {
    func testInjectedBundleLoadsReadableManifest() throws {
        let bundle = try makeBundle(
            manifest: """
            {
              "schema": "TatwoOsManifestV1",
              "sourceId": "TATWO-ULTRAWORKos/os.md",
              "sourceSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "generatedAt": "2026-07-29T00:00:00.000Z",
              "sections": [
                {
                  "id": "meta-rule",
                  "title": "元規則（防漂移）",
                  "items": ["單一真相源"]
                },
                {
                  "id": "9.5",
                  "title": "記錄機制（防人忘/防 AI 亂）",
                  "items": ["fixture manifest"]
                }
              ]
            }
            """
        )
        let state = UltraArchitectureManifestLoader.load(from: bundle)
        let manifest = try XCTUnwrap(state.manifest)

        XCTAssertEqual(manifest.schema, "TatwoOsManifestV1")
        XCTAssertEqual(manifest.sections.map(\.id), ["meta-rule", "9.5"])
        XCTAssertEqual(manifest.sections[1].items, ["fixture manifest"])
    }

    func testInjectedBundleWithoutManifestDegradesGracefully() throws {
        let emptyBundle = try makeBundle(manifest: nil)
        XCTAssertEqual(
            UltraArchitectureManifestLoader.load(from: emptyBundle),
            .missing
        )
    }

    func testInjectedBundleWithInvalidManifestFailsClosed() throws {
        let bundle = try makeBundle(manifest: "{ not-json }")
        guard case let .invalid(message) = UltraArchitectureManifestLoader.load(from: bundle) else {
            return XCTFail("invalid JSON must not be treated as a loaded manifest")
        }
        XCTAssertTrue(message.contains("manifest JSON"))
    }

    private func makeBundle(manifest: String?) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.tatwo.tests.\(UUID().uuidString)",
            "CFBundleName": "UltraArchitectureManifestFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))

        if let manifest {
            try manifest.write(
                to: resources.appendingPathComponent("os-architecture-standard.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        return try XCTUnwrap(Bundle(url: root))
    }
}
