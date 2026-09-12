import XCTest
@testable import TatwoUltraworkMac

final class FlexPrimaryStatusTests: XCTestCase {
    private func makeTempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flex-primary-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testUnassignedWhenNoPrimaryFile() {
        let root = makeTempRoot()
        let state = TatwoFlexPrimaryReader.read(appSupportRoot: root)
        XCTAssertFalse(state.isAssigned)
        XCTAssertFalse(state.isLocalPrimary)
        XCTAssertNil(state.currentPrimaryName)
    }

    func testReadsPrimaryAndDetectsLocalMatch() throws {
        let root = makeTempRoot()
        try "{\"name\":\"mac-mini\",\"createdAt\":\"2026-07-22T00:00:00Z\"}"
            .write(
                to: root.appendingPathComponent("device-identity.json"),
                atomically: true,
                encoding: .utf8
            )
        let channelDir = root.appendingPathComponent("device-sync-channel", isDirectory: true)
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try "{\"name\":\"mac-mini\",\"epoch\":3,\"changedAt\":\"2026-07-22T10:00:00Z\"}"
            .write(
                to: channelDir.appendingPathComponent("primary.json"),
                atomically: true,
                encoding: .utf8
            )

        let state = TatwoFlexPrimaryReader.read(appSupportRoot: root)
        XCTAssertTrue(state.isAssigned)
        XCTAssertTrue(state.isLocalPrimary)
        XCTAssertEqual(state.currentPrimaryName, "mac-mini")
        XCTAssertEqual(state.epoch, 3)
    }

    func testDetectsSecondaryWhenPrimaryIsAnotherDevice() throws {
        let root = makeTempRoot()
        try "{\"name\":\"macbook-m3\"}"
            .write(
                to: root.appendingPathComponent("device-identity.json"),
                atomically: true,
                encoding: .utf8
            )
        let channelDir = root.appendingPathComponent("device-sync-channel", isDirectory: true)
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try "{\"name\":\"mac-mini\",\"epoch\":1,\"changedAt\":\"2026-07-22T10:00:00Z\"}"
            .write(
                to: channelDir.appendingPathComponent("primary.json"),
                atomically: true,
                encoding: .utf8
            )

        let state = TatwoFlexPrimaryReader.read(appSupportRoot: root)
        XCTAssertTrue(state.isAssigned)
        XCTAssertFalse(state.isLocalPrimary)
        XCTAssertEqual(state.currentPrimaryName, "mac-mini")
        XCTAssertEqual(state.localDeviceName, "macbook-m3")
    }
}
