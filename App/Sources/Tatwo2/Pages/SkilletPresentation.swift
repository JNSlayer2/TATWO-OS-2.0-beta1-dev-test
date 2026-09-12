// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/SkilletPresentation.swift；改動 2 行（原因：run A plugins 照搬；移除舊 core import，資料由同名 Facade 提供）
import Foundation
import SwiftUI

enum SkilletDetailTab: String, CaseIterable, Identifiable {
    case files = "Files"
    case history = "History"
    case merges = "Merges"
    case devices = "Devices"
    case receipts = "Receipts"

    var id: String { rawValue }
}

enum SkilletReconciliationState: String, Equatable, Sendable {
    case verified
    case missing
    case runtimeOnly = "runtime-only"
    case receiptMissing = "receipt-missing"
    case unreadable
}

struct SkilletFilePresentation: Identifiable, Equatable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    let byteCount: Int

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

struct SkilletRepositorySummary: Identifiable, Equatable, Sendable {
    var id: String { skill.id }

    let skill: TatwoSkillsDirectoryEntryV1
    let repository: TatwoCapabilityRepositoryV1
    let currentRevisionLabel: String
    let stableLabel: String
    let canaryLabel: String
    let healthLabel: String
    let syncLabel: String
    let receipts: [TatwoSkilletRepositoryReceiptV1]
    let mergeProposals: [TatwoMergeProposalV1]
    let mergeConflictsByProposal: [String: [TatwoSkilletMergeConflictArtifactV1]]
    let verifiedDeviceHeads: [TatwoDeviceHeadV1]
    let reconciliationState: SkilletReconciliationState
    let reconciliationDetail: String
    let runtimePresent: Bool

    var deviceCount: Int {
        verifiedDeviceHeads.count
    }

    var pendingMergeCount: Int {
        mergeProposals.filter { $0.status == .pending }.count
    }

    var isStaged: Bool {
        skill.isRegistered && repository.canonicalRevision != nil
    }

    var hasSnapshot: Bool {
        repository.canonicalRevision != nil
    }

    func matchingReceipt(
        for head: TatwoDeviceHeadV1
    ) -> TatwoSkilletRepositoryReceiptV1? {
        repository.matchingDeviceReceipt(for: head, receipts: receipts)
    }
}

struct SkilletRepositoryDetail: Equatable, Sendable {
    let revisionID: String?
    let files: [SkilletFilePresentation]
    var liveManifest: String? = nil
    var readError: String? = nil
}

enum SkilletRuntimeCatalogReconciler {
    static func reconcile(
        runtimeEntries: [TatwoSkillsDirectoryEntryV1],
        repositoryDisplayNames: [String: String]
    ) -> [String: TatwoSkillsDirectoryEntryV1] {
        var unmatchedRuntime = Dictionary(
            runtimeEntries
                .filter(\.hasManifest)
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var reconciled: [String: TatwoSkillsDirectoryEntryV1] = [:]

        for repositoryID in repositoryDisplayNames.keys.sorted() {
            if let exact = unmatchedRuntime.removeValue(forKey: repositoryID) {
                reconciled[repositoryID] = rebound(
                    exact,
                    repositoryID: repositoryID
                )
                continue
            }

            let expectedName = normalizedName(
                repositoryDisplayNames[repositoryID] ?? ""
            )
            guard !expectedName.isEmpty else { continue }
            let candidates = unmatchedRuntime.values.filter {
                normalizedName($0.name) == expectedName
            }
            guard candidates.count == 1, let matched = candidates.first else {
                continue
            }
            unmatchedRuntime.removeValue(forKey: matched.id)
            reconciled[repositoryID] = rebound(
                matched,
                repositoryID: repositoryID
            )
        }

        for entry in unmatchedRuntime.values {
            reconciled[entry.id] = entry
        }
        return reconciled
    }

    private static func rebound(
        _ entry: TatwoSkillsDirectoryEntryV1,
        repositoryID: String
    ) -> TatwoSkillsDirectoryEntryV1 {
        TatwoSkillsDirectoryEntryV1(
            id: repositoryID,
            name: entry.name,
            summary: entry.summary,
            path: entry.path,
            hasManifest: entry.hasManifest,
            isRegistered: entry.isRegistered,
            snapshotSourcePath: entry.snapshotSourcePath
        )
    }

    private static func normalizedName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}

enum SkilletPresentationBuilder {
    static func makeSummary(
        skill: TatwoSkillsDirectoryEntryV1,
        repository: TatwoCapabilityRepositoryV1?,
        receipts: [TatwoSkilletRepositoryReceiptV1] = [],
        mergeProposals: [TatwoMergeProposalV1] = [],
        mergeConflictsByProposal: [
            String: [TatwoSkilletMergeConflictArtifactV1]
        ] = [:],
        runtimePresent: Bool? = nil,
        unreadableReason: String? = nil
    ) -> SkilletRepositorySummary {
        let resolved = repository ?? emptyRepository(for: skill)
        let hasRuntime = runtimePresent ?? skill.hasManifest
        let verifiedHeads = resolved.verifiedDeviceHeads(receipts: receipts)
        let reconciliation = reconciliation(
            skill: skill,
            repository: repository,
            receipts: receipts,
            runtimePresent: hasRuntime,
            unreadableReason: unreadableReason
        )
        let currentRevisionLabel = resolved.canonicalRevision.map(shortRevision) ?? "尚未快照"
        let syncLabel: String
        switch reconciliation.state {
        case .verified:
            syncLabel = "\(verifiedHeads.count) 台設備有 canonical revision + device receipt"
        case .missing:
            syncLabel = "missing · repository 有 revision，但 runtime/canonical 不存在"
        case .runtimeOnly:
            syncLabel = "runtime-only · 尚未形成 Skillet revision"
        case .receiptMissing:
            syncLabel = "receipt-missing · device head 不足以算 verified"
        case .unreadable:
            syncLabel = "unreadable · repository/receipt fail-closed"
        }
        return SkilletRepositorySummary(
            skill: skill,
            repository: resolved,
            currentRevisionLabel: currentRevisionLabel,
            stableLabel: resolved.stableRevision.map(shortRevision) ?? "未發布",
            canaryLabel: resolved.canaryRevision.map(shortRevision) ?? "未發布",
            healthLabel: healthLabel(resolved.health),
            syncLabel: syncLabel,
            receipts: receipts,
            mergeProposals: mergeProposals,
            mergeConflictsByProposal: mergeConflictsByProposal,
            verifiedDeviceHeads: verifiedHeads,
            reconciliationState: reconciliation.state,
            reconciliationDetail: reconciliation.detail,
            runtimePresent: hasRuntime
        )
    }

    static func loadDetail(
        revisionID: String?,
        snapshotManifest: TatwoSkillSnapshotManifestV1?
    ) -> SkilletRepositoryDetail {
        SkilletRepositoryDetail(
            revisionID: revisionID,
            files: snapshotManifest?.files.map {
                SkilletFilePresentation(
                    relativePath: $0.relativePath,
                    byteCount: $0.byteCount
                )
            } ?? []
        )
    }

    static func loadRuntimeDetail(skill: TatwoSkillsDirectoryEntryV1) -> SkilletRepositoryDetail {
        guard skill.hasManifest, !skill.path.isEmpty else { return loadDetail(revisionID: nil, snapshotManifest: nil) }
        do {
            let data = try Data(contentsOf: skill.snapshotSourceURL.appendingPathComponent("SKILL.md"))
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            return .init(revisionID: nil, files: [.init(relativePath: "SKILL.md", byteCount: data.count)], liveManifest: text)
        } catch {
            return .init(revisionID: nil, files: [], readError: error.localizedDescription)
        }
    }

    static func healthLabel(_ health: TatwoCapabilityRepositoryHealthV1) -> String {
        switch health {
        case .healthy: "healthy"
        case .canary: "canary"
        case .diverged: "diverged"
        case .failed: "failed"
        case .unavailable: "unavailable"
        }
    }

    static func shortRevision(_ revision: String) -> String {
        String(revision.prefix(16))
    }

    private static func reconciliation(
        skill: TatwoSkillsDirectoryEntryV1,
        repository: TatwoCapabilityRepositoryV1?,
        receipts: [TatwoSkilletRepositoryReceiptV1],
        runtimePresent: Bool,
        unreadableReason: String?
    ) -> (state: SkilletReconciliationState, detail: String) {
        if let unreadableReason {
            return (.unreadable, unreadableReason)
        }
        guard let repository else {
            return runtimePresent
                ? (
                    .runtimeOnly,
                    "runtime \(skill.id) 可見，但 Skillet store 沒有可驗證 repository metadata。"
                )
                : (
                    .missing,
                    "canonical/runtime 與 Skillet repository 都不存在。"
                )
        }
        guard runtimePresent else {
            return (
                .missing,
                "Skillet store 有 \(repository.canonicalRevision ?? "no revision")，"
                    + "但 runtime/canonical directory 缺少。"
            )
        }
        guard repository.canonicalRevision != nil else {
            return (
                .runtimeOnly,
                "runtime 存在，但 repository 尚未建立 canonical revision。"
            )
        }

        let activeCanonicalHeads = repository.deviceHeads.filter {
            $0.activationState == .active
                && $0.revisionID == repository.canonicalRevision
        }
        let verifiedHeads = repository.verifiedDeviceHeads(receipts: receipts)
        guard !activeCanonicalHeads.isEmpty,
              verifiedHeads.count == activeCanonicalHeads.count
        else {
            return (
                .receiptMissing,
                "只有 active canonical head 且存在完全配對的 deviceHead receipt "
                    + "才會計入 verified device。"
            )
        }
        return (
            .verified,
            "\(verifiedHeads.count) 個 active canonical device heads 均有 request/epoch/sequence/digest/verifiedAt 配對 receipt。"
        )
    }

    private static func emptyRepository(
        for skill: TatwoSkillsDirectoryEntryV1
    ) -> TatwoCapabilityRepositoryV1 {
        TatwoCapabilityRepositoryV1(
            id: skill.id,
            displayName: skill.name,
            summary: skill.summary ?? "尚未提供 skill 摘要",
            canonicalRevision: nil,
            stableRevision: nil,
            canaryRevision: nil,
            revisions: [],
            deviceHeads: []
        )
    }
}

enum SkilletMergeDecisionKind: String, Equatable, Sendable {
    case approve
    case reject
}

struct SkilletMergeDecisionRequest: Identifiable, Equatable, Sendable {
    var id: String {
        "\(kind.rawValue)-\(repositoryID)-\(proposalID)"
    }

    let kind: SkilletMergeDecisionKind
    let repositoryID: String
    let proposalID: String
    let resolvedRevisionID: String?
}

struct SkilletMergeDecisionResult: Equatable, Sendable {
    let receipt: TatwoMergeDecisionReceiptV1
    let runtimeBefore: TatwoSkilletRuntimeReadbackV1
    let runtimeAfter: TatwoSkilletRuntimeReadbackV1

    var runtimeUnchanged: Bool {
        runtimeBefore == runtimeAfter
    }
}

enum SkilletMergeDecisionExecutor {
    static func execute(
        storeRoot: URL,
        runtimeRoot: URL,
        request: SkilletMergeDecisionRequest,
        decidedBy: String,
        decidedAt: Date = Date()
    ) throws -> SkilletMergeDecisionResult {
        let store = TatwoSkilletRepositoryStore(rootURL: storeRoot)
        let invariant = try TatwoSkilletBundleTransport
            .preservingRuntimeRepository(
                runtimeRoot: runtimeRoot,
                repositoryID: request.repositoryID
            ) {
                switch request.kind {
                case .approve:
                    return try store.approveMergeProposal(
                        repositoryID: request.repositoryID,
                        proposalID: request.proposalID,
                        resolvedRevisionID: request.resolvedRevisionID,
                        decidedBy: decidedBy,
                        decidedAt: decidedAt
                    )
                case .reject:
                    guard request.resolvedRevisionID == nil else {
                        throw TatwoSkilletRepositoryStoreError
                            .corruptedMergeProposal(request.proposalID)
                    }
                    return try store.rejectMergeProposal(
                        repositoryID: request.repositoryID,
                        proposalID: request.proposalID,
                        decidedBy: decidedBy,
                        decidedAt: decidedAt
                    )
                }
            }
        return SkilletMergeDecisionResult(
            receipt: invariant.result,
            runtimeBefore: invariant.before,
            runtimeAfter: invariant.after
        )
    }

    static func currentActor(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostName: String = ProcessInfo.processInfo.hostName
    ) -> String {
        let source = environment["TATWO_DEVICE_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? hostName
        let safe = source.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                Character(String(scalar))
            default:
                "-"
            }
        }
        let compact = String(safe)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return "human-\(compact.isEmpty ? "tatwo-app" : compact)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

struct SkilletRepositoryFacts: View {
    let summary: SkilletRepositorySummary

    private let columns = [
        GridItem(.adaptive(minimum: 116), spacing: 7, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
            fact(
                title: "Revision",
                value: summary.currentRevisionLabel,
                systemImage: "point.topleft.down.to.point.bottomright.curvepath"
            )
            fact(title: "Stable", value: summary.stableLabel, systemImage: "checkmark.seal")
            fact(title: "Canary", value: summary.canaryLabel, systemImage: "bird")
            fact(title: "Health", value: summary.healthLabel, systemImage: "heart.text.square")
            fact(
                title: "Devices",
                value: "\(summary.deviceCount) verified",
                systemImage: "laptopcomputer.and.iphone"
            )
            fact(
                title: "Reconcile",
                value: summary.reconciliationState.rawValue,
                systemImage: "arrow.triangle.branch"
            )
            fact(
                title: "Merge gates",
                value: "\(summary.pendingMergeCount) pending",
                systemImage: "arrow.triangle.merge"
            )
            fact(title: "Sync", value: summary.syncLabel, systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private func fact(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(
                    title == "Sync" || title == "Reconcile"
                        ? reconciliationTint
                        : .primary
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(
            Color.secondary.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var reconciliationTint: Color {
        switch summary.reconciliationState {
        case .verified:
            .green
        case .runtimeOnly, .receiptMissing:
            .orange
        case .missing, .unreadable:
            .red
        }
    }
}
