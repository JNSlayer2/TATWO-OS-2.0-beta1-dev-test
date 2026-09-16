// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DevicesComposition.swift；改動 4 行（原因：新增來源標頭；移除三個舊水電 module import，改用同名 Facade 假資料）
import Foundation

/// Interactive Devices wiring: a live Device Sync core (append transport +
/// persistence), the authority coordinator port for lease commands, and the
/// periodic snapshot producer. Built only when the coordinator environment is
/// fully configured; callers fall back to the read-only provider otherwise.
struct TatwoDevicesInteractiveStack {
    let domainID: String
    let syncCore: TatwoDeviceSyncCore
    let authorityPort: any TatwoDomainAuthorityCoordinatorPort
    let producer: TatwoDeviceSnapshotProducer
}

enum TatwoDevicesCompositionRoot {
    static let defaultDomainID = "tatwo-primary"

    static func makeProvider(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> any DomainDeviceSnapshotProvider {
        let isSnapshotExport =
            environment["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
            || environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
        if isSnapshotExport,
           let inlineJSON = environment["TATWO_ULTRAWORK_DEVICE_STATE_JSON"],
           let data = inlineJSON.data(using: .utf8),
           data.count <= 256 * 1_024,
           let snapshot = try? decoder().decode(TatwoDomainDeviceSnapshotV1.self, from: data),
           TatwoDomainSnapshotValidatorV1.isValid(snapshot, now: now())
        {
            return TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: snapshot,
                now: now
            )
        }

        guard !isSnapshotExport,
              let applicationSupportURL
        else {
            return TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: nil,
                now: now
            )
        }
        let persistenceRoot = TatwoRuntimeLayout.stateRoot(
            environment: environment,
            applicationSupportBase: applicationSupportURL
        )
            .appendingPathComponent("domain-ledger", isDirectory: true)
        guard let persistence = try? TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: persistenceRoot,
            createRootIfMissing: false,
            now: now
        ) else {
            return TatwoStaticDomainDeviceSnapshotProvider(
                snapshot: nil,
                now: now
            )
        }
        return TatwoPersistedDomainDeviceSnapshotProvider(
            persistenceAdapter: persistence,
            now: now
        )
    }

    /// Builds the interactive Devices stack when — and only when — the
    /// coordinator environment is fully configured:
    /// - `TATWO_DOMAIN_COORDINATOR_URL`: parseable URL; `https` always
    ///   allowed, `http` only for loopback hosts and only when
    ///   `TATWO_DOMAIN_COORDINATOR_ALLOW_LOOPBACK=1` (the flag is what turns
    ///   on `allowInsecureLoopbackForTesting` in both transports).
    /// - `TATWO_DOMAIN_GATEWAY_SECRET`: at least 32 UTF-8 bytes.
    /// - `TATWO_DOMAIN_ID` (optional): overrides the default
    ///   `tatwo-primary` domain.
    /// - `TATWO_DOMAIN_DEVICE_KIND`: required local device kind. This prevents
    ///   a MacBook from being silently registered as a Mac mini.
    ///
    /// Any missing or invalid condition returns `nil` so callers keep the
    /// existing read-only `makeProvider` behavior unchanged.
    @MainActor
    static func makeInteractiveStack(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        deviceDisplayName: String = Host.current().localizedName ?? "Mac",
        now: @escaping @Sendable () -> Date = Date.init
    ) -> TatwoDevicesInteractiveStack? {
        guard let rawBaseURL = environment["TATWO_DOMAIN_COORDINATOR_URL"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBaseURL.isEmpty,
              let baseURL = URL(string: rawBaseURL),
              let secret = environment["TATWO_DOMAIN_GATEWAY_SECRET"],
              secret.utf8.count >= 32,
              let deviceKind = localDeviceKind(environment: environment),
              let applicationSupportURL
        else {
            return nil
        }
        let allowLoopback =
            environment["TATWO_DOMAIN_COORDINATOR_ALLOW_LOOPBACK"] == "1"
        let secretProvider: () -> String? = { secret }
        // Both transports enforce the endpoint allowlist (https, or loopback
        // http when the testing escape hatch is enabled) and throw otherwise.
        guard let appendTransport = try? TatwoDomainCoordinatorHTTPTransport(
            baseURL: baseURL,
            allowInsecureLoopbackForTesting: allowLoopback,
            secretProvider: secretProvider
        ), let authorityTransport = try? TatwoDomainAuthorityHTTPTransport(
            baseURL: baseURL,
            allowInsecureLoopbackForTesting: allowLoopback,
            secretProvider: secretProvider
        ) else {
            return nil
        }
        let stateRoot = TatwoRuntimeLayout.stateRoot(
            environment: environment,
            applicationSupportBase: applicationSupportURL
        )
        guard let persistence = try? TatwoFileBackedDeviceSyncPersistenceAdapter(
            rootURL: stateRoot.appendingPathComponent(
                "domain-ledger",
                isDirectory: true
            ),
            createRootIfMissing: true,
            now: now
        ) else {
            return nil
        }
        let domainID = environment["TATWO_DOMAIN_ID"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultDomainID
        let hashRelay = TatwoSnapshotProducerReceiptHashRelay()
        let syncCore = TatwoDeviceSyncCore(
            domainID: domainID,
            snapshotProducerReceiptSHA256: { hashRelay.value },
            persistenceAdapter: persistence,
            transport: appendTransport,
            now: now
        )
        let producer = TatwoDeviceSnapshotProducer(
            syncCore: syncCore,
            deviceDisplayName: deviceDisplayName,
            deviceKind: deviceKind,
            stateRootURL: stateRoot,
            domainID: domainID,
            receiptHashSink: { hashRelay.value = $0 },
            now: now
        )
        return TatwoDevicesInteractiveStack(
            domainID: domainID,
            syncCore: syncCore,
            authorityPort: authorityTransport,
            producer: producer
        )
    }

    private static func localDeviceKind(
        environment: [String: String]
    ) -> TatwoDomainDeviceKindV1? {
        switch environment["TATWO_DOMAIN_DEVICE_KIND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "macbook", "mac-book", "laptop":
            .macBook
        case "macmini", "mac-mini", "mini":
            .macMini
        case "ipad":
            .iPad
        case "visionpro", "vision-pro":
            .visionPro
        case "remotehost", "remote-host":
            .remoteHost
        case "other":
            .other
        default:
            nil
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) ?? standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "date must be ISO-8601"
            )
        }
        return decoder
    }

    static func makeSyncModulesRegistry() -> TatwoSyncModulesRegistry? {
        try? TatwoSyncModulesRegistry.loadBundled()
    }

    static func makeEnablementStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportBase: URL? = nil
    ) -> TatwoSyncModuleEnablementStore {
        TatwoSyncModuleEnablementStore.defaultStore(
            environment: environment,
            applicationSupportBase: applicationSupportBase
        )
    }

    static func makeRuntimeStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportBase: URL? = nil
    ) -> TatwoSyncModuleRuntimeStateStore {
        TatwoSyncModuleRuntimeStateStore.defaultStore(
            environment: environment,
            applicationSupportBase: applicationSupportBase
        )
    }
}

enum DevicesConnectionPresentation: String, Equatable, Sendable {
    case connected
    case syncing
    case offline
    case unknown

    var label: String {
        switch self {
        case .connected: "在線"
        case .syncing: "連線中"
        case .offline: "離線"
        case .unknown: "未驗證"
        }
    }

    static func from(
        domain: TatwoDomainConnectionStateV1?,
        inventory: TatwoDeviceConnectionStatusV1?,
        isLocal: Bool = false
    ) -> DevicesConnectionPresentation {
        if isLocal { return .connected }
        if let domain {
            switch domain {
            case .connected: return .connected
            case .syncing: return .syncing
            case .offline: return .offline
            }
        }
        switch inventory {
        case .local, .online: return .connected
        case .offline: return .offline
        case .unknown, nil: return .unknown
        }
    }
}

enum DevicesExportSyncFixture {
    static let referenceDate = Date(timeIntervalSince1970: 1_785_542_400)
    static let localDeviceName = "Mac mini"
    static let remoteDeviceName = "MacBook Air"

    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let isSnapshot = environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || environment["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
        return isSnapshot && environment["TATWO_ULTRAWORK_EXPORT_SYNC_FIXTURE"] == "1"
    }

    static func primaryState() -> TatwoFlexPrimaryState {
        TatwoFlexPrimaryState(
            localDeviceName: localDeviceName,
            currentPrimaryName: localDeviceName,
            epoch: 7,
            changedAt: referenceDate.addingTimeInterval(-3_668)
        )
    }

    static func secondaryDevices() -> [EnrolledDevice] {
        [
            EnrolledDevice(
                name: remoteDeviceName,
                role: "secondary",
                enrolledAt: referenceDate.addingTimeInterval(-86_468)
            )
        ]
    }

    static func localInventory() -> TatwoDeviceHostInventoryV1 {
        TatwoDeviceHostInventoryV1(
            hardwareModel: "Mac16,10",
            chipName: "Apple M4",
            ramTotalBytes: 24 * 1_024 * 1_024 * 1_024,
            cpuPercent: 12,
            memoryPressureLevel: .normal,
            connectionStatus: .local,
            activeLoopCount: 1
        )
    }

    static func autosync() -> TatwoAutosyncStatusSnapshot {
        TatwoAutosyncStatusSnapshot(
            lastInstalledCommit: "aaaaaaaaaaaa",
            lastCheckAt: referenceDate
        )
    }

    static func localInventoryForDisplay() -> TatwoDeviceHostInventoryV1 {
        if isActive() { return localInventory() }
        return TatwoDeviceHostInventoryCollector.collectOnce(connectionStatus: .local)
            ?? TatwoDeviceHostInventoryV1()
    }
}

struct DevicesIdentityCardModel: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isLocal: Bool
    let isPrimary: Bool
    let connection: DevicesConnectionPresentation
    let hardwareModel: String?
    let chipName: String?
    let ramLabel: String?
    let appVersion: String?
    let inventoryUpdatedLabel: String?
    let isInventoryStale: Bool

    var localityLabel: String { isLocal ? "本機" : "遠端" }

    var hardwareLine: String {
        DevicesPagePresentation.hardwareLine(
            model: hardwareModel,
            chip: chipName,
            ramLabel: ramLabel
        )
    }
}

struct DevicesVersionRowModel: Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let isLocal: Bool
    let appVersion: String
    let releaseHead: String
    let lastCheckLabel: String?
    let isChecking: Bool
    let isFailed: Bool
}

struct DevicesDataDeviceRowModel: Equatable, Identifiable, Sendable {
    let id: String
    let deviceName: String
    let isLocal: Bool
    let statusLabel: String?
    let isSyncing: Bool
    let isFailed: Bool
}

enum DevicesBatchInclusionKind: String, CaseIterable, Sendable {
    case version
    case data

    var excludedDefaultsKey: String {
        switch self {
        case .version: DevicesBatchInclusionStore.versionExcludedKey
        case .data: DevicesBatchInclusionStore.dataExcludedKey
        }
    }
}

enum DevicesBatchInclusionStore {
    static let versionExcludedKey = "tatwo.devices.batchInclusion.version.excluded"
    static let dataExcludedKey = "tatwo.devices.batchInclusion.data.excluded"

    static func isIncluded(deviceName: String, excluded: Set<String>) -> Bool {
        let key = normalizedName(deviceName)
        guard !key.isEmpty else { return false }
        return !excluded.contains(key)
    }

    static func actionEnabled(deviceNames: [String], excluded: Set<String>) -> Bool {
        deviceNames.contains { isIncluded(deviceName: $0, excluded: excluded) }
    }

    static func selectedDeviceNames(
        _ deviceNames: [String],
        excluded: Set<String>
    ) -> [String] {
        deviceNames.filter { isIncluded(deviceName: $0, excluded: excluded) }
    }

    static func loadExcluded(
        kind: DevicesBatchInclusionKind,
        defaults: UserDefaults = .standard
    ) -> Set<String> {
        let raw = defaults.stringArray(forKey: kind.excludedDefaultsKey) ?? []
        return Set(raw.compactMap { name in
            let trimmed = normalizedName(name)
            return trimmed.isEmpty ? nil : trimmed
        })
    }

    static func saveExcluded(
        _ excluded: Set<String>,
        kind: DevicesBatchInclusionKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            excluded.map(normalizedName).filter { !$0.isEmpty }.sorted(),
            forKey: kind.excludedDefaultsKey
        )
    }

    static func setIncluded(
        _ included: Bool,
        deviceName: String,
        excluded: inout Set<String>
    ) {
        let key = normalizedName(deviceName)
        guard !key.isEmpty else { return }
        if included {
            excluded.remove(key)
        } else {
            excluded.insert(key)
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DevicesCLIVersionInfoModel: Equatable, Sendable {
    let titleZh: String
    let plainZh: String
}

struct DevicesDataModuleRowModel: Equatable, Identifiable, Sendable {
    let id: String
    let titleZh: String
    let plainZh: String
    let excluded: Bool
    let enabled: Bool
    let isSyncing: Bool
    let isFailed: Bool
    let failureReason: String?
    /// Registry IDs this presented row writes. Presentation groups (Skillet)
    /// list every underlying module; ordinary rows list themselves.
    let sourceModuleIDs: [String]
}

struct DevicesPressureCardModel: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let isLocal: Bool
    let hardwareModel: String?
    let chipName: String?
    let ramLabel: String?
    let cpuPercentLabel: String?
    let pressureLevel: TatwoHostMemoryPressureLevelV1?
    let connection: DevicesConnectionPresentation
    let activeLoopCount: Int?
    let canRequestLightLoop: Bool?
    let canRequestHeavyLoop: Bool?
    let showsDispatch: Bool
    let inventoryUpdatedLabel: String?
    let isInventoryStale: Bool

    var localityLabel: String { isLocal ? "本機" : "遠端" }
}

struct TatwoAutosyncStatusSnapshot: Equatable, Sendable {
    var lastInstalledCommit: String?
    var lastCheckAt: Date?

    static let empty = TatwoAutosyncStatusSnapshot()
}

enum TatwoAutosyncStatusReader {
    static let lastInstalledCommitFileName = "last-installed-commit"
    static let logFileName = "autosync.log"

    static func read(appSupportRoot: URL) -> TatwoAutosyncStatusSnapshot {
        let commitURL = appSupportRoot.appendingPathComponent(
            lastInstalledCommitFileName,
            isDirectory: false
        )
        let commit = (try? String(contentsOf: commitURL, encoding: .utf8))
            .flatMap { DevicesPagePresentation.shortHash($0) }
        let logURL = appSupportRoot.appendingPathComponent(
            logFileName,
            isDirectory: false
        )
        return TatwoAutosyncStatusSnapshot(
            lastInstalledCommit: commit,
            lastCheckAt: lastLogTimestamp(at: logURL)
        )
    }

    static func lastLogTimestamp(at url: URL) -> Date? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(whereSeparator: \.isNewline).reversed() {
            let token = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if let date = fractional.date(from: token) ?? formatter.date(from: token) {
                return date
            }
        }
        return nil
    }
}

enum DevicesPagePresentation {
    static let threadsExclusionNote = "已排除 · 7/23 裁決"
    static let secretsCaption = "不會同步：Keychain、auth、session、token、PID、cache 與 secrets。"
    static let versionStopCaption = "衝突或驗證失敗時會停止，不會顯示完成。"
    static let unknownVersion = "未回報"
    static let unknownHead = "尚未檢查"
    static let sourceCommitInfoKey = "TatwoSourceCommit"
    static let nameplateTitle = "設備"
    static let nameplateSubtitle = "連線設備與主輔狀態"

    /// Presentation-only hide list for ②. Registry modules stay; these IDs
    /// (plus any `excluded` module) do not appear in the data-module list.
    static let deferredDataModuleIDs: Set<String> = [
        "goal-state",
        "mcp-plugin-registry",
        "memory-sync",
    ]
    /// skillet-bundle-lane is the skillet-source lane; keep registry IDs split.
    static let skilletSourceModuleIDs = ["skillet-bundle-lane", "os-skillet-md"]
    static let skilletPresentedID = "skillet-skills"
    static let skilletTitleZh = "Skillet 技能"
    static let skilletPlainZh =
        "skill 技能與 skillet.md 主控文件跨設備同步。主設備已簽名的發送會在目標機自動套用。"

    static func processInfoDictionary(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> [String: Any] {
        if let infoDictionary,
           firstNonEmpty(
            infoDictionary["CFBundleShortVersionString"] as? String,
            infoDictionary[sourceCommitInfoKey] as? String
           ) != nil
        {
            return infoDictionary
        }
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Info.plist"),
            bundleURL.appendingPathComponent("Info.plist"),
            bundleURL.deletingLastPathComponent().appendingPathComponent("Info.plist"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any]
            else { continue }
            return plist
        }
        return infoDictionary ?? [:]
    }

    static func localSourceCommit(
        infoDictionary: [String: Any]? = nil,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let info = processInfoDictionary(
            infoDictionary: infoDictionary ?? Bundle.main.infoDictionary,
            bundleURL: bundleURL
        )
        return shortHash(info[sourceCommitInfoKey] as? String)
    }

    static func localAppVersion(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let info = processInfoDictionary(
            infoDictionary: infoDictionary,
            bundleURL: bundleURL
        )
        if let raw = firstNonEmpty(info["CFBundleShortVersionString"] as? String) {
            return raw
        }
        return localSourceCommit(infoDictionary: info, bundleURL: bundleURL)
    }

    static func localReleaseHead(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        bundleURL: URL = Bundle.main.bundleURL,
        autosync: TatwoAutosyncStatusSnapshot = .empty
    ) -> String? {
        autosync.lastInstalledCommit
            ?? localSourceCommit(
                infoDictionary: infoDictionary,
                bundleURL: bundleURL
            )
    }

    static func formatRAM(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func shortHash(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
        guard let trimmed, !trimmed.isEmpty else { return nil }
        if trimmed.count <= 12 { return trimmed }
        return String(trimmed.prefix(12))
    }

    static func hardwareLine(
        model: String?,
        chip: String?,
        ramLabel: String?
    ) -> String {
        let parts = [model, chip, ramLabel]
            .map { value -> String in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "—" : trimmed
            }
        return parts.allSatisfy { $0 == "—" } ? "—" : parts.joined(separator: " · ")
    }

    static func formatLastCheck(_ date: Date, now: Date) -> String {
        "上次檢查 " + date.formatted(date: .abbreviated, time: .shortened)
    }

    static func formatLastSync(_ date: Date, now: Date) -> String {
        "上次同步 " + date.formatted(date: .abbreviated, time: .shortened)
    }

    static func deviceRowStatusLabel(
        receipt: DeviceSyncReceipt?,
        fallbackDate: Date?,
        now: Date,
        successFormatter: (Date, Date) -> String = formatLastCheck
    ) -> String? {
        if let receipt {
            if isFailedReceipt(receipt) {
                let message = receipt.message
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return message.isEmpty ? "尚未完成" : message
            }
            return successFormatter(receipt.completedAt, now)
        }
        return fallbackDate.map { successFormatter($0, now) }
    }

    static func isFailedReceipt(_ receipt: DeviceSyncReceipt) -> Bool {
        receipt.result == "failure"
            || receipt.effectivePhase == .failed
            || receipt.effectivePhase == .diverged
    }

    static func formatCPUPercent(_ value: Double) -> String {
        let clamped = min(100, max(0, value))
        return String(format: "%.0f%%", clamped)
    }

    static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    static func mergedHostInventory(
        collected: TatwoDeviceHostInventoryV1?,
        projected: TatwoDeviceHostInventoryV1?
    ) -> TatwoDeviceHostInventoryV1? {
        // A fresh observation is authoritative, including missing fields. Never fill a
        // failed live sensor from stale projections or snapshot-only fixture values.
        if let collected { return collected.isEmpty ? nil : collected }
        return projected
    }

    static func identityCards(
        primary: TatwoFlexPrimaryState,
        enrolled: [EnrolledDevice],
        verified: [TatwoDomainDeviceV1],
        localInventory: TatwoDeviceHostInventoryV1?,
        localAppVersion: String?,
        peerInventories: [TatwoDevicePeerInventoryRecordV1] = [],
        now: Date = Date()
    ) -> [DevicesIdentityCardModel] {
        var seen = Set<String>()
        var cards: [DevicesIdentityCardModel] = []

        func append(
            name: String,
            isLocal: Bool,
            verifiedDevice: TatwoDomainDeviceV1?,
            enrolledDevice: EnrolledDevice?,
            inventory: TatwoDeviceHostInventoryV1?,
            appVersion: String?,
            peerRecord: TatwoDevicePeerInventoryRecordV1?
        ) {
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return }
            let isPrimary = primary.currentPrimaryName == name
            cards.append(
                DevicesIdentityCardModel(
                    id: verifiedDevice?.id
                        ?? enrolledDevice?.deviceId
                        ?? peerRecord?.deviceID
                        ?? name,
                    displayName: name,
                    isLocal: isLocal,
                    isPrimary: isPrimary,
                    connection: DevicesConnectionPresentation.from(
                        domain: verifiedDevice?.connectionState,
                        inventory: inventory?.connectionStatus,
                        isLocal: isLocal
                    ),
                    hardwareModel: inventory?.hardwareModel,
                    chipName: inventory?.chipName,
                    ramLabel: inventory?.ramTotalBytes.map(formatRAM),
                    appVersion: appVersion,
                    inventoryUpdatedLabel: peerRecord.map {
                        TatwoDevicePeerInventoryStalenessV1.updatedLabel(
                            timestamp: $0.timestamp,
                            now: now
                        )
                    },
                    isInventoryStale: peerRecord.map {
                        TatwoDevicePeerInventoryStalenessV1.isStale(
                            timestamp: $0.timestamp,
                            now: now
                        )
                    } ?? false
                )
            )
        }

        let localVerified = matchVerified(
            name: primary.localDeviceName,
            verified: verified
        )
        append(
            name: primary.localDeviceName,
            isLocal: true,
            verifiedDevice: localVerified,
            enrolledDevice: enrolled.first { $0.name == primary.localDeviceName },
            inventory: localInventory,
            appVersion: localAppVersion,
            peerRecord: nil
        )

        for device in enrolled where device.name != primary.localDeviceName {
            let verifiedDevice = matchVerified(name: device.name, verified: verified)
            let peer = matchPeerInventory(
                records: peerInventories,
                verifiedDevice: verifiedDevice,
                enrolledDevice: device,
                displayName: device.name
            )
            append(
                name: device.name,
                isLocal: false,
                verifiedDevice: verifiedDevice,
                enrolledDevice: device,
                inventory: peer?.hostInventory,
                appVersion: nil,
                peerRecord: peer
            )
        }

        if let currentPrimary = primary.currentPrimaryName,
           currentPrimary != primary.localDeviceName
        {
            let verifiedDevice = matchVerified(name: currentPrimary, verified: verified)
            let enrolledDevice = enrolled.first { $0.name == currentPrimary }
            let peer = matchPeerInventory(
                records: peerInventories,
                verifiedDevice: verifiedDevice,
                enrolledDevice: enrolledDevice,
                displayName: currentPrimary
            )
            append(
                name: currentPrimary,
                isLocal: false,
                verifiedDevice: verifiedDevice,
                enrolledDevice: enrolledDevice,
                inventory: peer?.hostInventory,
                appVersion: nil,
                peerRecord: peer
            )
        }

        for device in verified where device.displayName != primary.localDeviceName {
            let enrolledDevice = enrolled.first { $0.name == device.displayName }
            let peer = matchPeerInventory(
                records: peerInventories,
                verifiedDevice: device,
                enrolledDevice: enrolledDevice,
                displayName: device.displayName
            )
            append(
                name: device.displayName,
                isLocal: false,
                verifiedDevice: device,
                enrolledDevice: enrolledDevice,
                inventory: peer?.hostInventory,
                appVersion: nil,
                peerRecord: peer
            )
        }

        return cards
    }

    static func versionRows(
        cards: [DevicesIdentityCardModel],
        autosync: TatwoAutosyncStatusSnapshot,
        versionReceipts: [DeviceSyncReceipt],
        checkingDeviceNames: Set<String>,
        now: Date
    ) -> [DevicesVersionRowModel] {
        let latestByTarget = latestVersionReceipts(versionReceipts)
        return cards.map { card in
            let receipt = latestByTarget[card.displayName]
                ?? (card.isLocal ? latestByTarget[card.id] : nil)
            let appVersion = card.appVersion
                ?? shortHash(receipt?.appliedDigest)
                ?? (card.isLocal ? autosync.lastInstalledCommit : nil)
                ?? unknownVersion
            let head = autosync.lastInstalledCommit
                ?? (card.isLocal ? localSourceCommit() : nil)
                ?? shortHash(receipt?.sourceDigest)
                ?? unknownHead
            let lastCheck = receipt?.completedAt ?? (card.isLocal ? autosync.lastCheckAt : nil)
            return DevicesVersionRowModel(
                id: card.id,
                deviceName: card.displayName,
                isLocal: card.isLocal,
                appVersion: appVersion,
                releaseHead: head,
                lastCheckLabel: deviceRowStatusLabel(
                    receipt: receipt,
                    fallbackDate: lastCheck,
                    now: now,
                    successFormatter: formatLastCheck
                ),
                isChecking: checkingDeviceNames.contains(card.displayName),
                isFailed: receipt.map(isFailedReceipt) ?? false
            )
        }
    }

    static func dataDeviceRows(
        cards: [DevicesIdentityCardModel],
        dataReceipts: [DeviceSyncReceipt],
        syncingDeviceNames: Set<String>,
        now: Date
    ) -> [DevicesDataDeviceRowModel] {
        let latestByTarget = latestActionReceipts(dataReceipts, action: "system-pull")
        return cards.map { card in
            let receipt = latestByTarget[card.displayName]
                ?? (card.isLocal ? latestByTarget[card.id] : nil)
            return DevicesDataDeviceRowModel(
                id: card.id,
                deviceName: card.displayName,
                isLocal: card.isLocal,
                statusLabel: deviceRowStatusLabel(
                    receipt: receipt,
                    fallbackDate: receipt?.completedAt,
                    now: now,
                    successFormatter: formatLastSync
                ),
                isSyncing: syncingDeviceNames.contains(card.displayName),
                isFailed: receipt.map(isFailedReceipt) ?? false
            )
        }
    }

    static func cliVersionInfo(
        registry: TatwoSyncModulesRegistry?
    ) -> DevicesCLIVersionInfoModel? {
        guard let module = registry?.module(id: "cli-version") else { return nil }
        return DevicesCLIVersionInfoModel(
            titleZh: module.titleZh,
            plainZh: module.plainZh
        )
    }

    static func dataModuleRows(
        registry: TatwoSyncModulesRegistry?,
        enablement: TatwoSyncModuleEnablementStore,
        runtime: TatwoSyncModuleRuntimeStateStore
    ) -> [DevicesDataModuleRowModel] {
        guard let registry else { return [] }
        let resolved = (try? registry.resolvedModules(
            enablement: enablement,
            runtime: runtime
        )) ?? registry.modules.map { definition in
            TatwoSyncModuleResolvedV1(
                definition: definition,
                enabled: definition.enabled,
                runtime: TatwoSyncModuleRuntimeRecordV1(moduleID: definition.id)
            )
        }
        return dataModuleRows(resolved: resolved)
    }

    static func dataModuleRows(
        resolved: [TatwoSyncModuleResolvedV1]
    ) -> [DevicesDataModuleRowModel] {
        let visible = resolved
            .filter { $0.definition.section == .data }
            .compactMap { module -> DevicesDataModuleRowModel? in
                guard !isHiddenDataModule(module.definition) else { return nil }
                let reason = module.reason?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return DevicesDataModuleRowModel(
                    id: module.id,
                    titleZh: module.definition.titleZh,
                    plainZh: module.definition.plainZh,
                    excluded: module.definition.excluded,
                    enabled: module.enabled,
                    isSyncing: module.runState == .syncing,
                    isFailed: module.runState == .failed,
                    failureReason: (reason?.isEmpty == false) ? reason : nil,
                    sourceModuleIDs: [module.id]
                )
            }
        return collapseSkilletRows(visible)
    }

    static func isHiddenDataModule(_ definition: TatwoSyncModuleDefinitionV1) -> Bool {
        definition.excluded || deferredDataModuleIDs.contains(definition.id)
    }

    static func enablementModuleIDs(forPresentedID id: String) -> [String] {
        if id == skilletPresentedID {
            return skilletSourceModuleIDs
        }
        return [id]
    }

    static func admissionCaption(canRequestLight: Bool, canRequestHeavy: Bool) -> String {
        let light = canRequestLight ? "可接輕型工作" : "不接輕型工作"
        let heavy = canRequestHeavy ? "可接重型工作" : "不接重型工作"
        return "\(light) · \(heavy)"
    }

    static func isBorrowableDeviceID(_ value: String) -> Bool {
        TatwoDevicePeerInventoryStore.isSafeDeviceID(value)
    }

    /// Borrow policy keys a device by durable ID. Domain snapshot is preferred,
    /// then signed helper inventory / enrolled registry so the switch does not
    /// wait for the peer App to publish a domain heartbeat.
    static func borrowTargetDeviceID(
        displayName: String,
        verified: [TatwoDomainDeviceV1],
        enrolled: [EnrolledDevice],
        peerInventories: [TatwoDevicePeerInventoryRecordV1]
    ) -> String? {
        if let verifiedDevice = matchVerified(name: displayName, verified: verified),
           isBorrowableDeviceID(verifiedDevice.id)
        {
            return verifiedDevice.id
        }
        if let peer = TatwoDevicePeerInventoryStore.match(
            records: peerInventories,
            deviceID: nil,
            displayName: displayName
        ), isBorrowableDeviceID(peer.deviceID) {
            return peer.deviceID
        }
        let enrolledMatches = enrolled.filter {
            $0.name.caseInsensitiveCompare(displayName) == .orderedSame
        }
        if enrolledMatches.count == 1,
           let deviceId = enrolledMatches[0].deviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceId.isEmpty,
           isBorrowableDeviceID(deviceId)
        {
            return deviceId
        }
        if enrolledMatches.count == 1,
           peerInventories.count == 1,
           isBorrowableDeviceID(peerInventories[0].deviceID)
        {
            return peerInventories[0].deviceID
        }
        return nil
    }

    private static func collapseSkilletRows(
        _ rows: [DevicesDataModuleRowModel]
    ) -> [DevicesDataModuleRowModel] {
        let skilletMembers = rows.filter { skilletSourceModuleIDs.contains($0.id) }
        guard !skilletMembers.isEmpty else { return rows }
        let merged = mergedSkilletRow(from: skilletMembers)
        var emitted = false
        return rows.compactMap { row in
            guard skilletSourceModuleIDs.contains(row.id) else { return row }
            if emitted { return nil }
            emitted = true
            return merged
        }
    }

    private static func mergedSkilletRow(
        from members: [DevicesDataModuleRowModel]
    ) -> DevicesDataModuleRowModel {
        let failed = members.first(where: \.isFailed)
        return DevicesDataModuleRowModel(
            id: skilletPresentedID,
            titleZh: skilletTitleZh,
            plainZh: skilletPlainZh,
            excluded: false,
            enabled: members.contains(where: \.enabled),
            isSyncing: failed == nil && members.contains(where: \.isSyncing),
            isFailed: failed != nil,
            failureReason: failed?.failureReason,
            sourceModuleIDs: skilletSourceModuleIDs
        )
    }

    static func pressureCards(
        identityCards: [DevicesIdentityCardModel],
        localInventory: TatwoDeviceHostInventoryV1?,
        localProjection: TatwoPressureUIProjectionV1?,
        peerInventories: [TatwoDevicePeerInventoryRecordV1] = [],
        now: Date = Date()
    ) -> [DevicesPressureCardModel] {
        identityCards.map { card in
            let peer = card.isLocal
                ? nil
                : TatwoDevicePeerInventoryStore.match(
                    records: peerInventories,
                    deviceID: card.id,
                    displayName: card.displayName
                )
            let inventory = card.isLocal
                ? mergedHostInventory(
                    collected: localInventory,
                    projected: localProjection?.hostInventory
                )
                : peer?.hostInventory
            return DevicesPressureCardModel(
                id: card.id,
                displayName: card.displayName,
                isLocal: card.isLocal,
                hardwareModel: inventory?.hardwareModel ?? card.hardwareModel,
                chipName: inventory?.chipName ?? card.chipName,
                ramLabel: inventory?.ramTotalBytes.map(formatRAM) ?? card.ramLabel,
                cpuPercentLabel: inventory?.cpuPercent.map(formatCPUPercent),
                pressureLevel: inventory?.memoryPressureLevel,
                connection: DevicesConnectionPresentation.from(
                    domain: nil,
                    inventory: inventory?.connectionStatus,
                    isLocal: card.isLocal
                ) == .unknown ? card.connection : DevicesConnectionPresentation.from(
                    domain: nil,
                    inventory: inventory?.connectionStatus,
                    isLocal: card.isLocal
                ),
                activeLoopCount: card.isLocal
                    ? (inventory?.activeLoopCount
                        ?? localProjection.map { projection in
                            TatwoDeviceHostInventoryV1.activeLoopCount(
                                workers: [],
                                activeLoopID: projection.activeLoopID
                            )
                        })
                    : inventory?.activeLoopCount,
                canRequestLightLoop: card.isLocal ? localProjection?.canRequestLightLoop : nil,
                canRequestHeavyLoop: card.isLocal ? localProjection?.canRequestHeavyLoop : nil,
                showsDispatch: !card.isLocal,
                inventoryUpdatedLabel: card.isLocal
                    ? nil
                    : peer.map {
                        TatwoDevicePeerInventoryStalenessV1.updatedLabel(
                            timestamp: $0.timestamp,
                            now: now
                        )
                    } ?? card.inventoryUpdatedLabel,
                isInventoryStale: card.isLocal
                    ? false
                    : peer.map {
                        TatwoDevicePeerInventoryStalenessV1.isStale(
                            timestamp: $0.timestamp,
                            now: now
                        )
                    } ?? card.isInventoryStale
            )
        }
    }

    static func loadPeerInventories(
        appSupportRoot: URL
    ) -> [TatwoDevicePeerInventoryRecordV1] {
        let store = TatwoDevicePeerInventoryStore(
            storeURL: appSupportRoot.appendingPathComponent(
                TatwoDevicePeerInventoryStore.storeDirectoryName,
                isDirectory: true
            )
        )
        let channelRoot = appSupportRoot.appendingPathComponent(
            "device-sync-channel",
            isDirectory: true
        )
        _ = try? store.ingest(
            channelInventoryDirectory: TatwoDevicePeerInventoryStore.channelInventoryDirectory(
                channelRoot: channelRoot
            ),
            registeredDevicesDirectory: channelRoot.appendingPathComponent(
                "devices",
                isDirectory: true
            )
        )
        return (try? store.load()) ?? []
    }

    static func matchPeerInventory(
        records: [TatwoDevicePeerInventoryRecordV1],
        verifiedDevice: TatwoDomainDeviceV1?,
        enrolledDevice: EnrolledDevice?,
        displayName: String
    ) -> TatwoDevicePeerInventoryRecordV1? {
        TatwoDevicePeerInventoryStore.match(
            records: records,
            deviceID: verifiedDevice?.id ?? enrolledDevice?.deviceId,
            displayName: displayName
        )
    }

    static func matchVerified(
        name: String,
        verified: [TatwoDomainDeviceV1]
    ) -> TatwoDomainDeviceV1? {
        if let exact = verified.first(where: { $0.id == name }) {
            return exact
        }
        let matches = verified.filter {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func latestVersionReceipts(
        _ receipts: [DeviceSyncReceipt]
    ) -> [String: DeviceSyncReceipt] {
        latestActionReceipts(receipts, action: "version-pull")
    }

    private static func latestActionReceipts(
        _ receipts: [DeviceSyncReceipt],
        action: String
    ) -> [String: DeviceSyncReceipt] {
        var latest: [String: DeviceSyncReceipt] = [:]
        for receipt in receipts
        where DeviceSyncAction.canonicalArtifactValue(receipt.action) == action {
            let current = latest[receipt.target]
            if current == nil || receipt.completedAt > current!.completedAt {
                latest[receipt.target] = receipt
            }
        }
        return latest
    }
}
