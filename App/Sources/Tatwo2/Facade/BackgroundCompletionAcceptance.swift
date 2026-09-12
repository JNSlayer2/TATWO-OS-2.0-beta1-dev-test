import Foundation
import Darwin

/// Isolated real shell jobs only. No model, network, production registry or log.
enum BackgroundCompletionAcceptance {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [BackgroundJobManager.Record] = []
        private var mainThreadOnly = true
        private var queried = false
        func record(_ row: BackgroundJobManager.Record, onMain: Bool, queried: Bool) {
            lock.lock(); defer { lock.unlock() }
            rows.append(row); mainThreadOnly = mainThreadOnly && onMain
            self.queried = self.queried || queried
        }
        var snapshot: ([BackgroundJobManager.Record], Bool, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (rows, mainThreadOnly, queried)
        }
    }

    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path).appendingPathComponent("jobs")
        let thread = UUID()
        let manager = BackgroundJobManager(root: root)
        let events = Events()
        manager.onCompletion = { [weak manager] row in
            let main = Thread.isMainThread
            // The pre-fix callback runs on the serial job queue: do not
            // deliberately crash libdispatch by synchronously reentering it.
            let queried = main && manager?.status(jobID: row.jobID)?.state == "exited"
            events.record(row, onMain: main, queried: queried)
        }
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1 }
            print("BGCOMPLETIONTEST \(value ? "PASS" : "FAIL") \(name)")
        }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<400 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "BackgroundCompletionAcceptance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: name])
        }
        check("idle manager has no polling timer", !manager.pollsDetachedJobs)
        let success = try manager.run(command: "printf 'fixture ok\\n'", cwd: path,
                                      title: "success", threadID: thread)
        try await until("successful process exit") { manager.status(jobID: success.jobID)?.state == "exited" }
        try await until("successful process notification") { events.snapshot.0.count >= 1 }
        check("success preserves native exit code", manager.status(jobID: success.jobID)?.exitCode == 0)
        check("success classification uses native result", manager.status(jobID: success.jobID)?.completionStatus == "success|背景工作完成")
        check("completion callback is delivered away from the job queue", events.snapshot.1)
        check("completion callback can reenter status without deadlock", events.snapshot.2)
        let failure = try manager.run(command: "exit 7", cwd: path, title: "failure", threadID: thread)
        try await until("failed process exit") { manager.status(jobID: failure.jobID)?.state == "exited" }
        try await until("failed process notification") { events.snapshot.0.count >= 2 }
        check("failure preserves native exit code", manager.status(jobID: failure.jobID)?.exitCode == 7)
        check("failure classification uses native result", manager.status(jobID: failure.jobID)?.completionStatus == "error|背景工作失敗")
        for _ in 0..<10 { _ = manager.status(jobID: failure.jobID) }
        try await Task.sleep(for: .milliseconds(50))
        check("repeated reads do not duplicate completion notifications", events.snapshot.0.count == 2)

        let stopped = try manager.run(command: "sleep 2", cwd: path, title: "cancel", threadID: thread)
        let ownsGroup = stopped.pid > 1 && getpgid(stopped.pid) == stopped.pid
        check("fixture job owns its process group before signalling", ownsGroup)
        check("owned running job does not need polling", !manager.pollsDetachedJobs)
        if ownsGroup {
            let start = Date()
            let requested = manager.stop(jobID: stopped.jobID)
            check("stop returns promptly without waiting on job queue", Date().timeIntervalSince(start) < 0.5)
            check("stop request does not invent a terminal result", requested?.stopRequested == true && requested?.state == "running")
            _ = manager.stop(jobID: stopped.jobID)
        }
        // If group ownership is wrong, let our bounded fixture end naturally.
        // Never guess a group or signal a production process to pass a test.
        try await until("stop fixture ended") { manager.status(jobID: stopped.jobID)?.state == "exited" }
        try await until("stop notification") { events.snapshot.0.count >= 3 }
        check("one terminal notification per real job", Set(events.snapshot.0.map(\.jobID)).count == 3 && events.snapshot.0.count == 3)
        check("notification retains its owning thread", events.snapshot.0.allSatisfy { $0.threadID == thread })
        check("cancellation classification requires native signal", manager.status(jobID: stopped.jobID)?.completionStatus == "info|背景工作已取消")
        check("terminal jobs leave no polling timer", !manager.pollsDetachedJobs)

        let reopened = BackgroundJobManager(root: root)
        let replay = Events()
        reopened.onCompletion = { row in replay.record(row, onMain: Thread.isMainThread, queried: false) }
        try await Task.sleep(for: .milliseconds(150))
        check("completion registration replays persisted terminal jobs", Set(replay.snapshot.0.map(\.jobID)).count == 3)

        // A TERM-resistant, bounded fixture proves delayed escalation without
        // freezing the UI and without adopting any production process.
        let resistant = BackgroundJobManager(root: URL(fileURLWithPath: path).appendingPathComponent("resistant"))
        let resistantEvents = Events()
        resistant.onCompletion = { row in
            resistantEvents.record(row, onMain: Thread.isMainThread, queried: false)
        }
        let resistantJob = try resistant.run(command: "trap '' TERM; printf ready > ready-to-stop; sleep 3",
            cwd: path, title: "resistant", threadID: thread)
        try await until("resistant fixture is ready") {
            FileManager.default.fileExists(atPath: path + "/ready-to-stop")
        }
        let ownsResistant = resistantJob.pid > 1 && getpgid(resistantJob.pid) == resistantJob.pid
        check("resistant fixture group is verified before signalling", ownsResistant)
        if ownsResistant {
            _ = resistant.stop(jobID: resistantJob.jobID)
            _ = resistant.stop(jobID: resistantJob.jobID)
        }
        try await until("resistant fixture terminates") { resistant.status(jobID: resistantJob.jobID)?.state == "exited" }
        try await until("resistant notification delivered") { resistantEvents.snapshot.0.count == 1 }
        check("TERM-resistant owned process escalates once to native SIGKILL", resistant.status(jobID: resistantJob.jobID)?.terminationSignal == SIGKILL)
        check("repeated stop does not duplicate cancellation notification", resistantEvents.snapshot.0.count == 1)

        let detachedRoot = URL(fileURLWithPath: path).appendingPathComponent("detached")
        try FileManager.default.createDirectory(at: detachedRoot, withIntermediateDirectories: true)
        let detachedJob = try resistant.run(command: "sleep 0.3", cwd: path, title: "detached", threadID: thread)
        let detachedEncoder = JSONEncoder(); detachedEncoder.dateEncodingStrategy = .iso8601
        try detachedEncoder.encode([detachedJob]).write(to: detachedRoot.appendingPathComponent("bg-jobs.json"))
        let detached = BackgroundJobManager(root: detachedRoot)
        let detachedEvents = Events()
        detached.onCompletion = { row in
            detachedEvents.record(row, onMain: Thread.isMainThread, queried: false)
        }
        check("only detached running jobs start polling", detached.pollsDetachedJobs)
        try await until("detached fixture notification") { detachedEvents.snapshot.0.count == 1 }
        check("detached disappearance reports unknown without guessed exit code",
              detachedEvents.snapshot.0.first?.state == "unknown" && detachedEvents.snapshot.0.first?.exitCode == nil)
        check("last detached completion stops polling", !detached.pollsDetachedJobs)

        // A corrupt/legacy pid=0 record must never target our process group.
        let invalidRoot = URL(fileURLWithPath: path).appendingPathComponent("invalid-jobs")
        try FileManager.default.createDirectory(at: invalidRoot, withIntermediateDirectories: true)
        let invalid = BackgroundJobManager.Record(jobID: UUID(), pid: 0, title: "invalid",
            command: "not executed", cwd: path, logPath: "", threadID: thread,
            startedAt: Date(), state: "running", exitCode: nil)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([invalid]).write(to: invalidRoot.appendingPathComponent("bg-jobs.json"))
        let invalidManager = BackgroundJobManager(root: invalidRoot)
        check("invalid pid is unknown, never a running process group", invalidManager.status(jobID: invalid.jobID)?.state == "unknown")
        check("invalid pid cannot invent an exit code", invalidManager.status(jobID: invalid.jobID)?.exitCode == nil)
        check("invalid pid does not leave polling timer", !invalidManager.pollsDetachedJobs)
        // Do not call stop on pid=0 even in the pre-fix fixture.

        let liveRoot = URL(fileURLWithPath: path).appendingPathComponent("live")
        let engine = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: env)
        let project = engine.newProject(name: "background-fixture", workdir: path)
        let owner = engine.newThread(in: project)
        let unrelated = engine.newThread(in: project)
        let bots = BotStore(root: liveRoot)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, bots))
        var completed = manager.status(jobID: success.jobID)!
        completed.threadID = owner
        model.selectedThreadID = unrelated
        model.selectedRemote = (deviceID: "fixture-unconnected-remote", threadID: UUID())
        model.receiveLocalBackgroundCompletion(completed)
        model.receiveLocalBackgroundCompletion(completed)
        let notificationID = "background:\(completed.jobID.uuidString)"
        let rows = engine.transcript(for: owner)
        check("remote selection still routes notification to original local owner", rows.count == 1 && rows.first?.id == notificationID)
        check("background completion does not write selected unrelated thread", engine.transcript(for: unrelated).isEmpty)
        check("completion does not attach to another foreground turn", rows.first?.turnID == nil)
        check("background notification does not revive model work", !engine.isRunning(owner))
        let restored = ChatLiveEngine(store: ChatLiveStore(root: liveRoot), environment: env)
        restored.appendBackgroundCompletion(completed)
        check("notification persists and remains unique after reopening", restored.transcript(for: owner).filter { $0.id == notificationID }.count == 1)
        var legacy = completed
        legacy.jobID = UUID()
        let legacyText = "背景工作「\(legacy.title)」結束，exit=\(legacy.exitCode.map(String.init) ?? "unknown")，log：\(legacy.logPath)"
        restored.appendSystemMessage(threadID: owner, text: legacyText, status: "info|背景工作")
        let count = restored.transcript(for: owner).count
        restored.appendBackgroundCompletion(legacy)
        check("legacy notification is not duplicated during migration", restored.transcript(for: owner).count == count)
        var unknown = invalid
        unknown.threadID = owner; unknown.state = "unknown"
        restored.appendBackgroundCompletion(unknown)
        check("unknown result is not described as completed", restored.transcript(for: owner).last?.text.contains("無法確認") == true)
        var missing = completed
        missing.threadID = UUID()
        restored.appendBackgroundCompletion(missing)
        check("deleted owner is not recreated by notification replay", restored.threadRecord(missing.threadID) == nil && restored.transcript(for: missing.threadID).isEmpty)
        engine.shutdownAll(); restored.shutdownAll()
        print("BGCOMPLETIONTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
