import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    private nonisolated static func recoverWorkOSBindingMutationIntent(
        document originalDocument: TatwoNativeChatStoreDocument,
        store: TatwoNativeChatStore,
        intentStore: WorkOSBindingMutationIntentStore,
        scenarioBook: TatwoScenarioConfigBookV1,
        goalStore: TatwoGoalRunStore,
        standaloneWorkspacePath: String
    ) -> ChatWorkOSBindingMutationRecovery {
        let intent: WorkOSBindingMutationIntentV1
        do {
            guard let loaded = try intentStore.load() else {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: false,
                    message: nil)
            }
            intent = loaded
        } catch {
            return ChatWorkOSBindingMutationRecovery(
                document: originalDocument,
                blocked: true,
                message:
                    "Work OS 綁定復原已隔離：durable mutation intent 無法安全讀取。")
        }

        let goal: TatwoStoredGoalRun
        do {
            goal = try goalStore.requireIssuedContract(intent.oldContractID)
        } catch {
            return ChatWorkOSBindingMutationRecovery(
                document: originalDocument,
                blocked: true,
                message:
                    "Work OS 綁定復原已隔離：mutation intent 的 canonical GoalRun 無法驗證。")
        }
        guard goal.contractID == intent.oldContractID,
              goal.goalID == intent.oldGoalID
        else {
            return ChatWorkOSBindingMutationRecovery(
                document: originalDocument,
                blocked: true,
                message:
                    "Work OS 綁定復原已隔離：mutation intent 的 Goal identity 不一致。")
        }
        var document = originalDocument
        let projectIndex = intent.projectID.flatMap { projectID in
            document.projects.firstIndex(where: { $0.id == projectID })
        }
        let thread: TatwoNativeChatThread
        let applyThread: (TatwoNativeChatThread) -> Void
        if let projectID = intent.projectID {
            guard let projectIndex,
                  let threadIndex = document.projects[projectIndex].threads
                    .firstIndex(where: { $0.id == intent.threadID })
            else {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: true,
                    message:
                        "Work OS 綁定復原已隔離：mutation intent 的 project/thread identity 不存在。")
            }
            thread = document.projects[projectIndex].threads[threadIndex]
            applyThread = { updated in
                document.projects[projectIndex].threads[threadIndex] = updated
            }
            guard document.projects[projectIndex].id == projectID else {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: true,
                    message: "Work OS 綁定復原已隔離：project identity 已改變。")
            }
        } else {
            guard let threadIndex = document.threads.firstIndex(where: {
                $0.id == intent.threadID
            }) else {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: true,
                    message:
                        "Work OS 綁定復原已隔離：mutation intent 的 standalone thread 不存在。")
            }
            thread = document.threads[threadIndex]
            applyThread = { updated in
                document.threads[threadIndex] = updated
            }
        }

        if workOSBindingMutationIsCanonicalNativeDevelopmentRouteMaterialization(
            goal,
            intent: intent,
            thread: thread)
        {
            do {
                let projectedContract =
                    try WorkOSFactory.storedContractProjection(
                        contractID: goal.contractID,
                        fallbackMode: goal.mode,
                        fallbackScenarioProfileID: goal.scenario,
                        fallbackObjective: goal.objective,
                        scenarioBook: scenarioBook,
                        store: goalStore)
                guard projectedContract.contractID == goal.contractID,
                      projectedContract.goalID == goal.goalID,
                      projectedContract.mode == .xxl,
                      projectedContract.scenario
                        == TatwoScenarioConfigDefaults
                            .nativeDevelopmentXXLSolOpusScenarioID,
                      projectedContract.routeBindingOverride == nil,
                      try goalStore.verifyIssuedIdentityBindingsIfPresent(
                        contract: projectedContract,
                        record: goal),
                      workOSActivePLGRunProjectionMatchesVerifiedContract(
                        thread.activePLGRunProjection,
                        goal: goal,
                        contract: projectedContract)
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if let invalidation = thread.bindingInvalidation {
                    guard bindingInvalidationMatchesIntentEpisode(
                        invalidation,
                        intent: intent,
                        thread: thread,
                        document: document,
                        predecessorGoal: goal,
                        standaloneWorkspacePath:
                            standaloneWorkspacePath,
                        expectedDesiredLoopsConfigSHA256:
                            TatwoNativeThreadBindingInvalidationV1
                                .loopsConfigSHA256(
                                    intent.desiredLoopsConfig),
                        requiresCurrentLoopsAsPrevious: true)
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var restored = thread
                    restored.bindingInvalidation = nil
                    restored.updatedAt = Date()
                    applyThread(restored)
                    try store.save(document)
                }
                try intentStore.remove(intent)
                return ChatWorkOSBindingMutationRecovery(
                    document: document,
                    blocked: false,
                    message: nil)
            } catch {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: true,
                    message:
                        "Work OS 綁定復原已隔離：原生開發 canonical route materialization 無法安全清理。")
            }
        }

        if workOSBindingMutationPredecessorIsExactlyPlanned(
            goal,
            for: intent)
        {
            do {
                guard normalizedNonEmpty(thread.workOSContractID)
                        == intent.oldContractID,
                      normalizedNonEmpty(thread.workOSGoalID)
                        == intent.oldGoalID
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if let invalidation = thread.bindingInvalidation {
                    guard bindingInvalidationMatchesIntentEpisode(
                        invalidation,
                        intent: intent,
                        thread: thread,
                        document: document,
                        predecessorGoal: goal,
                        standaloneWorkspacePath:
                            standaloneWorkspacePath,
                        expectedDesiredLoopsConfigSHA256:
                            TatwoNativeThreadBindingInvalidationV1
                                .loopsConfigSHA256(
                                    intent.desiredLoopsConfig),
                        requiresCurrentLoopsAsPrevious: true)
                    else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    var restored = thread
                    restored.bindingInvalidation = nil
                    restored.updatedAt = Date()
                    applyThread(restored)
                    try store.save(document)
                }
                try intentStore.remove(intent)
                return ChatWorkOSBindingMutationRecovery(
                    document: document,
                    blocked: false,
                    message: nil)
            } catch {
                return ChatWorkOSBindingMutationRecovery(
                    document: originalDocument,
                    blocked: true,
                    message:
                        "Work OS 綁定復原已隔離：未 commit 的 mutation intent 無法安全清理。")
            }
        }
        guard workOSBindingMutationPredecessorIsExactlySuperseded(
            goal,
            for: intent)
        else {
            return ChatWorkOSBindingMutationRecovery(
                document: originalDocument,
                blocked: true,
                message:
                    "Work OS 綁定復原已隔離：舊 Goal 未符合 superseded-before-dispatch exact gate。")
        }

        let hasOldBinding =
            normalizedNonEmpty(thread.workOSContractID) == intent.oldContractID
            && normalizedNonEmpty(thread.workOSGoalID) == intent.oldGoalID
        let isAlreadyApplied = workOSBindingMutationIntentIsApplied(
            intent,
            in: document,
            predecessorGoal: goal,
            standaloneWorkspacePath: standaloneWorkspacePath)
        guard hasOldBinding || isAlreadyApplied else {
            return ChatWorkOSBindingMutationRecovery(
                document: originalDocument,
                blocked: true,
                message:
                    "Work OS 綁定復原已隔離：target row 已綁定其他 Goal，未做推測清理。")
        }

        let owner = workOSBindingCanonicalOwner(
            thread: thread,
            projectID: intent.projectID,
            document: document,
            standaloneWorkspacePath: standaloneWorkspacePath)
        if hasOldBinding {
            var updated = thread
            if let invalidation = updated.bindingInvalidation {
                guard bindingInvalidationMatchesIntentEpisode(
                        invalidation,
                        intent: intent,
                        thread: updated,
                        document: document,
                        predecessorGoal: goal,
                        standaloneWorkspacePath:
                            standaloneWorkspacePath,
                        expectedDesiredLoopsConfigSHA256:
                            TatwoNativeThreadBindingInvalidationV1
                                .loopsConfigSHA256(
                                    intent.desiredLoopsConfig),
                        requiresCurrentLoopsAsPrevious: true)
                else {
                    return ChatWorkOSBindingMutationRecovery(
                        document: originalDocument,
                        blocked: true,
                        message:
                            "Work OS 綁定復原已隔離：thread invalidation 與 mutation intent 不一致。")
                }
            } else {
                updated.bindingInvalidation =
                    TatwoNativeThreadBindingInvalidationV1(
                        id: intent.id,
                        reason: intent.desiredLoopsConfig == nil
                            ? .contractSuperseded
                            : .loopsConfigChanged,
                        threadID: intent.threadID,
                        projectID: intent.projectID,
                        previousBinding:
                            TatwoNativeThreadBindingIdentityV1(
                                contractID: intent.oldContractID,
                                goalID: intent.oldGoalID,
                                goalRevision: goal.resolvedRevision),
                        previousLoopsConfig: updated.loopsConfig,
                        desiredLoopsConfig:
                            intent.desiredLoopsConfig,
                        authorityProvenance: owner.map {
                            TatwoNativeThreadBindingAuthorityProvenanceV1(
                                provider: $0.provider,
                                externalProviderSessionID:
                                    $0.externalProviderID,
                                workspacePath: $0.workspacePath)
                        })
                updated.updatedAt = Date()
                applyThread(updated)
                do {
                    try store.save(document)
                } catch {
                    return ChatWorkOSBindingMutationRecovery(
                        document: document,
                        blocked: true,
                        message:
                            "舊 Goal 已取消，但 binding invalidation 尚未安全寫入磁碟；已停止清除 Chat 綁定。")
                }
            }
            updated.loopsConfig = intent.desiredLoopsConfig
            updated.workOSContractID = nil
            updated.workOSGoalID = nil
            updated.selectedThreadWorkOSContext = nil
            updated.activePLGRunProjection = nil
            updated.updatedAt = Date()
            applyThread(updated)
            do {
                try store.save(document)
            } catch {
                return ChatWorkOSBindingMutationRecovery(
                    document: document,
                    blocked: true,
                    message:
                        "舊 Goal 已取消，但 Chat 綁定尚未安全寫入磁碟；已停止建立新 Goal。")
            }
        }

        do {
            let sessionStore = TatwoSessionStore(
                directoryURL: goalStore.directoryURL)
            let ownerVerification: TatwoSessionOwnerVerificationV1?
            if let snapshot = try sessionStore.snapshotCurrent() {
                switch snapshot.pointer.schema {
                case "TatwoSessionPointerV1":
                    ownerVerification = nil
                case "TatwoSessionPointerV2":
                    guard let owner else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    ownerVerification = .legacyV2(owner.expectation)
                case "TatwoSessionAuthorityPointerV3":
                    guard let owner else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    ownerVerification = .canonicalV3(owner)
                default:
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else {
                ownerVerification = owner.map {
                    TatwoSessionOwnerVerificationV1.canonicalV3($0)
                }
            }
            _ = try sessionStore.reconcileSupersededTerminalCurrent(
                ownerVerification: ownerVerification,
                expectedContractID: intent.oldContractID,
                expectedGoalID: intent.oldGoalID,
                expectedMode: goal.mode,
                expectedScenario: goal.scenario,
                expectedObjective: goal.objective,
                scenarioBook: scenarioBook,
                goalStore: goalStore)
            guard workOSBindingMutationIntentIsApplied(
                intent,
                in: try store.load(),
                predecessorGoal: goal,
                standaloneWorkspacePath: standaloneWorkspacePath)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try intentStore.remove(intent)
        } catch {
            return ChatWorkOSBindingMutationRecovery(
                document: document,
                blocked: true,
                message:
                    "Chat 綁定已更新，但 superseded pointer／intent 尚未完成 exact cleanup；已停止建立新 Goal。")
        }
        return ChatWorkOSBindingMutationRecovery(
            document: document,
            blocked: false,
            message: "已完成中斷的 Work OS 綁定更新。")
    }

    private nonisolated static func workOSBindingCanonicalOwner(
        thread: TatwoNativeChatThread,
        projectID: UUID?,
        document: TatwoNativeChatStoreDocument,
        standaloneWorkspacePath: String
    ) -> TatwoCanonicalSessionOwnerV1? {
        // Must stay byte-for-byte equivalent to
        // `currentSessionCanonicalOwner(for:projectID:)`; a divergence here
        // silently blocks binding-mutation recovery for the same rows.
        if thread.sourceMarker
            != TatwoNativeChatThreadSourceMarker.codexAppMirror
        {
            if let projectID {
                guard let project = document.projects.first(where: {
                    $0.id == projectID
                }),
                      let projectWorkspace = normalizedWorkspacePath(
                        project.workdir)
                else { return nil }
                return TatwoCanonicalSessionOwnerV1(
                    provider: "tatwo-chat",
                    locator: .thread(thread.id.uuidString.lowercased()),
                    workspacePath: projectWorkspace)
            }
            return TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(thread.id.uuidString.lowercased()),
                workspacePath: standaloneWorkspacePath)
        }
        guard thread.sourceMarker
                == TatwoNativeChatThreadSourceMarker.codexAppMirror,
              isCodexAppMirrorThread(thread),
              let sessionID = normalizedNonEmpty(thread.codexSessionID),
              let workspace = normalizedWorkspacePath(
                thread.mirroredCodexWorkspacePath)
        else { return nil }
        if let projectID {
            guard let project = document.projects.first(where: {
                $0.id == projectID
            }),
                  normalizedWorkspacePath(project.workdir) == workspace
            else { return nil }
        } else {
            guard workspace == standaloneWorkspacePath
            else { return nil }
        }
        return TatwoCanonicalSessionOwnerV1(
            provider: "codex",
            locator: .session(sessionID),
            workspacePath: workspace)
    }

    nonisolated static func workOSBindingMutationIntentIsApplied(
        _ intent: WorkOSBindingMutationIntentV1,
        in document: TatwoNativeChatStoreDocument
    ) -> Bool {
        let thread: TatwoNativeChatThread?
        if let projectID = intent.projectID {
            thread = document.projects
                .first(where: { $0.id == projectID })?
                .threads
                .first(where: { $0.id == intent.threadID })
        } else {
            thread = document.threads.first(where: {
                $0.id == intent.threadID
            })
        }
        guard let thread,
              normalizedNonEmpty(thread.workOSContractID) == nil,
              normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.selectedThreadWorkOSContext == nil,
              thread.activePLGRunProjection == nil,
              thread.loopsConfig == intent.desiredLoopsConfig,
              let invalidation = thread.bindingInvalidation
        else { return false }
        let expectedReason: TatwoNativeThreadBindingInvalidationReasonV1 =
            intent.desiredLoopsConfig == nil
                ? .contractSuperseded
                : .loopsConfigChanged
        return invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1"
            && invalidation.id == intent.id
            && invalidation.reason == expectedReason
            && invalidation.threadID == intent.threadID
            && invalidation.projectID == intent.projectID
            && invalidation.previousBinding.contractID == intent.oldContractID
            && invalidation.previousBinding.goalID == intent.oldGoalID
            && invalidation.expectedSuccessor == nil
            && invalidation.desiredLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1
                    .loopsConfigSHA256(intent.desiredLoopsConfig)
    }

    // Retarget supersession: the picker moved the thread to a different loops
    // config while keeping the same invalidation episode (same id, same
    // previous binding). The durable intent's desired config can never become
    // "applied" after that, and the persisted retargeted invalidation now owns
    // recovery, so the intent is cleared as superseded instead of blocking.
    nonisolated static func workOSBindingMutationIntentIsRetargetSuperseded(
        _ intent: WorkOSBindingMutationIntentV1,
        in document: TatwoNativeChatStoreDocument
    ) -> Bool {
        let thread: TatwoNativeChatThread?
        if let projectID = intent.projectID {
            thread = document.projects
                .first(where: { $0.id == projectID })?
                .threads
                .first(where: { $0.id == intent.threadID })
        } else {
            thread = document.threads.first(where: {
                $0.id == intent.threadID
            })
        }
        guard let thread,
              normalizedNonEmpty(thread.workOSContractID) == nil,
              normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.selectedThreadWorkOSContext == nil,
              thread.activePLGRunProjection == nil,
              let invalidation = thread.bindingInvalidation
        else { return false }
        let intentSHA = TatwoNativeThreadBindingInvalidationV1
            .loopsConfigSHA256(intent.desiredLoopsConfig)
        let threadSHA = TatwoNativeThreadBindingInvalidationV1
            .loopsConfigSHA256(thread.loopsConfig)
        return invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1"
            && invalidation.id == intent.id
            && invalidation.reason == .loopsConfigChanged
            && invalidation.threadID == intent.threadID
            && invalidation.projectID == intent.projectID
            && invalidation.previousBinding.contractID == intent.oldContractID
            && invalidation.previousBinding.goalID == intent.oldGoalID
            && invalidation.expectedSuccessor == nil
            && invalidation.desiredLoopsConfigSHA256 == threadSHA
            && invalidation.desiredLoopsConfigSHA256 != intentSHA
    }

    nonisolated static func workOSBindingMutationIntentIsApplied(
        _ intent: WorkOSBindingMutationIntentV1,
        in document: TatwoNativeChatStoreDocument,
        predecessorGoal: TatwoStoredGoalRun,
        standaloneWorkspacePath: String
    ) -> Bool {
        guard workOSBindingMutationPredecessorIsExactlySuperseded(
            predecessorGoal,
            for: intent)
        else { return false }
        let thread: TatwoNativeChatThread?
        if let projectID = intent.projectID {
            thread = document.projects
                .first(where: { $0.id == projectID })?
                .threads
                .first(where: { $0.id == intent.threadID })
        } else {
            thread = document.threads.first(where: {
                $0.id == intent.threadID
            })
        }
        guard let thread else { return false }
        guard normalizedNonEmpty(thread.workOSContractID) == nil,
              normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.selectedThreadWorkOSContext == nil,
              thread.activePLGRunProjection == nil,
              let invalidation = thread.bindingInvalidation
        else { return false }
        let intentDesiredSHA256 =
            TatwoNativeThreadBindingInvalidationV1
                .loopsConfigSHA256(intent.desiredLoopsConfig)
        if thread.loopsConfig == intent.desiredLoopsConfig,
           bindingInvalidationMatchesIntentEpisode(
                invalidation,
                intent: intent,
                thread: thread,
                document: document,
                predecessorGoal: predecessorGoal,
                standaloneWorkspacePath: standaloneWorkspacePath,
                expectedDesiredLoopsConfigSHA256:
                    intentDesiredSHA256,
                requiresCurrentLoopsAsPrevious: false)
        {
            return true
        }

        guard intent.desiredLoopsConfig != nil,
              let currentLoopsConfigSHA256 =
                TatwoNativeThreadBindingInvalidationV1
                    .loopsConfigSHA256(thread.loopsConfig),
              currentLoopsConfigSHA256 != intentDesiredSHA256
        else { return false }
        return bindingInvalidationMatchesIntentEpisode(
            invalidation,
            intent: intent,
            thread: thread,
            document: document,
            predecessorGoal: predecessorGoal,
            standaloneWorkspacePath: standaloneWorkspacePath,
            expectedDesiredLoopsConfigSHA256:
                currentLoopsConfigSHA256,
            requiresCurrentLoopsAsPrevious: false)
    }

    private nonisolated static func
        workOSBindingMutationIsCanonicalNativeDevelopmentRouteMaterialization(
            _ goal: TatwoStoredGoalRun,
            intent: WorkOSBindingMutationIntentV1,
            thread: TatwoNativeChatThread
        ) -> Bool
    {
        let supportedScenarios = [
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLSolOpusScenarioID,
            TatwoScenarioConfigDefaults
                .nativeDevelopmentXXLFableGrokScenarioID,
        ]
        let scenarioID = goal.scenario
        guard goal.contractID == intent.oldContractID,
              goal.goalID == intent.oldGoalID,
              goal.status == .running,
              goal.mode == .xxl,
              supportedScenarios.contains(scenarioID),
              goal.routeBindingOverride == nil,
              normalizedNonEmpty(thread.workOSContractID)
                == intent.oldContractID,
              normalizedNonEmpty(thread.workOSGoalID)
                == intent.oldGoalID,
              let context = thread.selectedThreadWorkOSContext,
              context.matches(
                TatwoObjectiveIdentity.make(goal.objective)),
              workOSActivePLGRunProjectionMatchesIssuedGoal(
                thread.activePLGRunProjection,
                goal: goal),
              let previous = thread.loopsConfig,
              let desired = intent.desiredLoopsConfig,
              previous.scenarioID == scenarioID,
              desired.scenarioID == scenarioID,
              previous.mode == .xxl,
              desired.mode == .xxl,
              previous.identitySummary == desired.identitySummary,
              previous.tokenBudget == desired.tokenBudget,
              previous.primaryModelID == nil,
              previous.secondaryModelID == nil
        else {
            return false
        }
        let desiredRoute = WorkOSRouteBindingOverride(
            primaryModelID: desired.primaryModelID,
            secondaryModelID: desired.secondaryModelID)
        let expectedRoute =
            scenarioID
                == TatwoScenarioConfigDefaults
                    .nativeDevelopmentXXLFableGrokScenarioID
            ? canonicalFableGrokNativeDevelopmentRouteBinding
            : canonicalNativeDevelopmentRouteBinding
        return desiredRoute == expectedRoute
    }

    private nonisolated static func
        workOSActivePLGRunProjectionMatchesIssuedGoal(
            _ projection: TatwoPLGRun?,
            goal: TatwoStoredGoalRun
        ) -> Bool
    {
        guard let projection else { return true }
        guard projection.contractID == goal.contractID,
              projection.goalID == goal.goalID,
              projection.revision == Int(exactly: goal.resolvedRevision),
              let issuedBindings = goal.issuedIdentityBindings,
              let issuedDigest = goal.issuedIdentityBindingsDigest,
              TatwoIssuedIdentityBindingV1.deterministicDigest(
                for: issuedBindings) == issuedDigest
        else { return false }
        let projectedBindings =
            projection.leadBindings + projection.subBindings
        guard projection.leadBindings.allSatisfy({
                  $0.identity == .lead
              }),
              projection.subBindings.allSatisfy({
                  $0.identity != .lead
              }),
              Set(projectedBindings.map(\.id)).count
                == projectedBindings.count,
              Set(issuedBindings.map(\.id)).count
                == issuedBindings.count,
              projectedBindings.count == issuedBindings.count
        else { return false }
        return projectedBindings.allSatisfy { projected in
            issuedBindings.contains { issued in
                issued.id == projected.id
                    && issued.sourceSlotID == projected.sourceSlotID
                    && issued.identity == projected.identity
                    && issued.modelID == projected.modelID
                    && issued.authority == projected.authority
                    && issued.engineID == projected.engineID
                    && issued.canMutateHost == projected.canMutateHost
            }
        }
    }

    private nonisolated static func
        workOSActivePLGRunProjectionMatchesVerifiedContract(
            _ projection: TatwoPLGRun?,
            goal: TatwoStoredGoalRun,
            contract: TatwoWorkOSContractV1
        ) -> Bool
    {
        guard let projection else { return true }
        guard projection.contractID == goal.contractID,
              projection.goalID == goal.goalID,
              projection.revision == Int(exactly: goal.resolvedRevision)
        else { return false }
        let projectedBindings =
            projection.leadBindings + projection.subBindings
        let contractBindings = contract.identityBindings
        guard projection.leadBindings.allSatisfy({
                  $0.identity == .lead
              }),
              projection.subBindings.allSatisfy({
                  $0.identity != .lead
              }),
              Set(projectedBindings.map(\.id)).count
                == projectedBindings.count,
              Set(contractBindings.map(\.id)).count
                == contractBindings.count,
              projectedBindings.count == contractBindings.count
        else { return false }
        return projectedBindings.allSatisfy { projected in
            guard let verified = contractBindings.first(where: {
                $0.id == projected.id
            }) else { return false }
            if verified == projected {
                return true
            }
            guard TatwoLegacyNativeDevelopmentBindingUpgradePolicy
                    .isGrandfathered(issuedAt: goal.issuedAt)
            else {
                return false
            }
            let legacyNativeToolBridgeSourceSlots: Set<String> = [
                TatwoNativeDevelopmentDispatchCoordinator
                    .solExecutorSourceSlotID,
                TatwoNativeDevelopmentDispatchCoordinator
                    .opusSupervisorSourceSlotID,
            ]
            return legacyNativeToolBridgeSourceSlots.contains(
                    projected.sourceSlotID)
                && verified.sourceSlotID == projected.sourceSlotID
                && verified.identity == projected.identity
                && verified.modelID == projected.modelID
                && verified.engineID == projected.engineID
                && verified.authority == .toolIntentBridge
                && verified.canMutateHost
                && projected.authority == .brainOnly
                && !projected.canMutateHost
        }
    }

    nonisolated static func
        workOSBindingMutationPredecessorIsExactlyPlanned(
            _ goal: TatwoStoredGoalRun,
            for intent: WorkOSBindingMutationIntentV1
        ) -> Bool
    {
        goal.contractID == intent.oldContractID
            && goal.goalID == intent.oldGoalID
            && goal.status == .planned
            && goal.statusReason == nil
            && goal.latestDispatchCycleEpoch == nil
            && goal.latestDispatchCycleSealID == nil
            && workOSBindingMutationHasOnlyActivationReceipt(goal)
    }

    nonisolated static func
        workOSBindingMutationPredecessorIsExactlySuperseded(
            _ goal: TatwoStoredGoalRun,
            for intent: WorkOSBindingMutationIntentV1
        ) -> Bool
    {
        goal.contractID == intent.oldContractID
            && goal.goalID == intent.oldGoalID
            && goal.status == .cancelled
            && goal.statusReason == "superseded_before_dispatch"
            && goal.latestDispatchCycleEpoch == nil
            && goal.latestDispatchCycleSealID == nil
            && workOSBindingMutationHasOnlyActivationReceipt(goal)
    }

    private nonisolated static func
        workOSBindingMutationHasOnlyActivationReceipt(
            _ goal: TatwoStoredGoalRun
        ) -> Bool
    {
        goal.receipts.allSatisfy {
            $0.receiptID == "goal-tracker"
                && $0.kind == "goal_tracker"
        }
    }

    nonisolated static func
        bindingInvalidationMatchesIntentEpisode(
        _ invalidation: TatwoNativeThreadBindingInvalidationV1,
        intent: WorkOSBindingMutationIntentV1,
        thread: TatwoNativeChatThread,
        document: TatwoNativeChatStoreDocument,
        predecessorGoal: TatwoStoredGoalRun,
        standaloneWorkspacePath: String,
        expectedDesiredLoopsConfigSHA256: String?,
        requiresCurrentLoopsAsPrevious: Bool
    ) -> Bool {
        let expectedReason: TatwoNativeThreadBindingInvalidationReasonV1 =
            intent.desiredLoopsConfig == nil
                ? .contractSuperseded
                : .loopsConfigChanged
        let expectedProvenance = workOSBindingCanonicalOwner(
            thread: thread,
            projectID: intent.projectID,
            document: document,
            standaloneWorkspacePath: standaloneWorkspacePath).map {
                TatwoNativeThreadBindingAuthorityProvenanceV1(
                    provider: $0.provider,
                    externalProviderSessionID:
                        $0.externalProviderID,
                    workspacePath: $0.workspacePath)
            }
        return invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1"
            && invalidation.id == intent.id
            && invalidation.reason == expectedReason
            && invalidation.threadID == intent.threadID
            && invalidation.threadID == thread.id
            && invalidation.projectID == intent.projectID
            && invalidation.previousBinding.contractID
                == intent.oldContractID
            && invalidation.previousBinding.goalID == intent.oldGoalID
            && invalidation.previousBinding.goalRevision
                == predecessorGoal.resolvedRevision
            && invalidation.expectedSuccessor == nil
            && invalidation.authorityProvenance == expectedProvenance
            && invalidation.desiredLoopsConfigSHA256
                == expectedDesiredLoopsConfigSHA256
            && (!requiresCurrentLoopsAsPrevious
                || invalidation.previousLoopsConfigSHA256
                    == TatwoNativeThreadBindingInvalidationV1
                        .loopsConfigSHA256(thread.loopsConfig))
    }

    static func cliTabSeed(engine: TatwoNativeCLISessionBook.Engine, workdir: String) -> String {
        let hint: String
        switch engine {
        case .codex: hint = "# 這是 Codex CLI 分頁。輸入 `codex` 啟動（需已登入）。"
        case .claude: hint = "# 這是 Claude CLI 分頁。輸入 `claude` 啟動（需已登入）。"
        case .grok: hint = "# 這是 Grok CLI 分頁。輸入 `grok` 啟動（需已登入）。"
        case .generic: hint = "# 這是通用 Shell 分頁。"
        }
        return "\(hint)\n# workdir: \(workdir)\n"
    }

    func startInitialStoreLoad(
        environment: [String: String],
        hydrationAttempt: UInt64
    ) {
        let store = self.store
        let workOSBindingMutationIntentStore =
            self.workOSBindingMutationIntentStore
        let composerDraftStore = self.composerDraftStore
        let codexAppStateBridge = self.codexAppStateBridge
        let preferenceStore = self.preferenceStore
        let pluginRegistryStore = self.pluginRegistryStore
        let goalRunStore = self.goalRunStore
        let codexMirrorCacheRootURL = self.codexMirrorCacheRootURL
        let barrier = coldStartInitialStoreLoadBarrier
        initialStoreLoadController.start(priority: .userInitiated) {
            do {
                if let barrier {
                    try await barrier()
                }
                return .loaded(try Self.loadInitialStorePayload(
                    environment: environment,
                    store: store,
                    workOSBindingMutationIntentStore:
                        workOSBindingMutationIntentStore,
                    composerDraftStore: composerDraftStore,
                    codexAppStateBridge: codexAppStateBridge,
                    preferenceStore: preferenceStore,
                    pluginRegistryStore: pluginRegistryStore,
                    goalRunStore: goalRunStore,
                    codexMirrorCacheRootURL: codexMirrorCacheRootURL))
            } catch {
                return .failed(TatwoPrivacyRedactor.redacted(
                    error.localizedDescription))
            }
        } apply: { [weak self] outcome in
            self?.applyInitialStoreLoadOutcome(
                outcome,
                environment: environment,
                hydrationAttempt: hydrationAttempt)
        }
    }

    nonisolated static func loadInitialStorePayload(
        environment: [String: String],
        store: TatwoNativeChatStore,
        workOSBindingMutationIntentStore: WorkOSBindingMutationIntentStore,
        composerDraftStore: TatwoChatComposerDraftStore,
        codexAppStateBridge: TatwoCodexAppStateBridge?,
        preferenceStore: TatwoPreferenceStore,
        pluginRegistryStore: TatwoPluginRegistryStore,
        goalRunStore: TatwoGoalRunStore,
        codexMirrorCacheRootURL: URL
    ) throws -> ChatInitialStoreLoadPayload {
        try Task.checkCancellation()
        var localDocument =
            (try? store.load()) ?? TatwoNativeChatStoreDocument()
        var composerDraftsBySessionKey: [String: String] = [:]
        var composerDraftUpdatedAtBySessionKey: [String: Date] = [:]
        var composerDraftAcknowledgedMessageIDBySessionKey: [String: String] = [:]
        var composerDraftPersistenceWarning: String?
        do {
            let draftDocument = try composerDraftStore.load()
            composerDraftsBySessionKey = draftDocument.draftsBySessionKey
            composerDraftUpdatedAtBySessionKey =
                draftDocument.draftUpdatedAtBySessionKey
            composerDraftAcknowledgedMessageIDBySessionKey =
                draftDocument.acknowledgedAcceptedMessageIDBySessionKey
        } catch {
            composerDraftPersistenceWarning =
                "本機草稿檔目前無法安全讀取；既有檔案未被覆寫，請保留視窗後重試。"
        }
        try Task.checkCancellation()
        let unifiedLedgerRead: TatwoUnifiedSessionLedgerReadV1
        if let ledger = store.unifiedLedger, let read = try? ledger.inspect() {
            unifiedLedgerRead = read
        } else {
            unifiedLedgerRead = TatwoUnifiedSessionLedgerReadV1(
                events: [],
                corruptionReceipts: [])
        }
        try Task.checkCancellation()
        let codexMirrorResult: TatwoCodexAppStateBridge.MirrorLoadResult
        if let codexAppStateBridge {
            let externalVolumeOptIn = (try? preferenceStore.load()
                .codexThreadMirrorExternalVolumeOptIn) ?? false
            codexMirrorResult = codexAppStateBridge.loadDocumentOverlayFailSoft(
                externalVolumeOptIn: externalVolumeOptIn,
                cacheRootURL: codexMirrorCacheRootURL)
            if codexAppStateBridge.sourcePaths.requiresExternalVolumeOptIn,
               externalVolumeOptIn,
               codexMirrorResult.status == .unavailable {
                _ = try? preferenceStore
                    .setCodexThreadMirrorExternalVolumeOptIn(false)
            }
        } else {
            codexMirrorResult = TatwoCodexAppStateBridge.MirrorLoadResult(
                document: nil,
                status: .notEnabled)
        }
        try Task.checkCancellation()
        let scenarioConfigBook = TatwoScenarioConfigStore
            .loadDefaultStaging(environment: environment)
            .normalizedForCurrentDefaults()
        let standaloneWorkspacePath =
            Self.safeChatWorkspaceURL().standardizedFileURL.path
        let bindingMutationRecovery =
            Self.recoverWorkOSBindingMutationIntent(
                document: localDocument,
                store: store,
                intentStore: workOSBindingMutationIntentStore,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore,
                standaloneWorkspacePath: standaloneWorkspacePath)
        localDocument = bindingMutationRecovery.document
        let bindingMutationRecoveryIntent:
            WorkOSBindingMutationIntentV1?
        if bindingMutationRecovery.blocked {
            bindingMutationRecoveryIntent =
                try? workOSBindingMutationIntentStore.load()
        } else {
            bindingMutationRecoveryIntent = nil
        }
        try Task.checkCancellation()
        let pluginRegistryBook =
            ((try? pluginRegistryStore.load()) ?? TatwoPluginRegistryBookV1())
            .normalizedForCurrentDefaults()
        try Task.checkCancellation()
        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        let currentSessionPointerPresent = FileManager.default.fileExists(
            atPath: goalRunStore.directoryURL
                .appendingPathComponent(
                    "current-session.json",
                    isDirectory: false)
                .path)
        var verifiedCurrentSession: ChatVerifiedCurrentSessionBundle?
        if let attachment = try? sessionStore.inspectCurrent(
            scenarioBook: scenarioConfigBook,
            goalStore: goalRunStore)
        {
            verifiedCurrentSession = ChatVerifiedCurrentSessionBundle(
                pointer: attachment.pointer,
                contract: attachment.contract,
                goalRecord: attachment.goalRecord)
        }
        try Task.checkCancellation()
        return ChatInitialStoreLoadPayload(
            localDocument: localDocument,
            composerDraftsBySessionKey: composerDraftsBySessionKey,
            composerDraftUpdatedAtBySessionKey:
                composerDraftUpdatedAtBySessionKey,
            composerDraftAcknowledgedMessageIDBySessionKey:
                composerDraftAcknowledgedMessageIDBySessionKey,
            composerDraftPersistenceWarning: composerDraftPersistenceWarning,
            unifiedLedgerRead: unifiedLedgerRead,
            codexMirrorDocument: codexMirrorResult.document,
            codexMirrorStatus: codexMirrorResult.status,
            scenarioConfigBook: scenarioConfigBook,
            pluginRegistryBook: pluginRegistryBook,
            currentSessionPointerPresent: currentSessionPointerPresent,
            verifiedCurrentSession: verifiedCurrentSession,
            workOSBindingMutationRecoveryBlocked:
                bindingMutationRecovery.blocked,
            workOSBindingMutationRecoveryIntent:
                bindingMutationRecoveryIntent,
            workOSBindingMutationRecoveryMessage:
                bindingMutationRecovery.message)
    }

    private func applyInitialStoreLoadOutcome(
        _ outcome: ChatInitialStoreLoadOutcome,
        environment: [String: String],
        hydrationAttempt: UInt64
    ) {
        guard hydrationAttempt == coldStartHydrationAttempt,
              coldStartHydrationState == .loadingStore
        else { return }
        switch outcome {
        case .loaded(let payload):
            isApplyingInitialStorePayload = true
            applyInitialStoreLoad(payload, environment: environment)
            isApplyingInitialStorePayload = false
            finishColdStartHydration(attempt: hydrationAttempt)
        case .failed(let reason):
            failColdStartHydration(
                reason: "initial-store-load-failed:\(reason)",
                attempt: hydrationAttempt)
        }
    }

    func applyInitialStoreLoad(_ payload: ChatInitialStoreLoadPayload, environment: [String: String]) {
        codexMirrorStatus = payload.codexMirrorStatus
        scenarioConfigBook = payload.scenarioConfigBook
        pluginRegistryBook = payload.pluginRegistryBook
        workOSBindingMutationRecoveryBlocked =
            payload.workOSBindingMutationRecoveryBlocked
        workOSBindingMutationRecoveryIntent =
            payload.workOSBindingMutationRecoveryIntent
        if let recoveryMessage = payload.workOSBindingMutationRecoveryMessage {
            selectedWorkOSStateMessage = recoveryMessage
        }
        latestLedgerActivityByThreadID =
            TatwoUnifiedSessionActivityProjection.latestActivityByThreadID(
                from: payload.unifiedLedgerRead.events)
        coworkTemplates = TatwoCoworkTemplateFactory.templates(from: payload.scenarioConfigBook)
        if selectedCoworkTemplateID.flatMap({ selectedID in coworkTemplates.first(where: { $0.id == selectedID }) }) == nil {
            selectedCoworkTemplateID = coworkTemplates.first?.id
        }

        let localDocument = payload.localDocument
        let reconciledDrafts = composerDraftsDiscardingCanonicallyAcceptedRows(
            payload.composerDraftsBySessionKey,
            updatedAtBySessionKey:
                payload.composerDraftUpdatedAtBySessionKey,
            acknowledgedMessageIDBySessionKey:
                payload.composerDraftAcknowledgedMessageIDBySessionKey)
        composerDraftsBySessionKey = reconciledDrafts.drafts
        composerDraftAcknowledgedMessageIDBySessionKey =
            reconciledDrafts.acknowledgedMessageIDs
        composerDraftPersistenceWarning = payload.composerDraftPersistenceWarning
        if reconciledDrafts.didChangeDocument {
            do {
                try composerDraftStore.save(
                    composerDraftsBySessionKey,
                    acknowledgedAcceptedMessageIDBySessionKey:
                        composerDraftAcknowledgedMessageIDBySessionKey)
            } catch {
                composerDraftPersistenceWarning =
                    "已送出的舊草稿已隱藏，但本機草稿檔尚未完成清理；下次儲存會重試。"
            }
        }
        if let codexMirror = payload.codexMirrorDocument {
            // Codex session restore may refresh matching rows and keep
            // projectless standalone chats. It must not invent sidebar
            // projects; only explicit 新增/匯入 may add those.
            let merged = ChatCodexMirrorMerger.merge(
                codexMirror: codexMirror,
                localDocument: localDocument)
            document = GitHubProjectBindingMerger.apply(
                localDocument: localDocument,
                to: merged)
        } else {
            document = localDocument
        }
        migrateLegacyDocumentTranscriptsIfNeeded()
        reconcileColdStartTranscriptOrphans(
            authority: coldStartRunnerAuthoritySnapshot)
        let standalone = document.threads
            .filter { !$0.isArchived }
            .sorted(by: { threadActivityDate($0) > threadActivityDate($1) })
        let projectThreads = document.projects.flatMap { project in
            project.threads
                .filter { !$0.isArchived }
                .map { (project: project, thread: $0) }
        }
        let newestProjectThread = projectThreads.max(by: {
            threadActivityDate($0.thread) < threadActivityDate($1.thread)
        })
        if !restorePersistedDiscussionSelection() {
            if let firstStandalone = standalone.first,
               newestProjectThread == nil
                || threadActivityDate(firstStandalone) >= threadActivityDate(newestProjectThread!.thread) {
                selectStandaloneThread(
                    firstStandalone.id,
                    persistDiscussionSelection: false)
            } else if let newestProjectThread {
                select(
                    projectID: newestProjectThread.project.id,
                    threadID: newestProjectThread.thread.id,
                    persistDiscussionSelection: false)
            } else if let firstProject = document.projects.first,
               let firstThread = firstProject.threads.sorted(by: {
                   threadActivityDate($0) > threadActivityDate($1)
               }).first {
                select(
                    projectID: firstProject.id,
                    threadID: firstThread.id,
                    persistDiscussionSelection: false)
            } else if let firstProject = document.projects.first {
                selectedProjectID = firstProject.id
                workspacePath = firstProject.workdir
            }
        }
        currentSessionPointerPresent = payload.currentSessionPointerPresent
        verifiedCurrentSessionBundle = payload.verifiedCurrentSession
        restoreVerifiedWorkOSSessionIfNeeded()
        applyExportOnlyLoopOverride(environment: environment)
        // Selecting the restored thread intentionally resets foreground-only
        // turn state. Durable cancellation authority is App-global, though,
        // so restore it after selection has finished or a cold-start retry can
        // briefly unlock sending even while an unresolved runner still owns
        // the workspace. Reuse the attempt-bound snapshot to avoid a second
        // authority probe and keep stale hydration attempts unable to mutate
        // the current attempt.
        restoreDurableCancellationLock(
            authority: coldStartRunnerAuthoritySnapshot)
    }

    private func restoreVerifiedWorkOSSessionIfNeeded() {
        guard let bundle = verifiedCurrentSessionBundle,
              verifiedCurrentSessionBundleIsCanonical(bundle),
              let target = verifiedCurrentSessionTarget(bundle),
              let targetThread = thread(
                id: target.threadID,
                projectID: target.projectID)
        else { return }
        let recoverConfirmedGoalRevision =
            confirmedGoalRevisionPredecessorIdentity(
                for: targetThread,
                bundle: bundle) != nil

        if selectedProjectID != target.projectID
            || selectedThreadID != target.threadID
            || selectedDiscussionID != nil {
            if let projectID = target.projectID {
                select(
                    projectID: projectID,
                    threadID: target.threadID,
                    persistDiscussionSelection: false,
                    recoverConfirmedGoalRevision:
                        recoverConfirmedGoalRevision)
            } else {
                selectStandaloneThread(
                    target.threadID,
                    persistDiscussionSelection: false,
                    recoverConfirmedGoalRevision:
                        recoverConfirmedGoalRevision)
            }
        } else if recoverConfirmedGoalRevision {
            _ = refreshAfterGoalRevisionPromotion()
        } else {
            _ = attachVerifiedCurrentSessionToSelectedThreadIfEligible()
        }
    }

    func verifiedCurrentSessionTarget(
        _ bundle: ChatVerifiedCurrentSessionBundle
    ) -> CurrentSessionThreadTarget? {
        if bundle.pointer.schema == "TatwoSessionPointerV2"
            || bundle.pointer.schema == "TatwoSessionAuthorityPointerV3"
        {
            guard let owner = bundle.pointer.ownerBinding else { return nil }
            let matches = allCurrentSessionThreadTargets().filter { target in
                guard let thread = thread(
                    id: target.threadID,
                    projectID: target.projectID),
                      let canonicalOwner = currentSessionCanonicalOwner(
                        for: thread,
                        projectID: target.projectID)
                else { return false }
                if bundle.pointer.schema == "TatwoSessionPointerV2" {
                    return legacyOwnerExpectation(
                        canonicalOwner,
                        matches: owner)
                }
                return currentSessionCanonicalOwner(
                    canonicalOwner,
                    matches: owner)
            }
            guard matches.count == 1,
                  let target = matches.first,
                  let targetThread = thread(
                    id: target.threadID,
                    projectID: target.projectID)
            else { return nil }
            if threadHasExactCurrentSessionBinding(targetThread, bundle: bundle) {
                guard threadCanonicalStateMatchesCurrentSession(
                    targetThread,
                    bundle: bundle)
                else { return nil }
            } else {
                guard threadCanAcceptVerifiedCurrentSession(
                    targetThread,
                    bundle: bundle)
                    || threadCanResumeExactBindingInvalidation(
                        targetThread,
                        projectID: target.projectID,
                        bundle: bundle)
                    || confirmedGoalRevisionPredecessorIdentity(
                        for: targetThread,
                        bundle: bundle) != nil
                else { return nil }
            }
            return target
        }

        guard bundle.pointer.schema == "TatwoSessionPointerV1" else {
            return nil
        }
        let exactTargets = allCurrentSessionThreadTargets().filter { target in
            guard let thread = thread(
                id: target.threadID,
                projectID: target.projectID)
            else { return false }
            return threadHasExactCurrentSessionBinding(
                thread,
                bundle: bundle)
        }
        if exactTargets.count > 1 {
            return nil
        }
        if let exactTarget = exactTargets.first {
            guard let exactThread = thread(
                id: exactTarget.threadID,
                projectID: exactTarget.projectID),
                  threadCanonicalStateMatchesCurrentSession(exactThread, bundle: bundle)
            else { return nil }
            if exactTarget.projectID == nil {
                guard isEligibleTatwoChatWorkspaceMirror(exactThread) else {
                    return nil
                }
            } else {
                guard currentSessionCanonicalOwner(
                    for: exactThread,
                    projectID: exactTarget.projectID) != nil
                else { return nil }
            }
            return exactTarget
        }

        let standaloneCandidates = document.threads
            .filter {
                isEligibleTatwoChatWorkspaceMirror($0)
                    && threadCanAcceptVerifiedCurrentSession($0, bundle: bundle)
            }
            .map {
                CurrentSessionThreadTarget(
                    projectID: nil,
                    threadID: $0.id)
            }
        let projectCandidates = legacyV1ProjectOwnerCandidates(
            bundle: bundle)
        // The pointer has no thread ID. Multiple unbound rows with the same
        // Tatwo chat-workspace cwd or multiple project-owner signals are
        // ambiguous. Choosing the newest row would be a heuristic hijack
        // rather than verified continuity.
        let candidates = standaloneCandidates + projectCandidates
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    @discardableResult
    func refreshVerifiedCurrentSessionBundleFromDisk(
        ownerVerification: TatwoSessionOwnerVerificationV1? = nil
    ) -> Bool {
        let sessionStore = TatwoSessionStore(directoryURL: goalRunStore.directoryURL)
        let pointerFile = goalRunStore.directoryURL
            .appendingPathComponent("current-session.json", isDirectory: false)
        currentSessionPointerPresent = FileManager.default.fileExists(
            atPath: pointerFile.path)
        guard currentSessionPointerPresent else {
            verifiedCurrentSessionBundle = nil
            return false
        }
        guard let attachment = try? sessionStore.attachCurrent(
            ownerVerification: ownerVerification,
            scenarioBook: scenarioConfigBook,
            goalStore: goalRunStore)
        else {
            verifiedCurrentSessionBundle = nil
            return false
        }
        verifiedCurrentSessionBundle = ChatVerifiedCurrentSessionBundle(
            pointer: attachment.pointer,
            contract: attachment.contract,
            goalRecord: attachment.goalRecord)
        return true
    }

    @discardableResult
    func inspectCurrentSessionBundleFromDisk() -> Bool {
        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        let pointerFile = goalRunStore.directoryURL
            .appendingPathComponent("current-session.json", isDirectory: false)
        currentSessionPointerPresent = FileManager.default.fileExists(
            atPath: pointerFile.path)
        guard currentSessionPointerPresent else {
            verifiedCurrentSessionBundle = nil
            return false
        }
        guard let attachment = try? sessionStore.inspectCurrent(
            scenarioBook: scenarioConfigBook,
            goalStore: goalRunStore)
        else {
            verifiedCurrentSessionBundle = nil
            return false
        }
        verifiedCurrentSessionBundle = ChatVerifiedCurrentSessionBundle(
            pointer: attachment.pointer,
            contract: attachment.contract,
            goalRecord: attachment.goalRecord)
        return true
    }
}
