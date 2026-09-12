import SwiftUI
import AppKit
import TatwoUltraworkCore

enum ModesIssuedIntegrityState: Equatable, Sendable {
    case noPointer
    case validated
    case revisionRequired(String)
    case blocked(String)
}

struct ModesScenarioAuthorityPresentation: Equatable, Sendable {
    let previewScenarioProfileID: String
    let previewContract: TatwoWorkOSContractV1?
    let previewModePlan: ModeIdentityPlan?
    let previewIssue: String?
    let issuedContract: TatwoWorkOSContractV1?
    let issuedIntegrityState: ModesIssuedIntegrityState
    let mismatchMessage: String?

    var canRequestGoalRevision: Bool {
        guard issuedContract != nil else { return false }
        switch issuedIntegrityState {
        case .validated, .revisionRequired:
            return true
        case .noPointer, .blocked:
            return false
        }
    }

    static func make(
        previewMode: WorkModeID,
        previewScenarioProfileID: String,
        scenarioBook: TatwoScenarioConfigBookV1,
        selectedPresetID: String = "recommended",
        customLoopIDs: [String]? = nil,
        issuedContract: TatwoWorkOSContractV1?,
        issuedIntegrityState: ModesIssuedIntegrityState
    ) -> ModesScenarioAuthorityPresentation {
        let previewResult: (
            contract: TatwoWorkOSContractV1?,
            modePlan: ModeIdentityPlan?,
            issue: String?
        )
        do {
            let contract = try WorkOSFactory.preview(
                mode: previewMode,
                scenarioProfileID: previewScenarioProfileID,
                objective: "App modes Work OS preview",
                scenarioBook: scenarioBook,
                loopPresetID: selectedPresetID,
                enabledLoopTemplateIDs:
                    selectedPresetID == "custom" ? customLoopIDs : nil
            )
            let plan = try WorkOSFactory.previewModePlan(
                mode: previewMode,
                scenarioProfileID: previewScenarioProfileID,
                scenarioBook: scenarioBook,
                contract: contract
            )
            previewResult = (contract, plan, nil)
        } catch {
            previewResult = (
                nil,
                nil,
                TatwoPrivacyRedactor.redacted(error.localizedDescription)
            )
        }
        let previewContract = previewResult.contract
        let previewModePlan = previewResult.modePlan
        let previewIssue = previewResult.issue

        let normalizedIssuedContract: TatwoWorkOSContractV1?
        let normalizedIntegrityState: ModesIssuedIntegrityState
        switch issuedIntegrityState {
        case .validated:
            if let issuedContract {
                normalizedIssuedContract = issuedContract
                normalizedIntegrityState = .validated
            } else {
                normalizedIssuedContract = nil
                normalizedIntegrityState = .blocked(
                    "current-session marked validated without an exact contract")
            }
        case .noPointer:
            normalizedIssuedContract = nil
            normalizedIntegrityState = .noPointer
        case .revisionRequired(let issue):
            if let issuedContract {
                normalizedIssuedContract = issuedContract
                normalizedIntegrityState = .revisionRequired(
                    TatwoPrivacyRedactor.redacted(issue))
            } else {
                normalizedIssuedContract = nil
                normalizedIntegrityState = .blocked(
                    "current-session requires revision without an exact issued contract")
            }
        case .blocked(let issue):
            normalizedIssuedContract = nil
            normalizedIntegrityState = .blocked(
                TatwoPrivacyRedactor.redacted(issue))
        }

        let mismatchMessage: String?
        let issuedDiffersFromPreview =
            normalizedIssuedContract.map {
                $0.mode != previewMode
                    || $0.scenario != previewScenarioProfileID
            } ?? false
        if let normalizedIssuedContract, issuedDiffersFromPreview {
            mismatchMessage =
                "預覽 \(previewMode.rawValue)/\(previewScenarioProfileID)；"
                + "目前 Session \(normalizedIssuedContract.mode.rawValue)/"
                + normalizedIssuedContract.scenario
        } else {
            mismatchMessage = nil
        }

        return ModesScenarioAuthorityPresentation(
            previewScenarioProfileID: previewScenarioProfileID,
            previewContract: previewContract,
            previewModePlan: previewModePlan,
            previewIssue: previewIssue,
            issuedContract: normalizedIssuedContract,
            issuedIntegrityState: normalizedIntegrityState,
            mismatchMessage: mismatchMessage
        )
    }
}

private struct ModesAuthorityLaneCard: View {
    let presentation: ModesScenarioAuthorityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                authorityLane(
                    title: "Preview",
                    systemImage: "eye",
                    primary:
                        presentation.previewContract.map {
                            "\($0.mode.rawValue) · \($0.scenario)"
                        } ?? "預覽不可用",
                    secondary:
                        presentation.previewIssue.map { "規劃預覽受阻：\($0)" }
                        ?? "規劃預覽 · 不建立 Session"
                )

                Divider()

                authorityLane(
                    title: "Issued",
                    systemImage: "checkmark.seal",
                    primary: issuedPrimary,
                    secondary: issuedSecondary
                )
            }

            if let mismatchMessage = presentation.mismatchMessage {
                Text(mismatchMessage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("modes-authority-lanes")
    }

    private var issuedPrimary: String {
        switch presentation.issuedIntegrityState {
        case .validated:
            guard let contract = presentation.issuedContract else {
                return "Session blocked"
            }
            return "\(contract.mode.rawValue) · \(contract.scenario)"
        case .revisionRequired:
            guard let contract = presentation.issuedContract else {
                return "Session blocked"
            }
            return "\(contract.mode.rawValue) · \(contract.scenario) · 需 Revision"
        case .noPointer:
            return "目前無 current-session"
        case .blocked:
            return "Session blocked"
        }
    }

    private var issuedSecondary: String {
        switch presentation.issuedIntegrityState {
        case .validated:
            guard let contract = presentation.issuedContract else {
                return "缺少已驗證 contract"
            }
            return "\(contract.goalRun.status.rawValue) · #\(String(contract.contractID.prefix(10)))"
        case .revisionRequired(let issue):
            return String(TatwoPrivacyRedactor.redacted(issue).prefix(120))
        case .noPointer:
            return "沒有 issued authority"
        case .blocked(let issue):
            return String(TatwoPrivacyRedactor.redacted(issue).prefix(120))
        }
    }

    private func authorityLane(
        title: String,
        systemImage: String,
        primary: String,
        secondary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.black))
                .foregroundStyle(.secondary)
            Text(primary)
                .font(.caption.weight(.black))
                .lineLimit(1)
            Text(secondary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModesPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let modes: [WorkMode]
    let selectedMode: WorkModeID
    @Binding var previewScenarioProfileID: String
    let issuedContract: TatwoWorkOSContractV1?
    let issuedIntegrityState: ModesIssuedIntegrityState
    let onRequestGoalRevision: (TatwoGoalRevisionSelection) -> Void
    @Environment(\.tatwoSurfaceKind) private var surface
    @State private var visibleModeRaw: String = ""
    @State private var modePageVisible = false
    @State private var mountHeavyContent = Self.isSnapshotExport
    @State private var selectedPresetByMode: [String: String] = [:]
    @State private var customLoopIDsByMode: [String: [String]] = [:]
    @State private var scenarioBook = TatwoScenarioConfigDefaults.book

    private static var isSnapshotExport: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
    }

    private var visibleModeID: WorkModeID {
        WorkModeID(rawValue: visibleModeRaw) ?? selectedMode
    }

    private var visibleMode: WorkMode? {
        modes.first { $0.mode == visibleModeID } ?? modes.first
    }

    private func presetBinding(for mode: WorkModeID) -> Binding<String> {
        Binding(
            get: { selectedPresetByMode[mode.rawValue] ?? "recommended" },
            set: { selectedPresetByMode[mode.rawValue] = $0 }
        )
    }

    private func customLoopIDsBinding(for mode: WorkModeID) -> Binding<[String]> {
        Binding(
            get: {
                customLoopIDsByMode[mode.rawValue]
                    ?? WorkOSFactory.collaborationPresets(mode: mode, scenarioProfileID: previewScenarioProfileID)
                        .first { $0.id == "recommended" }?.loopTemplateIDs
                    ?? []
            },
            set: { customLoopIDsByMode[mode.rawValue] = $0 }
        )
    }

    private var previewScenarioBinding: Binding<String> {
        Binding(
            get: { previewScenarioProfileID },
            set: { scenarioID in
                guard scenarioBook.scenario(id: scenarioID) != nil else { return }
                previewScenarioProfileID = scenarioID
            }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            if let mode = visibleMode {
                let selectedPresetID = selectedPresetByMode[mode.mode.rawValue] ?? "recommended"
                let customLoopIDs = customLoopIDsByMode[mode.mode.rawValue]
                let authority = ModesScenarioAuthorityPresentation.make(
                    previewMode: mode.mode,
                    previewScenarioProfileID: previewScenarioProfileID,
                    scenarioBook: scenarioBook,
                    selectedPresetID: selectedPresetID,
                    customLoopIDs: customLoopIDs,
                    issuedContract: issuedContract,
                    issuedIntegrityState: issuedIntegrityState
                )
                let osContract =
                    (mountHeavyContent || surface == .panel)
                    ? authority.previewContract
                    : nil

                GlassCard {
                    HStack(spacing: 10) {
                        Label("預覽情境", systemImage: "eye")
                            .font(.caption.weight(.black))
                        Picker(
                            "預覽情境",
                            selection: previewScenarioBinding
                        ) {
                            ForEach(scenarioBook.scenarios) { scenario in
                                Text(scenario.displayName).tag(scenario.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .accessibilityIdentifier(
                            "modes-preview-scenario-picker")
                        Spacer(minLength: 0)
                        Badge(mode.mode.rawValue)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ModesAuthorityLaneCard(presentation: authority)

                        if let osContract {
                            WorkOSShowLoopsCard(contract: osContract)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .drawingGroup()
                        } else if surface == .window {
                            ModeSwitchSkeleton(mode: mode.mode, scenarioProfileID: previewScenarioProfileID)
                                .transition(.opacity)
                        }

                        if let plan = authority.previewModePlan {
                            ModeDashboardSurface(
                                modes: modes,
                                mode: mode,
                                selectedMode: selectedMode,
                                scenarioProfileID: previewScenarioProfileID,
                                plan: plan,
                                scenarioBook: scenarioBook,
                                selectedPresetID: presetBinding(for: mode.mode),
                                selectedLoopIDs: customLoopIDsBinding(for: mode.mode),
                                osContract: osContract,
                                canRequestRevision:
                                    authority.canRequestGoalRevision,
                                onPreviewMode: { previewMode in
                                    visibleModeRaw = previewMode.rawValue
                                },
                                onApplyMode: { applyMode in
                                    onRequestGoalRevision(
                                        TatwoGoalRevisionSelection(
                                            mode: applyMode,
                                            scenarioProfileID:
                                                previewScenarioProfileID,
                                            scenarioBook: scenarioBook,
                                            loopPresetID: selectedPresetID,
                                            enabledLoopTemplateIDs:
                                                selectedPresetID == "custom"
                                                ? customLoopIDs
                                                : nil
                                        ))
                                }
                            )
                        } else if let previewIssue = authority.previewIssue {
                            EmptyStateStrip(
                                text: "預覽受阻：\(previewIssue)")
                        }
                    }
                }
            }
        }
        .onAppear {
            modePageVisible = true
            if visibleModeRaw.isEmpty { visibleModeRaw = selectedMode.rawValue }
            mountHeavyContent = Self.isSnapshotExport || surface == .panel
            if surface == .window { scheduleHeavyContentMount() }
        }
        .task {
            let loadedBook = await Task.detached(priority: .userInitiated) {
                TatwoScenarioConfigStore.loadDefaultStaging()
            }.value
            guard !Task.isCancelled else { return }
            scenarioBook = loadedBook
        }
        .onDisappear {
            modePageVisible = false
            mountHeavyContent = false
        }
        .onChange(of: visibleModeRaw) { _, _ in
            mountHeavyContent = Self.isSnapshotExport || surface == .panel
            if surface == .window { scheduleHeavyContentMount() }
        }
    }

    private func scheduleHeavyContentMount() {
        let expectedMode = visibleModeRaw.isEmpty ? selectedMode.rawValue : visibleModeRaw
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard modePageVisible, visibleModeRaw == expectedMode else { return }
            withAnimation(modePageVisible ? .snappy(duration: 0.16) : nil) {
                mountHeavyContent = true
            }
        }
    }

    private var modeSwitchBar: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("模式切換", systemImage: "switch.2")
                        .font(.caption.weight(.black))
                    Spacer(minLength: 0)
                    Badge(previewScenarioProfileID)
                }
                Picker("模式", selection: $visibleModeRaw) {
                    ForEach(modes) { mode in
                        Text("\(mode.mode.rawValue) · \(mode.chineseName)").tag(mode.mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                modeScaleStrip
            }
        }
    }

    /// 橫式 S/M/L/XL/XXL 強度條：由 `modes` 實資料驅動，選中者高亮。
    /// 取代先前寫死且漏掉 XXL 的 badge 列。
    private var modeScaleStrip: some View {
        HStack(spacing: 6) {
            ForEach(modes) { mode in
                let isCurrent = mode.mode.rawValue == visibleModeRaw
                HStack(spacing: 4) {
                    Text(mode.mode.rawValue)
                        .font(.caption2.monospacedDigit().weight(.black))
                    Text(mode.chineseName)
                        .font(.caption2)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LiquidGlassTokens.brandAccent.opacity(isCurrent ? 0.16 : 0.06))
                }
                .contentShape(Rectangle())
                .onTapGesture { visibleModeRaw = mode.mode.rawValue }
                .accessibilityLabel("\(mode.mode.rawValue) \(mode.chineseName)")
                .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
    }

    private var windowModeSwitchBar: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 12) {
                    Label("模式切換", systemImage: "switch.2")
                        .font(.caption.weight(.black))
                    Picker("模式", selection: $visibleModeRaw) {
                        ForEach(modes) { mode in
                            Text("\(mode.mode.rawValue) · \(mode.chineseName)").tag(mode.mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Badge(previewScenarioProfileID)
                }
            }
        }
    }

    private func previewContract(for mode: WorkMode) -> TatwoWorkOSContractV1? {
        let selectedPresetID = selectedPresetByMode[mode.mode.rawValue] ?? "recommended"
        let customLoopIDs = customLoopIDsByMode[mode.mode.rawValue]
        return try? WorkOSFactory.preview(
            mode: mode.mode,
            scenarioProfileID: previewScenarioProfileID,
            objective: "App modes first-screen preview",
            scenarioBook: scenarioBook,
            loopPresetID: selectedPresetID,
            enabledLoopTemplateIDs: selectedPresetID == "custom" ? customLoopIDs : nil
        )
    }

    @ViewBuilder
    private func modeSummary(
        mode: WorkMode,
        plan: ModeIdentityPlan,
        selectedPresetID: String,
        osContract: TatwoWorkOSContractV1?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Text(mode.mode.rawValue)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .frame(width: 68, height: 68)
                    .tatwoAdaptiveMaterial(cornerRadius: 20)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(mode.chineseName)
                            .font(.title3.weight(.bold))
                        Badge(selectedPresetID == "custom" ? "自定義" : "模板")
                        if let osContract { Badge("圖 \(WorkOSFlowTemplateFactory.make(contract: osContract).nodes.count)") }
                    }
                    Text("\(mode.defaultBudget.tokenRangeLabel) · \(mode.defaultBudget.helperLimitLabel) · \(mode.defaultBudget.roundLimitLabel)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        ForEach(plan.identitySlots.prefix(4)) { slot in
                            Badge(slot.kind.chineseName)
                        }
                        if plan.identitySlots.count > 4 { Badge("+\(plan.identitySlots.count - 4)") }
                    }
                }
            }

            Button("建立 Goal revision") {
                let selectedPresetID =
                    selectedPresetByMode[mode.mode.rawValue] ?? "recommended"
                onRequestGoalRevision(
                    TatwoGoalRevisionSelection(
                        mode: mode.mode,
                        scenarioProfileID: previewScenarioProfileID,
                        scenarioBook: scenarioBook,
                        loopPresetID: selectedPresetID,
                        enabledLoopTemplateIDs:
                            selectedPresetID == "custom"
                            ? customLoopIDsByMode[mode.mode.rawValue]
                            : nil
                    ))
            }
            .font(.caption.weight(.black))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        }
    }

    @ViewBuilder
    private func identityAndStopRules(plan: ModeIdentityPlan) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.identitySlots) { slot in
                    IdentitySlotRow(slot: slot, showCandidates: true)
                }
                Divider()
                ForEach(plan.stopRules, id: \.self) { rule in
                    Label(rule, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Label("身份 / 停止條件", systemImage: "list.bullet.rectangle")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)
        }
    }
}

struct ModeSwitchSkeleton: View {
    let mode: WorkModeID
    let scenarioProfileID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Badge("載入 \(mode.rawValue)")
                Badge(scenarioProfileID)
                Spacer(minLength: 0)
            }
            Text("正在掛載 Work OS 預覽；面板首屏與快照匯出將顯示實際內容。")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tatwoAdaptiveMaterial(cornerRadius: 16)
        .help("Round 9：切模式先出骨架，延後掛載重架構圖，降低同步重算卡頓。")
    }
}




enum ModeInspectorTab: String, CaseIterable, Identifiable {
    case plan = "Plan"
    case loops = "Loops"
    case goal = "Goal"
    case receipts = "收據"
    case tools = "工具"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .plan: "rectangle.and.pencil.and.ellipsis"
        case .loops: "arrow.triangle.branch"
        case .goal: "scope"
        case .receipts: "doc.text.magnifyingglass"
        case .tools: "wrench.and.screwdriver"
        }
    }
}

struct ModeDashboardSurface: View {
    let modes: [WorkMode]
    let mode: WorkMode
    let selectedMode: WorkModeID
    let scenarioProfileID: String
    let plan: ModeIdentityPlan
    let scenarioBook: TatwoScenarioConfigBookV1
    @Binding var selectedPresetID: String
    @Binding var selectedLoopIDs: [String]
    let osContract: TatwoWorkOSContractV1?
    let canRequestRevision: Bool
    let onPreviewMode: (WorkModeID) -> Void
    let onApplyMode: (WorkModeID) -> Void

    @Environment(\.tatwoSurfaceKind) private var surface
    @State private var inspectorTab: ModeInspectorTab = .plan

    private var presets: [WorkOSCollaborationPreset] {
        WorkOSFactory.collaborationPresets(mode: mode.mode, scenarioProfileID: scenarioProfileID, scenarioBook: scenarioBook)
    }

    private var templates: [WorkOSLoopTemplate] {
        WorkOSFactory.availableLoopTemplates(mode: mode.mode, scenarioProfileID: scenarioProfileID, scenarioBook: scenarioBook)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: surface == .panel ? 10 : 14) {
            if let osContract {
                ModeDifferenceMatrix(
                    modes: modes,
                    visibleMode: mode.mode,
                    selectedMode: selectedMode,
                    scenarioProfileID: scenarioProfileID,
                    scenarioBook: scenarioBook,
                    onPreviewMode: onPreviewMode
                )

                ModeMinimalCurrentHeader(
                    mode: mode,
                    selectedMode: selectedMode,
                    scenarioProfileID: scenarioProfileID,
                    scenarioBook: scenarioBook,
                    selectedPresetID: selectedPresetID,
                    contract: osContract,
                    canRequestRevision: canRequestRevision,
                    onApplyMode: onApplyMode
                )
                .padding(.top, surface == .panel ? 2 : 0)
            } else {
                EmptyStateStrip(text: "Work OS contract 建立失敗；模式頁只顯示規劃，不可放行")
            }
        }
    }
}

struct ModeMinimalCurrentHeader: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let mode: WorkMode
    let selectedMode: WorkModeID
    let scenarioProfileID: String
    let scenarioBook: TatwoScenarioConfigBookV1
    let selectedPresetID: String
    let contract: TatwoWorkOSContractV1
    let canRequestRevision: Bool
    let onApplyMode: (WorkModeID) -> Void

    @Environment(\.tatwoSurfaceKind) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: surface == .panel ? 9 : 11) {
            HStack(alignment: .center, spacing: 12) {
                Text(mode.mode.rawValue)
                    .font(.system(size: surface == .panel ? 26 : 30, weight: .black, design: .rounded))
                    .frame(width: surface == .panel ? 50 : 58, height: surface == .panel ? 50 : 58)
                    .foregroundStyle(.white)
                    .background(modeColor.opacity(0.82), in: RoundedRectangle(cornerRadius: surface == .panel ? 16 : 18, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(mode.chineseName)
                            .font(.headline.weight(.black))
                        Badge(mode.mode == selectedMode ? "目前模式" : "預覽中")
                        Badge(contract.configStage == .staging ? "staging" : "active")
                        Badge(contract.showLoopsProjection.readOnly ? "只讀投影" : "可寫")
                    }
                    Text(configSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(surface == .panel ? 2 : 1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 0)

                Button("Revision \(mode.mode.rawValue)") {
                    onApplyMode(mode.mode)
                }
                .font(.caption.weight(.black))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canRequestRevision)
            }

            if surface == .panel {
                Divider().opacity(0.34)
                Text("流程摘要在上方卡片；此列只保留模式、情境與身份組綁定，避免重複。")
                    .font(.system(size: 10.2, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(surface == .panel ? 11 : 12)
        .background(Color.white.opacity(0.048), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(modeColor.opacity(0.14), lineWidth: 1))
    }

    private var modeColor: Color {
        switch mode.mode {
        case .s: .green
        case .m: LiquidGlassTokens.brandAccent
        case .l: LiquidGlassTokens.brandAccent
        case .xl: .indigo
        case .xxl: .purple
        }
    }

    private var scenarioName: String {
        scenarioBook.scenario(id: contract.scenario)?.displayName
            ?? TatwoIdentityCatalog.scenarioProfile(contract.scenario)?.displayName
            ?? contract.scenario
    }

    private var configSummary: String {
        let bindings = contract.loopGovernorDecision.activatedBindings
        guard bindings.isEmpty == false else {
            return "\(scenarioName)情境｜身份組尚未綁定｜\(contract.loopGovernorDecision.configHash)"
        }
        let orderedPhases: [TatwoScenarioPhase] = [.plan, .loops, .goal]
        let parts = orderedPhases.flatMap { phase in
            bindings
                .filter { $0.phase == phase }
                .map { binding -> String in
                    let models = binding.boundModelIDs.isEmpty ? "未指定" : binding.boundModelIDs.joined(separator: "·")
                    return "\(phaseLabel(phase, identity: binding.identity)) \(models)"
                }
        }
        return "\(scenarioName)情境｜" + parts.joined(separator: "｜")
    }

    private func phaseLabel(_ phase: TatwoScenarioPhase, identity: String) -> String {
        switch phase {
        case .plan:
            return "Plan\(identity)"
        case .loops:
            if identity.lowercased() == "sub" { return "sub" }
            return "Loops\(identity)"
        case .goal:
            return "Goal\(identity)"
        }
    }
}



struct ModeDifferenceMatrix: View {
    let modes: [WorkMode]
    let visibleMode: WorkModeID
    let selectedMode: WorkModeID
    let scenarioProfileID: String
    let scenarioBook: TatwoScenarioConfigBookV1
    let onPreviewMode: (WorkModeID) -> Void

    @Environment(\.tatwoSurfaceKind) private var surface

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("S / M / L / XL 形狀差異", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.black))
                Spacer()
                Text("點卡片＝切預覽；套用要按上方按鈕")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: surface == .panel ? 142 : 188), spacing: 9)], spacing: 9) {
                ForEach(modes) { item in
                    ModeDifferenceCard(
                        mode: item,
                        scenarioProfileID: scenarioProfileID,
                        scenarioBook: scenarioBook,
                        selected: item.mode == selectedMode,
                        previewing: item.mode == visibleMode
                    ) {
                        onPreviewMode(item.mode)
                    }
                }
            }
        }
    }
}

struct ModeDifferenceCard: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let mode: WorkMode
    let scenarioProfileID: String
    let scenarioBook: TatwoScenarioConfigBookV1
    let selected: Bool
    let previewing: Bool
    let onPreview: () -> Void

    private var contract: TatwoWorkOSContractV1? {
        try? WorkOSFactory.preview(
            mode: mode.mode,
            scenarioProfileID: scenarioProfileID,
            objective: "Mode difference preview",
            scenarioBook: scenarioBook
        )
    }

    var body: some View {
        Button(action: onPreview) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(mode.mode.rawValue)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .frame(width: 34, height: 34)
                        .background(modeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .foregroundStyle(modeColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.chineseName)
                            .font(.caption.weight(.black))
                            .lineLimit(1)
                        Text(mode.defaultBudget.helperLimitLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if selected { Badge("套用") }
                    else if previewing { Badge("預覽") }
                }

                HStack(spacing: 5) {
                    ForEach(flowLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 8.4, weight: .black, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(modeColor.opacity(0.08), in: Capsule())
                            .foregroundStyle(modeColor)
                    }
                }

                Text(shapeSentence)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(previewing ? modeColor.opacity(0.105) : Color.white.opacity(0.040), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(previewing ? modeColor.opacity(0.42) : Color.white.opacity(0.08), lineWidth: previewing ? 1.35 : 1))
        }
        .buttonStyle(.plain)
    }

    /// 由 contract 實資料推導的流程，而非各模式寫死的字串。
    /// XXL 因此能反映自己的 loop 數與監督層，不再與 XL 共用同一段假流程。
    private var flowLabels: [String] {
        guard let contract else { return ["不可用"] }
        var labels = ["Plan"]
        let loopCount = contract.domainLoops.count
        if loopCount > 0 {
            labels.append(loopCount == 1 ? "1 Loop" : "\(loopCount) Loops")
        }
        if contract.mainlineLoop.reviewerGateRequired {
            labels.append("副審")
        }
        if contract.mode == .xxl {
            labels.append("編排監督")
        }
        if !contract.receiptRequirements.isEmpty {
            labels.append("收據")
        }
        labels.append("Goal")
        return labels
    }

    private var shapeSentence: String {
        guard let contract else { return "contract 未產生，不可放行。" }
        if contract.domainLoops.isEmpty {
            return contract.mainlineLoop.reviewerGateRequired ? "主線 + 副審關卡，不開多支線。" : "主線直修，收最小證據。"
        }
        let domains = contract.domainLoops.prefix(3).map { $0.domain.plainName }.joined(separator: " / ")
        return "\(domains) 先各自產收據，再回主線。"
    }

    private var modeColor: Color {
        switch mode.mode {
        case .s: .green
        case .m: LiquidGlassTokens.brandAccent
        case .l: LiquidGlassTokens.brandAccent
        case .xl, .xxl: .orange
        }
    }
}






struct ModeFlowNode: View {
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .black, design: .rounded))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 9.0, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(minWidth: 92, alignment: .leading)
        .background(color.opacity(0.090), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}










struct ModeInspectorLine: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 8.4, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.052), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}






struct WorkOSModeSurfaceStrip: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let contract: TatwoWorkOSContractV1

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("主線")
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                Text("→")
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
                if contract.domainLoops.isEmpty {
                    Text(contract.mode == .s ? "直接查證" : "副審關卡")
                        .font(.system(size: 8.2, weight: .black, design: .rounded))
                } else {
                    ForEach(contract.domainLoops.prefix(3)) { loop in
                        Text(loop.domain.rawValue)
                            .font(.system(size: 8.2, weight: .black, design: .rounded))
                    }
                }
                Text("→ 收據")
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Text(surfaceSummary)
                .font(.system(size: 8.4, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(LiquidGlassTokens.brandAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var surfaceSummary: String {
        WorkOSFlowTemplateFactory.surfaceSummary(contract: contract)
    }
}

enum ScenarioCanvasTool: String, CaseIterable, Equatable {
    case edit
    case addBox
    case arrow
    case tools

    var label: String {
        switch self {
        case .edit: return "編輯"
        case .addBox: return "新增筐"
        case .arrow: return "箭頭"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .edit: return "cursorarrow.click"
        case .addBox: return "plus.square.on.square"
        case .arrow: return "arrow.triangle.branch"
        case .tools: return "puzzlepiece.extension"
        }
    }

    var color: Color {
        switch self {
        case .edit: return LiquidGlassTokens.brandAccent
        case .addBox: return LiquidGlassTokens.brandAccent
        case .arrow: return .orange
        case .tools: return .teal
        }
    }
}
