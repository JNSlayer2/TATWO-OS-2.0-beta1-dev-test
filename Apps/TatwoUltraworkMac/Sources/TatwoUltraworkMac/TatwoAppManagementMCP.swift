import CryptoKit
import Foundation
import TatwoCEFBridge
import TatwoUltraworkCore

enum TatwoAppManagementMCP {
    private static let computerBridge = TatwoComputerMCPCallBridge()
    private static let browserGrantBridge =
        TatwoBrowserGrantMCPCallBridge()
    private static let browserSnapshotBridge =
        TatwoBrowserSnapshotMCPCallBridge()

    static func installComputerHandler(
        _ handler: @escaping @MainActor ([String: JSONValue]) -> TatwoMCPToolCallResult
    ) {
        computerBridge.install(handler)
    }

    static func installBrowserGrantHandler(
        _ handler: @escaping @MainActor ([String: JSONValue]) throws
            -> TatwoBrowserAgentGrant
    ) {
        browserGrantBridge.install(handler)
    }

    static func installBrowserSnapshotProviderForTesting(
        _ provider: (@Sendable () throws -> TatwoCEFVisibleSnapshotV1)?
    ) {
        browserSnapshotBridge.install(provider)
    }

    static func call(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        switch tool {
        case "tatwo.browser.read_sanitized":
            return browserReadSanitized(tool: tool, arguments: arguments)
        case "tatwo.browser.plan_actions":
            return browserPlanActions(tool: tool, arguments: arguments)
        case "tatwo.browser.execute_approved_plan":
            return browserExecuteApprovedPlan(
                tool: tool,
                arguments: arguments)
        case "tatwo.computer.execute":
            guard let result = computerBridge.call(arguments) else {
                return failure(tool, "computer_turn_unavailable")
            }
            return result
        case "tatwo.app.read_os_state":
            return success(tool, payload: [
                "selectedSurface": .string("app"),
                "sidebarPinned": .bool(
                    UserDefaults.standard.bool(forKey: "tatwo.sidebar.pinned")),
                "appMCP": .string("ready"),
            ])
        case "tatwo.app.list_loops":
            // 2026-08-23 崩潰修復：HTTP server 從背景 queue 進來，裸
            // assumeIsolated 直接 SIGTRAP 弄死整個 App（每次 list_loops
            // 都崩，chat 端看到的就是 "user cancelled MCP tool call"）。
            guard let snapshot = onMainBounded({
                TatwoLoopsActivityMonitor.loopsInProgressNow()
            }) else {
                return failure(tool, "main thread busy, retry")
            }
            return success(tool, payload: [
                "active": .bool(snapshot.isActive),
                "running": .number(Double(snapshot.runningCount)),
                "queued": .number(Double(snapshot.queuedCount)),
                "loops": .array(snapshot.rows.map { row in
                    .object([
                        "id": .string(row.id),
                        "model": .string(row.displayName),
                        "status": .string(row.statusLabel),
                        "subtask": .string(row.subtask),
                    ])
                }),
            ])
        case "tatwo.app.switch_tab":
            guard let requested = arguments["tab"]?.stringValue else {
                return failure(tool, "missing_tab")
            }
            return switchTab(tool: tool, requested: requested)
        case "tatwo.app.set_sidebar_pinned":
            guard case .bool(let pinned) = arguments["pinned"] else {
                return failure(tool, "missing_pinned")
            }
            UserDefaults.standard.set(pinned, forKey: "tatwo.sidebar.pinned")
            return success(tool, payload: ["pinned": .bool(pinned)])
        case "tatwo.app.set_tab_setting":
            guard let tab = arguments["tab"]?.stringValue,
                  let key = arguments["key"]?.stringValue,
                  let value = arguments["value"]
            else { return failure(tool, "missing_setting_argument") }
            let allowedKeys: Set<String> = ["sidebarPinned"]
            guard allowedKeys.contains(key) else {
                return failure(tool, "setting_not_allowlisted")
            }
            if key == "sidebarPinned", case .bool(let pinned) = value {
                UserDefaults.standard.set(pinned, forKey: "tatwo.sidebar.pinned")
                return success(tool, payload: [
                    "tab": .string(tab), "key": .string(key), "value": value,
                ])
            }
            return failure(tool, "invalid_setting_value")
        case "tatwo.app.chat.create_project", "tatwo.app.chat.new_thread",
             "tatwo.app.chat.send", "tatwo.app.chat.status", "tatwo.app.chat.stop":
            return chatAutomation(tool: tool, arguments: arguments)
        default:
            if tool.hasPrefix("tatwo.webmcp.") {
                return browserPlanWebMCP(
                    tool: tool,
                    arguments: arguments)
            }
            return TatwoMCPRegistry.call(tool: tool, arguments: arguments)
        }
    }

    // Exec-arena automation: acts exactly like the composer (see
    // ChatPageModel+Automation.swift). Main-thread bounded like list_loops.
    private static func chatAutomation(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        let result: JSONValue? = onMainBounded(timeout: 10) {
            guard let model = ChatPageModel.automationInstance else {
                return .object(["error": .string("chat_model_unavailable")])
            }
            switch tool {
            case "tatwo.app.chat.create_project":
                guard let workdir = arguments["workdir"]?.stringValue else {
                    return .object(["error": .string("missing_workdir")])
                }
                guard let id = model.automationCreateProject(
                    workdir: workdir,
                    name: arguments["name"]?.stringValue)
                else { return .object(["error": .string("project_not_created")]) }
                return .object(["projectID": .string(id.uuidString)])
            case "tatwo.app.chat.new_thread":
                guard let id = model.automationNewThread(
                    projectID: arguments["projectID"]?.stringValue)
                else {
                    return .object(["error": .string("thread_not_created")])
                }
                return .object(["threadID": .string(id.uuidString)])
            case "tatwo.app.chat.send":
                guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                    return .object(["error": .string("missing_text")])
                }
                let started = model.automationSend(
                    text: text,
                    modelID: arguments["model"]?.stringValue)
                return .object([
                    "started": .bool(started),
                    "threadID": .string(model.selectedThreadID?.uuidString ?? ""),
                ])
            case "tatwo.app.chat.stop":
                model.automationStop()
                return .object(["stopped": .bool(true)])
            default:
                return model.automationStatus()
            }
        }
        guard let result else { return failure(tool, "main thread busy, retry") }
        if case .object(let object) = result, let error = object["error"]?.stringValue {
            return failure(tool, error)
        }
        return success(tool, payload: result)
    }

    private static func switchTab(
        tool: String,
        requested: String
    ) -> TatwoMCPToolCallResult {
        let normalized = requested.lowercased()
        if normalized == "cli" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .tatwoOpenWorkOSWindow,
                    object: TatwoPage.chat.rawValue)
                NotificationCenter.default.post(
                    name: .tatwoChatSelectMode,
                    object: ChatRunMode.cli.rawValue)
            }
            return success(tool, payload: ["tab": .string("cli")])
        }
        let mapped: TatwoPage?
        switch normalized {
        case "chat": mapped = .chat
        case "ultrawork": mapped = .workflow
        case "plugins": mapped = .plugins
        case "devices": mapped = .devices
        case "settings": mapped = .modes
        default: mapped = nil
        }
        guard let mapped else { return failure(tool, "unknown_tab") }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .tatwoOpenWorkOSWindow,
                object: mapped.rawValue)
        }
        return success(tool, payload: ["tab": .string(normalized)])
    }

    private static func browserReadSanitized(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        do {
            let grant = try resolveBrowserGrant(arguments)
            let raw = try captureRawBrowserSnapshot()
            let envelope = try TatwoBrowserEnvelopeBuilder.build(
                raw: raw,
                grant: grant)
            try TatwoBrowserAgentSecurityRuntime.shared.record(
                envelope: envelope,
                grant: grant)
            return success(
                tool,
                payload: try JSONValue.fromEncodable(envelope),
                hostMutationAllowed: false)
        } catch {
            showBrowserProtectionDegraded(error)
            return failure(tool, browserErrorCode(error))
        }
    }

    private static func browserPlanActions(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        do {
            let grant = try resolveBrowserGrant(arguments)
            guard let snapshotHash =
                    arguments["snapshotHash"]?.stringValue
            else {
                return failure(tool, "missing_snapshot_hash")
            }
            let actions: [TatwoBrowserRequestedActionV1] = try decode(
                arguments["actions"],
                as: [TatwoBrowserRequestedActionV1].self)
            let token = try TatwoBrowserAgentSecurityRuntime.shared.freezePlan(
                grant: grant,
                snapshotHash: snapshotHash,
                requestedActions: actions)
            return success(
                tool,
                payload: try JSONValue.fromEncodable(token),
                hostMutationAllowed: false)
        } catch {
            return failure(tool, browserErrorCode(error))
        }
    }

    private static func browserExecuteApprovedPlan(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        do {
            let grant = try resolveBrowserGrant(arguments)
            let approvedToken: TatwoBrowserTypedPlanTokenV1 = try decode(
                arguments["approvedPlanToken"],
                as: TatwoBrowserTypedPlanTokenV1.self)
            guard let workspaceRoot =
                    arguments["workspaceRoot"]?.stringValue,
                  !workspaceRoot.isEmpty
            else {
                return failure(tool, "missing_workspace_root")
            }
            if approvedToken.actions.first?.action == .webMCP {
                return browserExecuteApprovedWebMCPPlan(
                    tool: tool,
                    grant: grant,
                    approvedToken: approvedToken)
            }
            let raw = try captureRawBrowserSnapshot()
            let currentEnvelope = try TatwoBrowserEnvelopeBuilder.build(
                raw: raw,
                grant: grant)
            let (_, action) =
                try TatwoBrowserAgentSecurityRuntime.shared.prepareNextAction(
                    approvedToken: approvedToken,
                    grant: grant,
                    currentSnapshotHash: currentEnvelope.snapshotHash,
                    currentOrigin: currentEnvelope.origin,
                    currentNavigationGeneration:
                        currentEnvelope.navigationGeneration)
            let computerArguments: [String: JSONValue] = [
                "contractID": .string(grant.contractID),
                "leaseID": .string(grant.leaseID),
                "runID": .string(grant.runID),
                "workspaceRoot": .string(workspaceRoot),
                "action": .string(computerActionName(action.action)),
                "value": .string(action.executionValue),
            ]
            guard let receipt = computerBridge.call(computerArguments) else {
                _ = try? TatwoBrowserAgentSecurityRuntime.shared
                    .requireVerification(
                        tokenID: approvedToken.tokenID,
                        actionSucceeded: false)
                return failure(tool, "typed_browser_executor_unavailable")
            }
            let verifiedState =
                try TatwoBrowserAgentSecurityRuntime.shared.requireVerification(
                tokenID: approvedToken.tokenID,
                actionSucceeded: receipt.ok)
            guard receipt.ok else {
                return failure(
                    tool,
                    receipt.error ?? "typed_browser_action_failed")
            }
            return success(
                tool,
                payload: [
                    "planTokenID": .string(approvedToken.tokenID),
                    "planHash": .string(approvedToken.planHash),
                    "actionID": .string(action.id),
                    "elementID": .string(action.elementID),
                    "verified": .bool(true),
                    "state": .string(verifiedState.rawValue),
                    "receipt": receipt.payload ?? .null,
                ],
                hostMutationAllowed: true)
        } catch {
            return failure(tool, browserErrorCode(error))
        }
    }

    private static func browserPlanWebMCP(
        tool: String,
        arguments: [String: JSONValue]
    ) -> TatwoMCPToolCallResult {
        do {
            guard let descriptor =
                    TatwoWebMCPRuntime.shared.descriptor(named: tool)
            else {
                return failure(tool, "webmcp_tool_unavailable")
            }
            let grant = try resolveBrowserGrant(arguments)
            let argumentsJSON =
                try TatwoWebMCPRuntime.shared.canonicalArgumentsJSON(
                    from: arguments)
            let token = try TatwoBrowserAgentSecurityRuntime.shared
                .freezeWebMCPPlan(
                    grant: grant,
                    toolName: descriptor.mcpToolName,
                    origin: descriptor.origin,
                    navigationGeneration:
                        descriptor.navigationGeneration,
                    bindingHash: descriptor.bindingHash,
                    argumentsJSON: argumentsJSON)
            return success(
                tool,
                payload: [
                    "trust": .string("untrusted_web"),
                    "executionPolicy": .string(
                        "plan_then_execute_human_gate"),
                    "invoked": .bool(false),
                    "approvedPlanToken":
                        try JSONValue.fromEncodable(token),
                ],
                hostMutationAllowed: false)
        } catch {
            return failure(tool, browserErrorCode(error))
        }
    }

    private static func browserExecuteApprovedWebMCPPlan(
        tool: String,
        grant: TatwoBrowserAgentGrant,
        approvedToken: TatwoBrowserTypedPlanTokenV1
    ) -> TatwoMCPToolCallResult {
        guard approvedToken.actions.count == 1,
              let plannedAction = approvedToken.actions.first,
              plannedAction.action == .webMCP,
              let descriptor = TatwoWebMCPRuntime.shared.descriptor(
                  named: plannedAction.elementID)
        else {
            return failure(tool, "webmcp_tool_unavailable")
        }
        do {
            let (_, action) =
                try TatwoBrowserAgentSecurityRuntime.shared.prepareNextAction(
                    approvedToken: approvedToken,
                    grant: grant,
                    currentSnapshotHash: descriptor.bindingHash,
                    currentOrigin: descriptor.origin,
                    currentNavigationGeneration:
                        descriptor.navigationGeneration)
            let executionDigest =
                SHA256.hash(data: Data(action.executionValue.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
            guard action.action == .webMCP,
                  action.elementID == descriptor.mcpToolName,
                  action.parameterDigest == executionDigest
            else {
                _ = try? TatwoBrowserAgentSecurityRuntime.shared
                    .requireVerification(
                        tokenID: approvedToken.tokenID,
                        actionSucceeded: false)
                return failure(tool, "invalid_webmcp_plan")
            }
            let outcome = TatwoWebMCPRuntime.shared.invoke(
                descriptor: descriptor,
                argumentsJSON: action.executionValue)
            guard let pageResult = outcome.value,
                  outcome.errorCode == nil
            else {
                _ = try? TatwoBrowserAgentSecurityRuntime.shared
                    .requireVerification(
                        tokenID: approvedToken.tokenID,
                        actionSucceeded: false)
                return failure(
                    tool,
                    outcome.errorCode ?? "webmcp_execute_failed")
            }
            let verifiedState =
                try TatwoBrowserAgentSecurityRuntime.shared
                    .requireVerification(
                        tokenID: approvedToken.tokenID,
                        actionSucceeded: true)
            let envelope =
                try ChatPageModel.browserUntrustedToolResultDataChannel(
                    pageResult)
            return success(
                tool,
                payload: [
                    "planTokenID": .string(approvedToken.tokenID),
                    "planHash": .string(approvedToken.planHash),
                    "actionID": .string(action.id),
                    "state": .string(verifiedState.rawValue),
                    "result": envelope,
                ],
                hostMutationAllowed: true)
        } catch {
            return failure(tool, browserErrorCode(error))
        }
    }

    private static func captureRawBrowserSnapshot()
        throws -> TatwoCEFVisibleSnapshotV1
    {
        if let injected = try browserSnapshotBridge.capture() {
            return injected
        }
        guard TatwoCEFRuntime.compiled, !Thread.isMainThread else {
            throw TatwoBrowserSecurityError.snapshotUnavailable
        }
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var capturedJSON: String?
        nonisolated(unsafe) var capturedError: String?
        TatwoCEFRuntime.captureActiveVisibleSnapshot { json, error in
            lock.lock()
            capturedJSON = json
            capturedError = error
            lock.unlock()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 1) == .success else {
            throw TatwoBrowserSecurityError.snapshotUnavailable
        }
        lock.lock()
        let json = capturedJSON
        let error = capturedError
        lock.unlock()
        guard error == nil, let json, let data = json.data(using: .utf8)
        else {
            throw TatwoBrowserSecurityError(
                rawValue: error ?? "") ?? .snapshotUnavailable
        }
        do {
            return try JSONDecoder().decode(
                TatwoCEFVisibleSnapshotV1.self,
                from: data)
        } catch {
            throw TatwoBrowserSecurityError.snapshotParseFailed
        }
    }

    private static func resolveBrowserGrant(
        _ arguments: [String: JSONValue]
    ) throws -> TatwoBrowserAgentGrant {
        if arguments["grant"] != nil {
            return try decode(
                arguments["grant"],
                as: TatwoBrowserAgentGrant.self)
        }
        guard let outcome = browserGrantBridge.call(arguments) else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
        if let grant = outcome.grant {
            return grant
        }
        throw TatwoBrowserSecurityError(
            rawValue: outcome.errorCode ?? "")
            ?? .invalidGrant
    }

    private static func decode<T: Decodable>(
        _ value: JSONValue?,
        as type: T.Type
    ) throws -> T {
        guard let value else {
            throw TatwoBrowserSecurityError.invalidGrant
        }
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func computerActionName(
        _ action: TatwoBrowserTypedActionKind
    ) -> String {
        switch action {
        case .click: "mouse_click"
        case .doubleClick: "mouse_double_click"
        case .typeText: "type_text"
        case .pressKey: "press_key"
        case .scroll: "scroll"
        case .webMCP: "webmcp"
        }
    }

    private static func browserErrorCode(_ error: Error) -> String {
        (error as? TatwoBrowserSecurityError)?.rawValue
            ?? "browser_security_failure"
    }

    private static func showBrowserProtectionDegraded(_ error: Error) {
        let code = browserErrorCode(error)
        Task { @MainActor in
            TatwoBrowserSecurityProjection.shared.showDegraded(code)
        }
    }

    fileprivate static func onMainBounded<T: Sendable>(
        timeout: TimeInterval = 10,
        _ body: @MainActor @escaping @Sendable () -> T
    ) -> T? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let abandonment = TatwoMainDispatchAbandonment()
        nonisolated(unsafe) var result: T?
        DispatchQueue.main.async {
            guard !abandonment.isAbandoned else {
                semaphore.signal()
                return
            }
            result = MainActor.assumeIsolated(body)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            abandonment.abandon()
            return nil
        }
        return result
    }

    private static func success(
        _ tool: String,
        payload: [String: JSONValue],
        hostMutationAllowed: Bool? = nil
    ) -> TatwoMCPToolCallResult {
        success(
            tool,
            payload: .object(payload),
            hostMutationAllowed: hostMutationAllowed)
    }

    private static func success(
        _ tool: String,
        payload: JSONValue,
        hostMutationAllowed: Bool? = nil
    ) -> TatwoMCPToolCallResult {
        TatwoMCPToolCallResult(
            tool: tool,
            ok: true,
            payload: payload,
            hostMutationAllowed: hostMutationAllowed
                ?? (tool != "tatwo.app.read_os_state"
                    && tool != "tatwo.app.list_loops"))
    }

    private static func failure(
        _ tool: String,
        _ error: String
    ) -> TatwoMCPToolCallResult {
        TatwoMCPToolCallResult(
            tool: tool,
            ok: false,
            payload: nil,
            error: error,
            failureKind: .contract,
            hostMutationAllowed: false)
    }
}

private final class TatwoMainDispatchAbandonment: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false

    var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }
}

private final class TatwoComputerMCPCallBridge: @unchecked Sendable {
    typealias Handler =
        @MainActor ([String: JSONValue]) -> TatwoMCPToolCallResult

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func call(_ arguments: [String: JSONValue]) -> TatwoMCPToolCallResult? {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else { return nil }
        return TatwoAppManagementMCP.onMainBounded {
            handler(arguments)
        }
    }
}

private struct TatwoBrowserGrantMCPOutcome: Sendable {
    let grant: TatwoBrowserAgentGrant?
    let errorCode: String?
}

private final class TatwoBrowserGrantMCPCallBridge: @unchecked Sendable {
    typealias Handler =
        @MainActor ([String: JSONValue]) throws
            -> TatwoBrowserAgentGrant

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func call(
        _ arguments: [String: JSONValue]
    ) -> TatwoBrowserGrantMCPOutcome? {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else { return nil }
        return TatwoAppManagementMCP.onMainBounded {
            do {
                return TatwoBrowserGrantMCPOutcome(
                    grant: try handler(arguments),
                    errorCode: nil)
            } catch {
                return TatwoBrowserGrantMCPOutcome(
                    grant: nil,
                    errorCode:
                        (error as? TatwoBrowserSecurityError)?.rawValue
                            ?? "invalid_browser_grant")
            }
        }
    }
}

private final class TatwoBrowserSnapshotMCPCallBridge:
    @unchecked Sendable
{
    typealias Provider =
        @Sendable () throws -> TatwoCEFVisibleSnapshotV1

    private let lock = NSLock()
    private var provider: Provider?

    func install(_ provider: Provider?) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }

    func capture() throws -> TatwoCEFVisibleSnapshotV1? {
        lock.lock()
        let provider = self.provider
        lock.unlock()
        return try provider?()
    }
}
