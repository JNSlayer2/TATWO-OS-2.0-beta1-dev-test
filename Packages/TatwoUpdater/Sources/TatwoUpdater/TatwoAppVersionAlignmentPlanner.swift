import CryptoKit
import Foundation

/// Environment names for the explicit, user-triggered App alignment plane.
/// These values intentionally do not participate in the Domain Sync plane.
public enum TatwoAppVersionAlignmentEnvironmentV1 {
    public static let primarySSHHostKey = "TATWO_PRIMARY_SSH_HOST"
    public static let primaryAppPathKey = "TATWO_PRIMARY_APP_PATH"
    public static let localAppPathKey = "TATWO_LOCAL_APP_PATH"
}

/// A copied, data-plane-free projection of the local device's authority role.
/// The caller owns deriving it from a verified snapshot and lease.
public enum TatwoAppVersionAlignmentDeviceRoleV1: String, Codable, Hashable, Sendable {
    case primary
    case secondary
    case unknown
}

public struct TatwoAppVersionAlignmentConfigurationV1:
    Codable,
    Hashable,
    Sendable
{
    public let primarySSHHost: String
    public let primaryAppPath: String
    public let localAppPath: String

    public init(
        primarySSHHost: String,
        primaryAppPath: String,
        localAppPath: String
    ) {
        self.primarySSHHost = primarySSHHost
        self.primaryAppPath = primaryAppPath
        self.localAppPath = localAppPath
    }

    public static func load(
        environment: [String: String]
    ) -> TatwoAppVersionAlignmentConfigurationV1? {
        guard let primarySSHHost = nonEmpty(
            environment[TatwoAppVersionAlignmentEnvironmentV1.primarySSHHostKey]
        ), let primaryAppPath = nonEmpty(
            environment[TatwoAppVersionAlignmentEnvironmentV1.primaryAppPathKey]
        ), let localAppPath = nonEmpty(
            environment[TatwoAppVersionAlignmentEnvironmentV1.localAppPathKey]
        ) else {
            return nil
        }
        return TatwoAppVersionAlignmentConfigurationV1(
            primarySSHHost: primarySSHHost,
            primaryAppPath: primaryAppPath,
            localAppPath: localAppPath
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum TatwoAppVersionAlignmentStepKindV1:
    String,
    Codable,
    Hashable,
    Sendable
{
    case rsync
    case staging
    case atomicSwap
    case relaunch
    case backup
}

public struct TatwoAppVersionAlignmentStepV1: Codable, Hashable, Sendable {
    public let kind: TatwoAppVersionAlignmentStepKindV1
    public let description: String

    public init(
        kind: TatwoAppVersionAlignmentStepKindV1,
        description: String
    ) {
        self.kind = kind
        self.description = description
    }
}

public enum TatwoAppVersionAlignmentRejectionReasonV1:
    String,
    Codable,
    Hashable,
    Sendable
{
    case configurationMissing = "configuration_missing"
    case localDeviceIsNotSecondary = "local_device_is_not_secondary"
    case primarySourceIsLocal = "primary_source_is_local"
    case appPathInvalid = "app_path_invalid"
}

public struct TatwoAppVersionAlignmentPlanV1: Codable, Hashable, Sendable {
    public let isValid: Bool
    public let executionAllowed: Bool
    public let rsyncSource: String?
    public let rsyncDestination: String?
    public let stagingPath: String?
    public let rollbackBackupPath: String?
    public let steps: [TatwoAppVersionAlignmentStepV1]
    public let rejectionReason: TatwoAppVersionAlignmentRejectionReasonV1?
    public let refusalDescription: String

    public init(
        isValid: Bool,
        executionAllowed: Bool,
        rsyncSource: String?,
        rsyncDestination: String?,
        stagingPath: String?,
        rollbackBackupPath: String?,
        steps: [TatwoAppVersionAlignmentStepV1],
        rejectionReason: TatwoAppVersionAlignmentRejectionReasonV1?,
        refusalDescription: String
    ) {
        self.isValid = isValid
        self.executionAllowed = executionAllowed
        self.rsyncSource = rsyncSource
        self.rsyncDestination = rsyncDestination
        self.stagingPath = stagingPath
        self.rollbackBackupPath = rollbackBackupPath
        self.steps = steps
        self.rejectionReason = rejectionReason
        self.refusalDescription = refusalDescription
    }
}

public struct TatwoAppVersionAlignmentPlanReceiptV1:
    Codable,
    Hashable,
    Sendable
{
    public let planHash: String
    public let dryRun: Bool
    public let observedAt: Date

    public init(planHash: String, dryRun: Bool, observedAt: Date) {
        self.planHash = planHash
        self.dryRun = dryRun
        self.observedAt = observedAt
    }
}

/// Produces only a dry-run plan. It has no process, filesystem, SSH, rsync,
/// Domain Sync, or automatic execution capability.
public struct TatwoAppVersionAlignmentPlannerV1: Sendable {
    public init() {}

    public func plan(
        environment: [String: String],
        localRole: TatwoAppVersionAlignmentDeviceRoleV1
    ) -> TatwoAppVersionAlignmentPlanV1 {
        plan(
            configuration: TatwoAppVersionAlignmentConfigurationV1.load(
                environment: environment
            ),
            localRole: localRole
        )
    }

    public func plan(
        configuration: TatwoAppVersionAlignmentConfigurationV1?,
        localRole: TatwoAppVersionAlignmentDeviceRoleV1
    ) -> TatwoAppVersionAlignmentPlanV1 {
        guard localRole == .secondary else {
            return rejected(
                .localDeviceIsNotSecondary,
                "僅已確認的副設備可預覽對齊主設備版本。"
            )
        }
        guard let configuration else {
            return rejected(
                .configurationMissing,
                "未設定，無法對齊。請設定主設備連線、主設備 App 路徑與本機 App 路徑。"
            )
        }
        guard !isLocalSSHHost(configuration.primarySSHHost) else {
            return rejected(
                .primarySourceIsLocal,
                "主設備來源不可指向本機；請設定遠端主設備 SSH host。"
            )
        }
        guard let primaryAppPath = normalizedAppPath(configuration.primaryAppPath),
              let localAppPath = normalizedAppPath(configuration.localAppPath)
        else {
            return rejected(
                .appPathInvalid,
                "主設備與本機 App 路徑都必須是絕對 .app 路徑。"
            )
        }

        let stagedBundle = stagingPath(for: localAppPath)
        let backupBundle = rollbackBackupPath(for: localAppPath)
        let rsyncSource = "\(configuration.primarySSHHost):\(primaryAppPath)"
        let steps: [TatwoAppVersionAlignmentStepV1] = [
            .init(
                kind: .rsync,
                description: "預覽：將 \(rsyncSource) 以 rsync 複製到 \(stagedBundle)；真實執行僅接受不帶 quarantine 的主設備 build，並不走 Finder 下載流程。此輪不建立 SSH 連線、不執行 rsync。"
            ),
            .init(
                kind: .staging,
                description: "預覽：驗證 staged .app 位於 active bundle 之外，並保留與本機 App 同一檔案系統的換裝前提。"
            ),
            .init(
                kind: .atomicSwap,
                description: "待 human gate：依 scripts/tatwo-safe-app-bundle.sh::tatwo_activate_staged_app_bundle 語義，先保留目前 App 到 \(backupBundle)，再以 staged bundle 原子換裝 \(localAppPath)。"
            ),
            .init(
                kind: .relaunch,
                description: "待 human gate：只在原子換裝與健康檢查成功後，重新啟動 \(localAppPath)；本輪不終止或啟動任何 App。"
            ),
            .init(
                kind: .backup,
                description: "保留 \(backupBundle) 作為 rollback 備份；若後續健康檢查失敗，使用同一安全換裝語義還原，且不碰使用者資料或 Domain Sync ledger。"
            )
        ]
        return TatwoAppVersionAlignmentPlanV1(
            isValid: true,
            executionAllowed: false,
            rsyncSource: rsyncSource,
            rsyncDestination: stagedBundle,
            stagingPath: stagedBundle,
            rollbackBackupPath: backupBundle,
            steps: steps,
            rejectionReason: nil,
            refusalDescription: "乾跑預覽有效；尚未取得 human gate，executionAllowed=false。"
        )
    }

    public func receipt(
        for plan: TatwoAppVersionAlignmentPlanV1,
        observedAt: Date
    ) -> TatwoAppVersionAlignmentPlanReceiptV1 {
        TatwoAppVersionAlignmentPlanReceiptV1(
            planHash: hash(of: plan),
            dryRun: true,
            observedAt: observedAt
        )
    }

    private func rejected(
        _ reason: TatwoAppVersionAlignmentRejectionReasonV1,
        _ description: String
    ) -> TatwoAppVersionAlignmentPlanV1 {
        TatwoAppVersionAlignmentPlanV1(
            isValid: false,
            executionAllowed: false,
            rsyncSource: nil,
            rsyncDestination: nil,
            stagingPath: nil,
            rollbackBackupPath: nil,
            steps: [],
            rejectionReason: reason,
            refusalDescription: description
        )
    }

    private func normalizedAppPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let absolute = "/" + normalized
        guard absolute.hasSuffix(".app") else { return nil }
        return absolute
    }

    private func stagingPath(for localAppPath: String) -> String {
        let directory = directoryPath(for: localAppPath)
        return "\(directory).\(bundleStem(for: localAppPath))-alignment-staging.app"
    }

    private func rollbackBackupPath(for localAppPath: String) -> String {
        let directory = directoryPath(for: localAppPath)
        let stem = bundleStem(for: localAppPath)
        return "\(directory).\(stem)-alignment-backups/\(stem)-previous.app"
    }

    private func directoryPath(for path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + components.dropLast().joined(separator: "/") + "/"
    }

    private func bundleStem(for path: String) -> String {
        let lastPathComponent = path.split(separator: "/").last.map(String.init) ?? "App.app"
        return String(lastPathComponent.dropLast(".app".count))
    }

    private func isLocalSSHHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = URL(string: host), parsed.scheme == "ssh", let parsedHost = parsed.host {
            host = parsedHost
        }
        if let accountSeparator = host.lastIndex(of: "@") {
            host = String(host[host.index(after: accountSeparator)...])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let lowercase = host.lowercased()
        return [
            "localhost",
            "127.0.0.1",
            "::1"
        ].contains(lowercase)
    }

    private func hash(of plan: TatwoAppVersionAlignmentPlanV1) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(plan) else {
            return SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
