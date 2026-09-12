import SwiftUI
import TatwoUltraworkCore

struct ScenarioGlassPickerMenu: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let title: String
    let width: CGFloat
    let groups: [TatwoScenarioDisplayGroup]
    @Binding var selection: String

    var body: some View {
        Menu {
            ForEach(groups) { group in
                Section(group.category) {
                    ForEach(group.scenarios) { scenario in
                        Button {
                            selection = scenario.id
                        } label: {
                            Label(scenario.displayName, systemImage: selection == scenario.id ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 24)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
            .contentShape(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusChip, style: LiquidGlassTokens.shapeStyle))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .help("玻璃情境選單；取代原生藍系統 NSPopUpButton 風格")
    }
}

struct ScenarioGlassModeSegmentedControl: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(WorkModeID.allCases, id: \.rawValue) { mode in
                Button {
                    selection = mode.rawValue
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10.2, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(selection == mode.rawValue ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background {
                            if selection == mode.rawValue {
                                RoundedRectangle(cornerRadius: 9, style: LiquidGlassTokens.shapeStyle)
                                    .fill(.ultraThinMaterial)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: LiquidGlassTokens.shapeStyle)
                                            .fill(Color.white.opacity(0.30))
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: LiquidGlassTokens.shapeStyle)
                                            .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                                    }
                                    .shadow(color: .black.opacity(0.05), radius: 7, x: 0, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(height: 24)
        .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusChip)
        .help("玻璃 S/M/L/XL 分段；選中段用白玻璃亮起")
    }
}

struct ScenarioGateSummaryCard: View {
    let modeConfig: TatwoScenarioModeConfig
    let contract: ScenarioWorkflowContract?
    @Binding var isExpanded: Bool

    private var summaryItems: [String] {
        var items = modeConfig.gateRules
        if let contract {
            items.append(contract.failClosedRule)
        }
        return Array(items.prefix(8))
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Label("情境 Gate 摘要", systemImage: "lock.shield")
                            .font(.headline.weight(.black))
                        Badge("\(modeConfig.gateRules.count) gate")
                        if let contract {
                            Badge("\(contract.receiptRequirements.count) receipt requirements")
                            Badge(contract.showLoopsProjection.presentationLabel)
                        }
                        Spacer()
                        Text(isExpanded ? "收合" : "點開查看")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(.secondary)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.black))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("收據不在編輯器 tab 內修改；這裡只顯示 OS pass / fail-closed 條件。")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        FlowTagWrap(tags: summaryItems.isEmpty ? ["未設定 gate"] : summaryItems)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

struct ScenarioSavedCanvasVersionsRail: View {
    let versions: [TatwoScenarioCanvasVersion]
    let locked: Bool
    let onRevert: (String) -> Void

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("已儲存的畫布版本", systemImage: "clock.arrow.circlepath")
                        .font(.headline.weight(.black))
                    Spacer()
                    Badge("\(versions.count) versions")
                    Badge(locked ? "解鎖後可回復" : "staging 可回復")
                }

                if versions.isEmpty {
                    EmptyStateStrip(text: "尚未有畫布版本；解鎖 staging 後按「保存」會建立第一個版本。")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                        ForEach(versions) { version in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(version.name)
                                        .font(.system(size: 13, weight: .black, design: .rounded))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Badge(Self.formatter.string(from: version.createdAt))
                                        Badge(String(version.hash.prefix(7)))
                                    }
                                }
                                Spacer(minLength: 0)
                                Button("回復") { onRevert(version.id) }
                                    .buttonStyle(ScenarioLiquidGlassActionButtonStyle())
                                    .controlSize(.small)
                                    .disabled(locked)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }
}








struct MiniSpecPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 7.2, weight: .black, design: .rounded))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 7.6, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.085), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}








