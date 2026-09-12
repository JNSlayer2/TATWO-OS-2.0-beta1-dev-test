import Foundation

/// 遠端引擎「同一份 session 內 handle」（Codex 2026-09-06 14:13 批准第一階段 capture-only 接線；14:18 四點收窄）：
/// 從 RemoteEngineSync 一路傳到 DispatchEngine → ChatLiveEngine.ensureSidecar → ClaudeSidecar.start，不丟棄重算、不寫進 document。
/// production：destination 固定 ~/.tatwo2/engines、remoteEnvironment 空、argv 與原本逐字相同（基線 shots/remote-baseline-e6fdae13）。
/// fixture（DEBUG）：所有路徑由唯一 validated root 推導固定 component（既有 component 不得是 symlink）；每段只擷取命令，不起任何 ssh／rsync／sidecar。
struct RemoteEngineHandle {
    let device: RemoteDeviceRef
    let kind: ClaudeSidecar.Kind
    let destination: ValidatedRemoteDestination
    let remoteEnvironment: [String: String]
    let remoteProjectRoot: String?   // fixture：owned 專案根；worktree 由同一 planner 從它推導（單一真值，沒有另一個 worktreeRoot）
    let captureRoot: String?
    let fixtureToken: String?

    var isCaptureOnly: Bool { destination.origin == .fixture }
    var sidecarScript: String { destination.sidecarBase + "/\(kind.rawValue)-sidecar/sidecar.mjs" }
    /// 一致＝整個 launch endpoint tuple（id／host／user／port／pin）＋kind；同 id 但 registered host／port 變了也算不一致（production 重 resolve，fixture fail-closed）。
    func matches(device other: RemoteDeviceRef, kind otherKind: ClaudeSidecar.Kind) -> Bool {
        device.id == other.id && device.host == other.host && device.user == other.user && device.sshPort == other.sshPort
            && device.publicKeyFingerprint == other.publicKeyFingerprint && kind == otherKind
    }

    static func production(device: RemoteDeviceRef, kind: ClaudeSidecar.Kind) -> RemoteEngineHandle {
        RemoteEngineHandle(device: device, kind: kind, destination: .production, remoteEnvironment: [:], remoteProjectRoot: nil, captureRoot: nil, fixtureToken: nil)
    }

    /// 解析「這次要用哪個 handle」：session 有且與 device／engine 一致→用它；session 不一致→fixture 一律 fail-closed，production 依 registered device 重新 resolve 固定 handle；
    /// 沒 session→測試訊號存在則 fail-closed，否則 production（正常恢復語意不變）。
    static func resolve(session: RemoteEngineHandle?, device: RemoteDeviceRef, engine: ClaudeSidecar.Kind, testRequested: Bool) throws -> RemoteEngineHandle {
        if let session {
            if session.matches(device: device, kind: engine) { return session }
            if session.isCaptureOnly { throw RemoteEngineSyncError.fixtureBlocked("session handle 與本次 device／engine 不一致（\(session.device.id)/\(session.kind.rawValue) vs \(device.id)/\(engine.rawValue)）：fixture 不重新 resolve") }
        }
        if testRequested { throw RemoteEngineSyncError.fixtureBlocked("測試訊號存在但沒有本次 session 的 capture-only handle（不 resolve 生產路徑）") }
        return production(device: device, kind: engine)
    }

    #if DEBUG
    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
    /// 既有的 component：不得是 symlink，且 realpath 必須等於自己（祖先也不能是 symlink）；不存在的 component 只驗字串 containment。
    private static func assertOwnedComponent(_ path: String, root: String) throws {
        guard path.hasPrefix(root + "/"), !path.contains("/../"), !path.hasSuffix("/..") else { throw RemoteEngineSyncError.fixtureBlocked("衍生路徑越界：\(path)") }
        guard FileManager.default.fileExists(atPath: path) || isSymlink(path) else { return }
        guard !isSymlink(path) else { throw RemoteEngineSyncError.fixtureBlocked("既有 component 是 symlink：\(path)") }
        let real = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard real == path else { throw RemoteEngineSyncError.fixtureBlocked("component realpath 不符：\(path) → \(real)") }
    }

    /// 同一套 component 驗證（factory 與 start 入口共用）：由 root 推導固定 component，驗 containment；既有者不得是 symlink、realpath 必須等於自己。
    static func validatedComponents(root: String, destination: ValidatedRemoteDestination) throws -> (environment: [String: String], remoteProjectRoot: String) {
        let derived: [String: String] = [
            "HOME": root + "/home", "CODEX_HOME": root + "/codex-home", "TATWO2_CODEX_SOURCE_HOME": root + "/source-home",
            "TMPDIR": root + "/tmp", "XDG_CACHE_HOME": root + "/cache",
        ]
        let remoteProjectRoot = root + "/remote-project"
        let captureFile = root + "/capture-chain.jsonl"
        for path in Array(derived.values) + [remoteProjectRoot, captureFile] { try assertOwnedComponent(path, root: root) }
        guard destination.sidecarBase.hasPrefix(root + "/") else { throw RemoteEngineSyncError.fixtureBlocked("fixture destination 不在 root 內") }
        return (derived, remoteProjectRoot)
    }

    /// 第一階段只允許 codex；所有路徑由 fixture.root 推導並驗 containment 與 symlink（validatedComponents）。
    static func fixture(device: RemoteDeviceRef, kind: ClaudeSidecar.Kind, fixture: RemoteSyncFixture) throws -> RemoteEngineHandle {
        guard kind == .codex else { throw RemoteEngineSyncError.fixtureBlocked("fixture 第一階段只允許 codex kind（收到 \(kind.rawValue)）") }
        let root = fixture.root.standardizedFileURL.path
        let components = try validatedComponents(root: root, destination: fixture.destination)
        return RemoteEngineHandle(device: device, kind: kind, destination: fixture.destination, remoteEnvironment: components.environment,
                                  remoteProjectRoot: components.remoteProjectRoot, captureRoot: root, fixtureToken: fixture.token)
    }

    /// ClaudeSidecar.start 入口用：測試訊號存在時，handle 必須是 capture-only、kind 一致、且環境裡的 fixture 現在重新驗證仍有效並與 handle 同 root／token；否則 fail-closed。
    func validateForStart(kind startKind: ClaudeSidecar.Kind, environment: [String: String]) throws {
        guard RemoteSyncFixture.isRequested(environment: environment) else {
            if isCaptureOnly { throw RemoteEngineSyncError.fixtureBlocked("沒有測試訊號卻拿到 capture-only handle") }
            return
        }
        guard isCaptureOnly, kind == startKind else { throw RemoteEngineSyncError.fixtureBlocked("測試訊號存在但 handle 不是 capture-only／kind 不符（\(kind.rawValue) vs \(startKind.rawValue)）") }
        guard let current = try RemoteSyncFixture.validate(environment: environment),
              current.root.standardizedFileURL.path == captureRoot, current.token == fixtureToken,
              current.destination.remoteDirectory == destination.remoteDirectory else {
            throw RemoteEngineSyncError.fixtureBlocked("fixture 已失效或與 session handle 不一致（root／token／destination）")
        }
        // 重用同一套 component 驗證：handle 建立後若 home／codex-home／tmp／cache／remote-project／capture 記錄檔變成 symlink 或 realpath 不符，入口即 fail-closed
        let components = try Self.validatedComponents(root: current.root.standardizedFileURL.path, destination: current.destination)
        guard components.environment == remoteEnvironment, components.remoteProjectRoot == remoteProjectRoot else {
            throw RemoteEngineSyncError.fixtureBlocked("fixture component 與 session handle 不一致")
        }
    }

    /// 每段擷取一行 JSON 到 fixture root 的 capture-chain.jsonl（只在 capture-only handle 上）；記錄檔或 root 是 symlink 就 throw，不吞錯。
    func capture(stage: String, commands: [[String]], extra: [String: Any] = [:]) throws {
        guard isCaptureOnly else { return }
        guard let captureRoot else { throw RemoteEngineSyncError.fixtureBlocked("capture-only handle 沒有 captureRoot") }
        let path = captureRoot + "/capture-chain.jsonl"
        guard !Self.isSymlink(captureRoot), !Self.isSymlink(path) else { throw RemoteEngineSyncError.fixtureBlocked("capture 記錄檔或 root 是 symlink：\(path)") }
        var row: [String: Any] = ["stage": stage, "commands": commands, "at": ISO8601DateFormatter().string(from: Date())]
        for (k, v) in extra { row[k] = v }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])   // 存在性與 symlink 已在上面驗過
        }
    }
    #endif
}

/// session 內的 handle 登記（threadID → handle）：不持久化；App 重開後 production 依 registered device 重新 resolve 固定 handle。
/// session-only 登記；沒有全域 singleton——每個 ChatLiveEngine 實例各持一份，
/// 隨 engine 一起釋放；shutdownAll／stop 只清自己那份（別的 engine 互不可見）。
@MainActor final class RemoteSessionHandles {
    private var handles: [UUID: RemoteEngineHandle] = [:]
    init() {}
    func set(_ threadID: UUID, _ handle: RemoteEngineHandle) { handles[threadID] = handle }
    func get(_ threadID: UUID) -> RemoteEngineHandle? { handles[threadID] }
    func remove(_ threadID: UUID) { handles[threadID] = nil }
    func removeAll() { handles.removeAll() }
    var count: Int { handles.count }
}

enum RemoteCaptureOnlyError: Error, CustomStringConvertible {
    case sidecarNotStarted(String)
    var description: String {
        switch self { case .sidecarNotStarted(let path): return "capture-only：遠端 sidecar 未啟動（argv 已擷取到 \(path)）" }
    }
}
