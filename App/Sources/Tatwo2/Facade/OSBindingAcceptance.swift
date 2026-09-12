import Foundation
import CryptoKit

/// Isolated, no engines, no cleanup/deletion. Supersedes the legacy removal test without editing SelfTest.swift.
enum OSBindingAcceptance {
    @MainActor static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["TATWO2_BINDTEST"] == "1" else { return false }
        Task.detached { await run() }
        // Keep MainActor on the main thread while the no-LLM bridge tests run.
        RunLoop.main.run()
        return true
    }
    static func run() async {
        var failed = false
        func check(_ name: String, _ condition: Bool) {
            print("BINDTEST \(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failed = true }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tatwo2-bind-preview-" + UUID().uuidString).path
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            // Exercise the production bridge with an isolated live document; never send to an LLM.
            let roomPath = root + "/room"
            try fm.createDirectory(atPath: roomPath, withIntermediateDirectories: true)
            var testEnvironment = ProcessInfo.processInfo.environment
            testEnvironment["TATWO2_LIVE_ROOT"] = root + "/receipts-live"
            // os_binding_status 走 model 既有 environment：綁到本 fixture 的 OS root 與兩個 target（同下方 `environment`）
            testEnvironment["TATWO2_OS_ROOT"] = root + "/os"
            testEnvironment["TATWO2_BIND_TARGETS"] = "a=\(root)/A.md,b=\(root)/B.md"
            let store = ChatLiveStore(root: URL(fileURLWithPath: root + "/receipts-live"))
            let bots = BotStore(root: URL(fileURLWithPath: root + "/receipts-live"))
            let manager = BackgroundJobManager(root: URL(fileURLWithPath: root + "/receipts-live"))
            let (model, parent, room) = await MainActor.run { () -> (ChatPageModel, UUID, UUID) in
                    let live = ChatLiveEngine(store: store, environment: testEnvironment)
                    let project = live.newProject(name: "receipt-test", workdir: root)
                    let parent = live.newThread(in: project, title: "parent")
                    let room = live.newThread(in: project, title: "room")
                    live.configureRoom(threadID: room, parentThreadID: parent, roomBrief: "no LLM", engine: "codex", cwdOverride: roomPath)
                    let model = ChatPageModel(environment: testEnvironment, botCoreFixture: (live, bots))
                    model.document = live.document
                    model.selectedThreadID = parent
                    OSAgentBridge.shared.configureCallerTest(model: model, manager: manager)
                    return (model, parent, room)
            }
            defer { withExtendedLifetime(model) {} }
            let sent = OSAgentBridge.cliSendReceipt(id: room.uuidString)
            check("cli_send receipt readWith and terminal id", sent["sent"] as? Bool == true && sent["id"] as? String == room.uuidString && sent["readWith"] as? String == "cli_tail")
            let rows = try OSAgentBridge.shared.callForSelfTest(method: "list_rooms", params: ["callerThreadID": parent.uuidString])["rooms"] as? [[String: Any]] ?? []
            // dispatch-hygiene：requestedModel 從 live engine 持久化欄位一路到 list_rooms 同值
            await MainActor.run { (model.live as? ChatLiveEngine)?.setRequestedModel("gpt-test-requested", threadID: room) }
            let requestedRows = try OSAgentBridge.shared.callForSelfTest(method: "list_rooms", params: ["callerThreadID": parent.uuidString])["rooms"] as? [[String: Any]] ?? []
            check("list_rooms requestedModel 同 live 持久化欄位", requestedRows.first?["requestedModel"] as? String == "gpt-test-requested")
            check("list_rooms receipt fields", rows.count == 1 && rows[0]["branch"] is String && rows[0]["requestedModel"] is String && rows[0]["dispatchedBy"] as? String == parent.uuidString && rows[0]["sizeMeasuredAt"] is String)
            check("worktreeExists on cold cache real directory", rows.first?["worktreeExists"] as? Bool == true)
            check("ordinary directory has no branch", rows.first?["branch"] as? String == "")
            // Real du cache, plus deterministic age boundaries (no fabricated live values).
            for _ in 0..<200 {
                if CallerDirectoryCache.shared.snapshot(roomPath).measuredAt != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let measuredRows = try OSAgentBridge.shared.callForSelfTest(method: "list_rooms", params: ["callerThreadID": parent.uuidString])["rooms"] as? [[String: Any]] ?? []
            let now = Date()
            let measured = CallerDirectoryCache.shared.snapshot(roomPath)
            let stamp = measuredRows.first?["sizeMeasuredAt"] as? String ?? ""
            check("sizeMeasuredAt and sizeStale reflect successful measurement and 60s boundary",
                rows.first?["sizeMeasuredAt"] as? String == "" && rows.first?["sizeStale"] as? Bool == true
                && measured.measuredAt != nil && ISO8601DateFormatter().date(from: stamp) != nil
                && measuredRows.first?["sizeStale"] as? Bool == false
                && CallerDirectoryCache.Snapshot().isStale(at: now)
                && !CallerDirectoryCache.Snapshot(measuredAt: now.addingTimeInterval(-60)).isStale(at: now)
                && CallerDirectoryCache.Snapshot(measuredAt: now.addingTimeInterval(-61)).isStale(at: now))
            // Owned git repo + linked worktree: queries must run in project workdir, not the child.
            func git(_ args: [String]) throws -> String {
                let p = Process(), output = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-C", root] + args
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
                p.environment = env
                p.standardOutput = output; p.standardError = FileHandle.nullDevice
                try p.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { throw BotLibraryError.invalid("owned_git_fixture_failed") }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            _ = try git(["init", "-b", "main"])
            _ = try git(["config", "user.name", "Owned Fixture"])
            _ = try git(["config", "user.email", "fixture@example.invalid"])
            _ = try git(["commit", "--allow-empty", "-m", "base"])
            _ = try git(["worktree", "add", "-b", "friction-child", roomPath])
            _ = try git(["-C", roomPath, "commit", "--allow-empty", "-m", "child"])
            await MainActor.run {
                (model.live as? ChatLiveEngine)?.markSubStatus(room, "done")
                if let live = model.live { model.document = live.document }
            }
            func roomMerge() throws -> [String: Any] {
                let result = try OSAgentBridge.shared.callForSelfTest(method: "list_rooms", params: ["callerThreadID": parent.uuidString])
                return ((result["rooms"] as? [[String: Any]])?.first?["merge"] as? [String: Any]) ?? [:]
            }
            let unmerged = try roomMerge()
            check("merge unmerged branch is false with actual check time", unmerged["merged"] as? Bool == false
                && unmerged["commit"] as? String == ""
                && ISO8601DateFormatter().date(from: unmerged["checkedAt"] as? String ?? "") != nil)
            _ = try git(["merge", "--no-ff", "friction-child", "-m", "merge child"])
            let mergeCommit = try git(["rev-parse", "HEAD"])
            let merged = try roomMerge()
            check("merge no-ff returns the real merge commit", merged["merged"] as? Bool == true
                && merged["commit"] as? String == mergeCommit
                && ISO8601DateFormatter().date(from: merged["checkedAt"] as? String ?? "") != nil)
            _ = try git(["worktree", "add", "-b", "friction-ff", root + "/ff-room"])
            _ = try git(["-C", root + "/ff-room", "commit", "--allow-empty", "-m", "ff child"])
            _ = try git(["merge", "--ff-only", "friction-ff"])
            let ffTip = try git(["rev-parse", "friction-ff"])
            let ff = OSAgentBridge.mergeReceipt(branch: "friction-ff", workdir: root)
            let missing = OSAgentBridge.mergeReceipt(branch: "missing-branch", workdir: root)
            let invalidRevision = OSAgentBridge.mergeReceipt(branch: "friction-ff~1", workdir: root)
            check("merge rejects revision syntax disguised as branch", invalidRevision["merged"] as? Bool == false
                && invalidRevision["commit"] as? String == "")
            let coldMerge = rows.first?["merge"] as? [String: Any] ?? [:]
            check("merge unchecked room has no checkedAt", coldMerge["merged"] as? Bool == false
                && coldMerge["commit"] as? String == "" && coldMerge["checkedAt"] as? String == "")

            check("merge fast-forward tip and missing branch fail closed", ff["merged"] as? Bool == true
                && ff["commit"] as? String == ffTip && missing["merged"] as? Bool == false && missing["commit"] as? String == "")

            let cappedParent = await MainActor.run { () -> UUID? in
                guard let live = model.live as? ChatLiveEngine,
                      let projectID = live.threadRecord(parent)?.projectID else { return nil }
                let cappedParent = live.newThread(in: projectID, title: "merge cap parent")
                for i in 0..<51 {
                    let child = live.newThread(in: projectID, title: "merge cap child \(i)")
                    live.configureRoom(threadID: child, parentThreadID: cappedParent, roomBrief: "no LLM", engine: "codex", cwdOverride: roomPath)
                    live.markSubStatus(child, "done")
                }
                model.document = live.document
                return cappedParent
            }
            if let cappedParent {
                let capRows = try OSAgentBridge.shared.callForSelfTest(method: "list_rooms", params: ["callerThreadID": cappedParent.uuidString])["rooms"] as? [[String: Any]] ?? []
                let receipts = capRows.compactMap { $0["merge"] as? [String: Any] }
                check("merge checks at most 50 eligible rooms", receipts.count == 51
                    && receipts.filter { ($0["checkedAt"] as? String ?? "").isEmpty }.count == 1
                    && receipts.filter { $0["merged"] as? Bool == true }.count == 50)
            } else { check("merge cap fixture real live engine", false) }
            let identity = try OSAgentBridge.shared.callForSelfTest(method: "whoami", params: ["callerThreadID": room.uuidString])
            check("whoami callerWorktree and projectWorkdir preserve cwd", identity["callerWorktree"] as? String == roomPath && identity["projectWorkdir"] as? String == root && identity["cwd"] as? String == roomPath)
            let parentIdentity = try OSAgentBridge.shared.callForSelfTest(method: "whoami", params: ["callerThreadID": parent.uuidString])
            check("whoami no override is null", parentIdentity["callerWorktree"] is NSNull && parentIdentity["cwd"] as? String == root)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let legacy = try decoder.decode(LiveThreadRecord.self, from: Data("{}".utf8))
            check("legacy missing optional room fields decodes", legacy.parentThreadID == nil && legacy.cwdOverride == nil)
            if let legacyPath = ProcessInfo.processInfo.environment["TATWO2_BIND_LEGACY_DOCUMENT"] {
                // Read-only copy, never print content or private identifiers.
                let data = try Data(contentsOf: URL(fileURLWithPath: legacyPath))
                _ = try decoder.decode(LiveDocumentRecord.self, from: data)
                check("legacy document copy decodes", true)
            } else {
                print("BINDTEST 未跑 legacy document copy (TATWO2_BIND_LEGACY_DOCUMENT not set)")
            }
            func put(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: root + "/" + name)) }
            func text(_ name: String) throws -> String { try OSUpstreamBinding.readText(root + "/" + name) }
            func env(_ targets: String, _ entrance: String = "os") -> [String: String] {
                ["TATWO2_OS_ROOT": root + "/" + entrance, "TATWO2_BIND_TARGETS": targets]
            }
            try fm.createDirectory(atPath: root + "/branch-fixture/.git", withIntermediateDirectories: true)
            try put("branch-fixture/.git/HEAD", "ref: refs/heads/receipt-test\n")
            check("branch reads repository HEAD", OSAgentBridge.worktreeBranch(root + "/branch-fixture") == "receipt-test")
            try fm.createDirectory(atPath: root + "/linked-fixture", withIntermediateDirectories: true)
            try put("linked-fixture/.git", "gitdir: ../branch-fixture/.git\n")
            check("branch reads relative worktree gitdir", OSAgentBridge.worktreeBranch(root + "/linked-fixture") == "receipt-test")
            let dispatched = DispatchedRoom(roomID: "test", threadID: "test", worktree: root + "/linked-fixture")
            check("DispatchedRoom branch uses worktree HEAD", dispatched.branch == "receipt-test")
            try put("branch-fixture/.git/HEAD", String(repeating: "a", count: 40) + "\n")
            check("detached and missing branches unknown", OSAgentBridge.worktreeBranch(root + "/linked-fixture").isEmpty && OSAgentBridge.worktreeBranch(root + "/missing").isEmpty)
            let environment = env("a=\(root)/A.md,b=\(root)/B.md")
            let prefix = "個人規則\r\n\n<!-- TATWO_OS_UPSTREAM_BINDING_V1:BEGIN -->\n舊規則\n<!-- TATWO_OS_UPSTREAM_BINDING_V1:END -->\n"
            let suffix = "\r\n\n尾巴\t  \n"
            let oldBlock = OSUpstreamBinding.block(root: "old", hash: "old")
            try put("A.md", prefix + oldBlock + suffix)
            let plan = OSUpstreamBinding.preview(environment: environment)
            check("preview stale + unbound", plan.items.map(\.state) == [.stale, .unbound])
            // MARK: Goal #7 擴充點：os_binding_status（read-only，經現 MCP 登記）
            do {
                func sha(_ path: String) -> String {
                    guard let data = fm.contents(atPath: path) else { return "absent" }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                func snapshot() -> [String] {
                    let osDir = (try? fm.contentsOfDirectory(atPath: root + "/os"))?.sorted() ?? ["<absent>"]
                    return [sha(root + "/A.md"), sha(root + "/B.md")] + osDir
                }
                let before = snapshot()
                let status = try OSAgentBridge.shared.callForSelfTest(method: "os_binding_status", params: ["callerThreadID": room.uuidString])
                let items = status["items"] as? [[String: Any]] ?? []
                let expected = plan.items.map { ["id": $0.target.id, "path": $0.path, "state": $0.state.rawValue, "expectedHash": $0.expectedHash, "currentBlockHash": $0.currentBlockHash ?? "nil"] }
                let got = items.map { ["id": $0["id"] as? String ?? "", "path": $0["path"] as? String ?? "", "state": $0["state"] as? String ?? "", "expectedHash": $0["expectedHash"] as? String ?? "", "currentBlockHash": ($0["currentBlockHash"] as? String) ?? "nil"] }
                check("os_binding_status items 與 UI preview.items 一致（stale＋unbound、hash 同）", got == expected && items.count == 2)
                check("os_binding_status osRoot／upstreamHash／writable:false／ownerSource=caller", status["osRoot"] as? String == root + "/os" && status["upstreamHash"] as? String == OSUpstreamBinding.upstreamHash(environment: environment) && status["writable"] as? Bool == false && status["ownerSource"] as? String == "caller")
                let keys = Set(items.flatMap { $0.keys })
                check("os_binding_status 不回 original／diff／規則全文", !keys.contains("diff") && !keys.contains("original") && status["upstream"] == nil && status["constitution"] == nil)
                check("os_binding_status 呼叫前後 target hash 與 os root 目錄內容不變", snapshot() == before)
                func rejected(_ params: [String: Any]) -> Bool {
                    do { _ = try OSAgentBridge.shared.callForSelfTest(method: "os_binding_status", params: params); return false } catch { return true }
                }
                check("os_binding_status 非 owner（未知 thread）拒絕", rejected(["callerThreadID": UUID().uuidString]))
                check("os_binding_status 拒 path／target／environment 參數覆寫", rejected(["callerThreadID": room.uuidString, "path": "/etc"]) && rejected(["callerThreadID": room.uuidString, "target": "a"]) && rejected(["callerThreadID": room.uuidString, "environment": ["TATWO2_OS_ROOT": "/"]]))
                check("os_binding_status 越權後 fixture 仍不變", snapshot() == before)
                // 真 Node stdio MCP：tools/list ＋ tools/call（同一 owned socket；只本 fixture）
                let socket = OSAgentBridge.shared.socketPath
                try fm.createDirectory(atPath: (socket as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                await MainActor.run { OSAgentBridge.shared.start(model: model) }
                var waited = 0
                while !fm.fileExists(atPath: socket) && waited < 60 { try await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
                check("os bridge socket listening（owned fixture 路徑）", fm.fileExists(atPath: socket) && socket.hasPrefix(ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"] ?? "<none>"))
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["node", "Engines/os-mcp/server.mjs"]
                var nodeEnv = ProcessInfo.processInfo.environment
                nodeEnv["TATWO2_OS_SOCKET"] = socket
                nodeEnv["TATWO2_THREAD_ID"] = room.uuidString
                p.environment = nodeEnv
                let input = Pipe(), output = Pipe()
                p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.standardError
                try p.run()
                let lines = [
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"os_binding_status","arguments":{}}}"#,
                    #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"os_binding_status","arguments":{"path":"/etc"}}}"#,
                ]
                try input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
                try input.fileHandleForWriting.close()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                for line in text.split(separator: "\n") { print("BINDTEST MCP-RAW " + line.prefix(1200)) }
                let replies = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let byID = Dictionary(uniqueKeysWithValues: replies.compactMap { r in (r["id"] as? Int).map { ($0, r) } })
                let toolList = (byID[1]?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
                let listed = toolList.first { $0["name"] as? String == "os_binding_status" }
                let schema = listed?["inputSchema"] as? [String: Any]
                check("MCP tools/list 有 os_binding_status 且 schema 無參數、additionalProperties=false", listed != nil && (schema?["properties"] as? [String: Any])?.isEmpty == true && schema?["additionalProperties"] as? Bool == false)
                let callText = ((byID[2]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                let callObj = (try? JSONSerialization.jsonObject(with: Data(callText.utf8))) as? [String: Any]
                let callItems = callObj?["items"] as? [[String: Any]] ?? []
                check("MCP tools/call os_binding_status 回 stale＋unbound 同 UI preview、writable:false", (byID[2]?["result"] as? [String: Any])?["isError"] == nil && callItems.map { $0["state"] as? String ?? "" } == ["stale", "unbound"] && callObj?["writable"] as? Bool == false && callObj?["osRoot"] as? String == root + "/os")
                let badResult = byID[3]?["result"] as? [String: Any]
                check("MCP tools/call 帶 path 參數 → isError（server 端拒）", badResult?["isError"] as? Bool == true && p.terminationStatus == 0)
                check("MCP 呼叫後 target hash 與 os root 目錄內容不變", snapshot() == before)
            }
            check("diff only owned block", !plan.items[0].diff.contains("個人規則") && !plan.items[0].diff.contains("尾巴"))
            let result = OSUpstreamBinding.apply(plan, environment: environment)
            try check("seed absent entrance + readback", result.failure == nil && fm.fileExists(atPath: root + "/os/os-upstream.md") && (try text("os/os.md")) == OSUpstreamBinding.bundled("os"))
            let newText = try text("A.md")
            let range = try OSUpstreamBinding.blockRange(newText)!
            check("outside block byte-identical", Data(newText[..<range.lowerBound].utf8) == Data(prefix.utf8) && Data(newText[range.upperBound...].utf8) == Data(suffix.utf8))
            try check("backup exists exact original", result.backups.count == 1 && (try OSUpstreamBinding.readText(result.backups[0])) == prefix + oldBlock + suffix)
            let bound = OSUpstreamBinding.preview(environment: environment)
            check("preview bound + hashes match", bound.items.allSatisfy { $0.state == .bound && $0.currentBlockHash == $0.expectedHash })
            let noOp = OSUpstreamBinding.apply(bound, environment: environment)
            check("bound no-op", noOp.modified.isEmpty && noOp.backups.isEmpty && noOp.failure == nil)
            try put("bad.md", OSUpstreamBinding.beginMarker)
            let unread = OSUpstreamBinding.preview(environment: env("bad=\(root)/bad.md"))
            check("preview unreadable malformed block", unread.items.first?.state == .unreadable)
            try put("large.md", String(repeating: "x", count: OSUpstreamBinding.byteLimit + 1))
            check("bounded reads", OSUpstreamBinding.preview(environment: env("large=\(root)/large.md")).items.first?.state == .unreadable)
            try put("first.md", "first")
            try put("readonly.md", "read only")
            try put("last.md", "last")
            try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: root + "/readonly.md")
            let stopEnv = env("first=\(root)/first.md,readonly=\(root)/readonly.md,last=\(root)/last.md")
            let stopped = OSUpstreamBinding.apply(OSUpstreamBinding.preview(environment: stopEnv), environment: stopEnv)
            try check("readonly stops + partial report", stopped.failure?.contains("readonly.md") == true && stopped.modified == [root + "/first.md"] && (try text("last.md")) == "last" && (try text("readonly.md")) == "read only")
            let changedPlan = OSUpstreamBinding.preview(environment: env("last=\(root)/last.md"))
            try put("last.md", "someone else edited")
            let changed = OSUpstreamBinding.apply(changedPlan, environment: env("last=\(root)/last.md"))
            try check("stale preview no write", changed.failure != nil && changed.modified.isEmpty && (try text("last.md")) == "someone else edited")
            try fm.createDirectory(atPath: root + "/legacy", withIntermediateDirectories: true)
            try put("legacy/os.md", "old constitution\r\n")
            let seedEnv = env("last=\(root)/last.md", "legacy")
            let seedPlan = OSUpstreamBinding.preview(environment: seedEnv)
            check("seed confirmation lists all paths", seedPlan.paths.contains(root + "/legacy/os.1.0.md") && seedPlan.paths.contains(root + "/legacy/os.md") && seedPlan.paths.contains(root + "/legacy/os-upstream.md"))
            let seeded = OSUpstreamBinding.apply(seedPlan, environment: seedEnv)
            try check("legacy constitution retained + backed up", seeded.failure == nil && (try text("legacy/os.1.0.md")) == "old constitution\r\n" && seeded.backups.contains { $0.hasSuffix("/os.md") })
            try put("denied.md", "no read")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/denied.md")
            check("preview unreadable permissions + missing parent", OSUpstreamBinding.preview(environment: env("denied=\(root)/denied.md,missing=\(root)/missing/X.md")).items.allSatisfy { $0.state == .unreadable })
            try put("duplicate.md", oldBlock + oldBlock)
            check("duplicate block rejected", OSUpstreamBinding.preview(environment: env("duplicate=\(root)/duplicate.md")).items.first?.state == .unreadable)
            try fm.createDirectory(atPath: root + "/one", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: root + "/two", withIntermediateDirectories: true)
            try put("one/AGENTS.md", "one")
            try put("two/AGENTS.md", "two")
            let collisionsEnv = env("one=\(root)/one/AGENTS.md,two=\(root)/two/AGENTS.md")
            let collisions = OSUpstreamBinding.apply(OSUpstreamBinding.preview(environment: collisionsEnv), environment: collisionsEnv)
            let backupTexts = try collisions.backups.map { try OSUpstreamBinding.readText($0) }
            check("same basename backups isolated", collisions.failure == nil && backupTexts == ["one", "two"])
            try fm.createDirectory(atPath: root + "/archiveConflict", withIntermediateDirectories: true)
            try put("archiveConflict/os.md", "original")
            try put("archiveConflict/os.1.0.md", "existing archive")
            let conflictEnv = env("last=\(root)/last.md", "archiveConflict")
            let conflictPlan = OSUpstreamBinding.preview(environment: conflictEnv)
            let conflict = OSUpstreamBinding.apply(conflictPlan, environment: conflictEnv)
            check("existing archive never overwritten", conflictPlan.error != nil && conflict.modified.isEmpty)
            try put("unicode.md", "caf\u{00e9}")
            let unicodeEnv = env("unicode=\(root)/unicode.md")
            let unicodePlan = OSUpstreamBinding.preview(environment: unicodeEnv)
            try put("unicode.md", "cafe\u{0301}")
            let unicodeChanged = OSUpstreamBinding.apply(unicodePlan, environment: unicodeEnv)
            check("unicode-equivalent byte change rejected", unicodeChanged.failure != nil && unicodeChanged.modified.isEmpty)
            try put("A.md", prefix + oldBlock + suffix)
            let cancelPlan = OSUpstreamBinding.preview(environment: environment)
            try check("preview has no write side effects", cancelPlan.items[0].state == .stale && (try text("A.md")) == prefix + oldBlock + suffix)
        } catch {
            check("unexpected error: \(error.localizedDescription)", false)
        }
        print("BINDTEST fixtures retained: " + root)
        print(failed ? "BINDTEST FAILED" : "BINDTEST ALL PASS")
        fflush(stdout)
        exit(failed ? 1 : 0)
    }
}
