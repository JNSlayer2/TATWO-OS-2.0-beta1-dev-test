import Foundation
import TatwoUltraworkCore

protocol RunAdmissionPolicy: Sendable {
    func admit(contract: TatwoWorkOSContractV1, owner: TatwoCanonicalSessionOwnerV1) throws -> TatwoGoalAuthorityTransactionResultV1
}

protocol ToolAuthorizationPolicy: Sendable {
    func authorize(_ request: TatwoNativeHostAuthorizationRequest) throws -> String
}

protocol CompletionJudge: Sendable {
    func judge(goalID: String?, contractID: String?, mode: WorkModeID, scenarioProfileID: String, suppliedReceiptIDs: [String]) throws -> WorkOSGoalCloseResult
}

struct ExistingGoalAuthorityAdmissionAdapter: RunAdmissionPolicy, Sendable {
    let transaction: TatwoGoalAuthorityTransaction
    func admit(contract: TatwoWorkOSContractV1, owner: TatwoCanonicalSessionOwnerV1) throws -> TatwoGoalAuthorityTransactionResultV1 {
        try transaction.begin(contract: contract, owner: owner)
    }
}

struct ExistingHostOperationAuthorizationAdapter: ToolAuthorizationPolicy, Sendable {
    let issuer: ChatNativeHostOperationAuthorizationIssuer
    func authorize(_ request: TatwoNativeHostAuthorizationRequest) throws -> String {
        try issuer.authorizationID(for: request)
    }
}

protocol RunStopPolicy: Sendable {
    func stopReason(startedAt: Date, now: Date, usage: Int, failures: Int, disabled: Bool) -> AgentKernelStopReason?
}

struct ExistingKernelStopPolicyAdapter: RunStopPolicy, Sendable {
    let policy: AgentKernelStopPolicy
    func stopReason(startedAt: Date, now: Date, usage: Int, failures: Int, disabled: Bool) -> AgentKernelStopReason? {
        policy.reason(startedAt: startedAt, now: now, usage: usage, failures: failures, disabled: disabled)
    }
}

struct ExistingGoalCompletionJudgeAdapter: CompletionJudge, Sendable {
    let store: TatwoGoalRunStore
    func judge(goalID: String?, contractID: String?, mode: WorkModeID, scenarioProfileID: String, suppliedReceiptIDs: [String]) throws -> WorkOSGoalCloseResult {
        try WorkOSFactory.closeGoal(
            goalID: goalID,
            contractID: contractID,
            mode: mode,
            scenarioProfileID: scenarioProfileID,
            suppliedReceiptIDs: suppliedReceiptIDs,
            store: store,
            dispatchRegistry: TatwoDispatchRegistry(
                directoryURL: store.directoryURL))
    }
}
