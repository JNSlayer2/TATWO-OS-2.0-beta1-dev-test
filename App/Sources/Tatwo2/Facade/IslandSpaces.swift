// island-core: new container data; no legacy governance implementation.
import Foundation

enum IslandSpaceKind: String, Codable, CaseIterable { case work, music, quotes }
struct IslandSpaceRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: IslandSpaceKind
    var title: String
    var enabled: Bool
    var order: Int
    var settings: [String: String]
    static var defaults: [Self] {
        [
            Self(id: UUID(), kind: .work, title: "工作", enabled: true, order: 0, settings: [:]),
            // 2026-09-12 停用音樂／行情預設頁；保留 kind 解碼相容性，不改寫既有 island.json。
            // Self(id: UUID(), kind: .music, title: "音樂", enabled: true, order: 1, settings: [:]),
            // Self(id: UUID(), kind: .quotes, title: "行情", enabled: true, order: 2,
            //      settings: ["symbols": "BINANCE:BTCUSDT,BINANCE:ETHUSDT"]),
        ]
    }
}
final class IslandSpaceStore: @unchecked Sendable {
    static var liveRoot: URL {
        ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("tatwo2/live")
    }
    let url: URL
    private let queue = DispatchQueue(label: "tatwo2.island.store", qos: .utility)
    init(root: URL = IslandSpaceStore.liveRoot) { url = root.appendingPathComponent("island.json") }
    private func decode() throws -> [IslandSpaceRecord] {
        let rows = try JSONDecoder().decode([IslandSpaceRecord].self, from: Data(contentsOf: url))
        guard Set(rows.map(\.id)).count == rows.count else { throw CocoaError(.fileReadCorruptFile) }
        return rows
    }
    func load() async throws -> [IslandSpaceRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if FileManager.default.fileExists(atPath: self.url.path) {
                        continuation.resume(returning: try self.decode())
                    } else {
                        let rows = IslandSpaceRecord.defaults
                        try self.write(rows)
                        continuation.resume(returning: rows)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func write(_ rows: [IslandSpaceRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(rows).write(to: url, options: .atomic)
    }
    func save(_ rows: [IslandSpaceRecord]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    // Never replace corrupt or unsupported data, including corruption after load.
                    if FileManager.default.fileExists(atPath: self.url.path) { _ = try self.decode() }
                    guard Set(rows.map(\.id)).count == rows.count else { throw CocoaError(.fileWriteUnknown) }
                    try self.write(rows); continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
struct IslandSpaceSnapshot {
    var lines: [String] = []
}
@MainActor protocol IslandSpaceProvider: AnyObject {
    func activate()
    func suspend()
    func unload()
    var snapshot: IslandSpaceSnapshot { get }
}
