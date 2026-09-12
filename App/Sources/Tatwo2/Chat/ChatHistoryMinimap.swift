import SwiftUI

extension ChatTranscriptDisplayItem {
    var historyIsUser: Bool {
        if case .message(let message) = self { return message.role == .user }
        return false
    }

    var historyTitle: String {
        switch self {
        case .message(let message):
            return message.role == .user ? "你的指令"
                : (message.role == .assistant ? "回覆" : "系統")
        case .workTimeline:
            return "工作"
        case .planSummary:
            return "計畫"
        }
    }

    var historyPreviewText: String {
        let text: String
        switch self {
        case .message(let message): text = message.text
        case .workTimeline(let timeline): text = timeline.presentation.text
        case .planSummary: text = "展開計畫畫布"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（無文字）" : String(trimmed.prefix(140))
    }
}

// Codex app 式聊天歷史 minimap（使用者「逐格 parity」——可找歷史指令的功能）。
// 一個實際呈現列對應一格；合併工作事件不產生不存在的跳轉目標。
// 2026-09-11 使用者：不要把一大堆刻度擠在一起；上下留白一致（原本偏高）；刻度太多就用滾輪上下捲（同 Codex）。
struct ChatHistoryMinimap: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let items: [ChatTranscriptDisplayItem]
    let onJump: (String) -> Void
    @State private var hovered: String?
    /// 滑鼠在歷史條上移動時，附近的刻度像波浪一樣隆起（參考 Codex）。
    @State private var pointerY: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 使用者：不夠凸、不夠圓潤 → 隆起更高（可略超出欄寬）、落差更寬更平滑，峰值處也稍微變粗。
    private static let waveMaxWidth: CGFloat = 30

    /// Fixed spacing — never compressed; overflow scrolls instead.
    private static let slot: CGFloat = 8
    /// Same margin above and below the column inside the *visible* transcript area. The transcript runs
    /// under the composer, so its bottom ~150pt is not visible and is reserved first (使用者：天地不對稱).
    private static let verticalMargin: CGFloat = 56
    private static let composerReserve: CGFloat = 150
    /// 使用者：整體歷史條縮小一點 — the column never grows taller than this; more ticks scroll.
    private static let maxColumnHeight: CGFloat = 360
    private static let columnWidth: CGFloat = 22
    /// Room for the wave, which may reach past the column.
    private static let laneWidth: CGFloat = 34
    private static let tooltipEstHeight: CGFloat = 58

    var body: some View {
        if items.count >= 4 {
            GeometryReader { geo in
                let available = min(max(geo.size.height - Self.composerReserve - Self.verticalMargin * 2, Self.slot * 4),
                                    Self.maxColumnHeight)
                let contentHeight = CGFloat(items.count) * Self.slot
                let visible = min(contentHeight, available)
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: false) {
                        tickColumn
                    }
                    .scrollDisabled(contentHeight <= available)
                    .frame(width: Self.laneWidth, height: visible)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.bottom, Self.composerReserve)
                    .onAppear {
                        if let last = items.last?.id { reader.scrollTo(last, anchor: .bottom) }
                        // headless 自驗：TATWO_ULTRAWORK_MINIMAP_HOVER=<index> 強制 hover 某格看預覽筐位置。
                        if let raw = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_MINIMAP_HOVER"],
                           let i = Int(raw), items.indices.contains(i) {
                            hovered = items[i].id
                        }
                    }
                    .onChange(of: items.count) { _, _ in
                        if let last = items.last?.id { reader.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .overlayPreferenceValue(MinimapHoverAnchor.self) { anchor in
                GeometryReader { proxy in
                    if let anchor, let id = hovered, let m = items.first(where: { $0.id == id }) {
                        let rect = proxy[anchor]
                        // #86 預覽筐貼在「hover 那一格旁邊」：垂直對齊該格中心，並夾在可視範圍內。
                        let y = min(max(rect.midY - Self.tooltipEstHeight / 2, 0),
                                    max(proxy.size.height - Self.tooltipEstHeight, 0))
                        tooltip(m)
                            .fixedSize()
                            .offset(x: Self.laneWidth + 6, y: y)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
            .frame(width: Self.laneWidth)
            .padding(.leading, 3)
        }
    }

    private var tickColumn: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, m in
                tick(m, index: index)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard !reduceMotion else { return }
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.78)) {
                switch phase {
                case .active(let point): pointerY = point.y
                case .ended: pointerY = nil
                }
            }
        }
    }

    /// 0…1：離滑鼠越近隆起越高（高斯落差）。
    private func waveLift(index: Int) -> CGFloat {
        guard let pointerY else { return 0 }
        let distance = (CGFloat(index) + 0.5) * Self.slot - pointerY
        let sigma = max(Self.slot * 2.2, 14)   // 使用者：凸起範圍太大 → 收窄
        return exp(-(distance * distance) / (2 * sigma * sigma))
    }

    private func tick(_ m: ChatTranscriptDisplayItem, index: Int) -> some View {
        let slot = Self.slot
        let isUser = m.historyIsUser
        let active = hovered == m.id
        let lift = waveLift(index: index)
        let barHeight = min((active ? 4 : (isUser ? 3 : 2.6)) + lift * 0.9, slot - 1)
        return ZStack(alignment: .leading) {
            // #86 交互特效：hover 那格底下浮一條 brandAccent 高亮膠囊，格子本身橫向長出、變亮。
            if active {
                Capsule()
                    .fill(LiquidGlassTokens.brandAccent.opacity(0.16))
                    .frame(width: Self.columnWidth, height: slot - 1)
            }
            Capsule()
                .fill((isUser ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .opacity(active ? 1 : (isUser ? 0.52 : 0.24)))
                .frame(width: { () -> CGFloat in
                    let base: CGFloat = active ? 20 : (isUser ? 16 : 9)
                    return base + (Self.waveMaxWidth - base) * lift
                }(), height: barHeight)
        }
        .frame(width: Self.laneWidth, height: slot, alignment: .leading)
        .contentShape(Rectangle())
        .anchorPreference(key: MinimapHoverAnchor.self, value: .bounds) { active ? $0 : nil }
        .onHover { inside in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                if inside { hovered = m.id } else if hovered == m.id { hovered = nil }
            }
        }
        .onTapGesture { onJump(m.id) }
    }

    private func tooltip(_ m: ChatTranscriptDisplayItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.historyTitle)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(m.historyIsUser ? LiquidGlassTokens.brandAccent : Color.secondary)
            Text(m.historyPreviewText)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .padding(9)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .liquidGlassSurface(cornerRadius: 12)
    }
}

/// The hovered tick's bounds, read outside the ScrollView so the preview card is never clipped.
private struct MinimapHoverAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct ChatHistoryArrival: Equatable {
    let id: String
    let serial: Int
}

/// 歷史條跳轉抵達：左右短抖一下，底下浮出一張淡卡片陰影再退掉（約 1 秒）。
struct ChatHistoryArrivalNudge: ViewModifier {
    let id: String
    let arrival: ChatHistoryArrival?
    @State private var offsetX: CGFloat = 0
    @State private var playedSerial = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 2026-09-11 使用者：不要白框，直接抖訊息本身。
        content
            .offset(x: offsetX)
            .onAppear(perform: playIfNeeded)
            .onChange(of: arrival) { _, _ in playIfNeeded() }
    }

    private func playIfNeeded() {
        guard let arrival, arrival.id == id, arrival.serial != playedSerial else { return }
        playedSerial = arrival.serial
        guard !reduceMotion else { return }
        Task { @MainActor in
            for x in [-6.0, 6.0, -4.0, 3.0, 0.0] {
                withAnimation(.easeInOut(duration: 0.07)) { offsetX = x }
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }
}
