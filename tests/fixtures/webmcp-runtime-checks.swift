@main struct WebMCPChecks {
    static func json(_ value: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    static func snapshot(origin: String = "https://example.com", generation: UInt64 = 1,
                         name: String = "get_note", description: String = "Read note",
                         schema: String = #"{"type":"object"}"#) -> String {
        json(["schema": "TatwoCEFWebMCPToolsSnapshotV1", "origin": origin,
              "navigationGeneration": generation, "futureField": "ignored",
              "tools": [["name": name, "description": description, "inputSchemaJSON": schema,
                         "origin": origin, "navigationGeneration": generation, "contextID": "context-1",
                         "futureToolField": true]]])
    }
    static func expectError(_ code: String? = nil, _ body: () throws -> Void) {
        do { try body(); fatalError("expected error \(code ?? "")") }
        catch let error as WebMCPFailure { precondition(code == nil || error.code == code, error.code) }
        catch { fatalError("unexpected \(error)") }
    }
    @MainActor static func expectAsync(_ code: String, _ body: () async throws -> String) async {
        do { _ = try await body(); fatalError("expected \(code)") }
        catch let error as WebMCPFailure { precondition(error.code == code, "\(error.code) != \(code)") }
        catch { fatalError("unexpected \(error)") }
    }
    @MainActor static func main() async throws {
        try FixtureBridge().checkTargets()
        typealias P = TatwoPermissionPreset
        typealias E = EmbeddedBrowserSiteToolEffect
        typealias D = WebMCPInvocationPolicy.Decision
        let presets: [P?] = [.askFirst, .approveForMe, .fullAccess, .configFile, nil]
        let effects: [E] = [.readOnly, .sideEffect, .highRisk]
        for preset in presets { for effect in effects { for readOnly in [false, true] {
            let expected: D = readOnly ? (effect == .readOnly ? .allow : .reject)
                : preset == .fullAccess ? .allow
                : preset == .approveForMe && effect == .readOnly ? .allow : .confirm
            precondition(WebMCPInvocationPolicy.decision(effect: effect, preset: preset, readOnlyCaller: readOnly) == expected)
        } } }
        let classifications: [(String, String, [String: Any], E)] = [
            ("get_note", "", [:], .readOnly), ("listNotes", "", [:], .readOnly),
            ("search", "", [:], .readOnly), ("read-note", "", [:], .readOnly),
            ("ready", "", [:], .sideEffect), ("getter", "", [:], .sideEffect),
            ("set_note", "", [:], .sideEffect), ("inspect", "readOnlyHint: true", [:], .readOnly),
            ("inspect", #""readOnlyHint": true"#, [:], .readOnly),
            ("inspect", "", ["readOnlyHint": true], .readOnly),
            ("inspect", "", ["annotations": ["readOnlyHint": true]], .readOnly),
            ("inspect", "", ["readOnlyHint": "true"], .sideEffect),
            ("inspect", "", ["readOnlyHint": 1], .sideEffect),
            ("delete_note", "", ["readOnlyHint": true], .highRisk),
            ("get_note", "send a message", [:], .highRisk),
            ("get_note", "pay for a note", [:], .highRisk),
            ("inspect", "destructiveHint: true", [:], .highRisk),
            ("get_note", "", ["annotations": ["destructiveHint": true]], .highRisk),
            ("get_note", "display", [:], .readOnly),
        ]
        for (name, description, schema, expected) in classifications {
            precondition(WebMCPTool.classify(name: name, description: description, schema: schema) == expected, name)
        }
        let parsed = try WebMCPPageTools.parse(snapshot())
        precondition(parsed.origin == "https://example.com" && parsed.navigationGeneration == 1 && parsed.tools.count == 1)
        precondition(parsed.tools[0].effect == .readOnly)
        _ = try WebMCPPageTools.parse(snapshot(name: String(repeating: "a", count: 128),
                                              description: String(repeating: "a", count: 8192)))
        expectError("tool_too_large") { _ = try WebMCPPageTools.parse(snapshot(name: String(repeating: "界", count: 43))) }
        expectError("tool_too_large") { _ = try WebMCPPageTools.parse(snapshot(description: String(repeating: "a", count: 8193))) }
        let exactSchema = json(["x": String(repeating: "a", count: 65528)])
        precondition(exactSchema.utf8.count == 65536)
        _ = try WebMCPPageTools.parse(snapshot(schema: exactSchema))
        expectError("payload_too_large") { _ = try WebMCPPageTools.parse(snapshot(schema: json(["x": String(repeating: "a", count: 65529)]))) }
        expectError("payload_too_large") { _ = try WebMCPPageTools.parse(String(repeating: " ", count: 1048577)) }
        expectError("invalid_json") { _ = try WebMCPPageTools.parse(snapshot(schema: "[]")) }
        let deepSchema = String(repeating: #"{"x":"#, count: 17) + "0" + String(repeating: "}", count: 17)
        expectError("json_limit_exceeded") { _ = try WebMCPPageTools.parse(snapshot(schema: deepSchema)) }
        var raw = try JSONSerialization.jsonObject(with: Data(snapshot().utf8)) as! [String: Any]
        for value: Any in [true, 0, -1, 1.5, "1"] {
            raw["navigationGeneration"] = value
            expectError("invalid_snapshot") { _ = try WebMCPPageTools.parse(json(raw)) }
        }
        raw["navigationGeneration"] = 1
        raw["tools"] = Array(repeating: (raw["tools"] as! [[String: Any]])[0], count: 129)
        expectError("too_many_tools") { _ = try WebMCPPageTools.parse(json(raw)) }
        raw["tools"] = Array((raw["tools"] as! [[String: Any]]).prefix(2))
        expectError("invalid_tool") { _ = try WebMCPPageTools.parse(json(raw)) }
        raw = try JSONSerialization.jsonObject(with: Data(snapshot().utf8)) as! [String: Any]
        raw["origin"] = "https://other.example"
        expectError("stale_page") { _ = try WebMCPPageTools.parse(json(raw)) }

        var prompts = 0, invoked = 0
        var audit: [String] = [], logs: [String] = []
        let runtime = TatwoWebMCPRuntime(confirm: { title, detail in
            precondition((title == "網頁想執行工具" || title == "網頁想讀取資料") && title.count <= 14 && !title.contains("\n") && !detail.contains("\n") && detail.contains("・"))
            prompts += 1; return true
        }, audit: { audit.append($0) }, log: { logs.append($0) })
        let ask = WebMCPCaller(id: "fixture-caller", session: "session", preset: .askFirst, readOnly: false)
        let full = WebMCPCaller(id: "fixture-caller", session: "session", preset: .fullAccess, readOnly: false)
        let auto = WebMCPCaller(id: "fixture-caller", session: "session", preset: .approveForMe, readOnly: false)
        let readOnly = WebMCPCaller(id: "fixture-caller", session: "session", preset: .fullAccess, readOnly: true)
        let sentinel = "NEVER_AUDIT_ARGUMENT_OR_RESULT"
        let arguments = json(["note": sentinel])
        let invoker: TatwoWebMCPRuntime.MainActorInvoker = { name, args, generation, completion in
            precondition(generation == 1 && args == arguments)
            invoked += 1
            completion(#"{"note":"NEVER_AUDIT_ARGUMENT_OR_RESULT"}"#, nil)
            completion(nil, "duplicate ignored")
        }
        runtime.attach(tabID: "a", invoker: invoker)
        runtime.activate(tabID: "a")
        precondition(runtime.activeTabID == "a")
        runtime.update(tabID: "a", snapshotJSONString: snapshot())
        for _ in 0..<2 { _ = try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: ask) }
        precondition(prompts == 1 && invoked == 2)
        _ = try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: auto)
        _ = try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: readOnly)
        precondition(prompts == 1)
        runtime.attach(tabID: "b", invoker: invoker)
        runtime.update(tabID: "b", snapshotJSONString: snapshot())
        _ = try await runtime.invoke(tabID: "b", tool: "get_note", argumentsJSON: arguments, caller: ask)
        precondition(prompts == 2)
        let newSession = WebMCPCaller(id: ask.id, session: "second", preset: .askFirst, readOnly: false)
        _ = try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: newSession)
        precondition(prompts == 3)
        runtime.update(tabID: "a", snapshotJSONString: snapshot(origin: "https://example.org"))
        _ = try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: ask)
        precondition(prompts == 4)
        runtime.update(tabID: "a", snapshotJSONString: snapshot(name: "set_note"))
        for _ in 0..<2 { _ = try await runtime.invoke(tabID: "a", tool: "set_note", argumentsJSON: arguments, caller: auto) }
        precondition(prompts == 6)
        _ = try await runtime.invoke(tabID: "a", tool: "set_note", argumentsJSON: arguments, caller: full)
        await expectAsync("policy_rejected") {
            try await runtime.invoke(tabID: "a", tool: "set_note", argumentsJSON: arguments, caller: readOnly)
        }
        precondition(prompts == 6)
        runtime.update(tabID: "a", snapshotJSONString: snapshot(origin: "http://127.0.0.1"))
        await expectAsync("origin_rejected") {
            try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        runtime.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("invalid_json") {
            try await runtime.invoke(tabID: "a", tool: "get_note", argumentsJSON: "[]", caller: full)
        }
        runtime.update(tabID: "a", snapshotJSONString: String(repeating: "a", count: 1048577))
        precondition(runtime.pageTools(tabID: "a") == nil && logs == ["snapshot_rejected:payload_too_large"])
        runtime.update(tabID: "a", snapshotJSONString: snapshot(generation: 2))
        runtime.update(tabID: "a", snapshotJSONString: snapshot(generation: 1))
        precondition(runtime.pageTools(tabID: "a") == nil)

        var stale: TatwoWebMCPRuntime!
        stale = TatwoWebMCPRuntime(confirm: { _, _ in
            stale.update(tabID: "a", snapshotJSONString: snapshot(generation: 2))
            return true
        }, audit: { audit.append($0) })
        stale.attach(tabID: "a") { _, _, _, _ in fatalError("stale confirmation dispatched") }
        stale.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("stale_page") {
            try await stale.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: ask)
        }
        let inFlight = TatwoWebMCPRuntime(audit: { audit.append($0) })
        inFlight.attach(tabID: "a") { _, _, generation, completion in
            precondition(generation == 1)
            inFlight.update(tabID: "a", snapshotJSONString: snapshot(generation: 2))
            completion("{}", nil)
        }
        inFlight.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("stale_page") {
            try await inFlight.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        let detached = TatwoWebMCPRuntime(audit: { audit.append($0) })
        detached.attach(tabID: "a") { _, _, _, completion in detached.detach(tabID: "a"); completion("{}", nil) }
        detached.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("stale_page") {
            try await detached.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        let denied = TatwoWebMCPRuntime(confirm: { _, _ in false }, audit: { audit.append($0) })
        denied.attach(tabID: "a") { _, _, _, _ in fatalError("denied dispatch") }
        denied.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("user_denied") {
            try await denied.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: ask)
        }
        let timeout = TatwoWebMCPRuntime(audit: { audit.append($0) }, invocationTimeout: 0.05)
        timeout.attach(tabID: "a") { _, _, _, _ in }
        timeout.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("invocation_timeout") {
            try await timeout.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        let cancelled = Task { @MainActor in
            try await timeout.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        cancelled.cancel()
        await expectAsync("cancelled") { try await cancelled.value }
        var current = true
        let stopped = TatwoWebMCPRuntime(confirm: { _, _ in current = false; return true }, audit: { audit.append($0) })
        stopped.attach(tabID: "a") { _, _, _, _ in fatalError("revoked caller dispatched") }
        stopped.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("caller_changed") {
            try await stopped.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: ask, contextIsCurrent: { current })
        }
        let reflected = TatwoWebMCPRuntime(audit: { audit.append($0) })
        reflected.attach(tabID: "a") { _, _, _, completion in completion(nil, sentinel) }
        reflected.update(tabID: "a", snapshotJSONString: snapshot())
        await expectAsync("execution_failed") {
            try await reflected.invoke(tabID: "a", tool: "get_note", argumentsJSON: arguments, caller: full)
        }
        precondition(audit.count == 21, "audit count \(audit.count)")
        for line in audit {
            precondition(!line.contains(sentinel) && !line.contains("\n"))
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            precondition(Set(value.keys) == ["time", "caller", "origin", "tool", "decision", "outcome", "error"])
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("audit-\(UUID()).log")
        try TatwoWebMCPRuntime.appendAudit(audit[0], to: file)
        try TatwoWebMCPRuntime.appendAudit(audit[1], to: file)
        let content = try String(contentsOf: file, encoding: .utf8)
        precondition(content.split(separator: "\n").count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        runtime.detach(tabID: "a")
        precondition(runtime.activeTabID == nil && runtime.pageTools(tabID: "a") == nil)
        print("W48 runtime fixture PASS: 30 policy cases, 19 effects, bounds, consent, stale, cancellation, 21 private audit lines")
    }
}
