import SwiftUI
import TatwoUltraworkCore

/// Wave 1: 情境分頁改為唯讀 Plan / Loops / Goal workflow 呈現。
/// 編輯、畫布 CRUD、Inspector 入口已移除；config 真值仍由 OS contract / MCP 管。
struct ScenariosPage: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let profiles: [ScenarioProfile]
    let currentAppMode: WorkModeID
    let selectedScenario: ScenarioID
    let pluginRegistryEntries: [PluginRegistryEntry]
    let onSelect: (ScenarioID) -> Void
    @Binding var previewScenarioProfileID: String

    @State private var scenarioBook = TatwoScenarioConfigDefaults.book
    @State private var showGateSummary = false

    init(
        profiles: [ScenarioProfile],
        selectedMode: WorkModeID,
        selectedScenario: ScenarioID,
        previewScenarioProfileID: Binding<String>,
        pluginRegistryEntries: [PluginRegistryEntry],
        onSelect: @escaping (ScenarioID) -> Void
    ) {
        self.profiles = profiles
        self.currentAppMode = selectedMode
        self.selectedScenario = selectedScenario
        _previewScenarioProfileID = previewScenarioProfileID
        // Host still supplies plugins / onSelect; Wave 1 drops in-page edit entrypoints.
        self.pluginRegistryEntries = pluginRegistryEntries
        self.onSelect = onSelect
    }

    private var selectedMode: WorkModeID { currentAppMode }

    private var selectedProfile: ScenarioProfile {
        if let baseScenario = selectedScenarioConfig?.baseScenario,
           let baseProfile = profiles.first(where: { $0.baseScenario == baseScenario }) {
            return baseProfile
        }
        return profiles.first { $0.id == selectedScenario.rawValue }
            ?? profiles.first { $0.baseScenario == selectedScenario }
            ?? profiles.first
            ?? ScenarioProfile(
                id: "fallback",
                displayName: "未設定",
                baseScenario: .coding,
                plainPurpose: "尚未建立情境。",
                defaultMode: .m,
                allowsNewsIdentity: false,
                identitySlots: [],
                agentsMarkdownTemplate: "# AGENTS.md\n尚未建立情境。",
                guardrails: ["fail closed"]
            )
    }

    private var contract: ScenarioWorkflowContract? {
        try? ScenarioWorkflowContractFactory.make(
            mode: selectedMode,
            scenarioProfileID: previewScenarioProfileID,
            objective: "App scenario workflow preview",
            scenarioBook: scenarioBook,
            loopPresetID: "recommended",
            enabledLoopTemplateIDs: nil
        )
    }

    private var selectedScenarioConfig: TatwoCustomScenarioConfig? {
        scenarioBook.scenario(id: previewScenarioProfileID)
            ?? scenarioBook.scenarios.first
    }

    private var selectedModeConfig: TatwoScenarioModeConfig? {
        selectedScenarioConfig?.modeConfigs[selectedMode]
            ?? (previewScenarioProfileID == "daily" && selectedMode == .m ? TatwoScenarioConfigDefaults.dailyM : nil)
    }

    private var activeModeConfig: TatwoScenarioModeConfig {
        selectedModeConfig ?? TatwoScenarioConfigDefaults.defaultModeConfig(selectedMode)
    }

    private var isSelectedScenarioLocked: Bool {
        selectedScenarioConfig?.builtin ?? true
    }

    private var scenarioConfigStore: TatwoScenarioConfigStore {
        TatwoScenarioConfigStore.defaultStore()
    }

    private func loadScenarioConfigBook() async {
        let store = scenarioConfigStore
        let loadedBook = await Task.detached(priority: .userInitiated) {
            (try? store.load()) ?? TatwoScenarioConfigDefaults.book
        }.value
        guard !Task.isCancelled else { return }
        scenarioBook = loadedBook
        resolvePreviewScenarioProfileID()
    }

    private var previewScenarioBinding: Binding<String> {
        Binding(
            get: { previewScenarioProfileID },
            set: { scenarioID in
                guard let config = scenarioBook.scenario(id: scenarioID) else { return }
                previewScenarioProfileID = config.id
                if let baseScenario = config.baseScenario,
                   baseScenario != selectedScenario
                {
                    onSelect(baseScenario)
                }
            }
        )
    }

    private func resolvePreviewScenarioProfileID() {
        if scenarioBook.scenario(id: previewScenarioProfileID) != nil {
            return
        }
        if let match = scenarioBook.scenarios.first(where: { $0.baseScenario == selectedScenario }) {
            previewScenarioProfileID = match.id
            return
        }
        previewScenarioProfileID = scenarioBook.scenarios.first?.id ?? "daily"
    }

    var body: some View {
        VStack(spacing: 14) {
            GlassCard {
                HStack(spacing: 10) {
                    Label("預覽情境", systemImage: "eye")
                        .font(.caption.weight(.black))
                    Picker("預覽情境", selection: previewScenarioBinding) {
                        ForEach(scenarioBook.scenarios) { scenario in
                            Text(scenario.displayName).tag(scenario.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Spacer(minLength: 0)
                    Badge("規劃預覽")
                }
            }

            ScenarioGateSummaryCard(
                modeConfig: activeModeConfig,
                contract: contract,
                isExpanded: $showGateSummary
            )

            ScenarioWorkflowPresentationCard(
                contract: contract,
                modeConfig: activeModeConfig,
                scenarioName: selectedScenarioConfig?.displayName ?? selectedProfile.displayName,
                locked: isSelectedScenarioLocked
            )

            ScenarioSavedCanvasVersionsRail(
                versions: activeModeConfig.canvasVersions,
                locked: true,
                onRevert: { _ in }
            )
        }
        .task {
            await loadScenarioConfigBook()
        }
        .onChange(of: selectedScenario) { _, _ in
            resolvePreviewScenarioProfileID()
        }
        .animation(.snappy(duration: 0.22), value: scenarioBook)
        .animation(.snappy(duration: 0.22), value: previewScenarioProfileID)
        .accessibilityIdentifier("scenarios-page-readonly")
    }
}

/// 唯讀 Plan + Loops + Goal 流程圖呈現（無 pan/zoom/edit 互動層）。
struct ScenarioWorkflowPresentationCard: View {
    let contract: ScenarioWorkflowContract?
    let modeConfig: TatwoScenarioModeConfig
    let scenarioName: String
    let locked: Bool
    @Environment(\.tatwoSurfaceKind) private var surface

    private var mapHeight: CGFloat { surface == .window ? 760 : 360 }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Plan + Loops Cycle + Goal", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline.weight(.black))
                    Spacer(minLength: 8)
                    Badge(scenarioName)
                    Badge(modeConfig.mode.rawValue)
                    Badge(locked ? "唯讀投影" : "staging 投影")
                }

                if let contract {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contract.showLoopsProjection.presentationLabel)
                            .font(.system(size: 12, weight: .black, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(contract.showLoopsProjection.dispatchSummary)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(contract.showLoopsProjection.runtimeReceiptSummary)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(
                                contract.showLoopsProjection.runtimeReceiptCount > 0
                                    ? Color.green
                                    : Color.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    GeometryReader { proxy in
                        let scale = min(
                            proxy.size.width / WorkOSPlanLoopsGoalMetrics.width,
                            mapHeight / WorkOSPlanLoopsGoalMetrics.height
                        )
                        let scaledWidth = WorkOSPlanLoopsGoalMetrics.width * scale
                        let scaledHeight = WorkOSPlanLoopsGoalMetrics.height * scale
                        let mapLeft = (proxy.size.width - scaledWidth) / 2
                        let mapTop = (mapHeight - scaledHeight) / 2

                        WorkOSPlanLoopsGoalCycleMap(contract: contract.workOSContract)
                            .frame(width: WorkOSPlanLoopsGoalMetrics.width, height: WorkOSPlanLoopsGoalMetrics.height)
                            .scaleEffect(scale, anchor: .topLeading)
                            .frame(width: scaledWidth, height: scaledHeight, alignment: .topLeading)
                            .position(x: mapLeft + scaledWidth / 2, y: mapTop + scaledHeight / 2)
                            .allowsHitTesting(false)
                    }
                    .frame(height: mapHeight)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                } else {
                    Text("無法投影目前情境的 workflow contract。")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }
        }
    }
}

/// Shared by ScenarioSavedCanvasVersionsRail (leaf); kept after config-bar removal.
struct ScenarioLiquidGlassActionButtonStyle: ButtonStyle {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.black))
            .foregroundStyle(.primary)
            .padding(.horizontal, prominent ? 11 : 10)
            .frame(height: 23)
            .background {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(prominent ? LiquidGlassTokens.tintOpacity : 0.12))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle)
                            .strokeBorder(Color.white.opacity(prominent ? LiquidGlassTokens.strokeOpacity : 0.16), lineWidth: 1)
                    }
                    .shadow(
                        color: .black.opacity(LiquidGlassTokens.shadowOpacity),
                        radius: prominent ? 10 : 7,
                        x: LiquidGlassTokens.shadowOffsetX,
                        y: prominent ? 3 : 2)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shared by ScenarioGateSummaryCard; relocated from deleted ScenarioPageConfigEditor.
struct FlowTagWrap: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 8.2, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.075), in: Capsule())
                    .foregroundStyle(Color.primary)
            }
        }
    }
}
