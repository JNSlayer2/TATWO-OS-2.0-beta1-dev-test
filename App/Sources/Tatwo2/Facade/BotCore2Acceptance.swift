import Foundation

/// Headless, isolated fixtures only. No SDK or model is imported by the echo sidecar.
enum BotCore2Acceptance {
    @MainActor final class Decisions { var tools: [String] = [] }
    static func check(_ name: String, _ value: Bool) throws {
        print("BOTCORETEST \(value ? "PASS" : "FAIL") \(name)")
        if !value { throw BotLibraryError.invalid(name) }
    }

    static func run(root: URL, threadID: UUID, socket: String) async throws {
        try await BotNotesAcceptance.run(root: root.appendingPathComponent("notes"))
        let emptyLibrary = BotLibrary(root: root.appendingPathComponent("friction/empty-library"))
        await emptyLibrary.ready()
        let emptyBridge = OSAgentBridge.botCoreTestBridge(library: emptyLibrary)
        let emptyList = try emptyBridge.callForSelfTest(method: "bot_list", params: [:])
        let populatedList = try OSAgentBridge.shared.callForSelfTest(method: "bot_list", params: [:])
        let emptyScope = emptyList["scope"] as? [String: String] ?? [:]
        let populatedScope = populatedList["scope"] as? [String: String] ?? [:]
        try check("bot_list_scope_empty_and_populated", (emptyList["bots"] as? [Any])?.isEmpty == true
            && emptyScope == ["instance": "isolated", "libraryRoot": "friction/empty-library", "reason": "no_bots_in_library"]
            && (populatedList["bots"] as? [Any])?.isEmpty == false
            && populatedScope["instance"] == "isolated" && populatedScope["reason"] == ""
            && populatedScope["libraryRoot"]?.hasPrefix("/") == false
            && populatedScope["libraryRoot"]?.split(separator: "/").count == 2)
        let unbound = try emptyBridge.callForSelfTest(method: "bot_pending_list", params: [:])
        let scope = unbound["scope"] as? [String: Any] ?? [:]
        var rejectsOther = false
        do { _ = try emptyBridge.callForSelfTest(method: "bot_pending_list", params: ["id": "someone-else"]) }
        catch { rejectsOther = String(describing: error).contains("pending_requires_own_bot") }
        try check("bot_pending_list_unbound_structure_and_ownership", (unbound["pending"] as? [Any])?.isEmpty == true
            && scope["threadIsBot"] as? Bool == false && scope["boundBotID"] is NSNull
            && scope["canProceed"] as? Bool == false
            && scope["hint"] as? String == "這條對話不是 bot；帶 id 只能查自己綁定的 bot" && rejectsOther)

        for bound in [true, false] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["node", "Engines/os-mcp/server.mjs"]
            var env = ProcessInfo.processInfo.environment
            env["TATWO2_OS_SOCKET"] = socket
            env.removeValue(forKey: "TATWO2_BOT_THREAD_ID")
            env["TATWO2_THREAD_ID"] = bound ? threadID.uuidString : nil
            p.environment = env
            let input = Pipe(), output = Pipe()
            p.standardInput = input; p.standardOutput = output; p.standardError = output
            try p.run()
            try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"bot_state_get","arguments":{}}}"#.utf8) + Data([10]))
            try input.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit(); print(text, terminator: "")
            try check(bound ? "thread_env_bound" : "thread_env_unbound", p.terminationStatus == 0 && (bound ? text.contains("stdio-task") : text.contains("這條對話不是 bot")))
        }
        try check("thread_env_in_mcp", true)
        let testRoot = root.appendingPathComponent("end-to-end")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        let script = testRoot.appendingPathComponent("echo.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args = process.argv.slice(2);
        const flag = n => args[args.indexOf(n)+1];
        const emit = x => console.log(JSON.stringify(x));
        const cwd = flag('--cwd');
        fs.writeFileSync(cwd+'/observed.json', JSON.stringify({cwd:process.cwd(),args}));
        const finish = () => setTimeout(() => emit({ev:'sdk',msg:{type:'result',subtype:'success',result:'echo-complete'}}), 1200);
        readline.createInterface({input:process.stdin}).on('line', l => {
          const c = JSON.parse(l);
          if(c.op === 'send') {
            emit({ev:'sdk',msg:{type:'system',subtype:'init',session_id:'echo-session'}});
            emit({ev:'permission_request',id:'fixture-permission',tool:'fixture_tool',input:{fixture:true}});
          } else if(c.op === 'permission') {
            fs.writeFileSync(cwd+'/permission.json',JSON.stringify(c)); finish();
          } else if(c.op === 'close') process.exit(0);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        // Volatile argument domain: never writes host preferences or auth/session files.
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous; overrides["tatwo2.sidecarPath.claude"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        setenv("TATWO2_LIVE_ROOT", testRoot.appendingPathComponent("live").path, 1)
        let store = BotStore(root: testRoot); await store.library.ready()
        let memory = BotMemory(library: store.library)
        let decisions = await MainActor.run { Decisions() }
        let live = await MainActor.run { ChatLiveEngine(store: ChatLiveStore(root: testRoot)) }
        let model = await MainActor.run { () -> ChatPageModel in
            live.permissionDecider = { tool, _ in decisions.tools.append(tool); return false }
            return ChatPageModel(environment: ["TATWO2_LIVE_ROOT": testRoot.path], botCoreFixture: (live, store))
        }
        for approval in ["ask", "auto", "full"] {
            let workdir = testRoot.appendingPathComponent(approval)
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
            let bot = try await store.library.create(.init(id: "e2e-"+approval, name: approval, emoji: "🤖", role: "general", engine: "claude", workdir: workdir.path, permissions: .init(approval: approval, mcp: [], folders: [], network: false)), instructions: "e2e-instructions")
            let pending = try await memory.remember(botID: bot.id, text: "e2e-profile", threadID: "fixture")
            try await memory.confirm(botID: bot.id, pendingID: pending)
            try await memory.updateState(botID: bot.id, patch: .init(currentTask: "e2e-state", lastSessionAt: "2000-01-01T00:00:00Z"))
            guard let id = await MainActor.run(body: { model.sendAsBot(botID: bot.id, text: "echo only") }) else { throw BotLibraryError.invalid("send_failed") }
            var finished = false
            for _ in 0..<160 {
                try await Task.sleep(for: .milliseconds(50))
                if store.library.snapshot.states[bot.id]?.lastSessionAt != "2000-01-01T00:00:00Z" { finished = true; break }
            }
            let observed = try JSONSerialization.jsonObject(with: Data(contentsOf: workdir.appendingPathComponent("observed.json"))) as! [String: Any]
            let args = observed["args"] as! [String]
            func flag(_ name: String) -> String { args.firstIndex(of: name).map { args[$0 + 1] } ?? "" }
            let prompt = flag("--system-prompt")
            let record = await MainActor.run { live.threadRecord(id) }
            let sessions = try JSONDecoder().decode([BotSessionRecord].self, from: Data(contentsOf: testRoot.appendingPathComponent("bots/\(bot.id)/sessions.json")))
            let state = try JSONDecoder().decode(BotMemoryState.self, from: Data(contentsOf: testRoot.appendingPathComponent("bots/\(bot.id)/memory/state.json")))
            let expected = approval == "ask" ? "default" : approval == "auto" ? "acceptEdits" : "bypassPermissions"
            try check("send_e2e_"+approval, finished && record?.enabledMCP == ["__tatwo_none__"] && record?.cwdOverride == workdir.path && (observed["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == workdir.resolvingSymlinksInPath().path && flag("--permission-mode") == expected && prompt.contains("e2e-instructions") && prompt.contains("e2e-profile") && prompt.contains("e2e-state") && flag("--mcp-config").contains(id.uuidString) && sessions.last?.lastActiveAt != sessions.last?.startedAt && state.lastSessionAt == sessions.last?.lastActiveAt)
            let decision = try JSONSerialization.jsonObject(with: Data(contentsOf: workdir.appendingPathComponent("permission.json"))) as! [String: Any]
            try check("permission_"+approval, decision["allow"] as? Bool == (approval != "ask"))
        }
        try check("send_as_bot_end_to_end", true)
        try check("ask_first_uses_app_decider", await MainActor.run { decisions.tools == ["fixture_tool"] })
        await MainActor.run { live.shutdownAll() }
    }
}
