import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers
import Darwin
import TatwoUltraworkCore
import TatwoWorkReceiptContracts

extension ChatPageModel {

    /// Explicit collaboration activation may reclaim a stale pointer only when
    /// its exact canonical GoalRun is already terminal and it resolves uniquely
    /// to the selected Codex-mirror row. Ordinary Chat never enters this path,
    /// and `.succeeded` remains attached awaiting Goal Judge rather than being
    /// treated as reclaimable terminal state.
    func recoverTerminalCurrentSessionForExplicitActivation(
        thread: TatwoNativeChatThread,
        projectID: UUID?,
        canonicalOwner: TatwoCanonicalSessionOwnerV1?
    ) -> ExplicitTerminalCurrentSessionRecoveryResult {
        guard selectedDiscussionID == nil,
              let location = selectedThreadLocation(),
              self.thread(at: location).id == thread.id
        else {
            return .notApplicable
        }

        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        let snapshot: TatwoSessionPointerSnapshotV1
        do {
            guard let currentSnapshot = try sessionStore.snapshotCurrent() else {
                currentSessionPointerPresent = false
                verifiedCurrentSessionBundle = nil
                return .notApplicable
            }
            snapshot = currentSnapshot
        } catch {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：explicit activation 無法讀取 current-session exact revision。")
            return .quarantined
        }

        let ownerVerification: TatwoSessionOwnerVerificationV1?
        switch snapshot.pointer.schema {
        case "TatwoSessionPointerV1":
            ownerVerification = nil
        case "TatwoSessionPointerV2":
            guard let canonicalOwner else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V2 terminal current-session 缺少 selected row owner 證據。")
                return .quarantined
            }
            ownerVerification = .legacyV2(canonicalOwner.expectation)
        case "TatwoSessionAuthorityPointerV3":
            guard let canonicalOwner else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V3 terminal current-session 缺少 selected row canonical owner 證據。")
                return .quarantined
            }
            ownerVerification = .canonicalV3(canonicalOwner)
        default:
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：terminal current-session schema 不受支援。")
            return .quarantined
        }

        let terminalAttachment: TatwoSessionAttachmentV1
        do {
            guard let inspected = try sessionStore.inspectCurrent(
                ownerVerification: ownerVerification,
                expectedContractID: snapshot.pointer.contractID,
                expectedGoalID: snapshot.pointer.goalID,
                expectedMode: snapshot.pointer.mode,
                expectedScenario: snapshot.pointer.scenario,
                expectedObjective: snapshot.pointer.objective,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore)
            else {
                return .notApplicable
            }
            terminalAttachment = inspected
        } catch TatwoSessionAttachmentError.terminalGoalRun {
            // `inspectCurrent` deliberately permits terminal records, so this
            // remains fail-closed if its contract changes.
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：terminal current-session inspection contract 不一致。")
            return .quarantined
        } catch {
            // A valid active pointer is not a recovery candidate; let the normal
            // attach path handle it. Invalid/mismatched pointers stay isolated.
            if (try? sessionStore.attachCurrent(
                ownerVerification: ownerVerification,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore)) != nil
            {
                return .notApplicable
            }
            // 2026-08-21「每對話一 session」補洞：/plg、/goal 的明確啟動
            // 走這條 recovery 檢查，比 attach 旁路更早——指標屬於另一個
            // 真實存在的 Chat row 時，這不是本列的事故，放行讓本列自建
            // 自己的 Goal（親測抓到：新 thread 確認計劃→PLG 在此被誤隔離）。
            if let pointerOwner = snapshot.pointer.ownerBinding,
               currentSessionPointerIsOwnedByAnExistingOtherThread(
                   pointerOwner: pointerOwner,
                   excluding: thread.id)
            {
                return .notApplicable
            }
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：explicit activation 無法驗證 terminal current-session。")
            return .quarantined
        }

        switch terminalAttachment.goalRecord.status {
        case .failed, .cancelled, .passed, .rollbackRequired:
            break
        case .superseded:
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：current-session 指向已由新版取代的 Goal；必須先完成 revision promotion reconciliation。")
            return .quarantined
        case .planned, .dispatching, .running, .succeeded, .humanGate,
             .awaitingNextCycle, .blocked:
            return .notApplicable
        }

        let terminalBundle = ChatVerifiedCurrentSessionBundle(
            pointer: terminalAttachment.pointer,
            contract: terminalAttachment.contract,
            goalRecord: terminalAttachment.goalRecord)
        guard verifiedCurrentSessionBundleIsCanonical(terminalBundle),
              let target = verifiedCurrentSessionTarget(terminalBundle),
              target.projectID == projectID,
              target.threadID == thread.id
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：terminal current-session 無法唯一對應 selected Codex mirror row。")
            return .quarantined
        }

        var currentThread = self.thread(at: location)
        let rowContractID = Self.normalizedNonEmpty(
            currentThread.workOSContractID)
        let rowGoalID = Self.normalizedNonEmpty(currentThread.workOSGoalID)
        let rowIsUnbound =
            rowContractID == nil
            && rowGoalID == nil
            && currentThread.selectedThreadWorkOSContext == nil
            && currentThread.activePLGRunProjection == nil
        let rowBindsTerminalGoal =
            rowContractID == terminalAttachment.contract.contractID
            && rowGoalID == terminalAttachment.contract.goalID
        guard rowIsUnbound || rowBindsTerminalGoal else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：selected row 綁定其他 Goal，未回收 terminal pointer。")
            return .quarantined
        }

        do {
            _ = try sessionStore.compareAndClearCurrent(
                snapshot: snapshot,
                ownerVerification: ownerVerification,
                expectedContractID: terminalAttachment.contract.contractID,
                expectedGoalID: terminalAttachment.contract.goalID,
                expectedMode: terminalAttachment.contract.mode,
                expectedScenario: terminalAttachment.contract.scenario,
                expectedObjective: terminalAttachment.contract.objective,
                scenarioBook: scenarioConfigBook,
                goalStore: goalRunStore)
        } catch {
            refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification: ownerVerification)
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：terminal pointer exact CAS 失敗，未建立替代 Goal。")
            return .quarantined
        }

        currentSessionPointerPresent = false
        verifiedCurrentSessionBundle = nil
        if rowBindsTerminalGoal {
            currentThread.workOSGoalID = nil
            currentThread.workOSContractID = nil
            currentThread.selectedThreadWorkOSContext = nil
            currentThread.activePLGRunProjection = nil
            currentThread.updatedAt = Date()
            replaceThread(currentThread, at: location)
            publishDocumentChangeAndPersist()
        }
        selectedWorkOSContract = nil
        selectedGoalRecord = nil
        selectedDispatchRecords = []
        activePLGRun = nil
        appliedPLGEventIDs = []
        plgAuthorityState = .none
        selectedWorkOSStateMessage =
            "已回收 terminal Work OS pointer；explicit activation 將建立新 Goal revision。"
        return .recovered
    }

    @discardableResult
    func attachVerifiedCurrentSessionToSelectedThreadIfEligible(
        allowLegacyV1OwnerMigration: Bool = false,
        rebindPolicy: CurrentSessionRebindPolicy = .ordinary
    )
        -> CurrentSessionAttachResult
    {
        guard selectedDiscussionID == nil,
              let location = selectedThreadLocation()
        else { return .notApplicable }

        var thread = thread(at: location)
        let sessionStore = TatwoSessionStore(
            directoryURL: goalRunStore.directoryURL)
        let projectID: UUID?
        switch location {
        case .standalone:
            projectID = nil
        case .project(let projectIndex, _):
            projectID = document.projects[projectIndex].id
        }
        let isCodexMirror =
            thread.sourceMarker
                == TatwoNativeChatThreadSourceMarker.codexAppMirror
            && Self.isCodexAppMirrorThread(thread)
        let isDedicatedStandaloneChat =
            projectID == nil
            && !isCodexMirror
            && (
                thread.loopsConfig != nil
                    || Self.normalizedNonEmpty(
                        thread.workOSContractID) != nil
                    || Self.normalizedNonEmpty(
                        thread.workOSGoalID) != nil
                    || thread.selectedThreadWorkOSContext != nil
                    || thread.activePLGRunProjection != nil
                    || thread.bindingInvalidation != nil
            )
        guard isCodexMirror || isDedicatedStandaloneChat else {
            return .notApplicable
        }

        inspectCurrentSessionBundleFromDisk()
        guard let bundle = verifiedCurrentSessionBundle,
              verifiedCurrentSessionBundleIsCanonical(bundle)
        else {
            if currentSessionPointerPresent {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：current-session 存在但 canonical GoalRun 驗證失敗，未建立新 Goal。")
                return .quarantined
            }
            return .notApplicable
        }

        // 2026-08-21 使用者裁決：每個對話各自一個 Work OS session。
        //
        // 關鍵在於分辨兩種「owner 對不上」：
        //   (a) 指標確實屬於**另一個真實存在的 Chat row** → 良性，這一列
        //       只是還沒有自己的 session，放行讓它自建。
        //   (b) 指標誰都不屬於（owner 欄位被竄改／損毀成孤兒）→ 真事故，
        //       維持原本的 fail-closed 隔離。
        // 只用「對不上我」當判準會把 (b) 誤放，所以這裡實際去比對所有
        // Chat row，確認有「別人」擁有它才放行。
        if let pointerOwner = bundle.pointer.ownerBinding,
           let canonicalOwner = currentSessionCanonicalOwner(
            for: thread,
            projectID: projectID),
           !currentSessionCanonicalOwner(canonicalOwner, matches: pointerOwner),
           !legacyOwnerExpectation(canonicalOwner, matches: pointerOwner),
           currentSessionPointerIsOwnedByAnExistingOtherThread(
            pointerOwner: pointerOwner,
            excluding: thread.id)
        {
            return .ownedByAnotherThread
        }

        switch bundle.pointer.schema {
        case "TatwoSessionPointerV1":
            if projectID == nil {
                guard isEligibleTatwoChatWorkspaceMirror(thread) else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：legacy V1 current-session 沒有 dedicated Chat owner，未猜測綁定。")
                    return .quarantined
                }
                guard refreshVerifiedCurrentSessionBundleFromDisk(),
                      verifiedCurrentSessionBundle?.pointer.schema
                        == "TatwoSessionPointerV1"
                else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：legacy V1 current-session 無法完成 unowned attach。")
                    return .quarantined
                }
            } else {
                guard allowLegacyV1OwnerMigration else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：legacy V1 current-session 尚未綁定 project owner；請用明確 $tatwo-ultrawork 指令授權一次性 CAS migration。")
                    return .quarantined
                }
                guard let canonicalOwner = currentSessionCanonicalOwner(
                    for: thread,
                    projectID: projectID)
                else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：selected project mirror 缺少可驗證的 provider／session／workspace owner。")
                    return .quarantined
                }
                let candidates = legacyV1ProjectOwnerCandidates(
                    bundle: bundle,
                    rebindPolicy: rebindPolicy)
                guard candidates.count == 1,
                      candidates.first?.projectID == projectID,
                      candidates.first?.threadID == thread.id
                else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：V1 current-session 對應零個或多個 project owner candidates。")
                    return .quarantined
                }
                do {
                    guard let snapshot = try sessionStore.snapshotCurrent(),
                          snapshot.pointer == bundle.pointer
                    else {
                        quarantineSelectedWorkOSState(
                            "Work OS continuity 已隔離：V1 current-session 在 owner migration 前已改變。")
                        return .quarantined
                    }
                    _ = try sessionStore.migrateCurrentV1Owner(
                        snapshot: snapshot,
                        legacyOwnerExpectation: canonicalOwner.expectation)
                } catch {
                    guard refreshVerifiedCurrentSessionBundleFromDisk(
                        ownerVerification:
                            .legacyV2(canonicalOwner.expectation)),
                          let concurrentWinner =
                            verifiedCurrentSessionBundle,
                          concurrentWinner.pointer.schema
                            == "TatwoSessionPointerV2",
                          verifiedCurrentSessionBundleIsCanonical(
                            concurrentWinner)
                    else {
                        quarantineSelectedWorkOSState(
                            "Work OS continuity 已隔離：V1 owner migration CAS 失敗，且其他程序的 winner 無法通過相同 owner 驗證。")
                        return .quarantined
                    }
                }
                guard refreshVerifiedCurrentSessionBundleFromDisk(
                    ownerVerification:
                        .legacyV2(canonicalOwner.expectation)),
                      let migratedBundle = verifiedCurrentSessionBundle,
                      migratedBundle.pointer.schema
                        == "TatwoSessionPointerV2",
                      verifiedCurrentSessionBundleIsCanonical(
                        migratedBundle)
                else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：V1 owner migration 後無法重新驗證 canonical session。")
                    return .quarantined
                }
            }
        case "TatwoSessionPointerV2":
            guard let canonicalOwner = currentSessionCanonicalOwner(
                for: thread,
                projectID: projectID)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：selected Chat row 缺少可驗證的 provider／session／workspace owner。")
                return .quarantined
            }
            guard refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification:
                    .legacyV2(canonicalOwner.expectation)),
                  let directlyVerifiedBundle =
                    verifiedCurrentSessionBundle,
                  verifiedCurrentSessionBundleIsCanonical(
                    directlyVerifiedBundle)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V2 owner 與 selected Chat row 不一致。")
                return .quarantined
            }
            let ownerMatches = allCurrentSessionThreadTargets().filter { target in
                guard let candidate = self.thread(
                    id: target.threadID,
                    projectID: target.projectID),
                      let candidateOwner = currentSessionCanonicalOwner(
                        for: candidate,
                        projectID: target.projectID),
                      let owner = bundle.pointer.ownerBinding
                else { return false }
                return legacyOwnerExpectation(
                    candidateOwner,
                    matches: owner)
            }
            guard ownerMatches.count == 1,
                  ownerMatches.first?.projectID == projectID,
                  ownerMatches.first?.threadID == thread.id
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V2 owner 對應零個或多個 Chat rows。")
                return .quarantined
            }
        case "TatwoSessionAuthorityPointerV3":
            guard let canonicalOwner = currentSessionCanonicalOwner(
                for: thread,
                projectID: projectID)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：selected Chat row 缺少 canonical session/thread owner。")
                return .quarantined
            }
            guard refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification: .canonicalV3(canonicalOwner)),
                  let directlyVerifiedBundle =
                    verifiedCurrentSessionBundle,
                  verifiedCurrentSessionBundleIsCanonical(
                    directlyVerifiedBundle)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V3 canonical owner kind 與 selected Chat row 不一致。")
                return .quarantined
            }
            let ownerMatches = allCurrentSessionThreadTargets().filter { target in
                guard let candidate = self.thread(
                    id: target.threadID,
                    projectID: target.projectID),
                      let candidateOwner = currentSessionCanonicalOwner(
                        for: candidate,
                        projectID: target.projectID),
                      let owner = bundle.pointer.ownerBinding
                else { return false }
                return currentSessionCanonicalOwner(
                    candidateOwner,
                    matches: owner)
            }
            guard ownerMatches.count == 1,
                  ownerMatches.first?.projectID == projectID,
                  ownerMatches.first?.threadID == thread.id
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：V3 canonical owner 對應零個或多個 Chat rows。")
                return .quarantined
            }
        default:
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：current-session schema 不受支援。")
            return .quarantined
        }

        guard let bundle = verifiedCurrentSessionBundle,
              verifiedCurrentSessionBundleIsCanonical(bundle)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：current-session canonical bundle 驗證失敗。")
            return .quarantined
        }
        if thread.bindingInvalidation != nil {
            guard prepareBindingInvalidationForExactSuccessor(
                thread: &thread,
                at: location,
                projectID: projectID,
                bundle: bundle)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：durable binding invalidation 與 current-session successor 不一致。")
                return .quarantined
            }
        }
        let allThreads = document.threads + document.projects.flatMap(\.threads)
        let exactBoundIDs = allThreads
            .filter { threadHasExactCurrentSessionBinding($0, bundle: bundle) }
            .map(\.id)
        guard exactBoundIDs.count <= 1,
              exactBoundIDs.first == nil || exactBoundIDs.first == thread.id
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：current-session 已綁定其他 Tatwo chat-workspace row。")
            return .quarantined
        }

        if threadHasExactCurrentSessionBinding(thread, bundle: bundle) {
            guard threadCanonicalStateMatchesCurrentSession(thread, bundle: bundle) else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：thread 與 current-session 的 canonical metadata 不一致。")
                return .quarantined
            }
            guard let dispatchRecords = verifiedCurrentSessionDispatchRecords(bundle) else {
                return .quarantined
            }
            if thread.loopsConfig == nil {
                thread.loopsConfig = loopsConfig(
                    materializing: bundle.contract)
                thread.updatedAt = Date()
                replaceThread(thread, at: location)
                guard publishDocumentChangeAndPersist() else {
                    quarantineSelectedWorkOSState(
                        "Work OS continuity 已隔離：Goal 已驗證，但協作拓撲修復尚未安全寫入 thread。")
                    return .quarantined
                }
            }
            applyVerifiedCurrentSessionState(
                bundle,
                thread: thread,
                dispatchRecords: dispatchRecords)
            return .attached
        }

        if bundle.pointer.schema == "TatwoSessionPointerV1" {
            let eligibleCandidateIDs = document.threads
                .filter {
                    isEligibleTatwoChatWorkspaceMirror($0)
                        && (
                            threadCanAcceptVerifiedCurrentSession(
                                $0,
                                bundle: bundle)
                            || threadHasExactBindingInvalidation(
                                $0,
                                projectID: nil,
                                bundle: bundle)
                            || threadIsExactConfirmedRevisionPredecessor(
                                $0,
                                bundle: bundle,
                                expected: rebindPolicy
                                    .expectedRevisionPredecessor)
                        )
                }
                .map(\.id)
            guard eligibleCandidateIDs.count == 1,
                  eligibleCandidateIDs.first == thread.id
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：多個 Tatwo chat-workspace rows 無法判定 current-session 所屬 thread。")
                return .quarantined
            }
        }

        guard threadCanAcceptVerifiedCurrentSession(thread, bundle: bundle)
                || threadHasExactBindingInvalidation(
                    thread,
                    projectID: projectID,
                    bundle: bundle)
                || (
                    rebindPolicy.isConfirmedGoalRevision
                    && threadIsExactConfirmedRevisionPredecessor(
                        thread,
                        bundle: bundle,
                        expected: rebindPolicy
                            .expectedRevisionPredecessor)
                )
                || (
                    !rebindPolicy.isConfirmedGoalRevision
                    &&
                    projectID != nil
                    && threadHasReplaceableStaleWorkOSProjection(
                        thread,
                        bundle: bundle)
                )
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Tatwo chat-workspace row 已有衝突綁定，未修改原值。")
            return .quarantined
        }
        guard let dispatchRecords = verifiedCurrentSessionDispatchRecords(bundle) else {
            return .quarantined
        }
        if thread.bindingInvalidation != nil {
            guard refreshVerifiedCurrentSessionBundleFromDisk(
                    ownerVerification: currentSessionOwnerVerification(
                        for: thread,
                        projectID: projectID,
                        pointerSchema: bundle.pointer.schema)),
                  let currentBundle = verifiedCurrentSessionBundle,
                  exactBindingIdentity(currentBundle)
                    == exactBindingIdentity(bundle),
                  threadHasExactBindingInvalidation(
                    thread,
                    projectID: projectID,
                    bundle: currentBundle)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：Goal revision 在 successor commit 前改變。")
                return .quarantined
            }
        }

        let originalThread = thread
        let contract = bundle.contract
        thread.loopsConfig = loopsConfig(materializing: contract)
        thread.workOSGoalID = contract.goalID
        thread.workOSContractID = contract.contractID
        thread.selectedThreadWorkOSContext = TatwoStoredObjectiveContextV2(
            identity: TatwoObjectiveIdentity.make(contract.objective))
        if thread.activePLGRunProjection?.contractID != contract.contractID {
            thread.activePLGRunProjection = nil
        }
        thread.bindingInvalidation = nil
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            replaceThread(originalThread, at: location)
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：canonical Goal 已驗證，但 dedicated Chat 綁定尚未安全寫入磁碟。")
            return .quarantined
        }

        applyVerifiedCurrentSessionState(
            bundle,
            thread: thread,
            dispatchRecords: dispatchRecords)
        return .attached
    }

    /// Rebind the existing selected Codex-mirror row after the App has
    /// completed an exact Goal revision promotion. This never creates a chat
    /// session. It cold-reads current-session again, permits only the selected
    /// row's exact superseded predecessor binding to be replaced, and reuses
    /// the same canonical attach/apply path as ordinary reconnect.
    @discardableResult
    func refreshAfterGoalRevisionPromotion() -> Bool {
        guard let location = selectedThreadLocation(),
              var thread = selectedThread
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision promotion 後沒有 selected thread。")
            return false
        }
        let boundContractID = Self.normalizedNonEmpty(
            thread.workOSContractID)
        let boundGoalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        guard let boundContractID, let boundGoalID else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision promotion 只允許 exact predecessor rebind；selected thread 未綁定 predecessor。")
            return false
        }
        let expectedPredecessor = WorkOSBindingIdentity(
            contractID: boundContractID,
            goalID: boundGoalID)
        inspectCurrentSessionBundleFromDisk()
        guard let successorBundle = verifiedCurrentSessionBundle,
              verifiedCurrentSessionBundleIsCanonical(successorBundle),
              threadIsExactConfirmedRevisionPredecessor(
                thread,
                bundle: successorBundle,
                expected: expectedPredecessor)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision successor 與 exact predecessor 關係無法驗證。")
            return false
        }
        let successorOwnerVerification = currentSessionOwnerVerification(
            for: thread,
            projectID: projectID(for: location),
            pointerSchema: successorBundle.pointer.schema)
        guard refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification: successorOwnerVerification),
              let attachedSuccessor = verifiedCurrentSessionBundle,
              exactBindingIdentity(attachedSuccessor)
                == exactBindingIdentity(successorBundle)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision successor owner 無法通過 schema-aware attach。")
            return false
        }
        let successorIdentity = TatwoNativeThreadBindingIdentityV1(
            contractID: successorBundle.contract.contractID,
            goalID: successorBundle.contract.goalID,
            goalRevision: successorBundle.goalRecord.resolvedRevision)
        let successorConfig = loopsConfig(
            materializing: successorBundle.contract)
        do {
            let invalidation = try makeThreadBindingInvalidation(
                reason: .goalRevisionChanged,
                for: thread,
                at: location,
                oldContractID: boundContractID,
                oldGoalID: boundGoalID,
                desiredLoopsConfig: successorConfig,
                expectedSuccessor: successorIdentity)
            guard persistThreadBindingInvalidation(
                invalidation,
                for: &thread,
                at: location)
            else {
                quarantineSelectedWorkOSState(
                    "Work OS continuity 已隔離：Goal revision invalidation 尚未安全寫入磁碟。")
                return false
            }
        } catch {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision invalidation 無法建立。")
            return false
        }
        guard refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification: successorOwnerVerification),
              let reverifiedBundle = verifiedCurrentSessionBundle,
              TatwoNativeThreadBindingIdentityV1(
                contractID: reverifiedBundle.contract.contractID,
                goalID: reverifiedBundle.contract.goalID,
                goalRevision:
                    reverifiedBundle.goalRecord.resolvedRevision)
                == successorIdentity
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision 在 predecessor clear 前改變。")
            return false
        }

        let beforeClear = thread
        thread.loopsConfig = successorConfig
        thread.workOSGoalID = nil
        thread.workOSContractID = nil
        thread.selectedThreadWorkOSContext = nil
        thread.activePLGRunProjection = nil
        thread.updatedAt = Date()
        replaceThread(thread, at: location)
        guard publishDocumentChangeAndPersist() else {
            replaceThread(beforeClear, at: location)
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision predecessor 尚未安全清除。")
            return false
        }
        let result = attachVerifiedCurrentSessionToSelectedThreadIfEligible(
            allowLegacyV1OwnerMigration: true,
            rebindPolicy: .confirmedGoalRevision(
                expectedPredecessor: expectedPredecessor))
        switch result {
        case .attached:
            return true
        case .quarantined:
            return false
        case .notApplicable:
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision promotion 後 selected thread 不符合既有 canonical attach 條件。")
            return false
        case .ownedByAnotherThread:
            // 「各自一個 session」放行的是**尚未持有 session 的新對話**。
            // Goal revision promotion 不同：後繼 session 本來就該屬於這一
            // 列，指標卻指向別人＝真正的完整性事故，維持 fail-closed。
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Goal revision promotion 後的 current-session 屬於其他 Chat row。")
            return false
        }
    }

    private func verifiedCurrentSessionDispatchRecords(
        _ bundle: ChatVerifiedCurrentSessionBundle
    ) -> [TatwoDispatchRecord]? {
        do {
            return try dispatchRegistry.latestRecordsByBinding(
                forContractID: bundle.contract.contractID)
        } catch {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：dispatch ledger 無法驗證，未以空清單取代。"
            )
            return nil
        }
    }

    private func applyVerifiedCurrentSessionState(
        _ bundle: ChatVerifiedCurrentSessionBundle,
        thread: TatwoNativeChatThread,
        dispatchRecords: [TatwoDispatchRecord]
    ) {
        selectedWorkOSStateLoadTask?.cancel()
        selectedWorkOSContract = bundle.contract
        selectedGoalRecord = bundle.goalRecord
        selectedDispatchRecords = dispatchRecords
        selectedWorkOSStateMessage =
            "已接回目前 Work OS session · \(bundle.contract.mode.rawValue) · \(bundle.contract.scenario)"
        restoreActivePLGProjection(from: thread)
    }

    func verifiedCurrentSessionBundleIsCanonical(
        _ bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        let objectiveHash = TatwoObjectiveIdentity.make(bundle.contract.objective).objectiveHash
        return bundle.pointer.contractID == bundle.contract.contractID
            && bundle.pointer.goalID == bundle.contract.goalID
            && bundle.pointer.mode == bundle.contract.mode
            && bundle.pointer.scenario == bundle.contract.scenario
            && TatwoObjectiveIdentity.make(bundle.pointer.objective).objectiveHash == objectiveHash
            && bundle.goalRecord.contractID == bundle.contract.contractID
            && bundle.goalRecord.goalID == bundle.contract.goalID
            && bundle.goalRecord.mode == bundle.contract.mode
            && bundle.goalRecord.scenario == bundle.contract.scenario
            && TatwoObjectiveIdentity.make(bundle.goalRecord.objective).objectiveHash == objectiveHash
            && bundle.goalRecord.routeBindingOverride == bundle.contract.routeBindingOverride
    }

    func threadHasExactCurrentSessionBinding(
        _ thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        Self.normalizedNonEmpty(thread.workOSContractID) == bundle.contract.contractID
            && Self.normalizedNonEmpty(thread.workOSGoalID) == bundle.contract.goalID
    }

    func threadCanonicalStateMatchesCurrentSession(
        _ thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard threadHasExactCurrentSessionBinding(thread, bundle: bundle),
              thread.selectedThreadWorkOSContext?.matches(
                TatwoObjectiveIdentity.make(bundle.contract.objective)) == true
        else { return false }
        return threadLoopsConfigMatches(
            thread.loopsConfig,
            contract: bundle.contract)
    }

    func exactBindingIdentity(
        _ bundle: ChatVerifiedCurrentSessionBundle
    ) -> TatwoNativeThreadBindingIdentityV1 {
        TatwoNativeThreadBindingIdentityV1(
            contractID: bundle.contract.contractID,
            goalID: bundle.contract.goalID,
            goalRevision: bundle.goalRecord.resolvedRevision)
    }

    private func invalidationDesiredLoopsConfigMatchesExactSuccessor(
        _ invalidation: TatwoNativeThreadBindingInvalidationV1,
        thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        switch invalidation.reason {
        case .loopsConfigChanged:
            guard let loopsConfig = thread.loopsConfig else { return false }
            return invalidation.desiredLoopsConfigSHA256
                    == TatwoNativeThreadBindingInvalidationV1
                        .loopsConfigSHA256(loopsConfig)
                && threadLoopsConfigMatches(
                    loopsConfig,
                    contract: bundle.contract)
        case .goalRevisionChanged:
            return invalidation.desiredLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1.loopsConfigSHA256(
                    loopsConfig(materializing: bundle.contract))
        case .contractSuperseded:
            return invalidation.desiredLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1.loopsConfigSHA256(
                    thread.loopsConfig)
        }
    }

    func prepareBindingInvalidationForExactSuccessor(
        thread: inout TatwoNativeChatThread,
        at location: ThreadLocation,
        projectID: UUID?,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard var invalidation = thread.bindingInvalidation,
              invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1",
              invalidation.threadID == thread.id,
              invalidation.projectID == projectID,
              invalidation.authorityProvenance
                == bindingAuthorityProvenance(
                    for: thread,
                    projectID: projectID)
        else { return false }

        let successor = exactBindingIdentity(bundle)
        let successorConfig = loopsConfig(materializing: bundle.contract)
        guard invalidationDesiredLoopsConfigMatchesExactSuccessor(
                invalidation,
                thread: thread,
                bundle: bundle),
              invalidationPredecessorIsCanonical(
                invalidation,
                successor: successor)
        else { return false }

        if let expected = invalidation.expectedSuccessor {
            guard expected == successor else { return false }
        } else {
            guard invalidation.reason != .goalRevisionChanged else {
                return false
            }
            invalidation = invalidation.expectingSuccessor(successor)
            guard persistThreadBindingInvalidation(
                invalidation,
                for: &thread,
                at: location),
                  refreshVerifiedCurrentSessionBundleFromDisk(
                    ownerVerification: currentSessionOwnerVerification(
                        for: thread,
                        projectID: projectID,
                        pointerSchema: bundle.pointer.schema)),
                  let refreshed = verifiedCurrentSessionBundle,
                  exactBindingIdentity(refreshed) == successor
            else { return false }
        }

        let hasPreviousBinding =
            Self.normalizedNonEmpty(thread.workOSContractID)
                == invalidation.previousBinding.contractID
            && Self.normalizedNonEmpty(thread.workOSGoalID)
                == invalidation.previousBinding.goalID
        if hasPreviousBinding {
            guard invalidation.previousLoopsConfigSHA256
                    == TatwoNativeThreadBindingInvalidationV1
                        .loopsConfigSHA256(thread.loopsConfig)
            else { return false }
            let original = thread
            switch invalidation.reason {
            case .loopsConfigChanged, .goalRevisionChanged:
                thread.loopsConfig = successorConfig
            case .contractSuperseded:
                break
            }
            thread.workOSGoalID = nil
            thread.workOSContractID = nil
            thread.selectedThreadWorkOSContext = nil
            thread.activePLGRunProjection = nil
            thread.updatedAt = Date()
            replaceThread(thread, at: location)
            guard publishDocumentChangeAndPersist() else {
                thread = original
                replaceThread(original, at: location)
                return false
            }
        } else {
            guard Self.normalizedNonEmpty(thread.workOSContractID) == nil,
                  Self.normalizedNonEmpty(thread.workOSGoalID) == nil,
                  thread.selectedThreadWorkOSContext == nil,
                  thread.activePLGRunProjection == nil,
                  invalidation.desiredLoopsConfigSHA256
                    == TatwoNativeThreadBindingInvalidationV1
                        .loopsConfigSHA256(thread.loopsConfig)
            else { return false }
        }

        guard refreshVerifiedCurrentSessionBundleFromDisk(
                ownerVerification: currentSessionOwnerVerification(
                    for: thread,
                    projectID: projectID,
                    pointerSchema: bundle.pointer.schema)),
              let refreshed = verifiedCurrentSessionBundle,
              exactBindingIdentity(refreshed) == successor
        else { return false }
        return true
    }

    func threadHasExactBindingInvalidation(
        _ thread: TatwoNativeChatThread,
        projectID: UUID?,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard let invalidation = thread.bindingInvalidation,
              invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1",
              invalidation.threadID == thread.id,
              invalidation.projectID == projectID,
              invalidation.expectedSuccessor
                == exactBindingIdentity(bundle),
              invalidation.desiredLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1
                    .loopsConfigSHA256(thread.loopsConfig),
              invalidation.authorityProvenance
                == bindingAuthorityProvenance(
                    for: thread,
                    projectID: projectID),
              Self.normalizedNonEmpty(thread.workOSContractID) == nil,
              Self.normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.selectedThreadWorkOSContext == nil,
              thread.activePLGRunProjection == nil
        else { return false }
        return invalidationPredecessorIsCanonical(
            invalidation,
            successor: exactBindingIdentity(bundle))
    }

    func threadCanResumeExactBindingInvalidation(
        _ thread: TatwoNativeChatThread,
        projectID: UUID?,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard let invalidation = thread.bindingInvalidation,
              invalidation.schema
                == "TatwoNativeThreadBindingInvalidationV1",
              invalidation.threadID == thread.id,
              invalidation.projectID == projectID,
              invalidation.authorityProvenance
                == bindingAuthorityProvenance(
                    for: thread,
                    projectID: projectID)
        else { return false }

        let successor = exactBindingIdentity(bundle)
        guard invalidationDesiredLoopsConfigMatchesExactSuccessor(
                invalidation,
                thread: thread,
                bundle: bundle),
              invalidationPredecessorIsCanonical(
                invalidation,
                successor: successor)
        else { return false }
        if let expected = invalidation.expectedSuccessor {
            guard expected == successor else { return false }
        } else {
            guard invalidation.reason != .goalRevisionChanged else {
                return false
            }
        }

        let hasPreviousBinding =
            Self.normalizedNonEmpty(thread.workOSContractID)
                == invalidation.previousBinding.contractID
            && Self.normalizedNonEmpty(thread.workOSGoalID)
                == invalidation.previousBinding.goalID
        if hasPreviousBinding {
            return invalidation.previousLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1
                    .loopsConfigSHA256(thread.loopsConfig)
        }
        return Self.normalizedNonEmpty(thread.workOSContractID) == nil
            && Self.normalizedNonEmpty(thread.workOSGoalID) == nil
            && thread.selectedThreadWorkOSContext == nil
            && thread.activePLGRunProjection == nil
            && invalidation.desiredLoopsConfigSHA256
                == TatwoNativeThreadBindingInvalidationV1
                    .loopsConfigSHA256(thread.loopsConfig)
    }

    private func invalidationPredecessorIsCanonical(
        _ invalidation: TatwoNativeThreadBindingInvalidationV1,
        successor: TatwoNativeThreadBindingIdentityV1
    ) -> Bool {
        do {
            let predecessor = try goalRunStore.requireIssuedContract(
                invalidation.previousBinding.contractID)
            guard predecessor.goalID
                    == invalidation.previousBinding.goalID,
                  predecessor.resolvedRevision
                    == invalidation.previousBinding.goalRevision
            else { return false }
            switch invalidation.reason {
            case .loopsConfigChanged, .contractSuperseded:
                return predecessor.status == .cancelled
                    && predecessor.statusReason
                        == "superseded_before_dispatch"
            case .goalRevisionChanged:
                guard predecessor.status == .superseded,
                      predecessor.successorContractID
                        == successor.contractID,
                      predecessor.successorGoalID == successor.goalID,
                      let metadata = predecessor.supersession,
                      metadata.predecessorContractID
                        == invalidation.previousBinding.contractID,
                      metadata.predecessorGoalID
                        == invalidation.previousBinding.goalID,
                      metadata.predecessorRevision
                        == invalidation.previousBinding.goalRevision,
                      invalidation.previousPointerGeneration
                        == metadata.oldPointerGeneration,
                      metadata.successorContractID
                        == successor.contractID,
                      metadata.successorGoalID == successor.goalID,
                      metadata.successorRevision
                        == successor.goalRevision
                else { return false }
                return true
            }
        } catch {
            return false
        }
    }

    func threadCanAcceptVerifiedCurrentSession(
        _ thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard Self.normalizedNonEmpty(thread.workOSContractID) == nil,
              Self.normalizedNonEmpty(thread.workOSGoalID) == nil,
              thread.selectedThreadWorkOSContext == nil,
              thread.activePLGRunProjection == nil,
              thread.bindingInvalidation == nil
        else { return false }
        guard thread.loopsConfig != nil else { return true }
        return threadLoopsConfigMatches(
            thread.loopsConfig,
            contract: bundle.contract)
    }

    /// V1 has no persisted owner. A project migration is allowed only when one
    /// and only one project mirror carries an explicit continuity signal:
    /// either the exact canonical binding, or a matching Loops topology plus
    /// an unbound/demonstrably stale row projection.
    func legacyV1ProjectOwnerCandidates(
        bundle: ChatVerifiedCurrentSessionBundle,
        rebindPolicy: CurrentSessionRebindPolicy = .ordinary
    ) -> [CurrentSessionThreadTarget] {
        allCurrentSessionThreadTargets().filter { target in
            guard target.projectID != nil,
                  let candidate = thread(
                    id: target.threadID,
                    projectID: target.projectID),
                  currentSessionCanonicalOwner(
                    for: candidate,
                    projectID: target.projectID) != nil
            else { return false }

            if threadHasExactCurrentSessionBinding(
                candidate,
                bundle: bundle)
            {
                return threadCanonicalStateMatchesCurrentSession(
                    candidate,
                    bundle: bundle)
            }
            if rebindPolicy.isConfirmedGoalRevision,
               threadIsExactConfirmedRevisionPredecessor(
                    candidate,
                    bundle: bundle,
                    expected: rebindPolicy
                        .expectedRevisionPredecessor)
            {
                return true
            }
            if threadHasExactBindingInvalidation(
                candidate,
                projectID: target.projectID,
                bundle: bundle)
            {
                return true
            }
            guard candidate.loopsConfig != nil,
                  threadLoopsConfigMatches(
                    candidate.loopsConfig,
                    contract: bundle.contract)
            else { return false }
            return threadCanAcceptVerifiedCurrentSession(
                candidate,
                bundle: bundle)
                || (
                    !rebindPolicy.isConfirmedGoalRevision
                    && threadHasReplaceableStaleWorkOSProjection(
                        candidate,
                        bundle: bundle)
                )
        }
    }

    /// App-confirmed Goal revision is narrower than ordinary stale projection
    /// repair. The selected row may move only from the exact predecessor named
    /// by the successor's durable supersession metadata. Any unrelated
    /// terminal/stale Goal remains a conflict and is never rebound.
    private func threadIsExactConfirmedRevisionPredecessor(
        _ thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle,
        expected: WorkOSBindingIdentity?
    ) -> Bool {
        guard let expected,
              Self.normalizedNonEmpty(thread.workOSContractID)
                == expected.contractID,
              Self.normalizedNonEmpty(thread.workOSGoalID)
                == expected.goalID,
              let metadata = bundle.goalRecord.supersession,
              bundle.goalRecord.predecessorContractID
                == expected.contractID,
              bundle.goalRecord.predecessorGoalID == expected.goalID,
              metadata.predecessorContractID == expected.contractID,
              metadata.predecessorGoalID == expected.goalID,
              metadata.successorContractID == bundle.contract.contractID,
              metadata.successorGoalID == bundle.contract.goalID,
              metadata.successorRevision
                == bundle.goalRecord.resolvedRevision
        else { return false }

        do {
            guard let predecessor = try goalRunStore.record(
                forContractID: expected.contractID),
                  predecessor.goalID == expected.goalID,
                  predecessor.status == .superseded,
                  predecessor.successorContractID
                    == bundle.contract.contractID,
                  predecessor.successorGoalID == bundle.contract.goalID,
                  predecessor.supersession == metadata
            else { return false }
            if let context = thread.selectedThreadWorkOSContext {
                guard context.matches(
                    TatwoObjectiveIdentity.make(predecessor.objective))
                else { return false }
            }
            if let projection = thread.activePLGRunProjection {
                guard projection.contractID == expected.contractID,
                      projection.goalID == expected.goalID
                else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    func confirmedGoalRevisionPredecessorIdentity(
        for thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> WorkOSBindingIdentity? {
        guard let contractID = Self.normalizedNonEmpty(
                thread.workOSContractID),
              let goalID = Self.normalizedNonEmpty(thread.workOSGoalID)
        else { return nil }
        let expected = WorkOSBindingIdentity(
            contractID: contractID,
            goalID: goalID)
        return threadIsExactConfirmedRevisionPredecessor(
            thread,
            bundle: bundle,
            expected: expected)
            ? expected
            : nil
    }

    /// A row-local ID may be replaced only when its backing GoalRun is absent
    /// or explicitly reclaimable terminal history. `.succeeded` is still
    /// awaiting Goal Judge, so it remains a material conflict alongside active
    /// and planned Goals and is never overwritten by canonical projection.
    private func threadHasReplaceableStaleWorkOSProjection(
        _ thread: TatwoNativeChatThread,
        bundle: ChatVerifiedCurrentSessionBundle
    ) -> Bool {
        guard let contractID = Self.normalizedNonEmpty(
                thread.workOSContractID),
              let goalID = Self.normalizedNonEmpty(thread.workOSGoalID),
              contractID != bundle.contract.contractID
                || goalID != bundle.contract.goalID,
              thread.activePLGRunProjection == nil
        else { return false }

        do {
            guard let record = try goalRunStore.record(
                forContractID: contractID)
            else {
                return true
            }
            guard record.goalID == goalID else { return false }
            switch record.status {
            case .succeeded:
                return false
            case .failed, .cancelled, .passed, .rollbackRequired:
                return true
            case .superseded:
                return true
            case .planned, .dispatching, .running, .humanGate,
                 .awaitingNextCycle, .blocked:
                return false
            }
        } catch {
            return false
        }
    }

    private func threadLoopsConfigMatches(
        _ config: TatwoNativeThreadLoopsConfig?,
        contract: TatwoWorkOSContractV1
    ) -> Bool {
        guard let config else { return true }
        return config.mode == contract.mode
            && config.scenarioID == contract.scenario
            && Self.workOSRouteBindingPreservesContract(
                mode: contract.mode,
                scenarioID: contract.scenario,
                issuedOverride: contract.routeBindingOverride,
                loopsConfig: config)
    }

    func allCurrentSessionThreadTargets() -> [CurrentSessionThreadTarget] {
        document.threads.map {
            CurrentSessionThreadTarget(projectID: nil, threadID: $0.id)
        } + document.projects.flatMap { project in
            project.threads.map {
                CurrentSessionThreadTarget(
                    projectID: project.id,
                    threadID: $0.id)
            }
        }
    }

    func isSelectedCodexProjectMirror() -> Bool {
        guard selectedProjectID != nil,
              let thread = selectedThread
        else { return false }
        return thread.sourceMarker
            == TatwoNativeChatThreadSourceMarker.codexAppMirror
            && Self.isCodexAppMirrorThread(thread)
    }

    func thread(
        id threadID: UUID,
        projectID: UUID?
    ) -> TatwoNativeChatThread? {
        if let projectID {
            return document.projects
                .first(where: { $0.id == projectID })?
                .threads
                .first(where: { $0.id == threadID })
        }
        return document.threads.first(where: { $0.id == threadID })
    }

    /// True when the resolved canonical owner is this exact Tatwo chat row.
    ///
    /// Equivalent to "the user owns this row", but derived from the owner the
    /// contract will actually be minted against instead of a `sourceMarker`
    /// string that older persisted project rows never carried.
    static func canonicalOwnerIsSelfOwnedTatwoChatRow(
        _ owner: TatwoCanonicalSessionOwnerV1,
        thread: TatwoNativeChatThread
    ) -> Bool {
        owner.provider == "tatwo-chat"
            && owner.ownerKind == .thread
            && owner.externalProviderID.lowercased()
                == thread.id.uuidString.lowercased()
    }

    static func canonicalChatAuthorityInstanceDiscriminator(
        for owner: TatwoCanonicalSessionOwnerV1
    ) -> String {
        "provider:\(owner.provider)|ownerKind:\(owner.ownerKind.rawValue)|sessionID:\(owner.externalProviderID)"
    }

    func currentSessionCanonicalOwner(
        for thread: TatwoNativeChatThread,
        projectID: UUID?
    ) -> TatwoCanonicalSessionOwnerV1? {
        let standaloneWorkspacePath =
            Self.safeChatWorkspaceURL().standardizedFileURL.path
        if thread.sourceMarker
            == TatwoNativeChatThreadSourceMarker.userOwned
        {
            let workspacePath: String
            if let projectID {
                guard let project = document.projects.first(where: {
                    $0.id == projectID
                }),
                      let projectWorkspace = Self.normalizedWorkspacePath(
                        project.workdir)
                else { return nil }
                workspacePath = projectWorkspace
            } else {
                workspacePath = standaloneWorkspacePath
            }
            return TatwoCanonicalSessionOwnerV1(
                provider: "tatwo-chat",
                locator: .thread(thread.id.uuidString.lowercased()),
                workspacePath: workspacePath)
        }
        if thread.sourceMarker
            != TatwoNativeChatThreadSourceMarker.codexAppMirror
        {
            // 2026-08-27 runtime-63 live blocker (project `test`, thread
            // `F0453782…`): rows created under a project folder were persisted
            // with no `sourceMarker` at all, so neither the `userOwned` branch
            // above nor this one claimed them. `/goal` then fail-closed with
            // "缺少明確 provider session/thread owner" right after a successful
            // `/plan`. A non-mirror row is a Tatwo chat row by construction and
            // its owner is exactly this row (`thread` locator) inside its own
            // project workspace — no fallback to another thread and no
            // synthesized session ID. An unresolvable project workdir still
            // returns nil.
            if let projectID {
                guard let project = document.projects.first(where: {
                    $0.id == projectID
                }),
                      let projectWorkspace = Self.normalizedWorkspacePath(
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
        guard thread.sourceMarker == TatwoNativeChatThreadSourceMarker.codexAppMirror,
              Self.isCodexAppMirrorThread(thread),
              let sessionID = Self.normalizedNonEmpty(thread.codexSessionID),
              let mirroredWorkspace = Self.normalizedWorkspacePath(
                thread.mirroredCodexWorkspacePath)
        else { return nil }

        if let projectID {
            guard let project = document.projects.first(where: {
                $0.id == projectID
            }),
                  Self.normalizedWorkspacePath(project.workdir)
                    == mirroredWorkspace
            else { return nil }
        } else {
            guard mirroredWorkspace == standaloneWorkspacePath
            else { return nil }
        }

        return TatwoCanonicalSessionOwnerV1(
            provider: "codex",
            locator: .session(sessionID),
            workspacePath: mirroredWorkspace)
    }

    /// current-session 指標是否確實屬於「另一個真實存在的 Chat row」。
    ///
    /// 2026-08-21「每個對話各自一個 session」裁決的安全閥：只有找得到
    /// 真正的別家主人，才把 owner 不符當成良性；找不到任何主人代表
    /// owner 欄位是孤兒（竄改／損毀），必須照舊 fail-closed。
    func currentSessionPointerIsOwnedByAnExistingOtherThread(
        pointerOwner: TatwoSessionOwnerBindingV1,
        excluding excludedThreadID: UUID
    ) -> Bool {
        allCurrentSessionThreadTargets().contains { target in
            guard target.threadID != excludedThreadID,
                  let candidate = self.thread(
                    id: target.threadID,
                    projectID: target.projectID),
                  let candidateOwner = currentSessionCanonicalOwner(
                    for: candidate,
                    projectID: target.projectID)
            else { return false }
            return currentSessionCanonicalOwner(
                candidateOwner,
                matches: pointerOwner)
                || legacyOwnerExpectation(
                    candidateOwner,
                    matches: pointerOwner)
        }
    }

    func currentSessionCanonicalOwner(
        _ canonicalOwner: TatwoCanonicalSessionOwnerV1,
        matches owner: TatwoSessionOwnerBindingV1
    ) -> Bool {
        Self.normalizedNonEmpty(canonicalOwner.provider)
            == Self.normalizedNonEmpty(owner.provider)
            && Self.normalizedNonEmpty(
                canonicalOwner.externalProviderID)
                == Self.normalizedNonEmpty(owner.sessionID)
            && owner.ownerKind == canonicalOwner.ownerKind
            && Self.normalizedWorkspacePath(canonicalOwner.workspacePath)
                == Self.normalizedWorkspacePath(owner.workspacePath)
    }

    func currentSessionOwnerVerification(
        for thread: TatwoNativeChatThread,
        projectID: UUID?,
        pointerSchema: String
    ) -> TatwoSessionOwnerVerificationV1? {
        switch pointerSchema {
        case "TatwoSessionPointerV1":
            return nil
        case "TatwoSessionPointerV2":
            return currentSessionCanonicalOwner(
                for: thread,
                projectID: projectID
            ).map {
                .legacyV2($0.expectation)
            }
        case "TatwoSessionAuthorityPointerV3":
            return currentSessionCanonicalOwner(
                for: thread,
                projectID: projectID
            ).map {
                .canonicalV3($0)
            }
        default:
            return nil
        }
    }

    func legacyOwnerExpectation(
        _ canonicalOwner: TatwoCanonicalSessionOwnerV1,
        matches owner: TatwoSessionOwnerBindingV1
    ) -> Bool {
        let expectation = canonicalOwner.expectation
        return Self.normalizedNonEmpty(expectation.provider)
            == Self.normalizedNonEmpty(owner.provider)
            && Self.normalizedNonEmpty(
                expectation.externalProviderSessionID)
                == Self.normalizedNonEmpty(owner.sessionID)
            && Self.normalizedWorkspacePath(expectation.workspacePath)
                == Self.normalizedWorkspacePath(owner.workspacePath)
    }

    func isEligibleTatwoChatWorkspaceMirror(
        _ thread: TatwoNativeChatThread
    ) -> Bool {
        guard thread.sourceMarker == TatwoNativeChatThreadSourceMarker.codexAppMirror,
              Self.isCodexAppMirrorThread(thread),
              let workspacePath = Self.normalizedWorkspacePath(
                thread.mirroredCodexWorkspacePath)
        else { return false }
        return workspacePath
            == Self.safeChatWorkspaceURL().standardizedFileURL.path
    }

    nonisolated static func normalizedWorkspacePath(
        _ raw: String?
    ) -> String? {
        guard let trimmed = normalizedNonEmpty(raw) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .path
    }

    internal func quarantineSelectedWorkOSState(_ message: String) {
        selectedWorkOSContract = nil
        selectedGoalRecord = nil
        selectedDispatchRecords = []
        selectedWorkOSStateMessage = message
    }

    func restorePersistedDiscussionSelection() -> Bool {
        guard let discussionID = document.selectedDiscussionID else { return false }
        if let thread = document.threads.first(where: {
            $0.discussions.contains(where: { $0.id == discussionID && !$0.isArchived })
        }) {
            selectDiscussion(
                projectID: nil,
                threadID: thread.id,
                discussionID: discussionID,
                persistDiscussionSelection: false)
            return selectedDiscussionID == discussionID
        }
        for project in document.projects {
            guard let thread = project.threads.first(where: {
                $0.discussions.contains(where: { $0.id == discussionID && !$0.isArchived })
            }) else {
                continue
            }
            selectDiscussion(
                projectID: project.id,
                threadID: thread.id,
                discussionID: discussionID,
                persistDiscussionSelection: false)
            return selectedDiscussionID == discussionID
        }
        return false
    }

    func enableCodexThreadMirror() {
        guard allowColdStartDocumentMutation() else { return }
        guard let codexAppStateBridge,
              codexAppStateBridge.sourcePaths.requiresExternalVolumeOptIn,
              !isEnablingCodexMirror
        else { return }

        let preferenceStore = self.preferenceStore
        isEnablingCodexMirror = true
        codexMirrorLoadTask?.cancel()
        codexMirrorLoadTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let loadResult = codexAppStateBridge.loadDocumentOverlayFailSoft(
                    externalVolumeOptIn: true)
                if loadResult.status == .loaded {
                    guard (try? preferenceStore.setCodexThreadMirrorExternalVolumeOptIn(true)) != nil else {
                        return TatwoCodexAppStateBridge.MirrorLoadResult(
                            document: nil,
                            status: .unavailable)
                    }
                } else {
                    _ = try? preferenceStore.setCodexThreadMirrorExternalVolumeOptIn(false)
                }
                return loadResult
            }.value

            guard !Task.isCancelled, let self else { return }
            self.isEnablingCodexMirror = false
            self.codexMirrorStatus = result.status
            guard self.coldStartDocumentMutationAllowed else { return }
            guard let codexMirror = result.document else { return }
            let localDocument = self.document
            let merged = ChatCodexMirrorMerger.merge(
                codexMirror: codexMirror,
                localDocument: localDocument)
            self.document = GitHubProjectBindingMerger.apply(
                localDocument: localDocument,
                to: merged)
            self.reconcileVerifiedCurrentSessionAfterCodexMirrorMerge()
        }
    }

    private func reconcileVerifiedCurrentSessionAfterCodexMirrorMerge() {
        inspectCurrentSessionBundleFromDisk()
        guard currentSessionPointerPresent else {
            persistStore()
            return
        }
        guard let bundle = verifiedCurrentSessionBundle,
              verifiedCurrentSessionBundleIsCanonical(bundle)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Codex mirror 更新後 current-session 無法驗證，未猜測 Goal 所屬 thread。")
            persistStore()
            return
        }
        guard let target = verifiedCurrentSessionTarget(bundle)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Codex mirror 更新後找不到唯一 verified owner row。")
            persistStore()
            return
        }

        let targetAlreadySelected =
            selectedProjectID == target.projectID
            && selectedThreadID == target.threadID
            && selectedDiscussionID == nil
        if isRunning && !targetAlreadySelected {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：目前回覆尚未結束，未強制切換輸出 session；完成或停止後再重試 Codex mirror。")
            persistStore()
            return
        }

        let attachResult: CurrentSessionAttachResult
        if targetAlreadySelected {
            attachResult =
                attachVerifiedCurrentSessionToSelectedThreadIfEligible()
        } else {
            if let projectID = target.projectID {
                select(
                    projectID: projectID,
                    threadID: target.threadID,
                    persistDiscussionSelection: false)
            } else {
                selectStandaloneThread(
                    target.threadID,
                    persistDiscussionSelection: false)
            }
            attachResult =
                selectedThreadID == target.threadID
                && selectedProjectID == target.projectID
                && selectedDiscussionID == nil
                && selectedThread.map {
                    threadHasExactCurrentSessionBinding($0, bundle: bundle)
                        && threadCanonicalStateMatchesCurrentSession(
                            $0,
                            bundle: bundle)
                } == true
                ? .attached
                : .quarantined
        }

        guard case .attached = attachResult,
              let selectedThread,
              threadHasExactCurrentSessionBinding(
                selectedThread,
                bundle: bundle),
              threadCanonicalStateMatchesCurrentSession(
                selectedThread,
                bundle: bundle)
        else {
            quarantineSelectedWorkOSState(
                "Work OS continuity 已隔離：Codex mirror canonical row 未能精確接回原 GoalRun。")
            persistStore()
            return
        }
        persistStore()
    }

    nonisolated static func normalizedNonEmpty(
        _ value: String?
    ) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func applyExportOnlyLoopOverride(environment: [String: String]) {
        let primary = environment["TATWO_ULTRAWORK_CHAT_LOOP_PRIMARY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = environment["TATWO_ULTRAWORK_CHAT_LOOP_SECONDARY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMode = environment["TATWO_ULTRAWORK_CHAT_LOOP_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard primary?.isEmpty == false || secondary?.isEmpty == false || rawMode?.isEmpty == false else { return }

        let base = selectedThread?.loopsConfig ?? selectedCoworkTemplate.map { loopsConfig(for: $0) }
        var override = base ?? TatwoNativeThreadLoopsConfig(
            scenarioID: "ui-ux-1-fireworks",
            mode: .l,
            identitySummary: "Plan:lead=gpt-5.5；Loops:supervisor=sonnet5",
            tokenBudget: "UI UX L：5方向提案")
        if let rawMode, let mode = WorkModeID(rawValue: rawMode.uppercased()) ?? WorkModeID(rawValue: rawMode.lowercased()) {
            override.mode = mode
        }
        if let primary, !primary.isEmpty {
            override.primaryModelID = primary
        }
        if let secondary, !secondary.isEmpty {
            override.secondaryModelID = secondary
        }
        snapshotLoopsOverride = override
    }
}
