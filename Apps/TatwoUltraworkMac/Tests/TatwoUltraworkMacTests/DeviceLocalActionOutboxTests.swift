import XCTest
@testable import TatwoUltraworkMac

final class DeviceLocalActionOutboxTests: XCTestCase {
    private func makeTempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-action-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testEnqueueWritesPendingSetPrimaryIntentWithTarget() throws {
        let root = makeTempRoot()
        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let intent = try store.enqueue(kind: .setPrimary, target: "macbook-m3")
        XCTAssertEqual(intent.kind, "set-primary")
        XCTAssertEqual(intent.target, "macbook-m3")

        let pending = try store.pendingIntents()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.target, "macbook-m3")
    }

    func testEnqueuePushVersionHasNoTarget() throws {
        let root = makeTempRoot()
        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let intent = try store.enqueue(kind: .pushVersion)
        XCTAssertEqual(intent.kind, "push-version")
        XCTAssertNil(intent.target)
    }

    func testLatestReceiptReturnsNilWhenNoneWritten() throws {
        let root = makeTempRoot()
        let store = DeviceLocalActionOutboxStore(rootURL: root)
        XCTAssertNil(try store.latestReceipt(kind: .setPrimary))
    }

    func testLatestReceiptPicksMostRecentByCompletedAt() throws {
        let root = makeTempRoot()
        let receiptsDir = root
            .appendingPathComponent("device-local-actions", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)

        let older = DeviceLocalActionReceipt(
            kind: "set-primary",
            target: "mac-mini",
            requestedAt: Date(timeIntervalSince1970: 100),
            result: "failure",
            completedAt: Date(timeIntervalSince1970: 200),
            message: "old",
            pairingSeed: nil,
            pairingExpiresAt: nil
        )
        let newer = DeviceLocalActionReceipt(
            kind: "set-primary",
            target: "macbook-m3",
            requestedAt: Date(timeIntervalSince1970: 300),
            result: "success",
            completedAt: Date(timeIntervalSince1970: 400),
            message: "new",
            pairingSeed: nil,
            pairingExpiresAt: nil
        )
        try DeviceSyncOutboxJSON.encoder.encode(older)
            .write(to: receiptsDir.appendingPathComponent("a.json"))
        try DeviceSyncOutboxJSON.encoder.encode(newer)
            .write(to: receiptsDir.appendingPathComponent("b.json"))

        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let latest = try store.latestReceipt(kind: .setPrimary)
        XCTAssertEqual(latest?.message, "new")
        XCTAssertEqual(latest?.result, "success")
        XCTAssertEqual(latest?.target, "macbook-m3")
    }

    func testEnqueueCreatePairingHasNoTarget() throws {
        let root = makeTempRoot()
        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let intent = try store.enqueue(kind: .createPairing)
        XCTAssertEqual(intent.kind, "create-pairing")
        XCTAssertNil(intent.target)
    }

    func testPairingReceiptDecodesSeedAndExpiryWhenPresent() throws {
        let root = makeTempRoot()
        let receiptsDir = root
            .appendingPathComponent("device-local-actions", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)

        let receipt = DeviceLocalActionReceipt(
            kind: "create-pairing",
            target: nil,
            requestedAt: Date(timeIntervalSince1970: 100),
            result: "success",
            completedAt: Date(timeIntervalSince1970: 200),
            message: "配對代碼已產生",
            pairingSeed: "ABCD1234",
            pairingExpiresAt: Date(timeIntervalSince1970: 380)
        )
        try DeviceSyncOutboxJSON.encoder.encode(receipt)
            .write(to: receiptsDir.appendingPathComponent("a.json"))

        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let latest = try store.latestReceipt(kind: .createPairing)
        XCTAssertEqual(latest?.pairingSeed, "ABCD1234")
        XCTAssertEqual(latest?.pairingExpiresAt, Date(timeIntervalSince1970: 380))
    }

    func testOlderReceiptsWithoutPairingFieldsDecodeAsNil() throws {
        // 相容性：舊 receipt（set-primary/push-version）沒有 pairing 欄位也要能正常解碼。
        let root = makeTempRoot()
        let receiptsDir = root
            .appendingPathComponent("device-local-actions", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        let legacyJSON = """
        {"kind":"push-version","target":null,"requestedAt":"2026-07-22T00:00:00Z",
         "result":"success","completedAt":"2026-07-22T00:00:05Z","message":"ok"}
        """
        try legacyJSON.data(using: .utf8)!
            .write(to: receiptsDir.appendingPathComponent("legacy.json"))

        let store = DeviceLocalActionOutboxStore(rootURL: root)
        let latest = try store.latestReceipt(kind: .pushVersion)
        XCTAssertEqual(latest?.result, "success")
        XCTAssertNil(latest?.pairingSeed)
        XCTAssertNil(latest?.pairingExpiresAt)
    }
}
