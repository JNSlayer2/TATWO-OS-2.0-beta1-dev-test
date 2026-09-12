import Foundation

// 本機動作 outbox：由「本機」執行的動作（不需經過現任主機器）。
// App 只寫 intent；本機常駐 helper（scripts/tatwo-sync-helper.sh）輪詢執行並回寫 receipt。
// - setPrimary(target): 把 target 設為主設備。本機是目前主時可轉移給任何副設備；
//   尚未設定主時任一設備可自行設為主（target = 本機自己）。
// - pushVersion: 把本機的程式碼改動回傳（副→主），不需現任主權限，永遠可執行。
// - createPairing: 產生限時 3 分鐘、單次有效的配對代碼，供新設備納管時驗證身分，
//   避免納管指令外流後被長期重複使用。

struct DeviceLocalActionIntent: Codable, Equatable, Sendable {
    let kind: String
    let target: String?
    let requestedAt: Date
}

struct DeviceLocalActionReceipt: Codable, Equatable, Sendable {
    let kind: String
    let target: String?
    let requestedAt: Date
    let result: String
    let completedAt: Date
    let message: String
    let pairingSeed: String?
    let pairingExpiresAt: Date?
}

enum TatwoDeviceLocalActionKind: String {
    case setPrimary = "set-primary"
    case pushVersion = "push-version"
    case createPairing = "create-pairing"
}

struct DeviceLocalActionOutboxStore: Sendable {
    private let rootURL: URL
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    init(
        rootURL: URL = DeviceSyncOutboxStore.defaultApplicationSupportRootPublic(),
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.rootURL = rootURL
        self.now = now
        self.uuid = uuid
    }

    @discardableResult
    func enqueue(
        kind: TatwoDeviceLocalActionKind,
        target: String? = nil
    ) throws -> DeviceLocalActionIntent {
        let intent = DeviceLocalActionIntent(kind: kind.rawValue, target: target, requestedAt: now())
        let pendingURL = actionsRootURL.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingURL,
            withIntermediateDirectories: true
        )
        let destination = pendingURL.appendingPathComponent(
            "\(uuid().uuidString).json",
            isDirectory: false
        )
        try DeviceSyncOutboxJSON.encoder.encode(intent).write(
            to: destination,
            options: [.atomic]
        )
        return intent
    }

    func pendingIntents() throws -> [DeviceLocalActionIntent] {
        try decodeJSONFiles(
            in: actionsRootURL.appendingPathComponent("pending", isDirectory: true),
            as: DeviceLocalActionIntent.self
        )
    }

    /// 同一 kind 的全部 receipts（新到舊排序）。「轉移主權」需依 target 分開追蹤，
    /// 不能只取單一最新值（否則會被別台設備的結果蓋掉）。
    func receipts(kind: TatwoDeviceLocalActionKind) throws -> [DeviceLocalActionReceipt] {
        try decodeJSONFiles(
            in: actionsRootURL.appendingPathComponent("receipts", isDirectory: true),
            as: DeviceLocalActionReceipt.self
        )
        .filter { $0.kind == kind.rawValue }
        .sorted { $0.completedAt > $1.completedAt }
    }

    func latestReceipt(kind: TatwoDeviceLocalActionKind) throws -> DeviceLocalActionReceipt? {
        try receipts(kind: kind).first
    }

    private var actionsRootURL: URL {
        rootURL.appendingPathComponent("device-local-actions", isDirectory: true)
    }

    private func decodeJSONFiles<Value: Decodable>(
        in directory: URL,
        as type: Value.Type
    ) throws -> [Value] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? DeviceSyncOutboxJSON.decoder.decode(type, from: data)
        }
    }
}
