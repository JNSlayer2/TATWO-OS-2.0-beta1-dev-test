import Foundation

/// Real App model/store -> grouped sidecar process -> SDK event path.
/// The sidecar is a local fixture, never a model or user session.
enum TurnLifecycleAcceptance {
    @MainActor static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path)
        let script = root.appendingPathComponent("lifecycle-fixture.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args = process.argv.slice(2), cwd = args[args.indexOf('--cwd') + 1];
        const emit = msg => console.log(JSON.stringify({ev:'sdk',msg}));
        let active, prior, timer, rejectedStop = false;
        const watch = (file, subtype) => {
          clearInterval(timer);
          timer = setInterval(() => {
            if (!fs.existsSync(cwd+'/'+file)) return;
            clearInterval(timer);
            const uuid = active;
            emit({type:'result',client_turn_id:uuid,subtype,is_error:subtype==='error',result:subtype==='error'?'fixture failed':''});
            emit({type:'system',subtype:'model',model:'fixture-native'});
            prior = uuid;
          },10);
        };
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => {
          const c = JSON.parse(line);
          fs.appendFileSync(cwd+'/lifecycle-commands.jsonl',JSON.stringify({op:c.op,uuid:c.uuid})+'\n');
          if(c.op === 'send') {
            active = c.uuid;
            emit({type:'system',subtype:'init',session_id:'lifecycle-fixture',model:'fixture-native'});
            if(prior) {
              emit({type:'stream_event',client_turn_id:prior,event:{type:'content_block_delta',delta:{type:'text_delta',text:'STALE'}}});
              emit({type:'result',client_turn_id:prior,subtype:'success',is_error:false,result:'STALE'});
            }
            emit({type:'stream_event',client_turn_id:active,event:{type:'content_block_delta',delta:{type:'text_delta',text:c.text}}});
            emit({type:'assistant',client_turn_id:active,message:{content:[{type:'tool_use',id:active+'-tool',name:'fixture_tool',input:{}}]}});
            if(c.text === 'second') watch('finish-success','success');
            if(c.text === 'third') watch('finish-failure','error');
          } else if(c.op === 'interrupt') {
            if(!rejectedStop) {
              rejectedStop = true;
              console.log(JSON.stringify({ev:'error',terminal:false,client_turn_id:active,message:'fixture stop rejected'}));
            }
            watch('finish-stop','cancelled');
          }
          else if(c.op === 'close') process.exit(0);
        });
        rl.on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let priorDefaults = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = priorDefaults
        overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(priorDefaults, forName: UserDefaults.argumentDomain) }
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "lifecycle-fixture", workdir: path)
        let parent = engine.newThread(in: project)
        let thread = engine.newThread(in: project)
        engine.configureRoom(threadID: thread, parentThreadID: parent, roomBrief: "fixture",
                             engine: "codex", cwdOverride: path)
        let bots = BotStore(root: root.appendingPathComponent("live"))
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, bots))
        let bridge = OSAgentBridge.botCoreTestBridge(library: bots.library)
        bridge.configureCallerTest(model: model, manager: BackgroundJobManager())
        model.selectedThreadID = thread
        // botCoreFixture deliberately skips live subscriptions. Mirror the
        // existing production projection without activating any real bridges.
        engine.onChange = { [weak model, weak engine] in
            guard let model, let engine else { return }
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
        }
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1 }
            print("TURNLIFECYCLETEST \(value ? "PASS" : "FAIL") \(name)")
        }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "TurnLifecycleAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        func commands() -> [[String: Any]] {
            guard let data = try? String(contentsOf: root.appendingPathComponent("lifecycle-commands.jsonl"),
                                         encoding: .utf8) else { return [] }
            return data.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        check("fixture send accepted", engine.send(threadID: thread, text: "first", model: "fixture", engine: .codex))
        try await until("first tool event") { engine.transcript(for: thread).contains { $0.eventKind == .toolUse } }
        check("tool execution remains running in the engine", engine.isRunning(thread))
        check("ending a text segment does not mark background work done", engine.threadRecord(thread)?.subStatus == "running")
        check("view model reflects background execution", model.isRunning)
        model.stop()
        try await until("interrupt reached fixture") { commands().contains { $0["op"] as? String == "interrupt" } }
        try await until("recoverable stop error") {
            engine.transcript(for: thread).contains { $0.text == "fixture stop rejected" }
        }
        check("stop waits for native terminal confirmation", engine.isRunning(thread))
        check("stop button does not falsely report idle", model.isRunning)
        check("rejected stop is visible without pretending the turn failed",
              engine.transcript(for: thread).contains { $0.text == "fixture stop rejected" && $0.status == "error|停止失敗" }
              && engine.threadRecord(thread)?.subStatus == "running")
        check("background room stays active until confirmation", engine.threadRecord(thread)?.subStatus == "running")
        var unpairedRejected = false
        do { _ = try bridge.callForSelfTest(method: "stop_thread", params: ["threadID": thread.uuidString]) }
        catch { unpairedRejected = String(describing: error).contains("remote_access_disabled") }
        check("unpaired remote access remains rejected", unpairedRejected)
        // Registration metadata only, in the fixture root. No SSH trust/key write,
        // pairing listener or remote connection is created by this acceptance.
        let registry = DeviceRegistry(root: root.appendingPathComponent("live"),
            authorizedKeysURL: root.appendingPathComponent("unused-authorized-keys"), environment: env)
        try registry.add(id: "fixture-peer", name: "fixture", host: "fixture.invalid",
                         user: "fixture", publicKeyFingerprint: "SHA256:fixture")
        let requested = try bridge.callForSelfTest(method: "stop_thread", params: ["threadID": thread.uuidString])
        check("remote stop response distinguishes requested from confirmed",
              requested["stopRequested"] as? Bool == true && requested["stopped"] as? Bool == false)
        let roomStop = try bridge.callForSelfTest(method: "stop_room",
            params: ["roomID": thread.uuidString, "callerThreadID": parent.uuidString])
        check("room stop does not falsely acknowledge completion", roomStop["stopped"] as? Bool == false)
        let allStop = try bridge.callForSelfTest(method: "stop_all_rooms",
            params: ["callerThreadID": parent.uuidString])
        check("stop all rooms also waits for confirmation", allStop["stopped"] as? Bool == false)
        if engine.isRunning(thread) {
            check("another ordinary send cannot overlap pending cancellation",
                  !engine.send(threadID: thread, text: "must-not-start", model: "fixture", engine: .codex))
        }
        try Data().write(to: root.appendingPathComponent("finish-stop"))
        try await until("cancelled terminal") { !engine.isRunning(thread) }
        // Consume both terminal and immediately following late system metadata.
        try await Task.sleep(for: .milliseconds(50))
        check("confirmed stop clears view model running", !model.isRunning)
        check("late system metadata does not resurrect background work", engine.threadRecord(thread)?.subStatus == "done")
        check("cancelled tool no longer appears running", engine.transcript(for: thread)
            .filter { $0.eventKind == .toolUse }.allSatisfy { $0.status?.hasPrefix("cancelled") == true })
        check("cancelled turn does not create a failure message", !engine.transcript(for: thread)
            .contains { $0.status == "error|回合失敗" })

        check("explicit new send accepted after confirmation",
              engine.send(threadID: thread, text: "second", model: "fixture", engine: .codex))
        try await until("second tool") { engine.transcript(for: thread).filter { $0.eventKind == .toolUse }.count == 2 }
        check("old completion cannot clear new running state", engine.isRunning(thread) && model.isRunning)
        check("old text cannot enter new transcript", !engine.transcript(for: thread).contains { $0.text.contains("STALE") })
        try Data().write(to: root.appendingPathComponent("finish-success"))
        try await until("normal terminal") { !engine.isRunning(thread) }
        try await Task.sleep(for: .milliseconds(50))
        check("normal completion keeps background room done", engine.threadRecord(thread)?.subStatus == "done")
        check("completed turn cannot leave a tool spinner running",
              !engine.transcript(for: thread).contains { $0.status?.hasPrefix("running-command") == true })
        check("missing tool result is not invented as successful output",
              engine.transcript(for: thread).last(where: { $0.eventKind == .toolUse })?.status?.hasPrefix("info|") == true)
        let idle = try bridge.callForSelfTest(method: "stop_thread", params: ["threadID": thread.uuidString])
        check("remote idle stop reports confirmed state", idle["stopped"] as? Bool == true)
        let idleRooms = try bridge.callForSelfTest(method: "stop_all_rooms",
            params: ["callerThreadID": parent.uuidString])
        check("all rooms report stopped after terminal event", idleRooms["stopped"] as? Bool == true)
        let stopCount = commands().filter { $0["op"] as? String == "interrupt" }.count
        model.stop()
        try await Task.sleep(for: .milliseconds(50))
        check("idle stop does not contact sidecar", commands().filter { $0["op"] as? String == "interrupt" }.count == stopCount)
        check("explicit third send accepted", engine.send(threadID: thread, text: "third", model: "fixture", engine: .codex))
        try await until("third tool") { engine.transcript(for: thread).filter { $0.eventKind == .toolUse }.count == 3 }
        try Data().write(to: root.appendingPathComponent("finish-failure"))
        try await until("failed terminal") { !engine.isRunning(thread) }
        try await Task.sleep(for: .milliseconds(50))
        check("failed native turn stays failed after late metadata", engine.threadRecord(thread)?.subStatus == "failed")
        check("failure stops the unfinished tool spinner",
              engine.transcript(for: thread).last(where: { $0.eventKind == .toolUse })?.status == "error|回合失敗")
        check("failure remains visible in transcript", engine.transcript(for: thread)
            .contains { $0.role == .system && $0.status == "error|回合失敗" && $0.text == "fixture failed" })
        check("only three explicit sends reached fixture",
              commands().filter { $0["op"] as? String == "send" }.count == 3)
        check("production sidecar path was not used", ClaudeSidecar.scriptPath(for: .codex) == script.path)
        print("TURNLIFECYCLETEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
