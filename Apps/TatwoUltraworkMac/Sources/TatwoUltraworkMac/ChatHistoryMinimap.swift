import SwiftUI

// Codex app 式聊天歷史 minimap（使用者「逐格 parity」——可找歷史指令的功能）。
// 左側垂直刻度條：每則訊息一格，user 指令較寬較顯眼；hover 一格 → 預覽筐浮在「該格旁邊」；點擊 → 跳到該則。
struct ChatHistoryMinimap: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let messages: [ChatMessage]
    let onJump: (String) -> Void
    @State private var hovered: String?

    // #86 上下微微加寬：每格 slot 由 6 → 9（少訊息更好點；多訊息才等比壓縮）。
    private static let compactSlot: CGFloat = 9
    private static let columnWidth: CGFloat = 22
    private static let tooltipEstHeight: CGFloat = 58

    var body: some View {
        if messages.count >= 4 {
            GeometryReader { geo in
                let count = max(messages.count, 1)
                let slot = min(Self.compactSlot, geo.size.height / CGFloat(count))
                let columnHeight = slot * CGFloat(count)
                let topInset = max((geo.size.height - columnHeight) / 2, 0)
                ZStack(alignment: .topLeading) {
                    tickColumn(slot: slot)
                    tooltipOverlay(slot: slot, topInset: topInset, viewportHeight: geo.size.height)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .onAppear {
                    // headless 自驗：TATWO_ULTRAWORK_MINIMAP_HOVER=<index> 強制 hover 某格看預覽筐位置。
                    if let raw = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_MINIMAP_HOVER"],
                       let i = Int(raw), messages.indices.contains(i) {
                        hovered = messages[i].id
                    }
                }
            }
            .frame(width: Self.columnWidth)
            .padding(.vertical, 10)
            .padding(.leading, 3)
        }
    }

    private func tickColumn(slot: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(messages) { m in
                tick(m, slot: slot)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func tick(_ m: ChatMessage, slot: CGFloat) -> some View {
        let isUser = m.role == .user
        let active = hovered == m.id
        let barHeight = min(active ? 4 : (isUser ? 3 : 2.6), max(slot - 1, 1))
        return ZStack(alignment: .leading) {
            // #86 交互特效：hover 那格底下浮一條 brandAccent 高亮膠囊，格子本身橫向長出、變亮。
            if active {
                Capsule()
                    .fill(LiquidGlassTokens.brandAccent.opacity(0.16))
                    .frame(width: Self.columnWidth, height: max(slot - 1, 2))
            }
            Capsule()
                .fill((isUser ? LiquidGlassTokens.brandAccent : Color.secondary)
                    .opacity(active ? 1 : (isUser ? 0.52 : 0.24)))
                .frame(width: active ? 20 : (isUser ? 16 : 9), height: barHeight)
        }
        .frame(width: Self.columnWidth, height: max(slot, 2), alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                if inside { hovered = m.id } else if hovered == m.id { hovered = nil }
            }
        }
        .onTapGesture { onJump(m.id) }
    }

    @ViewBuilder
    private func tooltipOverlay(slot: CGFloat, topInset: CGFloat, viewportHeight: CGFloat) -> some View {
        if let id = hovered,
           let idx = messages.firstIndex(where: { $0.id == id }),
           let m = messages.first(where: { $0.id == id }) {
            // #86 預覽筐貼在「hover 那一格旁邊」：垂直對齊該格中心，並夾在可視範圍內。
            let tickCenterY = topInset + (CGFloat(idx) + 0.5) * slot
            let rawY = tickCenterY - Self.tooltipEstHeight / 2
            let clampedY = min(max(rawY, 0), max(viewportHeight - Self.tooltipEstHeight, 0))
            tooltip(m)
                .fixedSize()
                .offset(x: Self.columnWidth + 6, y: clampedY)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .move(edge: .leading)))
        }
    }

    private func tooltip(_ m: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.role == .user ? "你的指令" : (m.role == .assistant ? "回覆" : "系統"))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(m.role == .user ? LiquidGlassTokens.brandAccent : Color.secondary)
            Text(previewText(m))
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
        }
        .padding(9)
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .liquidGlassSurface(cornerRadius: 12)
    }

    private func previewText(_ m: ChatMessage) -> String {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "（無文字）" : String(t.prefix(140))
    }
}
