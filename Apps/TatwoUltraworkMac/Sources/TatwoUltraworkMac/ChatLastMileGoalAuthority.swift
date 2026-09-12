import Foundation
import TatwoUltraworkCore

@MainActor
extension ChatPageModel {
    /// Re-verifies this turn's frozen Work OS authority at the exact spawn
    /// boundary and returns a machine-readable blocker when a host
    /// mutation-capable runner must not start.
    ///
    /// 2026-08-27 staging61: goal
    /// `contract-xxl-general-xxl-sol-opus5-luna-grok-exact-2cd42154892f`
    /// reached `cancelled`/`superseded_before_dispatch` at the same second it
    /// was issued, yet run `339CAEFE…` still started on the `codex-exec`
    /// transport and created three files. Every pre-existing goal-authority
    /// check sat behind `runtimeAdapter == .nativeAgent`, so the provider-CLI
    /// transports were never gated.
    ///
    /// The frozen dispatch snapshot is an optimistic submit-time decision.
    /// Authority can change between submit and spawn, so the goal record is
    /// re-read here rather than trusted from in-memory state.
    func lastMileGoalAuthorityBlocker(
        dispatchSnapshot: ChatTurnDispatchSnapshot,
        command: ChatCLICommand
    ) -> String? {
        // A native-agent process is not inherently mutation-authorized. Its
        // immutable command access is the authority boundary. Read-only
        // recovery/diagnostic turns may continue against a blocked Goal, while
        // Computer Host authority remains mutation-capable regardless.
        if command.runtimeAdapter == .nativeAgent,
           command.nativeDevelopmentAccess == .readOnly,
           !dispatchSnapshot.computerHostDecision.isAuthorized
        {
            return nil
        }
        guard TatwoGoalDispatchAuthorityGate.isHostMutationCapable(
            runtimeAdapter: command.runtimeAdapter,
            computerHostAuthorized:
                dispatchSnapshot.computerHostDecision.isAuthorized)
        else { return nil }
        guard let contractID = Self.normalizedNonEmpty(
            dispatchSnapshot.contractID)
        else {
            // Ordinary uncontracted chat has no Goal authority to re-verify.
            // Once a frozen contract exists, the gate below still requires the
            // durable Goal record and owning thread/discussion binding.
            return nil
        }

        let record = try? goalRunStore.requireIssuedContract(contractID)
        // `startTurn` and queued-turn dequeue both invoke this gate
        // synchronously on MainActor after selecting the exact session that
        // owns the physical turn. Read the durable thread row behind that
        // session instead of the mutable `selectedWorkOSContract` projection.
        // A discussion inherits its parent thread's Work OS authority.
        let boundContractID = workOSContractIDForExecutingTurnSession()
        guard let denial = TatwoGoalDispatchAuthorityGate.denial(
            frozenContractID: contractID,
            runtimeAdapter: command.runtimeAdapter,
            computerHostAuthorized:
                dispatchSnapshot.computerHostDecision.isAuthorized,
            boundContractID: boundContractID,
            goalStatus: record?.status,
            goalStatusReason: record?.statusReason)
        else {
            return nil
        }
        return TatwoGoalDispatchAuthorityGate.blocker(
            denial,
            goalStatus: record?.status,
            goalStatusReason: record?.statusReason)
    }

    private func workOSContractIDForExecutingTurnSession() -> String? {
        guard let session = selectedSessionReference else { return nil }
        let threads = document.threads + document.projects.flatMap(\.threads)
        switch session.kind {
        case .thread:
            return Self.normalizedNonEmpty(
                threads.first(where: { $0.id == session.id })?
                    .workOSContractID)
        case .discussion:
            return Self.normalizedNonEmpty(
                threads.first(where: { thread in
                    thread.discussions.contains(where: {
                        $0.id == session.id
                    })
                })?.workOSContractID)
        }
    }
}
