import Foundation
import CryptoKit

enum RemoteEngineSyncError: Error, CustomStringConvertible {
    case enginesMissing(String)
    case commandFailed(String)
    case fixtureBlocked(String)
    case fixtureCaptureOnly(String)

    var description: String {
        switch self {
        case .enginesMissing(let path): return "找不到本機 Engines：\(path)"
        case .commandFailed(let detail): return "遠端 Engines 同步失敗：\(detail)"
        case .fixtureBlocked(let why): return "遠端同步測試 fixture 無效，BLOCKED（不 ssh／不 rsync、不退回真家）：\(why)"
        case .fixtureCaptureOnly(let path): return "遠端同步 fixture 模式：只擷取命令不執行，已寫 \(path)"
        }
    }
}

/// 已驗證的遠端目的地（不用 raw 字串）：只有兩種來源——真派工的固定 `~/.tatwo2/engines`，或測試 fixture 的 owned 唯一目錄。
struct ValidatedRemoteDestination {
    enum Origin { case production, fixture }
    let origin: Origin
    let remoteDirectory: String      // 遠端 shell 用的目錄字串（production：~/.tatwo2/engines；fixture：絕對路徑）
    let sidecarBase: String          // 回傳給派工用的 sidecar 根（production：~/.tatwo2/engines）
    static let production = ValidatedRemoteDestination(origin: .production, remoteDirectory: "~/.tatwo2/engines", sidecarBase: "~/.tatwo2/engines")
}

#if DEBUG
/// 測試專用 owned fixture（Codex 2026-09-06 提案 v2）：只在 DEBUG 且明確注入才存在；缺／無效一律 BLOCKED，不退回真家。
struct RemoteSyncFixture {
    let root: URL
    let token: String
    let destination: ValidatedRemoteDestination
    var plannedCommandsURL: URL { root.appendingPathComponent("planned-commands.json") }

    /// 有沒有「要求測試模式」：三個訊號任一存在就算要求（部分缺＝要求但無效＝BLOCKED）；三個都沒有才是正常生產路徑。
    static func isRequested(environment: [String: String]) -> Bool {
        environment["TATWO2_REMOTETEST"] == "1" || environment["TATWO2_REMOTE_SYNC_FIXTURE"] != nil || environment["TATWO2_REMOTE_SYNC_TOKEN"] != nil
    }
    /// token 必須是「完整」小寫 UUID：用 UUID 解析後回寫字串逐字相等（regex `$` 會放過結尾 newline）。
    private static func isStrictLowercaseUUID(_ token: String) -> Bool {
        guard let uuid = UUID(uuidString: token) else { return false }
        return uuid.uuidString.lowercased() == token
    }
    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
    /// 沒有任何要求訊號 → nil（正常路徑）；有要求但缺／無效 → throw fixtureBlocked（絕不退回真家）。
    static func validate(environment: [String: String]) throws -> RemoteSyncFixture? {
        guard isRequested(environment: environment) else { return nil }
        let fm = FileManager.default
        guard let raw = environment["TATWO2_REMOTE_SYNC_FIXTURE"], !raw.isEmpty else { throw RemoteEngineSyncError.fixtureBlocked("要求測試模式但缺 TATWO2_REMOTE_SYNC_FIXTURE") }
        guard let token = environment["TATWO2_REMOTE_SYNC_TOKEN"], !token.isEmpty else { throw RemoteEngineSyncError.fixtureBlocked("缺 TATWO2_REMOTE_SYNC_TOKEN") }
        guard isStrictLowercaseUUID(token) else { throw RemoteEngineSyncError.fixtureBlocked("token 必須是完整小寫 UUID（逐字相等）") }
        guard raw.hasPrefix("/"), !raw.contains("/../"), !raw.hasSuffix("/.."), !raw.contains("//") else { throw RemoteEngineSyncError.fixtureBlocked("fixture 根路徑非正規（相對、..、//）") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: raw, isDirectory: &isDir), isDir.boolValue else { throw RemoteEngineSyncError.fixtureBlocked("fixture 根不存在") }
        // 祖先鏈任何一層是 symlink 都拒絕：給的路徑必須與 realpath 逐字相同
        let real = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let given = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        guard real == given else { throw RemoteEngineSyncError.fixtureBlocked("fixture 根或其祖先含 symlink（given≠realpath）") }
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        let tmpRoots = [tmpRoot, "/private/tmp"].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        // 必須是 $TMPDIR／/private/tmp 之下的「專屬子目錄」，TMPDIR 本身不算 owned
        guard tmpRoots.contains(where: { real.hasPrefix($0 + "/") && real.count > $0.count + 1 }) else { throw RemoteEngineSyncError.fixtureBlocked("fixture 根必須是 $TMPDIR／/private/tmp 之下的專屬子目錄") }
        let ownerPath = real + "/owner.json"
        guard !isSymlink(ownerPath), let data = try? Data(contentsOf: URL(fileURLWithPath: ownerPath)),
              let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ownerToken = owner["token"] as? String, ownerToken == token else {
            throw RemoteEngineSyncError.fixtureBlocked("owner.json 缺、是 symlink 或 token 不符")
        }
        // 衍生目的地：固定兩個安全 component（token 已限 UUID），再驗 containment；已存在的前綴不得是 symlink
        let destRoot = real + "/remote-dest-" + token
        let dest = destRoot + "/engines"
        guard dest.hasPrefix(real + "/"), !isSymlink(destRoot), !isSymlink(dest) else { throw RemoteEngineSyncError.fixtureBlocked("衍生目的地越界或含 symlink") }
        if fm.fileExists(atPath: destRoot) {
            let destReal = URL(fileURLWithPath: destRoot).standardizedFileURL.resolvingSymlinksInPath().path
            guard destReal == destRoot else { throw RemoteEngineSyncError.fixtureBlocked("衍生目的地 realpath 不符") }
        }
        let destination = ValidatedRemoteDestination(origin: .fixture, remoteDirectory: dest, sidecarBase: dest)
        return RemoteSyncFixture(root: URL(fileURLWithPath: real, isDirectory: true), token: token, destination: destination)
    }
}
#endif

struct RemoteEngineSync {
    private static let lock = NSLock()
    private static let stampURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("tatwo2-remote-engine-last-sync.json")

    /// 同一設備＋目的地的 Engines 內容雜湊相同才跳過 rsync；回傳 session 內 handle（production：固定 ~/.tatwo2/engines；fixture：capture-only）。
    @discardableResult
    static func ensureEnginesOnDevice(_ ref: RemoteDeviceRef, kind: ClaudeSidecar.Kind) throws -> RemoteEngineHandle {
        lock.lock()
        defer { lock.unlock() }

        // 測試模式偵測＋驗證必須在內容快取 fast-return 之前：fixture 永遠不能回傳生產 sidecar 路徑，也不能被快取繞過。
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        if let fixture = try RemoteSyncFixture.validate(environment: environment) {
            let localEngines = enginesDirectory()
            guard FileManager.default.fileExists(atPath: localEngines.path) else {
                throw RemoteEngineSyncError.enginesMissing(localEngines.path)
            }
            // owned fixture：只擷取命令、不執行任何 ssh／rsync；缺／無效已在 validate throw（絕不退回真家）
            let handle = try RemoteEngineHandle.fixture(device: ref, kind: kind, fixture: fixture)   // kind／containment 不合→BLOCKED（在任何 Process 之前）
            let planned = plannedCommands(ref: ref, localEngines: localEngines, destination: fixture.destination)
            let payload: [String: Any] = ["commands": planned, "destination": fixture.destination.remoteDirectory, "origin": "fixture", "sidecarBase": fixture.destination.sidecarBase]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fixture.plannedCommandsURL, options: .atomic)
            try handle.capture(stage: "sync", commands: planned)
            return handle   // capture-only handle：後面每段只記錄，不執行
        }
        #else
        // release 沒有 fixture 型別：只要有任何測試模式訊號就 BLOCKED，沒有 fallback 到真 SSH
        if environment["TATWO2_REMOTETEST"] == "1" || environment["TATWO2_REMOTE_SYNC_FIXTURE"] != nil || environment["TATWO2_REMOTE_SYNC_TOKEN"] != nil {
            throw RemoteEngineSyncError.fixtureBlocked("release 編譯沒有測試 fixture；測試模式訊號存在即 BLOCKED")
        }
        #endif

        let production = RemoteEngineHandle.production(device: ref, kind: kind)
        var stamps = loadStamps()
        let localEngines = enginesDirectory()
        let key = "\(ref.id)|\(ref.sshTarget)|\(ref.sshPort)|engines-v2"
        stamps[key] = try deployIfNeeded(source: localEngines, previousHash: stamps[key]) {
            for command in plannedCommands(ref: ref, localEngines: localEngines, destination: .production) {
                try run(executable: command[0], arguments: Array(command.dropFirst()))
            }
        }

        saveStamps(stamps)
        return production
    }

    /// Shared by production and synthetic fixtures. Failed/in-flight changed sources
    /// never earn a success stamp. No timestamp can bypass the content check.
    static func deployIfNeeded(source: URL, previousHash: String?, deploy: () throws -> Void) throws -> String {
        let hash = try contentHash(source)
        guard hash != previousHash else { return hash }
        try deploy()
        guard try contentHash(source) == hash else {
            throw RemoteEngineSyncError.commandFailed("Engines changed during deployment; retry required")
        }
        return hash
    }

    /// Hash only Engines: sorted relative paths, kinds, modes and streaming SHA256.
    /// Symlinks hash their link text (rsync -a preserves links, not referent contents).
    static func contentHash(_ source: URL) throws -> String {
        let fm = FileManager.default
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RemoteEngineSyncError.enginesMissing("Engines")
        }
        var walkError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in walkError = error; return false }) else {
            throw RemoteEngineSyncError.enginesMissing("Engines")
        }
        let urls = walker.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        if let walkError { throw walkError }
        var tree = SHA256()
        for url in urls {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            var fileHash = SHA256()
            let kind: String
            switch type {
            case .typeRegular:
                kind = "file"
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { fileHash.update(data: chunk) }
            case .typeSymbolicLink:
                kind = "link"
                fileHash.update(data: Data(try fm.destinationOfSymbolicLink(atPath: url.path).utf8))
            case .typeDirectory: kind = "directory"
            default: throw RemoteEngineSyncError.commandFailed("unsupported Engines entry")
            }
            let hash = fileHash.finalize().map { String(format: "%02x", $0) }.joined()
            tree.update(data: Data("\(relative.utf8.count):\(relative)\0\(kind)\0\(mode)\0\(hash)\n".utf8))
        }
        return tree.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 純函式：只算 argv，不執行。目的地必須是 ValidatedRemoteDestination（不接受 raw 字串）。
    static func plannedCommands(ref: RemoteDeviceRef, localEngines: URL, destination: ValidatedRemoteDestination) -> [[String]] {
        let expandHome = destination.origin == .production
        let mkdir = ["/usr/bin/ssh"] + sshPrefix(ref) + ["/bin/mkdir", "-p", remoteShellQuote(destination.remoteDirectory, expandHome: expandHome)]
        var rsyncArguments = ["/usr/bin/rsync", "-az", "--checksum", "--delete"]
        if ref.sshPort != 22 {
            rsyncArguments += ["-e", "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -p \(ref.sshPort)"]
        }
        let remoteDir = destination.remoteDirectory.hasSuffix("/") ? destination.remoteDirectory : destination.remoteDirectory + "/"
        rsyncArguments += [
            localEngines.path.hasSuffix("/") ? localEngines.path : localEngines.path + "/",
            "\(ref.sshTarget):\(expandHome ? remoteDir : remoteShellQuote(remoteDir))",   // rsync 遠端路徑經對方 shell：fixture 絕對路徑要 quote
        ]
        return [mkdir, rsyncArguments]
    }

    private static func enginesDirectory() -> URL {
        // 2026-09-06：這裡要的是 Engines「腳本來源」（sidecar／MCP 原始碼），不是引擎家；之前借用 TATWO2_ENGINES_ROOT
        // 讓 REMOTETEST 把引擎家也指到 repo/Engines，claude 私態就寫進 repo（r8 停鏈真因）。改用專屬變數。
        if let override = ProcessInfo.processInfo.environment["TATWO2_ENGINES_SOURCE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var sourceRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { sourceRoot.deleteLastPathComponent() }
        let sourceEngines = sourceRoot.appendingPathComponent("Engines", isDirectory: true)
        if FileManager.default.fileExists(atPath: sourceEngines.path) { return sourceEngines }
        return URL(fileURLWithPath: ClaudeSidecar.scriptPath(for: .claude))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sshPrefix(_ ref: RemoteDeviceRef) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            "-p", String(ref.sshPort),
            ref.sshTarget,
        ]
    }

    #if DEBUG
    /// 測試用：capture 分支必須是 0 次程序執行（主要證據），mtime 只是弱觀察。
    static var debugRunCount = 0
    /// 測試要求時的 stamps 走純記憶體，不碰共享的 NSTemporaryDirectory()/tatwo2-remote-engine-last-sync.json
    /// （2026-09-06 13:13 事故：debugRecordStamp 曾寫進真共享 cache，該紀錄保留不清）。
    static var debugMemoryStamps: [String: String] = [:]
    private static var debugStampsIsolated: Bool { RemoteSyncFixture.isRequested(environment: ProcessInfo.processInfo.environment) }
    static func debugRecordStamp(_ deviceID: String) {
        precondition(debugStampsIsolated, "debugRecordStamp 只能在測試要求模式下用（純記憶體）")
        debugMemoryStamps[deviceID] = "legacy-time-only-stamp"
    }
    #endif
    private static func run(executable: String, arguments: [String]) throws {
        #if DEBUG
        debugRunCount += 1
        #endif
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw RemoteEngineSyncError.commandFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw RemoteEngineSyncError.commandFailed(
                "\(executable) exit=\(process.terminationStatus)\(text.isEmpty ? "" : " — \(text)")")
        }
    }

    private static func loadStamps() -> [String: String] {
        #if DEBUG
        if debugStampsIsolated { return debugMemoryStamps }
        #endif
        guard let data = try? Data(contentsOf: stampURL) else { return [:] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }

    private static func saveStamps(_ stamps: [String: String]) {
        #if DEBUG
        if debugStampsIsolated { debugMemoryStamps = stamps; return }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stamps) else { return }
        try? data.write(to: stampURL, options: .atomic)
    }
}
