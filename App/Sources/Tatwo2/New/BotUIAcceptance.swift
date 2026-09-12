import Foundation
import AppKit
import SwiftUI

enum BotUIAcceptance {
    static func check(_ name: String, _ value: Bool) throws {
        print("BOTUITEST \(value ? "PASS" : "FAIL") \(name)")
        if !value { throw BotLibraryError.invalid(name) }
    }

    static func run() async throws {
        guard let path = ProcessInfo.processInfo.environment["TATWO2_BOTUI_ROOT"],
              let socket = ProcessInfo.processInfo.environment["TATWO2_BROWSER_SOCKET"],
              socket.hasPrefix("/tmp/"), path.hasPrefix("/tmp/"),
              ProcessInfo.processInfo.environment["TATWO2_LIVE_ROOT"] == path,
              !FileManager.default.fileExists(atPath: path) else {
            throw BotLibraryError.invalid("new_isolated_root_and_browser_socket_required")
        }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("echo.mjs")
        try #"""
        import readline from 'node:readline';
        const emit = x => console.log(JSON.stringify(x));
        readline.createInterface({input:process.stdin}).on('line', l => {
          const c = JSON.parse(l);
          if(c.op === 'send') {
            emit({ev:'sdk',msg:{type:'system',subtype:'init',session_id:'bot-ui-echo'}});
            emit({ev:'sdk',msg:{type:'stream_event',event:{type:'content_block_delta',delta:{type:'text_delta',text:'bot-ui echo complete'}}}});
            emit({ev:'sdk',msg:{type:'result',subtype:'success',result:'bot-ui echo complete'}});
          } else if(c.op === 'close') process.exit(0);
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = previous
        overrides["tatwo2.sidecarPath.claude"] = script.path
        overrides["tatwo2.sidecarPath.codex"] = script.path
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let store = BotStore(root: root)
        await store.library.ready()
        for id in ["one", "two"] {
            _ = try await store.library.create(.init(id: id, name: "UI " + id, emoji: "🤖",
                role: "general", engine: "claude", workdir: root.path,
                permissions: .init(approval: "ask", mcp: [], folders: [root.path], network: false)), instructions: "Echo fixture only")
            try await BotMemory(library: store.library).updateState(botID: id,
                patch: .init(currentTask: "task-" + id))
        }
        let liveStore = ChatLiveStore(root: root)
        let project = LiveProjectRecord(name: "UI fixture", workdir: root.path)
        let thread = LiveThreadRecord(projectID: project.id)
        liveStore.save(.init(projects: [project], threads: [thread], selectedThreadID: thread.id))
        let (model, live, page) = await MainActor.run {
            let live = ChatLiveEngine(store: liveStore)
            let model = ChatPageModel(environment: ["TATWO2_LIVE_ROOT": root.path], botCoreFixture: (live, store))
            live.onChange = { [weak model, weak live] in
                if let live { model?.document = live.document }
            }
            CLISessionsTermination.model = model
            return (model, live, BotPageState(sceneID: "rail-tree"))
        }
        do {
            try await MainActor.run {
                let ids = page.mainListEntries.flatMap { entry -> [String] in
                    if case .principal(let p) = entry { return p.subs.map(\.id) }; return []
                }
                try check("library_list_two_bots", Set(ids) == ["one", "two"] && page.tempBots.isEmpty)
                page.selectSub("one", of: "ui-ungrouped")
                try check("unbound_empty", page.currentThread.isEmpty)
                try check("composer_empty_no_send_no_hint", !page.sendComposer("  \n") && model.composerHint == nil)
                try check("composer_send", page.sendComposer("hello bot one"))
                try check("bound_user_row", page.currentThread.contains { $0.author == .user && $0.text == "hello bot one" })
            }
            for _ in 0..<200 {
                if store.library.snapshot.states["one"]?.lastSessionAt != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let sessions = try JSONDecoder().decode([BotSessionRecord].self,
                from: Data(contentsOf: root.appendingPathComponent("bots/one/sessions.json")))
            let state = try JSONDecoder().decode(BotMemoryState.self,
                from: Data(contentsOf: root.appendingPathComponent("bots/one/memory/state.json")))
            try check("sessions_state_disk_updated", sessions.count == 1
                && state.lastThreadID == sessions.last?.threadID && state.lastSessionAt != nil
                && state.lastSessionAt == sessions.last?.lastActiveAt)
            try await MainActor.run {
                try check("assistant_transcript", page.currentThread.contains { $0.text.contains("bot-ui echo complete") })
                try check("resume_note_one", page.liveNoteRevision.contains("task-one"))
                page.selectSub("two", of: "ui-ungrouped")
                try check("selection_isolation", page.currentThread.isEmpty
                    && page.liveNoteRevision.contains("task-two") && !page.liveNoteRevision.contains("task-one"))
                let count = live.doc.threads.count
                try check("fixture_item_rejected", !page.sendComposer("do not send", botID: "fixture-bot-tattoo-po")
                    && model.composerHint == "這是展示資料，先 create bot" && live.doc.threads.count == count)
                page.createBot()
            }
            for _ in 0..<100 {
                if store.library.snapshot.bots.count == 3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check("create_bot_library", store.library.snapshot.bots.count == 3
                && store.library.snapshot.bots.last?.engine == "codex"
                && store.library.snapshot.bots.last?.workdir == root.path)
            var grouped = store.library.snapshot
            grouped.bots[1].parentBotID = "one"
            grouped.bots[1].spaceIDs = ["space-a"]
            grouped.spaces = [.init(id: "space-a", name: "A", density: "compact", ownerBotID: "one")]
            let projection = await MainActor.run { BotUIWire.project(grouped) }
            try check("parent_and_space_projection",
                projection.principals.first { $0.id == "one" }?.subs.contains { $0.id == "two" } == true
                && projection.principals.first { $0.id == "ui-space:space-a" }?.subs.contains { $0.id == "two" } == true)
            try await MainActor.run {
                // Island 冷導航：Bot 分頁未建立時點卡 → 暫存目標，分頁建立後選中。
                IslandExceptionsNavigation.botPage = nil
                IslandExceptionsNavigation.pendingBotID = nil
                let coldTarget = IslandWorkSnapshot.Target(threadID: nil, botID: "two", jobID: nil)
                try check("island_cold_can_open", IslandExceptionsNavigation.canOpen(coldTarget)
                    && !IslandExceptionsNavigation.canOpen(.init(threadID: nil, botID: "no-such-bot", jobID: nil)))
                IslandExceptionsNavigation.open(coldTarget)
                try check("island_cold_open_pending", IslandExceptionsNavigation.pendingBotID == "two" && model.mode == .bot)
                let coldPage = BotPageState(sceneID: "rail-tree")
                try check("island_cold_open_consumed", IslandExceptionsNavigation.pendingBotID == nil
                    && coldPage.selectedSubID == "two" && IslandExceptionsNavigation.botPage === coldPage)
                // Enter 送出：隔離重現（ComposerNSTextView 直接吃 keyDown，不經視窗／IME）。
                let textView = ChatComposerTextView.ComposerNSTextView()
                var submitted = 0
                textView.onSubmit = { submitted += 1 }
                textView.string = "enter should send"
                func returnKey(shift: Bool) -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: false, keyCode: 36)!
                }
                textView.keyDown(with: returnKey(shift: false))
                try check("composer_enter_submits", submitted == 1)
                textView.keyDown(with: returnKey(shift: true))
                try check("composer_shift_enter_no_submit", submitted == 1)
                textView.setMarkedText("ㄅ", selectedRange: NSRange(location: 0, length: 1),
                    replacementRange: NSRange(location: NSNotFound, length: 0))
                let markedBefore = textView.hasMarkedText()
                textView.keyDown(with: returnKey(shift: false))
                try check("composer_enter_ime_marked_no_submit", markedBefore && submitted == 1)
                // 匯出偏好隔離：被污染的網域在 shield 後讀回出廠值，且不寫任何檔。
                let suite = "tatwo2.botuitest.shield.\(getpid())"
                let polluted = UserDefaults(suiteName: suite)!
                polluted.set(true, forKey: "tatwo.sidebar.pinned")
                polluted.set(3, forKey: "tatwo2.note.stage")
                ExportPrefsShield.apply(to: polluted)
                let shielded = polluted.bool(forKey: "tatwo.sidebar.pinned") == false
                    && polluted.integer(forKey: "tatwo2.note.stage") == 1
                    && polluted.persistentDomain(forName: suite)?["tatwo.sidebar.pinned"] as? Bool == true
                polluted.removePersistentDomain(forName: suite)
                try check("export_prefs_shield", shielded && !ExportPrefsShield.isExportProcess([:])
                    && ExportPrefsShield.isExportProcess(["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT": "/tmp/x.png"]))
                setenv("TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT", "/tmp/bot-ui-test-only.png", 1)
                defer { unsetenv("TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT") }
                let scenes = ["rail-tree", "rail-collapsed", "rail-empty", "thread", "group-sandbox",
                    "space-full", "space-compact", "space-status", "add-space", "quick-card", "settings-9row", "stress"]
                for scene in scenes {
                    let fixture = BotPageState(sceneID: scene)
                    try check("export_fixture_" + scene, !fixture.usesLiveBots && !fixture.unknownScene
                        && fixture.fixture.principals == BotPageFixture.scene(scene)?.principals
                        && !fixture.sendComposer("never send"))
                }
                // 真正掛載原 Bot View 的匯出 fixture，沿 AX children 查詢，不用手造控制項。
                let axWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                        styleMask: [.titled], backing: .buffered, defer: false)
                axWindow.isReleasedWhenClosed = false
                axWindow.contentView = NSHostingView(rootView: BotPageRootView.forScene("thread"))
                axWindow.orderFrontRegardless()
                defer { axWindow.close() }
                axWindow.contentView?.layoutSubtreeIfNeeded()
                axWindow.displayIfNeeded()
                var axNodes = 0
                var axTextFields = Set<String>()
                func composerAX(_ root: Any, identifier: Bool, depth: Int = 0) -> Bool {
                    guard depth < 80, let element = root as? NSObject else { return false }
                    axNodes += 1
                    // SwiftUI AX 節點不一定宣告完整 NSAccessibilityProtocol；
                    // 直接查同一套 ObjC AX selectors，仍只走 accessibilityChildren。
                    func attribute(_ name: String) -> Any? {
                        let selector = NSSelectorFromString(name)
                        let modern = element.responds(to: selector)
                            ? element.perform(selector)?.takeUnretainedValue() : nil
                        if let modern, (modern as? [Any])?.isEmpty != true { return modern }
                        // NSHostingView／SwiftUI 虛擬節點亦可能只供應舊式 AX attribute API。
                        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
                        let keys = ["accessibilityLabel": "AXDescription", "accessibilityIdentifier": "AXIdentifier",
                                    "accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole"]
                        guard element.responds(to: legacy), let key = keys[name] else { return modern }
                        return element.perform(legacy, with: key)?.takeUnretainedValue() ?? modern
                    }
                    let role = attribute("accessibilityRole") as? String ?? ""
                    if role == "AXTextArea" || role == "AXTextField" {
                        axTextFields.insert("\(role) label=\(attribute("accessibilityLabel") as? String ?? "<nil>") id=\(attribute("accessibilityIdentifier") as? String ?? "<nil>")")
                    }
                    if attribute("accessibilityLabel") as? String == "Bot message",
                       !identifier || attribute("accessibilityIdentifier") as? String == "bot-composer" { return true }
                    return (attribute("accessibilityChildren") as? [Any] ?? []).contains {
                        composerAX($0, identifier: identifier, depth: depth + 1)
                    }
                }
                var identified = false
                var labelled = false
                for _ in 0..<40 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    identified = composerAX(axWindow, identifier: true)
                        || axWindow.contentView.map { composerAX($0, identifier: true) } == true
                    labelled = composerAX(axWindow, identifier: false)
                        || axWindow.contentView.map { composerAX($0, identifier: false) } == true
                    if identified { break }
                }
                print("BOTUITEST NOTE fixture AX nodes visited (including repeated polls): \(axNodes); text fields: \(axTextFields.sorted())")
                if let view = axWindow.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("composer-ax.png"))
                }
                if !identified {
                    print("BOTUITEST NOTE bot-composer identifier not found in fixture AX tree; fallback to label Bot message")
                }
                try check("fixture_composer_accessibility_" + (identified ? "identifier_and_label" : "label_fallback"),
                          identified || labelled)
            }
            await MainActor.run { live.shutdownAll(); CLISessionsTermination.model = nil }
            print("BOTUITEST PASS — 0 LLM calls")
        } catch {
            await MainActor.run { live.shutdownAll(); CLISessionsTermination.model = nil }
            throw error
        }
    }
}
