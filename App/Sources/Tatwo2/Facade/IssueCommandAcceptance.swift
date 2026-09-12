import Foundation

/// Exercises the real composer and store, with no model, sockets or production document.
enum IssueCommandAcceptance {
    @MainActor static func run() -> Bool {
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1 }
            print("ISSUECOMMANDTEST \(condition ? "PASS" : "FAIL") \(name)")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["TATWO2_ISSUE_TEST_ROOT"] else {
            print("ISSUECOMMANDTEST FAIL isolated root required")
            return false
        }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-only").path),
              environment["TATWO2_LIVE_ROOT"] == root.appendingPathComponent("live").path,
              environment["TATWO2_ENGINES_ROOT"] == root.appendingPathComponent("engines").path else {
            print("ISSUECOMMANDTEST FAIL fixture marker and isolated stores required")
            return false
        }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: environment)
        let project = engine.newProject(name: "issue-fixture", workdir: root.path)
        let thread = engine.newThread(in: project)
        let bots = BotStore(root: root.appendingPathComponent("live"))
        let model = ChatPageModel(environment: environment, botCoreFixture: (engine, bots))
        model.selectedThreadID = thread
        model.isRunning = true
        let imageURL = root.appendingPathComponent("截圖 測試.png")
        let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        do { try imageData.write(to: imageURL) }
        catch { check("fixture image written", false); return false }
        model.droppedPaths = [imageURL.path, imageURL.path]
        let transcriptBefore = engine.transcript(for: thread).count
        let originalCount = engine.issues(threadID: thread, global: false).count

        model.prompt = "/issue 測試標題\n第一行內容\n第二行內容"
        check("issue remains sendable during a model turn", model.canSend)
        check("issue diagnostic describes local submission", model.sendAvailabilityDiagnostic == "記錄問題，不中斷目前工作")
        model.send()
        var issues = engine.issues(threadID: thread, global: false)
        check("one submission writes exactly one issue", issues.count == originalCount + 1)
        check("title and multiline body preserved", issues.first?.title == "測試標題" && issues.first?.body == "第一行內容\n第二行內容")
        check("does not finish or interrupt the active model turn", model.isRunning)
        check("submitted images leave composer only after persistence", model.droppedPaths.isEmpty)
        let firstIssue = issues.first!
        check("image is stored once beside text", firstIssue.imageAssetPaths.count == 1)
        check("preview resolves persistent image bytes", model.issueImageURLs(for: firstIssue).first.flatMap { try? Data(contentsOf: $0) } == imageData)
        check("body is not polluted by file paths", !firstIssue.body.contains(root.path))
        check("does not send a chat message", engine.transcript(for: thread).count == transcriptBefore)
        check("submitted command is cleared", model.prompt.isEmpty)

        model.prompt = "/issue 測試標題\n不同內容"
        model.send()
        issues = engine.issues(threadID: thread, global: false)
        check("intentional same-title submissions remain separate", issues.count == originalCount + 2)
        model.prompt = " \n/issue\tTab 分隔\n內文"
        check("whitespace command delimiter is accepted", model.canSend)
        model.send()
        issues = engine.issues(threadID: thread, global: false)
        check("tab command also writes once", issues.count == originalCount + 3)
        model.prompt = "/issue"
        model.droppedPaths = [imageURL.path]
        model.send()
        check("empty command does not create an issue", engine.issues(threadID: thread, global: false).count == issues.count)
        check("empty command stays available for editing", model.prompt == "/issue")
        model.prompt = "/issue   \n\t"
        model.send()
        check("whitespace-only body does not create an issue", engine.issues(threadID: thread, global: false).count == issues.count)
        check("empty issue preserves the original draft and attachments", model.prompt == "/issue   \n\t" && model.droppedPaths.count == 1)
        for text in ["普通訊息", "/issues 不是指令", "/issue-other"] {
            model.prompt = text
            check("does not unlock unrelated commands: \(text)", !model.canSend && !model.isLocalIssueCommand)
        }
        model.isRunning = false
        model.prompt = "普通訊息"
        check("normal idle submission remains enabled", model.canSend)
        check("idle diagnostic is accurate", model.sendAvailabilityDiagnostic == "可送出")
        model.prompt = ""
        model.droppedPaths = []
        check("empty diagnostic requests content", model.sendAvailabilityDiagnostic == "請輸入內容")
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment)
        check("exact count survives store reload", reopened.issues(threadID: thread, global: false).count == originalCount + 3)
        check("image metadata survives reload", reopened.issues(threadID: thread, global: false).first(where: { $0.id == firstIssue.id })?.imageAssetPaths == firstIssue.imageAssetPaths)
        model.prompt = "既有草稿"
        model.packIssueIntoComposer(firstIssue)
        check("pack brings image and text without sending", model.prompt.contains(firstIssue.body) &&
              model.droppedPaths.count == 1 && engine.transcript(for: thread).count == transcriptBefore)
        model.packIssueIntoComposer(firstIssue)
        check("pack does not duplicate image attachments", model.droppedPaths.count == 1)
        check("asset traversal is rejected", model.issueImageURL(relativeAssetPath: "../document.json") == nil)

        model.prompt = "/issue 失敗重試"
        model.droppedPaths = [root.appendingPathComponent("missing.png").path]
        model.send()
        check("missing image preserves draft and creates no issue",
              model.prompt == "/issue 失敗重試" && model.droppedPaths.count == 1 &&
              engine.issues(threadID: thread, global: false).count == originalCount + 3)
        model.droppedPaths = [imageURL.path]
        let liveRoot = root.appendingPathComponent("live")
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: liveRoot.path)
            let permissions = attributes[.posixPermissions]!
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: liveRoot.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: liveRoot.path) }
            model.send()
            check("store write failure preserves draft and in-memory issue count",
                  model.prompt == "/issue 失敗重試" && model.droppedPaths == [imageURL.path] &&
                  engine.issues(threadID: thread, global: false).count == originalCount + 3)
        } catch { check("fixture write-failure setup", false) }
        model.send()
        check("retry creates exactly one complete issue", model.prompt.isEmpty && model.droppedPaths.isEmpty &&
              engine.issues(threadID: thread, global: false).count == originalCount + 4)
        check("retry reuses staged image", (try? FileManager.default.contentsOfDirectory(atPath: model.issueImageRoot.path).count) == 1)
        if let image = firstIssue.imageAssetPaths.first {
            model.prompt = ""
            model.packIssueIntoComposer(firstIssue)
            let packed = model.droppedPaths.first
            model.removeIssueImageNote(image, from: firstIssue)
            check("removing one reference preserves another issue image",
                  engine.issues(threadID: thread, global: false).contains {
                      $0.id != firstIssue.id && $0.imageAssetPaths.contains(image)
                  } && model.issueImageURL(relativeAssetPath: image) != nil)
            check("removing reference preserves packed draft bytes",
                  packed.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) } == imageData)
        }
        engine.addIssue(threadID: thread, title: "legacy-image", body: "保留說明\n\(imageURL.path)")
        if let old = engine.issues(threadID: thread, global: false).first(where: { $0.title == "legacy-image" }) {
            model.importLegacyIssueImages(old)
            let migrated = engine.issues(threadID: thread, global: false).first(where: { $0.id == old.id })
            check("legacy screenshot becomes preview without losing prose",
                  migrated?.body == "保留說明" && migrated?.imageAssetPaths.count == 1)
            check("missing legacy source remains recoverable text",
                  IssueImageAssets.extractingLegacyImages(from: "/tmp/not-a-real-issue-image.png").text == "/tmp/not-a-real-issue-image.png")
        } else { check("legacy fixture created", false) }
        check("no native engine was started", !engine.isRunning(thread))
        print("ISSUECOMMANDTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
