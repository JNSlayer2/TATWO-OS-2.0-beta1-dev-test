import Foundation

/// Real composer/store with disposable data. Never sends a model request.
@MainActor
enum DiscussionCommandAcceptance {
    static func run() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only")
        else {
            print("DISCUSSIONCOMMANDTEST FAIL isolated stores required")
            return false
        }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("DISCUSSIONCOMMANDTEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        let root = URL(fileURLWithPath: path)
        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env)
        let project = engine.newProject(name: "discussion-fixture", workdir: path)
        let parent = engine.newThread(in: project, title: "parent")
        engine.setModelPreferences(threadID: parent, model: "gpt-5.6-sol", effort: "high", speedTier: "standard")
        let model = ChatPageModel(environment: env,
                                  botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        model.selectedThreadID = parent
        let initialCount = engine.doc.threads.count
        let attachment = root.appendingPathComponent("unsent.png").path
        model.droppedPaths = [attachment]

        check("Chinese command is suggested",
              ChatComposerSlashCatalog.matches(prompt: "/討").contains(.init(command: "/討論串")))
        check("English alias is not invented",
              !ChatComposerSlashCatalog.commands.contains("/subthread"))
        if let item = ChatPageModel.slashCommandItems.first(where: { $0.cmd == "/討論串" }) {
            model.prompt = "/討"
            model.applySlashCommandSuggestion(item)
            check("suggestion only edits draft", model.prompt == "/討論串 " && engine.doc.threads.count == initialCount)
        } else { check("suggestion exists", false) }

        model.isRunning = true
        for empty in ["/討論串", " \n/討論串 \t\n"] {
            model.prompt = empty
            check("local command is available during work", model.canSend && model.isLocalDiscussionCommand)
            model.send()
            check("empty argument does not create or send", engine.doc.threads.count == initialCount &&
                  engine.transcript(for: parent).isEmpty && model.isRunning)
            check("empty argument preserves draft and attachment", model.prompt == empty && model.droppedPaths == [attachment])
        }
        for nonCommand in ["/討論串別名 主題", "/subthread topic", "先寫文字\n/討論串 主題"] {
            model.prompt = nonCommand
            check("unrelated text is not intercepted", !model.isLocalDiscussionCommand && !model.canSend)
        }
        model.prompt = " \n/討論串\t登入問題\n保留第二行"
        check("diagnostic describes no model start", model.sendAvailabilityDiagnostic == "開啟討論串，不啟動模型")
        model.send()
        let childID = model.selectedThreadID
        guard let childID, childID != parent, let child = engine.threadRecord(childID) else {
            check("opens a real child discussion", false)
            print("DISCUSSIONCOMMANDTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
            return false
        }
        check("one command creates one child", engine.doc.threads.count == initialCount + 1)
        check("child belongs to original parent and project", child.parentThreadID == parent && child.projectID == project)
        check("first line names child", child.title == "登入問題")
        check("body remains editable without command prefix", model.prompt == "登入問題\n保留第二行")
        check("unsent attachment is retained", model.droppedPaths == [attachment])
        check("no chat messages were sent", engine.transcript(for: parent).isEmpty && engine.transcript(for: childID).isEmpty)
        check("no worktree or task was created", child.cwdOverride == nil && child.roomBrief == nil && child.subStatus == nil)
        check("no model process was started", engine.sidecarProcessID(threadID: childID) == nil &&
              engine.sidecarProcessID(threadID: parent) == nil && !engine.isRunning(childID))
        check("child selection reflects its own idle state", model.selectedDiscussionID == childID && !model.isRunning)
        check("explicit native preferences are inherited", child.requestedModel == "gpt-5.6-sol" &&
              child.requestedEffort == "high" && child.requestedSpeedTier == "standard")
        check("visible controls restore child preferences", model.selectedModel == "gpt-5.6-sol" &&
              model.selectedEffort == .high && model.selectedSpeedTier == .standard)
        model.document = engine.document
        check("draft discussion is not mislabelled as a dispatched job", model.dispatchRooms(parent: parent).isEmpty)
        check("no worktree directory was created", !FileManager.default.fileExists(atPath: path + "/.tatwo2/wt"))

        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env)
        let restored = reopened.threadRecord(childID)
        check("discussion survives store reload", restored?.id == childID &&
              restored?.parentThreadID == parent && restored?.projectID == project &&
              restored?.title == child.title && restored?.messages.isEmpty == true &&
              restored?.cwdOverride == nil && restored?.subStatus == nil)
        check("preferences survive store reload", restored?.requestedModel == "gpt-5.6-sol" &&
              restored?.requestedEffort == "high" && restored?.requestedSpeedTier == "standard")
        // ChatLiveStore's existing ISO8601 codec persists whole seconds.
        check("reload retains timestamps at store precision", restored.map {
            (0..<1).contains(child.createdAt.timeIntervalSince($0.createdAt)) &&
            (0..<1).contains(child.updatedAt.timeIntervalSince($0.updatedAt))
        } ?? false)
        check("parent data remains unchanged", reopened.threadRecord(parent)?.title == "parent" &&
              reopened.threadRecord(parent)?.requestedModel == "gpt-5.6-sol")
        engine.markSubStatus(childID, "running")
        model.document = engine.document
        check("stale running record does not claim a live process", model.dispatchRooms(parent: parent).first?.isRunning == false)
        check("stale running record has an honest status", model.dispatchRooms(parent: parent).first?.statusLabel == "狀態待確認" &&
              model.dispatchRooms(parent: parent).first?.needsAttention == true)
        engine.markSubStatus(childID, "failed")
        model.document = engine.document
        check("failed child remains visible for inspection", model.dispatchRooms(parent: parent).first?.liveness == .failed)
        model.selectedThreadID = parent
        let beforeShowCount = engine.doc.threads.count
        let beforeShowTranscript = engine.transcript(for: parent).count
        model.hideDiscussionTray()
        check("hide only changes presentation", model.isDiscussionTrayHidden &&
              !model.dispatchRooms.isEmpty && engine.doc.threads.count == beforeShowCount)
        model.selectedThreadID = childID
        check("another discussion is not hidden", !model.isDiscussionTrayHidden)
        model.selectedThreadID = parent
        check("returning retains hidden presentation", model.isDiscussionTrayHidden)
        model.isRunning = true
        model.droppedPaths = [attachment]
        model.prompt = " \n/顯示討論串 \t"
        check("show command is suggested",
              ChatComposerSlashCatalog.matches(prompt: "/顯示").contains(.init(command: "/顯示討論串")))
        check("show remains available during work", model.canSend && model.isShowDiscussionTrayCommand)
        model.send()
        check("show command restores tray and clears only command",
              !model.isDiscussionTrayHidden && model.prompt.isEmpty && model.droppedPaths == [attachment])
        check("show does not start or stop work",
              model.isRunning && engine.doc.threads.count == beforeShowCount &&
              engine.transcript(for: parent).count == beforeShowTranscript)
        model.prompt = "/顯示討論串別名"
        check("show command matches exactly", !model.isShowDiscussionTrayCommand)
        engine.archive(parent)
        model.prompt = "/討論串 不應建立"
        let count = engine.doc.threads.count
        model.send()
        check("archived parent failure preserves draft", engine.doc.threads.count == count && model.prompt == "/討論串 不應建立")
        print("DISCUSSIONCOMMANDTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
