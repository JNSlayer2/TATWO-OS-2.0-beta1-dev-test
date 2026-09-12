import SwiftUI
import TatwoDomainContracts
import TatwoUltraworkCore

/// App-visible readback for the App-owned pressure monitor.
///
/// This card is display-only for admission: it reads `TatwoAppPressureRuntimeRegistry` and
/// the runtime's own `TatwoPressureUIProjectionV1`. Loop admission still goes
/// through `TatwoAppPressureAdmissionBridgeV1`, which re-samples through the
/// App-owned runtime before spawn and never trusts this view state.
struct DevicePressureMonitorCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private let outboxStore: DeviceSyncOutboxStore
    private let remoteAuthorizationStore: TatwoRemoteBorrowAuthorizationStore
    private let deviceSnapshotProvider: any DomainDeviceSnapshotProvider
    private let now: () -> Date

    @State private var projection = TatwoPressureUIProjectionV1(
        deviceID: "local-device",
        displayClassification: .unknown,
        lastObservedAt: nil,
        activeLoopID: nil,
        workerIDs: [],
        stopReason: "monitor_unknown",
        canRequestLightLoop: false,
        canRequestHeavyLoop: false
    )
    @State private var runtimeRunning = false
    @State private var registryGeneration: UInt64?
    @State private var lastReadbackAt: Date?
    @State private var primaryState: TatwoFlexPrimaryState = TatwoFlexPrimaryReader.read()
    @State private var secondaryDevices: [EnrolledDevice] = []
    @State private var verifiedDomainDevices: [TatwoDomainDeviceV1] = []
    @State private var localInventory: TatwoDeviceHostInventoryV1?
    @State private var peerInventories: [TatwoDevicePeerInventoryRecordV1] = []
    @State private var remoteExecutionPolicies:
        [String: TatwoRemoteDeviceExecutionPolicyV1] = [:]
    @State private var remoteBorrowMessages: [String: String] = [:]
    @State private var remoteBorrowErrorTargets: Set<String> = []

    init(
        outboxStore: DeviceSyncOutboxStore = DeviceSyncOutboxStore(),
        remoteAuthorizationStore: TatwoRemoteBorrowAuthorizationStore = .default(),
        deviceSnapshotProvider: any DomainDeviceSnapshotProvider =
            TatwoDevicesCompositionRoot.makeProvider(),
        now: @escaping () -> Date = Date.init
    ) {
        self.outboxStore = outboxStore
        self.remoteAuthorizationStore = remoteAuthorizationStore
        self.deviceSnapshotProvider = deviceSnapshotProvider
        self.now = now

        if DevicesExportSyncFixture.isActive() {
            _primaryState = State(initialValue: DevicesExportSyncFixture.primaryState())
            _secondaryDevices = State(
                initialValue: DevicesExportSyncFixture.secondaryDevices()
            )
            _localInventory = State(
                initialValue: DevicesExportSyncFixture.localInventoryForDisplay()
            )
        } else {
            _localInventory = State(
                initialValue: TatwoDeviceHostInventoryCollector.collectOnce(
                    connectionStatus: .local
                )
            )
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                DevicesSectionHeader(index: "③", title: "Loops 派送與壓力")
                ForEach(pressureCards) { card in
                    pressureDeviceCard(card)
                }
            }
        }
        .task {
            refreshDevices()
            await refreshProjection()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                refreshDevices()
                await refreshProjection()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Loops 派送與壓力，\(runtimeRunning ? "monitor 運作中" : "monitor 未開啟")"
                + (registryGeneration.map { "，registry \($0)" } ?? "")
        )
    }

    private var pressureCards: [DevicesPressureCardModel] {
        let resolvedInventory = DevicesPagePresentation.mergedHostInventory(
            collected: localInventory
                ?? TatwoDeviceHostInventoryCollector.collectOnce(
                    connectionStatus: .local
                ),
            projected: DevicesExportSyncFixture.isActive()
                ? DevicesExportSyncFixture.localInventory()
                : projection.hostInventory
        )
        let identities = DevicesPagePresentation.identityCards(
            primary: primaryState,
            enrolled: secondaryDevices,
            verified: verifiedDomainDevices,
            localInventory: resolvedInventory,
            localAppVersion: DevicesPagePresentation.localAppVersion()
                ?? (DevicesExportSyncFixture.isActive()
                    ? DevicesExportSyncFixture.autosync().lastInstalledCommit
                    : nil),
            peerInventories: peerInventories,
            now: now()
        )
        return DevicesPagePresentation.pressureCards(
            identityCards: identities,
            localInventory: resolvedInventory,
            localProjection: projection,
            peerInventories: peerInventories,
            now: now()
        )
    }

    private func pressureDeviceCard(_ card: DevicesPressureCardModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor(card.connection))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(card.displayName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(card.localityLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        LiquidGlassTokens.tint.opacity(LiquidGlassTokens.chipFillOpacity),
                        in: Capsule()
                    )
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if card.isLocal {
                    Text(classificationTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            classificationColor.opacity(
                                classificationColor == .yellow ? 0.16 : LiquidGlassTokens.chipFillOpacity
                            ),
                            in: Capsule()
                        )
                        .foregroundStyle(classificationColor)
                }
            }

            Text(DevicesPagePresentation.hardwareLine(
                model: card.hardwareModel,
                chip: card.chipName,
                ramLabel: card.ramLabel
            ))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .opacity(card.isInventoryStale ? 0.4 : 1)

            HStack(spacing: 6) {
                DevicePressureMetricChip(
                    label: "CPU",
                    value: card.cpuPercentLabel ?? "—"
                )
                DevicePressureMetricChip(
                    label: "內存",
                    value: pressureLabel(card.pressureLevel),
                    tint: pressureColor(card.pressureLevel)
                )
                DevicePressureMetricChip(
                    label: "連線",
                    value: card.connection.label,
                    tint: connectionColor(card.connection)
                )
                DevicePressureMetricChip(
                    label: "Loops",
                    value: card.activeLoopCount.map(String.init) ?? "—"
                )
                Spacer(minLength: 0)
            }
            .opacity(card.isInventoryStale ? 0.4 : 1)

            if let updated = card.inventoryUpdatedLabel {
                Text(updated)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if card.isLocal {
                Text(
                    DevicesPagePresentation.admissionCaption(
                        canRequestLight: card.canRequestLightLoop ?? projection.canRequestLightLoop,
                        canRequestHeavy: card.canRequestHeavyLoop ?? projection.canRequestHeavyLoop
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if card.showsDispatch {
                dispatchControls(for: card)
            }
        }
        .padding(10)
        .background(
            LiquidGlassTokens.tint.opacity(LiquidGlassTokens.subtleFillOpacity),
            in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(card.displayName)，\(card.localityLabel)，連線 \(card.connection.label)"
        )
    }

    @ViewBuilder
    private func dispatchControls(for card: DevicesPressureCardModel) -> some View {
        let canonicalTargetDeviceID = canonicalTargetDeviceID(for: card)
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "允許自動借用",
                isOn: autoBorrowBinding(
                    displayName: card.displayName,
                    targetDeviceID: canonicalTargetDeviceID
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("只允許低風險工作；每個 Chat Session 仍保留獨立授權，高風險工作一律逐次確認。")
            .disabled(canonicalTargetDeviceID == nil)

            if let message = remoteBorrowMessages[card.displayName] {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(
                        remoteBorrowErrorTargets.contains(card.displayName) ? .red : .secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            } else if canonicalTargetDeviceID == nil {
                Text("尚未取得這台設備的已驗證 ID。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var classificationColor: Color {
        switch projection.displayClassification {
        case .yellow: return .yellow
        case .green, .red, .unknown: return .secondary
        }
    }

    private var classificationTitle: String {
        switch projection.displayClassification {
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .unknown: return "Unknown"
        }
    }

    private func connectionColor(_ connection: DevicesConnectionPresentation) -> Color {
        switch connection {
        case .connected: .green
        case .syncing, .offline, .unknown: .secondary
        }
    }

    private func pressureLabel(_ level: TatwoHostMemoryPressureLevelV1?) -> String {
        switch level {
        case .normal: "正常"
        case .warn: "警告"
        case .urgent: "緊迫"
        case .critical: "危急"
        case .unknown, nil: "—"
        }
    }

    private func pressureColor(_ level: TatwoHostMemoryPressureLevelV1?) -> Color {
        switch level {
        case .warn: .yellow
        case .normal, .urgent, .critical, .unknown, nil: .secondary
        }
    }

    @MainActor
    private func refreshProjection() async {
        if DevicesExportSyncFixture.isActive() {
            localInventory = DevicesExportSyncFixture.localInventoryForDisplay()
            return
        }
        let readback = await TatwoAppPressureAdmissionBridgeV1.currentReadback()
        projection = readback.projection
        runtimeRunning = readback.runtimeRunning
        registryGeneration = readback.registryGeneration
        lastReadbackAt = Date()
        localInventory = DevicesPagePresentation.mergedHostInventory(
            collected: TatwoDeviceHostInventoryCollector.collectOnce(
                activeLoopCount: TatwoDeviceHostInventoryV1.activeLoopCount(
                    workers: [],
                    activeLoopID: readback.projection.activeLoopID
                ),
                connectionStatus: .local
            ),
            projected: readback.projection.hostInventory
        )
    }

    private func refreshDevices() {
        if DevicesExportSyncFixture.isActive() {
            primaryState = DevicesExportSyncFixture.primaryState()
            secondaryDevices = DevicesExportSyncFixture.secondaryDevices()
            if localInventory == nil {
                localInventory = DevicesExportSyncFixture.localInventoryForDisplay()
            }
            return
        }
        primaryState = TatwoFlexPrimaryReader.read()
        let allEnrolled = (try? outboxStore.enrolledDevices()) ?? []
        if let currentPrimaryName = primaryState.currentPrimaryName {
            secondaryDevices = allEnrolled.filter { $0.name != currentPrimaryName }
        } else {
            secondaryDevices = (try? outboxStore.secondaryDevices()) ?? []
        }
        let verifiedSnapshot = deviceSnapshotProvider.verifiedSnapshot()
        verifiedDomainDevices = verifiedSnapshot?.devices ?? []
        peerInventories = DevicesPagePresentation.loadPeerInventories(
            appSupportRoot: DeviceSyncOutboxStore.defaultApplicationSupportRootPublic()
        )
        remoteExecutionPolicies = Dictionary(
            uniqueKeysWithValues: secondaryDevices.compactMap { device in
                guard let targetDeviceID = canonicalTargetDeviceID(named: device.name) else {
                    return nil
                }
                return try? (
                    targetDeviceID,
                    remoteAuthorizationStore.devicePolicy(
                        targetDeviceID: targetDeviceID
                    )
                )
            }
        )
    }

    private func canonicalTargetDeviceID(for card: DevicesPressureCardModel) -> String? {
        if DevicesPagePresentation.isBorrowableDeviceID(card.id),
           card.id.caseInsensitiveCompare(card.displayName) != .orderedSame
        {
            return card.id
        }
        return DevicesPagePresentation.borrowTargetDeviceID(
            displayName: card.displayName,
            verified: verifiedDomainDevices,
            enrolled: secondaryDevices,
            peerInventories: peerInventories
        )
    }

    private func canonicalTargetDeviceID(named displayName: String) -> String? {
        if let card = pressureCards.first(where: {
            $0.displayName.caseInsensitiveCompare(displayName) == .orderedSame
        }) {
            return canonicalTargetDeviceID(for: card)
        }
        return DevicesPagePresentation.borrowTargetDeviceID(
            displayName: displayName,
            verified: verifiedDomainDevices,
            enrolled: secondaryDevices,
            peerInventories: peerInventories
        )
    }

    private func autoBorrowBinding(
        displayName: String,
        targetDeviceID: String?
    ) -> Binding<Bool> {
        Binding(
            get: {
                guard let targetDeviceID else { return false }
                return remoteExecutionPolicies[targetDeviceID]?.autoBorrowEnabled ?? false
            },
            set: { enabled in
                guard let targetDeviceID else { return }
                setAutoBorrow(
                    enabled,
                    displayName: displayName,
                    targetDeviceID: targetDeviceID
                )
            }
        )
    }

    private func setAutoBorrow(
        _ enabled: Bool,
        displayName: String,
        targetDeviceID: String
    ) {
        do {
            let policy = try remoteAuthorizationStore.setAutoBorrow(
                targetDeviceID: targetDeviceID,
                enabled: enabled
            )
            remoteExecutionPolicies[targetDeviceID] = policy
            remoteBorrowErrorTargets.remove(displayName)
            remoteBorrowMessages[displayName] = enabled
                ? "已允許新的低風險工作自動借用；每個 Session 仍需自己的授權。"
                : "已停止新的自動借用；已在執行中的工作不會被強制中斷。"
        } catch {
            remoteBorrowErrorTargets.insert(displayName)
            remoteBorrowMessages[displayName] =
                "無法更新借用規範：\(error.localizedDescription)"
        }
    }
}
