import CryptoKit
import Foundation
import TatwoUltraworkCore

enum DeviceSyncCatalogProjection {
    static let currentDocument: TatwoSyncCatalogDocumentV1? = try? .loadBundled()

    static var currentRevision: String? {
        currentDocument?.catalogRevision
    }

    static var systemPullItemIDs: [String] {
        currentDocument?.systemPullItemIDs ?? []
    }

    static var systemPullItemNames: [String: String] {
        guard let currentDocument else { return [:] }
        let activeIDs = Set(currentDocument.systemPullItemIDs)
        return Dictionary(
            uniqueKeysWithValues: currentDocument.entries.compactMap { entry in
                guard activeIDs.contains(entry.id) else { return nil }
                return (entry.id, displayName(for: entry.id, fallback: entry.displayName))
            }
        )
    }

    static func displayName(for id: String, fallback: String? = nil) -> String {
        switch id {
        case "os.constitution": "os.md"
        case "os.issue": "issue.md"
        case "os.todo": "TODO.md"
        case "skills.skillet": "Skillet repositories"
        default: fallback ?? id
        }
    }
}

enum DeviceSyncAction {
    static let supported: Set<String> = [
        "system-pull",
        "version-pull",
        "db-pull",
        "both",
    ]
    static let requestable: Set<String> = [
        "system-pull",
        "version-pull",
        "db-pull",
    ]

    static func canonicalArtifactValue(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard value == normalized, supported.contains(normalized) else {
            return nil
        }
        return normalized
    }

    static func canonicalRequestValue(_ value: String) -> String? {
        guard let canonical = canonicalArtifactValue(value),
              requestable.contains(canonical)
        else {
            return nil
        }
        return canonical
    }
}

enum DeviceSyncOutboxError: LocalizedError {
    case unsupportedRequestAction(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRequestAction(let action):
            if action == "both" {
                return "Combined sync cannot prove one digest contract; send system and version requests separately（請分開同步）。"
            }
            return "Unsupported device sync request action: \(action)"
        }
    }
}

struct DeviceSyncOperationKey: Hashable, Identifiable, Sendable {
    let target: String
    let action: String

    init(target: String, action: String) {
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.action = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var id: String { "\(target)::\(action)" }

    var displayName: String {
        switch action {
        case "system-pull": "OS 資料"
        case "version-pull": "來源版本"
        case "db-pull": "Goal 狀態"
        case "both": "舊版合併同步（不再接受）"
        default: action
        }
    }
}

struct DeviceSyncIntent: Codable, Equatable, Sendable {
    let target: String
    let action: String
    let requestedAt: Date

    var operationKey: DeviceSyncOperationKey {
        DeviceSyncOperationKey(target: target, action: action)
    }
}

enum DeviceSyncReceiptPhase: String, Codable, Equatable, CaseIterable, Sendable {
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

    var progressFraction: Double {
        switch self {
        case .queued: 0.08
        case .delivered: 0.25
        case .accepted: 0.34
        case .transferring: 0.48
        case .merging: 0.60
        case .validating: 0.72
        case .activating: 0.84
        case .verified: 0.94
        case .converged: 1
        case .failed: 0.76
        case .diverged: 0.88
        }
    }
}

struct DeviceSyncProgressPayload: Codable, Equatable, Sendable {
    let completedUnits: Int?
    let totalUnits: Int?
    let percent: Int?
    let completedBytes: Int64?
    let totalBytes: Int64?
    let completedItems: Int?
    let totalItems: Int?
    let completedRepositories: Int?
    let totalRepositories: Int?
    let elapsedMilliseconds: Int64?
    let throughputBytesPerSecond: Double?
    let currentItem: String?

    init(
        completedUnits: Int? = nil,
        totalUnits: Int? = nil,
        percent: Int? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        completedItems: Int? = nil,
        totalItems: Int? = nil,
        completedRepositories: Int? = nil,
        totalRepositories: Int? = nil,
        elapsedMilliseconds: Int64? = nil,
        throughputBytesPerSecond: Double? = nil,
        currentItem: String? = nil
    ) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.percent = percent
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.completedRepositories = completedRepositories
        self.totalRepositories = totalRepositories
        self.elapsedMilliseconds = elapsedMilliseconds
        self.throughputBytesPerSecond = throughputBytesPerSecond
        self.currentItem = currentItem
    }

    var hasMeasuredProgress: Bool {
        measuredFraction != nil
    }

    fileprivate var preferredFraction: Double? {
        measuredFraction
            ?? Self.validFraction(completed: completedUnits, total: totalUnits)
            ?? percent.flatMap { value in
                (0...100).contains(value) ? Double(value) / 100 : nil
            }
    }

    private var measuredFraction: Double? {
        Self.validFraction(completed: completedBytes, total: totalBytes)
            ?? Self.validFraction(completed: completedItems, total: totalItems)
            ?? Self.validFraction(
                completed: completedRepositories,
                total: totalRepositories
            )
    }

    private static func validFraction<T: BinaryInteger>(
        completed: T?,
        total: T?
    ) -> Double? {
        guard let completed,
              let total,
              completed >= 0,
              total > 0,
              completed <= total
        else {
            return nil
        }
        return Double(completed) / Double(total)
    }
}

struct DeviceSyncProgressValue: Equatable, Sendable {
    enum Provenance: String, Equatable, Sendable {
        case artifact
        case phaseDerived
        case synthetic
    }

    let fraction: Double
    let provenance: Provenance

    var percent: Int {
        Int((fraction * 100).rounded())
    }

    var percentLabel: String {
        "\(percent)%"
    }

    static func make(
        payload: DeviceSyncProgressPayload?,
        fallbackPhase: DeviceSyncReceiptPhase,
        provenance: Provenance = .phaseDerived
    ) -> DeviceSyncProgressValue {
        let failureCeiling = fallbackPhase == .failed || fallbackPhase == .diverged
            ? fallbackPhase.progressFraction
            : 1
        if let artifactFraction = payload?.preferredFraction {
            return DeviceSyncProgressValue(
                fraction: min(artifactFraction, failureCeiling),
                provenance: .artifact
            )
        }
        return DeviceSyncProgressValue(
            fraction: fallbackPhase.progressFraction,
            provenance: provenance
        )
    }
}

struct DeviceSyncItemReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let phase: DeviceSyncReceiptPhase
    let digestAlgorithm: String?
    let sourceDigest: String?
    let appliedDigest: String?
    let message: String
    let repositoryCount: Int?
    let repositories: [DeviceSyncSkilletRepositoryReceipt]?
    let targetPreservedCount: Int?
    let targetPreservedRepositories:
        [DeviceSyncTargetPreservedRepositoryReceipt]?
    let targetPreservedRuntimeClosureCapability: String?
    let targetPreservedRuntimeClosed: Bool?
    let progress: DeviceSyncProgressPayload?

    init(
        id: String,
        displayName: String,
        phase: DeviceSyncReceiptPhase,
        digestAlgorithm: String? = nil,
        sourceDigest: String?,
        appliedDigest: String?,
        message: String,
        repositoryCount: Int? = nil,
        repositories: [DeviceSyncSkilletRepositoryReceipt]? = nil,
        targetPreservedCount: Int? = nil,
        targetPreservedRepositories:
            [DeviceSyncTargetPreservedRepositoryReceipt]? = nil,
        targetPreservedRuntimeClosureCapability: String? = nil,
        targetPreservedRuntimeClosed: Bool? = nil,
        progress: DeviceSyncProgressPayload? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.phase = phase
        self.digestAlgorithm = digestAlgorithm
        self.sourceDigest = sourceDigest
        self.appliedDigest = appliedDigest
        self.message = message
        self.repositoryCount = repositoryCount
        self.repositories = repositories
        self.targetPreservedCount = targetPreservedCount
        self.targetPreservedRepositories = targetPreservedRepositories
        self.targetPreservedRuntimeClosureCapability =
            targetPreservedRuntimeClosureCapability
        self.targetPreservedRuntimeClosed = targetPreservedRuntimeClosed
        self.progress = progress
    }

    var isVerified: Bool {
        phase == .verified
            && DeviceSyncDigestValidator.matches(
                algorithm: digestAlgorithm,
                source: sourceDigest,
                applied: appliedDigest
            )
            && (progress == nil || progressValue.fraction >= 1)
    }

    func isVerified(in receipt: DeviceSyncReceipt) -> Bool {
        guard isVerified else { return false }
        if id == "skills.skillet" {
            guard let repositoryCount, repositoryCount >= 0,
                  let repositories,
                  repositoryCount == repositories.count
            else {
                return false
            }
            let repositoryIDs = repositories.map(\.repositoryID)
            guard Set(repositoryIDs).count == repositoryIDs.count,
                  repositoryIDs == repositoryIDs.sorted()
            else {
                return false
            }
            return repositories.allSatisfy { $0.isVerified(in: receipt) }
                && hasValidTargetPreservedRuntimeClosure
        }
        return repositoryCount == nil
            && repositories == nil
            && targetPreservedCount == nil
            && targetPreservedRepositories == nil
            && targetPreservedRuntimeClosureCapability == nil
            && targetPreservedRuntimeClosed == nil
    }

    var progressValue: DeviceSyncProgressValue {
        if progress == nil, phase == .verified {
            return DeviceSyncProgressValue(fraction: 1, provenance: .synthetic)
        }
        return DeviceSyncProgressValue.make(payload: progress, fallbackPhase: phase)
    }

    func containsVerifiedSkilletConsumerReference(
        revisionID: String,
        contentDigest: String
    ) -> Bool {
        if repositories?.contains(where: {
            $0.revisionID == revisionID && $0.contentDigest == contentDigest
        }) == true {
            return true
        }
        guard hasValidTargetPreservedRuntimeClosure else { return false }
        return targetPreservedRepositories?.contains(where: {
            $0.revisionID == revisionID && $0.contentDigest == contentDigest
        }) == true
    }

    var hasAnySkilletConsumerReference: Bool {
        repositories?.isEmpty == false
            || targetPreservedRepositories?.isEmpty == false
    }

    private var hasValidTargetPreservedRuntimeClosure: Bool {
        let hasAnyClosureField =
            targetPreservedCount != nil
                || targetPreservedRepositories != nil
                || targetPreservedRuntimeClosureCapability != nil
                || targetPreservedRuntimeClosed != nil
        guard hasAnyClosureField else { return true }
        guard let targetPreservedCount,
              targetPreservedCount >= 0,
              let targetPreservedRepositories,
              targetPreservedCount == targetPreservedRepositories.count
        else {
            return false
        }
        let repositoryIDs = targetPreservedRepositories.map(\.repositoryID)
        guard Set(repositoryIDs).count == repositoryIDs.count,
              repositoryIDs == repositoryIDs.sorted(),
              targetPreservedRepositories.allSatisfy(\.isVerified)
        else {
            return false
        }
        guard targetPreservedCount > 0 else {
            return targetPreservedRuntimeClosed != false
        }
        return targetPreservedRuntimeClosureCapability
            == "target-preserved-runtime-closure-v1"
            && targetPreservedRuntimeClosed == true
    }
}

struct DeviceSyncSkilletRepositoryReceipt: Codable, Equatable, Sendable {
    let repositoryID: String
    let revisionID: String
    let contentDigest: String
    let bundleDigest: String
    let requestID: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let catalogRevision: String
    let phase: DeviceSyncReceiptPhase

    private enum CodingKeys: String, CodingKey {
        case repositoryID
        case revisionID
        case proposedRevisionID
        case canonicalRevisionID
        case mergedRevisionID
        case contentDigest
        case bundleDigest
        case requestID
        case sourceDeviceID
        case targetDeviceID
        case authorityEpoch
        case ledgerSequence
        case catalogRevision
        case phase
    }

    init(
        repositoryID: String,
        revisionID: String,
        contentDigest: String,
        bundleDigest: String,
        requestID: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        catalogRevision: String,
        phase: DeviceSyncReceiptPhase
    ) {
        self.repositoryID = repositoryID
        self.revisionID = revisionID
        self.contentDigest = contentDigest
        self.bundleDigest = bundleDigest
        self.requestID = requestID
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.catalogRevision = catalogRevision
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repositoryID = try container.decode(String.self, forKey: .repositoryID)
        revisionID =
            try container.decodeIfPresent(String.self, forKey: .revisionID)
                ?? container.decodeIfPresent(
                    String.self,
                    forKey: .proposedRevisionID
                )
                ?? container.decodeIfPresent(
                    String.self,
                    forKey: .mergedRevisionID
                )
                ?? container.decodeIfPresent(
                    String.self,
                    forKey: .canonicalRevisionID
                )
                ?? {
                    throw DecodingError.keyNotFound(
                        CodingKeys.revisionID,
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription:
                                "Skillet repository revision identity is missing."
                        )
                    )
                }()
        contentDigest = try container.decode(
            String.self,
            forKey: .contentDigest
        )
        bundleDigest = try container.decode(String.self, forKey: .bundleDigest)
        requestID =
            try container.decodeIfPresent(String.self, forKey: .requestID) ?? ""
        sourceDeviceID =
            try container.decodeIfPresent(
                String.self,
                forKey: .sourceDeviceID
            ) ?? ""
        targetDeviceID =
            try container.decodeIfPresent(
                String.self,
                forKey: .targetDeviceID
            ) ?? ""
        authorityEpoch =
            try container.decodeIfPresent(Int.self, forKey: .authorityEpoch)
                ?? -1
        ledgerSequence =
            try container.decodeIfPresent(Int.self, forKey: .ledgerSequence)
                ?? -1
        catalogRevision =
            try container.decodeIfPresent(
                String.self,
                forKey: .catalogRevision
            ) ?? ""
        phase = try container.decode(DeviceSyncReceiptPhase.self, forKey: .phase)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repositoryID, forKey: .repositoryID)
        try container.encode(revisionID, forKey: .revisionID)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(bundleDigest, forKey: .bundleDigest)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(sourceDeviceID, forKey: .sourceDeviceID)
        try container.encode(targetDeviceID, forKey: .targetDeviceID)
        try container.encode(authorityEpoch, forKey: .authorityEpoch)
        try container.encode(ledgerSequence, forKey: .ledgerSequence)
        try container.encode(catalogRevision, forKey: .catalogRevision)
        try container.encode(phase, forKey: .phase)
    }

    func isVerified(in receipt: DeviceSyncReceipt) -> Bool {
        guard phase == .verified,
              DeviceSyncReceipt.isSafeIdentifier(repositoryID),
              DeviceSyncReceipt.isSafeIdentifier(revisionID),
              revisionID == "rev-\(contentDigest)",
              DeviceSyncDigestValidator.matches(
                  algorithm: "sha256",
                  source: contentDigest,
                  applied: contentDigest
              ),
              DeviceSyncDigestValidator.matches(
                  algorithm: "sha256",
                  source: bundleDigest,
                  applied: bundleDigest
              ),
              requestID == receipt.requestID,
              sourceDeviceID == receipt.sourceDeviceID,
              targetDeviceID == receipt.targetDeviceID,
              authorityEpoch == receipt.authorityEpoch,
              ledgerSequence == receipt.ledgerSequence,
              catalogRevision == receipt.catalogRevision
        else {
            return false
        }
        return true
    }
}

struct DeviceSyncTargetPreservedRepositoryReceipt:
    Codable,
    Equatable,
    Sendable
{
    let repositoryID: String
    let revisionID: String
    let contentDigest: String
    let state: String
    let phase: String

    var isVerified: Bool {
        DeviceSyncReceipt.isSafeIdentifier(repositoryID)
            && DeviceSyncReceipt.isSafeIdentifier(revisionID)
            && revisionID == "rev-\(contentDigest)"
            && DeviceSyncDigestValidator.isSHA256(contentDigest)
            && state == "runtime-preserved"
            && phase == "preserved"
    }
}

enum DeviceSyncAttestationLevel: String, Equatable, Sendable {
    case none
    case channelClaimed
    case targetLocallyAttested
    case unreadable
}

struct DeviceSyncConsumerReadbackEvidence: Equatable, Identifiable, Sendable {
    let consumerID: String
    let consumerKind: String
    let sourceItemID: String
    let expectedDigest: String
    let loadedDigest: String
    let loadedRevision: String
    let loadedPath: String
    let runtimeRef: String
    let observedAt: Date
    let status: String

    var id: String {
        "\(consumerID)::\(sourceItemID)::\(loadedRevision)::\(loadedPath)"
    }

    var isLoaded: Bool {
        status == "loaded"
            && DeviceSyncDigestValidator.matches(
                algorithm: "sha256",
                source: expectedDigest,
                applied: loadedDigest
            )
            && hasContentBoundRevision
            && !loadedPath.isEmpty
            && !runtimeRef.isEmpty
    }

    private var hasContentBoundRevision: Bool {
        if sourceItemID == "skills.skillet" {
            return loadedRevision == "rev-\(loadedDigest)"
        }
        return loadedRevision == "sha256-\(loadedDigest)"
    }
}

struct DeviceSyncAttestationEvidence: Equatable, Sendable {
    let level: DeviceSyncAttestationLevel
    let attestedAt: Date?
    let provenance: String
    let detail: String
    let consumerReadbackDigest: String?
    let consumerReadbacks: [DeviceSyncConsumerReadbackEvidence]

    init(
        level: DeviceSyncAttestationLevel,
        attestedAt: Date?,
        provenance: String,
        detail: String,
        consumerReadbackDigest: String? = nil,
        consumerReadbacks: [DeviceSyncConsumerReadbackEvidence] = []
    ) {
        self.level = level
        self.attestedAt = attestedAt
        self.provenance = provenance
        self.detail = detail
        self.consumerReadbackDigest = consumerReadbackDigest
        self.consumerReadbacks = consumerReadbacks
    }

    var hasCompleteConsumerReadback: Bool {
        guard DeviceSyncDigestValidator.isSHA256(consumerReadbackDigest),
              !consumerReadbacks.isEmpty,
              consumerReadbacks.allSatisfy(\.isLoaded)
        else {
            return false
        }
        let requiredConsumerIDs = Set(
            TatwoTargetConsumerReadbackProbe.requiredConsumerIDs
        )
        guard Set(consumerReadbacks.map(\.consumerID)) == requiredConsumerIDs else {
            return false
        }
        let requiredOSItems = Set([
            "os.constitution",
            "os.issue",
            "os.todo",
        ])
        for consumerID in ["work-os.bootstrap", "tatwo-app.shared-runtime"] {
            let loadedItems = Set(
                consumerReadbacks
                    .filter { $0.consumerID == consumerID }
                    .map(\.sourceItemID)
            )
            guard loadedItems == requiredOSItems else { return false }
        }
        let requiredSkilletConsumerIDs = Set([
            "skillet.runtime-loader",
            "codex.native-skills",
            "claude.native-skills",
        ])
        let skilletReadbacks = consumerReadbacks.filter {
            requiredSkilletConsumerIDs.contains($0.consumerID)
        }
        return !skilletReadbacks.isEmpty
            && Set(skilletReadbacks.map(\.consumerID)) == requiredSkilletConsumerIDs
            && skilletReadbacks.allSatisfy { $0.sourceItemID == "skills.skillet" }
    }

    static let none = DeviceSyncAttestationEvidence(
        level: .none,
        attestedAt: nil,
        provenance: "outbox",
        detail: "尚未收到可驗證的 target ACK。",
        consumerReadbackDigest: nil,
        consumerReadbacks: []
    )

    static func channelClaimed(_ detail: String) -> DeviceSyncAttestationEvidence {
        DeviceSyncAttestationEvidence(
            level: .channelClaimed,
            attestedAt: nil,
            provenance: "channel ACK",
            detail: detail,
            consumerReadbackDigest: nil,
            consumerReadbacks: []
        )
    }

    static func unreadable(_ detail: String) -> DeviceSyncAttestationEvidence {
        DeviceSyncAttestationEvidence(
            level: .unreadable,
            attestedAt: nil,
            provenance: "artifact fail-closed",
            detail: detail,
            consumerReadbackDigest: nil,
            consumerReadbacks: []
        )
    }
}

struct DeviceSyncReceipt: Codable, Equatable, Sendable {
    let target: String
    let action: String
    let requestedAt: Date
    let result: String
    let completedAt: Date
    let message: String
    let phase: DeviceSyncReceiptPhase?
    let requestID: String?
    let sourceRefreshAttemptID: String?
    let authorityEpoch: Int?
    let ledgerSequence: Int?
    let authorityPrimary: String?
    let sourceDeviceID: String?
    let targetDeviceID: String?
    let catalogRevision: String?
    let sourceMode: String?
    let inventoryDigest: String?
    let fallbackAuthorizationID: String?
    let fallbackAuthorizationPath: String?
    let fallbackAuthorizationDigest: String?
    let digestAlgorithm: String?
    let sourceDigest: String?
    let appliedDigest: String?
    let signaturePurpose: String?
    let signaturePath: String?
    let attestationKind: String?
    let targetAttestationPath: String?
    let targetAttestationDigest: String?
    let targetAttestationSignaturePath: String?
    let consumerReadbackKind: String?
    let consumerReadbackPath: String?
    let consumerReadbackDigest: String?
    let consumerReadbackCount: Int?
    let requiredItemIDs: [String]?
    let items: [DeviceSyncItemReceipt]?
    let attestationEvidence: DeviceSyncAttestationEvidence
    let progress: DeviceSyncProgressPayload?

    var operationKey: DeviceSyncOperationKey {
        DeviceSyncOperationKey(target: target, action: action)
    }

    var canonicalAction: String? {
        DeviceSyncAction.canonicalArtifactValue(action)
    }

    init(
        target: String,
        action: String,
        requestedAt: Date,
        result: String,
        completedAt: Date,
        message: String,
        phase: DeviceSyncReceiptPhase? = nil,
        requestID: String? = nil,
        sourceRefreshAttemptID: String? = nil,
        authorityEpoch: Int? = nil,
        ledgerSequence: Int? = nil,
        authorityPrimary: String? = nil,
        sourceDeviceID: String? = nil,
        targetDeviceID: String? = nil,
        catalogRevision: String? = nil,
        sourceMode: String? = nil,
        inventoryDigest: String? = nil,
        fallbackAuthorizationID: String? = nil,
        fallbackAuthorizationPath: String? = nil,
        fallbackAuthorizationDigest: String? = nil,
        digestAlgorithm: String? = nil,
        sourceDigest: String? = nil,
        appliedDigest: String? = nil,
        signaturePurpose: String? = nil,
        signaturePath: String? = nil,
        attestationKind: String? = nil,
        targetAttestationPath: String? = nil,
        targetAttestationDigest: String? = nil,
        targetAttestationSignaturePath: String? = nil,
        consumerReadbackKind: String? = nil,
        consumerReadbackPath: String? = nil,
        consumerReadbackDigest: String? = nil,
        consumerReadbackCount: Int? = nil,
        requiredItemIDs: [String]? = nil,
        items: [DeviceSyncItemReceipt] = [],
        attestationEvidence: DeviceSyncAttestationEvidence = .none,
        progress: DeviceSyncProgressPayload? = nil
    ) {
        self.target = target
        self.action = action
        self.requestedAt = requestedAt
        self.result = result
        self.completedAt = completedAt
        self.message = message
        self.phase = phase
        self.requestID = requestID
        self.sourceRefreshAttemptID = sourceRefreshAttemptID
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.authorityPrimary = authorityPrimary
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.catalogRevision = catalogRevision
        self.sourceMode = sourceMode
        self.inventoryDigest = inventoryDigest
        self.fallbackAuthorizationID = fallbackAuthorizationID
        self.fallbackAuthorizationPath = fallbackAuthorizationPath
        self.fallbackAuthorizationDigest = fallbackAuthorizationDigest
        self.digestAlgorithm = digestAlgorithm
        self.sourceDigest = sourceDigest
        self.appliedDigest = appliedDigest
        self.signaturePurpose = signaturePurpose
        self.signaturePath = signaturePath
        self.attestationKind = attestationKind
        self.targetAttestationPath = targetAttestationPath
        self.targetAttestationDigest = targetAttestationDigest
        self.targetAttestationSignaturePath = targetAttestationSignaturePath
        self.consumerReadbackKind = consumerReadbackKind
        self.consumerReadbackPath = consumerReadbackPath
        self.consumerReadbackDigest = consumerReadbackDigest
        self.consumerReadbackCount = consumerReadbackCount
        self.requiredItemIDs = requiredItemIDs
        self.items = items
        self.attestationEvidence = attestationEvidence
        self.progress = progress
    }

    var effectivePhase: DeviceSyncReceiptPhase {
        if let phase { return phase }
        switch result {
        case "converged": return .converged
        case "failure", "failed": return .failed
        case "diverged": return .diverged
        case "success":
            // Legacy "success" only proved that a request was published.
            return .delivered
        default:
            return .queued
        }
    }

    var progressFraction: Double {
        progressValue.fraction
    }

    var progressValue: DeviceSyncProgressValue {
        let mustCapUnconvergedProgress = !isConverged
        let fallbackPhase = effectivePhase == .converged
            && mustCapUnconvergedProgress
                ? DeviceSyncReceiptPhase.verified
                : effectivePhase
        let value = DeviceSyncProgressValue.make(
            payload: progress,
            fallbackPhase: fallbackPhase
        )
        guard mustCapUnconvergedProgress else {
            return value
        }
        return DeviceSyncProgressValue(
            fraction: min(
                value.fraction,
                DeviceSyncReceiptPhase.verified.progressFraction
            ),
            provenance: value.provenance
        )
    }

    var isChannelClaimed: Bool {
        guard canonicalAction != nil else { return false }
        guard effectivePhase == .converged else { return false }
        guard let requestID, Self.isSafeIdentifier(requestID),
              let authorityEpoch, authorityEpoch >= 0,
              let ledgerSequence, ledgerSequence > 0,
              Self.isNonEmpty(authorityPrimary),
              Self.isNonEmpty(sourceDeviceID),
              Self.isNonEmpty(targetDeviceID),
              Self.isNonEmpty(catalogRevision),
              !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        guard isCatalogCompatible else { return false }

        let itemReceipts = items ?? []
        let requiredIDs = effectiveRequiredItemIDs
        guard !requiredIDs.isEmpty,
              hasCanonicalRequiredItemIDs(requiredIDs),
              DeviceSyncDigestValidator.matches(
                  algorithm: digestAlgorithm,
                  source: sourceDigest,
                  applied: appliedDigest
              )
        else {
            return false
        }
        let itemsByID = Dictionary(
            itemReceipts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard itemsByID.count == itemReceipts.count,
              Set(itemsByID.keys) == Set(requiredIDs),
              itemReceipts.count == requiredIDs.count
        else {
            return false
        }
        return requiredIDs.allSatisfy {
            guard let item = itemsByID[$0] else { return false }
            return item.isVerified(in: self)
        }
    }

    var isConverged: Bool {
        guard isChannelClaimed else { return false }
        if canonicalAction == "system-pull" {
            return attestationEvidence.level == .targetLocallyAttested
                && attestationEvidence.hasCompleteConsumerReadback
        }
        return true
    }

    func withAttestationEvidence(
        _ evidence: DeviceSyncAttestationEvidence
    ) -> DeviceSyncReceipt {
        DeviceSyncReceipt(
            target: target,
            action: action,
            requestedAt: requestedAt,
            result: result,
            completedAt: completedAt,
            message: message,
            phase: phase,
            requestID: requestID,
            sourceRefreshAttemptID: sourceRefreshAttemptID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: authorityPrimary,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            catalogRevision: catalogRevision,
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: fallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            digestAlgorithm: digestAlgorithm,
            sourceDigest: sourceDigest,
            appliedDigest: appliedDigest,
            signaturePurpose: signaturePurpose,
            signaturePath: signaturePath,
            attestationKind: attestationKind,
            targetAttestationPath: targetAttestationPath,
            targetAttestationDigest: targetAttestationDigest,
            targetAttestationSignaturePath: targetAttestationSignaturePath,
            consumerReadbackKind: consumerReadbackKind,
            consumerReadbackPath: consumerReadbackPath,
            consumerReadbackDigest: consumerReadbackDigest,
            consumerReadbackCount: consumerReadbackCount,
            requiredItemIDs: requiredItemIDs,
            items: items ?? [],
            attestationEvidence: evidence,
            progress: progress
        )
    }

    var effectiveRequiredItemIDs: [String] {
        switch canonicalAction {
        case "system-pull"?:
            return DeviceSyncCatalogProjection.systemPullItemIDs
        case "version-pull"?:
            return ["app.version"]
        case "db-pull"?:
            return ["work.goal-state"]
        case "both"?:
            return ["app.version", "work.goal-state"]
        default:
            return []
        }
    }

    var isCatalogCompatible: Bool {
        guard let canonicalAction else { return false }
        guard canonicalAction == "system-pull" else { return true }
        guard let expectedRevision = DeviceSyncCatalogProjection.currentRevision else {
            return false
        }
        return catalogRevision == expectedRevision
    }

    func isItemVerified(_ item: DeviceSyncItemReceipt) -> Bool {
        item.isVerified(in: self)
    }

    var statusLabel: String {
        switch effectivePhase {
        case .queued: return "等待送出"
        case .delivered: return "已送達，等待設備接收"
        case .accepted: return "設備已接收"
        case .transferring: return "傳輸中"
        case .merging: return "合併中"
        case .validating: return "驗證中"
        case .activating: return "啟用中"
        case .verified: return "設備已驗證"
        case .converged:
            if !isCatalogCompatible {
                return "同步 catalog 不相容"
            }
            if isConverged {
                return canonicalAction == "system-pull"
                    ? "target-locally-attested · 已收斂"
                    : "已收斂"
            }
            if isChannelClaimed {
                switch attestationEvidence.level {
                case .unreadable:
                    return "channel-claimed · attestation 無法讀取"
                case .targetLocallyAttested:
                    return "target-attested · actual consumer readback 不完整"
                default:
                    return "channel-claimed · 等待 actual consumer readback / target attestation"
                }
            }
            return "缺少項目驗證"
        case .failed: return "同步失敗"
        case .diverged: return "內容分岔"
        }
    }

    private func hasCanonicalRequiredItemIDs(_ canonicalIDs: [String]) -> Bool {
        guard let requiredItemIDs,
              requiredItemIDs.count == canonicalIDs.count,
              Set(requiredItemIDs).count == requiredItemIDs.count,
              requiredItemIDs == canonicalIDs
        else {
            return false
        }
        return true
    }

    static func isNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix(".")
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 58, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case action
        case requestedAt
        case result
        case completedAt
        case message
        case phase
        case requestID
        case sourceRefreshAttemptID
        case authorityEpoch
        case ledgerSequence
        case authorityPrimary
        case sourceDeviceID
        case targetDeviceID
        case catalogRevision
        case sourceMode
        case inventoryDigest
        case fallbackAuthorizationID
        case fallbackAuthorizationPath
        case fallbackAuthorizationDigest
        case digestAlgorithm
        case sourceDigest
        case appliedDigest
        case signaturePurpose
        case signaturePath
        case attestationKind
        case targetAttestationPath
        case targetAttestationDigest
        case targetAttestationSignaturePath
        case consumerReadbackKind
        case consumerReadbackPath
        case consumerReadbackDigest
        case consumerReadbackCount
        case requiredItemIDs
        case items
        case progress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(String.self, forKey: .target)
        let decodedAction = try container.decode(String.self, forKey: .action)
        guard let canonicalAction = DeviceSyncAction.canonicalArtifactValue(decodedAction) else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "sync action must be a canonical supported action"
            )
        }
        action = canonicalAction
        requestedAt = try container.decode(Date.self, forKey: .requestedAt)
        result = try container.decode(String.self, forKey: .result)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        message = try container.decode(String.self, forKey: .message)
        phase = try container.decodeIfPresent(DeviceSyncReceiptPhase.self, forKey: .phase)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        sourceRefreshAttemptID = try container.decodeIfPresent(
            String.self,
            forKey: .sourceRefreshAttemptID
        )
        authorityEpoch = try container.decodeIfPresent(Int.self, forKey: .authorityEpoch)
        ledgerSequence = try container.decodeIfPresent(Int.self, forKey: .ledgerSequence)
        authorityPrimary = try container.decodeIfPresent(String.self, forKey: .authorityPrimary)
        sourceDeviceID = try container.decodeIfPresent(String.self, forKey: .sourceDeviceID)
        targetDeviceID = try container.decodeIfPresent(String.self, forKey: .targetDeviceID)
        catalogRevision = try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        sourceMode = try container.decodeIfPresent(String.self, forKey: .sourceMode)
        inventoryDigest = try container.decodeIfPresent(String.self, forKey: .inventoryDigest)
        fallbackAuthorizationID = try container.decodeIfPresent(
            String.self,
            forKey: .fallbackAuthorizationID
        )
        fallbackAuthorizationPath = try container.decodeIfPresent(
            String.self,
            forKey: .fallbackAuthorizationPath
        )
        fallbackAuthorizationDigest = try container.decodeIfPresent(
            String.self,
            forKey: .fallbackAuthorizationDigest
        )
        digestAlgorithm = try container.decodeIfPresent(String.self, forKey: .digestAlgorithm)
        sourceDigest = try container.decodeIfPresent(String.self, forKey: .sourceDigest)
        appliedDigest = try container.decodeIfPresent(String.self, forKey: .appliedDigest)
        signaturePurpose = try container.decodeIfPresent(
            String.self,
            forKey: .signaturePurpose
        )
        signaturePath = try container.decodeIfPresent(String.self, forKey: .signaturePath)
        attestationKind = try container.decodeIfPresent(String.self, forKey: .attestationKind)
        targetAttestationPath = try container.decodeIfPresent(
            String.self,
            forKey: .targetAttestationPath
        )
        targetAttestationDigest = try container.decodeIfPresent(
            String.self,
            forKey: .targetAttestationDigest
        )
        targetAttestationSignaturePath = try container.decodeIfPresent(
            String.self,
            forKey: .targetAttestationSignaturePath
        )
        consumerReadbackKind = try container.decodeIfPresent(
            String.self,
            forKey: .consumerReadbackKind
        )
        consumerReadbackPath = try container.decodeIfPresent(
            String.self,
            forKey: .consumerReadbackPath
        )
        consumerReadbackDigest = try container.decodeIfPresent(
            String.self,
            forKey: .consumerReadbackDigest
        )
        consumerReadbackCount = try container.decodeIfPresent(
            Int.self,
            forKey: .consumerReadbackCount
        )
        requiredItemIDs = try container.decodeIfPresent([String].self, forKey: .requiredItemIDs)
        items = try container.decodeIfPresent([DeviceSyncItemReceipt].self, forKey: .items)
        progress = try container.decodeIfPresent(DeviceSyncProgressPayload.self, forKey: .progress)
        attestationEvidence = .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(action, forKey: .action)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encode(result, forKey: .result)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(phase, forKey: .phase)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(
            sourceRefreshAttemptID,
            forKey: .sourceRefreshAttemptID
        )
        try container.encodeIfPresent(authorityEpoch, forKey: .authorityEpoch)
        try container.encodeIfPresent(ledgerSequence, forKey: .ledgerSequence)
        try container.encodeIfPresent(authorityPrimary, forKey: .authorityPrimary)
        try container.encodeIfPresent(sourceDeviceID, forKey: .sourceDeviceID)
        try container.encodeIfPresent(targetDeviceID, forKey: .targetDeviceID)
        try container.encodeIfPresent(catalogRevision, forKey: .catalogRevision)
        try container.encodeIfPresent(sourceMode, forKey: .sourceMode)
        try container.encodeIfPresent(inventoryDigest, forKey: .inventoryDigest)
        try container.encodeIfPresent(
            fallbackAuthorizationID,
            forKey: .fallbackAuthorizationID
        )
        try container.encodeIfPresent(
            fallbackAuthorizationPath,
            forKey: .fallbackAuthorizationPath
        )
        try container.encodeIfPresent(
            fallbackAuthorizationDigest,
            forKey: .fallbackAuthorizationDigest
        )
        try container.encodeIfPresent(digestAlgorithm, forKey: .digestAlgorithm)
        try container.encodeIfPresent(sourceDigest, forKey: .sourceDigest)
        try container.encodeIfPresent(appliedDigest, forKey: .appliedDigest)
        try container.encodeIfPresent(signaturePurpose, forKey: .signaturePurpose)
        try container.encodeIfPresent(signaturePath, forKey: .signaturePath)
        try container.encodeIfPresent(attestationKind, forKey: .attestationKind)
        try container.encodeIfPresent(targetAttestationPath, forKey: .targetAttestationPath)
        try container.encodeIfPresent(targetAttestationDigest, forKey: .targetAttestationDigest)
        try container.encodeIfPresent(
            targetAttestationSignaturePath,
            forKey: .targetAttestationSignaturePath
        )
        try container.encodeIfPresent(consumerReadbackKind, forKey: .consumerReadbackKind)
        try container.encodeIfPresent(consumerReadbackPath, forKey: .consumerReadbackPath)
        try container.encodeIfPresent(consumerReadbackDigest, forKey: .consumerReadbackDigest)
        try container.encodeIfPresent(consumerReadbackCount, forKey: .consumerReadbackCount)
        try container.encodeIfPresent(requiredItemIDs, forKey: .requiredItemIDs)
        try container.encodeIfPresent(items, forKey: .items)
        try container.encodeIfPresent(progress, forKey: .progress)
    }
}

enum DeviceSyncSourceProvenanceValidator {
    static let canonical = "canonical"
    static let runtimeFallback = "runtime-fallback"

    static func isValid(
        sourceMode: String?,
        inventoryDigest: String?,
        fallbackAuthorizationID: String?,
        fallbackAuthorizationPath: String?,
        fallbackAuthorizationDigest: String?,
        authorityPrimary: String,
        authorityEpoch: Int
    ) -> Bool {
        guard DeviceSyncDigestValidator.isSHA256(inventoryDigest) else {
            return false
        }
        switch sourceMode {
        case canonical:
            return isEmpty(fallbackAuthorizationID)
                && isEmpty(fallbackAuthorizationPath)
                && isEmpty(fallbackAuthorizationDigest)
        case runtimeFallback:
            guard let fallbackAuthorizationID,
                  DeviceSyncReceipt.isSafeIdentifier(fallbackAuthorizationID),
                  let fallbackAuthorizationPath,
                  fallbackAuthorizationPath
                    == "fallback-authorizations/\(authorityPrimary)/epoch-\(authorityEpoch).json",
                  DeviceSyncDigestValidator.isSHA256(fallbackAuthorizationDigest)
            else {
                return false
            }
            return true
        default:
            return false
        }
    }

    private static func isEmpty(_ value: String?) -> Bool {
        value == nil || value == ""
    }
}

struct DeviceSyncRequestArtifact: Codable, Equatable, Sendable {
    let id: String?
    let requestID: String
    let action: String
    let target: String
    let targetDeviceName: String?
    let targetDeviceID: String
    let requestedAt: Date
    let authorityPrimary: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let sourceDeviceID: String
    let catalogRevision: String
    let sourceMode: String
    let inventoryDigest: String
    let fallbackAuthorizationID: String
    let fallbackAuthorizationPath: String
    let fallbackAuthorizationDigest: String
    let digestAlgorithm: String
    let sourceDigest: String
    let manifestPath: String
    let manifestDigest: String
    let signaturePurpose: String?
    let signaturePath: String?

    init(
        id: String?,
        requestID: String,
        action: String,
        target: String,
        targetDeviceName: String?,
        targetDeviceID: String,
        requestedAt: Date,
        authorityPrimary: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        sourceDeviceID: String,
        catalogRevision: String,
        sourceMode: String,
        inventoryDigest: String,
        fallbackAuthorizationID: String,
        fallbackAuthorizationPath: String,
        fallbackAuthorizationDigest: String,
        digestAlgorithm: String,
        sourceDigest: String,
        manifestPath: String,
        manifestDigest: String,
        signaturePurpose: String? = nil,
        signaturePath: String? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.action = action
        self.target = target
        self.targetDeviceName = targetDeviceName
        self.targetDeviceID = targetDeviceID
        self.requestedAt = requestedAt
        self.authorityPrimary = authorityPrimary
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.sourceDeviceID = sourceDeviceID
        self.catalogRevision = catalogRevision
        self.sourceMode = sourceMode
        self.inventoryDigest = inventoryDigest
        self.fallbackAuthorizationID = fallbackAuthorizationID
        self.fallbackAuthorizationPath = fallbackAuthorizationPath
        self.fallbackAuthorizationDigest = fallbackAuthorizationDigest
        self.digestAlgorithm = digestAlgorithm
        self.sourceDigest = sourceDigest
        self.manifestPath = manifestPath
        self.manifestDigest = manifestDigest
        self.signaturePurpose = signaturePurpose
        self.signaturePath = signaturePath
    }
}

struct DeviceSyncManifestItemArtifact: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let payloadRelativePath: String
    let mirrorRelativePath: String
    let sourceDigest: String
    let byteCount: Int
    let repositoryCount: Int?
}

struct DeviceSyncManifestArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let catalogRevision: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let authorityPrimary: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let sourceMode: String
    let inventoryDigest: String
    let fallbackAuthorizationID: String
    let fallbackAuthorizationPath: String
    let fallbackAuthorizationDigest: String
    let items: [DeviceSyncManifestItemArtifact]
}

struct DeviceSyncTargetAttestationArtifact: Codable, Equatable, Sendable {
    let schema: String
    let kind: String
    let requestID: String
    let target: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let authorityPrimary: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let catalogRevision: String
    let transactionPhase: String
    let transactionJournalDigest: String
    let manifestDigest: String
    let skilletActiveSetReceiptDigest: String
    let consumerReadbackKind: String
    let consumerReadbackPath: String
    let consumerReadbackDigest: String
    let consumerReadbackCount: Int
    let attestedAt: Date
    let signaturePurpose: String?
    let signaturePath: String?

    init(
        schema: String,
        kind: String,
        requestID: String,
        target: String,
        authorityEpoch: Int,
        ledgerSequence: Int,
        authorityPrimary: String,
        sourceDeviceID: String,
        targetDeviceID: String,
        catalogRevision: String,
        transactionPhase: String,
        transactionJournalDigest: String,
        manifestDigest: String,
        skilletActiveSetReceiptDigest: String,
        consumerReadbackKind: String,
        consumerReadbackPath: String,
        consumerReadbackDigest: String,
        consumerReadbackCount: Int,
        attestedAt: Date,
        signaturePurpose: String? = nil,
        signaturePath: String? = nil
    ) {
        self.schema = schema
        self.kind = kind
        self.requestID = requestID
        self.target = target
        self.authorityEpoch = authorityEpoch
        self.ledgerSequence = ledgerSequence
        self.authorityPrimary = authorityPrimary
        self.sourceDeviceID = sourceDeviceID
        self.targetDeviceID = targetDeviceID
        self.catalogRevision = catalogRevision
        self.transactionPhase = transactionPhase
        self.transactionJournalDigest = transactionJournalDigest
        self.manifestDigest = manifestDigest
        self.skilletActiveSetReceiptDigest = skilletActiveSetReceiptDigest
        self.consumerReadbackKind = consumerReadbackKind
        self.consumerReadbackPath = consumerReadbackPath
        self.consumerReadbackDigest = consumerReadbackDigest
        self.consumerReadbackCount = consumerReadbackCount
        self.attestedAt = attestedAt
        self.signaturePurpose = signaturePurpose
        self.signaturePath = signaturePath
    }
}

struct DeviceSyncTargetConsumerReadbackArtifact: Codable, Equatable, Sendable {
    let schema: String
    let requestID: String
    let targetDeviceID: String
    let authorityPrimary: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let catalogRevision: String
    let consumerID: String
    let consumerKind: String
    let sourceItemID: String
    let expectedDigest: String
    let loadedDigest: String
    let loadedRevision: String
    let loadedPath: String
    let runtimeRef: String
    let observedAt: Date
    let status: String
}

struct DeviceSyncTargetConsumerReadbackSetArtifact: Codable, Equatable, Sendable {
    let schema: String
    let requestID: String
    let target: String
    let targetDeviceID: String
    let sourceDeviceID: String
    let authorityPrimary: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let catalogRevision: String
    let manifestDigest: String
    let requiredConsumerIDs: [String]
    let readbackCount: Int
    let readbacks: [DeviceSyncTargetConsumerReadbackArtifact]
    let observedAt: Date
    let status: String
}

enum DeviceSyncArtifactDigester {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(at url: URL) throws -> String {
        sha256(try Data(contentsOf: url))
    }
}

struct DeviceSyncChannelSignatureVerifier: Sendable {
    let channelRootURL: URL

    func verify(
        payload: Data,
        producerName: String,
        producerDeviceID: String,
        purpose: String,
        signaturePath: String?,
        expectedSignaturePath: String
    ) throws {
        guard DeviceSyncReceipt.isSafeIdentifier(producerName),
              DeviceSyncReceipt.isNonEmpty(producerDeviceID),
              signaturePath == expectedSignaturePath
        else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "\(purpose) signature binding"
            )
        }

        let registryData = try secureRegularFile(
            rootURL: channelRootURL,
            components: ["devices", "\(producerName).json"]
        )
        guard let registryObject = try JSONSerialization.jsonObject(
            with: registryData
        ) as? [String: Any],
              registryObject["name"] as? String == producerName,
              registryObject["deviceId"] as? String == producerDeviceID
        else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "\(producerName) device registry binding"
            )
        }
        let registryIdentity = try DeviceSyncOutboxJSON.decoder.decode(
            TatwoDevicePublicIdentityV1.self,
            from: registryData
        )
        guard registryIdentity.deviceID == producerDeviceID else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "\(producerName) pinned device identity"
            )
        }

        let trustedIdentity = try trustedIdentity(
            producerName: producerName,
            producerDeviceID: producerDeviceID
        )
        guard trustedIdentity == registryIdentity else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "\(producerName) registry/pin mismatch"
            )
        }

        let signatureData = try secureRegularFile(
            rootURL: channelRootURL,
            components: expectedSignaturePath.split(separator: "/").map(String.init)
        )
        let signature = try DeviceSyncOutboxJSON.decoder.decode(
            TatwoDeviceSignatureV1.self,
            from: signatureData
        )
        try TatwoDeviceTrustAuthority.verify(
            payload: payload,
            purpose: purpose,
            signature: signature,
            pinnedIdentity: trustedIdentity
        )
    }

    private func trustedIdentity(
        producerName: String,
        producerDeviceID: String
    ) throws -> TatwoDevicePublicIdentityV1 {
        let appSupportRootURL = channelRootURL.deletingLastPathComponent()
        let localIdentityURL = appSupportRootURL
            .appendingPathComponent("device-trust", isDirectory: true)
            .appendingPathComponent("identity.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: localIdentityURL.path) {
            let localData = try secureRegularFile(
                rootURL: appSupportRootURL,
                components: ["device-trust", "identity.json"]
            )
            let localIdentity = try DeviceSyncOutboxJSON.decoder.decode(
                TatwoDevicePublicIdentityV1.self,
                from: localData
            )
            if localIdentity.deviceID == producerDeviceID {
                return localIdentity
            }
        }

        let peerData = try secureRegularFile(
            rootURL: appSupportRootURL,
            components: ["device-trust", "peers", "\(producerName).json"]
        )
        let peerIdentity = try DeviceSyncOutboxJSON.decoder.decode(
            TatwoDevicePublicIdentityV1.self,
            from: peerData
        )
        guard peerIdentity.deviceID == producerDeviceID else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "\(producerName) peer pin"
            )
        }
        return peerIdentity
    }

    private func secureRegularFile(
        rootURL: URL,
        components: [String]
    ) throws -> Data {
        guard !components.isEmpty else {
            throw DeviceSyncArtifactError.unsafePath(rootURL.path)
        }
        let standardizedRoot = rootURL.standardizedFileURL
        let rootValues = try standardizedRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else {
            throw DeviceSyncArtifactError.notRegularFile(
                standardizedRoot.lastPathComponent
            )
        }

        var candidate = standardizedRoot
        for (index, component) in components.enumerated() {
            guard !component.isEmpty,
                  component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.contains("\\")
            else {
                throw DeviceSyncArtifactError.unsafePath(component)
            }
            candidate.appendPathComponent(
                component,
                isDirectory: index < components.count - 1
            )
            let values = try candidate.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isSymbolicLink != true else {
                throw DeviceSyncArtifactError.notRegularFile(
                    candidate.lastPathComponent
                )
            }
            if index < components.count - 1 {
                guard values.isDirectory == true else {
                    throw DeviceSyncArtifactError.notRegularFile(
                        candidate.lastPathComponent
                    )
                }
            } else {
                guard values.isRegularFile == true else {
                    throw DeviceSyncArtifactError.notRegularFile(
                        candidate.lastPathComponent
                    )
                }
            }
        }

        let standardizedCandidate = candidate.standardizedFileURL
        guard standardizedCandidate.path.hasPrefix(
            standardizedRoot.path + "/"
        ) else {
            throw DeviceSyncArtifactError.unsafePath(
                standardizedCandidate.path
            )
        }
        return try Data(contentsOf: standardizedCandidate)
    }
}

struct DeviceSyncTargetAttestationVerifier: Sendable {
    static let attestationSchema = "TatwoTargetLocalSystemAttestationV2"
    static let attestationKind = "target-local-consumer-readback-attested"
    static let consumerReadbackSchema = "TatwoTargetConsumerReadbackSetV1"
    static let consumerReadbackKind = "actual-consumer-readback-set"
    static let requiredConsumerIDs =
        TatwoTargetConsumerReadbackProbe.requiredConsumerIDs

    let channelRootURL: URL

    func verify(
        receipt: DeviceSyncReceipt,
        ackReceiptData: Data? = nil
    ) -> DeviceSyncAttestationEvidence {
        guard receipt.isChannelClaimed else {
            return .none
        }
        guard let requestID = receipt.requestID,
              let targetDeviceID = receipt.targetDeviceID,
              DeviceSyncReceipt.isSafeIdentifier(requestID),
              DeviceSyncReceipt.isSafeIdentifier(receipt.target),
              DeviceSyncReceipt.isNonEmpty(targetDeviceID)
        else {
            return .channelClaimed("ACK 缺少安全的 request/target/authority binding。")
        }

        let signatureVerifier = DeviceSyncChannelSignatureVerifier(
            channelRootURL: channelRootURL
        )
        if let ackReceiptData {
            let expectedACKSignaturePath = "signatures/acks/\(requestID).json"
            guard receipt.signaturePurpose == "sync-ack" else {
                return .unreadable("ACK 缺少固定 sync-ack signature purpose。")
            }
            do {
                try signatureVerifier.verify(
                    payload: ackReceiptData,
                    producerName: receipt.target,
                    producerDeviceID: targetDeviceID,
                    purpose: "sync-ack",
                    signaturePath: receipt.signaturePath,
                    expectedSignaturePath: expectedACKSignaturePath
                )
            } catch {
                return .unreadable(
                    "ACK signature 無法驗證：\(error.localizedDescription)"
                )
            }
        }

        guard receipt.canonicalAction == "system-pull" else {
            return .none
        }
        guard let authorityEpoch = receipt.authorityEpoch,
              let ledgerSequence = receipt.ledgerSequence,
              let authorityPrimary = receipt.authorityPrimary,
              let sourceDeviceID = receipt.sourceDeviceID,
              let catalogRevision = receipt.catalogRevision
        else {
            return .channelClaimed("ACK 缺少完整的 system-pull authority binding。")
        }
        guard DeviceSyncSourceProvenanceValidator.isValid(
            sourceMode: receipt.sourceMode,
            inventoryDigest: receipt.inventoryDigest,
            fallbackAuthorizationID: receipt.fallbackAuthorizationID,
            fallbackAuthorizationPath: receipt.fallbackAuthorizationPath,
            fallbackAuthorizationDigest: receipt.fallbackAuthorizationDigest,
            authorityPrimary: authorityPrimary,
            authorityEpoch: authorityEpoch
        ) else {
            return .unreadable("ACK 的 Skillet canonical/fallback source provenance 不合法。")
        }

        let attestationFields = [
            receipt.attestationKind,
            receipt.targetAttestationPath,
            receipt.targetAttestationDigest,
        ]
        if attestationFields.allSatisfy({ !DeviceSyncReceipt.isNonEmpty($0) }) {
            return .channelClaimed("ACK 未綁定預期的 target-local attestation 相對路徑。")
        }
        let expectedAttestationPath = "attestations/\(receipt.target)/\(requestID).json"
        guard receipt.attestationKind == Self.attestationKind,
              receipt.targetAttestationPath == expectedAttestationPath,
              DeviceSyncDigestValidator.isSHA256(receipt.targetAttestationDigest)
        else {
            return .unreadable("ACK 的 target-local attestation kind/path/digest binding 不合法。")
        }
        let consumerReadbackFields = [
            receipt.consumerReadbackKind,
            receipt.consumerReadbackPath,
            receipt.consumerReadbackDigest,
        ]
        if consumerReadbackFields.allSatisfy({ !DeviceSyncReceipt.isNonEmpty($0) }),
           receipt.consumerReadbackCount == nil || receipt.consumerReadbackCount == 0
        {
            return .channelClaimed("ACK 尚未綁定 actual consumer readback set。")
        }
        let expectedConsumerReadbackPath =
            "consumer-readbacks/\(receipt.target)/\(requestID).json"
        guard receipt.consumerReadbackKind == Self.consumerReadbackKind,
              receipt.consumerReadbackPath == expectedConsumerReadbackPath,
              DeviceSyncDigestValidator.isSHA256(receipt.consumerReadbackDigest),
              let consumerReadbackCount = receipt.consumerReadbackCount,
              consumerReadbackCount >= Self.requiredConsumerIDs.count
        else {
            return .unreadable("ACK 的 actual consumer readback kind/path/digest/count binding 不合法。")
        }

        do {
            let requestURL = try exactArtifactURL(
                components: ["requests", receipt.target, "\(requestID).json"]
            )
            let requestData = try readRegularFile(requestURL)
            let request = try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncRequestArtifact.self,
                from: requestData
            )
            guard request.requestID == requestID,
                  request.id == nil || request.id == requestID,
                  request.target == receipt.target,
                  request.targetDeviceName == nil || request.targetDeviceName == receipt.target,
                  request.action == receipt.action,
                  request.authorityEpoch == authorityEpoch,
                  request.ledgerSequence == ledgerSequence,
                  request.authorityPrimary == authorityPrimary,
                  request.sourceDeviceID == sourceDeviceID,
                  request.targetDeviceID == targetDeviceID,
                  request.catalogRevision == catalogRevision,
                  request.sourceMode == (receipt.sourceMode ?? ""),
                  request.inventoryDigest == (receipt.inventoryDigest ?? ""),
                  request.fallbackAuthorizationID
                    == (receipt.fallbackAuthorizationID ?? ""),
                  request.fallbackAuthorizationPath
                    == (receipt.fallbackAuthorizationPath ?? ""),
                  request.fallbackAuthorizationDigest
                    == (receipt.fallbackAuthorizationDigest ?? ""),
                  DeviceSyncSourceProvenanceValidator.isValid(
                      sourceMode: request.sourceMode,
                      inventoryDigest: request.inventoryDigest,
                      fallbackAuthorizationID: request.fallbackAuthorizationID,
                      fallbackAuthorizationPath: request.fallbackAuthorizationPath,
                      fallbackAuthorizationDigest: request.fallbackAuthorizationDigest,
                      authorityPrimary: authorityPrimary,
                      authorityEpoch: authorityEpoch
                  ),
                  request.digestAlgorithm == "sha256",
                  request.sourceDigest == receipt.sourceDigest,
                  request.manifestDigest == request.sourceDigest,
                  DeviceSyncDigestValidator.isSHA256(request.manifestDigest)
            else {
                return .unreadable("原始 request 與 ACK binding 不一致。")
            }

            let expectedRequestSignaturePath =
                "signatures/requests/\(receipt.target)/\(requestID).json"
            guard request.signaturePurpose == "sync-request" else {
                return .unreadable("原始 request 缺少固定 sync-request signature purpose。")
            }
            try signatureVerifier.verify(
                payload: requestData,
                producerName: authorityPrimary,
                producerDeviceID: sourceDeviceID,
                purpose: "sync-request",
                signaturePath: request.signaturePath,
                expectedSignaturePath: expectedRequestSignaturePath
            )

            let expectedManifestPath = "payloads/\(requestID)/manifest.json"
            guard request.manifestPath == expectedManifestPath else {
                return .unreadable("request manifestPath 不是受限制的 request 相對路徑。")
            }
            let manifestURL = try exactArtifactURL(
                components: ["payloads", requestID, "manifest.json"]
            )
            let manifestData = try readRegularFile(manifestURL)
            guard DeviceSyncArtifactDigester.sha256(manifestData) == request.manifestDigest else {
                return .unreadable("request manifest digest 與實際 artifact 不一致。")
            }
            let manifest = try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncManifestArtifact.self,
                from: manifestData
            )
            guard manifest.schemaVersion == 1,
                  manifest.requestID == requestID,
                  manifest.authorityEpoch == authorityEpoch,
                  manifest.ledgerSequence == ledgerSequence,
                  manifest.authorityPrimary == authorityPrimary,
                  manifest.sourceDeviceID == sourceDeviceID,
                  manifest.targetDeviceID == targetDeviceID,
                  manifest.catalogRevision == catalogRevision,
                  manifest.sourceMode == request.sourceMode,
                  manifest.inventoryDigest == request.inventoryDigest,
                  manifest.fallbackAuthorizationID == request.fallbackAuthorizationID,
                  manifest.fallbackAuthorizationPath == request.fallbackAuthorizationPath,
                  manifest.fallbackAuthorizationDigest == request.fallbackAuthorizationDigest,
                  manifest.items.map(\.id) == receipt.requiredItemIDs,
                  manifest.items.count == (receipt.items ?? []).count,
                  zip(manifest.items, receipt.items ?? []).allSatisfy({ pair in
                      let (manifestItem, receiptItem) = pair
                      return manifestItem.id == receiptItem.id
                          && manifestItem.sourceDigest == receiptItem.sourceDigest
                          && DeviceSyncDigestValidator.isSHA256(manifestItem.sourceDigest)
                  })
            else {
                return .unreadable("manifest authority/catalog/item binding 不一致。")
            }

            let consumerReadbackURL = try exactArtifactURL(
                components: [
                    "consumer-readbacks",
                    receipt.target,
                    "\(requestID).json",
                ]
            )
            let consumerReadbackData = try readRegularFile(consumerReadbackURL)
            guard DeviceSyncArtifactDigester.sha256(consumerReadbackData)
                == receipt.consumerReadbackDigest
            else {
                return .unreadable("actual consumer readback digest 與 ACK 不一致。")
            }
            let consumerReadbackSet = try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncTargetConsumerReadbackSetArtifact.self,
                from: consumerReadbackData
            )
            guard consumerReadbackSet.schema == Self.consumerReadbackSchema,
                  consumerReadbackSet.requestID == requestID,
                  consumerReadbackSet.target == receipt.target,
                  consumerReadbackSet.authorityEpoch == authorityEpoch,
                  consumerReadbackSet.ledgerSequence == ledgerSequence,
                  consumerReadbackSet.authorityPrimary == authorityPrimary,
                  consumerReadbackSet.sourceDeviceID == sourceDeviceID,
                  consumerReadbackSet.targetDeviceID == targetDeviceID,
                  consumerReadbackSet.catalogRevision == catalogRevision,
                  consumerReadbackSet.manifestDigest == request.manifestDigest,
                  consumerReadbackSet.requiredConsumerIDs == Self.requiredConsumerIDs,
                  consumerReadbackSet.readbackCount == consumerReadbackCount,
                  consumerReadbackSet.readbacks.count == consumerReadbackCount,
                  consumerReadbackSet.status == "passed"
            else {
                return .unreadable(
                    "actual consumer readback set 未綁定同一 request/target/epoch/sequence/catalog/manifest。"
                )
            }
            let manifestItemsByID = Dictionary(
                uniqueKeysWithValues: manifest.items.map { ($0.id, $0) }
            )
            let receiptItemsByID = Dictionary(
                uniqueKeysWithValues: (receipt.items ?? []).map { ($0.id, $0) }
            )
            var consumerReadbackEvidence: [DeviceSyncConsumerReadbackEvidence] = []
            for readback in consumerReadbackSet.readbacks {
                guard readback.schema == "TatwoTargetConsumerReadbackV1",
                      readback.requestID == requestID,
                      readback.targetDeviceID == targetDeviceID,
                      readback.authorityPrimary == authorityPrimary,
                      readback.authorityEpoch == authorityEpoch,
                      readback.ledgerSequence == ledgerSequence,
                      readback.catalogRevision == catalogRevision,
                      Self.requiredConsumerIDs.contains(readback.consumerID),
                      DeviceSyncReceipt.isNonEmpty(readback.consumerKind),
                      DeviceSyncReceipt.isSafeIdentifier(readback.sourceItemID),
                      DeviceSyncDigestValidator.matches(
                          algorithm: "sha256",
                          source: readback.expectedDigest,
                          applied: readback.loadedDigest
                      ),
                      DeviceSyncReceipt.isNonEmpty(readback.loadedRevision),
                      Self.isSafeReadbackPath(readback.loadedPath),
                      DeviceSyncReceipt.isNonEmpty(readback.runtimeRef),
                      readback.status == "loaded",
                      let manifestItem = manifestItemsByID[readback.sourceItemID]
                else {
                    return .unreadable("actual consumer readback record schema/digest/path 不合法。")
                }
                if readback.sourceItemID == "skills.skillet" {
                    guard let skillItem = receiptItemsByID["skills.skillet"],
                          skillItem.hasAnySkilletConsumerReference
                    else {
                        return .unreadable(
                            "Skillet consumer readback 缺少非空 repository evidence。"
                        )
                    }
                    guard skillItem.containsVerifiedSkilletConsumerReference(
                        revisionID: readback.loadedRevision,
                        contentDigest: readback.expectedDigest
                    ) else {
                        return .unreadable(
                            "Skillet consumer loaded revision/digest 未對應 ACK repository。"
                        )
                    }
                } else {
                    guard readback.expectedDigest == manifestItem.sourceDigest,
                          readback.loadedRevision == "sha256-\(readback.loadedDigest)"
                    else {
                        return .unreadable(
                            "\(readback.sourceItemID) consumer loaded digest/revision 與 manifest 不一致。"
                        )
                    }
                }
                consumerReadbackEvidence.append(
                    DeviceSyncConsumerReadbackEvidence(
                        consumerID: readback.consumerID,
                        consumerKind: readback.consumerKind,
                        sourceItemID: readback.sourceItemID,
                        expectedDigest: readback.expectedDigest,
                        loadedDigest: readback.loadedDigest,
                        loadedRevision: readback.loadedRevision,
                        loadedPath: readback.loadedPath,
                        runtimeRef: readback.runtimeRef,
                        observedAt: readback.observedAt,
                        status: readback.status
                    )
                )
            }
            let projectedConsumerEvidence = DeviceSyncAttestationEvidence(
                level: .targetLocallyAttested,
                attestedAt: nil,
                provenance: Self.consumerReadbackSchema,
                detail: "actual consumer readback set 已解析。",
                consumerReadbackDigest: receipt.consumerReadbackDigest,
                consumerReadbacks: consumerReadbackEvidence
            )
            guard projectedConsumerEvidence.hasCompleteConsumerReadback else {
                return .unreadable("required consumers 未完整回報 loaded digest/revision。")
            }

            let attestationURL = try exactArtifactURL(
                components: ["attestations", receipt.target, "\(requestID).json"]
            )
            let attestationData = try readRegularFile(attestationURL)
            guard DeviceSyncArtifactDigester.sha256(attestationData)
                == receipt.targetAttestationDigest
            else {
                return .unreadable("target attestation digest 與 ACK 不一致。")
            }
            let attestation = try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncTargetAttestationArtifact.self,
                from: attestationData
            )
            let expectedAttestationSignaturePath =
                "signatures/attestations/\(receipt.target)/\(requestID).json"
            guard attestation.schema == Self.attestationSchema,
                  attestation.kind == Self.attestationKind,
                  attestation.requestID == requestID,
                  attestation.target == receipt.target,
                  attestation.authorityEpoch == authorityEpoch,
                  attestation.ledgerSequence == ledgerSequence,
                  attestation.authorityPrimary == authorityPrimary,
                  attestation.sourceDeviceID == sourceDeviceID,
                  attestation.targetDeviceID == targetDeviceID,
                  attestation.catalogRevision == catalogRevision,
                  attestation.transactionPhase == "committed",
                  attestation.manifestDigest == request.manifestDigest,
                  DeviceSyncDigestValidator.isSHA256(attestation.transactionJournalDigest),
                  DeviceSyncDigestValidator.isSHA256(
                      attestation.skilletActiveSetReceiptDigest
                  ),
                  attestation.consumerReadbackKind == receipt.consumerReadbackKind,
                  attestation.consumerReadbackPath == receipt.consumerReadbackPath,
                  attestation.consumerReadbackDigest == receipt.consumerReadbackDigest,
                  attestation.consumerReadbackCount == receipt.consumerReadbackCount,
                  attestation.signaturePurpose == "target-attestation",
                  attestation.signaturePath == expectedAttestationSignaturePath,
                  receipt.targetAttestationSignaturePath
                    == expectedAttestationSignaturePath
            else {
                return .unreadable(
                    "target attestation 未證明同一 request/target/epoch/sequence/catalog committed transaction 與 actual consumer readback。"
                )
            }
            try signatureVerifier.verify(
                payload: attestationData,
                producerName: receipt.target,
                producerDeviceID: targetDeviceID,
                purpose: "target-attestation",
                signaturePath: attestation.signaturePath,
                expectedSignaturePath: expectedAttestationSignaturePath
            )

            return DeviceSyncAttestationEvidence(
                level: .targetLocallyAttested,
                attestedAt: attestation.attestedAt,
                provenance: Self.attestationSchema,
                detail: "request/ACK/attestation signatures、digest、manifest、actual consumers、target、epoch、sequence、catalog 與 committed transaction binding 已驗證。",
                consumerReadbackDigest: receipt.consumerReadbackDigest,
                consumerReadbacks: consumerReadbackEvidence
            )
        } catch {
            return .unreadable("attestation/request/manifest artifact 無法讀取：\(error.localizedDescription)")
        }
    }

    private static func isSafeReadbackPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { component in
                !component.isEmpty && component != "." && component != ".."
            }
    }

    private func exactArtifactURL(components: [String]) throws -> URL {
        var candidate = channelRootURL.standardizedFileURL
        for component in components {
            guard component != ".",
                  component != "..",
                  !component.contains("/"),
                  !component.contains("\\"),
                  !component.isEmpty
            else {
                throw DeviceSyncArtifactError.unsafePath(component)
            }
            candidate.appendPathComponent(component, isDirectory: false)
        }
        let standardizedRoot = channelRootURL.standardizedFileURL.path
        let standardizedCandidate = candidate.standardizedFileURL.path
        guard standardizedCandidate.hasPrefix(standardizedRoot + "/") else {
            throw DeviceSyncArtifactError.unsafePath(standardizedCandidate)
        }
        return candidate
    }

    private func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeviceSyncArtifactError.notRegularFile(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }
}

enum DeviceSyncOperationIndex {
    static func latestPending(
        _ intents: [DeviceSyncIntent]
    ) -> [DeviceSyncOperationKey: DeviceSyncIntent] {
        var result: [DeviceSyncOperationKey: DeviceSyncIntent] = [:]
        for intent in intents {
            let key = intent.operationKey
            // Any pending intent invalidates prior convergence. The selected
            // representative is deterministic input order; requestedAt remains
            // metadata and never decides validity across machines.
            if result[key] == nil { result[key] = intent }
        }
        return result
    }

    static func latestReceipts(
        _ receipts: [DeviceSyncReceipt]
    ) -> [DeviceSyncOperationKey: DeviceSyncReceipt] {
        var result: [DeviceSyncOperationKey: DeviceSyncReceipt] = [:]
        for receipt in receipts {
            let key = receipt.operationKey
            if let current = result[key], !isLater(receipt, than: current) {
                continue
            }
            result[key] = receipt
        }
        return result
    }

    static func latestSourceRefreshAttempts(
        _ attempts: [DeviceSyncSourceRefreshAttempt]
    ) -> [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] {
        var result: [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:]
        for attempt in attempts {
            let key = attempt.operationKey
            if let current = result[key], !isLater(attempt, than: current) {
                continue
            }
            result[key] = attempt
        }
        return result
    }

    static func isLater(_ lhs: DeviceSyncReceipt, than rhs: DeviceSyncReceipt) -> Bool {
        let lhsEpoch = lhs.authorityEpoch ?? Int.min
        let rhsEpoch = rhs.authorityEpoch ?? Int.min
        if lhsEpoch != rhsEpoch { return lhsEpoch > rhsEpoch }

        let lhsSequence = lhs.ledgerSequence ?? Int.min
        let rhsSequence = rhs.ledgerSequence ?? Int.min
        if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }

        let lhsRequest = lhs.requestID ?? ""
        let rhsRequest = rhs.requestID ?? ""
        if lhsRequest != rhsRequest { return lhsRequest > rhsRequest }

        // Wall clocks are presentation metadata only. Cross-device clock skew
        // must never decide authority ordering for an identical request binding.
        return false
    }

    static func isLater(
        _ lhs: DeviceSyncSourceRefreshAttempt,
        than rhs: DeviceSyncSourceRefreshAttempt
    ) -> Bool {
        if lhs.authorityEpoch != rhs.authorityEpoch {
            return lhs.authorityEpoch > rhs.authorityEpoch
        }
        if lhs.ledgerSequence != rhs.ledgerSequence {
            return lhs.ledgerSequence > rhs.ledgerSequence
        }
        if lhs.attemptID != rhs.attemptID {
            return lhs.attemptID > rhs.attemptID
        }
        return false
    }

    static func isLater(
        _ lhs: DeviceSyncSourceRefreshAttempt,
        than rhs: DeviceSyncReceipt
    ) -> Bool {
        let rhsEpoch = rhs.authorityEpoch ?? Int.min
        if lhs.authorityEpoch != rhsEpoch {
            return lhs.authorityEpoch > rhsEpoch
        }
        let rhsSequence = rhs.ledgerSequence ?? Int.min
        if lhs.ledgerSequence != rhsSequence {
            return lhs.ledgerSequence > rhsSequence
        }
        let rhsIdentity = rhs.requestID ?? rhs.sourceRefreshAttemptID ?? ""
        if lhs.attemptID != rhsIdentity {
            return lhs.attemptID > rhsIdentity
        }
        return false
    }

    static func presentationReceipt(
        for key: DeviceSyncOperationKey,
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:]
    ) -> DeviceSyncReceipt? {
        let receipt = receipts[key]
        // A durable pending artifact is the local truth that newer work exists.
        // It immediately invalidates the prior projected convergence without
        // comparing source and target wall clocks.
        if let intent = pending[key] {
            return DeviceSyncReceipt(
                target: intent.target,
                action: intent.action,
                requestedAt: intent.requestedAt,
                result: "pending",
                completedAt: intent.requestedAt,
                message: "已進入本機 outbox，等待 helper 送達目標設備。",
                phase: .queued,
                requestID: nil,
                items: []
            )
        }
        guard let attempt = sourceRefreshAttempts[key] else { return receipt }
        guard let receipt else { return attempt.presentationReceipt }

        let isSamePublishedRequest = receipt.requestID == attempt.attemptID
        let isSameFailedAttempt =
            receipt.sourceRefreshAttemptID == attempt.attemptID
                && attempt.hasFailedSources
        if isSamePublishedRequest {
            return receipt
        }
        if isSameFailedAttempt {
            return attempt.presentationReceipt
        }
        if isLater(attempt, than: receipt) {
            return attempt.presentationReceipt
        }
        return receipt
    }

    static func operationKeys(
        for target: String,
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:]
    ) -> [DeviceSyncOperationKey] {
        let keys = allOperationKeys(
            pending: pending,
            receipts: receipts,
            sourceRefreshAttempts: sourceRefreshAttempts
        )
            .filter { $0.target == target }
        return keys.sorted { lhs, rhs in
            let lhsPending = pending[lhs] != nil
            let rhsPending = pending[rhs] != nil
            if lhsPending != rhsPending { return lhsPending }
            if let lhsAttempt = sourceRefreshAttempts[lhs],
               let rhsAttempt = sourceRefreshAttempts[rhs],
               lhsAttempt.operationKey == rhsAttempt.operationKey
            {
                if isLater(lhsAttempt, than: rhsAttempt) { return true }
                if isLater(rhsAttempt, than: lhsAttempt) { return false }
            }
            if let lhsReceipt = receipts[lhs], let rhsReceipt = receipts[rhs] {
                if isLater(lhsReceipt, than: rhsReceipt) { return true }
                if isLater(rhsReceipt, than: lhsReceipt) { return false }
            } else if (receipts[lhs] != nil) != (receipts[rhs] != nil) {
                return receipts[lhs] != nil
            }
            return lhs.action < rhs.action
        }
    }

    static func allOperationKeys(
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:]
    ) -> Set<DeviceSyncOperationKey> {
        Set(pending.keys)
            .union(receipts.keys)
            .union(sourceRefreshAttempts.keys)
    }

    static func targetNames(
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:]
    ) -> [String] {
        Set(
            allOperationKeys(
                pending: pending,
                receipts: receipts,
                sourceRefreshAttempts: sourceRefreshAttempts
            ).map(\.target)
        ).sorted()
    }
}

enum DeviceSyncDigestValidator {
    static func matches(
        algorithm: String?,
        source: String?,
        applied: String?
    ) -> Bool {
        guard let source, let applied, source == applied else { return false }
        switch algorithm?.lowercased() {
        case "sha256":
            return isLowercaseHex(source, allowedLengths: [64])
        case "git-object-id":
            return isLowercaseHex(source, allowedLengths: [40, 64])
        default:
            return false
        }
    }

    private static func isLowercaseHex(
        _ value: String,
        allowedLengths: Set<Int>
    ) -> Bool {
        guard allowedLengths.contains(value.count), !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                true
            default:
                false
            }
        }
    }

    static func isSHA256(_ value: String?) -> Bool {
        guard let value else { return false }
        return isLowercaseHex(value, allowedLengths: [64])
    }
}

enum DeviceSyncArtifactError: Error, Equatable, LocalizedError {
    case unsafePath(String)
    case notRegularFile(String)
    case unsupportedSchema(String)
    case unreadableArtifact(String)
    case multipleRequestArtifacts(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "unsafe artifact path: \(path)"
        case .notRegularFile(let file):
            return "artifact is not a regular file: \(file)"
        case .unsupportedSchema(let schema):
            return "unsupported sync artifact schema: \(schema)"
        case .unreadableArtifact(let file):
            return "unreadable sync artifact: \(file)"
        case .multipleRequestArtifacts(let requestID):
            return "multiple request artifacts bind the same request: \(requestID)"
        }
    }
}

enum DeviceSyncArtifactIssueScope: Equatable, Sendable {
    case global
    case verifiedBinding(
        target: String?,
        action: String?,
        requestID: String?
    )

    var target: String? {
        guard case .verifiedBinding(let target, _, _) = self else { return nil }
        return target
    }

    var action: String? {
        guard case .verifiedBinding(_, let action, _) = self else { return nil }
        return action
    }

    var requestID: String? {
        guard case .verifiedBinding(_, _, let requestID) = self else { return nil }
        return requestID
    }
}

struct DeviceSyncArtifactIssue: Equatable, Identifiable, Sendable {
    var id: String {
        [kind, target, action, requestID, fileName]
            .map(Self.stableIDComponent)
            .joined(separator: "|")
    }
    let kind: String
    let fileName: String
    let message: String
    let scope: DeviceSyncArtifactIssueScope

    var target: String? { scope.target }
    var action: String? { scope.action }
    var requestID: String? { scope.requestID }

    init(
        kind: String,
        fileName: String,
        message: String,
        scope: DeviceSyncArtifactIssueScope = .global
    ) {
        self.kind = kind
        self.fileName = fileName
        self.message = message
        self.scope = scope
    }

    private static func stableIDComponent(_ value: String?) -> String {
        guard let value else { return "nil" }
        return "s\(value.utf8.count):\(value)"
    }
}

struct DeviceSyncReceiptLoadResult: Equatable, Sendable {
    let receipts: [DeviceSyncReceipt]
    let issues: [DeviceSyncArtifactIssue]

    var isFailClosed: Bool {
        !issues.isEmpty
    }

    var issueSummary: String? {
        guard !issues.isEmpty else { return nil }
        return issues.map(\.message).joined(separator: "；")
    }
}

enum DeviceSyncSourceRefreshOutcome: String, Codable, Equatable, Sendable {
    case started
    case converged
    case partial
    case failed
}

struct DeviceSyncSourceRefreshResult: Codable, Equatable, Sendable {
    let sourceName: String
    let repositoryID: String
    let displayName: String
    let status: String
    let message: String?
    let revisionID: String?
    let contentDigest: String?

    var isFailed: Bool {
        status == "failed"
    }
}

struct DeviceSyncSourceRefreshAttempt: Codable, Equatable, Sendable {
    static let schema = "TatwoSkilletCanonicalRefreshReceiptV1"
    static let evidenceKind = "local-source-refresh-attempt"

    let schema: String
    let evidenceKind: String
    let attemptID: String
    let target: String
    let action: String
    let requestedAt: Date
    let currentDeviceName: String
    let currentDeviceID: String
    let authorityPrimary: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let catalogRevision: String
    let sourceDeviceID: String
    let targetDeviceID: String
    let outcome: DeviceSyncSourceRefreshOutcome
    let sourceMode: String
    let storeMutation: String
    let inventoryDigest: String
    let fallbackAuthorizationID: String
    let fallbackAuthorizationPath: String
    let fallbackAuthorizationDigest: String
    let discoveredSourceCount: Int
    let refreshedCount: Int
    let failedCount: Int
    let results: [DeviceSyncSourceRefreshResult]
    let message: String?
    let startedAt: Date
    let completedAt: Date

    var operationKey: DeviceSyncOperationKey {
        DeviceSyncOperationKey(target: target, action: action)
    }

    var hasFailedSources: Bool {
        outcome == .partial
            || outcome == .failed
            || failedCount > 0
            || results.contains(where: \.isFailed)
    }

    var presentationReceipt: DeviceSyncReceipt {
        let phase: DeviceSyncReceiptPhase
        let result: String
        switch outcome {
        case .started:
            phase = .validating
            result = "pending"
        case .converged:
            // A local source refresh is not request publication, an ACK, or
            // target attestation. Keep it non-terminal even when the source
            // store itself converged.
            phase = .validating
            result = "partial"
        case .partial, .failed:
            phase = .failed
            result = "failure"
        }
        let itemReceipts = results.enumerated().map { index, source in
            let sourceDigest = DeviceSyncDigestValidator.isSHA256(source.contentDigest)
                ? source.contentDigest
                : nil
            return DeviceSyncItemReceipt(
                id: "skillet.source.\(index).\(source.repositoryID.isEmpty ? "unbound" : source.repositoryID)",
                displayName: source.displayName,
                phase: source.isFailed ? .failed : .verified,
                digestAlgorithm: sourceDigest == nil ? nil : "sha256",
                sourceDigest: sourceDigest,
                appliedDigest: sourceDigest,
                message: source.message
                    ?? (source.isFailed ? "source refresh failed" : "source refresh verified")
            )
        }
        let completedSources = max(0, min(refreshedCount, discoveredSourceCount))
        let progress = DeviceSyncProgressPayload(
            completedItems: completedSources,
            totalItems: discoveredSourceCount > 0 ? discoveredSourceCount : nil,
            completedRepositories: completedSources,
            totalRepositories: discoveredSourceCount > 0 ? discoveredSourceCount : nil,
            currentItem: results.first(where: \.isFailed)?.displayName
        )
        let detail = "這是主設備上的本機 source-refresh attempt；尚未證明 request 已發布，"
            + "也不是副設備 ACK 或 target attestation。"
        return DeviceSyncReceipt(
            target: target,
            action: action,
            requestedAt: requestedAt,
            result: result,
            completedAt: completedAt,
            message: message ?? detail,
            phase: phase,
            requestID: nil,
            sourceRefreshAttemptID: attemptID,
            authorityEpoch: authorityEpoch,
            ledgerSequence: ledgerSequence,
            authorityPrimary: authorityPrimary,
            sourceDeviceID: sourceDeviceID,
            targetDeviceID: targetDeviceID,
            catalogRevision: catalogRevision,
            sourceMode: sourceMode,
            inventoryDigest: inventoryDigest.isEmpty ? nil : inventoryDigest,
            fallbackAuthorizationID: fallbackAuthorizationID,
            fallbackAuthorizationPath: fallbackAuthorizationPath,
            fallbackAuthorizationDigest: fallbackAuthorizationDigest,
            requiredItemIDs: nil,
            items: itemReceipts,
            attestationEvidence: DeviceSyncAttestationEvidence(
                level: .none,
                attestedAt: nil,
                provenance: Self.evidenceKind,
                detail: detail
            ),
            progress: progress
        )
    }
}

struct DeviceSyncSourceRefreshAttemptLoadResult: Equatable, Sendable {
    let attempts: [DeviceSyncSourceRefreshAttempt]
    let issues: [DeviceSyncArtifactIssue]

    var isFailClosed: Bool {
        !issues.isEmpty
    }
}

enum DeviceSyncTransactionProjectionState: String, Equatable, Sendable {
    case preparing
    case oldMirrorMoveStarted
    case committedAwaitingACK = "committed-awaiting-ACK"
    case recovering
    case rollbackPending
    case diverged
    case rolledBack
    case targetLocallyAttested = "target-locally-attested"
    case unreadable

    var progress: DeviceSyncProgressValue {
        let fraction: Double
        switch self {
        case .preparing: fraction = 0.20
        case .oldMirrorMoveStarted: fraction = 0.56
        case .committedAwaitingACK: fraction = 0.94
        case .recovering: fraction = 0.50
        case .rollbackPending: fraction = 0.42
        case .diverged: fraction = 0.88
        case .rolledBack: fraction = 0.18
        case .targetLocallyAttested: fraction = 1
        case .unreadable: fraction = 0
        }
        return DeviceSyncProgressValue(fraction: fraction, provenance: .phaseDerived)
    }
}

struct DeviceSyncSystemTransactionJournal: Codable, Equatable, Sendable {
    let schema: String
    let requestID: String
    let phase: String
    let authorityPrimary: String
    let authorityEpoch: Int
    let ledgerSequence: Int
    let catalogRevision: String
    let ackState: String
    let recoveryState: String
    let createdAt: Date
    let updatedAt: Date
    let message: String
}

struct DeviceSyncTransactionProjection: Equatable, Identifiable, Sendable {
    var id: String { journal.requestID }
    let target: String
    let action: String
    let journal: DeviceSyncSystemTransactionJournal
    let state: DeviceSyncTransactionProjectionState
    let attestationEvidence: DeviceSyncAttestationEvidence

    var statusLabel: String {
        switch state {
        case .preparing: "preparing · 建立 rollback snapshots"
        case .oldMirrorMoveStarted: "oldMirrorMoveStarted · live mirror 已進入交換區"
        case .committedAwaitingACK: "committed-awaiting-ACK · 不重複 activation"
        case .recovering: "recovering · 由 durable journal 回復"
        case .rollbackPending: "rollbackPending · 等待完成 rollback"
        case .diverged: "diverged · 禁止假綠，需人工處理"
        case .rolledBack: "rolledBack · 已回復前一版"
        case .targetLocallyAttested: "target-locally-attested · transaction 已閉環"
        case .unreadable: "unreadable · artifact fail-closed"
        }
    }
}

struct DeviceSyncTransactionProjectionLoadResult: Equatable, Sendable {
    let projections: [DeviceSyncTransactionProjection]
    let issues: [DeviceSyncArtifactIssue]

    var isFailClosed: Bool {
        !issues.isEmpty
    }
}

struct EnrolledDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let role: String
    let enrolledAt: Date
    let deviceId: String?

    init(
        name: String,
        role: String,
        enrolledAt: Date,
        deviceId: String? = nil
    ) {
        self.name = name
        self.role = role
        self.enrolledAt = enrolledAt
        self.deviceId = deviceId
    }
}

enum DeviceSyncOutboxJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct DeviceSyncOutboxStore: Sendable {
    static let receiptSchema = "TatwoDeviceSyncReceiptV1"
    static let transactionSchema = "TatwoSystemSyncTransactionV1"

    private let rootURL: URL
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    init(
        rootURL: URL = Self.defaultApplicationSupportRoot(),
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.rootURL = rootURL
        self.now = now
        self.uuid = uuid
    }

    @discardableResult
    func enqueue(target: String, action: String) throws -> DeviceSyncIntent {
        guard let canonicalAction = DeviceSyncAction.canonicalRequestValue(action) else {
            throw DeviceSyncOutboxError.unsupportedRequestAction(action)
        }
        let intent = DeviceSyncIntent(
            target: target,
            action: canonicalAction,
            requestedAt: now()
        )
        let pendingURL = outboxRootURL.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pendingURL,
            withIntermediateDirectories: true
        )
        let destination = pendingURL.appendingPathComponent(
            "\(uuid().uuidString).json",
            isDirectory: false
        )
        try DeviceSyncOutboxJSON.encoder.encode(intent).write(
            to: destination,
            options: [.atomic]
        )
        return intent
    }

    func pendingIntents() throws -> [DeviceSyncIntent] {
        try decodeJSONFiles(
            in: outboxRootURL.appendingPathComponent("pending", isDirectory: true),
            as: DeviceSyncIntent.self
        )
    }

    func pendingCount() throws -> Int {
        try jsonFiles(
            in: outboxRootURL.appendingPathComponent("pending", isDirectory: true)
        ).count
    }

    func receipts() throws -> [DeviceSyncReceipt] {
        try receiptLoadResult().receipts
    }

    func receiptLoadResult() throws -> DeviceSyncReceiptLoadResult {
        let verifier = DeviceSyncTargetAttestationVerifier(
            channelRootURL: channelRootURL
        )
        var loaded: [DeviceSyncReceipt] = []
        var issues: [DeviceSyncArtifactIssue] = []

        let sources: [
            (
                directory: URL,
                requiresChannelSignature: Bool,
                unreadableKind: String,
                rootUnreadableKind: String
            )
        ] = [
            (
                outboxRootURL.appendingPathComponent(
                    "receipts",
                    isDirectory: true
                ),
                false,
                "receipt-unreadable",
                "receipt-root-unreadable"
            ),
            (
                channelRootURL.appendingPathComponent(
                    "acks",
                    isDirectory: true
                ),
                true,
                "channel-ack-unreadable",
                "channel-ack-root-unreadable"
            ),
        ]

        for source in sources {
            let urls: [URL]
            do {
                urls = try safeJSONFiles(in: source.directory)
            } catch {
                issues.append(
                    DeviceSyncArtifactIssue(
                        kind: source.rootUnreadableKind,
                        fileName: source.directory.lastPathComponent,
                        message: "\(source.directory.lastPathComponent) 不是安全且可讀的同步 artifact 目錄：\(error.localizedDescription)"
                    )
                )
                continue
            }

            for url in urls {
                do {
                    let data = try readRegularFile(url)
                    try validateArtifactSchema(
                        data,
                        acceptedSchema: Self.receiptSchema,
                        acceptedSchemaVersion: 1,
                        allowsMissingSchema: true
                    )
                    let decoded = try DeviceSyncOutboxJSON.decoder.decode(
                        DeviceSyncReceipt.self,
                        from: data
                    )
                    let evidence = verifier.verify(
                        receipt: decoded,
                        ackReceiptData: data
                    )
                    if evidence.level == .unreadable {
                        issues.append(
                            artifactIssue(
                                kind: source.requiresChannelSignature
                                    ? "channel-ack-unreadable"
                                    : "attestation-unreadable",
                                url: url,
                                message: evidence.detail
                            )
                        )
                    }
                    loaded.append(decoded.withAttestationEvidence(evidence))
                } catch {
                    issues.append(
                        artifactIssue(
                            kind: source.unreadableKind,
                            url: url,
                            message: error.localizedDescription
                        )
                    )
                }
            }
        }

        let requestGroups = Dictionary(
            grouping: loaded.compactMap { receipt -> DeviceSyncReceipt? in
                receipt.requestID == nil ? nil : receipt
            },
            by: { $0.requestID! }
        )
        for (requestID, receipts) in requestGroups where receipts.count > 1 {
            let canonical = receipts[0]
            if receipts.dropFirst().contains(where: { $0 != canonical }) {
                let sharedTarget = receipts.allSatisfy {
                    $0.target == canonical.target
                } ? canonical.target : nil
                let sharedAction = receipts.allSatisfy {
                    $0.action == canonical.action
                } ? canonical.action : nil
                issues.append(
                    DeviceSyncArtifactIssue(
                        kind: "receipt-conflict",
                        fileName: requestID,
                        message: "同一 request \(requestID) 存在互相衝突的 ACK artifacts。",
                        scope: .verifiedBinding(
                            target: sharedTarget,
                            action: sharedAction,
                            requestID: requestID
                        )
                    )
                )
            }
        }

        var deduplicated: [DeviceSyncReceipt] = []
        for receipt in loaded where !deduplicated.contains(receipt) {
            deduplicated.append(receipt)
        }
        loaded = deduplicated

        loaded.sort { lhs, rhs in
            if lhs.operationKey == rhs.operationKey {
                return DeviceSyncOperationIndex.isLater(lhs, than: rhs)
            }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.action < rhs.action
        }
        issues.sort {
            if $0.fileName == $1.fileName { return $0.kind < $1.kind }
            return $0.fileName < $1.fileName
        }
        return DeviceSyncReceiptLoadResult(receipts: loaded, issues: issues)
    }

    func sourceRefreshAttemptLoadResult() throws
        -> DeviceSyncSourceRefreshAttemptLoadResult
    {
        let root = rootURL
            .appendingPathComponent("device-sync-state", isDirectory: true)
            .appendingPathComponent("skillet-export-receipts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return DeviceSyncSourceRefreshAttemptLoadResult(attempts: [], issues: [])
        }
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            return DeviceSyncSourceRefreshAttemptLoadResult(
                attempts: [],
                issues: [
                    DeviceSyncArtifactIssue(
                        kind: "source-refresh-root-unreadable",
                        fileName: root.lastPathComponent,
                        message: "Skillet source-refresh receipt root 不是安全的本機目錄。"
                    )
                ]
            )
        }

        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var attempts: [DeviceSyncSourceRefreshAttempt] = []
        var issues: [DeviceSyncArtifactIssue] = []

        for directory in directories {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                issues.append(
                    artifactIssue(
                        kind: "source-refresh-directory-unreadable",
                        url: directory,
                        message: "source-refresh attempt entry 不是安全目錄。"
                    )
                )
                continue
            }
            let receiptURL = directory.appendingPathComponent(
                "canonical-refresh.json",
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: receiptURL.path) else {
                // Repository export receipts may coexist below this root in
                // older installations. Only directories with the canonical
                // attempt receipt participate in App projection.
                continue
            }
            do {
                let data = try readRegularFile(receiptURL)
                guard let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
                else {
                    throw DeviceSyncArtifactError.unreadableArtifact(
                        receiptURL.lastPathComponent
                    )
                }
                guard object["schema"] as? String
                    == DeviceSyncSourceRefreshAttempt.schema
                else {
                    throw DeviceSyncArtifactError.unsupportedSchema(
                        String(describing: object["schema"])
                    )
                }
                // Pre-I3 receipts use the same refresh schema but contain no
                // local-attempt identity. They remain durable historical
                // evidence and are intentionally ignored rather than
                // misprojected as ACKs.
                guard object["evidenceKind"] as? String
                    == DeviceSyncSourceRefreshAttempt.evidenceKind
                else {
                    continue
                }
                let attempt = try DeviceSyncOutboxJSON.decoder.decode(
                    DeviceSyncSourceRefreshAttempt.self,
                    from: data
                )
                try validateSourceRefreshAttempt(
                    attempt,
                    directoryName: directory.lastPathComponent
                )
                attempts.append(attempt)
            } catch {
                issues.append(
                    artifactIssue(
                        kind: "source-refresh-attempt-unreadable",
                        url: receiptURL,
                        message: error.localizedDescription
                    )
                )
            }
        }

        attempts.sort { lhs, rhs in
            if lhs.operationKey == rhs.operationKey {
                return DeviceSyncOperationIndex.isLater(lhs, than: rhs)
            }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.action < rhs.action
        }
        issues.sort {
            if $0.fileName == $1.fileName { return $0.kind < $1.kind }
            return $0.fileName < $1.fileName
        }
        return DeviceSyncSourceRefreshAttemptLoadResult(
            attempts: attempts,
            issues: issues
        )
    }

    func transactionProjectionLoadResult(
        receipts: [DeviceSyncReceipt]
    ) throws -> DeviceSyncTransactionProjectionLoadResult {
        let root = rootURL
            .appendingPathComponent("device-sync-state", isDirectory: true)
            .appendingPathComponent("system-transactions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return DeviceSyncTransactionProjectionLoadResult(projections: [], issues: [])
        }
        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            return DeviceSyncTransactionProjectionLoadResult(
                projections: [],
                issues: [
                    DeviceSyncArtifactIssue(
                        kind: "transaction-root-unreadable",
                        fileName: root.lastPathComponent,
                        message: "system transaction root 不是安全的本機目錄。"
                    )
                ]
            )
        }

        let latestReceiptByRequest = latestReceiptsByRequest(receipts)
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var projections: [DeviceSyncTransactionProjection] = []
        var issues: [DeviceSyncArtifactIssue] = []

        for directory in directories {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                issues.append(
                    artifactIssue(
                        kind: "transaction-directory-unreadable",
                        url: directory,
                        message: "transaction entry 不是安全的本機目錄。"
                    )
                )
                continue
            }
            let journalURL = directory.appendingPathComponent(
                "journal.json",
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: journalURL.path) else {
                issues.append(
                    artifactIssue(
                        kind: "transaction-journal-missing",
                        url: directory,
                        message: "transaction 目錄缺少 durable journal.json。"
                    )
                )
                continue
            }

            do {
                let journalData = try readRegularFile(journalURL)
                try validateArtifactSchema(
                    journalData,
                    acceptedSchema: Self.transactionSchema,
                    acceptedSchemaVersion: nil,
                    allowsMissingSchema: false
                )
                let journal = try DeviceSyncOutboxJSON.decoder.decode(
                    DeviceSyncSystemTransactionJournal.self,
                    from: journalData
                )
                guard journal.schema == Self.transactionSchema,
                      DeviceSyncReceipt.isSafeIdentifier(journal.requestID),
                      journal.authorityEpoch >= 0,
                      journal.ledgerSequence > 0,
                      journal.createdAt <= journal.updatedAt
                else {
                    throw DeviceSyncArtifactError.unreadableArtifact(
                        journalURL.lastPathComponent
                    )
                }
                if !directory.lastPathComponent.hasPrefix(".preparing-"),
                   directory.lastPathComponent != journal.requestID
                {
                    throw DeviceSyncArtifactError.unreadableArtifact(
                        "transaction directory/request mismatch"
                    )
                }

                let receipt = latestReceiptByRequest[journal.requestID]
                let request = try requestArtifact(requestID: journal.requestID)
                guard request != nil || receipt != nil else {
                    throw DeviceSyncArtifactError.unreadableArtifact(
                        "request \(journal.requestID) has no channel request or ACK binding"
                    )
                }
                if let request {
                    guard request.requestID == journal.requestID,
                          request.authorityPrimary == journal.authorityPrimary,
                          request.authorityEpoch == journal.authorityEpoch,
                          request.ledgerSequence == journal.ledgerSequence,
                          request.catalogRevision == journal.catalogRevision
                    else {
                        throw DeviceSyncArtifactError.unreadableArtifact(
                            "transaction journal/request authority binding"
                        )
                    }
                }
                if let receipt {
                    guard receipt.requestID == journal.requestID,
                          receipt.authorityPrimary == journal.authorityPrimary,
                          receipt.authorityEpoch == journal.authorityEpoch,
                          receipt.ledgerSequence == journal.ledgerSequence,
                          receipt.catalogRevision == journal.catalogRevision
                    else {
                        throw DeviceSyncArtifactError.unreadableArtifact(
                            "transaction journal/ACK authority binding"
                        )
                    }
                }

                let target = request?.target ?? receipt?.target ?? "unknown-target"
                let action = request?.action ?? receipt?.action ?? "system-pull"
                let evidence = receipt?.attestationEvidence ?? .none
                let state = Self.projectTransactionState(
                    journal: journal,
                    receipt: receipt,
                    evidence: evidence
                )
                if state == .unreadable {
                    issues.append(
                        artifactIssue(
                            kind: "transaction-phase-unreadable",
                            url: journalURL,
                            message: "未知 transaction phase/recovery/ACK 狀態："
                                + "\(journal.phase)/\(journal.recoveryState)/\(journal.ackState)",
                            scope: .verifiedBinding(
                                target: target,
                                action: action,
                                requestID: journal.requestID
                            )
                        )
                    )
                }
                projections.append(
                    DeviceSyncTransactionProjection(
                        target: target,
                        action: action,
                        journal: journal,
                        state: state,
                        attestationEvidence: evidence
                    )
                )
            } catch {
                issues.append(
                    artifactIssue(
                        kind: "transaction-journal-unreadable",
                        url: journalURL,
                        message: error.localizedDescription
                    )
                )
            }
        }

        projections.sort { lhs, rhs in
            let left = lhs.journal
            let right = rhs.journal
            if left.authorityEpoch != right.authorityEpoch {
                return left.authorityEpoch > right.authorityEpoch
            }
            if left.ledgerSequence != right.ledgerSequence {
                return left.ledgerSequence > right.ledgerSequence
            }
            if left.requestID != right.requestID {
                return left.requestID > right.requestID
            }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.action < rhs.action
        }
        issues.sort {
            if $0.fileName == $1.fileName { return $0.kind < $1.kind }
            return $0.fileName < $1.fileName
        }
        return DeviceSyncTransactionProjectionLoadResult(
            projections: projections,
            issues: issues
        )
    }

    func enrolledDevices() throws -> [EnrolledDevice] {
        try decodeJSONFiles(
            in: rootURL
                .appendingPathComponent("device-sync-channel", isDirectory: true)
                .appendingPathComponent("devices", isDirectory: true),
            as: EnrolledDevice.self
        )
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func secondaryDevices() throws -> [EnrolledDevice] {
        try enrolledDevices().filter { $0.role == "secondary" }
    }

    private var outboxRootURL: URL {
        rootURL.appendingPathComponent("device-sync-outbox", isDirectory: true)
    }

    private var channelRootURL: URL {
        rootURL.appendingPathComponent("device-sync-channel", isDirectory: true)
    }

    private func jsonFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func decodeJSONFiles<Value: Decodable>(
        in directory: URL,
        as type: Value.Type
    ) throws -> [Value] {
        try jsonFiles(in: directory).compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? DeviceSyncOutboxJSON.decoder.decode(type, from: data)
        }
    }

    private func safeJSONFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw DeviceSyncArtifactError.notRegularFile(directory.lastPathComponent)
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DeviceSyncArtifactError.notRegularFile(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }

    private func validateArtifactSchema(
        _ data: Data,
        acceptedSchema: String,
        acceptedSchemaVersion: Int?,
        allowsMissingSchema: Bool
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceSyncArtifactError.unreadableArtifact("top-level JSON object")
        }
        if let rawSchema = object["schema"] {
            guard let schema = rawSchema as? String, schema == acceptedSchema else {
                throw DeviceSyncArtifactError.unsupportedSchema(String(describing: rawSchema))
            }
        } else if !allowsMissingSchema {
            throw DeviceSyncArtifactError.unsupportedSchema("missing")
        }
        if let rawVersion = object["schemaVersion"] {
            guard let acceptedSchemaVersion,
                  let number = rawVersion as? NSNumber,
                  number.intValue == acceptedSchemaVersion
            else {
                throw DeviceSyncArtifactError.unsupportedSchema(
                    "\(acceptedSchema)#\(String(describing: rawVersion))"
                )
            }
        }
    }

    private func artifactIssue(
        kind: String,
        url: URL,
        message: String,
        scope: DeviceSyncArtifactIssueScope = .global
    ) -> DeviceSyncArtifactIssue {
        DeviceSyncArtifactIssue(
            kind: kind,
            fileName: url.lastPathComponent,
            message: "\(url.lastPathComponent)：\(message)",
            scope: scope
        )
    }

    private func validateSourceRefreshAttempt(
        _ attempt: DeviceSyncSourceRefreshAttempt,
        directoryName: String
    ) throws {
        guard attempt.schema == DeviceSyncSourceRefreshAttempt.schema,
              attempt.evidenceKind == DeviceSyncSourceRefreshAttempt.evidenceKind,
              DeviceSyncReceipt.isSafeIdentifier(attempt.attemptID),
              directoryName == attempt.attemptID,
              DeviceSyncReceipt.isSafeIdentifier(attempt.target),
              attempt.action == "system-pull",
              DeviceSyncReceipt.isSafeIdentifier(attempt.currentDeviceName),
              DeviceSyncReceipt.isSafeIdentifier(attempt.currentDeviceID),
              DeviceSyncReceipt.isSafeIdentifier(attempt.authorityPrimary),
              attempt.authorityEpoch >= 0,
              attempt.ledgerSequence > 0,
              DeviceSyncReceipt.isSafeIdentifier(attempt.sourceDeviceID),
              DeviceSyncReceipt.isSafeIdentifier(attempt.targetDeviceID),
              !attempt.catalogRevision.isEmpty,
              attempt.requestedAt <= attempt.startedAt,
              attempt.startedAt <= attempt.completedAt,
              attempt.discoveredSourceCount >= 0,
              attempt.refreshedCount >= 0,
              attempt.failedCount >= 0,
              attempt.refreshedCount <= attempt.discoveredSourceCount,
              attempt.sourceMode == "unresolved"
                || attempt.sourceMode == DeviceSyncSourceProvenanceValidator.canonical
                || attempt.sourceMode
                    == DeviceSyncSourceProvenanceValidator.runtimeFallback
        else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "invalid local source-refresh attempt binding"
            )
        }

        let failedResults = attempt.results.filter(\.isFailed)
        guard failedResults.count == attempt.failedCount,
              attempt.results.allSatisfy({ result in
                  !result.sourceName.isEmpty
                      && !result.displayName.isEmpty
                      && (result.repositoryID.isEmpty
                          || DeviceSyncReceipt.isSafeIdentifier(result.repositoryID))
                      && ["failed", "refreshed", "validated"].contains(result.status)
                      && (result.contentDigest == nil
                          || DeviceSyncDigestValidator.isSHA256(result.contentDigest))
                      && (result.revisionID == nil
                          || result.contentDigest == nil
                          || result.revisionID == "rev-\(result.contentDigest!)")
              })
        else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "invalid local source-refresh result set"
            )
        }

        switch attempt.outcome {
        case .started:
            guard attempt.results.isEmpty,
                  attempt.failedCount == 0,
                  attempt.storeMutation == "not-started"
            else {
                throw DeviceSyncArtifactError.unreadableArtifact(
                    "started source-refresh attempt contains terminal evidence"
                )
            }
        case .converged:
            guard attempt.failedCount == 0,
                  attempt.refreshedCount == attempt.discoveredSourceCount,
                  DeviceSyncSourceProvenanceValidator.isValid(
                      sourceMode: attempt.sourceMode,
                      inventoryDigest: attempt.inventoryDigest,
                      fallbackAuthorizationID: attempt.fallbackAuthorizationID,
                      fallbackAuthorizationPath: attempt.fallbackAuthorizationPath,
                      fallbackAuthorizationDigest: attempt.fallbackAuthorizationDigest,
                      authorityPrimary: attempt.authorityPrimary,
                      authorityEpoch: attempt.authorityEpoch
                  )
            else {
                throw DeviceSyncArtifactError.unreadableArtifact(
                    "converged source-refresh attempt lacks trusted source provenance"
                )
            }
        case .partial, .failed:
            guard !failedResults.isEmpty,
                  !attempt.storeMutation.hasPrefix("activated")
            else {
                throw DeviceSyncArtifactError.unreadableArtifact(
                    "failed source-refresh attempt claims activation or lacks failed rows"
                )
            }
        }

        let messages = [attempt.message].compactMap { $0 }
            + attempt.results.compactMap(\.message)
        guard messages.allSatisfy({ message in
            !message.contains("/Users/")
                && !message.contains("/Volumes/")
                && !message.contains("/private/var/")
                && !message.contains("/tmp/")
                && !message.contains(rootURL.path)
        }) else {
            throw DeviceSyncArtifactError.unreadableArtifact(
                "source-refresh message contains a private absolute path"
            )
        }
    }

    private func latestReceiptsByRequest(
        _ receipts: [DeviceSyncReceipt]
    ) -> [String: DeviceSyncReceipt] {
        var result: [String: DeviceSyncReceipt] = [:]
        for receipt in receipts {
            guard let requestID = receipt.requestID else { continue }
            if let existing = result[requestID],
               !DeviceSyncOperationIndex.isLater(receipt, than: existing)
            {
                continue
            }
            result[requestID] = receipt
        }
        return result
    }

    private func requestArtifact(
        requestID: String
    ) throws -> DeviceSyncRequestArtifact? {
        guard DeviceSyncReceipt.isSafeIdentifier(requestID) else {
            throw DeviceSyncArtifactError.unsafePath(requestID)
        }
        let requestsRoot = channelRootURL.appendingPathComponent(
            "requests",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: requestsRoot.path) else { return nil }
        let rootValues = try requestsRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw DeviceSyncArtifactError.notRegularFile(requestsRoot.lastPathComponent)
        }
        let targetDirectories = try FileManager.default.contentsOfDirectory(
            at: requestsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [DeviceSyncRequestArtifact] = []
        for targetDirectory in targetDirectories {
            let values = try targetDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            let target = targetDirectory.lastPathComponent
            guard DeviceSyncReceipt.isSafeIdentifier(target) else {
                throw DeviceSyncArtifactError.unsafePath(target)
            }
            let candidate = targetDirectory.appendingPathComponent(
                "\(requestID).json",
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let data = try readRegularFile(candidate)
            let request = try DeviceSyncOutboxJSON.decoder.decode(
                DeviceSyncRequestArtifact.self,
                from: data
            )
            guard request.target == target, request.requestID == requestID else {
                throw DeviceSyncArtifactError.unreadableArtifact(
                    candidate.lastPathComponent
                )
            }
            matches.append(request)
        }
        guard matches.count <= 1 else {
            throw DeviceSyncArtifactError.multipleRequestArtifacts(requestID)
        }
        return matches.first
    }

    static func projectTransactionState(
        journal: DeviceSyncSystemTransactionJournal,
        receipt: DeviceSyncReceipt?,
        evidence: DeviceSyncAttestationEvidence
    ) -> DeviceSyncTransactionProjectionState {
        if evidence.level == .targetLocallyAttested {
            return .targetLocallyAttested
        }
        if evidence.level == .unreadable {
            return .unreadable
        }
        if receipt?.effectivePhase == .diverged
            || journal.phase == "diverged"
            || journal.recoveryState == "diverged"
            || journal.ackState == "blocked"
        {
            return .diverged
        }
        if journal.phase == "rollbackPending"
            || journal.recoveryState == "rollbackPending"
        {
            return .rollbackPending
        }
        if journal.recoveryState == "recovering"
            || journal.recoveryState == "revalidating-committed"
        {
            return .recovering
        }
        switch journal.phase {
        case "preparing", "prepared", "osCandidatePreparing", "osCandidateReady":
            return .preparing
        case "oldMirrorMoveStarted", "oldMirrorBackedUp", "newMirrorInstallStarted",
             "osActive", "skilletActivating", "skilletActive":
            return .oldMirrorMoveStarted
        case "committed":
            return .committedAwaitingACK
        case "rolledBack":
            return .rolledBack
        default:
            return .unreadable
        }
    }

    static func defaultApplicationSupportRootPublic() -> URL {
        defaultApplicationSupportRoot()
    }

    private static func defaultApplicationSupportRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let canonicalOverride = environment["TATWO_ULTRAWORK_APP_SUPPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !canonicalOverride.isEmpty
        {
            return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
        }
        if let legacyOverride = environment["TATWO_APP_SUPPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyOverride.isEmpty
        {
            return URL(
                fileURLWithPath: legacyOverride,
                isDirectory: true
            ).standardizedFileURL
        }
        return TatwoRuntimeLayout.applicationSupportRoot(environment: environment)
    }
}
