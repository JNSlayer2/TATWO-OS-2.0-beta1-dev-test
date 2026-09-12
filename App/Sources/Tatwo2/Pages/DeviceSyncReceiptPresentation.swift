// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncReceiptPresentation.swift；改動 43 行（原因：新增來源標頭；動態文字改用 verbatim 並明確指定 Color，以避開薄殼 target 的 SwiftUI 多載 type-check 超時；layout、字級、色值不變）
import SwiftUI

enum DeviceSyncPresentationState: Equatable {
    case pending
    case partial
    case unreadable
    case diverged
    case failed
    case converged
}

struct DeviceSyncItemPresentation: Identifiable, Equatable {
    let id: String
    let displayName: String
    let phaseLabel: String
    let digestLabel: String
    let message: String
    let isVerified: Bool
    let isSyntheticMissingItem: Bool
    let progressFraction: Double
    let percentLabel: String
    let progressProvenance: DeviceSyncProgressValue.Provenance
    let progressBasisLabel: String
    let progressDetailLabel: String?
    let repositories: [DeviceSyncRepositoryPresentation]
}

struct DeviceSyncRepositoryPresentation: Identifiable, Equatable {
    let id: String
    let repositoryID: String
    let revisionLabel: String
    let digestLabel: String
    let bindingLabel: String
    let isVerified: Bool
}

struct DeviceSyncConsumerReadbackPresentation: Identifiable, Equatable {
    let id: String
    let consumerID: String
    let consumerKind: String
    let sourceItemLabel: String
    let revisionLabel: String
    let digestLabel: String
    let runtimeLabel: String
    let isLoaded: Bool
}

struct DeviceSyncReceiptPresentation: Equatable {
    static let progressPhases: [DeviceSyncReceiptPhase] = [
        .queued,
        .delivered,
        .accepted,
        .transferring,
        .merging,
        .validating,
        .activating,
        .verified,
        .converged
    ]

    let receipt: DeviceSyncReceipt
    let artifactIssues: [DeviceSyncArtifactIssue]

    init(
        receipt: DeviceSyncReceipt,
        artifactIssues: [DeviceSyncArtifactIssue] = []
    ) {
        self.receipt = receipt
        self.artifactIssues = artifactIssues
    }

    var operationKey: DeviceSyncOperationKey {
        receipt.operationKey
    }

    var isLocalSourceRefreshAttempt: Bool {
        receipt.requestID == nil
            && receipt.sourceRefreshAttemptID != nil
            && receipt.attestationEvidence.provenance
                == DeviceSyncSourceRefreshAttempt.evidenceKind
    }

    var operationLabel: String {
        isLocalSourceRefreshAttempt
            ? "\(operationKey.displayName) · 本機來源刷新"
            : operationKey.displayName
    }

    var expectsIssueDocument: Bool {
        let normalizedAction = receipt.action.lowercased()
        return normalizedAction == "system-pull" && !isLocalSourceRefreshAttempt
    }

    var issueItem: DeviceSyncItemReceipt? {
        (receipt.items ?? []).first { item in
            item.id == "os.issue" || {
                let identity = "\(item.id) \(item.displayName)".lowercased()
                return identity.contains("issue.md") || identity.contains("issue-md")
            }()
        }
    }

    var hasVerifiedIssueDocument: Bool {
        !expectsIssueDocument
            || issueItem.map(receipt.isItemVerified) == true
    }

    var state: DeviceSyncPresentationState {
        if !artifactIssues.isEmpty || receipt.attestationEvidence.level == .unreadable {
            return .unreadable
        }
        if receipt.effectivePhase == .failed {
            return .failed
        }
        if receipt.effectivePhase == .diverged {
            return .diverged
        }
        if receipt.effectivePhase == .queued {
            return .pending
        }
        if expectsIssueDocument,
           !receipt.isCatalogCompatible,
           receipt.effectivePhase == .verified || receipt.effectivePhase == .converged
        {
            return .diverged
        }
        if expectsIssueDocument, !missingRequiredItemIDs.isEmpty {
            switch receipt.effectivePhase {
            case .verified, .converged:
                return .diverged
            default:
                return .partial
            }
        }
        if receipt.isConverged {
            return .converged
        }
        return receipt.effectivePhase == .queued ? .pending : .partial
    }

    var isConverged: Bool {
        artifactIssues.isEmpty
            && receipt.attestationEvidence.level != .unreadable
            && receipt.isConverged
            && hasVerifiedIssueDocument
    }

    var statusLabel: String {
        if !artifactIssues.isEmpty {
            return "unreadable · artifact fail-closed"
        }
        if isLocalSourceRefreshAttempt {
            switch receipt.effectivePhase {
            case .failed:
                return "本機 Skill 來源刷新失敗 · 未發布 request"
            case .validating:
                return receipt.result == "pending"
                    ? "本機正在刷新 Skill 來源 · 尚未發布 request"
                    : "本機 Skill 來源已刷新 · 尚未證明 request 發布"
            default:
                return "本機 Skill 來源刷新證據 · 不是 ACK"
            }
        }
        if receipt.attestationEvidence.level == .unreadable {
            return "unreadable · target attestation 驗證失敗"
        }
        if receipt.effectivePhase == .queued {
            return receipt.statusLabel
        }
        if expectsIssueDocument, !receipt.isCatalogCompatible {
            let expected = DeviceSyncCatalogProjection.currentRevision ?? "unavailable"
            let received = receipt.catalogRevision ?? "missing"
            if receipt.effectivePhase == .verified || receipt.effectivePhase == .converged {
                return "內容分岔 · catalog \(received) ≠ \(expected)"
            }
        }
        if expectsIssueDocument, !missingRequiredItemIDs.isEmpty {
            let missingNames = missingRequiredItemIDs.map {
                DeviceSyncCatalogProjection.systemPullItemNames[$0]
                    ?? DeviceSyncCatalogProjection.displayName(for: $0)
            }
            let suffix = missingNames.joined(separator: "、")
            if missingRequiredItemIDs == ["os.issue"] {
                return state == .diverged
                    ? "內容分岔 · issue.md 未驗證"
                    : "部分同步 · 缺少 issue.md"
            }
            return state == .diverged
                ? "內容分岔 · 缺少 \(suffix)"
                : "部分同步 · 缺少 \(suffix)"
        }
        if expectsIssueDocument,
           issueItem.map(receipt.isItemVerified) == false,
           receipt.effectivePhase == .verified || receipt.effectivePhase == .converged
        {
            return "內容分岔 · issue.md 未收斂"
        }
        if expectsIssueDocument,
           receipt.isChannelClaimed,
           !receipt.attestationEvidence.hasCompleteConsumerReadback
        {
            return "部分同步 · first broken phase consumer-readback"
        }
        return receipt.statusLabel
    }

    var firstBrokenPhaseLabel: String? {
        if !artifactIssues.isEmpty || receipt.attestationEvidence.level == .unreadable {
            return "artifact-readback"
        }
        if isLocalSourceRefreshAttempt, receipt.effectivePhase == .failed {
            return "source-refresh"
        }
        if expectsIssueDocument, !receipt.isCatalogCompatible {
            return "catalog-compatibility"
        }
        if !missingRequiredItemIDs.isEmpty {
            return "source-item-verification"
        }
        if expectsIssueDocument,
           receipt.isChannelClaimed,
           !receipt.attestationEvidence.hasCompleteConsumerReadback
        {
            return "consumer-readback"
        }
        if expectsIssueDocument,
           receipt.isChannelClaimed,
           receipt.attestationEvidence.level != .targetLocallyAttested
        {
            return "target-attestation"
        }
        if receipt.effectivePhase == .failed {
            return "failed"
        }
        if receipt.effectivePhase == .diverged {
            return "authority-or-content-diverged"
        }
        return nil
    }

    var progressFraction: Double {
        if state == .unreadable {
            return min(receipt.progressFraction, DeviceSyncReceiptPhase.diverged.progressFraction)
        }
        if state != .converged || !isConverged {
            return min(
                receipt.progressFraction,
                DeviceSyncReceiptPhase.verified.progressFraction
            )
        }
        return receipt.progressFraction
    }

    var percentLabel: String {
        "\(Int((progressFraction * 100).rounded()))%"
    }

    var progressBasisLabel: String {
        receipt.progress?.hasMeasuredProgress == true ? "實測" : "階段推估"
    }

    var progressDetailLabel: String? {
        Self.progressDetailLabel(for: receipt.progress)
    }

    var hasTrustedSourceProvenance: Bool {
        guard receipt.action.lowercased() == "system-pull",
              let authorityPrimary = receipt.authorityPrimary,
              let authorityEpoch = receipt.authorityEpoch
        else {
            return false
        }
        return DeviceSyncSourceProvenanceValidator.isValid(
            sourceMode: receipt.sourceMode,
            inventoryDigest: receipt.inventoryDigest,
            fallbackAuthorizationID: receipt.fallbackAuthorizationID,
            fallbackAuthorizationPath: receipt.fallbackAuthorizationPath,
            fallbackAuthorizationDigest: receipt.fallbackAuthorizationDigest,
            authorityPrimary: authorityPrimary,
            authorityEpoch: authorityEpoch
        )
    }

    var sourceProvenanceLabel: String? {
        guard receipt.action.lowercased() == "system-pull" else {
            return nil
        }
        if isLocalSourceRefreshAttempt {
            switch receipt.sourceMode {
            case DeviceSyncSourceProvenanceValidator.canonical:
                if DeviceSyncDigestValidator.isSHA256(receipt.inventoryDigest) {
                    return "local canonical source-refresh · inventory "
                        + Self.shortDigest(receipt.inventoryDigest ?? "")
                        + " · not ACK"
                }
                return "local canonical source-refresh · not ACK"
            case DeviceSyncSourceProvenanceValidator.runtimeFallback:
                return "local runtime-fallback source-refresh · not ACK"
            default:
                return "local source discovery · not published · not ACK"
            }
        }
        guard hasTrustedSourceProvenance else {
            return "source provenance missing or invalid"
        }
        let inventory = Self.shortDigest(receipt.inventoryDigest ?? "")
        switch receipt.sourceMode {
        case DeviceSyncSourceProvenanceValidator.canonical:
            return "canonical source · inventory \(inventory)"
        case DeviceSyncSourceProvenanceValidator.runtimeFallback:
            let authorizationID = String(
                (receipt.fallbackAuthorizationID ?? "").prefix(12)
            )
            let authorizationDigest = Self.shortDigest(
                receipt.fallbackAuthorizationDigest ?? ""
            )
            return "runtime fallback · explicitly authorized"
                + " · inventory \(inventory)"
                + " · authorization \(authorizationID)/\(authorizationDigest)"
        default:
            return "source provenance missing or invalid"
        }
    }

    var phaseLabel: String {
        Self.label(for: receipt.effectivePhase)
    }

    var syncItemEvidenceLabel: String? {
        let items = itemPresentations
        guard !items.isEmpty else { return nil }
        let verifiedCount = items.filter(\.isVerified).count
        let names = items.map(\.displayName).joined(separator: "、")
        return "同步項目 \(verifiedCount) / \(items.count)：\(names)"
    }

    var skilletEvidenceLabel: String? {
        guard let skilletItem = (receipt.items ?? []).first(where: {
            $0.id == "skills.skillet"
        }) else {
            return nil
        }
        let synchronizedCount = skilletItem.repositories?.count ?? 0
        let preservedCount = skilletItem.targetPreservedRepositories?.count ?? 0
        let readbackCount = receipt.attestationEvidence.consumerReadbacks.count
        return "Skillet：\(synchronizedCount) 同步 repositories"
            + " · \(preservedCount) 目標保留 repositories"
            + " · \(readbackCount) consumer readbacks"
    }

    var itemPresentations: [DeviceSyncItemPresentation] {
        if state == .pending {
            return []
        }
        var presentations = (receipt.items ?? []).map { item in
            let progress = item.progressValue
            let synchronizedRepositories =
                (item.repositories ?? []).enumerated().map { index, repository in
                    DeviceSyncRepositoryPresentation(
                        id: "synchronized::\(repository.repositoryID)"
                            + "::\(repository.revisionID)::\(index)",
                        repositoryID: repository.repositoryID,
                        revisionLabel: String(repository.revisionID.prefix(18)),
                        digestLabel: "content \(Self.shortDigest(repository.contentDigest))"
                            + " · bundle \(Self.shortDigest(repository.bundleDigest))",
                        bindingLabel: "epoch \(repository.authorityEpoch)"
                            + " · seq \(repository.ledgerSequence)"
                            + " · #\(String(repository.requestID.prefix(10)))",
                        isVerified: repository.isVerified(in: receipt)
                    )
                }
            let preservedRepositories =
                (item.targetPreservedRepositories ?? []).enumerated().map {
                    index,
                    repository in
                    DeviceSyncRepositoryPresentation(
                        id: "target-preserved::\(repository.repositoryID)"
                            + "::\(repository.revisionID)::\(index)",
                        repositoryID: repository.repositoryID,
                        revisionLabel: String(repository.revisionID.prefix(18)),
                        digestLabel: "content \(Self.shortDigest(repository.contentDigest))"
                            + " · runtime preserved",
                        bindingLabel: "target-preserved"
                            + " · \(repository.state)"
                            + " · \(repository.phase)",
                        isVerified: repository.isVerified
                    )
                }
            return DeviceSyncItemPresentation(
                id: item.id,
                displayName: item.displayName,
                phaseLabel: Self.label(for: item.phase),
                digestLabel: Self.digestLabel(
                    source: item.sourceDigest,
                    applied: item.appliedDigest
                ),
                message: item.message,
                isVerified: receipt.isItemVerified(item),
                isSyntheticMissingItem: false,
                progressFraction: progress.fraction,
                percentLabel: progress.percentLabel,
                progressProvenance: progress.provenance,
                progressBasisLabel: item.progress?.hasMeasuredProgress == true
                    ? "實測"
                    : "階段推估",
                progressDetailLabel: Self.progressDetailLabel(for: item.progress),
                repositories: synchronizedRepositories + preservedRepositories
            )
        }
        if expectsIssueDocument {
            for missingID in missingRequiredItemIDs {
                let displayName = DeviceSyncCatalogProjection.systemPullItemNames[missingID]
                    ?? DeviceSyncCatalogProjection.displayName(for: missingID)
                presentations.append(
                    DeviceSyncItemPresentation(
                        id: "required-\(missingID)",
                        displayName: displayName,
                        phaseLabel: state == .diverged ? "分岔" : "缺少",
                        digestLabel: "未收到 source/applied hash",
                        message: "目標設備沒有回傳 \(displayName) 的逐項驗證收據。",
                        isVerified: false,
                        isSyntheticMissingItem: true,
                        progressFraction: 0,
                        percentLabel: "0%",
                        progressProvenance: .synthetic,
                        progressBasisLabel: "階段推估",
                        progressDetailLabel: nil,
                        repositories: []
                    )
                )
            }
        }
        return presentations
    }

    var metadataLabel: String? {
        var segments: [String] = []
        if let authorityEpoch = receipt.authorityEpoch {
            segments.append("epoch \(authorityEpoch)")
        }
        if let ledgerSequence = receipt.ledgerSequence {
            segments.append("seq \(ledgerSequence)")
        }
        if let authorityPrimary = receipt.authorityPrimary, !authorityPrimary.isEmpty {
            segments.append("primary \(authorityPrimary)")
        }
        if let sourceDeviceID = receipt.sourceDeviceID, !sourceDeviceID.isEmpty,
           let targetDeviceID = receipt.targetDeviceID, !targetDeviceID.isEmpty
        {
            segments.append("\(shortIdentifier(sourceDeviceID)) → \(shortIdentifier(targetDeviceID))")
        }
        if let catalogRevision = receipt.catalogRevision, !catalogRevision.isEmpty {
            segments.append("catalog \(catalogRevision)")
        }
        if receipt.action.lowercased() == "system-pull",
           let expected = DeviceSyncCatalogProjection.currentRevision,
           expected != receipt.catalogRevision
        {
            segments.append("app expects \(expected)")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    var requestLabel: String? {
        if isLocalSourceRefreshAttempt,
           let attemptID = receipt.sourceRefreshAttemptID,
           !attemptID.isEmpty
        {
            return "local-\(String(attemptID.prefix(8)))"
        }
        guard let requestID = receipt.requestID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestID.isEmpty
        else {
            return nil
        }
        return String(requestID.prefix(12))
    }

    var attestationLabel: String {
        if isLocalSourceRefreshAttempt {
            return "local-source-refresh-attempt · not-request · not-ACK · "
                + "not-target-attestation"
        }
        let level: String
        switch receipt.attestationEvidence.level {
        case .none:
            level = "no-target-attestation"
        case .channelClaimed:
            level = "channel-claimed"
        case .targetLocallyAttested:
            level = "target-locally-attested"
        case .unreadable:
            level = "unreadable"
        }
        var segments = [
            level,
            "provenance \(receipt.attestationEvidence.provenance)",
        ]
        if let verifiedAt = receipt.attestationEvidence.attestedAt {
            segments.append(
                "verifiedAt "
                    + verifiedAt.formatted(date: .abbreviated, time: .standard)
            )
        }
        if !receipt.attestationEvidence.consumerReadbacks.isEmpty {
            segments.append(
                "consumers \(receipt.attestationEvidence.consumerReadbacks.count)"
            )
        }
        if let digest = receipt.attestationEvidence.consumerReadbackDigest {
            segments.append("consumer \(Self.shortDigest(digest))")
        }
        return segments.joined(separator: " · ")
    }

    var consumerReadbackPresentations: [DeviceSyncConsumerReadbackPresentation] {
        receipt.attestationEvidence.consumerReadbacks.map { readback in
            DeviceSyncConsumerReadbackPresentation(
                id: readback.id,
                consumerID: readback.consumerID,
                consumerKind: readback.consumerKind,
                sourceItemLabel: DeviceSyncCatalogProjection.displayName(
                    for: readback.sourceItemID
                ),
                revisionLabel: readback.loadedRevision,
                digestLabel: "\(Self.shortDigest(readback.expectedDigest))"
                    + (readback.expectedDigest == readback.loadedDigest ? " = loaded" : " ≠ loaded"),
                runtimeLabel: "\(readback.runtimeRef) · \(readback.loadedPath)",
                isLoaded: readback.isLoaded
            )
        }
    }

    var artifactIssueLabel: String? {
        guard !artifactIssues.isEmpty else { return nil }
        return artifactIssues
            .map { "\($0.fileName): \($0.message)" }
            .joined(separator: "\n")
    }

    static func label(for phase: DeviceSyncReceiptPhase) -> String {
        switch phase {
        case .queued: "排隊"
        case .delivered: "已送達"
        case .accepted: "已接收"
        case .transferring: "傳輸"
        case .merging: "合併"
        case .validating: "驗證"
        case .activating: "啟用"
        case .verified: "已驗證"
        case .converged: "已收斂"
        case .failed: "失敗"
        case .diverged: "分岔"
        }
    }

    private static func digestLabel(source: String?, applied: String?) -> String {
        guard let source, !source.isEmpty else {
            return "尚無 source hash"
        }
        guard let applied, !applied.isEmpty else {
            return "source \(shortDigest(source)) · 尚未套用"
        }
        if source == applied {
            return "\(shortDigest(source)) = \(shortDigest(applied))"
        }
        return "\(shortDigest(source)) ≠ \(shortDigest(applied))"
    }

    private static func shortDigest(_ digest: String) -> String {
        String(digest.prefix(10))
    }

    private static func progressDetailLabel(
        for payload: DeviceSyncProgressPayload?
    ) -> String? {
        guard let payload else { return nil }
        var segments: [String] = []
        if let currentItem = payload.currentItem?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !currentItem.isEmpty
        {
            segments.append(currentItem)
        }
        if let completed = payload.completedBytes,
           let total = payload.totalBytes,
           completed >= 0,
           total > 0,
           completed <= total
        {
            segments.append(
                "\(byteCountLabel(completed)) / \(byteCountLabel(total))"
            )
        }
        if let completed = payload.completedItems,
           let total = payload.totalItems,
           completed >= 0,
           total > 0,
           completed <= total
        {
            segments.append("\(completed) / \(total) 項")
        }
        if let completed = payload.completedRepositories,
           let total = payload.totalRepositories,
           completed >= 0,
           total >= 0,
           completed <= total
        {
            segments.append("\(completed) / \(total) repositories")
        }
        if let elapsed = payload.elapsedMilliseconds, elapsed >= 0 {
            segments.append(
                String(format: "%.1f 秒", Double(elapsed) / 1_000)
            )
        }
        if let throughput = payload.throughputBytesPerSecond,
           throughput >= 0,
           throughput.isFinite
        {
            segments.append("\(byteCountLabel(Int64(throughput.rounded())))/s")
        }
        return segments.isEmpty ? nil : segments.joined(separator: " · ")
    }

    private static func byteCountLabel(_ byteCount: Int64) -> String {
        guard byteCount >= 1_024 else {
            return "\(byteCount) bytes"
        }
        let kilobytes = Double(byteCount) / 1_024
        if kilobytes.rounded() == kilobytes {
            return "\(Int(kilobytes)) KB"
        }
        return String(format: "%.1f KB", kilobytes)
    }

    private var missingRequiredItemIDs: [String] {
        let itemsByID = Dictionary(
            (receipt.items ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return receipt.effectiveRequiredItemIDs.filter {
            guard let item = itemsByID[$0] else { return true }
            return !receipt.isItemVerified(item)
        }
    }

    private func shortIdentifier(_ identifier: String) -> String {
        String(identifier.prefix(8))
    }
}

struct DeviceSyncReceiptProgressView: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let presentation: DeviceSyncReceiptPresentation
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(verbatim: presentation.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                if let requestLabel = presentation.requestLabel {
                    Text("#\(requestLabel)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: presentation.percentLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint)
                Text(verbatim: presentation.progressBasisLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        presentation.progressBasisLabel == "實測"
                            ? Color.secondary
                            : Color.orange
                    )
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isExpanded ? "收合逐項同步收據" : "展開逐項同步收據")
            }

            segmentedProgress
            if let progressDetailLabel = presentation.progressDetailLabel {
                Text(verbatim: progressDetailLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let syncItemEvidenceLabel = presentation.syncItemEvidenceLabel {
                Text(verbatim: syncItemEvidenceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let skilletEvidenceLabel = presentation.skilletEvidenceLabel {
                Text(verbatim: skilletEvidenceLabel)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sourceProvenanceLabel = presentation.sourceProvenanceLabel {
                Text(verbatim: sourceProvenanceLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(
                        presentation.hasTrustedSourceProvenance
                            ? Color.secondary
                            : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(presentation.itemPresentations) { item in
                        itemRow(item)
                    }
                    if presentation.itemPresentations.isEmpty {
                        Text("尚未收到逐項 receipt；不能判定資料已收斂。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let firstBrokenPhase = presentation.firstBrokenPhaseLabel {
                        Label(
                            "first broken phase · \(firstBrokenPhase)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.orange)
                    }
                    ForEach(presentation.consumerReadbackPresentations) { consumer in
                        consumerReadbackRow(consumer)
                    }
                    if presentation.receipt.action.lowercased() == "system-pull",
                       !presentation.isLocalSourceRefreshAttempt,
                       presentation.consumerReadbackPresentations.isEmpty
                    {
                        Text("actual consumers 尚未回報 loaded digest / revision；不得顯示已收斂。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: presentation.receipt.message)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let metadataLabel = presentation.metadataLabel {
                        Text(verbatim: metadataLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Text(verbatim: presentation.attestationLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(
                            presentation.receipt.attestationEvidence.level
                                == .targetLocallyAttested
                                && !presentation.isLocalSourceRefreshAttempt
                                ? Color.green : Color.orange
                        )
                        .textSelection(.enabled)
                    Text(verbatim: presentation.receipt.attestationEvidence.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let artifactIssueLabel = presentation.artifactIssueLabel {
                        Text(verbatim: artifactIssueLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(9)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        }
    }

    private var segmentedProgress: some View {
        HStack(spacing: 3) {
            ForEach(Array(DeviceSyncReceiptPresentation.progressPhases.enumerated()), id: \.offset) {
                index,
                phase in
                let threshold = Double(index + 1)
                    / Double(DeviceSyncReceiptPresentation.progressPhases.count)
                Capsule()
                    .fill(
                        presentation.progressFraction + 0.0001 >= threshold
                            ? tint
                            : Color.secondary.opacity(0.16)
                    )
                    .frame(height: 5)
                    .help(DeviceSyncReceiptPresentation.label(for: phase))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("同步進度")
        .accessibilityValue("\(presentation.statusLabel)，\(presentation.percentLabel)")
    }

    private func itemRow(_ item: DeviceSyncItemPresentation) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: item.isVerified
                    ? "checkmark.circle.fill"
                    : (item.isSyntheticMissingItem ? "exclamationmark.triangle.fill" : "clock")
            )
            .font(.caption)
            .foregroundStyle(item.isVerified ? Color.green : Color.orange)
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.caption2.weight(.semibold))
                    Text(item.phaseLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(item.isVerified ? .green : .secondary)
                    Spacer(minLength: 4)
                    Text(item.percentLabel)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(item.isVerified ? Color.green : Color.orange)
                    Text(item.progressBasisLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            item.progressBasisLabel == "實測"
                                ? Color.secondary
                                : Color.orange
                        )
                }
                ProgressView(value: item.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(item.isVerified ? Color.green : Color.orange)
                    .accessibilityLabel("\(item.displayName) 同步進度")
                    .accessibilityValue("\(item.percentLabel)，\(item.progressBasisLabel)")
                if let progressDetailLabel = item.progressDetailLabel {
                    Text(verbatim: progressDetailLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(item.digestLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.repositories) { repository in
                    HStack(alignment: .top, spacing: 6) {
                        Image(
                            systemName: repository.isVerified
                                ? "checkmark.seal.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(repository.isVerified ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repository.repositoryID)
                                .font(.caption2.monospaced().weight(.semibold))
                            Text(repository.revisionLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(repository.digestLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(repository.bindingLabel)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            Spacer(minLength: 4)
        }
    }

    private func consumerReadbackRow(
        _ consumer: DeviceSyncConsumerReadbackPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: consumer.isLoaded
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(consumer.isLoaded ? Color.green : Color.orange)
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(consumer.consumerID)
                        .font(.caption2.weight(.semibold))
                    Text(consumer.sourceItemLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(consumer.isLoaded ? "loaded" : "blocked")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(consumer.isLoaded ? Color.green : Color.orange)
                }
                Text("\(consumer.consumerKind) · \(consumer.revisionLabel)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(consumer.digestLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(consumer.runtimeLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch presentation.state {
        case .converged:
            // Green is reserved for a real isConverged receipt with required issue.md verification.
            return presentation.isConverged ? Color.green : Color.orange
        case .failed:
            return .red
        case .unreadable:
            return .red
        case .diverged:
            return .red
        case .partial:
            return .orange
        case .pending:
            return LiquidGlassTokens.brandAccent
        }
    }
}
