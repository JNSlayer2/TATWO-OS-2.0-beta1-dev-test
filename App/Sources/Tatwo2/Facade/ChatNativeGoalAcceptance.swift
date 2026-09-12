import Foundation

@MainActor
enum ChatNativeGoalAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path)
        let script = root.appendingPathComponent("goal-fixture.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args=process.argv.slice(2), cwd=args[args.indexOf('--cwd')+1];
        const sdk=msg=>console.log(JSON.stringify({ev:'sdk',msg}));
        let goal=null, turn=null, counter=0, held=null;
        const snapshot=status=>({threadId:'goal-fixture',objective:goal?.objective??'fixture',
          status,tokensUsed:321,tokenBudget:null,timeUsedSeconds:125,createdAt:1,updatedAt:2});
        const emitGoal=()=>sdk({type:'system',subtype:'goal',session_id:'goal-fixture',goal});
        const result=()=>sdk({type:'result',client_turn_id:turn,subtype:'success',is_error:false,result:''});
        sdk({type:'system',subtype:'init',session_id:'goal-fixture',model:'gpt-6-astra'});
        emitGoal();
        readline.createInterface({input:process.stdin}).on('line',line=>{
          const c=JSON.parse(line); fs.appendFileSync(cwd+'/goal-commands.jsonl',JSON.stringify(c)+'\n');
          if(c.op==='goal_get') { emitGoal(); return; }
          if(c.op==='goal_set'||c.op==='goal_clear') {
            if(c.objective==='preboot-reject') {
              sdk({type:'system',subtype:'goal_result',session_id:null,request_id:c.uuid,
                accepted:false,message:'fixture preboot rejection'}); return;
            }
            if(c.objective==='hold') { held=c; return; }
            setTimeout(()=>{
              if(c.objective==='reject') {
                sdk({type:'system',subtype:'goal_result',session_id:'goal-fixture',
                     request_id:c.uuid,accepted:false,message:'fixture rejection'}); return;
              }
              goal=c.op==='goal_clear'?null:{...snapshot(c.status),objective:c.objective??goal?.objective??'fixture'};
              emitGoal();
              sdk({type:'system',subtype:'goal_result',session_id:'goal-fixture',request_id:c.uuid,accepted:true});
              if(c.status==='active') {
                turn='native:goal-'+(++counter);
                sdk({type:'system',subtype:'native_turn_started',session_id:'goal-fixture',client_turn_id:turn});
                sdk({type:'stream_event',client_turn_id:turn,event:{type:'content_block_delta',
                  delta:{type:'text_delta',text:'原生目標工作'}}});
              }
            },40);
          } else if(c.op==='send') { turn=c.uuid;result(); }
          else if(c.op==='interrupt') {
            if(held) {
              sdk({type:'system',subtype:'goal_result',session_id:null,request_id:held.uuid,
                accepted:false,message:'fixture cancelled pending Goal'}); held=null;
            }
            if(c.pauseGoal===true&&goal?.status==='active') {goal=snapshot('paused');emitGoal();}
            sdk({type:'result',client_turn_id:turn,subtype:'cancelled',is_error:false,result:''});
          } else if(c.op==='close') process.exit(0);
        }).on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior
        overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "goal-fixture", workdir: path)
        let thread = engine.newThread(in: project)
        let other = engine.newThread(in: project)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        model.selectedThreadID = thread
        engine.onChange = { model.document = engine.document; model.isRunning = engine.isRunning(model.selectedThreadID) }
        var passed = 0, failed = 0
        func check(_ name: String, _ value: Bool) {
            if value { passed += 1 } else { failed += 1 }
            print("NATIVEGOALTEST \(value ? "PASS" : "FAIL") \(name)")
        }
        func until(_ name: String, _ condition: () -> Bool) async throws {
            for _ in 0..<250 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "ChatNativeGoalAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("goal-commands.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func report(_ goal: Any, session: String = "goal-fixture") {
            engine.handleSDK(thread, ["type": "system", "subtype": "goal", "session_id": session, "goal": goal])
        }
        func goalJSON(_ status: String) -> [String: Any] {
            ["threadId": "goal-fixture", "objective": "完成真正目標", "status": status, "tokensUsed": 321,
             "tokenBudget": NSNull(), "timeUsedSeconds": 125, "createdAt": 1, "updatedAt": 2]
        }
        check("ordinary live chat has no invented Goal", !model.selectedThreadHasWorkOSGoal && model.activeGoalObjectiveLabel.isEmpty)
        engine.refreshNativeGoal(thread)
        check("refresh and navigation never launch a process", engine.sidecarProcessID(threadID: thread) == nil)
        model.prompt = "/goal 未登入測試"; model.send()
        check("Goal activation uses existing login preflight without launching work",
              !model.nativeGoalControlPending && engine.sidecarProcessID(threadID: thread) == nil &&
              model.prompt == "/goal 未登入測試")
        // Empty fixture marker only: never real credentials or account stores.
        let fixtureAuth = EnginePaths(environment: env).codexAuth
        try "{}".write(to: fixtureAuth, atomically: true, encoding: .utf8)
        model.prompt = "/goal 完成真正目標"
        model.droppedPaths = [root.appendingPathComponent("not-auto-sent.png").path]
        check("native Goal command is locally recognized", model.isLocalNativeGoalCommand)
        model.send()
        check("creating Goal does not claim the model is already running", !engine.isRunning(thread))
        check("Goal draft and files remain pending acknowledgement", model.prompt == "/goal 完成真正目標" && model.droppedPaths.count == 1)
        check("pending Goal command prevents duplicate send", !model.canSend && model.nativeGoalControlPending)
        try await until("Goal accepted and native turn starts") { model.nativeGoalSnapshot?.status == "active" && model.isRunning }
        check("saved Goal clears only its unchanged objective draft", model.prompt.isEmpty && model.droppedPaths.count == 1)
        check("native Goal turn has no synthetic user message", !engine.transcript(for: thread).contains { $0.role == .user })
        check("Goal creation did not call send or create an extra turn", !commands().contains { $0["op"] as? String == "send" })
        let create = commands().first { $0["op"] as? String == "goal_set" }
        check("Goal activation uses GPT-6 medium and native Fast settings",
              create?["model"] as? String == "gpt-6-astra" &&
              create?["effort"] as? String == "medium" && create?["serviceTier"] as? String == "priority")
        check("real Goal is visible and current", model.selectedThreadHasWorkOSGoal && model.shouldShowActiveGoalInlineCard && model.nativeGoalIsCurrent)
        check("actual objective and native counters replace fixtures",
              model.activeGoalObjectiveLabel == "完成真正目標" && model.activeGoalElapsedLabel == "02:05" &&
              model.activeGoalHeaderProgressLabel == "321 tokens" && model.activeGoalStepProgress.total == 0)
        check("autonomous native turn offers existing steering controls", engine.canSteer(thread))
        check("Goal snapshot is persisted in the original thread document", store.load().threads.first { $0.id == thread }?.nativeGoal?.tokensUsed == 321)
        report(goalJSON("complete"), session: "other-session")
        check("another native session cannot complete this Goal", model.nativeGoalSnapshot?.status == "active")
        var invalid = goalJSON("complete"); invalid["tokensUsed"] = -1
        report(invalid)
        check("malformed native counters cannot replace the last good snapshot", model.nativeGoalSnapshot?.status == "active")
        model.toggleActiveGoalPause()
        check("pause is not displayed before native confirmation", model.nativeGoalSnapshot?.status == "active" && model.nativeGoalControlPending)
        try await until("pause and interrupt") { !engine.isRunning(thread) && model.nativeGoalSnapshot?.status == "paused" }
        check("pause preserves Goal rather than marking it complete", model.activeGoalPaused && model.canResumeActiveGoal)
        let pauseOps = commands()
        let pauseIndex = pauseOps.firstIndex { $0["op"] as? String == "goal_set" && $0["status"] as? String == "paused" }
        let interruptIndex = pauseOps.firstIndex { $0["op"] as? String == "interrupt" }
        check("pause command precedes turn interruption", pauseIndex != nil && interruptIndex != nil && pauseIndex! < interruptIndex!)
        report(goalJSON("blocked"))
        let activeCount = commands().filter { $0["op"] as? String == "goal_set" && $0["status"] as? String == "active" }.count
        model.prompt = "普通對話"; model.droppedPaths = []
        check("ordinary blocked-Goal conversation starts explicitly", engine.send(threadID: thread, text: model.prompt, model: "gpt-6-astra", engine: .codex))
        try await until("ordinary conversation ends") { !engine.isRunning(thread) }
        check("ordinary conversation cannot silently resume a blocked Goal",
              model.nativeGoalSnapshot?.status == "blocked" &&
              commands().filter { $0["op"] as? String == "goal_set" && $0["status"] as? String == "active" }.count == activeCount)
        model.toggleActiveGoalPause()
        try await until("explicit resume") { model.isRunning && model.nativeGoalSnapshot?.status == "active" }
        check("explicit resume uses native scheduling without a new user message",
              commands().filter { $0["op"] as? String == "send" }.count == 1)
        model.endActiveGoal()
        try await until("clear and stop") { model.nativeGoalSnapshot == nil && !model.isRunning }
        check("ending Goal clears it without inventing completion", !model.selectedThreadHasWorkOSGoal)
        model.prompt = "/goal preboot-reject"; model.send()
        try await until("matched rejection without native session") { !model.nativeGoalControlPending }
        check("sessionless matched rejection releases controls and retains draft",
              model.prompt == "/goal preboot-reject" && model.nativeGoalSnapshot == nil)
        check("failed Goal without snapshot is not falsely presented as absent",
              model.activeGoalStatusPresentationLabel == "目標狀態無法確認")
        model.prompt = "/goal reject"; model.send()
        try await until("rejected Goal") { !model.nativeGoalControlPending }
        check("rejected Goal creation preserves draft and shows no false Goal", model.prompt == "/goal reject" && model.nativeGoalSnapshot == nil)
        model.prompt = "/goal hold"; model.send()
        try await until("held Goal command") { commands().contains { $0["objective"] as? String == "hold" } }
        engine.stop(threadID: thread)
        try await until("pending Goal stopped before turn exists") { !model.nativeGoalControlPending }
        check("Stop reaches pending Goal even without a running turn", model.prompt == "/goal hold" && !engine.isRunning(thread))
        model.prompt = "/goal 新目標"; model.send()
        model.selectedThreadID = other; model.prompt = "另一串草稿"
        try await until("Goal accepted after navigation") { engine.threadRecord(thread)?.nativeGoal?.status == "active" }
        check("late Goal acknowledgement does not clear another thread draft", model.prompt == "另一串草稿")
        model.selectedThreadID = thread
        engine.handleSDK(thread, ["type": "system", "subtype": "goal_unavailable", "session_id": "goal-fixture", "message": "fixture unavailable"])
        check("unavailable Goal retains last data but no longer claims live state", !model.nativeGoalIsCurrent && model.activeGoalStatusPresentationLabel == "上次：進行中")
        report(goalJSON("budgetLimited"))
        check("budget limit cannot be bypassed with an unbudgeted resume", !model.canResumeActiveGoal)
        report(goalJSON("complete"))
        check("native complete is not resumable", !model.canResumeActiveGoal && model.selectedWorkOSGoalStatusLabel == "complete")
        report(goalJSON("active"))
        engine.handleSDK(thread, ["type": "result", "subtype": "success", "is_error": false, "result": ""])
        check("turn terminal does not imply active Goal completion", !engine.isRunning(thread) && model.nativeGoalSnapshot?.status == "active")
        engine.stop(threadID: thread)
        try await until("Stop between native turns still pauses Goal") { model.nativeGoalSnapshot?.status == "paused" }
        check("App forwards Stop during the gap between autonomous turns", !engine.isRunning(thread) && model.activeGoalPaused)
        report(goalJSON("active"))
        engine.shutdownAll()
        let reopened = ChatLiveEngine(store: store, environment: env)
        defer { reopened.shutdownAll() }
        check("reopening retains native counters without restarting work",
              reopened.threadRecord(thread)?.nativeGoal?.timeUsedSeconds == 125 && !reopened.isRunning(thread) &&
              !reopened.nativeGoalIsCurrent(thread) && reopened.sidecarProcessID(threadID: thread) == nil)
        print("NATIVEGOALTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
