import Foundation
import CryptoKit
import SwiftUI
import TatwoUltraworkCore

struct TatwoAppAuthorityBootstrapProposalV1:
    Identifiable, Sendable, Equatable
{
    let schema = "TatwoAppAuthorityBootstrapProposalV1"
    let canonicalGoalStoreRootPath: String
    let contractID: String
    let owner: TatwoCanonicalSessionOwnerV1
    let preflight: TatwoSessionAuthorityLockPreflightV1
    let objectivePreview: String

    var id: String {
        canonicalGoalStoreRootPath + "#" + contractID
    }

    var authoritySubjectDigest: String {
        Self.digest([
            schema,
            canonicalGoalStoreRootPath,
            contractID,
            owner.provider,
            owner.ownerKind.rawValue,
            owner.externalProviderID,
            owner.workspacePath,
            objectivePreview,
        ])
    }

    var preflightDigest: String {
        Self.digest([
            preflight.schema,
            preflight.canonicalGoalStoreRootPath,
            preflight.contractID,
            String(preflight.rootDeviceID),
            String(preflight.rootInode),
            preflight.presentArtifactNames.joined(separator: "\u{1F}"),
            preflight.artifactFingerprints.joined(separator: "\u{1E}"),
        ])
    }

    var bootstrapDispositionPreview: String {
        let present = Set(preflight.presentArtifactNames)
        if present.isEmpty { return "create_global_and_contract_lifecycle" }
        let contractLock = "\(contractID).state.lock"
        let contractReceipt = "\(contractID).state.lock.initialized.json"
        let required: Set<String> = [
            TatwoGoalStoreGlobalLock.lockFileName,
            TatwoGoalStoreGlobalLock.initializationReceiptFileName,
            TatwoGoalStoreLifecycleLock.lifecycleDirectoryName,
            contractLock,
            contractReceipt,
        ]
        if present == required { return "validate_existing" }
        let globalAndDirectory: Set<String> = [
            TatwoGoalStoreGlobalLock.lockFileName,
            TatwoGoalStoreGlobalLock.initializationReceiptFileName,
            TatwoGoalStoreLifecycleLock.lifecycleDirectoryName,
        ]
        if present == Set([
            TatwoGoalStoreLifecycleLock.lifecycleDirectoryName
        ]) {
            return
                "create_global_and_contract_lifecycle_preserving_existing_directory"
        }
        if globalAndDirectory.isSubset(of: present),
           !present.contains(contractLock),
           !present.contains(contractReceipt)
        {
            return "create_contract_lifecycle_only"
        }
        return "blocked_mixed_or_partial"
    }

    init(
        goalStoreRoot: URL,
        contractID: String,
        owner: TatwoCanonicalSessionOwnerV1,
        preflight: TatwoSessionAuthorityLockPreflightV1,
        objectivePreview: String
    ) {
        canonicalGoalStoreRootPath =
            goalStoreRoot.standardizedFileURL.resolvingSymlinksInPath().path
        self.contractID = contractID
        self.owner = owner
        self.preflight = preflight
        self.objectivePreview = objectivePreview
    }

    private static func digest(_ fields: [String]) -> String {
        let data = fields
            .joined(separator: "\u{1D}")
            .data(using: .utf8) ?? Data()
        return "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct TatwoAppAuthorityBootstrapConfirmationV1:
    Sendable, Equatable
{
    let schema = "TatwoAppAuthorityBootstrapConfirmationV1"
    let proposal: TatwoAppAuthorityBootstrapProposalV1
    let readback: TatwoSessionAuthorityLockBootstrapResultV1
    let confirmedAt: Date
    let expiresAt: Date

    init(
        proposal: TatwoAppAuthorityBootstrapProposalV1,
        readback: TatwoSessionAuthorityLockBootstrapResultV1,
        confirmedAt: Date = Date(),
        ttl: TimeInterval = 600
    ) {
        self.proposal = proposal
        self.readback = readback
        self.confirmedAt = confirmedAt
        let boundedTTL = max(60, min(ttl, 30 * 60))
        self.expiresAt = confirmedAt.addingTimeInterval(boundedTTL)
    }
}

private enum TatwoAppAuthorityBootstrapActivationError:
    LocalizedError
{
    case notUserOwnedThread
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .notUserOwnedThread:
            return
                "automatic authority bootstrap is restricted to an explicit user-owned Tatwo Chat thread"
        case .readbackMismatch:
            return
                "authority bootstrap fresh readback did not match the exact contract and preflight"
        }
    }
}

/// App-owned human gate for initial authority-lock bootstrap.
///
/// Merely staging a proposal is read-only. Mutation is allowed only through
/// either the visible AppShell confirmation action or an explicit `/goal` /
/// `/plg` submit from its exact user-owned Tatwo thread. Both routes invoke the
/// shared Core primitive and then invoke it again for a fresh existing-only
/// readback. ChatPageModel can consume only that second,
/// contract/owner-bound result.
@MainActor
final class TatwoAppAuthorityBootstrapModel: ObservableObject {
    static let defaultConfirmationTTL: TimeInterval = 10 * 60

    @Published private(set) var pendingProposal:
        TatwoAppAuthorityBootstrapProposalV1?
    @Published private(set) var confirmed:
        TatwoAppAuthorityBootstrapConfirmationV1?
    @Published private(set) var isConfirming = false
    @Published private(set) var statusMessage =
        "尚未要求初始化 Goal authority locks"
    @Published private(set) var errorMessage: String?
    private let confirmationTTL: TimeInterval

    init(confirmationTTL: TimeInterval = TatwoAppAuthorityBootstrapModel.defaultConfirmationTTL) {
        self.confirmationTTL = confirmationTTL
    }

    func stage(
        _ proposal: TatwoAppAuthorityBootstrapProposalV1
    ) {
        if confirmedReadbackMatches(proposal) {
            pendingProposal = nil
            return
        }
        pendingProposal = proposal
        errorMessage = nil
        statusMessage =
            "等待你在 App 內確認初始化 Goal authority locks"
    }

    func consumeConfirmedReadback(
        for proposal: TatwoAppAuthorityBootstrapProposalV1
    ) -> Bool {
        guard confirmedReadbackMatches(proposal) else { return false }
        self.confirmed = nil
        return true
    }

    /// `/goal` and `/plg` are themselves explicit owner actions when submitted
    /// from a Tatwo-created user thread. They may initialize the exact
    /// contract-bound authority locks without a second hidden AppShell ritual,
    /// but still go through the same bootstrap primitive and fresh readback as
    /// the visible confirmation gate. Codex-mirror and provider-session owners
    /// remain on the separately confirmed path.
    func bootstrapAndConsumeExplicitUserOwnedActivation(
        _ proposal: TatwoAppAuthorityBootstrapProposalV1
    ) throws -> Bool {
        guard proposal.owner.provider == "tatwo-chat",
              proposal.owner.ownerKind == .thread
        else {
            throw TatwoAppAuthorityBootstrapActivationError
                .notUserOwnedThread
        }
        let confirmation = try Self.bootstrapConfirmation(
            proposal: proposal,
            confirmationTTL: confirmationTTL)
        confirmed = confirmation
        pendingProposal = nil
        errorMessage = nil
        statusMessage =
            "User-owned Work OS activation 已完成 authority-lock fresh readback。"
        let freshReadbackProposal =
            TatwoAppAuthorityBootstrapProposalV1(
                goalStoreRoot: URL(
                    fileURLWithPath:
                        confirmation.readback
                            .canonicalGoalStoreRootPath,
                    isDirectory: true),
                contractID: confirmation.readback.contractID,
                owner: proposal.owner,
                preflight:
                    confirmation.readback.validatedPreflight,
                objectivePreview: proposal.objectivePreview)
        return consumeConfirmedReadback(
            for: freshReadbackProposal)
    }

    private func confirmedReadbackMatches(
        _ proposal: TatwoAppAuthorityBootstrapProposalV1
    ) -> Bool {
        guard let confirmed,
              confirmed.expiresAt > Date(),
              confirmed.proposal.authoritySubjectDigest
                == proposal.authoritySubjectDigest,
              confirmed.readback.disposition == .validatedExisting,
              confirmed.readback.canonicalGoalStoreRootPath
                == proposal.canonicalGoalStoreRootPath,
              confirmed.readback.contractID == proposal.contractID,
              confirmed.readback.validatedPreflight == proposal.preflight
        else { return false }
        return true
    }

    func dismissPending() {
        guard !isConfirming else { return }
        pendingProposal = nil
        confirmed = nil
        errorMessage = nil
        statusMessage = "你已取消 authority-lock bootstrap；未建立任何 Goal。"
    }

    func confirmPending() async {
        guard !isConfirming, let proposal = pendingProposal else { return }
        isConfirming = true
        errorMessage = nil
        let confirmationTTL = self.confirmationTTL
        let payload:
            (
                confirmation: TatwoAppAuthorityBootstrapConfirmationV1?,
                error: String?
            ) = await Task.detached(priority: .userInitiated) {
                do {
                    return (
                        confirmation:
                            try Self.bootstrapConfirmation(
                                proposal: proposal,
                                confirmationTTL: confirmationTTL),
                        error: Optional<String>.none
                    )
                } catch {
                    return (
                        confirmation:
                            Optional<
                                TatwoAppAuthorityBootstrapConfirmationV1
                            >.none,
                        error: TatwoPrivacyRedactor.redacted(
                            error.localizedDescription)
                    )
                }
            }.value
        isConfirming = false
        if let confirmation = payload.confirmation {
            confirmed = confirmation
            pendingProposal = nil
            statusMessage =
                "Authority locks 已由你確認並完成 fresh readback；10 分鐘內可重新送出 /goal 或 /plg。"
        } else {
            errorMessage = payload.error
            statusMessage =
                "Authority-lock bootstrap 已停止；partial/corrupt state 不會被修復。"
        }
    }

    nonisolated private static func bootstrapConfirmation(
        proposal: TatwoAppAuthorityBootstrapProposalV1,
        confirmationTTL: TimeInterval
    ) throws -> TatwoAppAuthorityBootstrapConfirmationV1 {
        let root = URL(
            fileURLWithPath: proposal.canonicalGoalStoreRootPath,
            isDirectory: true)
        let first =
            try TatwoSessionAuthorityLockBootstrap
                .bootstrapExplicitly(
                    goalStoreRoot: root,
                    contractID: proposal.contractID,
                    expectedPreflight: proposal.preflight)
        let readback =
            try TatwoSessionAuthorityLockBootstrap
                .bootstrapExplicitly(
                    goalStoreRoot: root,
                    contractID: proposal.contractID,
                    expectedPreflight: first.validatedPreflight)
        guard readback.disposition == .validatedExisting,
              first.canonicalGoalStoreRootPath
                == readback.canonicalGoalStoreRootPath,
              first.contractID == readback.contractID,
              first.globalInitializationReceiptSHA256
                == readback.globalInitializationReceiptSHA256,
              first.lifecycleInitializationReceiptSHA256
                == readback.lifecycleInitializationReceiptSHA256
        else {
            throw TatwoAppAuthorityBootstrapActivationError
                .readbackMismatch
        }
        return TatwoAppAuthorityBootstrapConfirmationV1(
            proposal: proposal,
            readback: readback,
            ttl: confirmationTTL)
    }

    #if DEBUG
        func installConfirmedForTesting(
            _ confirmation: TatwoAppAuthorityBootstrapConfirmationV1
        ) {
            confirmed = confirmation
        }
    #endif
}
