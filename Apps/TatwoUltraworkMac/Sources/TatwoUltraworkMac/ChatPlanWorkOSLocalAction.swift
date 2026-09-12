import Foundation
import TatwoUltraworkCore

enum ChatPlanWorkOSLocalActionPhase: String, Equatable, Sendable {
    case idle
    case pending
    case dispatching
    case succeeded
    case failed
}

struct ChatPlanWorkOSLocalActionPresentation: Equatable, Sendable {
    var phase: ChatPlanWorkOSLocalActionPhase
    var message: String
    var goalID: String?
    var contractID: String?
    var dispatchID: String? = nil
    var runnerEvidenceID: String? = nil
    var stateRoot: String?
    var isRetryable: Bool

    static let idle = Self(
        phase: .idle,
        message: "",
        goalID: nil,
        contractID: nil,
        stateRoot: nil,
        isRetryable: false)

    var isInFlight: Bool {
        phase == .pending || phase == .dispatching
    }
}

struct ChatPlanWorkOSLocalActionRequest: Equatable, Sendable {
    let artifactThreadID: UUID
    let selectedThreadID: UUID
    let goalID: String
    let contractID: String
    let expectedStateRoot: URL
}

enum ChatPlanWorkOSLocalActionError: Error, LocalizedError, Equatable {
    case threadMismatch
    case stateRootMismatch
    case goalMismatch
    case contractMismatch
    case nextRejected(code: String)

    var errorDescription: String? {
        switch self {
        case .threadMismatch:
            return "Plan artifact 與目前 thread 不一致。"
        case .stateRootMismatch:
            return "Work OS state root 與目前 App session 不一致。"
        case .goalMismatch:
            return "Work OS Goal ID 與本機 ledger 不一致。"
        case .contractMismatch:
            return "Work OS Contract ID 與本機 ledger 不一致。"
        case .nextRejected(let code):
            return "Work OS next gate 拒絕本次操作（\(code)）。"
        }
    }
}

typealias ChatPlanWorkOSNextResolver = (
    _ request: ChatPlanWorkOSLocalActionRequest,
    _ store: TatwoGoalRunStore,
    _ registry: TatwoDispatchRegistry,
    _ scenarioBook: TatwoScenarioConfigBookV1
) throws -> TatwoWorkOSNextAction

enum ChatPlanWorkOSLocalActionBridge {
    static func resolveNext(
        request: ChatPlanWorkOSLocalActionRequest,
        store: TatwoGoalRunStore,
        registry: TatwoDispatchRegistry,
        scenarioBook: TatwoScenarioConfigBookV1
    ) throws -> TatwoWorkOSNextAction {
        guard request.artifactThreadID == request.selectedThreadID else {
            throw ChatPlanWorkOSLocalActionError.threadMismatch
        }
        guard store.directoryURL.standardizedFileURL
                == request.expectedStateRoot.standardizedFileURL
        else {
            throw ChatPlanWorkOSLocalActionError.stateRootMismatch
        }

        let stored = try store.requireIssuedContract(request.contractID)
        guard stored.goalID == request.goalID else {
            throw ChatPlanWorkOSLocalActionError.goalMismatch
        }
        guard stored.contractID == request.contractID else {
            throw ChatPlanWorkOSLocalActionError.contractMismatch
        }

        let projected = try WorkOSFactory.storedContractProjection(
            contractID: request.contractID,
            fallbackMode: stored.mode,
            fallbackScenarioProfileID: stored.scenario,
            fallbackObjective: stored.objective,
            scenarioBook: scenarioBook,
            store: store)
        guard projected.goalID == request.goalID,
              projected.contractID == request.contractID
        else {
            throw ChatPlanWorkOSLocalActionError.contractMismatch
        }

        let next = try WorkOSFactory.next(
            goalID: request.goalID,
            contractID: request.contractID,
            mode: stored.mode,
            scenarioProfileID: stored.scenario,
            objective: stored.objective,
            scenarioBook: scenarioBook,
            store: store,
            registry: registry)
        guard next.goalID == request.goalID else {
            throw ChatPlanWorkOSLocalActionError.goalMismatch
        }
        guard next.contractID == request.contractID else {
            throw ChatPlanWorkOSLocalActionError.contractMismatch
        }
        guard next.ok else {
            throw ChatPlanWorkOSLocalActionError.nextRejected(
                code: next.decision.code)
        }
        return next
    }
}

extension ChatPageModel {
    static func confirmedPlanExecutionObjective(
        _ artifact: TatwoPlanArtifactV1
    ) -> String {
        let planID = artifact.planID.uuidString.lowercased()
        return """
        Execute the user-confirmed Plan artifact \(planID). This confirmation \
        supersedes the prior planning-only limitation and authorizes the \
        approved Plan steps and validation to run through Work OS.
        """
    }

    static func resemblesLocalWorkOSNextCommand(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.hasPrefix("tatwo.os.next") else { return false }
        let suffix = normalized.dropFirst("tatwo.os.next".count)
        return suffix.isEmpty || suffix.first?.isWhitespace == true
    }

    func effectivePermissionLabel(compact: Bool) -> String {
        if isPlanModeEnabled {
            return "\(permissionPreset.shortDisplayName) · Plan 唯讀"
        }
        return compact
            ? permissionPreset.shortDisplayName
            : permissionPreset.displayName
    }

    var effectivePermissionMappingSummary: String {
        if isPlanModeEnabled {
            return permissionPreset.mappingSummary
                + "；Plan 模式只讀，確認計畫後才送交 Work OS。"
        }
        return permissionPreset.mappingSummary
    }

    func beginPlanWorkOSLocalActionPresentation() {
        planWorkOSLocalActionPresentation = .init(
            phase: .pending,
            message: "正在確認計畫；尚未啟動 runner。",
            goalID: nil,
            contractID: nil,
            stateRoot: goalRunStore.directoryURL.standardizedFileURL.path,
            isRetryable: false)
    }

    func failPlanWorkOSLocalActionPresentation(_ message: String) {
        planWorkOSLocalActionPresentation = .init(
            phase: .failed,
            message: message,
            goalID: selectedWorkOSContract?.goalID,
            contractID: selectedWorkOSContract?.contractID,
            dispatchID:
                planWorkOSLocalActionPresentation.dispatchID,
            stateRoot: goalRunStore.directoryURL.standardizedFileURL.path,
            isRetryable: true)
    }

    @discardableResult
    func publishConfirmedPlanWorkOSDispatchSuccessIfVerified(
        dispatchID expectedDispatchID: String? = nil,
        message: String = "已送交 Work OS：正式 dispatch 與 runner 已進入 running。"
    ) -> Bool {
        guard planWorkOSLocalActionPresentation.phase == .dispatching,
              let contract = selectedWorkOSContract,
              planWorkOSLocalActionPresentation.goalID == contract.goalID,
              planWorkOSLocalActionPresentation.contractID
                == contract.contractID
        else {
            return false
        }

        let activeDispatchID: String?
        let runnerEvidenceID: String?
        if let active = activeSingleModelGoalDispatch,
           active.contractID == contract.contractID
        {
            activeDispatchID = active.dispatchID
            runnerEvidenceID =
                active.runnerInstanceID.uuidString.lowercased()
        } else if let active = activeNativeDevelopmentDispatch,
                  active.contractID == contract.contractID
        {
            activeDispatchID = active.dispatchID
            runnerEvidenceID = active.runID
        } else {
            activeDispatchID = nil
            runnerEvidenceID = nil
        }
        let dispatchID =
            expectedDispatchID
            ?? activeDispatchID
            ?? pendingSingleModelGoalDispatch?.id
            ?? pendingNativeDevelopmentDispatch?.id
        guard let dispatchID, !dispatchID.isEmpty else {
            planWorkOSLocalActionPresentation.message =
                "Work OS 本機 canonical transition 已完成；"
                + "尚未建立可驗證的 dispatch record，runner 尚未啟動。"
            return false
        }
        planWorkOSLocalActionPresentation.dispatchID = dispatchID

        do {
            guard let record = try dispatchRegistry.run(
                forContractID: contract.contractID)?.records.first(where: {
                    $0.id == dispatchID
                })
            else {
                failPlanWorkOSLocalActionPresentation(
                    "Work OS dispatch 驗證失敗：找不到 canonical dispatch record"
                        + "（\(dispatchID)）；計畫可重試。")
                return false
            }
            guard record.contractID == contract.contractID else {
                failPlanWorkOSLocalActionPresentation(
                    "Work OS dispatch 驗證失敗：dispatch/contract 綁定不一致；"
                        + "計畫可重試。")
                return false
            }
            guard record.status == .running else {
                planWorkOSLocalActionPresentation.message =
                    "Work OS canonical dispatch 已建立（\(dispatchID)），"
                    + "但狀態仍為 \(record.status.rawValue)；"
                    + "尚未宣告 runner 啟動成功。"
                return false
            }
        } catch {
            failPlanWorkOSLocalActionPresentation(
                "Work OS dispatch 驗證失敗："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription)
                    + " 計畫可重試。")
            return false
        }

        guard isRunning,
              activeDispatchID == dispatchID,
              let runnerEvidenceID,
              !runnerEvidenceID.isEmpty
        else {
            planWorkOSLocalActionPresentation.message =
                "Work OS canonical dispatch 已進入 running（\(dispatchID)），"
                + "但 App 尚未觀測到對應 runner liveness；"
                + "不會提前宣告成功。"
            return false
        }

        planWorkOSLocalActionPresentation = .init(
            phase: .succeeded,
            message: message,
            goalID: contract.goalID,
            contractID: contract.contractID,
            dispatchID: dispatchID,
            runnerEvidenceID: runnerEvidenceID,
            stateRoot: goalRunStore.directoryURL.standardizedFileURL.path,
            isRetryable: false)
        return true
    }

    @discardableResult
    func performConfirmedPlanWorkOSLocalAction(
        artifact: TatwoPlanArtifactV1
    ) -> Bool {
        guard let selectedThreadID,
              let contract = selectedWorkOSContract
        else {
            failPlanWorkOSLocalActionPresentation(
                "送交 Work OS 失敗：新的 Goal/Contract 尚未建立；計畫可重試。")
            return false
        }
        let request = ChatPlanWorkOSLocalActionRequest(
            artifactThreadID: artifact.threadID,
            selectedThreadID: selectedThreadID,
            goalID: contract.goalID,
            contractID: contract.contractID,
            expectedStateRoot: goalRunStore.directoryURL)
        planWorkOSLocalActionPresentation = .init(
            phase: .dispatching,
            message: "正在以 App 本機 ledger 驗證 Work OS 下一步；尚未啟動 runner。",
            goalID: contract.goalID,
            contractID: contract.contractID,
            stateRoot: goalRunStore.directoryURL.standardizedFileURL.path,
            isRetryable: false)
        do {
            let next = try planWorkOSNextResolver(
                request,
                goalRunStore,
                dispatchRegistry,
                scenarioConfigBook)
            planWorkOSLocalActionPresentation = .init(
                phase: .dispatching,
                message:
                    "Work OS 本機 canonical transition 已完成："
                    + "\(next.nextStep)。正在建立正式 dispatch；"
                    + "runner 尚未啟動。",
                goalID: contract.goalID,
                contractID: contract.contractID,
                stateRoot: goalRunStore.directoryURL.standardizedFileURL.path,
                isRetryable: false)
            return true
        } catch {
            failPlanWorkOSLocalActionPresentation(
                "送交 Work OS 失敗："
                    + TatwoPrivacyRedactor.redacted(
                        error.localizedDescription)
                    + " 計畫已恢復，可重試。")
            return false
        }
    }
}
