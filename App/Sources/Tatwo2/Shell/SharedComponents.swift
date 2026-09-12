// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/SharedComponents.swift；改動 2 行（原因：run A 照搬，僅移除舊水電 import／呼叫並接同名 Facade）
import SwiftUI

enum TatwoMotionClock {
    static var secondsPerFrame: TimeInterval {
        let env = ProcessInfo.processInfo.environment
        if env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_WORKFLOW_GRAPH"] != nil {
            return 3600
        }

        if let raw = env["TATWO_ULTRAWORK_MOTION_FPS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
            if ["0", "off", "static", "false", "reduce"].contains(raw) {
                return 3600
            }
            if let fps = Double(raw), fps > 0 {
                return min(2.0, max(1.0 / 60.0, 1.0 / fps))
            }
        }

        return 0.45
    }

    static func progress(for date: Date, cycle: TimeInterval = 5.8) -> Double {
        guard cycle > 0 else { return 0 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
    }
}

// B4: shared leaf UI primitives extracted from the 12k-line TatwoUltraworkMacApp.swift.
// These are pure, reused-everywhere components with no page-private dependencies — a first,
// build-verified slice of the monolith split. Larger page extractions require promoting the
// file's ~219 `private` decls to `internal` and are a separate, attended step.

struct Badge: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let text: String
    init(_ text: String) { self.text = text }
    // 極光 P4 補齊（2026-08-20）：app 全域 Badge 原本裸用 .thinMaterial
    // 無主題分支；改依 usesGlass 分流，fable5 得到暖紙實底。
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if TatwoActivePalette.current.usesGlass {
                    Capsule().fill(.thinMaterial)
                } else {
                    Capsule().fill(TatwoActivePalette.current.surfaceFill)
                }
            }
    }
}

// B2: shows the live status of a real sub-dispatch bound to an identity slot.
struct DispatchStatusPill: View {
    let status: TatwoDispatchStatus
    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
    private var label: String {
        switch status {
        case .queued: "排隊"
        case .running: "執行中"
        case .completed: "完成"
        case .verified: "已驗收"
        case .failed: "失敗"
        }
    }
    private var color: Color {
        switch status {
        case .queued: Color.gray
        case .running: Color.blue
        case .completed: Color.green
        case .verified: Color.mint
        case .failed: Color.red
        }
    }
}

struct StatusPill: View {
    let state: InstallState
    let labelOverride: String?

    init(state: InstallState, labelOverride: String? = nil) {
        self.state = state
        self.labelOverride = labelOverride
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
    }

    private var label: String {
        if let labelOverride { return labelOverride }
        return switch state {
        case .installed: "已接"
        case .missing: "缺少"
        case .skipped: "略過"
        case .unknown: "待接入 / 未驗證"
        }
    }

    private var color: Color {
        switch state {
        case .installed: .green
        case .missing: .red
        case .skipped: .orange
        case .unknown: .gray
        }
    }
}

struct TatwoBackground: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    // 極光 P4 補齊（2026-08-20）：原本用 Color.accentColor/Color.purple
    // 字面量＋.bar 材質、完全無視 palette。改讀主題 token：極光＝三彩
    // 淡漸變（同 ultrawork 色系）疊系統材質；fable5＝暖紙實底。
    var body: some View {
        Group {
            if TatwoActivePalette.current.usesGlass {
                LinearGradient(
                    colors: [
                        LiquidGlassTokens.accentViolet.opacity(0.12),
                        LiquidGlassTokens.accentPink.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .background(.bar)
            } else {
                LiquidGlassTokens.canvasBackground
            }
        }
        .ignoresSafeArea()
    }
}

struct TatwoPanelBackdrop: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    // Round 8: liquid glass -- Dashboard token-driven backdrop; no dark/black base layer.
    // 極光 P4 補齊（2026-08-20）：加 fable5 分支——不透明暖紙圓角底，
    // 玻璃不再漏進紀念主題；極光分支照 Round 8 原樣。
    @ViewBuilder
    var body: some View {
        if TatwoActivePalette.current.usesGlass {
            glassBody
        } else {
            RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary, style: LiquidGlassTokens.shapeStyle)
                .fill(LiquidGlassTokens.canvasBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary, style: LiquidGlassTokens.shapeStyle)
                        .strokeBorder(
                            TatwoActivePalette.current.surfaceBorder.opacity(0.75),
                            lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: .black.opacity(LiquidGlassTokens.shadowOpacity),
                    radius: LiquidGlassTokens.shadowRadius,
                    x: LiquidGlassTokens.shadowOffsetX,
                    y: LiquidGlassTokens.shadowOffsetY
                )
        }
    }

    private var glassBody: some View {
        RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary, style: LiquidGlassTokens.shapeStyle)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary, style: LiquidGlassTokens.shapeStyle)
                    .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusPrimary, style: LiquidGlassTokens.shapeStyle)
                    .strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(LiquidGlassTokens.shadowOpacity),
                radius: LiquidGlassTokens.shadowRadius,
                x: LiquidGlassTokens.shadowOffsetX,
                y: LiquidGlassTokens.shadowOffsetY
            )
    }
}

// Loop 0: shared cards, rows, and helper views mechanically moved from TatwoUltraworkMacApp.swift.


struct EnvironmentComponentGrid: View {
    let components: [TatwoEnvironmentComponent]
    let title: String

    var body: some View {
        if !components.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title)
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                        ForEach(components) { component in
                            EnvironmentComponentTile(component: component)
                        }
                    }
                }
            }
        }
    }
}

struct EnvironmentComponentTile: View {
    let component: TatwoEnvironmentComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(component.title)
                    .font(.caption.weight(.bold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                StatusPill(state: component.status, labelOverride: component.healthState?.plainLabel)
            }
            Text(component.plainStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(component.nextAction)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var icon: String {
        switch component.kind {
        case .app: "menubar.rectangle"
        case .cli: "terminal"
        case .skill: "book.closed"
        case .legacyArchive: "archivebox"
        case .localRuntime: "server.rack"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .plugin: "puzzlepiece.extension"
        case .receipt: "doc.text.magnifyingglass"
        case .safetyGate: "lock.shield"
        }
    }
}




struct GlassCard<Content: View>: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    // 改為委派給已分流的 liquidGlassSurface：aurora=液態玻璃、fable5=扁平牛皮紙（不再自帶玻璃漏到 fable5）。
    var body: some View {
        content
            .padding(18)
            .liquidGlassSurface(cornerRadius: LiquidGlassTokens.radiusCard)
    }
}

struct IdentitySlotRow: View {
    let slot: IdentitySlot
    let showCandidates: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Badge(slot.kind.chineseName)
                Text(slot.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(slot.budgetWeight * 100))%")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.secondary)
                if slot.required { Badge("必須") }
            }
            Text(slot.responsibilities.joined(separator: "、"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if showCandidates {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(slot.candidates.prefix(3)) { candidate in
                        HStack(alignment: .top, spacing: 8) {
                            Badge(candidate.engineID.rawValue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(candidate.engineID.rawValue) · \(candidate.modelID)")
                                    .font(.caption.weight(.bold))
                                Text(candidate.bestWhen)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if candidate.canMutateHost { Badge("host") }
                        }
                    }
                }
                .padding(9)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}





extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// B4: Badge / StatusPill / DispatchStatusPill / TatwoBackground / TatwoPanelBackdrop moved to
// SharedComponents.swift.
