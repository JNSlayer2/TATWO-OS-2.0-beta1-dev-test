import Foundation
import CryptoKit
import Darwin

enum JobsIndexAcceptance {
    private static let thread = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let other = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private enum Failure: Error { case assertion(String) }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["TATWO2_JOBSTEST"] == "1" else { return }
        Task.detached {
            do {
                let base = URL(fileURLWithPath: env["TATWO2_JOBSTEST_ROOT"]
                    ?? FileManager.default.currentDirectoryPath + "/.build-sol/jobs-index-" + UUID().uuidString)
                if env["TATWO2_JOBSTEST_REOPEN"] == "1" {
                    let loaded = try await TurnArtifacts(root: base).list(threadID: thread, turnID: "acceptance")
                    try check(loaded?.artifacts.contains(where: { $0.path == "large.bin" && $0.sha256 != nil }) == true, "reopen persisted hash")
                    print("JOBSTEST PASS separate-process reopen persisted index")
                } else { try await run(base: base) }
                fflush(stdout); exit(0)
            } catch {
                print("JOBSTEST FAIL \(error)"); fflush(stdout); exit(1)
            }
        }
        // No main-thread semaphore, filesystem access, or subprocess wait.
        dispatchMain()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure.assertion(label) }
    }

    private static func run(base: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let workspace = base.appendingPathComponent("worktree")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = base.appendingPathComponent("fixture.log")
        try Data(repeating: 65, count: 100000).write(to: log)
        var records: [BackgroundJobManager.Record] = []
        for i in 0..<54 {
            records.append(.init(jobID: UUID(), pid: 0, title: "fixture-\(i)", command: "not executed",
                                 cwd: workspace.path, logPath: log.path, threadID: i < 52 ? thread : other,
                                 startedAt: Date(timeIntervalSince1970: Double(i)), state: "exited", exitCode: 0))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: base.appendingPathComponent("bg-jobs.json"))
        let manager = BackgroundJobManager(root: base)
        let store = TurnArtifacts(root: base)
        let bridge = OSAgentBridge.jobsTestBridge(manager: manager, artifacts: store, threads: [thread, other])
        let caller: [String: Any] = ["callerThreadID": thread.uuidString]
        let listed = try bridge.callForSelfTest(method: "background_list", params: caller)["jobs"] as? [[String: Any]] ?? []
        try check(listed.count == 50, "list max 50")
        try check(listed.allSatisfy { $0["logTail"] == nil && $0["command"] == nil }, "metadata without log content")
        try check(listed.first?["title"] as? String == "fixture-51", "newest first and caller isolated")
        let otherList = try bridge.callForSelfTest(method: "background_list", params: ["callerThreadID": other.uuidString])["jobs"] as? [[String: Any]]
        try check(otherList?.count == 2, "other caller isolated")
        do {
            _ = try bridge.callForSelfTest(method: "background_list", params: [:])
            throw Failure.assertion("missing caller accepted")
        } catch is Failure { throw Failure.assertion("missing caller accepted") } catch {}
        print("JOBSTEST PASS caller isolation, missing caller rejection, max 50, metadata only")

        for (requested, expected) in [(nil as Int?, 8192), (Int.max, 65536), (0, 0), (-1, 0), (17, 17)] {
            var params = caller; params["jobID"] = records[0].jobID.uuidString
            if let requested { params["tailBytes"] = requested }
            let result = try bridge.callForSelfTest(method: "background_status", params: params)
            try check((result["logTail"] as? String)?.utf8.count == expected, "tail limit \(expected)")
        }
        try Data(String(repeating: "漢", count: 40000).utf8).write(to: log)
        let unicodeTail = manager.response(records[0], tailBytes: 65536)["logTail"] as? String ?? ""
        try check(unicodeTail.utf8.count <= 65536, "UTF8 tail byte bound")
        print("JOBSTEST PASS tailBytes default 8192, cap 65536, zero/negative, UTF8")

        try Data("report\n".utf8).write(to: workspace.appendingPathComponent("report.md"))
        let large = Data(repeating: 90, count: 1024 * 1024 + 1)
        try large.write(to: workspace.appendingPathComponent("large.bin"))
        try fm.createSymbolicLink(atPath: workspace.appendingPathComponent("escape").path, withDestinationPath: base.path)
        try fm.createSymbolicLink(atPath: workspace.appendingPathComponent("inside.md").path, withDestinationPath: "report.md")
        let expectedHash = SHA256.hash(data: large).map { String(format: "%02x", $0) }.joined()
        let claim = TurnArtifacts.claimedPaths(tool: "Write", input: ["file_path": "missing.txt"])
        try check(claim == ["missing.txt"], "write claim")
        try check(TurnArtifacts.claimedPaths(tool: "Read", input: ["file_path": "report.md"]).isEmpty, "read not a write claim")
        try check(TurnArtifacts.claimedPaths(tool: "apply_patch", input: ["patch": "*** Update File: report.md\n"]).contains("report.md"), "patch claim")
        let index = try await store.collect(threadID: thread, turnID: "acceptance", messageID: "fixture-message",
                                            endedAt: Date(timeIntervalSince1970: 100), cwd: workspace.path,
                                            claimed: claim + ["escape/fixture.log", "../fixture.log", "large.bin", "inside.md"],
                                            gitFiles: ["report.md", "large.bin"])
        try check(index.artifacts.first(where: { $0.path == "missing.txt" })?.exists == false, "missing claim preserved")
        try check(index.artifacts.filter(\.outside).count == 2, "traversal and symlink escape")
        try check(index.artifacts.filter(\.outside).allSatisfy { $0.sha256 == nil && $0.sizeBytes == nil && !$0.exists }, "outside no content")
        try check(index.artifacts.allSatisfy { !$0.path.hasPrefix("/") && !$0.path.hasPrefix("../") }, "relative-only output")
        try check(index.artifacts.first(where: { $0.path == "large.bin" })?.sha256 == expectedHash, "background large hash")
        try check(index.artifacts.first(where: { $0.path == "inside.md" })?.exists == true, "inside symlink")
        try check(index.artifacts.first(where: { $0.path == "report.md" })?.claimed == false, "git observation not engine claim")
        try check(index.artifacts.allSatisfy { $0.verifiedBy == nil }, "not lead verified")
        print("JOBSTEST PASS structured claims, missing file, traversal/symlink escape, relative paths, git union")
        print("JOBSTEST PASS >1MiB SHA256 off main actor, inside symlink, verifiedBy nil")
        let huge = workspace.appendingPathComponent("too-large.bin")
        fm.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(TurnArtifacts.maxHashBytes + 1)); try handle.close()
        let limited = try await store.collect(threadID: other, turnID: "limits", messageID: nil, endedAt: Date(),
                                              cwd: workspace.path, claimed: ["too-large.bin"],
                                              gitFiles: (0...205).map { "missing-\($0)" })
        try check(limited.truncated && limited.artifacts.count == 200, "artifact row bound")
        try check(limited.artifacts.first?.hashState == "size_limit" && limited.artifacts.first?.sha256 == nil, "hash ceiling")
        print("JOBSTEST PASS index 200 row cap and 64MiB hash ceiling")

        let tools = try bridge.callForSelfTest(method: "artifacts_list", params: caller)
        try check(tools["turnID"] as? String == "acceptance", "tool latest")
        let wrongTurn = try bridge.callForSelfTest(method: "artifacts_list", params: ["callerThreadID": other.uuidString, "turnID": "acceptance"])
        try check((wrongTurn["artifacts"] as? [Any])?.isEmpty == true, "tool cross-thread isolation")
        let restored = try await TurnArtifacts(root: base).list(threadID: thread, turnID: "acceptance")
        try check(restored?.artifacts == index.artifacts, "store reload")
        _ = try await store.collect(threadID: thread, turnID: "older", messageID: nil, endedAt: Date(timeIntervalSince1970: 1),
                                    cwd: workspace.path, claimed: [], gitFiles: [])
        let latest = try await store.list(threadID: thread)
        try check(latest?.turnID == "acceptance", "out of order completion preserves latest")
        print("JOBSTEST PASS artifacts_list shared store, isolation, reload, latest ordering")
        try check(TurnArtifactsGit.paths("R  new name\0old name\0?? 中文.md\0") == ["new name", "中文.md"], "git NUL rename parsing")
        try check(TurnArtifactsGit.run(["init", "--quiet"], cwd: workspace.path) != nil, "fixture git init")
        let status = TurnArtifactsGit.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd: workspace.path)
        try check(status.map { TurnArtifactsGit.paths($0).contains("report.md") } == true, "bounded git subprocess")
        try check(TurnArtifactsGit.run(["--not-a-valid-option"], cwd: workspace.path) == nil, "git failure remains visible")
        print("JOBSTEST PASS bounded git subprocess, failure, NUL paths including rename and Unicode")

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO2_JOBSTEST_ROOT"] = base.path
        environment["TATWO2_JOBSTEST_REOPEN"] = "1"
        child.environment = environment
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 0, "separate process reopen")
        let jsonEncoder = JSONEncoder(); jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("JOBSTEST INDEX JSON")
        print(String(decoding: try jsonEncoder.encode(index.artifacts), as: UTF8.self))
        print("JOBSTEST PASS (0 LLM calls; fixtures retained under scratch path)")
    }
}
