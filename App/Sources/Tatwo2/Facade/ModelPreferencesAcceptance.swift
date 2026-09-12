import Foundation

/// Real thread-store and ChatPageModel hydration without launching an engine.
enum ModelPreferencesAcceptance {
    @MainActor static func run() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TATWO2_ISSUE_TEST_ROOT"] else { return false }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-only").path),
              environment["TATWO2_LIVE_ROOT"] == root.appendingPathComponent("live").path,
              environment["TATWO2_ENGINES_ROOT"] == root.appendingPathComponent("engines").path else { return false }
        var passed = 0
        var failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1 }
            print("MODELPREFERENCESTEST \(condition ? "PASS" : "FAIL") \(name)")
        }
        let store = ChatLiveStore(root: root.appendingPathComponent("live"))
        let engine = ChatLiveEngine(store: store, environment: environment)
        let project = engine.newProject(name: "model-fixture", workdir: root.path)
        let first = engine.newThread(in: project)
        let model = ChatPageModel(environment: environment,
                                  botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        check("new chat uses GPT-6", model.selectedModel == "gpt-6-astra")
        check("new chat uses medium reasoning", model.selectedEffort == .medium)
        check("new chat uses Fast", model.selectedSpeedTier == .fast)
        check("hydration does not write defaults into old records", engine.threadRecord(first)?.requestedModel == nil)
        model.setSingleModel("gpt-5.6-sol")
        model.selectedEffort = .high
        model.selectedSpeedTier = .standard
        check("explicit model is stored before sending", engine.threadRecord(first)?.requestedModel == "gpt-5.6-sol")
        check("explicit effort is stored", engine.threadRecord(first)?.requestedEffort == "high")
        check("explicit speed is stored", engine.threadRecord(first)?.requestedSpeedTier == "standard")
        let second = engine.newThread(in: project)
        model.selectedThreadID = second
        check("new chat does not inherit another chat's model", model.selectedModel == "gpt-6-astra")
        check("new chat resets to medium Fast", model.selectedEffort == .medium && model.selectedSpeedTier == .fast)
        model.selectedThreadID = first
        check("switching back restores explicit selection", model.selectedModel == "gpt-5.6-sol" && model.selectedEffort == .high && model.selectedSpeedTier == .standard)
        let reopened = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: environment)
        let restarted = ChatPageModel(environment: environment,
                                      botCoreFixture: (reopened, BotStore(root: root.appendingPathComponent("live"))))
        check("restart restores explicit selection", restarted.selectedModel == "gpt-5.6-sol" && restarted.selectedEffort == .high && restarted.selectedSpeedTier == .standard)
        restarted.selectedThreadID = second
        check("restart keeps untouched new-chat defaults", restarted.selectedModel == "gpt-6-astra" && restarted.selectedEffort == .medium && restarted.selectedSpeedTier == .fast)
        check("Fast uses native catalog ID", TatwoModelSpeedTier.fast.appServerValue == "priority")
        check("standard explicitly resets native Fast", TatwoModelSpeedTier.standard.appServerValue == "default")
        check("CLI speed mapping remains unchanged", TatwoModelSpeedTier.fast.codexArguments == ["-c", "service_tier=\"fast\""] && TatwoModelSpeedTier.standard.codexArguments.isEmpty)
        let old = Data("{\"title\":\"legacy\",\"requestedModel\":\"gpt-5.6-sol\"}".utf8)
        let decoded = try? JSONDecoder().decode(LiveThreadRecord.self, from: old)
        check("legacy documents retain explicit model", decoded?.requestedModel == "gpt-5.6-sol")
        check("legacy documents tolerate missing effort and speed", decoded != nil && decoded?.requestedEffort == nil && decoded?.requestedSpeedTier == nil)
        let command = ClaudeSidecar.sendCommand(kind: .codex, text: "fixture", uuid: "one", attachments: [],
                                               model: "gpt-6-astra", reasoningEffort: "medium",
                                               serviceTier: TatwoModelSpeedTier.fast.appServerValue)
        check("Swift command carries requested model and effort", command["model"] as? String == "gpt-6-astra" && command["effort"] as? String == "medium")
        check("Swift command carries native speed ID", command["serviceTier"] as? String == "priority")
        for kind in [ClaudeSidecar.Kind.claude, .grok] {
            let command = ClaudeSidecar.sendCommand(kind: kind, text: "fixture", uuid: "one", attachments: [],
                                                   model: "fixture", reasoningEffort: "medium", serviceTier: "priority")
            check("OpenAI controls are not forwarded to \(kind.rawValue)", command["effort"] == nil && command["serviceTier"] == nil && command["model"] == nil)
        }
        check("unknown thread cannot accept a send", !engine.send(threadID: UUID(), text: "fixture", model: "gpt-6-astra", engine: .codex))
        check("acceptance never starts a model", engine.sidecarProcessID(threadID: first) == nil && reopened.sidecarProcessID(threadID: first) == nil)
        print("MODELPREFERENCESTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
