import Foundation

@MainActor
enum ChatSteeringAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path)
        let script = root.appendingPathComponent("steering-fixture.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args = process.argv.slice(2), cwd = args[args.indexOf('--cwd')+1];
        const sdk = msg => console.log(JSON.stringify({ev:'sdk',msg}));
        let active;
        const text = (uuid, value) => sdk({type:'stream_event',client_turn_id:uuid,
          event:{type:'content_block_delta',delta:{type:'text_delta',text:value}}});
        const result = uuid => sdk({type:'result',client_turn_id:uuid,subtype:'success',is_error:false,result:''});
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => {
          const c = JSON.parse(line);
          fs.appendFileSync(cwd+'/steering-commands.jsonl',JSON.stringify(c)+'\n');
          if(c.op === 'send') {
            active = c.uuid;
            sdk({type:'system',subtype:'init',session_id:'steering-fixture',model:'native-fixture'});
            text(active,'原回合的回覆');
          } else if(c.op === 'steer') {
            const target = c.targetTurnUUID;
            if(c.text === 'hold') return;
            if(c.text === 'late') result(target);
            setTimeout(() => {
              sdk({type:'system',subtype:'steer_result',request_id:c.uuid,target_turn_id:target,
                   accepted:c.text !== 'reject',message:c.text === 'reject' ? 'fixture rejection' : undefined});
              if(c.text !== 'reject' && c.text !== 'late') text(target,'插話後的回覆');
            },c.text === 'late' ? 100 : 40);
          } else if(c.op === 'interrupt') {
            sdk({type:'result',client_turn_id:active,subtype:'cancelled',is_error:false,result:''});
          } else if(c.op === 'close') process.exit(0);
        });
        rl.on('close',()=>process.exit(0));
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
        let project = engine.newProject(name: "steering-fixture", workdir: path)
        let thread = engine.newThread(in: project)
        let other = engine.newThread(in: project)
        let model = ChatPageModel(environment: env,
            botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        model.selectedThreadID = thread
        engine.onChange = {
            model.document = engine.document
            model.isRunning = engine.isRunning(model.selectedThreadID)
        }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("CHATSTEERINGTEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        func until(_ name: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<250 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "ChatSteeringAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
        }
        func commands() -> [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("steering-commands.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func lastUser() -> ChatMessage? { engine.transcript(for: thread).last { $0.role == .user } }
        check("idle thread is not steerable", !engine.canSteer(thread))
        check("fixture starts original turn", engine.send(threadID: thread, text: "work", model: "gpt-6-astra", engine: .codex))
        try await until("original stream") { engine.transcript(for: thread).contains { $0.role == .assistant } }
        check("actual local Codex work offers native steering", model.canSteerCurrentTurn)
        model.prompt = "accept"
        model.droppedPaths = [root.appendingPathComponent("image.png").path]
        let attachments = model.droppedPaths
        check("working composer can send an insertion", model.canSend && model.sendAvailabilityDiagnostic == "插話到目前工作")
        model.send()
        let firstInsertion = lastUser()
        check("draft and images are retained until acknowledgement", model.prompt == "accept" && model.droppedPaths == attachments)
        check("pending insertion is visibly unconfirmed", firstInsertion?.status == "steering|等待插話確認")
        check("duplicate ordinary insertion cannot be submitted", !model.canSend && !engine.canSteer(thread))
        check("pending insertion keeps image metadata", firstInsertion?.inlineAttachments.map(\.path) == attachments)
        try await until("accepted insertion") { lastUser()?.status == nil && model.prompt.isEmpty }
        check("acknowledgement clears only the matching draft", model.prompt.isEmpty && model.droppedPaths.isEmpty)
        check("original work remains running", engine.isRunning(thread) && model.isRunning)
        check("no second send or turn was created", commands().filter { $0["op"] as? String == "send" }.count == 1)
        check("native request carries target and original attachments",
              commands().first { $0["op"] as? String == "steer" }?["attachments"] as? [String] == attachments &&
              commands().first { $0["op"] as? String == "steer" }?["targetTurnUUID"] as? String ==
              commands().first { $0["op"] as? String == "send" }?["uuid"] as? String)
        try await until("new assistant segment") { engine.transcript(for: thread).last?.role == .assistant }
        let rows = engine.transcript(for: thread)
        check("insertion is between assistant segments", rows.count >= 4 && rows[1].role == .assistant &&
              rows[2].id == firstInsertion?.id && rows[3].role == .assistant)
        check("segmented assistant retains its attested model",
              rows.first { $0.role == .assistant }?.modelID == "native-fixture")

        model.prompt = "reject"
        model.send()
        let rejectedID = lastUser()?.id
        try await until("rejection") { lastUser()?.status == "steer_failed|插話未送出" }
        check("native rejection preserves draft", model.prompt == "reject")
        check("rejection does not stop original work", engine.isRunning(thread))
        check("rejection permits an explicit later insertion", model.canSend)
        let savedRejection = store.load().threads.first { $0.id == thread }?.messages.first { $0.id == rejectedID }
        check("failure survives persistence", savedRejection?.status == "steer_failed|插話未送出")
        model.prompt = "editing"
        model.send()
        model.prompt = "我正在寫下一句"
        model.droppedPaths = [root.appendingPathComponent("new.png").path]
        try await until("editing ack") { engine.canSteer(thread) }
        check("late ack never erases edited text or attachments", model.prompt == "我正在寫下一句" &&
              model.droppedPaths == [root.appendingPathComponent("new.png").path])

        model.prompt = "same"
        model.droppedPaths = []
        model.send()
        model.prompt = "changed"
        model.prompt = "same"
        try await until("edit and undo ack") { engine.canSteer(thread) }
        check("editing back to the same text remains a newer draft", model.prompt == "same")

        model.prompt = "same attachment"
        model.send()
        model.droppedPaths = attachments
        model.droppedPaths = []
        try await until("attachment edit and undo ack") { engine.canSteer(thread) }
        check("attachment edit and undo prevents stale draft clearing", model.prompt == "same attachment")

        model.prompt = "same thread"
        model.send()
        model.selectedThreadID = other
        model.selectedThreadID = thread
        try await until("switch away and back ack") { engine.canSteer(thread) }
        check("returning to the same thread does not clear a later draft", model.prompt == "same thread")

        model.prompt = "accept"
        model.droppedPaths = []
        model.send()
        model.selectedThreadID = other
        model.prompt = "另一串草稿"
        try await until("ack after switch") { engine.canSteer(thread) }
        check("ack does not clear another thread's draft", model.prompt == "另一串草稿")
        model.selectedThreadID = thread
        model.prompt = "late"
        model.send()
        let lateID = lastUser()?.id
        try await until("completion before receipt") { !engine.isRunning(thread) }
        check("completion releases pending insertion without claiming delivery", lastUser()?.status == "steer_unknown|插話送達狀態待確認")
        check("unknown outcome keeps the draft", model.prompt == "late")
        check("explicit next turn starts", engine.send(threadID: thread, text: "next", model: "gpt-6-astra", engine: .codex))
        model.prompt = "hold"
        model.send()
        let successorInsertionID = lastUser()?.id
        model.prompt = "不要清除的新草稿"
        try await until("late receipt reconciles old row") {
            engine.transcript(for: thread).first { $0.id == lateID }?.status == nil
        }
        check("late accepted receipt does not alter new turn or draft", engine.isRunning(thread) && model.prompt == "不要清除的新草稿")
        check("old receipt does not resolve successor pending insertion",
              engine.transcript(for: thread).first { $0.id == successorInsertionID }?.status == "steering|等待插話確認")
        model.stop()
        check("steering is disabled immediately after stop request", !engine.canSteer(thread))
        try await until("stop confirmation") { !engine.isRunning(thread) }
        check("confirmed stop does not start another turn", commands().filter { $0["op"] as? String == "send" }.count == 2)
        check("stop leaves no false running state", !model.isRunning)

        check("starts final fixture turn", engine.send(threadID: thread, text: "last", model: "gpt-6-astra", engine: .codex))
        model.prompt = "hold"
        model.send()
        let heldID = lastUser()?.id
        engine.shutdownAll()
        check("shutdown marks unacknowledged insertion unknown",
              engine.transcript(for: thread).first { $0.id == heldID }?.status == "steer_unknown|插話送達狀態待確認")
        check("shutdown preserves the unsent draft", model.prompt == "hold")
        check("shutdown releases execution state and process", !engine.isRunning(thread) && engine.sidecarProcessID(threadID: thread) == nil)
        var document = store.load()
        let interrupted = ChatMessage(role: .user, text: "crash fixture", status: "steering|等待插話確認", turnID: "fixture-old-turn")
        let index = document.threads.firstIndex { $0.id == thread }!
        document.threads[index].messages.append(LiveMessageRecord(interrupted))
        store.save(document)
        let reopened = ChatLiveEngine(store: store, environment: env)
        defer { reopened.shutdownAll() }
        check("relaunch never displays a lost process as still submitting",
              reopened.transcript(for: thread).last?.status == "steer_unknown|插話送達狀態待確認")
        check("relaunch preserves original text and does not replay",
              reopened.transcript(for: thread).last?.text == "crash fixture" &&
              reopened.sidecarProcessID(threadID: thread) == nil && !reopened.canSteer(thread))
        print("CHATSTEERINGTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
