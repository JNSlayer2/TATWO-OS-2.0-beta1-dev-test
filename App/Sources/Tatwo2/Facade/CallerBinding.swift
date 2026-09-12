import Foundation
import CryptoKit

/// Returns the last completed size immediately. One serial worker, at most 256 cached paths.
final class CallerDirectoryCache: @unchecked Sendable {
    struct Snapshot {
        var exists = false
        var megabytes = 0
        var measuredAt: Date? = nil
        func isStale(at now: Date = Date()) -> Bool {
            guard let measuredAt else { return true }
            return now.timeIntervalSince(measuredAt) > 60
        }
    }
    static let shared = CallerDirectoryCache()
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "ai.tatwo.caller-directory", qos: .utility)
    private var values: [String: Snapshot] = [:]
    private var pending: Set<String> = []
    private var dates: [String: Date] = [:]
    private let measure: (String) -> Snapshot?
    init(measure: @escaping (String) -> Snapshot? = CallerDirectoryCache.measure) { self.measure = measure }

    func snapshot(_ path: String?) -> Snapshot {
        guard let path else { return Snapshot() }
        lock.lock()
        let previous = values[path] ?? Snapshot()
        guard !pending.contains(path), Date().timeIntervalSince(dates[path] ?? .distantPast) > 30,
              pending.count < 256 else { lock.unlock(); return previous }
        if values[path] == nil, values.count >= 256 {
            guard let old = values.keys.first(where: { !pending.contains($0) }) else { lock.unlock(); return previous }
            values[old] = nil; dates[old] = nil
        }
        values[path] = previous
        pending.insert(path)
        lock.unlock()
        worker.async { [self] in
            let measured = measure(path)
            lock.lock()
            if var measured { measured.measuredAt = Date(); values[path] = measured }
            dates[path] = Date(); pending.remove(path)
            lock.unlock()
        }
        return previous
    }

    private static func measure(_ path: String) -> Snapshot? {
        precondition(!Thread.isMainThread)
        guard FileManager.default.fileExists(atPath: path) else { return Snapshot() }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sm", path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { process.terminate(); return nil }
            guard process.terminationStatus == 0,
                  let data = try pipe.fileHandleForReading.read(upToCount: 4096),
                  let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).first,
                  let mb = Int(first) else { return nil }
            return Snapshot(exists: true, megabytes: mb)
        } catch { return nil }
    }
}

/// Same source precedence as OSUpstream.declaration; bounded read, no inferred identity.
enum CallerUpstream {
    static func identity() -> [String: Any] {
        var candidates: [(String, String)] = [("entry", OSUpstream.overridePath)]
        if let bundle = Bundle.module.url(forResource: "os-upstream", withExtension: "md")
            ?? Bundle.main.url(forResource: "os-upstream", withExtension: "md") {
            candidates.append(("bundle", bundle.path))
        }
        candidates.append(("entry", "\(NSHomeDirectory())/Library/Application Support/tatwo2/docs/os-upstream.md"))
        for (source, path) in candidates {
            guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { continue }
            defer { try? file.close() }
            guard let data = try? file.read(upToCount: 1_048_577), !data.isEmpty else { continue }
            // An oversized/invalid higher-priority source must not be attributed to a lower source.
            guard data.count <= 1_048_576, String(data: data, encoding: .utf8) != nil else { break }
            return ["source": source, "path": path, "hash": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        return ["source": NSNull(), "path": NSNull(), "hash": NSNull()]
    }
}
