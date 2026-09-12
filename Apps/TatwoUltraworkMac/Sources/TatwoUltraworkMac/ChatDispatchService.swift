import Foundation
import TatwoUltraworkCore

@MainActor
protocol ChatDispatchService {
    func startRuntime(
        model: ChatPageModel,
        command: ChatCLICommand,
        nativePrompt: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        runID: String,
        activityTurnID: String,
        allowsNativeGovernanceFallback: Bool,
        nativeGovernanceFallbackCommand: ChatCLICommand?,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity?
}

struct DefaultChatDispatchService: ChatDispatchService {
    func startRuntime(
        model: ChatPageModel,
        command: ChatCLICommand,
        nativePrompt: String,
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        runID: String,
        activityTurnID: String,
        allowsNativeGovernanceFallback: Bool = false,
        nativeGovernanceFallbackCommand: ChatCLICommand? = nil,
        onEvent: @escaping @Sendable (ChatCLIEvent) -> Void
    ) -> ChatRunnerAttemptIdentity? {
        model.lastNativeRuntimeStartBlocker = nil
        if let snapshotBlocker = model.computerHostAuthorityBlocker(
            runID: runID,
            dispatchSnapshot: dispatchSnapshot)
        {
            // Do not fall back to a repository CLI probe when the exact
            // contract/goal/plan authority snapshot changed.
            model.lastNativeRuntimeStartBlocker = snapshotBlocker
            return nil
        }
        // Last mile before any process is spawned. A goal that became
        // cancelled / superseded_before_dispatch / stale after this turn was
        // submitted must fail closed here, so a prior optimistic decision can
        // never mutate the host after authority changed.
        if let authorityBlocker = model.lastMileGoalAuthorityBlocker(
            dispatchSnapshot: dispatchSnapshot,
            command: command)
        {
            model.lastNativeRuntimeStartBlocker = authorityBlocker
            return nil
        }
        if command.runtimeAdapter == .minimaxDirect {
            return model.miniMaxRunnerForTurnStart().start(
                prompt: nativePrompt,
                runID: runID,
                onEvent: onEvent)
        }
        if command.runtimeAdapter == .unavailable {
            let identity = ChatRunnerAttemptIdentity(
                runID: runID,
                attempt: 1,
                instanceID: UUID(),
                revision: 1)
            let reason = command.runtimeFallbackReason?.rawValue
                ?? "dev_runtime_unavailable"
            onEvent(.runtimeFailure(
                "runtime_unavailable reason=\(reason) message=內建 runtime 不可用，請更新/重裝 App"))
            return identity
        }
        guard command.runtimeAdapter == .nativeAgent else {
            return model.processRunnerForTurnStart().start(
                command: command,
                runID: runID,
                activityTurnID: activityTurnID,
                onEvent: onEvent)
        }
        let pendingDispatchForTurn =
            model.matchingPendingNativeDevelopmentDispatch(
                dispatchSnapshot: dispatchSnapshot)
        func rejectNativeRuntimeStart(
            _ blocker: String
        ) -> ChatRunnerAttemptIdentity? {
            model.lastNativeRuntimeStartBlocker = blocker
            guard allowsNativeGovernanceFallback,
                  pendingDispatchForTurn == nil,
                  let fallback = nativeGovernanceFallbackCommand,
                  fallback.runtimeAdapter != .nativeAgent,
                  fallback.runtimeAdapter != .unavailable
            else { return nil }
            model.applyNativeGovernanceFallbackPresentation(
                command: fallback,
                activityTurnID: activityTurnID)
            return model.processRunnerForTurnStart().start(
                command: fallback,
                runID: runID,
                activityTurnID: activityTurnID,
                onEvent: onEvent)
        }
        guard let frozenRoute = ChatRouteChoice.resolveOrNil(
            dispatchSnapshot.routeID)
        else {
            return rejectNativeRuntimeStart("route_unresolved")
        }
        guard TatwoGatewayDispatchCatalog.normalize(
            frozenRoute.canonicalModelSlug)
            == TatwoGatewayDispatchCatalog.normalize(
                dispatchSnapshot.canonicalModelID)
        else {
            return rejectNativeRuntimeStart("route_model_mismatch")
        }
        guard command.nativeDevelopmentAccess.authorizesNativeRuntime else {
            return rejectNativeRuntimeStart("native_access_denied")
        }
        guard let contractID = dispatchSnapshot.contractID else {
            return rejectNativeRuntimeStart("contract_id_missing")
        }
        guard let selectedContract = model.selectedWorkOSContract else {
            return rejectNativeRuntimeStart("selected_contract_missing")
        }
        guard selectedContract.contractID == contractID else {
            return rejectNativeRuntimeStart("selected_contract_mismatch")
        }
        guard let selectedThread = model.selectedThread else {
            return rejectNativeRuntimeStart("selected_thread_missing")
        }
        guard selectedThread.workOSContractID == contractID else {
            return rejectNativeRuntimeStart("thread_contract_mismatch")
        }
        guard ChatPageModel.normalizedNonEmpty(selectedThread.workOSGoalID)
            == selectedContract.goalID
        else {
            return rejectNativeRuntimeStart("thread_goal_mismatch")
        }
        guard let issuedGoal = try? model.goalRunStore.requireIssuedContract(
            contractID)
        else {
            return rejectNativeRuntimeStart("issued_goal_missing")
        }
        guard issuedGoal.goalID == selectedContract.goalID else {
            return rejectNativeRuntimeStart("issued_goal_mismatch")
        }
        guard (try? model.goalRunStore.verifyIssuedIdentityBindings(
            contract: selectedContract)) != nil
        else {
            return rejectNativeRuntimeStart(
                "issued_identity_bindings_unverified")
        }
        guard let contractBindingID = dispatchSnapshot.contractBindingID
        else {
            return rejectNativeRuntimeStart("contract_binding_missing")
        }
        guard selectedContract.loopGovernorDecision.activatedBindings.contains(
            where: { binding in
                binding.id == contractBindingID
                    && binding.enabled
                    && binding.dynamicActivation != .disabled
                    && binding.phase == dispatchSnapshot.phase
                    && binding.boundModelIDs.contains {
                        TatwoGatewayDispatchCatalog.normalize($0)
                            == TatwoGatewayDispatchCatalog.normalize(
                                dispatchSnapshot.canonicalModelID)
                    }
            })
        else {
            return rejectNativeRuntimeStart("contract_binding_mismatch")
        }
        switch command.nativeDevelopmentAccess {
        case .none:
            return rejectNativeRuntimeStart("native_access_none")
        case .readOnly:
            guard ![
                GoalRunStatus.succeeded,
                .failed,
                .cancelled,
                .passed,
                .rollbackRequired,
                .superseded,
            ].contains(issuedGoal.status) else {
                return rejectNativeRuntimeStart(
                    "read_only_goal_terminal")
            }
        case .mutation:
            guard dispatchSnapshot.phase == .loops,
                  [.dispatching, .running].contains(issuedGoal.status)
            else {
                return rejectNativeRuntimeStart(
                    "mutation_goal_not_running")
            }
        }
        let effort =
            dispatchSnapshot.forwardedEffort
                ?? frozenRoute.defaultEffort
        let pendingDispatch = model.pendingNativeDevelopmentDispatch.flatMap {
            pending in
            let issuedBindingMatches =
                selectedContract.identityBindings.contains { binding in
                    binding.id == pending.bindingID
                        && binding.sourceSlotID == pending.sourceSlotID
                        && binding.sourceSlotID == contractBindingID
                        && binding.identity == pending.identity
                        && binding.modelID.map(
                            TatwoGatewayDispatchCatalog.normalize)
                            == TatwoGatewayDispatchCatalog.normalize(
                                pending.modelID)
                }
            return pending.contractID == contractID
                && issuedBindingMatches
                && TatwoGatewayDispatchCatalog.normalize(pending.modelID)
                    == TatwoGatewayDispatchCatalog.normalize(
                        dispatchSnapshot.canonicalModelID)
                && pending.status == .running
                ? pending : nil
        }
        if command.nativeDevelopmentAccess == .mutation,
           [
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
           ].contains(selectedContract.scenario),
           pendingDispatch == nil
        {
            return rejectNativeRuntimeStart(
                "mutation_dispatch_missing")
        }
        let identity = model.nativeAgentRunnerForTurnStart().start(
            request: ChatNativeAgentRunRequest(
                runID: runID,
                dispatchID: pendingDispatch?.id,
                prompt: nativePrompt,
                modelID: command.runtimeAdapter == .nativeAgent
                    ? frozenRoute.canonicalModelSlug : command.executable,
                effort: effort.gatewayReasoningValue,
                contractID: contractID,
                workspaceRoot: command.workingDirectory.path,
                readOnly:
                    command.nativeDevelopmentAccess.isReadOnly
                    || model.permissionPreset == .askFirst
                    || (model.permissionPreset == .configFile
                        && model.sandboxMode == .readOnly),
                permissionPreset: model.permissionPreset),
            onEvent: onEvent)
        if identity == nil {
            model.lastNativeRuntimeStartBlocker =
                "native_runner_start_returned_nil"
        }
        if identity != nil, let pendingDispatch {
            model.activeNativeDevelopmentDispatch = (
                runID: runID,
                contractID: pendingDispatch.contractID,
                dispatchID: pendingDispatch.id,
                modelID: pendingDispatch.modelID)
            model.pendingNativeDevelopmentDispatch = nil
        }
        return identity
    }
}
