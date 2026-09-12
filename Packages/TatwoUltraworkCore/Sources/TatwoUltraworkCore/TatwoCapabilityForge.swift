import Foundation

// MARK: - Mandatory sync catalog

public enum TatwoSyncArtifactKindV1: String, Codable, CaseIterable, Sendable {
    case osDocument
    case durableState
    case skillRepository
    case devicePolicy
    case governanceDocument
    case contentAddressedStore
    case externalCuratedStore
    case sourceArtifact
    case machineLocal
}

public enum TatwoSyncScopeV1: String, Codable, CaseIterable, Sendable {
    case shared
    case deviceOverlay
    case localOnly
    case forbidden
}

public enum TatwoSyncMergePolicyV1: String, Codable, CaseIterable, Sendable {
    case markdownSections
    case keyedJSON
    case repositoryRevision
    case replaceAfterValidation
    case appendOnlyLedger
    case contentAddressed
    case curatedProposal
    case perKeyOverlay
    case singleCanonicalWriter
    case never
}

public enum TatwoSyncActivationPolicyV1: String, Codable, CaseIterable, Sendable {
    case automaticAfterValidation
    case stagedHumanApproval
    case canaryThenStable
    case readOnlyMirror
    case never
}

public struct TatwoSyncCatalogEntryV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let kind: TatwoSyncArtifactKindV1
    public let scope: TatwoSyncScopeV1
    public let relativePath: String?
    public let mergePolicy: TatwoSyncMergePolicyV1
    public let activationPolicy: TatwoSyncActivationPolicyV1
    public let requiredOnDevices: [String]

    public init(
        id: String,
        displayName: String,
        kind: TatwoSyncArtifactKindV1,
        scope: TatwoSyncScopeV1,
        relativePath: String?,
        mergePolicy: TatwoSyncMergePolicyV1,
        activationPolicy: TatwoSyncActivationPolicyV1,
        requiredOnDevices: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.scope = scope
        self.relativePath = relativePath
        self.mergePolicy = mergePolicy
        self.activationPolicy = activationPolicy
        self.requiredOnDevices = requiredOnDevices
    }
}

public enum TatwoSyncCatalogError: Error, Equatable, LocalizedError {
    case duplicateID(String)
    case invalidID(String)
    case forbiddenEntryHasTransferPath(String)
    case forbiddenEntryRequiresNoDevices(String)
    case localOnlyEntryHasTransferPath(String)
    case localOnlyEntryRequiresNoDevices(String)
    case nonTransferableEntryRequiresNeverPolicies(String)
    case transferableEntryMissingPath(String)
    case unsafeTransferPath(String)
    case unregisteredPersistentSurface([String])

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id):
            return "Duplicate sync catalog id: \(id)"
        case .invalidID(let id):
            return "Invalid sync catalog id: \(id)"
        case .forbiddenEntryHasTransferPath(let id):
            return "Forbidden sync entry must not expose a transfer path: \(id)"
        case .forbiddenEntryRequiresNoDevices(let id):
            return "Forbidden sync entry must not require peer devices: \(id)"
        case .localOnlyEntryHasTransferPath(let id):
            return "Local-only sync entry must not expose a transfer path: \(id)"
        case .localOnlyEntryRequiresNoDevices(let id):
            return "Local-only sync entry must not require peer devices: \(id)"
        case .nonTransferableEntryRequiresNeverPolicies(let id):
            return "Forbidden/local-only entries must use never policies: \(id)"
        case .transferableEntryMissingPath(let id):
            return "Transferable sync entry must expose a relative path: \(id)"
        case .unsafeTransferPath(let id):
            return "Sync entry has an unsafe transfer path: \(id)"
        case .unregisteredPersistentSurface(let ids):
            return "Persistent surfaces are missing from the sync catalog: \(ids.joined(separator: ", "))"
        }
    }
}

public struct TatwoSyncCatalogV1: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let entries: [TatwoSyncCatalogEntryV1]

    public init(schemaVersion: Int = 1, entries: [TatwoSyncCatalogEntryV1]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public func validate() throws {
        var seen = Set<String>()
        for entry in entries {
            let trimmed = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed == entry.id, !trimmed.contains("/") else {
                throw TatwoSyncCatalogError.invalidID(entry.id)
            }
            guard seen.insert(entry.id).inserted else {
                throw TatwoSyncCatalogError.duplicateID(entry.id)
            }
            if entry.scope == .forbidden,
               entry.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                throw TatwoSyncCatalogError.forbiddenEntryHasTransferPath(entry.id)
            }
            if entry.scope == .localOnly,
               entry.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                throw TatwoSyncCatalogError.localOnlyEntryHasTransferPath(entry.id)
            }
            if entry.scope == .localOnly, !entry.requiredOnDevices.isEmpty {
                throw TatwoSyncCatalogError.localOnlyEntryRequiresNoDevices(entry.id)
            }
            if entry.scope == .forbidden, !entry.requiredOnDevices.isEmpty {
                throw TatwoSyncCatalogError.forbiddenEntryRequiresNoDevices(entry.id)
            }
            if entry.scope == .forbidden || entry.scope == .localOnly {
                guard entry.mergePolicy == .never, entry.activationPolicy == .never else {
                    throw TatwoSyncCatalogError.nonTransferableEntryRequiresNeverPolicies(entry.id)
                }
            } else {
                guard let path = entry.relativePath?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !path.isEmpty
                else {
                    throw TatwoSyncCatalogError.transferableEntryMissingPath(entry.id)
                }
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.hasPrefix("/"),
                      !components.contains(where: { $0.isEmpty || $0 == ".." })
                else {
                    throw TatwoSyncCatalogError.unsafeTransferPath(entry.id)
                }
            }
        }
    }

    public func validatePersistentSurfaceIDs(_ discoveredIDs: Set<String>) throws {
        try validate()
        let registered = Set(entries.map(\.id))
        let missing = discoveredIDs.subtracting(registered).sorted()
        guard missing.isEmpty else {
            throw TatwoSyncCatalogError.unregisteredPersistentSurface(missing)
        }
    }
}

// MARK: - Sync manifest, staged progress and convergence

public enum TatwoSyncProgressPhaseV1: String, Codable, CaseIterable, Sendable {
    case queued
    case delivered
    case accepted
    case transferring
    case merging
    case validating
    case activating
    case verified
    case converged
    case failed
    case diverged

    public var isTerminalSuccess: Bool {
        self == .verified || self == .converged
    }
}

public struct TatwoSyncManifestItemV1: Codable, Hashable, Sendable, Identifiable {
    public var id: String { catalogID }
    public let catalogID: String
    public let displayName: String
    public let required: Bool
    public let sourceDigest: String

    public init(
        catalogID: String,
        displayName: String,
        required: Bool,
        sourceDigest: String
    ) {
        self.catalogID = catalogID
        self.displayName = displayName
        self.required = required
        self.sourceDigest = sourceDigest
    }
}

public struct TatwoSyncManifestV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourceDeviceID: String
    public let targetDeviceID: String
    public let catalogRevision: String
    public let authorityEpoch: UInt64?
    public let items: [TatwoSyncManifestItemV1]

    public init(
        id: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        catalogRevision: String,
        authorityEpoch: UInt64? = nil,
        items: [TatwoSyncManifestItemV1]
    ) {
        self.id = id
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.catalogRevision = catalogRevision
        self.authorityEpoch = authorityEpoch
        self.items = items
    }
}

public struct TatwoSyncProgressReceiptV1: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        let epoch = authorityEpoch.map(String.init) ?? "missing-epoch"
        let sequence = ledgerSequence.map(String.init) ?? "missing-sequence"
        return "\(manifestID)::\(catalogID)::\(epoch)::\(sequence)::\(phase.rawValue)"
    }
    public let manifestID: String
    public let catalogID: String
    public let phase: TatwoSyncProgressPhaseV1
    public let sourceDigest: String
    public let appliedDigest: String?
    public let message: String
    public let authorityEpoch: UInt64?
    public let ledgerSequence: UInt64?
    public let recordedAt: Date

    public init(
        manifestID: String,
        catalogID: String,
        phase: TatwoSyncProgressPhaseV1,
        sourceDigest: String,
        appliedDigest: String?,
        message: String,
        authorityEpoch: UInt64? = nil,
        ledgerSequence: UInt64? = nil,
        recordedAt: Date = Date()
    ) {
        self.manifestID = manifestID
        self.catalogID = catalogID
        self.phase = phase
        self.sourceDigest = sourceDigest
        self.appliedDigest = appliedDigest
        self.message = message
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.recordedAt = recordedAt
    }
}

public enum TatwoConvergenceStateV1: String, Codable, Sendable {
    case partial
    case diverged
    case failed
    case converged
}

public struct TatwoConvergenceReceiptV1: Codable, Hashable, Sendable {
    public let manifestID: String
    public let sourceDeviceID: String
    public let targetDeviceID: String
    public let state: TatwoConvergenceStateV1
    public let missingOrDivergedCatalogIDs: [String]
    public let verifiedCatalogIDs: [String]

    public init(
        manifestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        state: TatwoConvergenceStateV1,
        missingOrDivergedCatalogIDs: [String],
        verifiedCatalogIDs: [String]
    ) {
        self.manifestID = manifestID
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.state = state
        self.missingOrDivergedCatalogIDs = missingOrDivergedCatalogIDs
        self.verifiedCatalogIDs = verifiedCatalogIDs
    }
}

public enum TatwoConvergenceEvaluatorV1 {
    public static func evaluate(
        manifest: TatwoSyncManifestV1,
        progress: [TatwoSyncProgressReceiptV1]
    ) -> TatwoConvergenceReceiptV1 {
        let relevant = progress.filter { $0.manifestID == manifest.id }
        var verified: [String] = []
        var incomplete: [String] = []
        var sawFailure = false
        var sawDivergence = false
        let requiredItems = manifest.items.filter(\.required)
        let requiredIDs = requiredItems.map(\.catalogID)

        guard !requiredItems.isEmpty else {
            return TatwoConvergenceReceiptV1(
                manifestID: manifest.id,
                sourceDeviceID: manifest.sourceDeviceID,
                targetDeviceID: manifest.targetDeviceID,
                state: .partial,
                missingOrDivergedCatalogIDs: ["manifest.required-items"],
                verifiedCatalogIDs: []
            )
        }
        guard Set(requiredIDs).count == requiredIDs.count else {
            return TatwoConvergenceReceiptV1(
                manifestID: manifest.id,
                sourceDeviceID: manifest.sourceDeviceID,
                targetDeviceID: manifest.targetDeviceID,
                state: .diverged,
                missingOrDivergedCatalogIDs: Array(Set(requiredIDs)).sorted(),
                verifiedCatalogIDs: []
            )
        }
        guard let authorityEpoch = manifest.authorityEpoch else {
            return TatwoConvergenceReceiptV1(
                manifestID: manifest.id,
                sourceDeviceID: manifest.sourceDeviceID,
                targetDeviceID: manifest.targetDeviceID,
                state: .partial,
                missingOrDivergedCatalogIDs: requiredIDs.sorted(),
                verifiedCatalogIDs: []
            )
        }

        if relevant.contains(where: {
            guard let receiptEpoch = $0.authorityEpoch else { return false }
            return receiptEpoch > authorityEpoch
        }) {
            return TatwoConvergenceReceiptV1(
                manifestID: manifest.id,
                sourceDeviceID: manifest.sourceDeviceID,
                targetDeviceID: manifest.targetDeviceID,
                state: .diverged,
                missingOrDivergedCatalogIDs: requiredIDs.sorted(),
                verifiedCatalogIDs: []
            )
        }

        let currentEpochProgress = relevant.filter {
            $0.authorityEpoch == authorityEpoch
                && ($0.ledgerSequence ?? 0) > 0
        }
        let progressByCatalog = Dictionary(
            grouping: currentEpochProgress,
            by: \.catalogID
        )

        for item in requiredItems {
            guard let receipts = progressByCatalog[item.catalogID],
                  let highestSequence = receipts.compactMap(\.ledgerSequence).max()
            else {
                incomplete.append(item.catalogID)
                continue
            }
            let latest = receipts.filter { $0.ledgerSequence == highestSequence }
            guard let receipt = latest.first,
                  latest.dropFirst().allSatisfy({
                      $0.manifestID == receipt.manifestID
                          && $0.catalogID == receipt.catalogID
                          && $0.phase == receipt.phase
                          && $0.sourceDigest == receipt.sourceDigest
                          && $0.appliedDigest == receipt.appliedDigest
                          && $0.message == receipt.message
                          && $0.authorityEpoch == receipt.authorityEpoch
                          && $0.ledgerSequence == receipt.ledgerSequence
                  })
            else {
                sawDivergence = true
                incomplete.append(item.catalogID)
                continue
            }
            if receipt.phase == .failed {
                sawFailure = true
                incomplete.append(item.catalogID)
            } else if receipt.phase == .diverged {
                sawDivergence = true
                incomplete.append(item.catalogID)
            } else if receipt.phase.isTerminalSuccess {
                if receipt.sourceDigest == item.sourceDigest,
                   receipt.appliedDigest == item.sourceDigest
                {
                    verified.append(item.catalogID)
                } else {
                    sawDivergence = true
                    incomplete.append(item.catalogID)
                }
            } else {
                incomplete.append(item.catalogID)
            }
        }

        let state: TatwoConvergenceStateV1
        if sawFailure {
            state = .failed
        } else if sawDivergence {
            state = .diverged
        } else if incomplete.isEmpty {
            state = .converged
        } else {
            state = .partial
        }

        return TatwoConvergenceReceiptV1(
            manifestID: manifest.id,
            sourceDeviceID: manifest.sourceDeviceID,
            targetDeviceID: manifest.targetDeviceID,
            state: state,
            missingOrDivergedCatalogIDs: incomplete.sorted(),
            verifiedCatalogIDs: verified.sorted()
        )
    }
}

// MARK: - Skillet private capability repositories

public enum TatwoSkillChannelV1: String, Codable, CaseIterable, Sendable {
    case draft
    case staging
    case canary
    case stable
    case rollback
}

public struct TatwoSkillRevisionV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String
    public let parentRevisionID: String?
    public let contentDigest: String
    public let channel: TatwoSkillChannelV1
    public let createdAt: Date

    public init(
        id: String,
        repositoryID: String,
        parentRevisionID: String?,
        contentDigest: String,
        channel: TatwoSkillChannelV1,
        createdAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.parentRevisionID = parentRevisionID
        self.contentDigest = contentDigest
        self.channel = channel
        self.createdAt = createdAt
    }
}

public enum TatwoSkillActivationStateV1: String, Codable, Sendable {
    case inactive
    case staged
    case canary
    case active
    case failed
    case rolledBack
}

public struct TatwoDeviceHeadV1: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(repositoryID)::\(deviceID)" }
    public let deviceID: String
    public let repositoryID: String
    public let revisionID: String
    public let contentDigest: String
    public let requestID: String
    public let authorityEpoch: UInt64
    public let ledgerSequence: UInt64?
    public let activationState: TatwoSkillActivationStateV1
    public let lastVerifiedAt: Date?

    public init(
        deviceID: String,
        repositoryID: String,
        revisionID: String,
        contentDigest: String = "",
        requestID: String = "",
        authorityEpoch: UInt64 = 0,
        ledgerSequence: UInt64? = nil,
        activationState: TatwoSkillActivationStateV1,
        lastVerifiedAt: Date?
    ) {
        self.deviceID = deviceID
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
        self.requestID = requestID
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.activationState = activationState
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public enum TatwoSkilletReceiptKindV1: String, Codable, Sendable {
    case snapshot
    case promotion
    case deviceHead
    case rollback
    case archive
}

public struct TatwoSkilletRepositoryReceiptV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String
    public let revisionID: String
    public let kind: TatwoSkilletReceiptKindV1
    public let contentDigest: String
    public let deviceID: String?
    public let requestID: String?
    public let authorityEpoch: UInt64?
    public let ledgerSequence: UInt64?
    public let activationState: TatwoSkillActivationStateV1?
    public let recordedAt: Date
    public let message: String

    public init(
        id: String,
        repositoryID: String,
        revisionID: String,
        kind: TatwoSkilletReceiptKindV1,
        contentDigest: String,
        deviceID: String? = nil,
        requestID: String? = nil,
        authorityEpoch: UInt64? = nil,
        ledgerSequence: UInt64? = nil,
        activationState: TatwoSkillActivationStateV1? = nil,
        recordedAt: Date = Date(),
        message: String
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.kind = kind
        self.contentDigest = contentDigest
        self.deviceID = deviceID
        self.requestID = requestID
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.activationState = activationState
        self.recordedAt = recordedAt
        self.message = message
    }
}

public enum TatwoCapabilityRepositoryHealthV1: String, Codable, Sendable {
    case healthy
    case canary
    case diverged
    case failed
    case unavailable
}

public struct TatwoCapabilityRepositoryV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let canonicalRevision: String?
    public let stableRevision: String?
    public let canaryRevision: String?
    public let rollbackRevision: String?
    public let revisions: [TatwoSkillRevisionV1]
    public let deviceHeads: [TatwoDeviceHeadV1]

    public init(
        id: String,
        displayName: String,
        summary: String,
        canonicalRevision: String?,
        stableRevision: String?,
        canaryRevision: String?,
        rollbackRevision: String? = nil,
        revisions: [TatwoSkillRevisionV1],
        deviceHeads: [TatwoDeviceHeadV1]
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.canonicalRevision = canonicalRevision
        self.stableRevision = stableRevision
        self.canaryRevision = canaryRevision
        self.rollbackRevision = rollbackRevision
        self.revisions = revisions
        self.deviceHeads = deviceHeads
    }

    public var compatibleDeviceCount: Int {
        guard let canonicalRevision else { return 0 }
        return deviceHeads.filter { head in
            head.activationState == .active
                && head.revisionID == canonicalRevision
                && head.lastVerifiedAt != nil
                && (head.ledgerSequence ?? 0) > 0
                && !head.requestID.isEmpty
        }.count
    }

    public func verifiedDeviceHeads(
        receipts: [TatwoSkilletRepositoryReceiptV1]
    ) -> [TatwoDeviceHeadV1] {
        guard let canonicalRevision,
              let canonical = revisions.first(where: { $0.id == canonicalRevision })
        else {
            return []
        }

        return deviceHeads.filter { head in
            guard head.activationState == .active,
                  head.revisionID == canonicalRevision,
                  head.contentDigest == canonical.contentDigest,
                  let verifiedAt = head.lastVerifiedAt,
                  let ledgerSequence = head.ledgerSequence,
                  ledgerSequence > 0,
                  !head.requestID.isEmpty
            else {
                return false
            }

            return receipts.contains { receipt in
                receipt.kind == .deviceHead
                    && receipt.repositoryID == id
                    && receipt.revisionID == canonicalRevision
                    && receipt.contentDigest == canonical.contentDigest
                    && receipt.deviceID == head.deviceID
                    && receipt.requestID == head.requestID
                    && receipt.authorityEpoch == head.authorityEpoch
                    && receipt.ledgerSequence == ledgerSequence
                    && receipt.activationState == .active
                    && receipt.recordedAt == verifiedAt
            }
        }
        .sorted {
            if $0.deviceID == $1.deviceID {
                return ($0.ledgerSequence ?? 0) < ($1.ledgerSequence ?? 0)
            }
            return $0.deviceID < $1.deviceID
        }
    }

    public func matchingDeviceReceipt(
        for head: TatwoDeviceHeadV1,
        receipts: [TatwoSkilletRepositoryReceiptV1]
    ) -> TatwoSkilletRepositoryReceiptV1? {
        verifiedDeviceHeads(receipts: receipts).contains(head)
            ? receipts.first { receipt in
                receipt.kind == .deviceHead
                    && receipt.repositoryID == head.repositoryID
                    && receipt.revisionID == head.revisionID
                    && receipt.contentDigest == head.contentDigest
                    && receipt.deviceID == head.deviceID
                    && receipt.requestID == head.requestID
                    && receipt.authorityEpoch == head.authorityEpoch
                    && receipt.ledgerSequence == head.ledgerSequence
                    && receipt.activationState == head.activationState
                    && receipt.recordedAt == head.lastVerifiedAt
            }
            : nil
    }

    public var health: TatwoCapabilityRepositoryHealthV1 {
        guard !revisions.isEmpty else { return .unavailable }
        if deviceHeads.contains(where: { $0.activationState == .failed }) {
            return .failed
        }
        if deviceHeads.contains(where: { head in
            head.activationState == .active
                && stableRevision != nil
                && head.revisionID != stableRevision
        }) {
            return .diverged
        }
        if canaryRevision != nil
            || deviceHeads.contains(where: { $0.activationState == .canary })
        {
            return .canary
        }
        return .healthy
    }
}

public enum TatwoMergeProposalStatusV1: String, Codable, Hashable, Sendable {
    case pending
    case approved
    case rejected
}

public struct TatwoMergeProposalV1: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let repositoryID: String
    public let sourceDeviceID: String
    public let baseRevisionID: String?
    public let canonicalRevisionID: String
    public let proposedRevisionID: String
    public let mergedRevisionID: String?
    public let conflictArtifactIDs: [String]
    public let requiresHumanApproval: Bool
    public let status: TatwoMergeProposalStatusV1
    public let createdAt: Date

    public init(
        id: String,
        repositoryID: String,
        sourceDeviceID: String,
        baseRevisionID: String?,
        canonicalRevisionID: String,
        proposedRevisionID: String,
        mergedRevisionID: String?,
        conflictArtifactIDs: [String],
        requiresHumanApproval: Bool = true,
        status: TatwoMergeProposalStatusV1 = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.sourceDeviceID = sourceDeviceID
        self.baseRevisionID = baseRevisionID
        self.canonicalRevisionID = canonicalRevisionID
        self.proposedRevisionID = proposedRevisionID
        self.mergedRevisionID = mergedRevisionID
        self.conflictArtifactIDs = conflictArtifactIDs.sorted()
        self.requiresHumanApproval = requiresHumanApproval
        self.status = status
        self.createdAt = createdAt
    }
}

public struct TatwoMergeDecisionReceiptV1:
    Codable, Hashable, Sendable, Identifiable
{
    public let id: String
    public let repositoryID: String
    public let proposalID: String
    public let status: TatwoMergeProposalStatusV1
    public let decidedBy: String
    public let decidedAt: Date
    public let resolvedRevisionID: String?
    public let message: String
    public let stalenessReason: String?
    public let corruptionReason: String?

    public init(
        id: String,
        repositoryID: String,
        proposalID: String,
        status: TatwoMergeProposalStatusV1,
        decidedBy: String,
        decidedAt: Date,
        resolvedRevisionID: String?,
        message: String,
        stalenessReason: String? = nil,
        corruptionReason: String? = nil
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.proposalID = proposalID
        self.status = status
        self.decidedBy = decidedBy
        self.decidedAt = decidedAt
        self.resolvedRevisionID = resolvedRevisionID
        self.message = message
        self.stalenessReason = stalenessReason
        self.corruptionReason = corruptionReason
    }
}
