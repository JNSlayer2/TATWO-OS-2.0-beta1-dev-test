import XCTest
@testable import TatwoUltraworkCore

final class TatwoPluginRegistryPartitionTests: XCTestCase {
    func testPartitionSplitsByKindAndKeepsOrder() {
        let entries = [
            makeEntry(id: "s1", kind: .skill),
            makeEntry(id: "m1", kind: .mcp),
            makeEntry(id: "a1", kind: .app),
            makeEntry(id: "s2", kind: .skill),
            makeEntry(id: "m2", kind: .mcp),
            makeEntry(id: "r1", kind: .localRuntime),
            makeEntry(id: "p1", kind: .plugin)
        ]

        let partition = TatwoPluginRegistryPartition.make(entries)

        XCTAssertEqual(partition.mcp.map(\.id), ["m1", "m2"])
        XCTAssertEqual(partition.skills.map(\.id), ["s1", "s2"])
        XCTAssertEqual(partition.other.map(\.id), ["a1", "r1", "p1"])
    }

    func testPartitionOfEmptyListIsEmpty() {
        let partition = TatwoPluginRegistryPartition.make([])
        XCTAssertTrue(partition.mcp.isEmpty)
        XCTAssertTrue(partition.skills.isEmpty)
        XCTAssertTrue(partition.other.isEmpty)
    }

    private func makeEntry(id: String, kind: RegistryKind) -> PluginRegistryEntry {
        PluginRegistryEntry(
            id: id,
            name: id,
            kind: kind,
            purpose: "test",
            trigger: "manual",
            safetyLevel: .low,
            requiredForModes: [],
            publicInstallHint: "test"
        )
    }
}
