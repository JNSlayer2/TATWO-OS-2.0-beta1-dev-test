import Foundation
import Darwin
import CryptoKit
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

protocol ChatNativeAgentRunning: Sendable {
    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity?
    func terminate()
}

struct ChatNativeAgentRunRequest: Sendable {
    let runID: String
    let dispatchID: String?
    let prompt: String
    let modelID: String
    let effort: String
    let contractID: String
    let workspaceRoot: String
    let readOnly: Bool
    let permissionPreset: TatwoPermissionPreset

    init(
        runID: String,
        dispatchID: String?,
        prompt: String,
        modelID: String,
        effort: String,
        contractID: String,
        workspaceRoot: String,
        readOnly: Bool,
        permissionPreset: TatwoPermissionPreset = .askFirst
    ) {
        self.runID = runID
        self.dispatchID = dispatchID
        self.prompt = prompt
        self.modelID = modelID
        self.effort = effort
        self.contractID = contractID
        self.workspaceRoot = workspaceRoot
        self.readOnly = readOnly
        self.permissionPreset = permissionPreset
    }
}

struct ChatNativeHostOperationAuthorizationIssuer: Sendable {
    let approvalStore: TatwoHostApprovalStore
    let contractID: String
    let workspaceRoot: String
    let permissionPreset: TatwoPermissionPreset
    let now: @Sendable () -> Date

    init(
        approvalStore: TatwoHostApprovalStore,
        contractID: String,
        workspaceRoot: String,
        permissionPreset: TatwoPermissionPreset,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.approvalStore = approvalStore
        self.contractID = contractID
        self.workspaceRoot =
            TatwoGoalRevisionPromotionAuthorizationV1
                .canonicalWorkspacePath(workspaceRoot)
        self.permissionPreset = permissionPreset
        self.now = now
    }

    func authorizationID(
        for request: TatwoNativeHostAuthorizationRequest
    ) throws -> String {
        if request.isMutation,
           ![TatwoPermissionPreset.approveForMe, .fullAccess]
            .contains(permissionPreset)
        {
            throw TatwoHostExecutorError.approvalRequired
        }
        let goalSnapshot = try approvalStore.goalRunStore.snapshot(
            forContractID: contractID)
        let goal = goalSnapshot.record
        guard goal.status == .running,
              let supersession = goal.supersession,
              goal.successorContractID == nil
        else {
            throw TatwoHostExecutorError.approvalRequired
        }
        let sessionStore = TatwoSessionStore(
            directoryURL: approvalStore.goalRunStore.directoryURL)
        guard let current = try sessionStore.snapshotCurrent(),
              current.pointer.contractID == contractID,
              current.pointer.goalID == goal.goalID
        else {
            throw TatwoHostExecutorError.approvalScopeMismatch
        }
        let contract = try WorkOSFactory.storedContractProjection(
            snapshot: goalSnapshot,
            catalog: .defaults,
            scenarioBook: TatwoScenarioConfigStore.loadDefaultStaging(),
            store: approvalStore.goalRunStore)
        guard contract.humanApprovableHostActions?
            .contains(request.action) == true,
              let ceiling = contract.hostActionCeiling
        else {
            throw TatwoHostExecutorError.approvalScopeMismatch
        }
        let issuedAt = now()
        let idDigest = Self.sha256(Data([
            contractID,
            goal.goalID,
            String(goal.resolvedRevision),
            String(current.pointer.generation ?? 1),
            request.action.rawValue,
            request.argumentDigest,
        ].joined(separator: "\n").utf8))
        let authorization = TatwoHostOperationAuthorizationV1(
            id: "native-host-\(idDigest)",
            issuerDomain:
                TatwoAppHumanGateAuthorizationStore.issuerDomain,
            contractID: contractID,
            goalID: goal.goalID,
            goalRevision: goal.resolvedRevision,
            pointerGeneration: current.pointer.generation ?? 1,
            activationEpoch: goal.resolvedRevision,
            completedTransitionReceiptID:
                supersession.supersessionReceiptID,
            humanGateReceiptID: supersession.humanGateReceiptID,
            canonicalWorkspacePath: workspaceRoot,
            action: request.action,
            argumentDigest: request.argumentDigest,
            outputRoots: [workspaceRoot],
            resourceBounds: ceiling,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(60),
            nonce: "native-host-\(idDigest)",
            proofDigest: "")
        return try approvalStore.hostOperationAuthorizationStore
            .authorizeAfterHumanConfirmation(authorization).id
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

final class ChatNativeAgentRunner: ChatNativeAgentRunning, @unchecked Sendable {
    static let productionMaximumRunDuration: TimeInterval = 30 * 60
    static let productionMaximumModelSteps = 96
    static let productionMaximumToolCalls = 256

    private enum Completion: Sendable {
        case receipt(
            TatwoNativeAgentRunReceipt,
            terminal: NativeTerminalReceipt?
        )
        case cancelled
        case timedOut
        case failed(code: String)
    }

    private struct NativeTerminalReceipt: Codable, Sendable {
        let schema: String
        let receiptID: String
        let runID: String
        let dispatchID: String?
        let modelID: String
        let effort: String
        let contractID: String
        let eventCount: Int
        let assistantTextSHA256: String?
        let completedAt: Date
        let outputRef: String
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let approvalStore: TatwoHostApprovalStore
    private let subscriptionSessionFactory:
        (@Sendable (URL) throws ->
            any ChatNativeSubscriptionAppServerSession)?
    private let claudeSubscriptionRunnerFactory:
        (@Sendable () throws ->
            any ChatNativeClaudeProcessRunning)?
    private let grokSubscriptionRunnerFactory:
        (@Sendable () throws ->
            any ChatNativeGrokProcessRunning)?
    private let journalDirectoryURL: URL
    private let maximumRunDuration: TimeInterval
    private let runtimeGovernor: TatwoRuntimeGovernor

    init(
        approvalStore: TatwoHostApprovalStore? = nil,
        subscriptionSessionFactory:
            (@Sendable (URL) throws ->
                any ChatNativeSubscriptionAppServerSession)? = nil,
        claudeSubscriptionRunnerFactory:
            (@Sendable () throws ->
                any ChatNativeClaudeProcessRunning)? = nil,
        grokSubscriptionRunnerFactory:
            (@Sendable () throws ->
                any ChatNativeGrokProcessRunning)? = nil,
        journalDirectoryURL: URL,
        runtimeGovernor: TatwoRuntimeGovernor = .shared,
        maximumRunDuration: TimeInterval =
            ChatNativeAgentRunner.productionMaximumRunDuration
    ) {
        self.approvalStore = approvalStore ?? TatwoHostApprovalStore.default()
        self.subscriptionSessionFactory = subscriptionSessionFactory
        self.claudeSubscriptionRunnerFactory =
            claudeSubscriptionRunnerFactory
        self.grokSubscriptionRunnerFactory =
            grokSubscriptionRunnerFactory
        self.journalDirectoryURL = journalDirectoryURL
        self.runtimeGovernor = runtimeGovernor
        self.maximumRunDuration = max(1, maximumRunDuration)
    }

    func start(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        terminate()
        let identity = ChatRunnerAttemptIdentity(
            runID: request.runID,
            attempt: 1,
            instanceID: UUID(),
            revision: 1)
        let approvalStore = self.approvalStore
        let subscriptionSessionFactory =
            self.subscriptionSessionFactory
        let claudeSubscriptionRunnerFactory =
            self.claudeSubscriptionRunnerFactory
        let grokSubscriptionRunnerFactory =
            self.grokSubscriptionRunnerFactory
        let journalDirectoryURL = self.journalDirectoryURL
        let runtimeGovernor = self.runtimeGovernor
        let maximumRunDuration = self.maximumRunDuration
        let newTask: Task<Void, Never> = Task {
            // M3a 更新：XXL/nativeAgent 治理行為不由 chat governor 排隊，
            // 但其實際 runtime 佔用仍登記，會壓縮後續聊天可用名額。
            let lease = runtimeGovernor.registerExternalRuntime(
                kind: .xxlGoalSpawn)
            defer { runtimeGovernor.release(lease) }
            await Self.run(
                request: request,
                onEvent: onEvent,
                approvalStore: approvalStore,
                subscriptionSessionFactory: subscriptionSessionFactory,
                claudeSubscriptionRunnerFactory:
                    claudeSubscriptionRunnerFactory,
                grokSubscriptionRunnerFactory:
                    grokSubscriptionRunnerFactory,
                journalDirectoryURL: journalDirectoryURL,
                maximumRunDuration: maximumRunDuration)
        }
        lock.lock()
        task = newTask
        lock.unlock()
        return identity
    }

    func terminate() {
        lock.lock()
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }

    private static func run(
        request: ChatNativeAgentRunRequest,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void,
        approvalStore: TatwoHostApprovalStore,
        subscriptionSessionFactory:
            (@Sendable (URL) throws ->
                any ChatNativeSubscriptionAppServerSession)?,
        claudeSubscriptionRunnerFactory:
            (@Sendable () throws ->
                any ChatNativeClaudeProcessRunning)?,
        grokSubscriptionRunnerFactory:
            (@Sendable () throws ->
                any ChatNativeGrokProcessRunning)?,
        journalDirectoryURL: URL,
        maximumRunDuration: TimeInterval
    ) async {
        guard
            ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs
                .contains(request.modelID)
            || ChatNativeClaudeSubscriptionModelTransport.supportedModelIDs
                .contains(request.modelID)
            || ChatNativeGrokSubscriptionModelTransport.supportedModelIDs
                .contains(request.modelID)
        else {
            onEvent(.runtimeFailure(
                "TATWO subscription runtime unavailable for selected model"))
            onEvent(.exit(1))
            return
        }
        let effectiveEffort = requiredSubscriptionEffort(
            modelID: request.modelID,
            requestedEffort: request.effort)
        let effectiveRequest = ChatNativeAgentRunRequest(
            runID: request.runID,
            dispatchID: request.dispatchID,
            prompt: request.prompt,
            modelID: request.modelID,
            effort: effectiveEffort,
            contractID: request.contractID,
            workspaceRoot: request.workspaceRoot,
            readOnly: request.readOnly,
            permissionPreset: request.permissionPreset)
        let scratchDirectoryURL = journalDirectoryURL
            .appendingPathComponent(
                "subscription-runtime",
                isDirectory: true)
            .appendingPathComponent(
                request.runID,
                isDirectory: true)
        let injectedFactory:
            (@Sendable () throws ->
                any ChatNativeSubscriptionAppServerSession)?
        if let subscriptionSessionFactory {
            injectedFactory = {
                try subscriptionSessionFactory(scratchDirectoryURL)
            }
        } else {
            injectedFactory = nil
        }
        let appAuthorizationPolicy: any ToolAuthorizationPolicy =
            ExistingHostOperationAuthorizationAdapter(
                issuer: ChatNativeHostOperationAuthorizationIssuer(
                    approvalStore: approvalStore,
                    contractID: request.contractID,
                    workspaceRoot: request.workspaceRoot,
                    permissionPreset: request.permissionPreset))
        let authorization = TatwoNativeExactHostAuthorizationProvider(
            approvalStore: approvalStore,
            contractID: request.contractID,
            workspaceRoot: request.workspaceRoot,
            allowsMutation: !request.readOnly,
            revisionBoundAuthorizationIssuer: { request in
                try appAuthorizationPolicy.authorize(request)
            })
        let executor = TatwoNativeDevelopmentToolExecutor(
            hostExecutor: TatwoHostExecutor(
                approvalStore: approvalStore,
                backupRoot: journalDirectoryURL.appendingPathComponent(
                    "backups", isDirectory: true)),
            authorizationProvider: authorization,
            contractID: request.contractID,
            workspaceRoot: request.workspaceRoot,
            readOnly: request.readOnly)
        let coordinator = TatwoNativeAgentRunCoordinator(
            journal: TatwoNativeAgentRunJournal(
                directoryURL: journalDirectoryURL))
        _ = try? coordinator.journal.reconcileInterruptedRuns()
        let completion: Completion
        if ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs
            .contains(request.modelID)
        {
            let transport = ChatNativeOpenAISubscriptionModelTransport(
                modelID: effectiveRequest.modelID,
                effort: effectiveRequest.effort,
                workspaceRoot: effectiveRequest.workspaceRoot,
                scratchDirectoryURL: scratchDirectoryURL,
                sessionFactory: injectedFactory)
            completion = await execute(
                transport: transport,
                executor: executor,
                coordinator: coordinator,
                request: effectiveRequest,
                maximumRunDuration: maximumRunDuration,
                onEvent: onEvent)
        } else if ChatNativeClaudeSubscriptionModelTransport
            .supportedModelIDs.contains(request.modelID)
        {
            let transport = ChatNativeClaudeSubscriptionModelTransport(
                modelID: request.modelID,
                effort: effectiveEffort,
                workspaceRoot: request.workspaceRoot,
                scratchDirectoryURL: scratchDirectoryURL,
                runnerFactory: claudeSubscriptionRunnerFactory)
            completion = await execute(
                transport: transport,
                executor: executor,
                coordinator: coordinator,
                request: effectiveRequest,
                maximumRunDuration: maximumRunDuration,
                onEvent: onEvent)
        } else {
            let transport = ChatNativeGrokSubscriptionModelTransport(
                modelID: effectiveRequest.modelID,
                effort: effectiveRequest.effort,
                workspaceRoot: effectiveRequest.workspaceRoot,
                scratchDirectoryURL: scratchDirectoryURL,
                runnerFactory: grokSubscriptionRunnerFactory)
            completion = await execute(
                transport: transport,
                executor: executor,
                coordinator: coordinator,
                request: effectiveRequest,
                maximumRunDuration: maximumRunDuration,
                onEvent: onEvent)
        }
        emit(completion: completion, onEvent: onEvent)
    }

    static func requiredSubscriptionEffort(
        modelID: String,
        requestedEffort: String
    ) -> String {
        if modelID == "fable-5" {
            return "medium"
        }
        if ChatNativeOpenAISubscriptionModelTransport.supportedModelIDs
            .contains(modelID)
            || modelID == "opus-5"
            || ChatNativeGrokSubscriptionModelTransport.supportedModelIDs
                .contains(modelID)
        {
            return "high"
        }
        return requestedEffort
    }

    private static func execute<Transport>(
        transport: Transport,
        executor: TatwoNativeDevelopmentToolExecutor,
        coordinator: TatwoNativeAgentRunCoordinator,
        request: ChatNativeAgentRunRequest,
        maximumRunDuration: TimeInterval,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) async -> Completion
    where Transport: TatwoNativeModelTransport {
        let runtime = TatwoNativeAgentRuntime(
            transport: transport,
            toolExecutor: executor,
            expectedAttestation: TatwoNativeModelAttestation(
                modelID: request.modelID,
                effort: request.effort,
                fallbackCount: 0),
            maximumModelSteps: productionMaximumModelSteps,
            maximumToolCalls: productionMaximumToolCalls)
        return await race(
            coordinator: coordinator,
            runtime: runtime,
            request: request,
            maximumRunDuration: maximumRunDuration,
            onEvent: onEvent)
    }

    private static func race<Transport>(
        coordinator: TatwoNativeAgentRunCoordinator,
        runtime: TatwoNativeAgentRuntime<
            Transport,
            TatwoNativeDevelopmentToolExecutor
        >,
        request: ChatNativeAgentRunRequest,
        maximumRunDuration: TimeInterval,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) async -> Completion
    where Transport: TatwoNativeModelTransport {
        await withTaskGroup(
            of: Completion?.self,
            returning: Completion.self
        ) { group in
            group.addTask {
                do {
                    let receipt = try await coordinator.run(
                        runID: request.runID,
                        prompt: request.prompt,
                        tools: TatwoNativeDevelopmentToolCatalog.definitions(
                            readOnly: request.readOnly),
                        runtime: runtime
                    ) { event in
                        if let chatEvent = Self.chatEvent(from: event) {
                            onEvent(chatEvent)
                        }
                    }
                    let terminal: NativeTerminalReceipt?
                    if receipt.outcome == .completed {
                        do {
                            terminal = try persistTerminalReceipt(
                                request: request,
                                receipt: receipt,
                                journalDirectoryURL:
                                    coordinator.journal.directoryURL)
                        } catch {
                            return .failed(
                                code: "native_terminal_receipt_persist_failed")
                        }
                    } else {
                        terminal = nil
                    }
                    return .receipt(receipt, terminal: terminal)
                } catch is CancellationError {
                    return .cancelled
                } catch let failure
                    as any TatwoNativeActionableTransportFailure
                {
                    return .failed(code: failure.nativeFailureCode)
                } catch {
                    return .failed(code: "native_runtime_error")
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            maximumRunDuration * 1_000_000_000))
                } catch {
                    return nil
                }
                return Task.isCancelled ? nil : .timedOut
            }
            while let next = await group.next() {
                guard let next else { continue }
                group.cancelAll()
                return next
            }
            return .cancelled
        }
    }

    private static func persistTerminalReceipt(
        request: ChatNativeAgentRunRequest,
        receipt: TatwoNativeAgentRunReceipt,
        journalDirectoryURL: URL
    ) throws -> NativeTerminalReceipt {
        let completedAt = Date()
        let assistantDigest = receipt.assistantText.map {
            sha256(Data($0.utf8))
        }
        let canonical = [
            "TatwoNativeTerminalReceiptV1",
            request.runID,
            request.dispatchID ?? "",
            request.modelID,
            request.effort,
            request.contractID,
            String(receipt.events.count),
            assistantDigest ?? "",
            String(Int64(completedAt.timeIntervalSince1970)),
        ].joined(separator: "\n")
        let receiptID = "native-terminal:\(sha256(Data(canonical.utf8)))"
        let directory = journalDirectoryURL.appendingPathComponent(
            "native-terminal-receipts",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let safeRunID = request.runID.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
                ? Character(String($0)) : "_"
        }
        let fileURL = directory.appendingPathComponent(
            String(safeRunID) + ".json",
            isDirectory: false)
        let terminal = NativeTerminalReceipt(
            schema: "TatwoNativeTerminalReceiptV1",
            receiptID: receiptID,
            runID: request.runID,
            dispatchID: request.dispatchID,
            modelID: request.modelID,
            effort: request.effort,
            contractID: request.contractID,
            eventCount: receipt.events.count,
            assistantTextSHA256: assistantDigest,
            completedAt: completedAt,
            outputRef: fileURL.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(terminal).write(to: fileURL, options: [.atomic])
        return terminal
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func emit(
        completion: Completion,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) {
        switch completion {
        case .receipt(let receipt, let terminal):
            switch receipt.outcome {
            case .completed:
                guard let terminal else {
                    onEvent(.runtimeFailure(
                        "Native terminal receipt was not persisted"))
                    onEvent(.exit(1))
                    return
                }
                onEvent(.nativeTerminalReceipt(
                    receiptID: terminal.receiptID,
                    outputRef: terminal.outputRef))
                onEvent(.exit(0))
            case .cancelled:
                onEvent(.exit(130))
            case .stepLimitReached:
                onEvent(.runtimeFailure("Native agent step limit reached"))
                onEvent(.exit(1))
            case .toolCallLimitReached:
                onEvent(.runtimeFailure("Native agent tool-call limit reached"))
                onEvent(.exit(1))
            case .failed(let code):
                onEvent(.runtimeFailure("Native agent failed: \(code)"))
                onEvent(.exit(1))
            }
        case .cancelled:
            onEvent(.exit(130))
        case .timedOut:
            onEvent(.runtimeFailure(
                "Native agent stopped after exceeding its bounded run time"))
            onEvent(.exit(1))
        case .failed(let code):
            onEvent(.runtimeFailure("Native agent runtime failed: \(code)"))
            onEvent(.exit(1))
        }
    }

    static func chatEvent(
        from event: TatwoNativeAgentEvent
    ) -> ChatCLIEvent? {
        switch event.kind {
        case .modelRequested(let step):
            return .thinking(ChatCLIActivity(
                text: "模型步驟 \(step)", rawType: "native_model"))
        case .toolRequested(_, let name):
            return .toolUse(ChatCLIActivity(
                text: name, rawType: "native_tool_started"))
        case .toolCompleted(_, let isError):
            return .toolUse(ChatCLIActivity(
                text: isError ? "工具失敗" : "工具完成",
                rawType: isError
                    ? "native_tool_failed" : "native_tool_completed"))
        case .assistantVisibleText(let text):
            return .output(text)
        case .cancelled:
            return .diagnostic("native_cancelled")
        case .stepLimitReached:
            return .diagnostic("native_step_limit")
        case .toolCallLimitReached:
            return .diagnostic("native_tool_limit")
        case .failed:
            return .diagnostic("native_failed")
        }
    }
}
