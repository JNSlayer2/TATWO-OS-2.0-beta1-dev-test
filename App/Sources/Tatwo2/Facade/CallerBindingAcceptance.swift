import Foundation
import AppKit

/// No engine send/start; all files live in an explicitly supplied fresh test root.
enum CallerBindingAcceptance {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["TATWO2_CALLERTEST"] == "1" else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do { try await run(); print("CALLERTEST PASS"); exit(0) }
            catch { print("CALLERTEST FAIL \(error)"); exit(1) }
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func check(_ name: String, _ condition: Bool) throws {
        print("CALLERTEST \(condition ? "PASS" : "FAIL") \(name)")
        if !condition { throw NSError(domain: name, code: 1) }
    }

    private static func run() async throws {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_CALLER_ROOT"],
              !FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "fresh TATWO2_CALLER_ROOT required", code: 1)
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["TATWO2_LIVE_ROOT"] = path
        env.removeValue(forKey: "TATWO2_SELFTEST")
        let manager = BackgroundJobManager(root: root)
        let store = ChatLiveStore(root: root)
        let bots = BotStore(root: root)
        let (model, a, b, room) = await MainActor.run { () -> (ChatPageModel, UUID, UUID, UUID) in
            let live = ChatLiveEngine(store: store, environment: env)
            let project = live.newProject(name: "caller-fixture", workdir: path)
            let a = live.newThread(in: project, title: "A")
            let b = live.newThread(in: project, title: "B")
            let room = live.newThread(in: project, title: "A room")
            live.configureRoom(threadID: room, parentThreadID: a, roomBrief: "no send", engine: "codex", cwdOverride: path)
            let model = ChatPageModel(environment: env, botCoreFixture: (live, bots))
            model.selectedThreadID = a
            OSAgentBridge.shared.configureCallerTest(model: model, manager: manager)
            return (model, a, b, room)
        }
        let bridge = OSAgentBridge.shared
        func call(_ method: String, _ params: [String: Any] = [:], caller: UUID? = nil) throws -> [String: Any] {
            var params = params
            if let caller { params["callerThreadID"] = caller.uuidString }
            return try bridge.callForSelfTest(method: method, params: params)
        }
        let first = try call("run_background", ["cmd": "printf caller-test", "cwd": path, "requestKey": "same"], caller: a)
        let job = first["jobID"] as! String
        await MainActor.run { model.selectedThreadID = b }
        let status = try call("background_status", ["jobID": job], caller: a)
        try check("A_status_after_select_B", status["jobID"] as? String == job && status["ownerSource"] as? String == "caller")
        do { _ = try call("stop_background", ["jobID": job], caller: b); throw NSError(domain: "wrong-owner-allowed", code: 1) }
        catch { try check("B_cannot_stop_A", String(describing: error) == "invalid_params") }
        do { _ = try call("background_status", ["jobID": job], caller: b); throw NSError(domain: "wrong-owner-allowed", code: 1) }
        catch { try check("B_cannot_read_A", String(describing: error) == "invalid_params") }
        let fallback = try call("whoami")
        try check("selected_fallback", fallback["threadID"] as? String == b.uuidString && fallback["ownerSource"] as? String == "selected")
        let identity = try call("whoami", caller: room)
        let permissions = identity["permissions"] as? [String: Any]
        let upstream = identity["upstream"] as? [String: Any]
        try check("whoami_fields", identity["parentThreadID"] as? String == a.uuidString && identity["cwd"] as? String == path && identity["engine"] as? String == "codex" && identity["botID"] is NSNull && permissions?["approval"] is NSNull && permissions?["mcp"] is NSNull && (upstream?["hash"] as? String)?.count == 64 && ["entry", "bundle"].contains(upstream?["source"] as? String ?? "") && upstream?["path"] is String)
        let repeated = try call("run_background", ["cmd": "printf should-not-run", "requestKey": "same"], caller: a)
        try check("requestKey_dedup", repeated["jobID"] as? String == job)
        let other = try call("run_background", ["cmd": "printf other-thread", "requestKey": "same"], caller: b)
        try check("requestKey_owner_scope", other["jobID"] as? String != job)
        do { _ = try call("whoami", ["callerThreadID": "bad"]); throw NSError(domain: "invalid-owner-allowed", code: 1) }
        catch { try check("invalid_caller_no_fallback", String(describing: error) == "invalid_params") }
        do { _ = try call("stop_room", ["roomID": room.uuidString], caller: b); throw NSError(domain: "wrong-room-allowed", code: 1) }
        catch { try check("room_owner_guard", String(describing: error) == "invalid_params") }

        let merged = try call("merge_reports", caller: a)
        let postedToA = await MainActor.run { model.live?.transcript(for: a).last?.text.contains("合併報告") == true && model.selectedThreadID == b }
        try check("merge_reports_owner_without_selecting_A", (merged["text"] as? String)?.contains("A room") == true && postedToA)
        let log = root.appendingPathComponent("large.log")
        var bytes = Data(repeating: 65, count: 1_048_576 - 65536)
        bytes.append(Data(repeating: 66, count: 65536))
        try bytes.write(to: log)
        let tail = BackgroundJobManager.readLogTail(log.path)
        try check("1MiB_log_reads_64KiB", tail.count == 65536 && tail.allSatisfy { $0 == 66 })
        print("CALLERTEST logBytes=1048576 returnedBytes=\(tail.count)")
        let large = root.appendingPathComponent("large-directory")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for index in 0..<2000 { FileManager.default.createFile(atPath: large.appendingPathComponent("f\(index)").path, contents: Data()) }
        await MainActor.run {
            model.live?.configureRoom(threadID: room, parentThreadID: a, roomBrief: "no send", engine: "codex", cwdOverride: large.path, deviceID: nil)
            if let live = model.live { model.document = live.document }
        }
        let listed = try await MainActor.run { () throws -> ([String: Any], Double) in
            let start = Date()
            let result = try call("list_rooms", caller: a)
            return (result, Date().timeIntervalSince(start) * 1000)
        }
        let rows = listed.0["rooms"] as? [[String: Any]] ?? []
        print(String(format: "CALLERTEST list_rooms main_ms=%.3f limit_ms=50 entries=2000", listed.1))
        try check("list_rooms_main_under_50ms", listed.1 < 50 && rows.count == 1 && rows[0]["sizeStale"] as? Bool == true)
        let bRooms = try call("list_rooms", caller: b)
        try check("list_rooms_owner", (bRooms["rooms"] as? [[String: Any]])?.isEmpty == true)
        let gate = DispatchSemaphore(value: 0)
        let cache = CallerDirectoryCache { _ in gate.wait(); return .init(exists: true, megabytes: 123) }
        let elapsed = await MainActor.run { () -> Double in
            let start = Date(); _ = cache.snapshot("mock"); _ = cache.snapshot("mock")
            return Date().timeIntervalSince(start) * 1000
        }
        gate.signal()
        try check("slow_size_worker_never_blocks_main", elapsed < 50)
        for _ in 0..<100 {
            if cache.snapshot("mock").megabytes == 123 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check("directory_cache_returns_previous", cache.snapshot("mock").megabytes == 123)
        // Seed only exited records; no real PID is adopted or signalled by this test.
        let replayRoot = root.appendingPathComponent("replay")
        try FileManager.default.createDirectory(at: replayRoot, withIntermediateDirectories: true)
        var fresh = BackgroundJobManager.Record(jobID: UUID(), pid: 0, title: "fresh", command: "unused", cwd: path,
                                                logPath: log.path, threadID: a, startedAt: Date().addingTimeInterval(-60), state: "exited", exitCode: 0)
        fresh.requestKey = "persisted"
        var expired = fresh
        expired.jobID = UUID(); expired.requestKey = "expired"; expired.startedAt = Date().addingTimeInterval(-601)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([fresh, expired]).write(to: replayRoot.appendingPathComponent("bg-jobs.json"))
        let replay = BackgroundJobManager(root: replayRoot)
        let resumed = try replay.run(command: "printf must-not-run", cwd: path, title: "repeat", threadID: a, requestKey: "persisted")
        try check("requestKey_persisted_replay", resumed.jobID == fresh.jobID)
        let renewed = try replay.run(command: "printf renewed", cwd: path, title: "renew", threadID: a, requestKey: "expired")
        try check("requestKey_expires_after_10_minutes", renewed.jobID != expired.jobID)
        replay.stopAll()
        manager.stopAll()
        _ = model // retain through all bridge calls
    }
}
