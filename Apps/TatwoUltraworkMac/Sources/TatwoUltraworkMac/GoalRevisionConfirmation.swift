import CryptoKit
import Foundation
import Security
import SwiftUI
@_spi(TatwoHumanGateApp) import TatwoUltraworkCore

struct TatwoGoalRevisionSelection: Equatable, Sendable {
    let mode: WorkModeID
    let scenarioProfileID: String
    let scenarioBook: TatwoScenarioConfigBookV1
    let loopPresetID: String
    let enabledLoopTemplateIDs: [String]?
}

struct TatwoGoalRevisionIssuerArtifactEvidence: Equatable, Sendable {
    let identity: TatwoHumanGateIssuerArtifactIdentityV1
    let executableURL: URL
}

struct TatwoGoalRevisionRequestedHostScope: Equatable, Sendable {
    let kind: String
    let workspacePath: String?
    let actions: [TatwoHostActionKind]
    let maxDurationSeconds: UInt64?
    let maxOutputBytes: UInt64?
    let maxFileCount: UInt64?

    static let revisionActivationOnly = TatwoGoalRevisionRequestedHostScope(
        kind: "revision_activation_only",
        workspacePath: nil,
        actions: [],
        maxDurationSeconds: nil,
        maxOutputBytes: nil,
        maxFileCount: nil
    )

    var canonicalValue: String {
        [
            kind,
            workspacePath ?? "none",
            actions.map(\.rawValue).sorted().joined(separator: ","),
            maxDurationSeconds.map(String.init) ?? "none",
            maxOutputBytes.map(String.init) ?? "none",
            maxFileCount.map(String.init) ?? "none"
        ].joined(separator: "\n")
    }

    var displayValue: String {
        guard kind == "revision_activation_only" else { return kind }
        return "只允許 Goal revision activation；不核發 Host Executor 操作"
    }
}

struct TatwoGoalRevisionBindingFact: Equatable, Sendable, Identifiable {
    let id: String
    let sourceSlotID: String
    let identity: IdentityKind
    let modelID: String?
    let engineID: EngineID?
    let authority: AuthorityMode
    let reasoningEffort: TatwoCodexReasoningEffort?
    let canMutateHost: Bool

    init(_ binding: TatwoIssuedIdentityBindingV1) {
        id = binding.id
        sourceSlotID = binding.sourceSlotID
        identity = binding.identity
        modelID = binding.modelID
        engineID = binding.engineID
        authority = binding.authority
        reasoningEffort = binding.reasoningEffort
        canMutateHost = binding.canMutateHost
    }

    var canonicalValue: String {
        [
            id,
            sourceSlotID,
            identity.rawValue,
            modelID ?? "none",
            engineID?.rawValue ?? "none",
            authority.rawValue,
            reasoningEffort?.rawValue ?? "route-default",
            String(canMutateHost)
        ].joined(separator: "|")
    }

    var topologyLine: String {
        [
            identity.rawValue,
            modelID ?? "unbound-model",
            engineID?.rawValue ?? "unbound-engine",
            authority.rawValue,
            reasoningEffort?.rawValue ?? "route-default",
            "canMutateHost=\(canMutateHost)"
        ].joined(separator: " · ")
    }
}

struct TatwoGoalRevisionCapabilityChange: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case added
        case removed
        case changed
    }

    let kind: Kind
    let bindingID: String
    let oldValue: TatwoGoalRevisionBindingFact?
    let newValue: TatwoGoalRevisionBindingFact?

    var id: String { "\(kind.rawValue):\(bindingID)" }
}

struct TatwoGoalRevisionProposal: Equatable, Sendable {
    let newContract: TatwoWorkOSContractV1
    let newBindings: [TatwoGoalRevisionBindingFact]
    let newBindingsDigest: String
    let topologyDigest: String
    let capabilityDigest: String
    let capabilityChanges: [TatwoGoalRevisionCapabilityChange]
    let requestedHostScopeDigest: String
    let humanGateSubjectDigest: String
}

struct TatwoGoalRevisionChallenge: Equatable, Sendable, Identifiable {
    let id: String
    let createdAt: Date
    let pointerSnapshot: TatwoSessionPointerSnapshotV1
    let oldGoalSnapshot: TatwoGoalRunSnapshotV1
    let oldContract: TatwoWorkOSContractV1
    let oldGoalRecord: TatwoStoredGoalRun
    let oldBindings: [TatwoGoalRevisionBindingFact]
    let oldBindingsDigest: String?
    let selection: TatwoGoalRevisionSelection
    let scenarioBook: TatwoScenarioConfigBookV1
    let requestedHostScope: TatwoGoalRevisionRequestedHostScope
    let issuerArtifact: TatwoGoalRevisionIssuerArtifactEvidence
    let initialNewObjective: String

    var sessionID: String {
        pointerSnapshot.pointer.ownerBinding?.sessionID
            ?? "unowned:\(oldContract.contractID):\(oldContract.goalID)"
    }

    func proposal(newObjective: String) throws -> TatwoGoalRevisionProposal {
        try TatwoGoalRevisionCoordinator.proposal(
            challenge: self,
            newObjective: newObjective
        )
    }
}

struct TatwoGoalRevisionConfirmationResult: Equatable, Sendable {
    let transition: TatwoGoalRevisionPromotionResultV1
    let readback: TatwoSessionAttachmentV1
    let pointerSnapshot: TatwoSessionPointerSnapshotV1
    let issuerArtifact: TatwoGoalRevisionIssuerArtifactEvidence
}

enum TatwoGoalRevisionConfirmationError:
    Error, LocalizedError, Equatable, Sendable
{
    case noCurrentSession
    case currentGoalMustBeRunning(GoalRunStatus)
    case invalidNewObjective(String)
    case unchangedGoal
    case staleCurrentSession
    case staleCurrentGoal
    case proposalChanged
    case issuerArtifactChanged
    case coldReadMismatch
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCurrentSession:
            return "目前沒有可 revision 的 current-session。"
        case .currentGoalMustBeRunning(let status):
            return "只有 running 或尚未派工的 pristine planned Goal 可以建立 successor；目前為 \(status.rawValue)。"
        case .invalidNewObjective(let reason):
            return "新 Goal objective 無效：\(reason)"
        case .unchangedGoal:
            return "新 Goal 與目前 Goal 完全相同；未建立無意義 revision。"
        case .staleCurrentSession:
            return "current-session 已改變；此確認已過期，請重新預覽。"
        case .staleCurrentGoal:
            return "目前 Goal revision 已改變；此確認已過期，請重新預覽。"
        case .proposalChanged:
            return "情境或模式投影已改變；未使用舊 proposal 寫入。"
        case .issuerArtifactChanged:
            return "執行中的 App artifact identity 已改變；未簽發確認收據。"
        case .coldReadMismatch:
            return "promotion 已完成，但 cold read 無法驗證 successor；已 fail closed。"
        case .operationFailed(let message):
            return TatwoPrivacyRedactor.redacted(message)
        }
    }
}

struct TatwoGoalRevisionPredecessorResolution: Sendable, Equatable {
    let attachment: TatwoSessionAttachmentV1?
    let requiresBindingRevision: Bool
}

enum TatwoGoalRevisionPredecessorResolver {
    static func resolve(
        pointer: TatwoSessionPointer,
        scenarioBook: TatwoScenarioConfigBookV1,
        goalStore: TatwoGoalRunStore,
        sessionStore: TatwoSessionStore
    ) throws -> TatwoGoalRevisionPredecessorResolution {
        do {
            return TatwoGoalRevisionPredecessorResolution(
                attachment: try sessionStore.inspectCurrent(
                    expectedContractID: pointer.contractID,
                    expectedGoalID: pointer.goalID,
                    expectedMode: pointer.mode,
                    expectedScenario: pointer.scenario,
                    expectedObjective: pointer.objective,
                    scenarioBook: scenarioBook,
                    goalStore: goalStore),
                requiresBindingRevision: false)
        } catch let error as TatwoGoalRunStoreError {
            guard case .issuedIdentityBindingsMismatch(let contractID) = error,
                  contractID == pointer.contractID
            else {
                throw error
            }
        }

        let issuedContract =
            try TatwoGoalAuthorityTransaction.validatedIssuedContractReadback(
                pointer: pointer,
                stateRoot: goalStore.directoryURL)
        let goalRecord = try goalStore.requireIssuedContract(pointer.contractID)
        guard pointer.schema == "TatwoSessionAuthorityPointerV3",
              issuedContract.contractID == pointer.contractID,
              issuedContract.goalID == pointer.goalID,
              issuedContract.mode == pointer.mode,
              issuedContract.scenario == pointer.scenario,
              sameObjective(issuedContract.objective, pointer.objective),
              goalRecord.contractID == pointer.contractID,
              goalRecord.goalID == pointer.goalID,
              goalRecord.mode == pointer.mode,
              goalRecord.scenario == pointer.scenario,
              sameObjective(goalRecord.objective, pointer.objective),
              goalRecord.routeBindingOverride
                == issuedContract.routeBindingOverride,
              let currentSnapshot = try sessionStore.snapshotCurrent(),
              currentSnapshot.pointer == pointer
        else {
            throw TatwoGoalRevisionConfirmationError.staleCurrentSession
        }
        return TatwoGoalRevisionPredecessorResolution(
            attachment: TatwoSessionAttachmentV1(
                pointer: pointer,
                contract: issuedContract,
                goalRecord: goalRecord),
            requiresBindingRevision: true)
    }

    private static func sameObjective(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        TatwoObjectiveIdentity.make(lhs).objectiveHash
            == TatwoObjectiveIdentity.make(rhs).objectiveHash
    }
}

enum TatwoGoalRevisionCoordinator {
    typealias ArtifactProvider =
        @Sendable () throws -> TatwoGoalRevisionIssuerArtifactEvidence

    static func prepare(
        selection: TatwoGoalRevisionSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        goalStore: TatwoGoalRunStore? = nil,
        sessionStore: TatwoSessionStore? = nil,
        challengeID: String = UUID().uuidString.lowercased(),
        now: Date = Date(),
        artifactProvider: ArtifactProvider = liveIssuerArtifact
    ) throws -> TatwoGoalRevisionChallenge {
        let resolvedGoalStore =
            goalStore ?? TatwoGoalRunStore.default(environment: environment)
        let resolvedSessionStore =
            sessionStore
            ?? TatwoSessionStore(directoryURL: resolvedGoalStore.directoryURL)
        guard let pointerSnapshot = try resolvedSessionStore.snapshotCurrent()
        else {
            throw TatwoGoalRevisionConfirmationError.noCurrentSession
        }
        let pointer = pointerSnapshot.pointer
        guard let attachment =
            try TatwoGoalRevisionPredecessorResolver.resolve(
                pointer: pointer,
                scenarioBook: selection.scenarioBook,
                goalStore: resolvedGoalStore,
                sessionStore: resolvedSessionStore
            ).attachment
        else {
            throw TatwoGoalRevisionConfirmationError.noCurrentSession
        }
        guard attachment.goalRecord.status == .running
                || attachment.goalRecord.status == .planned
        else {
            throw TatwoGoalRevisionConfirmationError.currentGoalMustBeRunning(
                attachment.goalRecord.status)
        }
        let oldSnapshot = try resolvedGoalStore.snapshot(
            forContractID: attachment.contract.contractID)
        let artifact = try validatedRevisionIssuerArtifact(
            try artifactProvider(),
            requestedHostScope: .revisionActivationOnly)
        let initialObjective =
            "Replace with the full new Goal objective for "
            + "\(selection.mode.rawValue) / \(selection.scenarioProfileID)."
        let challenge = TatwoGoalRevisionChallenge(
            id: challengeID,
            createdAt: wholeSecond(now),
            pointerSnapshot: pointerSnapshot,
            oldGoalSnapshot: oldSnapshot,
            oldContract: attachment.contract,
            oldGoalRecord: oldSnapshot.record,
            oldBindings: bindingFacts(
                oldSnapshot.record.issuedIdentityBindings
                    ?? TatwoIssuedIdentityBindingV1.canonicalSnapshot(
                        for: attachment.contract)),
            oldBindingsDigest: oldSnapshot.record.issuedIdentityBindingsDigest,
            selection: selection,
            scenarioBook: selection.scenarioBook,
            requestedHostScope: .revisionActivationOnly,
            issuerArtifact: artifact,
            initialNewObjective: initialObjective
        )
        _ = try proposal(
            challenge: challenge,
            newObjective: initialObjective,
            allowPlaceholder: true
        )
        return challenge
    }

    static func proposal(
        challenge: TatwoGoalRevisionChallenge,
        newObjective: String
    ) throws -> TatwoGoalRevisionProposal {
        try proposal(
            challenge: challenge,
            newObjective: newObjective,
            allowPlaceholder: false
        )
    }

    static func confirm(
        challenge: TatwoGoalRevisionChallenge,
        newObjective: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        goalStore: TatwoGoalRunStore? = nil,
        sessionStore: TatwoSessionStore? = nil,
        dispatchRegistry: TatwoDispatchRegistry? = nil,
        now: Date = Date(),
        artifactProvider: ArtifactProvider = liveIssuerArtifact
    ) throws -> TatwoGoalRevisionConfirmationResult {
        let resolvedGoalStore =
            goalStore ?? TatwoGoalRunStore.default(environment: environment)
        let resolvedSessionStore =
            sessionStore
            ?? TatwoSessionStore(directoryURL: resolvedGoalStore.directoryURL)
        let resolvedRegistry =
            dispatchRegistry
            ?? TatwoDispatchRegistry(directoryURL: resolvedGoalStore.directoryURL)
        let proposal = try proposal(
            challenge: challenge,
            newObjective: newObjective)

        let freshPointer: TatwoSessionPointerSnapshotV1?
        do {
            freshPointer = try resolvedSessionStore.snapshotCurrent()
        } catch {
            // The exact pointer revision is part of the confirmation challenge.
            // A malformed or authority-readback-invalid replacement is stale just
            // like a valid competing pointer; do not leak a lower-level storage
            // error past this fail-closed App boundary.
            throw TatwoGoalRevisionConfirmationError.staleCurrentSession
        }
        guard let freshPointer,
              freshPointer == challenge.pointerSnapshot
        else {
            throw TatwoGoalRevisionConfirmationError.staleCurrentSession
        }
        let freshOldSnapshot = try resolvedGoalStore.snapshot(
            forContractID: challenge.oldContract.contractID)
        guard freshOldSnapshot == challenge.oldGoalSnapshot,
              freshOldSnapshot.record == challenge.oldGoalRecord
        else {
            throw TatwoGoalRevisionConfirmationError.staleCurrentGoal
        }
        guard let freshAttachment =
            try TatwoGoalRevisionPredecessorResolver.resolve(
                pointer: challenge.pointerSnapshot.pointer,
                scenarioBook: challenge.scenarioBook,
                goalStore: resolvedGoalStore,
                sessionStore: resolvedSessionStore
            ).attachment,
              freshAttachment.contract == challenge.oldContract
        else {
            throw TatwoGoalRevisionConfirmationError.staleCurrentSession
        }
        let freshArtifact = try validatedRevisionIssuerArtifact(
            try artifactProvider(),
            requestedHostScope: challenge.requestedHostScope)
        guard freshArtifact == challenge.issuerArtifact else {
            throw TatwoGoalRevisionConfirmationError.issuerArtifactChanged
        }

        var disposition: TatwoGoalRunBeginDisposition?
        do {
            let created = try resolvedGoalStore.recordBeginWithDisposition(
                contract: proposal.newContract)
            disposition = created
            let newRecord = created.record
            let oldRecord = freshOldSnapshot.record
            let issuedAt = wholeSecond(now)
            let receiptID = "goal-revision-human-\(challenge.id)"
            let promotionID = "goal-revision-promotion-\(challenge.id)"
            let draft = TatwoGoalRevisionPromotionAuthorizationV1(
                id: promotionID,
                issuerDomain: TatwoAppHumanGateAuthorizationStore.issuerDomain,
                sessionID: challenge.sessionID,
                oldPointerRevisionDigest: challenge.pointerSnapshot.revision.digest,
                oldPointerGeneration:
                    challenge.pointerSnapshot.pointer.generation ?? 1,
                oldContractID: oldRecord.contractID,
                oldGoalID: oldRecord.goalID,
                oldGoalRevision: oldRecord.resolvedRevision,
                oldObjectiveDigest:
                    TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
                        oldRecord.objective),
                newContractID: newRecord.contractID,
                newGoalID: newRecord.goalID,
                newGoalRevision: oldRecord.resolvedRevision + 1,
                newObjectiveDigest:
                    TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
                        newRecord.objective),
                topologyDigest:
                    TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
                        sessionID: challenge.sessionID,
                        oldContractID: oldRecord.contractID,
                        oldGoalID: oldRecord.goalID,
                        newContractID: newRecord.contractID,
                        newGoalID: newRecord.goalID),
                capabilityDigest:
                    TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
                        oldBindingsDigest: oldRecord.issuedIdentityBindingsDigest,
                        newBindingsDigest: newRecord.issuedIdentityBindingsDigest),
                humanGateReceiptID: receiptID,
                requestedHostScopeDigest: proposal.requestedHostScopeDigest,
                issuedAt: issuedAt,
                expiresAt: issuedAt.addingTimeInterval(600),
                nonce: "subject-only",
                proofDigest: "subject-only"
            )
            guard draft.humanGateSubjectDigest
                    == proposal.humanGateSubjectDigest
            else {
                throw TatwoGoalRevisionConfirmationError.proposalChanged
            }
            let humanReceipt = try TatwoAppHumanGateAuthorizationStore(
                stateDirectoryURL: resolvedGoalStore.directoryURL
            ).authorizeAfterHumanConfirmation(
                id: receiptID,
                sessionID: draft.sessionID,
                oldContractID: draft.oldContractID,
                oldGoalID: draft.oldGoalID,
                newContractID: draft.newContractID,
                newGoalID: draft.newGoalID,
                subjectDigest: draft.humanGateSubjectDigest,
                issuerArtifactIdentity: freshArtifact.identity,
                ttl: 600,
                now: issuedAt
            )
            let authorization = try TatwoGoalRevisionPromotionAuthorizationStore(
                directoryURL: resolvedGoalStore.directoryURL
                    .appendingPathComponent(
                        "goal-revision-authorizations",
                        isDirectory: true)
            ).authorizeAfterHumanConfirmation(
                id: promotionID,
                sessionID: draft.sessionID,
                oldPointerRevisionDigest: draft.oldPointerRevisionDigest,
                oldPointerGeneration: draft.oldPointerGeneration,
                oldContractID: draft.oldContractID,
                oldGoalID: draft.oldGoalID,
                oldGoalRevision: draft.oldGoalRevision,
                oldObjectiveDigest: draft.oldObjectiveDigest,
                newContractID: draft.newContractID,
                newGoalID: draft.newGoalID,
                newGoalRevision: draft.newGoalRevision,
                newObjectiveDigest: draft.newObjectiveDigest,
                topologyDigest: draft.topologyDigest,
                capabilityDigest: draft.capabilityDigest,
                humanGateReceipt: humanReceipt,
                requestedHostScopeDigest: draft.requestedHostScopeDigest,
                ttl: 600,
                now: issuedAt
            )
            let transition =
                try resolvedSessionStore.transitionCurrentToPlannedRevision(
                    authorizationID: authorization.id,
                    now: issuedAt,
                    goalStore: resolvedGoalStore,
                    dispatchRegistry: resolvedRegistry
                )
            guard let coldPointer = try resolvedSessionStore.snapshotCurrent(),
                  coldPointer.pointer.contractID
                    == transition.successor.contractID,
                  coldPointer.pointer.goalID == transition.successor.goalID,
                  let readback = try resolvedSessionStore.inspectCurrent(
                    expectedContractID: transition.successor.contractID,
                    expectedGoalID: transition.successor.goalID,
                    expectedMode: proposal.newContract.mode,
                    expectedScenario: proposal.newContract.scenario,
                    expectedObjective: proposal.newContract.objective,
                    scenarioBook: challenge.scenarioBook,
                    goalStore: resolvedGoalStore),
                  readback.goalRecord.status == .running,
                  readback.goalRecord.predecessorContractID
                    == challenge.oldContract.contractID
            else {
                throw TatwoGoalRevisionConfirmationError.coldReadMismatch
            }
            return TatwoGoalRevisionConfirmationResult(
                transition: transition,
                readback: readback,
                pointerSnapshot: coldPointer,
                issuerArtifact: freshArtifact
            )
        } catch {
            if let disposition {
                _ = try? resolvedGoalStore.rollbackUnpublishedBegin(disposition)
            }
            if let typed = error as? TatwoGoalRevisionConfirmationError {
                throw typed
            }
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                error.localizedDescription)
        }
    }

    static func liveIssuerArtifact()
        throws -> TatwoGoalRevisionIssuerArtifactEvidence
    {
        guard let executableURL = Bundle.main.executableURL else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "App executable URL unavailable")
        }
        let bundleIdentifier =
            Bundle.main.bundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        guard TatwoGoalRevisionIssuerArtifactPolicy.acceptsBundleIdentifier(
            bundleIdentifier)
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Unexpected App bundle identifier: \(bundleIdentifier)")
        }
        let executableData = try Data(
            contentsOf: executableURL,
            options: [.mappedIfSafe])
        let executableSHA256 = sha256Hex(executableData)

        var teamIdentifier: String?
        var codeDirectoryHash: String?
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL.standardizedFileURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess, let staticCode {
            var signingInformation: CFDictionary?
            if SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &signingInformation
            ) == errSecSuccess,
               let values = signingInformation as? [String: Any]
            {
                teamIdentifier =
                    (values[kSecCodeInfoTeamIdentifier as String] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                if let digest =
                    values[kSecCodeInfoUnique as String] as? Data,
                   !digest.isEmpty
                {
                    codeDirectoryHash = digest.hexString
                }
            }
        }
        let identity = TatwoHumanGateIssuerArtifactIdentityV1(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier:
                teamIdentifier?.isEmpty == false ? teamIdentifier : nil,
            codeDirectoryHash:
                codeDirectoryHash ?? "unavailable:\(executableSHA256)",
            executableSHA256: executableSHA256
        )
        return try validatedRevisionIssuerArtifact(
            TatwoGoalRevisionIssuerArtifactEvidence(
            identity: identity,
            executableURL: executableURL
            ),
            requestedHostScope: .revisionActivationOnly
        )
    }

    private static func validatedRevisionIssuerArtifact(
        _ artifact: TatwoGoalRevisionIssuerArtifactEvidence,
        requestedHostScope: TatwoGoalRevisionRequestedHostScope
    ) throws -> TatwoGoalRevisionIssuerArtifactEvidence {
        let identity = artifact.identity
        guard identity.schema == "TatwoHumanGateIssuerArtifactIdentityV1",
              !identity.codeDirectoryHash.isEmpty,
              isSHA256Hex(identity.executableSHA256)
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Invalid App issuer artifact identity")
        }
        if identity.bundleIdentifier
            == TatwoGoalRevisionIssuerArtifactPolicy
                .productionBundleIdentifier
        {
            return artifact
        }
        guard TatwoGoalRevisionIssuerArtifactPolicy
                .isIsolatedStagingBundleIdentifier(
                    identity.bundleIdentifier)
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Unexpected App bundle identifier: "
                + identity.bundleIdentifier)
        }
        guard requestedHostScope == .revisionActivationOnly else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging App issuer is restricted to revision activation only")
        }

        let executableURL =
            artifact.executableURL.resolvingSymlinksInPath()
        let macOSDirectoryURL = executableURL.deletingLastPathComponent()
        let contentsURL = macOSDirectoryURL.deletingLastPathComponent()
        let bundleURL = contentsURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard macOSDirectoryURL.lastPathComponent == "MacOS",
              contentsURL.lastPathComponent == "Contents",
              bundleURL.lastPathComponent
                == "Tatwo Ultrawork Staging.app",
              bundleURL.path.hasPrefix(
                "/tmp/tatwo-os-staging-")
                || bundleURL.path.hasPrefix(
                    "/private/tmp/tatwo-os-staging-"),
              bundleURL.deletingLastPathComponent()
                .lastPathComponent.hasPrefix("tatwo-os-staging-")
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision issuer must be an isolated "
                + "/private/tmp bundle")
        }

        let infoURL = bundleURL.appendingPathComponent(
            "Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == identity.bundleIdentifier,
              info["CFBundleExecutable"] as? String
                == executableURL.lastPathComponent
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision issuer bundle metadata mismatch")
        }
        guard let declaredBundlePath =
                info["TatwoStagingDeclaredBundlePath"] as? String
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision issuer must declare a "
                + "/private/tmp bundle path")
        }
        let declaredBundleURL = URL(
            fileURLWithPath: declaredBundlePath,
            isDirectory: true)
        let declaredExecutableURL = declaredBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableURL.lastPathComponent)
        guard declaredBundleURL.path.hasPrefix(
                "/private/tmp/tatwo-os-staging-"),
              declaredBundleURL.deletingLastPathComponent()
                .lastPathComponent.hasPrefix("tatwo-os-staging-"),
              declaredBundleURL.lastPathComponent
                == "Tatwo Ultrawork Staging.app",
              declaredBundleURL.resolvingSymlinksInPath()
                .standardizedFileURL == bundleURL,
              declaredExecutableURL.resolvingSymlinksInPath()
                .standardizedFileURL
                == executableURL.standardizedFileURL
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision issuer must declare a "
                + "/private/tmp bundle path")
        }
        guard info["TatwoStagingRevisionIssuerScope"] as? String
                == "revision_activation_only"
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision activation marker is missing")
        }
        guard let anchor =
                info["TatwoStagingAnchorIdentity"] as? String
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging anchor identity marker is missing")
        }
        let anchorParts = anchor.split(
            separator: "|",
            omittingEmptySubsequences: false)
        guard anchorParts.count == 2,
              anchorParts[0].hasPrefix(
                "ai.tatwo.ultrawork.plg-chain-anchor.staging."),
              anchorParts[1].hasPrefix("staging.")
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging anchor identity marker is invalid")
        }
        guard let executableData = try? Data(
                contentsOf: executableURL,
                options: [.mappedIfSafe]),
              sha256Hex(executableData)
                == identity.executableSHA256.lowercased()
        else {
            throw TatwoGoalRevisionConfirmationError.operationFailed(
                "Staging revision issuer executable hash mismatch")
        }
        return TatwoGoalRevisionIssuerArtifactEvidence(
            identity: identity,
            executableURL: declaredExecutableURL)
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy {
                "0123456789abcdefABCDEF".contains($0)
            }
    }

    private static func proposal(
        challenge: TatwoGoalRevisionChallenge,
        newObjective rawObjective: String,
        allowPlaceholder: Bool
    ) throws -> TatwoGoalRevisionProposal {
        let objective =
            rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            throw TatwoGoalRevisionConfirmationError.invalidNewObjective(
                "不得為空")
        }
        guard allowPlaceholder
                || objective != challenge.initialNewObjective
        else {
            throw TatwoGoalRevisionConfirmationError.invalidNewObjective(
                "仍是預設提示文字，請填入完整 desired outcome 與 constraints")
        }
        guard objective
                != challenge.oldContract.objective
                    .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw TatwoGoalRevisionConfirmationError.invalidNewObjective(
                "不得沿用 predecessor objective")
        }
        let contract = try WorkOSFactory.preview(
            mode: challenge.selection.mode,
            scenarioProfileID: challenge.selection.scenarioProfileID,
            objective: objective,
            scenarioBook: challenge.scenarioBook,
            loopPresetID: challenge.selection.loopPresetID,
            enabledLoopTemplateIDs:
                challenge.selection.loopPresetID == "custom"
                ? challenge.selection.enabledLoopTemplateIDs
                : nil
        )
        guard contract.contractID != challenge.oldContract.contractID,
              contract.goalID != challenge.oldContract.goalID
        else {
            throw TatwoGoalRevisionConfirmationError.unchangedGoal
        }
        let newIssued =
            TatwoIssuedIdentityBindingV1.canonicalSnapshot(for: contract)
        let newBindings = bindingFacts(newIssued)
        let newBindingsDigest =
            TatwoIssuedIdentityBindingV1.deterministicDigest(for: newIssued)
        let topologyDigest =
            TatwoGoalRevisionPromotionAuthorizationV1.topologyDigest(
                sessionID: challenge.sessionID,
                oldContractID: challenge.oldContract.contractID,
                oldGoalID: challenge.oldContract.goalID,
                newContractID: contract.contractID,
                newGoalID: contract.goalID)
        let capabilityDigest =
            TatwoGoalRevisionPromotionAuthorizationV1.capabilityDigest(
                oldBindingsDigest: challenge.oldBindingsDigest,
                newBindingsDigest: newBindingsDigest)
        let requestedHostScopeBytes = Data(
            challenge.requestedHostScope.canonicalValue.utf8)
        let requestedHostScopeDigest =
            "sha256:\(sha256Hex(requestedHostScopeBytes))"
        let subjectDraft = TatwoGoalRevisionPromotionAuthorizationV1(
            id: "subject-preview",
            issuerDomain: TatwoAppHumanGateAuthorizationStore.issuerDomain,
            sessionID: challenge.sessionID,
            oldPointerRevisionDigest:
                challenge.pointerSnapshot.revision.digest,
            oldPointerGeneration:
                challenge.pointerSnapshot.pointer.generation ?? 1,
            oldContractID: challenge.oldContract.contractID,
            oldGoalID: challenge.oldContract.goalID,
            oldGoalRevision: challenge.oldGoalRecord.resolvedRevision,
            oldObjectiveDigest:
                TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
                    challenge.oldGoalRecord.objective),
            newContractID: contract.contractID,
            newGoalID: contract.goalID,
            newGoalRevision: challenge.oldGoalRecord.resolvedRevision + 1,
            newObjectiveDigest:
                TatwoGoalRevisionPromotionAuthorizationV1.objectiveDigest(
                    objective),
            topologyDigest: topologyDigest,
            capabilityDigest: capabilityDigest,
            humanGateReceiptID: "goal-revision-human-\(challenge.id)",
            requestedHostScopeDigest: requestedHostScopeDigest,
            issuedAt: challenge.createdAt,
            expiresAt: challenge.createdAt.addingTimeInterval(600),
            nonce: "subject-preview",
            proofDigest: "subject-preview"
        )
        return TatwoGoalRevisionProposal(
            newContract: contract,
            newBindings: newBindings,
            newBindingsDigest: newBindingsDigest,
            topologyDigest: topologyDigest,
            capabilityDigest: capabilityDigest,
            capabilityChanges: capabilityChanges(
                old: challenge.oldBindings,
                new: newBindings),
            requestedHostScopeDigest: requestedHostScopeDigest,
            humanGateSubjectDigest: subjectDraft.humanGateSubjectDigest
        )
    }

    private static func bindingFacts(
        _ bindings: [TatwoIssuedIdentityBindingV1]
    ) -> [TatwoGoalRevisionBindingFact] {
        bindings.map(TatwoGoalRevisionBindingFact.init).sorted {
            $0.canonicalValue < $1.canonicalValue
        }
    }

    private static func capabilityChanges(
        old: [TatwoGoalRevisionBindingFact],
        new: [TatwoGoalRevisionBindingFact]
    ) -> [TatwoGoalRevisionCapabilityChange] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        return Set(oldByID.keys).union(newByID.keys).sorted().compactMap { id in
            switch (oldByID[id], newByID[id]) {
            case (.some(let old), .some(let new)) where old != new:
                return TatwoGoalRevisionCapabilityChange(
                    kind: .changed,
                    bindingID: id,
                    oldValue: old,
                    newValue: new)
            case (.some(let old), .none):
                return TatwoGoalRevisionCapabilityChange(
                    kind: .removed,
                    bindingID: id,
                    oldValue: old,
                    newValue: nil)
            case (.none, .some(let new)):
                return TatwoGoalRevisionCapabilityChange(
                    kind: .added,
                    bindingID: id,
                    oldValue: nil,
                    newValue: new)
            default:
                return nil
            }
        }
    }

    private static func wholeSecond(_ value: Date) -> Date {
        Date(timeIntervalSince1970: value.timeIntervalSince1970.rounded(.down))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

struct GoalRevisionConfirmationSheet: View {
    let challenge: TatwoGoalRevisionChallenge
    let isConfirming: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var newObjective: String

    init(
        challenge: TatwoGoalRevisionChallenge,
        isConfirming: Bool,
        errorMessage: String?,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (String) -> Void
    ) {
        self.challenge = challenge
        self.isConfirming = isConfirming
        self.errorMessage = errorMessage
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _newObjective = State(initialValue: challenge.initialNewObjective)
    }

    private var proposal: TatwoGoalRevisionProposal? {
        try? challenge.proposal(newObjective: newObjective)
    }

    private var proposalError: String? {
        do {
            _ = try challenge.proposal(newObjective: newObjective)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("確認 Goal revision", systemImage: "arrow.triangle.2.circlepath")
                    .font(.title3.weight(.black))
                Spacer()
                Badge("App human gate")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    goalSection
                    objectiveSection
                    topologySection
                    capabilitySection
                    hostScopeSection
                    artifactSection
                    if let errorMessage {
                        errorStrip(errorMessage)
                    } else if let proposalError {
                        errorStrip(proposalError)
                    }
                }
            }

            Divider()
            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isConfirming)
                    .accessibilityIdentifier("goal-revision-cancel")
                Spacer()
                Button(isConfirming ? "確認中…" : "確認並建立 successor") {
                    onConfirm(newObjective)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isConfirming || proposal == nil)
                .accessibilityIdentifier("goal-revision-confirm")
            }
        }
        .padding(18)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 620)
        .interactiveDismissDisabled(isConfirming)
    }

    private var goalSection: some View {
        revisionCard(title: "Exact old → new Goal") {
            valueRow("Old contract", challenge.oldContract.contractID)
            valueRow("Old goal", challenge.oldContract.goalID)
            valueRow(
                "Old revision",
                String(challenge.oldGoalRecord.resolvedRevision))
            valueRow(
                "Old mode / scenario",
                "\(challenge.oldContract.mode.rawValue) / "
                    + challenge.oldContract.scenario)
            Divider()
            valueRow(
                "New contract",
                proposal?.newContract.contractID ?? "等待有效 objective")
            valueRow(
                "New goal",
                proposal?.newContract.goalID ?? "等待有效 objective")
            valueRow(
                "New revision",
                String(challenge.oldGoalRecord.resolvedRevision + 1))
            valueRow(
                "New mode / exact scenario",
                "\(challenge.selection.mode.rawValue) / "
                    + challenge.selection.scenarioProfileID)
        }
    }

    private var objectiveSection: some View {
        revisionCard(title: "Objective") {
            Text("Old objective")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            Text(challenge.oldContract.objective)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("New objective（必須由人類確認；不可沿用舊值）")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
            TextEditor(text: $newObjective)
                .font(.caption.monospaced())
                .frame(minHeight: 112)
                .padding(6)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("goal-revision-new-objective")
        }
    }

    private var topologySection: some View {
        revisionCard(title: "Topology / model / engine / authority / reasoning") {
            bindingList(title: "Old", bindings: challenge.oldBindings)
            Divider()
            bindingList(title: "New", bindings: proposal?.newBindings ?? [])
            valueRow(
                "Topology digest",
                proposal?.topologyDigest ?? "等待有效 objective")
        }
    }

    private var capabilitySection: some View {
        revisionCard(title: "Capability digest / exact diff") {
            valueRow(
                "Old binding digest",
                challenge.oldBindingsDigest ?? "missing")
            valueRow(
                "New binding digest",
                proposal?.newBindingsDigest ?? "等待有效 objective")
            valueRow(
                "Capability digest",
                proposal?.capabilityDigest ?? "等待有效 objective")
            if let proposal, proposal.capabilityChanges.isEmpty {
                Text("No identity-binding capability change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(proposal?.capabilityChanges ?? []) { change in
                    Text(
                        "\(change.kind.rawValue.uppercased()) "
                            + change.bindingID)
                        .font(.caption.monospaced().weight(.bold))
                    if let old = change.oldValue {
                        Text("− \(old.topologyLine)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let new = change.newValue {
                        Text("+ \(new.topologyLine)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            valueRow(
                "Human gate subject",
                proposal?.humanGateSubjectDigest ?? "等待有效 objective")
        }
    }

    private var hostScopeSection: some View {
        revisionCard(title: "Requested host scope") {
            valueRow("Scope", challenge.requestedHostScope.displayValue)
            valueRow(
                "Scope digest",
                proposal?.requestedHostScopeDigest
                    ?? "等待有效 objective")
            Text("所有 model binding 的 canMutateHost 仍逐列顯示；此確認不建立 host lease。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var artifactSection: some View {
        revisionCard(title: "App issuer artifact") {
            valueRow(
                "Bundle ID",
                challenge.issuerArtifact.identity.bundleIdentifier)
            valueRow(
                "Executable",
                challenge.issuerArtifact.executableURL.path)
            valueRow(
                "Team",
                challenge.issuerArtifact.identity.teamIdentifier ?? "ad-hoc")
            valueRow(
                "CDHash",
                challenge.issuerArtifact.identity.codeDirectoryHash)
            valueRow(
                "Executable SHA256",
                challenge.issuerArtifact.identity.executableSHA256)
        }
    }

    @ViewBuilder
    private func bindingList(
        title: String,
        bindings: [TatwoGoalRevisionBindingFact]
    ) -> some View {
        Text(title)
            .font(.caption.weight(.black))
            .foregroundStyle(.secondary)
        if bindings.isEmpty {
            Text("No bindings")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            ForEach(bindings) { binding in
                Text(binding.topologyLine)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func revisionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.black))
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12))
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
    }

    private func errorStrip(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.red.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10))
    }
}
