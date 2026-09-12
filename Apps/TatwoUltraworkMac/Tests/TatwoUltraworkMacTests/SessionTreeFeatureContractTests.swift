import Foundation
import XCTest

final class SessionTreeFeatureContractTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testFeatureProvidesARealChildSessionTreeInsteadOfOnlyRenderingRows() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoNativeSessionTree.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("public enum TatwoNativeSessionTree"))
        XCTAssertTrue(source.contains("public static func forkDiscussion("))
        XCTAssertTrue(source.contains("public static func mergeReceipt("))
    }
}
