import Foundation
import TatwoDeploymentPrimitives
import TatwoModuleContracts

public final class TatwoUpdater: TatwoUpdateCommandPort, TatwoUpdateStatusSnapshotProvider {
    public static let checkInterval: TimeInterval = 6 * 60 * 60

    private let appcast: any TatwoSignedAppcastPort
    private let trustVerifier: any TatwoUpdateTrustVerificationPort
    private let downloader: any TatwoUpdateDownloadPort
    private let activation: any TatwoBundleActivationPort
    private let makeReceiptID: () -> String
    private let now: () -> Date
    private var lastCheckedAtByChannel: [TatwoUpdateChannelV1: Date] = [:]
    private var candidateByChannel: [TatwoUpdateChannelV1: TatwoSignedAppcastEntryV1] = [:]
    private var downloadedArtifactByChannel: [TatwoUpdateChannelV1: TatwoBundlePathV1] = [:]
    private var statusByChannel: [TatwoUpdateChannelV1: TatwoUpdateStatusV1] = [:]
    private var selectedChannel: TatwoUpdateChannelV1

    public init(
        channel: TatwoUpdateChannelV1,
        appcast: any TatwoSignedAppcastPort,
        trustVerifier: any TatwoUpdateTrustVerificationPort,
        downloader: any TatwoUpdateDownloadPort,
        activation: any TatwoBundleActivationPort,
        receiptID: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = Date.init
    ) {
        selectedChannel = channel
        self.appcast = appcast
        self.trustVerifier = trustVerifier
        self.downloader = downloader
        self.activation = activation
        self.makeReceiptID = receiptID
        self.now = now
        statusByChannel[channel] = .idle
    }

    public func check(_ request: TatwoUpdateCheckRequestV1) -> TatwoUpdateReceiptV1 {
        let observedAt = now()
        selectedChannel = request.channel
        if !request.force,
           let lastChecked = lastCheckedAtByChannel[request.channel],
           observedAt.timeIntervalSince(lastChecked) < Self.checkInterval
        {
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: statusByChannel[request.channel] ?? .idle,
                error: .checkThrottled,
                artifact: candidateByChannel[request.channel]?.artifact,
                observedAt: observedAt,
                detail: "Signed feed check is limited to once every six hours unless explicitly forced"
            )
        }
        lastCheckedAtByChannel[request.channel] = observedAt

        let entry: TatwoSignedAppcastEntryV1?
        do {
            entry = try appcast.latestEntry(for: request.channel)
        } catch {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .feedUnavailable,
                artifact: nil,
                observedAt: observedAt,
                detail: "Signed feed unavailable: \(error)"
            )
        }
        guard let entry else {
            candidateByChannel[request.channel] = nil
            statusByChannel[request.channel] = .noUpdate
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .noUpdate,
                error: .none,
                artifact: nil,
                observedAt: observedAt,
                detail: "No update is available"
            )
        }
        guard entry.feedChannel == request.channel,
              entry.artifact.channel == request.channel
        else {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .channelMismatch,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: "Feed and artifact channel must match the enrolled channel"
            )
        }

        let trust = trustVerifier.verify(entry)
        guard trust.feedSignatureValid else {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .untrustedFeed,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: trust.detail
            )
        }
        guard trust.schemaCompatible else {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .schemaIncompatible,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: trust.detail
            )
        }
        guard trust.protocolCompatible else {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .protocolIncompatible,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: trust.detail
            )
        }
        guard trust.isTrusted else {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .untrustedArtifact,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: trust.detail
            )
        }
        guard entry.artifact.version > request.currentVersion else {
            candidateByChannel[request.channel] = nil
            statusByChannel[request.channel] = .noUpdate
            return receipt(
                operation: .check,
                request: request.correlationID,
                channel: request.channel,
                status: .noUpdate,
                error: .none,
                artifact: entry.artifact,
                observedAt: observedAt,
                detail: "Signed artifact is not newer than the installed version"
            )
        }

        candidateByChannel[request.channel] = entry
        statusByChannel[request.channel] = .available
        return receipt(
            operation: .check,
            request: request.correlationID,
            channel: request.channel,
            status: .available,
            error: .none,
            artifact: entry.artifact,
            observedAt: observedAt,
            detail: "Trusted update is available"
        )
    }

    public func download(_ request: TatwoUpdateDownloadRequestV1) -> TatwoUpdateReceiptV1 {
        let observedAt = now()
        selectedChannel = request.channel
        guard let candidate = candidateByChannel[request.channel] else {
            return receipt(
                operation: .download,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .noVerifiedCandidate,
                artifact: nil,
                observedAt: observedAt,
                detail: "A trusted checked candidate is required before download"
            )
        }
        do {
            let downloaded = try downloader.download(
                artifact: candidate.artifact,
                to: request.destination
            )
            guard downloaded == request.destination,
                  downloaded.role == .sourceArtifact
            else {
                statusByChannel[request.channel] = .failed
                return receipt(
                    operation: .download,
                    request: request.correlationID,
                    channel: request.channel,
                    status: .failed,
                    error: .artifactMismatch,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    detail: "Downloader returned an unexpected artifact path or role"
                )
            }
            downloadedArtifactByChannel[request.channel] = downloaded
            statusByChannel[request.channel] = .downloaded
            return receipt(
                operation: .download,
                request: request.correlationID,
                channel: request.channel,
                status: .downloaded,
                error: .none,
                artifact: candidate.artifact,
                observedAt: observedAt,
                detail: "Artifact downloaded in background and awaits user-approved activation"
            )
        } catch {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .download,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .downloadFailed,
                artifact: candidate.artifact,
                observedAt: observedAt,
                detail: "Download failed: \(error)"
            )
        }
    }

    public func requestUserApprovedInstall(
        _ request: TatwoUserApprovedInstallRequestV1
    ) -> TatwoUpdateReceiptV1 {
        let observedAt = now()
        selectedChannel = request.channel
        guard request.userApproved else {
            statusByChannel[request.channel] = .awaitingApproval
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .awaitingApproval,
                error: .userApprovalRequired,
                artifact: candidateByChannel[request.channel]?.artifact,
                observedAt: observedAt,
                detail: "Activation requires explicit user approval"
            )
        }
        guard let candidate = candidateByChannel[request.channel],
              let downloaded = downloadedArtifactByChannel[request.channel]
        else {
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .noVerifiedCandidate,
                artifact: nil,
                observedAt: observedAt,
                detail: "A trusted downloaded candidate is required"
            )
        }
        guard request.activationPlan.stage.sourceBundle == downloaded,
              request.activationPlan.verify.expectedArtifactDigest
                == candidate.artifact.artifactSHA256
        else {
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .artifactMismatch,
                artifact: candidate.artifact,
                observedAt: observedAt,
                detail: "Activation plan does not match the verified downloaded artifact"
            )
        }

        var bundleReceipts: [TatwoBundleOperationReceiptV1] = []
        var rollbackRequired = false
        var postMutationError: TatwoUpdateErrorKindV1 = .activationFailed
        do {
            let stage = try activation.stage(request.activationPlan.stage)
            bundleReceipts.append(stage)
            guard stage.outcome == .succeeded else {
                return activationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    error: .stageFailed,
                    receipts: bundleReceipts,
                    detail: stage.detail
                )
            }

            let verification = try activation.verify(request.activationPlan.verify)
            bundleReceipts.append(verification)
            guard verification.outcome == .succeeded else {
                return activationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    error: .verificationFailed,
                    receipts: bundleReceipts,
                    detail: verification.detail
                )
            }

            let archive = try activation.archiveCurrent(request.activationPlan.archiveCurrent)
            bundleReceipts.append(archive)
            guard archive.outcome == .succeeded else {
                return activationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    error: .archiveFailed,
                    receipts: bundleReceipts,
                    detail: archive.detail
                )
            }

            rollbackRequired = true
            postMutationError = .activationFailed
            let swap = try activation.atomicSwap(request.activationPlan.atomicSwap)
            bundleReceipts.append(swap)
            guard swap.outcome == .succeeded else {
                return recoverAfterActivationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    originalError: .activationFailed,
                    receipts: bundleReceipts,
                    detail: swap.detail
                )
            }

            postMutationError = .healthCheckFailed
            let health = try activation.healthCheck(request.activationPlan.healthCheck)
            bundleReceipts.append(health)
            guard health.outcome == .succeeded else {
                return recoverAfterActivationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    originalError: .healthCheckFailed,
                    receipts: bundleReceipts,
                    detail: health.detail
                )
            }

            rollbackRequired = false
            statusByChannel[request.channel] = .installed
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .installed,
                error: .none,
                artifact: candidate.artifact,
                observedAt: observedAt,
                bundleReceipts: bundleReceipts,
                detail: "User-approved bundle activated and passed health check"
            )
        } catch {
            if rollbackRequired {
                return recoverAfterActivationFailure(
                    request: request,
                    artifact: candidate.artifact,
                    observedAt: observedAt,
                    originalError: postMutationError,
                    receipts: bundleReceipts,
                    detail: "Activation primitive threw after the bundle may have mutated: \(error)"
                )
            }
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .activationFailed,
                artifact: candidate.artifact,
                observedAt: observedAt,
                bundleReceipts: bundleReceipts,
                detail: "Activation failed: \(error)"
            )
        }
    }

    private func recoverAfterActivationFailure(
        request: TatwoUserApprovedInstallRequestV1,
        artifact: TatwoUpdateArtifactMetadataV1,
        observedAt: Date,
        originalError: TatwoUpdateErrorKindV1,
        receipts: [TatwoBundleOperationReceiptV1],
        detail: String
    ) -> TatwoUpdateReceiptV1 {
        var recoveredReceipts = receipts
        do {
            let rollback = try activation.rollbackBundle(request.activationPlan.rollbackBundle)
            recoveredReceipts.append(rollback)
            guard rollback.outcome == .succeeded else {
                statusByChannel[request.channel] = .failed
                return receipt(
                    operation: .requestUserApprovedInstall,
                    request: request.correlationID,
                    channel: request.channel,
                    status: .failed,
                    error: .rollbackFailed,
                    artifact: artifact,
                    observedAt: observedAt,
                    bundleReceipts: recoveredReceipts,
                    detail: "\(detail); bundle-only rollback reported failure: \(rollback.detail)"
                )
            }
            statusByChannel[request.channel] = .rolledBack
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .rolledBack,
                error: originalError,
                artifact: artifact,
                observedAt: observedAt,
                bundleReceipts: recoveredReceipts,
                detail: "\(detail); previous verified bundle restored"
            )
        } catch {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .requestUserApprovedInstall,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .rollbackFailed,
                artifact: artifact,
                observedAt: observedAt,
                bundleReceipts: recoveredReceipts,
                detail: "\(detail); bundle-only rollback threw: \(error)"
            )
        }
    }

    public func rollbackBundle(
        _ request: TatwoUpdateRollbackRequestV1
    ) -> TatwoUpdateReceiptV1 {
        let observedAt = now()
        selectedChannel = request.channel
        guard request.userApproved || request.automaticActivationHealthRecovery else {
            return receipt(
                operation: .rollbackBundle,
                request: request.correlationID,
                channel: request.channel,
                status: .awaitingApproval,
                error: .userApprovalRequired,
                artifact: candidateByChannel[request.channel]?.artifact,
                observedAt: observedAt,
                detail: "Rollback requires user approval unless it is immediate activation-health recovery"
            )
        }
        do {
            let rollback = try activation.rollbackBundle(request.rollbackRequest)
            statusByChannel[request.channel] =
                rollback.outcome == .succeeded ? .rolledBack : .failed
            return receipt(
                operation: .rollbackBundle,
                request: request.correlationID,
                channel: request.channel,
                status: rollback.outcome == .succeeded ? .rolledBack : .failed,
                error: rollback.outcome == .succeeded ? .none : .rollbackFailed,
                artifact: candidateByChannel[request.channel]?.artifact,
                observedAt: observedAt,
                bundleReceipts: [rollback],
                detail: rollback.detail
            )
        } catch {
            statusByChannel[request.channel] = .failed
            return receipt(
                operation: .rollbackBundle,
                request: request.correlationID,
                channel: request.channel,
                status: .failed,
                error: .rollbackFailed,
                artifact: candidateByChannel[request.channel]?.artifact,
                observedAt: observedAt,
                detail: "Bundle-only rollback failed: \(error)"
            )
        }
    }

    public func updateStatusSnapshot() -> TatwoUpdateStatusSnapshotV1 {
        TatwoUpdateStatusSnapshotV1(
            channel: selectedChannel,
            status: statusByChannel[selectedChannel] ?? .idle,
            lastCheckedAt: lastCheckedAtByChannel[selectedChannel],
            candidateVersion: candidateByChannel[selectedChannel]?.artifact.version
        )
    }

    private func activationFailure(
        request: TatwoUserApprovedInstallRequestV1,
        artifact: TatwoUpdateArtifactMetadataV1,
        observedAt: Date,
        error: TatwoUpdateErrorKindV1,
        receipts: [TatwoBundleOperationReceiptV1],
        detail: String
    ) -> TatwoUpdateReceiptV1 {
        statusByChannel[request.channel] = .failed
        return receipt(
            operation: .requestUserApprovedInstall,
            request: request.correlationID,
            channel: request.channel,
            status: .failed,
            error: error,
            artifact: artifact,
            observedAt: observedAt,
            bundleReceipts: receipts,
            detail: detail
        )
    }

    private func receipt(
        operation: TatwoUpdateOperationV1,
        request correlationID: String,
        channel: TatwoUpdateChannelV1,
        status: TatwoUpdateStatusV1,
        error: TatwoUpdateErrorKindV1,
        artifact: TatwoUpdateArtifactMetadataV1?,
        observedAt: Date,
        bundleReceipts: [TatwoBundleOperationReceiptV1] = [],
        detail: String
    ) -> TatwoUpdateReceiptV1 {
        TatwoUpdateReceiptV1(
            receiptID: makeReceiptID(),
            operation: operation,
            correlationID: correlationID,
            status: status,
            errorKind: error,
            observedAt: observedAt,
            channel: channel,
            artifact: artifact,
            bundleReceipts: bundleReceipts,
            detail: detail
        )
    }
}
