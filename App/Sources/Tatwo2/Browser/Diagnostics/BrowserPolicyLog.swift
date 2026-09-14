import Foundation

/// Sync policy entry points are not all MainActor-isolated. No disk writes or raw URLs.
final class BrowserPolicyLog: @unchecked Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UInt64
        let time: Date
        let host: String
        let decision: String
        let actor: String
    }

    static let shared = BrowserPolicyLog()
    static let capacity = 200
    private let lock = NSLock()
    private var storage = [Entry?](repeating: nil, count: capacity)
    private var next = 0
    private var sequence: UInt64 = 0

    func record(host: String? = nil, decision: String, actor: String) {
        let host = BrowserDiagnosticsPrivacy.host(host)
        let decision = BrowserDiagnosticsPrivacy.text(decision)
        let actor = BrowserDiagnosticsPrivacy.text(actor)
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        storage[next] = Entry(id: sequence, time: Date(), host: host, decision: decision, actor: actor)
        next = (next + 1) % Self.capacity
    }

    func recent(_ limit: Int = 50) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        let ordered = (storage[next...] + storage[..<next]).compactMap { $0 }
        return Array(ordered.suffix(max(0, min(limit, Self.capacity))))
    }
}
