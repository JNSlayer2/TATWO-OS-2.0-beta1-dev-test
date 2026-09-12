// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/DeviceCrossSyncCard.swift；改動 3 行（原因：新增來源標頭；移除兩個舊 module import，改用同名 Facade 型別）
import AppKit
import SwiftUI

// 設備分頁視覺結構（2026-08-14）：頂部設備卡 + ①版本同步 + ②資料同步。
// ③Loops 派送與壓力在 DevicePressureMonitorCard。舊進度牆與證據失敗區塊已移除。
// 所有動作皆一鍵真執行：App 只寫本機 intent 檔，由常駐 helper 代執行並回寫 receipt。

enum TatwoSyncActionKind: String, Identifiable {
    case data = "system-pull"
    case version = "version-pull"

    var id: String { rawValue }
    var title: String { self == .data ? "同步 OS 資料" : "同步來源版本" }
    var pickerPrompt: String {
        self == .data
            ? "選擇要同步 OS manifest 的副設備"
            : "選擇要同步來源版本的副設備"
    }

    var contentSummary: String {
        self == .data
            ? "包含：os.md、issue.md、TODO.md 與已鎖定的 Skillet Skills 版本。"
            : "包含：主設備已核准的 Tatwo 來源版本。"
    }
}

enum TatwoDeviceEnrollmentCommand {
    static var repoURL: String { "https://github.com/\(FeedbackSettings.feedbackRepository).git" }
    static let branch = "release/tatwo-os"

    /// 指令必帶配對代碼——沒有配對代碼就不給完整指令，
    /// 避免產生一條可以脫離時效被反覆使用的納管指令。
    static func command(
        deviceName: String,
        pairingSeed: String,
        channelRemote: String
    ) -> String? {
        let sanitizedScalars = deviceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .filter { scalar in
                switch scalar.value {
                case 45, 46, 48...57, 65...90, 95, 97...122:
                    true
                default:
                    false
                }
            }
        let sanitized = String(String.UnicodeScalarView(sanitizedScalars))
        let name = sanitized.isEmpty ? "new-device" : sanitized
        let remote = channelRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAllowedPrivateChannelRemote(remote) else { return nil }
        return "git clone --branch \(branch) \(repoURL) ~/tatwo-ultrawork && "
            + "bash ~/tatwo-ultrawork/scripts/tatwo-device-enroll.sh --role secondary "
            + "--name \(shellQuote(name)) --pairing-seed \(shellQuote(pairingSeed)) "
            + "--channel-remote \(shellQuote(remote))"
    }

    static func configuredChannelRemote() -> String {
        if let environmentRemote = ProcessInfo.processInfo.environment["TATWO_CHANNEL_REMOTE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isAllowedPrivateChannelRemote(environmentRemote)
        {
            return environmentRemote
        }

        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/LaunchAgents/com.tatwo.device-sync-helper.plist",
                isDirectory: false
            )
        guard let data = try? Data(contentsOf: plistURL),
              let document = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let environment = document["EnvironmentVariables"] as? [String: Any],
              let storedRemote = environment["TATWO_CHANNEL_REMOTE"] as? String
        else {
            return ""
        }
        let remote = storedRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        return isAllowedPrivateChannelRemote(remote) ? remote : ""
    }

    static func isAllowedPrivateChannelRemote(_ remote: String) -> Bool {
        guard !remote.isEmpty,
              !remote.contains(where: \.isWhitespace),
              !remote.lowercased().hasPrefix("http://"),
              !remote.lowercased().hasPrefix("https://"),
              remote.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 37, 43, 44, 45, 46, 47, 48...58, 61, 64, 65...90, 95, 97...122, 126:
                      true
                  default:
                      false
                  }
              })
        else {
            return false
        }
        return remote.hasPrefix("ssh://")
            || remote.hasPrefix("git@")
            || remote.hasPrefix("file://")
            || remote.hasPrefix("/")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

struct DeviceCrossSyncCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    static let exportSyncFixtureReferenceDate =
        Date(timeIntervalSince1970: 1_785_542_400)

    @ObservedObject private var chatModel: ChatPageModel
    private let outboxStore: DeviceSyncOutboxStore
    private let localActionStore: DeviceLocalActionOutboxStore
    private let deviceSnapshotProvider: any DomainDeviceSnapshotProvider
    private let remoteComputeStateRootURL: URL
    private let enablementStore: TatwoSyncModuleEnablementStore
    private let runtimeStore: TatwoSyncModuleRuntimeStateStore
    private let syncRegistry: TatwoSyncModulesRegistry?
    private let now: () -> Date

    @State private var primaryState: TatwoFlexPrimaryState = TatwoFlexPrimaryReader.read()
    @State private var secondaryDevices: [EnrolledDevice] = []
    @State private var pendingSyncIntents: [DeviceSyncOperationKey: DeviceSyncIntent] = [:]
    @State private var latestSyncReceipts: [DeviceSyncOperationKey: DeviceSyncReceipt] = [:]
    @State private var pendingLocalActionKeys: Set<String> = []
    @State private var latestTransferReceipts: [String: DeviceLocalActionReceipt] = [:]
    @State private var pushVersionReceipt: DeviceLocalActionReceipt?
    @State private var selfClaimReceipt: DeviceLocalActionReceipt?
    @State private var showAddDeviceSheet = false
    @State private var newDeviceName = ""
    @State private var newDeviceChannelRemote = TatwoDeviceEnrollmentCommand
        .configuredChannelRemote()
    @State private var copiedEnrollCommand = false
    @State private var pairingSeed: String?
    @State private var pairingExpiresAt: Date?
    @State private var pairingWaitStartedAt: Date?
    @State private var pairingPending = false
    @State private var pairingEnqueueError: String?
    @State private var verifiedDomainDevices: [TatwoDomainDeviceV1] = []
    @State private var localInventory: TatwoDeviceHostInventoryV1?
    @State private var peerInventories: [TatwoDevicePeerInventoryRecordV1] = []
    @State private var autosyncStatus: TatwoAutosyncStatusSnapshot = .empty
    @State private var dataModules: [DevicesDataModuleRowModel] = []
    @State private var expandedFailedModuleIDs: Set<String> = []
    @State private var versionCheckPending = false
    @State private var versionExcluded: Set<String>
    @State private var dataExcluded: Set<String>

    init(
        chatModel: ChatPageModel,
        outboxStore: DeviceSyncOutboxStore = DeviceSyncOutboxStore(),
        localActionStore: DeviceLocalActionOutboxStore = DeviceLocalActionOutboxStore(),
        deviceSnapshotProvider: any DomainDeviceSnapshotProvider =
            TatwoDevicesCompositionRoot.makeProvider(),
        remoteComputeStateRootURL: URL =
            TatwoProductionLayoutLock.osNativeStateRoot(),
        enablementStore: TatwoSyncModuleEnablementStore =
            TatwoDevicesCompositionRoot.makeEnablementStore(),
        runtimeStore: TatwoSyncModuleRuntimeStateStore =
            TatwoDevicesCompositionRoot.makeRuntimeStore(),
        syncRegistry: TatwoSyncModulesRegistry? =
            TatwoDevicesCompositionRoot.makeSyncModulesRegistry(),
        now: @escaping () -> Date = Date.init
    ) {
        _chatModel = ObservedObject(wrappedValue: chatModel)
        self.outboxStore = outboxStore
        self.localActionStore = localActionStore
        self.deviceSnapshotProvider = deviceSnapshotProvider
        self.remoteComputeStateRootURL = remoteComputeStateRootURL
        self.enablementStore = enablementStore
        self.runtimeStore = runtimeStore
        self.syncRegistry = syncRegistry
        self.now = now
        _versionExcluded = State(
            initialValue: DevicesBatchInclusionStore.loadExcluded(kind: .version)
        )
        _dataExcluded = State(
            initialValue: DevicesBatchInclusionStore.loadExcluded(kind: .data)
        )

        if DevicesExportSyncFixture.isActive() {
            let fixtureNow = DevicesExportSyncFixture.referenceDate
            let requestedAt = fixtureNow.addingTimeInterval(-68)
            let target = DevicesExportSyncFixture.remoteDeviceName
            let key = DeviceSyncOperationKey(
                target: target,
                action: DeviceSyncAction.canonicalRequestValue("version-pull")
                    ?? "version-pull"
            )
            _primaryState = State(initialValue: DevicesExportSyncFixture.primaryState())
            _secondaryDevices = State(initialValue: DevicesExportSyncFixture.secondaryDevices())
            _latestSyncReceipts = State(initialValue: [
                key: DeviceSyncReceipt(
                    target: target,
                    action: key.action,
                    requestedAt: requestedAt,
                    result: "converged",
                    completedAt: fixtureNow,
                    message: "version-pull verified",
                    phase: .converged,
                    requestID: "snapshot-version-check",
                    authorityEpoch: 7,
                    ledgerSequence: 42,
                    authorityPrimary: DevicesExportSyncFixture.localDeviceName,
                    sourceDeviceID: "device-mac-mini",
                    targetDeviceID: "device-macbook-air",
                    catalogRevision:
                        DeviceSyncCatalogProjection.currentRevision ?? "snapshot",
                    sourceDigest: "aaaaaaaaaaaaaaaa",
                    appliedDigest: "bbbbbbbbbbbbbbbb")
            ])
            _autosyncStatus = State(initialValue: DevicesExportSyncFixture.autosync())
            _localInventory = State(initialValue: DevicesExportSyncFixture.localInventoryForDisplay())
        }

        _dataModules = State(initialValue: DevicesPagePresentation.dataModuleRows(
            registry: syncRegistry,
            enablement: enablementStore,
            runtime: runtimeStore
        ))
    }

    private var shouldInstallSyncProgressSnapshotFixture: Bool {
        DevicesExportSyncFixture.isActive()
    }

    private var displayedDataModules: [DevicesDataModuleRowModel] {
        if dataModules.isEmpty {
            return DevicesPagePresentation.dataModuleRows(
                registry: syncRegistry,
                enablement: enablementStore,
                runtime: runtimeStore
            )
        }
        return dataModules
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            identityStrip
            versionSyncSection
            dataSyncSection
            secondaryAdminSection
        }
        .task {
            refreshVisibleState()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                refreshVisibleState()
            }
        }
        .sheet(isPresented: $showAddDeviceSheet) { addDeviceSheet }
    }

    // MARK: - Top identity cards

    private var identityCards: [DevicesIdentityCardModel] {
        DevicesPagePresentation.identityCards(
            primary: primaryState,
            enrolled: secondaryDevices,
            verified: verifiedDomainDevices,
            localInventory: localInventory,
            localAppVersion: DevicesPagePresentation.localAppVersion()
                ?? autosyncStatus.lastInstalledCommit,
            peerInventories: peerInventories,
            now: now()
        )
    }

    private var versionRows: [DevicesVersionRowModel] {
        var checking = Set(
            pendingSyncIntents.values.compactMap { intent -> String? in
                DeviceSyncAction.canonicalArtifactValue(intent.action) == "version-pull"
                    ? intent.target
                    : nil
            }
        )
        if versionCheckPending || pendingLocalActionKeys.contains(pushVersionKey) {
            checking.insert(primaryState.localDeviceName)
        }
        return DevicesPagePresentation.versionRows(
            cards: identityCards,
            autosync: autosyncStatus,
            versionReceipts: Array(latestSyncReceipts.values),
            checkingDeviceNames: checking,
            now: now()
        )
    }

    private var dataDeviceRows: [DevicesDataDeviceRowModel] {
        let syncing = Set(
            pendingSyncIntents.values.compactMap { intent -> String? in
                DeviceSyncAction.canonicalArtifactValue(intent.action) == "system-pull"
                    ? intent.target
                    : nil
            }
        )
        return DevicesPagePresentation.dataDeviceRows(
            cards: identityCards,
            dataReceipts: Array(latestSyncReceipts.values),
            syncingDeviceNames: syncing,
            now: now()
        )
    }

    private var versionActionEnabled: Bool {
        DevicesBatchInclusionStore.actionEnabled(
            deviceNames: versionRows.map(\.deviceName),
            excluded: versionExcluded
        )
    }

    private var dataActionEnabled: Bool {
        DevicesBatchInclusionStore.actionEnabled(
            deviceNames: dataDeviceRows.map(\.deviceName),
            excluded: dataExcluded
        )
    }

    private var identityStrip: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DevicesPagePresentation.nameplateTitle)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(DevicesPagePresentation.nameplateSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        newDeviceName = ""
                        copiedEnrollCommand = false
                        requestNewPairing()
                        showAddDeviceSheet = true
                    } label: {
                        Text("配對")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(LiquidGlassTokens.brandAccent)
                    .opacity(0.72)
                    .help("新增設備")
                }
                ForEach(identityCards) { card in
                    DeviceIdentityCard(
                        model: card,
                        transferPending: pendingLocalActionKeys.contains("set-primary::\(card.displayName)"),
                        onTransferPrimary: card.isLocal || card.isPrimary
                            ? nil
                            : { transferPrimary(to: card.displayName) }
                    )
                }
            }
        }
    }

    // MARK: - ① 版本同步

    private var versionSyncSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                DevicesSectionHeader(
                    index: "①",
                    title: "版本同步",
                    actionTitle: "更新",
                    actionEnabled: versionActionEnabled,
                    onAction: performSelectedVersionUpdates
                )
                ForEach(versionRows) { row in
                    DeviceVersionRow(
                        model: row,
                        isIncluded: inclusionBinding(
                            deviceName: row.deviceName,
                            kind: .version
                        )
                    )
                }
                if let cli = DevicesPagePresentation.cliVersionInfo(registry: syncRegistry) {
                    Divider().opacity(0.25)
                    DeviceCLIVersionInfoRow(model: cli)
                }
                Text(DevicesPagePresentation.versionStopCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - ② 資料同步

    private var dataSyncSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                DevicesSectionHeader(
                    index: "②",
                    title: "資料同步",
                    actionTitle: "同步",
                    actionEnabled: dataActionEnabled,
                    onAction: performSelectedDataSyncs
                )
                ForEach(dataDeviceRows) { row in
                    DeviceDataDeviceRow(
                        model: row,
                        isIncluded: inclusionBinding(
                            deviceName: row.deviceName,
                            kind: .data
                        )
                    )
                }
                if !dataDeviceRows.isEmpty && !displayedDataModules.isEmpty {
                    Divider().opacity(0.25)
                }
                ForEach(displayedDataModules) { module in
                    DeviceDataModuleRow(
                        model: module,
                        isReasonExpanded: expandedFailedModuleIDs.contains(module.id),
                        onToggle: { enabled in setModuleEnabled(module.id, enabled) },
                        onToggleReason: {
                            if expandedFailedModuleIDs.contains(module.id) {
                                expandedFailedModuleIDs.remove(module.id)
                            } else {
                                expandedFailedModuleIDs.insert(module.id)
                            }
                        }
                    )
                }
                Text(DevicesPagePresentation.secretsCaption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Secondary admin (claim / pairing leftovers)

    private var secondaryAdminSection: some View {
        Group {
            if !primaryState.isLocalPrimary {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本機目前是副設備")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button(action: claimPrimaryForSelf) {
                                if pendingLocalActionKeys.contains(selfClaimKey) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("設為主設備")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(LiquidGlassTokens.brandAccent)
                            .disabled(pendingLocalActionKeys.contains(selfClaimKey))
                            .opacity(0.72)
                        }
                        if let receipt = selfClaimReceipt, receipt.result == "failure" {
                            Text(receipt.message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let receipt = pushVersionReceipt, receipt.result == "failure" {
                            Text("回傳失敗：\(receipt.message)")
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var selfClaimKey: String { "set-primary::\(primaryState.localDeviceName)" }
    private var pushVersionKey: String { "push-version::-" }

    private func claimPrimaryForSelf() {
        pendingLocalActionKeys.insert(selfClaimKey)
        selfClaimReceipt = nil
        do {
            try localActionStore.enqueue(kind: .setPrimary, target: primaryState.localDeviceName)
        } catch {
            pendingLocalActionKeys.remove(selfClaimKey)
            selfClaimReceipt = DeviceLocalActionReceipt(
                kind: TatwoDeviceLocalActionKind.setPrimary.rawValue,
                target: primaryState.localDeviceName,
                requestedAt: Date(),
                result: "failure",
                completedAt: Date(),
                message: error.localizedDescription,
                pairingSeed: nil,
                pairingExpiresAt: nil
            )
        }
    }

    private func pushVersion() {
        pendingLocalActionKeys.insert(pushVersionKey)
        pushVersionReceipt = nil
        do {
            try localActionStore.enqueue(kind: .pushVersion)
        } catch {
            pendingLocalActionKeys.remove(pushVersionKey)
            pushVersionReceipt = DeviceLocalActionReceipt(
                kind: TatwoDeviceLocalActionKind.pushVersion.rawValue,
                target: nil,
                requestedAt: Date(),
                result: "failure",
                completedAt: Date(),
                message: error.localizedDescription,
                pairingSeed: nil,
                pairingExpiresAt: nil
            )
        }
    }

    private func inclusionBinding(
        deviceName: String,
        kind: DevicesBatchInclusionKind
    ) -> Binding<Bool> {
        Binding(
            get: {
                switch kind {
                case .version:
                    DevicesBatchInclusionStore.isIncluded(
                        deviceName: deviceName,
                        excluded: versionExcluded
                    )
                case .data:
                    DevicesBatchInclusionStore.isIncluded(
                        deviceName: deviceName,
                        excluded: dataExcluded
                    )
                }
            },
            set: { setBatchIncluded($0, deviceName: deviceName, kind: kind) }
        )
    }

    private func setBatchIncluded(
        _ included: Bool,
        deviceName: String,
        kind: DevicesBatchInclusionKind
    ) {
        switch kind {
        case .version:
            DevicesBatchInclusionStore.setIncluded(
                included,
                deviceName: deviceName,
                excluded: &versionExcluded
            )
            DevicesBatchInclusionStore.saveExcluded(versionExcluded, kind: .version)
        case .data:
            DevicesBatchInclusionStore.setIncluded(
                included,
                deviceName: deviceName,
                excluded: &dataExcluded
            )
            DevicesBatchInclusionStore.saveExcluded(dataExcluded, kind: .data)
        }
    }

    private func performSelectedVersionUpdates() {
        let selected = Set(
            DevicesBatchInclusionStore.selectedDeviceNames(
                versionRows.map(\.deviceName),
                excluded: versionExcluded
            )
        )
        for row in versionRows where selected.contains(row.deviceName) {
            checkForUpdate(deviceName: row.deviceName, isLocal: row.isLocal)
        }
    }

    private func performSelectedDataSyncs() {
        let selected = Set(
            DevicesBatchInclusionStore.selectedDeviceNames(
                dataDeviceRows.map(\.deviceName),
                excluded: dataExcluded
            )
        )
        for row in dataDeviceRows where selected.contains(row.deviceName) {
            syncData(deviceName: row.deviceName)
        }
    }

    private func syncData(deviceName: String) {
        dispatchSync(kind: .data, targets: [deviceName])
        refreshModuleRows()
    }

    private func checkForUpdate(deviceName: String, isLocal: Bool) {
        if isLocal {
            versionCheckPending = true
        }
        if let registry = syncRegistry {
            try? runtimeStore.markSyncing(moduleID: "os-app-version", registry: registry, now: now())
        }
        if isLocal {
            if primaryState.isLocalPrimary {
                autosyncStatus.lastCheckAt = now()
            } else {
                pushVersion()
            }
        } else {
            dispatchSync(kind: .version, targets: [deviceName])
        }
        refreshModuleRows()
    }

    private func setModuleEnabled(_ moduleID: String, _ enabled: Bool) {
        guard let registry = syncRegistry else { return }
        for sourceID in DevicesPagePresentation.enablementModuleIDs(forPresentedID: moduleID) {
            do {
                try enablementStore.setEnabled(
                    enabled,
                    moduleID: sourceID,
                    registry: registry,
                    now: now()
                )
            } catch {
                try? runtimeStore.markFailed(
                    moduleID: sourceID,
                    reason: error.localizedDescription,
                    registry: registry,
                    now: now()
                )
            }
        }
        refreshModuleRows()
    }

    private func refreshModuleRows() {
        dataModules = DevicesPagePresentation.dataModuleRows(
            registry: syncRegistry,
            enablement: enablementStore,
            runtime: runtimeStore
        )
        if let registry = syncRegistry {
            reconcileVersionRuntime(registry: registry)
        }
    }

    private func reconcileVersionRuntime(registry: TatwoSyncModulesRegistry) {
        let pendingVersion = pendingSyncIntents.values.contains {
            DeviceSyncAction.canonicalArtifactValue($0.action) == "version-pull"
        }
        if pendingVersion {
            versionCheckPending = true
            return
        }
        guard versionCheckPending else { return }
        let versionReceipts = latestSyncReceipts.values.filter {
            DeviceSyncAction.canonicalArtifactValue($0.action) == "version-pull"
        }
        if let failed = versionReceipts
            .sorted(by: { $0.completedAt > $1.completedAt })
            .first(where: { $0.result == "failure" })
        {
            versionCheckPending = false
            let reason = failed.message
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "version-pull failed"
            try? runtimeStore.markFailed(
                moduleID: "os-app-version",
                reason: reason,
                lastSyncAt: failed.completedAt,
                registry: registry,
                now: now()
            )
            return
        }
        versionCheckPending = false
        let stamp = versionReceipts.map(\.completedAt).max() ?? now()
        try? runtimeStore.markIdle(
            moduleID: "os-app-version",
            lastSyncAt: stamp,
            registry: registry,
            now: now()
        )
    }

    private func transferPrimary(to target: String) {
        let key = "set-primary::\(target)"
        pendingLocalActionKeys.insert(key)
        do {
            try localActionStore.enqueue(kind: .setPrimary, target: target)
        } catch {
            pendingLocalActionKeys.remove(key)
            latestTransferReceipts[target] = DeviceLocalActionReceipt(
                kind: TatwoDeviceLocalActionKind.setPrimary.rawValue,
                target: target,
                requestedAt: Date(),
                result: "failure",
                completedAt: Date(),
                message: error.localizedDescription,
                pairingSeed: nil,
                pairingExpiresAt: nil
            )
        }
    }

    private func dispatchSync(kind: TatwoSyncActionKind, targets: Set<String>) {
        for target in targets {
            let key = DeviceSyncOperationKey(target: target, action: kind.rawValue)
            do {
                let intent = try outboxStore.enqueue(target: target, action: kind.rawValue)
                pendingSyncIntents[key] = intent
            } catch {
                latestSyncReceipts[key] = DeviceSyncReceipt(
                    target: target,
                    action: kind.rawValue,
                    requestedAt: Date(),
                    result: "failure",
                    completedAt: Date(),
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - 新增設備（限時配對代碼）
    //
    // 設計上不依賴任何「請求時間戳」比對——那種寫法在畫面重繪／切換分頁導致
    // @State 重置時會誤判成失敗（已實測踩到）。改成每次都直接查磁碟上現有的
    // receipts，找「尚未過期的成功配對碼」就直接用；找不到才真的去產生新的。
    // 沒有查到 ≠ 失敗，只代表「還沒查到」，畫面上不使用未經證實的「失敗」字眼。

    private func checkForUsablePairing() -> Bool {
        let now = Date()
        let pairingReceipts = (try? localActionStore.receipts(kind: .createPairing)) ?? []
        guard let usable = pairingReceipts.first(where: {
            $0.result == "success" && ($0.pairingExpiresAt ?? .distantPast) > now
        }) else {
            return false
        }
        pairingSeed = usable.pairingSeed
        pairingExpiresAt = usable.pairingExpiresAt
        pairingPending = false
        return true
    }

    private func requestNewPairing() {
        pairingEnqueueError = nil
        if checkForUsablePairing() { return }
        pairingSeed = nil
        pairingExpiresAt = nil
        pairingPending = true
        pairingWaitStartedAt = Date()
        do {
            try localActionStore.enqueue(kind: .createPairing)
        } catch {
            pairingPending = false
            pairingEnqueueError = error.localizedDescription
        }
    }

    private var addDeviceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增設備")
                .font(.system(size: 14, weight: .bold, design: .rounded))

            if let seed = pairingSeed, let expiresAt = pairingExpiresAt {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let remaining = Int(expiresAt.timeIntervalSince(context.date).rounded(.up))
                    if remaining > 0 {
                        pairingActiveContent(seed: seed, remainingSeconds: remaining)
                    } else {
                        pairingExpiredContent
                    }
                }
            } else if let enqueueError = pairingEnqueueError {
                Text("無法產生配對代碼：\(enqueueError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重試", action: requestNewPairing)
                    .buttonStyle(.bordered)
            } else {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let waited = pairingWaitStartedAt.map { Int(context.date.timeIntervalSince($0)) } ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(waited > 0 ? "產生配對代碼中…（已等待 \(waited) 秒）" : "產生配對代碼中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("由本機常駐服務處理，通常在數十秒內完成。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("完成") { showAddDeviceSheet = false }
                    .buttonStyle(.borderedProminent)
                    .tint(LiquidGlassTokens.brandAccent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task { _ = checkForUsablePairing() }
    }

    private func pairingActiveContent(seed: String, remainingSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("配對代碼剩餘 \(remainingSeconds) 秒（限時、僅此一次有效）")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Text("在新設備自己的終端機貼上這行（僅此設備需要跑一次，之後永遠自動同步）：")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("設備名稱", text: $newDeviceName)
                .textFieldStyle(.roundedBorder)
            TextField(
                "私人熱同步 remote（例：git@sync-host:tatwo/hot-sync.git）",
                text: $newDeviceChannelRemote
            )
            .textFieldStyle(.roundedBorder)
            if !TatwoDeviceEnrollmentCommand.isAllowedPrivateChannelRemote(
                newDeviceChannelRemote.trimmingCharacters(in: .whitespacesAndNewlines)
            ) {
                Text("必須填 SSH／file 私人 remote；HTTP(S) GitHub URL 只可作冷備份。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            let enrollCommand = TatwoDeviceEnrollmentCommand.command(
                deviceName: newDeviceName,
                pairingSeed: seed,
                channelRemote: newDeviceChannelRemote
            )
            HStack(spacing: 8) {
                Text(enrollCommand ?? "先填入私人熱同步 remote，才會產生納管指令。")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                Button {
                    guard let command = enrollCommand else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedEnrollCommand = true
                } label: {
                    Image(systemName: copiedEnrollCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(copiedEnrollCommand ? .green : LiquidGlassTokens.brandAccent)
                .disabled(enrollCommand == nil)
            }
        }
    }

    private var pairingExpiredContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("配對代碼已過期，請重新產生。")
                .font(.caption)
                .foregroundStyle(.red)
            Button("重新產生", action: requestNewPairing)
                .buttonStyle(.borderedProminent)
                .tint(LiquidGlassTokens.brandAccent)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }

    // MARK: - 狀態刷新

    private func installSyncProgressSnapshotFixture() {
        let target = "MacBook Air"
        let fixtureNow = Self.exportSyncFixtureReferenceDate
        let requestedAt = fixtureNow.addingTimeInterval(-68)
        let key = DeviceSyncOperationKey(
            target: target,
            action: DeviceSyncAction.canonicalRequestValue("version-pull")
                ?? "version-pull"
        )
        primaryState = DevicesExportSyncFixture.primaryState()
        secondaryDevices = DevicesExportSyncFixture.secondaryDevices()
        pendingSyncIntents = [:]
        latestSyncReceipts = [
            key: DeviceSyncReceipt(
                target: target,
                action: key.action,
                requestedAt: requestedAt,
                result: "converged",
                completedAt: fixtureNow,
                message: "version-pull verified",
                phase: .converged,
                requestID: "snapshot-version-check",
                authorityEpoch: 7,
                ledgerSequence: 42,
                authorityPrimary: "Mac mini",
                sourceDeviceID: "device-mac-mini",
                targetDeviceID: "device-macbook-air",
                catalogRevision:
                    DeviceSyncCatalogProjection.currentRevision ?? "snapshot",
                sourceDigest: "aaaaaaaaaaaaaaaa",
                appliedDigest: "bbbbbbbbbbbbbbbb")
        ]
        autosyncStatus = DevicesExportSyncFixture.autosync()
        localInventory = DevicesExportSyncFixture.localInventoryForDisplay()
        refreshModuleRows()
    }

    private func refreshVisibleState() {
        if shouldInstallSyncProgressSnapshotFixture {
            installSyncProgressSnapshotFixture()
        } else {
            refreshState()
        }
    }

    private func refreshState() {
        primaryState = TatwoFlexPrimaryReader.read()

        let allEnrolled = (try? outboxStore.enrolledDevices()) ?? []
        if let currentPrimaryName = primaryState.currentPrimaryName {
            secondaryDevices = allEnrolled.filter { $0.name != currentPrimaryName }
        } else {
            secondaryDevices = (try? outboxStore.secondaryDevices()) ?? []
        }
        let verifiedSnapshot = deviceSnapshotProvider.verifiedSnapshot()
        verifiedDomainDevices = verifiedSnapshot?.devices ?? []
        let leaseReadiness = TatwoActiveOriginLeaseProjector.project(
            snapshotProvider: deviceSnapshotProvider,
            stateRootURL: remoteComputeStateRootURL,
            now: now())
        let definitiveLeaseLossBlocker: String?
        switch leaseReadiness {
        case .activeLeaseUnavailable,
             .activeLeaseExpired,
             .splitBrain,
             .localDeviceIsNotOrigin:
            definitiveLeaseLossBlocker =
                leaseReadiness.userFacingBlocker
                    ?? ChatRemoteTurnDispatchBlocker.targetLeaseLost.rawValue
        case .ready,
             .verifiedSnapshotUnavailable,
             .invalidVerifiedSnapshot,
             .localDeviceIDUnavailable:
            definitiveLeaseLossBlocker = nil
        }
        chatModel.revalidatePendingRemoteTarget(
            verifiedTargetDeviceIDs: verifiedSnapshot.map {
                Set($0.devices.map(\.id))
            },
            definitiveLeaseLossBlocker: definitiveLeaseLossBlocker)

        let pendingIntents = (try? outboxStore.pendingIntents()) ?? []
        pendingSyncIntents = DeviceSyncOperationIndex.latestPending(pendingIntents)
        let receipts = (try? outboxStore.receiptLoadResult().receipts) ?? []
        latestSyncReceipts = DeviceSyncOperationIndex.latestReceipts(receipts)

        let pendingLocal = (try? localActionStore.pendingIntents()) ?? []
        var stillPending: Set<String> = []
        for intent in pendingLocal {
            stillPending.insert("\(intent.kind)::\(intent.target ?? "-")")
        }
        pendingLocalActionKeys = stillPending

        let transferReceipts = (try? localActionStore.receipts(kind: .setPrimary)) ?? []
        var transferByTarget: [String: DeviceLocalActionReceipt] = [:]
        for receipt in transferReceipts {
            let target = receipt.target ?? "-"
            if transferByTarget[target] == nil { transferByTarget[target] = receipt }
        }
        latestTransferReceipts = transferByTarget
        selfClaimReceipt = transferByTarget[primaryState.localDeviceName]

        pushVersionReceipt = (try? localActionStore.latestReceipt(kind: .pushVersion)) ?? nil

        if pairingPending {
            _ = checkForUsablePairing()
        }

        localInventory = TatwoDeviceHostInventoryCollector.collectOnce(
            connectionStatus: .local
        )
        autosyncStatus = TatwoAutosyncStatusReader.read(
            appSupportRoot: DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
        )
        peerInventories = DevicesPagePresentation.loadPeerInventories(
            appSupportRoot: DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
        )
        refreshModuleRows()
    }
}
