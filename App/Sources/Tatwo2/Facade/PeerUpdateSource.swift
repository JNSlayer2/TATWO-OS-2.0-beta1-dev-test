import Foundation
import Darwin
import CryptoKit

struct PeerUpdateEntry: Codable, Sendable {
    var app: String?
    var runtime: String?
    var runtimeSha: String?
    var sha256: [String: String] = [:]
    var sizes: [String: Int64] = [:]
    var installedApp: String?
    var files: [String: String] = [:]
    private enum CodingKeys: String, CodingKey { case app, runtime, runtimeSha, sha256, sizes, installedApp, files }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        runtimeSha = try c.decodeIfPresent(String.self, forKey: .runtimeSha)
        installedApp = try c.decodeIfPresent(String.self, forKey: .installedApp)
        sha256 = try c.decodeIfPresent([String: String].self, forKey: .sha256) ?? [:]
        sizes = try c.decodeIfPresent([String: Int64].self, forKey: .sizes) ?? [:]
        files = try c.decodeIfPresent([String: String].self, forKey: .files) ?? [:]
    }
}

enum PeerUpdateSource {
    struct Offer: Sendable {
        let device: DeviceRecord
        let host: String
        let entries: [String: PeerUpdateEntry]
    }
    static let relativeRoot = "Library/Application Support/TATWO OS/Updater"
    static let runtimePaths = ["Resources/runtime", "Frameworks/Chromium Embedded Framework.framework", "Resources/claude-sidecar/node_modules"]
    static func safe(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression).map { String(value[$0]) == value } ?? false
    }
    static func validTag(_ tag: String) -> Bool { safe(tag, pattern: #"^v?[0-9]+[.][0-9]+([.][0-9]+){0,2}([-+][A-Za-z0-9.-]+)?$"#) }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func options(_ device: DeviceRecord) -> [String] {
        ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=2",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ForwardAgent=no",
         "-o", "ServerAliveInterval=1", "-o", "ServerAliveCountMax=2", "-p", String(device.sshPort)]
    }
    static func hosts(_ device: DeviceRecord) -> [String] {
        guard safe(device.user, pattern: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"), (1...65535).contains(device.sshPort) else { return [] }
        return [device.lanHost, device.host].compactMap { $0 }.reduce(into: []) { result, host in
            if safe(host, pattern: "^[A-Za-z0-9][A-Za-z0-9.-]*$"), !result.contains(host) { result.append(host) }
        }
    }
    static func ssh(_ device: DeviceRecord, host: String) -> [String] {
        ["/usr/bin/ssh"] + options(device) + ["\(device.user)@\(host)", "cat ~/\(quote(relativeRoot + "/available.json"))"]
    }
    static func rsync(_ offer: Offer, path: String, destination: URL, relative: Bool = false) -> [String] {
        ["/usr/bin/rsync", "-az", "--partial", "--inplace", "--timeout=5"] + (relative ? ["--relative"] : []) +
        ["-e", (["/usr/bin/ssh"] + options(offer.device)).joined(separator: " "),
         "\(offer.device.user)@\(offer.host):\(quote(path))", destination.path]
    }
    // Every command, including local repacking, goes through the existing owned capture-only fixture gate.
    static func run(_ argv: [String], seconds: Double) async throws -> Data {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        if let fixture = try RemoteSyncFixture.validate(environment: environment) {
            try JSONSerialization.data(withJSONObject: ["commands": [argv]], options: .sortedKeys)
                .write(to: fixture.root.appendingPathComponent("peer-command-\(UUID()).json"), options: .atomic)
            throw RemoteEngineSyncError.fixtureCaptureOnly("peer")
        }
        #else
        if environment["TATWO2_REMOTETEST"] == "1" || environment["TATWO2_REMOTE_SYNC_FIXTURE"] != nil || environment["TATWO2_REMOTE_SYNC_TOKEN"] != nil {
            throw RemoteEngineSyncError.fixtureBlocked("release")
        }
        #endif
        try Task.checkCancellation()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: argv[0]); process.arguments = Array(argv.dropFirst())
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        try process.run()
        defer {
            if process.isRunning {
                let pid = process.processIdentifier
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(process.processIdentifier, SIGKILL) }
                // Foundation reaps asynchronously; waitUntilExit here can deadlock a cancelled task.
            }
            pipe.fileHandleForReading.closeFile()
        }
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var output = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        repeat {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            guard output.count <= 1_048_576, ProcessInfo.processInfo.systemUptime < deadline else { throw URLError(.timedOut) }
            try Task.checkCancellation()
            if !process.isRunning && count <= 0 { break }
            if count <= 0 { try await Task.sleep(for: .milliseconds(25)) }
        } while true
        guard process.terminationStatus == 0 else { throw URLError(.cannotConnectToHost) }
        return output
    }
    static func discover(_ devices: [DeviceRecord]) async -> [Offer] {
        await withTaskGroup(of: Offer?.self) { group in
            for device in devices {
                group.addTask {
                    let candidates = hosts(device), deadline = ProcessInfo.processInfo.systemUptime + 5
                    for (index, host) in candidates.enumerated() {
                        let budget = (deadline - ProcessInfo.processInfo.systemUptime) / Double(candidates.count - index)
                        if let data = try? await run(ssh(device, host: host), seconds: budget),
                           let entries = try? JSONDecoder().decode([String: PeerUpdateEntry].self, from: data) {
                            return Offer(device: device, host: host, entries: entries.filter { validTag($0.key) })
                        }
                    }
                    return nil
                }
            }
            var offers: [Offer] = []
            for await offer in group { if let offer { offers.append(offer) } }
            return offers
        }
    }
    static func cachePath(_ path: String, tag: String, name: String) -> Bool {
        path.hasPrefix("/Users/") && path.hasSuffix("/\(relativeRoot)/download/\(tag)/\(name)") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) &&
        !path.contains("\n") && !path.contains("\r")
    }
    // Candidate bytes are never authoritative: the caller must hash before publishing or handing off.
    static func pull(_ offer: Offer, tag: String, name: String, folder: URL) async throws -> URL? {
        guard validTag(tag), let entry = offer.entries[tag] else { return nil }
        let runtime = safe(name, pattern: "^TATWO-OS-runtime-[0-9a-f]{12}[.]zip$")
        let delta = safe(name, pattern: #"^TATWO-OS-delta-v[0-9]+([.][0-9]+){1,3}-v[0-9]+([.][0-9]+){1,3}[.]zip$"#)
        guard runtime || delta || ["TATWO-OS.zip", "TATWO-OS-app.zip", "TATWO-OS.manifest.json"].contains(name) else { return nil }
        let key = SHA256.hash(data: Data("\(offer.device.id)/\(name)".utf8)).map { String(format: "%02x", $0) }.joined()
        let stage = folder.appendingPathComponent("peer-\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let output = stage.appendingPathComponent(name)
        if let path = entry.files[name] ?? (runtime ? entry.runtime : entry.app), cachePath(path, tag: tag, name: name) {
            _ = try await run(rsync(offer, path: path, destination: output), seconds: 86_400)
        } else if runtime, entry.installedApp == "/Applications/TATWO OS.app",
                  let sha = entry.runtimeSha, safe(sha, pattern: "^[0-9a-f]{64}$"),
                  name == "TATWO-OS-runtime-\(sha.prefix(12)).zip" {
            let contents = stage.appendingPathComponent("runtime", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            for path in runtimePaths {
                _ = try await run(rsync(offer, path: "/Applications/TATWO OS.app/Contents/./\(path)", destination: contents, relative: true), seconds: 86_400)
            }
            _ = try await run(["/usr/bin/ditto", "-c", "-k", "--norsrc", contents.path, output.path], seconds: 30)
        } else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return output
    }
    static func read(_ root: URL) -> [String: PeerUpdateEntry] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("available.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: PeerUpdateEntry].self, from: data)) ?? [:]
    }
    @MainActor static func publish(_ root: URL, tag: String, edit: (inout PeerUpdateEntry) -> Void) throws {
        guard validTag(tag) else { return }
        var entries = read(root), entry = entries[tag] ?? PeerUpdateEntry()
        edit(&entry); entries[tag] = entry
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: root.appendingPathComponent("available.json"), options: .atomic)
    }
    @MainActor static func publishInstalled(_ root: URL) async {
        let app = Bundle.main.bundleURL
        guard app.path == "/Applications/TATWO OS.app" else { return }
        // Retire pointers even after a rollback to an older App without a runtime manifest.
        var entries = read(root)
        for key in entries.keys { entries[key]?.installedApp = nil }
        try? JSONEncoder().encode(entries).write(to: root.appendingPathComponent("available.json"), options: .atomic)
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/runtime-layer.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = meta["sha"] as? String, safe(sha, pattern: "^[0-9a-f]{64}$"),
              (try? await run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path], seconds: 30)) != nil else { return }
        try? publish(root, tag: version.hasPrefix("v") ? version : "v" + version) { $0.installedApp = app.path; $0.runtimeSha = sha }
    }
    static func summary(_ entries: [String: PeerUpdateEntry]) -> String {
        guard let tag = entries.keys.filter({ validTag($0) && (entries[$0]?.app != nil || entries[$0]?.runtime != nil || entries[$0]?.installedApp != nil) })
            .sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first, let entry = entries[tag] else { return "可提供更新：無" }
        let app = entry.sizes.first(where: { ["TATWO-OS-app.zip", "TATWO-OS.zip"].contains($0.key) }).map { String(format: "app %.0f MB", Double($0.value) / 1_000_000) } ?? (entry.app != nil ? "app 快取" : nil)
        let runtime = entry.installedApp != nil ? "runtime 已裝" : (entry.runtime != nil ? "runtime 快取" : nil)
        return "可提供更新：\(tag)（\([app, runtime].compactMap { $0 }.joined(separator: "／"))）"
    }
}
