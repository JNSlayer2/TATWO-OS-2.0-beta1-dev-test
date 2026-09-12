import Foundation
import TatwoUltraworkCore

enum TatwoQuotaRefreshKind: Sendable {
    case automatic
    case manual
}

struct TatwoQuotaProviderLoadResult: Sendable {
    let row: LiveQuotaDisplay
    let isSuccessful: Bool
    let isRateLimited: Bool
}

protocol TatwoQuotaProviderLoading: Sendable {
    func load(
        provider: UsageProviderStatus,
        allowExternalAccess: Bool
    ) async -> TatwoQuotaProviderLoadResult
}

struct TatwoLiveQuotaProviderLoader: TatwoQuotaProviderLoading {
    func load(
        provider: UsageProviderStatus,
        allowExternalAccess: Bool
    ) async -> TatwoQuotaProviderLoadResult {
        switch provider.id {
        case "codex-gpt":
            let recorder = CodexQuotaSnapshotRecorder()
            let row = await TatwoLiveQuotaReader.loadCodex(
                provider: provider,
                allowExternalAccess: allowExternalAccess,
                accountSnapshotReader: {
                    await recorder.read()
                })
                ?? .unverified(provider)
            let accountSnapshot = await recorder.snapshot
            return TatwoQuotaProviderLoadResult(
                row: row,
                isSuccessful: row.hasLiveUsage
                    || accountSnapshot?.rateLimitFailure == nil,
                isRateLimited:
                    accountSnapshot?.rateLimitFailure == .rateLimited)
        case "claude":
            let recorder = ClaudeQuotaUsageRecorder()
            let row = await TatwoLiveQuotaReader.loadClaude(
                provider: provider,
                usageClient: recorder)
                ?? .unverified(provider)
            let error = await recorder.lastError
            return TatwoQuotaProviderLoadResult(
                row: row,
                isSuccessful: error == nil,
                isRateLimited: error == .httpStatus(429))
        case "grok":
            let row = await TatwoLiveQuotaReader.loadGrok(
                provider: provider)
                ?? .unverified(provider)
            return TatwoQuotaProviderLoadResult(
                row: row,
                isSuccessful: true,
                isRateLimited: false)
        case "minimax":
            let row = await TatwoLiveQuotaReader.loadMiniMax(
                provider: provider)
                ?? .unverified(provider)
            return TatwoQuotaProviderLoadResult(
                row: row,
                isSuccessful: true,
                isRateLimited: false)
        default:
            return TatwoQuotaProviderLoadResult(
                row: .unverified(provider),
                isSuccessful: true,
                isRateLimited: false)
        }
    }
}

actor TatwoQuotaSnapshotCache {
    static let shared = TatwoQuotaSnapshotCache()

    private struct CachedSuccess: Sendable {
        let row: LiveQuotaDisplay
        let loadedAt: Date
    }

    private struct Flight: Sendable {
        let id: UUID
        let task: Task<TatwoQuotaProviderLoadResult, Never>
    }

    private let loader: any TatwoQuotaProviderLoading
    private let now: @Sendable () -> Date
    private let successTTL: TimeInterval
    private let localUsageTTL: TimeInterval
    private let rateLimitBackoff: TimeInterval
    private let manualRefreshDeduplicationWindow: TimeInterval

    private var successfulRows: [String: CachedSuccess] = [:]
    private var lastResults: [String: LiveQuotaDisplay] = [:]
    private var rateLimitedUntil: [String: Date] = [:]
    private var lastManualRefreshAt: [String: Date] = [:]
    private var inFlight: [String: Flight] = [:]

    init(
        loader: any TatwoQuotaProviderLoading =
            TatwoLiveQuotaProviderLoader(),
        successTTL: TimeInterval = 240,
        localUsageTTL: TimeInterval = 60,
        rateLimitBackoff: TimeInterval = 600,
        manualRefreshDeduplicationWindow: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.successTTL = successTTL
        self.localUsageTTL = localUsageTTL
        self.rateLimitBackoff = rateLimitBackoff
        self.manualRefreshDeduplicationWindow =
            manualRefreshDeduplicationWindow
        self.now = now
    }

    func load(
        providers: [UsageProviderStatus],
        refreshKind: TatwoQuotaRefreshKind = .automatic,
        allowExternalAccess: Bool = false
    ) async -> LiveQuotaDeckSnapshot {
        await withTaskGroup(
            of: (String, LiveQuotaDisplay).self
        ) { group in
            for provider in providers {
                group.addTask {
                    let row = await self.load(
                        provider: provider,
                        refreshKind: refreshKind,
                        allowExternalAccess: allowExternalAccess)
                    return (provider.id, row)
                }
            }

            var rows: [String: LiveQuotaDisplay] = [:]
            for await (providerID, row) in group {
                rows[providerID] = row
            }
            return LiveQuotaDeckSnapshot(
                loadedAt: now(),
                rows: rows)
        }
    }

    private func load(
        provider: UsageProviderStatus,
        refreshKind: TatwoQuotaRefreshKind,
        allowExternalAccess: Bool
    ) async -> LiveQuotaDisplay {
        let requestDate = now()

        if let backoffEnd = rateLimitedUntil[provider.id],
           requestDate < backoffEnd
        {
            if refreshKind == .manual {
                lastManualRefreshAt[provider.id] = requestDate
            }
            return rateLimitedFallback(
                provider: provider)
        }

        if refreshKind == .automatic,
           let cached = successfulRows[provider.id],
           requestDate.timeIntervalSince(cached.loadedAt)
                <= successTTL(for: provider.id)
        {
            return cached.row
        }

        if refreshKind == .manual,
           let lastManual = lastManualRefreshAt[provider.id],
           requestDate.timeIntervalSince(lastManual)
                < manualRefreshDeduplicationWindow,
           let lastResult = lastResults[provider.id]
                ?? successfulRows[provider.id]?.row
        {
            return lastResult
        }

        if let current = inFlight[provider.id] {
            return await consume(
                current.task,
                flightID: current.id,
                provider: provider,
                requestDate: requestDate)
        }

        if refreshKind == .manual {
            lastManualRefreshAt[provider.id] = requestDate
        }
        let loader = loader
        let task = Task {
            await loader.load(
                provider: provider,
                allowExternalAccess: allowExternalAccess)
        }
        let flightID = UUID()
        inFlight[provider.id] = Flight(
            id: flightID,
            task: task)
        return await consume(
            task,
            flightID: flightID,
            provider: provider,
            requestDate: requestDate)
    }

    private func consume(
        _ task: Task<TatwoQuotaProviderLoadResult, Never>,
        flightID: UUID,
        provider: UsageProviderStatus,
        requestDate: Date
    ) async -> LiveQuotaDisplay {
        let result = await task.value
        if inFlight[provider.id]?.id == flightID {
            inFlight[provider.id] = nil
        }

        if result.isRateLimited {
            let retryAt = requestDate.addingTimeInterval(
                rateLimitBackoff)
            rateLimitedUntil[provider.id] = retryAt
            let fallback = rateLimitedFallback(
                provider: provider,
                upstreamRow: result.row)
            lastResults[provider.id] = fallback
            return fallback
        }

        lastResults[provider.id] = result.row
        if result.isSuccessful {
            successfulRows[provider.id] = CachedSuccess(
                row: result.row,
                loadedAt: requestDate)
            rateLimitedUntil[provider.id] = nil
        }
        return result.row
    }

    private func rateLimitedFallback(
        provider: UsageProviderStatus,
        upstreamRow: LiveQuotaDisplay? = nil
    ) -> LiveQuotaDisplay {
        let base = successfulRows[provider.id]?.row
            ?? upstreamRow
            ?? lastResults[provider.id]
            ?? .unverified(provider)
        let reason = "稍後刷新（服務回應 HTTP 429）"
        return base.replacingCaption(
            base.caption.contains(reason)
                ? base.caption
                : "\(base.caption)；\(reason)")
    }

    private func successTTL(for providerID: String) -> TimeInterval {
        switch providerID {
        case "grok", "minimax":
            localUsageTTL
        default:
            successTTL
        }
    }
}

private actor CodexQuotaSnapshotRecorder {
    private(set) var snapshot:
        ChatNativeSubscriptionAccountSnapshot?

    func read() async
        -> ChatNativeSubscriptionAccountSnapshot
    {
        let value = await ChatNativeSubscriptionAccountService()
            .quotaSnapshot()
        snapshot = value
        return value
    }
}

private actor ClaudeQuotaUsageRecorder:
    ClaudeOAuthUsageQuerying
{
    private(set) var lastError: ClaudeOAuthUsageError?

    func queryUsage() async throws -> ClaudeOAuthUsage {
        do {
            return try await ClaudeOAuthUsageClient().queryUsage()
        } catch let error as ClaudeOAuthUsageError {
            lastError = error
            throw error
        } catch {
            lastError = .network
            throw ClaudeOAuthUsageError.network
        }
    }
}

private extension LiveQuotaDisplay {
    func replacingCaption(_ caption: String)
        -> LiveQuotaDisplay
    {
        LiveQuotaDisplay(
            id: id,
            displayName: displayName,
            planLabel: planLabel,
            status: status,
            statusText: statusText,
            caption: caption,
            permissionLabel: permissionLabel,
            sourceBadge: sourceBadge,
            remainingPercent: remainingPercent,
            primaryRemainingPercent: primaryRemainingPercent,
            secondaryRemainingPercent: secondaryRemainingPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            resetCreditsAvailable: resetCreditsAvailable,
            resetCreditsExpiresAt: resetCreditsExpiresAt,
            resetCreditExpiryDates: resetCreditExpiryDates)
    }
}
