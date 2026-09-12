import SwiftUI
import TatwoUltraworkCore

struct UltraManualHero: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let snapshot: TatwoAppSnapshot
    let surface: TatwoAppSurfaceKind

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: surface == .panel ? 9 : 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "book.pages.fill")
                        .font(.system(size: surface == .panel ? 18 : 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: surface == .panel ? 36 : 46, height: surface == .panel ? 36 : 46)
                        .background(
                            LiquidGlassTokens.ultraworkGradient,
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Ultra OS 說明書")
                            .font(.system(size: surface == .panel ? 18 : 24, weight: .black, design: .rounded))
                        Text("把 TATWO Ultrawork 當成一套 AI 工作作業系統來讀：先看 8 行大綱，需要時再展開細節。")
                            .font(surface == .panel ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    if surface == .window {
                        UltraManualModeStack(snapshot: snapshot)
                    }
                }

                Text(snapshot.plainSummary)
                    .font(.system(size: surface == .panel ? 10.8 : 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 6) {
                    Badge("預設全收合")
                    Badge("點章節展開")
                    Badge("白話優先")
                    if surface == .window {
                        Badge("技術名詞附中文")
                        Badge(snapshot.workflowPlan.sandboxRequired ? "沙盒 gate" : "視風險沙盒")
                    }
                }
            }
        }
    }
}

struct UltraManualModeStack: View {
    let snapshot: TatwoAppSnapshot

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Badge("Mode \(snapshot.selectedMode.rawValue)")
            Badge(snapshot.selectedScenario.rawValue)
            StatusPill(state: snapshot.hostMutationAllowed ? .installed : .skipped)
        }
    }
}

struct UltraManualChapterRow: View {
    let chapter: UltraManualChapter
    let isExpanded: Bool
    let compact: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: compact ? 9 : 12) {
                    Text(chapter.number)
                        .font(.caption.monospacedDigit().weight(.black))
                        .foregroundStyle(chapter.accent)
                        .frame(width: compact ? 25 : 32)

                    Image(systemName: chapter.symbol)
                        .font(.system(size: compact ? 13 : 16, weight: .bold))
                        .foregroundStyle(chapter.accent)
                        .frame(width: compact ? 19 : 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(compact ? .subheadline.weight(.black) : .headline.weight(.black))
                            .foregroundStyle(.primary)
                        Text(chapter.outline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 2 : 1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                        .font(.system(size: compact ? 16 : 18, weight: .bold))
                        .foregroundStyle(isExpanded ? chapter.accent : .secondary)
                }
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 8 : 12)
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                UltraManualChapterDetail(chapter: chapter, compact: compact)
                    .padding(.horizontal, compact ? 10 : 14)
                    .padding(.bottom, compact ? 10 : 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            LinearGradient(
                colors: [chapter.accent.opacity(isExpanded ? 0.15 : 0.08), Color.white.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(chapter.accent.opacity(isExpanded ? 0.34 : 0.15), lineWidth: 1)
        )
    }
}

struct UltraManualChapterDetail: View {
    let chapter: UltraManualChapter
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Text(chapter.plainText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 160 : 210), spacing: 8)], spacing: 8) {
                ForEach(chapter.details) { detail in
                    UltraManualInfoTile(detail: detail, accent: chapter.accent)
                }
            }

            UltraManualDiagram(title: "架構示意", steps: chapter.diagram, accent: chapter.accent)
            UltraManualTree(title: "樹狀層級", nodes: chapter.tree, accent: chapter.accent)
        }
        .padding(.top, 2)
    }
}

struct UltraManualInfoTile: View {
    let detail: UltraManualDetail
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(detail.title, systemImage: detail.symbol)
                .font(.caption.weight(.black))
                .foregroundStyle(accent)
            Text(detail.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

struct UltraManualDiagram: View {
    let title: String
    let steps: [String]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 7) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Text(step)
                        .font(.caption2.weight(.black))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(accent.opacity(index == 0 ? 0.22 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.22), lineWidth: 1))

                    if index < steps.count - 1 {
                        Image(systemName: "arrow.right")
                            .font(.caption2.weight(.black))
                            .foregroundStyle(accent)
                    }
                }
            }
        }
    }
}

struct UltraManualTree: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let title: String
    let nodes: [UltraManualTreeNode]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "list.bullet.indent")
                .font(.caption.weight(.black))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(nodes) { node in
                    UltraManualTreeNodeView(node: node, depth: 0, accent: accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tatwoAdaptiveMaterial(cornerRadius: LiquidGlassTokens.radiusCard)
            .background(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity), in: RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle))
            .overlay(RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusCard, style: LiquidGlassTokens.shapeStyle).strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1))
        }
    }
}

struct UltraManualTreeNodeView: View {
    let node: UltraManualTreeNode
    let depth: Int
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(depth == 0 ? accent : accent.opacity(0.55))
                    .frame(width: depth == 0 ? 7 : 5, height: depth == 0 ? 7 : 5)
                    .padding(.top, 5)
                Text(node.text)
                    .font(depth == 0 ? .caption.weight(.bold) : .caption2.weight(.semibold))
                    .foregroundStyle(depth == 0 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 15)

            ForEach(node.children) { child in
                UltraManualTreeNodeView(node: child, depth: depth + 1, accent: accent)
            }
        }
    }
}

struct DashboardMetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 7.5, weight: .black, design: .rounded))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct GateLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.orange)
                .frame(width: 12)
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}





struct WorkOSMiniStep: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 12.8, weight: .black, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}






struct WorkOSPipelineStepBadge: View {
    let index: Int
    let total: Int
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text("\(index)/\(total)")
                .font(.system(size: 16, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Rectangle()
                .fill(color.opacity(0.28))
                .frame(width: 24, height: 2)
        }
        .frame(maxHeight: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.16), lineWidth: 1))
    }
}

struct WorkOSPipelineLaneHeader: View {
    let lane: WorkOSFlowLane

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(lane.title)
                .font(.system(size: 22.6, weight: .black, design: .rounded))
                .foregroundStyle(lane.color)
                .lineLimit(2)
            Text(lane.subtitle)
                .font(.system(size: 16.2, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(lane.color.opacity(0.92))
                .frame(width: 4)
        }
    }
}

struct WorkOSPipelineNodeCard: View {
    let node: WorkOSFlowNode

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.995))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1.0)

            Rectangle()
                .fill(node.color.opacity(0.86))
                .frame(width: 5)
                .padding(.vertical, 15)
                .padding(.leading, 9)

            VStack(alignment: .leading, spacing: 8) {
                Text(node.title)
                    .font(.system(size: 18.4, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(node.body)
                    .font(.system(size: 18.0, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.leading, 23)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
        }
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 118, alignment: .topLeading)
    }

    private var semanticKind: WorkOSPipelineNodeKind {
        let key = "\(node.id) \(node.title)".lowercased()
        if key.contains("gate") || key.contains("停止") || key.contains("禁止") || key.contains("回滾") || key.contains("rollback") || key.contains("人工") { return .gate }
        if key.contains("收據") || key.contains("receipt") { return .receipt }
        if key.contains("沙盒") || key.contains("sandbox") { return .sandbox }
        if key.contains("工具") || key.contains("腳本") || key.contains("runtime") || key.contains("js") || key.contains("swift") { return .runtime }
        if key.contains("hub") || key.contains("領域") || key.contains("loop") { return .domain }
        if key.contains("contract") || key.contains("合約") || key.contains("os") { return .contract }
        return .standard
    }
}

struct WorkOSPipelineConnector: View {
    let color: Color

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color.opacity(0.42))
                .frame(height: 3)
            Rectangle()
                .fill(color.opacity(0.82))
                .frame(width: 8, height: 8)
        }
        .accessibilityHidden(true)
    }
}

struct WorkOSPipelineOutcomeSplit: View {
    let pass: WorkOSFlowNode
    let fail: WorkOSFlowNode

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            WorkOSPipelineSplitBus(passColor: pass.color, failColor: fail.color)
                .frame(width: 44, height: 104)
            VStack(spacing: 8) {
                WorkOSPipelineOutcomeCard(node: pass, kind: .pass)
                WorkOSPipelineOutcomeCard(node: fail, kind: .fail)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct WorkOSPipelineSplitBus: View {
    let passColor: Color
    let failColor: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 3, height: 84)
                .offset(x: 14)
            Rectangle()
                .fill(passColor.opacity(0.72))
                .frame(width: 30, height: 3)
                .offset(x: 14, y: -29)
            Rectangle()
                .fill(failColor.opacity(0.72))
                .frame(width: 30, height: 3)
                .offset(x: 14, y: 29)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 14, height: 3)
                .offset(x: 0)
        }
        .accessibilityHidden(true)
    }
}

struct WorkOSPipelineOutcomeCard: View {
    enum Kind {
        case pass
        case fail
    }

    let node: WorkOSFlowNode
    let kind: Kind

    private var tint: Color {
        switch kind {
        case .pass: return .green
        case .fail: return .red
        }
    }

    private var titlePrefix: String {
        switch kind {
        case .pass: return "通過"
        case .fail: return "未過"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(titlePrefix)
                .font(.system(size: 15.5, weight: .black, design: .rounded).monospaced())
                .foregroundStyle(tint)
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.title.replacingOccurrences(of: "\(titlePrefix) ", with: ""))
                    .font(.system(size: 18.2, weight: .black, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(node.body.replacingOccurrences(of: "\n", with: " / "))
                    .font(.system(size: 13.6, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54, alignment: .leading)
        .background(Color.white.opacity(0.995), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.48), lineWidth: kind == .pass ? 1.4 : 1.8))
    }
}




struct WorkOSShowLoopNodeRow: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let node: WorkOSShowLoopNode

    private var color: Color {
        switch node.kind {
        case .goal: LiquidGlassTokens.brandAccent
        case .contract: LiquidGlassTokens.brandAccent
        case .mainline: .indigo
        case .domain: .teal
        case .receipt: .orange
        case .gate: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(node.kind.rawValue)
                .font(.system(size: 7.6, weight: .black, design: .rounded))
                .frame(width: 54, height: 20)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(node.title)
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                    if let owner = node.ownerIdentity { Badge(owner.chineseName) }
                    Spacer(minLength: 0)
                    Text("r\(node.receiptIDs.count)")
                        .font(.system(size: 7.5, weight: .black, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(node.plainPurpose)
                    .font(.system(size: 8.1, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(7)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

