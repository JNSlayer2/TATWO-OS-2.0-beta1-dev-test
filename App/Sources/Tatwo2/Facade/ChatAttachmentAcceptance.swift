import Foundation

/// Persistent transcript -> existing attachment renderer, with a local sidecar
/// fixture. No account, network, model, or production data is used.
@MainActor
enum ChatAttachmentAcceptance {
    static func run() async throws -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only") else { return false }
        let root = URL(fileURLWithPath: path)
        let script = root.appendingPathComponent("attachment-fixture.mjs")
        try #"""
        import fs from 'node:fs';
        import readline from 'node:readline';
        const args = process.argv.slice(2), cwd = args[args.indexOf('--cwd') + 1];
        const rl = readline.createInterface({input:process.stdin});
        rl.on('line', line => {
          const c = JSON.parse(line);
          if(c.op === 'close') process.exit(0);
          if(c.op !== 'send') return;
          fs.appendFileSync(cwd+'/attachment-commands.jsonl',JSON.stringify(c)+'\n');
          console.log(JSON.stringify({ev:'sdk',msg:{type:'result',client_turn_id:c.uuid,
            subtype:'success',is_error:false,result:'fixture received'}}));
        });
        rl.on('close',()=>process.exit(0));
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = prior
        overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("CHATATTACHMENTTEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: env)
        defer { engine.shutdownAll() }
        let project = engine.newProject(name: "attachment-fixture", workdir: path)
        let thread = engine.newThread(in: project)
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let model = ChatPageModel(environment: env,
            botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        model.selectedThreadID = thread
        model.appendDroppedImageData(imageData, suggestedName: "剪貼簿.png")
        guard let pasted = model.droppedPaths.first else {
            check("pasted image enters attachment store", false)
            return false
        }
        check("paste is in persistent live store", pasted.hasPrefix(path + "/live/attachments/"))
        check("paste retains readable display name", URL(fileURLWithPath: pasted).lastPathComponent == "剪貼簿.png")
        check("paste retains original bytes", (try? Data(contentsOf: URL(fileURLWithPath: pasted))) == imageData)
        check("image-only draft is sendable", model.canSend)
        let first = engine.send(threadID: thread, text: "", model: "gpt-6-astra", engine: .codex, attachments: [pasted])
        check("engine accepts image without invented user text", first)
        for _ in 0..<300 {
            if !engine.isRunning(thread) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check("image-only turn finishes", !engine.isRunning(thread))
        let user = engine.transcript(for: thread).first { $0.role == .user }
        check("sent image retains path for preview", user?.inlineAttachments.map(\.path) == [pasted])
        check("user bubble hides attachment transport markup", user?.transcriptDisplayText == "")
        check("image-only chat has a useful title", engine.threadRecord(thread)?.title == "圖片附件 · 剪貼簿.png")
        check("thumbnail classifies the attachment as an image", user?.inlineAttachments.first?.isImage == true)
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env)
        defer { reopened.shutdownAll() }
        let restored = reopened.transcript(for: thread).first { $0.role == .user }
        check("store reload preserves preview metadata", restored?.inlineAttachments == user?.inlineAttachments)
        check("store reload preserves readable image", restored?.inlineAttachments.first?.isMissing == false)
        check("store reload needs no model process", reopened.sidecarProcessID(threadID: thread) == nil)

        let oddName = "中 文 ] \" <tag>.png"
        let odd = try store.saveAttachment(data: imageData, suggestedName: oddName)
        let shown = ChatAttachmentTranscript.displayTurn(text: "請看圖片", attachmentPaths: [odd.path, odd.path])
        let message = ChatMessage(role: .user, text: shown)
        check("marker escaping preserves unusual filenames", message.inlineAttachments.first?.displayName == oddName)
        check("marker escaping preserves exact paths", message.inlineAttachments.first?.path == odd.path)
        check("duplicate previews are not rendered twice", message.inlineAttachments.count == 1)
        check("message text remains unchanged above preview", message.transcriptDisplayText == "請看圖片")
        var edited = ChatMessage(id: "same-message", role: .user, text: "原文")
        _ = edited.inlineAttachments
        edited.text = shown
        check("existing derived cache sees attachment mutation", edited.inlineAttachments == message.inlineAttachments)
        let nested = try store.saveAttachment(data: imageData, suggestedName: "../../安全名稱.png")
        check("supplied name cannot escape its owned directory", nested.path.hasPrefix(path + "/live/attachments/") &&
              nested.lastPathComponent == "安全名稱.png")
        let twice = try store.saveAttachment(data: imageData, suggestedName: oddName)
        check("same filename never overwrites existing attachment", twice != odd && (try? Data(contentsOf: odd)) == imageData)
        let missingPath = root.appendingPathComponent("missing.png").path
        let missing = ChatMessage(role: .user, text: ChatAttachmentTranscript.displayTurn(
            text: "", attachmentPaths: [missingPath]))
        check("missing attachment retains visible error metadata", missing.inlineAttachments.first?.isMissing == true)
        check("plain filename history does not guess local paths",
              ChatMessage(role: .user, text: "舊圖片\n📎 old.png").inlineAttachments.isEmpty)
        check("empty turn without attachments remains rejected",
              !engine.send(threadID: thread, text: "  ", model: nil, engine: .codex))
        let second = engine.send(threadID: thread, text: "請看圖片", model: "gpt-6-astra", engine: .codex, attachments: [odd.path])
        check("text and image send is accepted", second)
        for _ in 0..<300 {
            if !engine.isRunning(thread) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let lines = (try? String(contentsOf: root.appendingPathComponent("attachment-commands.jsonl"), encoding: .utf8))?
            .split(separator: "\n") ?? []
        let commands = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        check("real sidecar receives image-only request", commands.first?["text"] as? String == "" &&
              commands.first?["attachments"] as? [String] == [pasted])
        check("real sidecar receives unchanged user text and image", commands.last?["text"] as? String == "請看圖片" &&
              commands.last?["attachments"] as? [String] == [odd.path] && commands.count == 2)
        check("test sidecar reaches terminal state", !engine.isRunning(thread))
        print("CHATATTACHMENTTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
