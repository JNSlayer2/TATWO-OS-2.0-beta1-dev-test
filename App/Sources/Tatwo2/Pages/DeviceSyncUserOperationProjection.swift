// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceSyncUserOperationProjection.swift；改動 1 行（原因：只新增來源標頭）
import Foundation

enum DeviceSyncUserStage: Int, CaseIterable, Comparable, Sendable {
    case preparing
    case comparing
    case transferring
    case activating
    case verifying
    case completed

    static func < (lhs: DeviceSyncUserStage, rhs: DeviceSyncUserStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .preparing: "準備"
        case .comparing: "比對"
        case .transferring: "傳輸"
        case .activating: "安裝／啟用"
        case .verifying: "目標驗證"
        case .completed: "完成"
        }
    }
}

enum DeviceSyncUserOutcome: Equatable, Sendable {
    case active
    case completed
    case attention
    case failed
}

struct DeviceSyncMeasuredTransferProgress: Equatable, Sendable {
    let fraction: Double
    let percentLabel: String
    let detailLabel: String
}

struct DeviceSyncUserOperationProjection: Equatable, Identifiable {
    var id: String { target }

    let target: String
    let operationKeys: [DeviceSyncOperationKey]
    let presentations: [DeviceSyncReceiptPresentation]
    let transactions: [DeviceSyncTransactionProjection]
    let artifactIssues: [DeviceSyncArtifactIssue]
    let stage: DeviceSyncUserStage
    let outcome: DeviceSyncUserOutcome
    let statusLabel: String
    let measuredTransferProgress: DeviceSyncMeasuredTransferProgress?
    let updatedAt: Date?

    var operationLabel: String {
        let labels = operationKeys.map(\.displayName)
        switch labels.count {
        case 0:
            return "設備同步"
        case 1:
            return labels[0]
        default:
            return labels.joined(separator: "＋")
        }
    }
}

enum DeviceSyncUserOperationReducer {
    static func project(
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt] = [:],
        transactions: [DeviceSyncTransactionProjection] = [],
        artifactIssues: [DeviceSyncArtifactIssue] = []
    ) -> [DeviceSyncUserOperationProjection] {
        let latestTransactions = latestTransactionsByOperationKey(transactions)
        let knownRequestIDs = Set(
            receipts.values.compactMap(\.requestID)
                + latestTransactions.values.map(\.journal.requestID)
        )
        let targets = Set(
            DeviceSyncOperationIndex.targetNames(
                pending: pending,
                receipts: receipts,
                sourceRefreshAttempts: sourceRefreshAttempts
            )
            + latestTransactions.keys.map(\.target)
        )

        return targets.sorted().compactMap { target in
            projection(
                for: target,
                pending: pending,
                receipts: receipts,
                sourceRefreshAttempts: sourceRefreshAttempts,
                latestTransactions: latestTransactions,
                knownRequestIDs: knownRequestIDs,
                artifactIssues: artifactIssues
            )
        }
    }

    private static func projection(
        for target: String,
        pending: [DeviceSyncOperationKey: DeviceSyncIntent],
        receipts: [DeviceSyncOperationKey: DeviceSyncReceipt],
        sourceRefreshAttempts:
            [DeviceSyncOperationKey: DeviceSyncSourceRefreshAttempt],
        latestTransactions:
            [DeviceSyncOperationKey: DeviceSyncTransactionProjection],
        knownRequestIDs: Set<String>,
        artifactIssues: [DeviceSyncArtifactIssue]
    ) -> DeviceSyncUserOperationProjection? {
        let indexedKeys = DeviceSyncOperationIndex.operationKeys(
            for: target,
            pending: pending,
            receipts: receipts,
            sourceRefreshAttempts: sourceRefreshAttempts
        )
        let transactionKeys = latestTransactions.keys.filter { $0.target == target }
        let keys = Set(indexedKeys)
            .union(transactionKeys)
            .sorted { $0.action < $1.action }
        guard !keys.isEmpty else { return nil }

        var presentations: [DeviceSyncReceiptPresentation] = []
        var relevantTransactions: [DeviceSyncTransactionProjection] = []
        var relevantArtifactIssues: [DeviceSyncArtifactIssue] = []
        var stageByKey: [DeviceSyncOperationKey: DeviceSyncUserStage] = [:]
        var completionByKey: [DeviceSyncOperationKey: Bool] = [:]

        for key in keys {
            let receipt = DeviceSyncOperationIndex.presentationReceipt(
                for: key,
                pending: pending,
                receipts: receipts,
                sourceRefreshAttempts: sourceRefreshAttempts
            )
            let rawTransaction = latestTransactions[key]
            let requestIDs = Set(
                [
                    receipt?.requestID,
                    rawTransaction?.journal.requestID,
                ].compactMap { $0 }
            )
            let keyArtifactIssues = artifactIssues.filter {
                artifactIssue(
                    $0,
                    appliesTo: key,
                    requestIDs: requestIDs,
                    knownRequestIDs: knownRequestIDs
                )
            }
            for issue in keyArtifactIssues where
                !relevantArtifactIssues.contains(where: { $0.id == issue.id })
            {
                relevantArtifactIssues.append(issue)
            }
            let presentation = receipt.map {
                DeviceSyncReceiptPresentation(
                    receipt: $0,
                    artifactIssues: keyArtifactIssues
                )
            }
            if let presentation {
                presentations.append(presentation)
            }

            let transaction = relevantTransaction(
                rawTransaction,
                for: presentation
            )
            if let transaction {
                relevantTransactions.append(transaction)
            }

            let evidenceStages = [
                presentation.map(stage(for:)),
                transaction.map(stage(for:)),
            ].compactMap { $0 }
            stageByKey[key] = evidenceStages.max() ?? .preparing
            completionByKey[key] =
                pending[key] == nil
                && (
                    presentation?.isConverged == true
                        || transaction?.state == .targetLocallyAttested
                )
        }

        let outcome = outcome(
            presentations: presentations,
            transactions: relevantTransactions,
            artifactIssues: relevantArtifactIssues,
            allKeysCompleted: completionByKey.values.allSatisfy { $0 }
        )
        let stage: DeviceSyncUserStage
        if outcome == .completed {
            stage = .completed
        } else {
            let incompleteStages = keys.compactMap { key -> DeviceSyncUserStage? in
                completionByKey[key] == true ? nil : stageByKey[key]
            }
            let derivedStage =
                incompleteStages.min() ?? stageByKey.values.max() ?? .preparing
            switch outcome {
            case .completed:
                stage = .completed
            case .attention:
                let hasDivergenceOrPendingRollback =
                    presentations.contains(where: { $0.state == .diverged })
                    || relevantTransactions.contains(where: {
                        $0.state == .diverged || $0.state == .rollbackPending
                    })
                let maximumAttentionStage: DeviceSyncUserStage =
                    hasDivergenceOrPendingRollback ? .verifying : .activating
                stage = min(derivedStage, maximumAttentionStage)
            case .failed:
                stage = min(derivedStage, .verifying)
            case .active:
                stage = derivedStage
            }
        }

        let measuredProgress = measuredTransferProgress(
            presentations: presentations,
            stage: stage
        )
        let updatedAt = (
            presentations.map(\.receipt.completedAt)
                + relevantTransactions.map(\.journal.updatedAt)
        ).max()

        return DeviceSyncUserOperationProjection(
            target: target,
            operationKeys: keys,
            presentations: presentations.sorted {
                $0.operationKey.action < $1.operationKey.action
            },
            transactions: relevantTransactions.sorted {
                $0.action < $1.action
            },
            artifactIssues: relevantArtifactIssues,
            stage: stage,
            outcome: outcome,
            statusLabel: statusLabel(
                outcome: outcome,
                stage: stage,
                presentations: presentations,
                transactions: relevantTransactions,
                hasArtifactIssues: !relevantArtifactIssues.isEmpty
            ),
            measuredTransferProgress: measuredProgress,
            updatedAt: updatedAt
        )
    }

    private static func artifactIssue(
        _ issue: DeviceSyncArtifactIssue,
        appliesTo key: DeviceSyncOperationKey,
        requestIDs: Set<String>,
        knownRequestIDs: Set<String>
    ) -> Bool {
        guard case .verifiedBinding(
            let target,
            let action,
            let requestID
        ) = issue.scope else {
            return true
        }

        if let target, target != key.target {
            return false
        }
        if let action, action != key.action {
            return false
        }

        // A verified target/action binding is already sufficient to scope the
        // failure. A request mismatch must not hide a newer unreadable
        // artifact behind an older completed request for the same operation.
        if target != nil || action != nil {
            return true
        }

        if let requestID {
            // Scope request-only evidence only when that request is present in
            // the readable index. An unknown request cannot safely be assigned
            // elsewhere, so it remains global/fail-closed.
            return knownRequestIDs.contains(requestID)
                ? requestIDs.contains(requestID)
                : true
        }
        return true
    }

    private static func latestTransactionsByOperationKey(
        _ transactions: [DeviceSyncTransactionProjection]
    ) -> [DeviceSyncOperationKey: DeviceSyncTransactionProjection] {
        var result: [DeviceSyncOperationKey: DeviceSyncTransactionProjection] = [:]
        for transaction in transactions {
            let key = DeviceSyncOperationKey(
                target: transaction.target,
                action: transaction.action
            )
            guard let current = result[key] else {
                result[key] = transaction
                continue
            }
            if isLater(transaction, than: current) {
                result[key] = transaction
            }
        }
        return result
    }

    private static func isLater(
        _ lhs: DeviceSyncTransactionProjection,
        than rhs: DeviceSyncTransactionProjection
    ) -> Bool {
        if lhs.journal.authorityEpoch != rhs.journal.authorityEpoch {
            return lhs.journal.authorityEpoch > rhs.journal.authorityEpoch
        }
        if lhs.journal.ledgerSequence != rhs.journal.ledgerSequence {
            return lhs.journal.ledgerSequence > rhs.journal.ledgerSequence
        }
        return lhs.journal.requestID > rhs.journal.requestID
    }

    private static func relevantTransaction(
        _ transaction: DeviceSyncTransactionProjection?,
        for presentation: DeviceSyncReceiptPresentation?
    ) -> DeviceSyncTransactionProjection? {
        guard let transaction else { return nil }
        guard let presentation else { return transaction }

        let receipt = presentation.receipt
        guard let requestID = receipt.requestID else {
            // A new local pending intent or source-refresh attempt invalidates
            // an older transaction. Do not let stale installation state paint
            // the new user operation as complete.
            return nil
        }
        if transaction.journal.requestID == requestID {
            return transaction
        }

        let receiptEpoch = receipt.authorityEpoch ?? Int.min
        if transaction.journal.authorityEpoch != receiptEpoch {
            return transaction.journal.authorityEpoch > receiptEpoch
                ? transaction
                : nil
        }
        let receiptSequence = receipt.ledgerSequence ?? Int.min
        if transaction.journal.ledgerSequence != receiptSequence {
            return transaction.journal.ledgerSequence > receiptSequence
                ? transaction
                : nil
        }
        return transaction.journal.requestID > requestID ? transaction : nil
    }

    private static func stage(
        for presentation: DeviceSyncReceiptPresentation
    ) -> DeviceSyncUserStage {
        switch presentation.receipt.effectivePhase {
        case .queued:
            return .preparing
        case .delivered, .accepted:
            return .comparing
        case .transferring:
            return .transferring
        case .merging, .activating:
            return .activating
        case .validating, .verified:
            return .verifying
        case .converged:
            return presentation.isConverged ? .completed : .verifying
        case .failed, .diverged:
            return .verifying
        }
    }

    private static func stage(
        for transaction: DeviceSyncTransactionProjection
    ) -> DeviceSyncUserStage {
        switch transaction.state {
        case .preparing:
            return .preparing
        case .oldMirrorMoveStarted:
            return .activating
        case .committedAwaitingACK, .recovering, .rollbackPending,
             .diverged, .unreadable:
            return .verifying
        case .rolledBack:
            return .activating
        case .targetLocallyAttested:
            return .completed
        }
    }

    private static func outcome(
        presentations: [DeviceSyncReceiptPresentation],
        transactions: [DeviceSyncTransactionProjection],
        artifactIssues: [DeviceSyncArtifactIssue],
        allKeysCompleted: Bool
    ) -> DeviceSyncUserOutcome {
        if !artifactIssues.isEmpty
            || presentations.contains(where: {
                $0.state == .unreadable || $0.state == .failed
            })
            || transactions.contains(where: { $0.state == .unreadable })
        {
            return .failed
        }
        if presentations.contains(where: { $0.state == .diverged })
            || transactions.contains(where: {
                $0.state == .diverged
                    || $0.state == .rollbackPending
                    || $0.state == .rolledBack
            })
        {
            return .attention
        }
        return allKeysCompleted ? .completed : .active
    }

    private static func statusLabel(
        outcome: DeviceSyncUserOutcome,
        stage: DeviceSyncUserStage,
        presentations: [DeviceSyncReceiptPresentation],
        transactions: [DeviceSyncTransactionProjection],
        hasArtifactIssues: Bool
    ) -> String {
        if hasArtifactIssues
            || presentations.contains(where: { $0.state == .unreadable })
            || transactions.contains(where: { $0.state == .unreadable })
        {
            return "同步證據讀取失敗，已停止顯示成功"
        }
        if presentations.contains(where: { $0.state == .failed }) {
            return "同步失敗，尚未完成"
        }
        if presentations.contains(where: { $0.state == .diverged })
            || transactions.contains(where: { $0.state == .diverged })
        {
            return "同步內容有衝突，尚未完成"
        }
        if transactions.contains(where: { $0.state == .rollbackPending }) {
            return "同步異常，正在回復前一版"
        }
        if transactions.contains(where: { $0.state == .rolledBack }) {
            return "同步未完成，已回復前一版"
        }
        if outcome == .completed {
            return "已同步，目標設備已驗證"
        }
        switch stage {
        case .preparing: return "正在準備同步"
        case .comparing: return "正在比對內容"
        case .transferring: return "正在傳輸"
        case .activating: return "正在安裝／啟用"
        case .verifying: return "等待目標設備驗證"
        case .completed: return "已完成"
        }
    }

    private static func measuredTransferProgress(
        presentations: [DeviceSyncReceiptPresentation],
        stage: DeviceSyncUserStage
    ) -> DeviceSyncMeasuredTransferProgress? {
        guard stage == .transferring else { return nil }

        var bytesByReceipt: [MeasuredTransferReceiptIdentity: MeasuredTransferBytes] = [:]
        var conflictingReceiptIdentities: Set<MeasuredTransferReceiptIdentity> = []

        for presentation in presentations {
            let receipt = presentation.receipt
            guard let identity = measuredTransferIdentity(for: receipt),
                  let completed = receipt.progress?.completedBytes,
                  let total = receipt.progress?.totalBytes,
                  completed >= 0,
                  total > 0,
                  completed <= total
            else {
                continue
            }

            let bytes = MeasuredTransferBytes(completed: completed, total: total)
            guard !conflictingReceiptIdentities.contains(identity) else {
                continue
            }
            if let existing = bytesByReceipt[identity] {
                guard existing != bytes else {
                    // The same durable receipt may be observed through more
                    // than one action/index path. Count its measured payload
                    // once, not once per presentation.
                    continue
                }
                // One receipt identity cannot truthfully report two byte
                // measurements. Exclude the conflicting identity entirely.
                bytesByReceipt.removeValue(forKey: identity)
                conflictingReceiptIdentities.insert(identity)
                continue
            }
            bytesByReceipt[identity] = bytes
        }

        guard !bytesByReceipt.isEmpty else { return nil }
        var completed: Int64 = 0
        var total: Int64 = 0
        for bytes in bytesByReceipt.values {
            let completedSum = completed.addingReportingOverflow(bytes.completed)
            let totalSum = total.addingReportingOverflow(bytes.total)
            guard !completedSum.overflow, !totalSum.overflow else {
                return nil
            }
            completed = completedSum.partialValue
            total = totalSum.partialValue
        }

        let fraction = Double(completed) / Double(total)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return DeviceSyncMeasuredTransferProgress(
            fraction: fraction,
            percentLabel: "\(Int((fraction * 100).rounded()))%",
            detailLabel: "\(formatter.string(fromByteCount: completed)) / "
                + formatter.string(fromByteCount: total)
        )
    }

    private static func measuredTransferIdentity(
        for receipt: DeviceSyncReceipt
    ) -> MeasuredTransferReceiptIdentity? {
        guard let requestIdentity =
            receipt.requestID ?? receipt.sourceRefreshAttemptID,
            DeviceSyncReceipt.isSafeIdentifier(requestIdentity)
        else {
            return nil
        }
        // Match the durable authority tuple used by latest-receipt ordering.
        // Action and wall-clock metadata are not independent receipt identity.
        return MeasuredTransferReceiptIdentity(
            authorityEpoch: receipt.authorityEpoch,
            ledgerSequence: receipt.ledgerSequence,
            requestIdentity: requestIdentity
        )
    }

    private struct MeasuredTransferReceiptIdentity: Hashable {
        let authorityEpoch: Int?
        let ledgerSequence: Int?
        let requestIdentity: String
    }

    private struct MeasuredTransferBytes: Equatable {
        let completed: Int64
        let total: Int64
    }
}
