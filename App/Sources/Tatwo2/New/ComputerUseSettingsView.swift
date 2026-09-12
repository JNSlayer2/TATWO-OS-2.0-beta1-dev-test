import SwiftUI
import AppKit
import ApplicationServices

/// Settings › Computer Use (approved design v5, 2026-09-11): one master switch whose card expands (tap its
/// blank area) to the arrow / label switches and the permission status; arrow style tiles show the shape only.
struct ComputerUseSettingsView: View {
    @ObservedObject private var settings = ComputerUseSettings.shared
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let onClose: () -> Void
    @State private var expanded = false
    @State private var accessibilityAllowed = AXIsProcessTrusted()
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                masterCard
                Text("箭頭風格")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, -6)
                styleCard
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Computer Use").font(.title3.bold())
                Text("讓 TATWO 用畫面操作你電腦上的 App")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var masterCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("啟用 Computer Use").font(.system(size: 13, weight: .semibold))
                    Text("關閉後 AI 不能操作任何 App；每個 App 仍會先問你同意")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .tint(LiquidGlassTokens.brandAccent)
                    .labelsHidden()
                    .accessibilityLabel("啟用 Computer Use")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "收起" : "展開箭頭、標籤與系統權限")

            if expanded {
                Divider()
                Group {
                    subRow("顯示 TATWO 箭頭", "標出 AI 正在操作的位置；只有你看得到，不會出現在 AI 的截圖裡",
                           isOn: $settings.showArrow)
                    Divider().padding(.leading, 32)
                    subRow("顯示「TATWO 操作中」標籤", "箭頭旁寫出正在操作哪個 App", isOn: $settings.showLabel)
                    Divider().padding(.leading, 32)
                    permissionsRow
                }
                .opacity(settings.enabled ? 1 : 0.42)
                .disabled(!settings.enabled)
            }
        }
        .background(cardBackground)
    }

    private func subRow(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(LiquidGlassTokens.brandAccent)
                .labelsHidden()
                .accessibilityLabel(title)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private var permissionsRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("系統權限").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    permission("輔助使用", allowed: accessibilityAllowed)
                    Text("·").foregroundStyle(.tertiary)
                    permission("螢幕錄製", allowed: screenAllowed)
                }
            }
            Spacer(minLength: 8)
            Button("打開系統設定") {
                let pane = accessibilityAllowed ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
    }

    private func permission(_ name: String, allowed: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 12))
            Text(allowed ? "✓ 已允許" : "尚未允許")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(allowed ? Color.green : Color.orange)
        }
    }

    private var styleCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(ComputerUseSettings.ArrowStyle.allCases) { style in
                    let selected = settings.arrowStyle == style
                    Button { settings.arrowStyle = style } label: {
                        ZStack {
                            ComputerUseSwatchGround()
                            ComputerUseArrowGlyph(style: style, spin: .zero)
                                .frame(width: 34, height: 38)
                                .scaleEffect(0.88)
                                // 使用者：三個造型高度對齊 — centre by the visible outline (the dart is ~8pt
                                // shorter than the arrow, so it moves down half of that).
                                .offset(y: style == .dart ? 3.2 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(selected ? LiquidGlassTokens.brandAccent.opacity(0.55) : .clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(style.title)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            ComputerUseArrowPreview(style: settings.arrowStyle, showLabel: settings.showLabel)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .background(cardBackground)
        .opacity(settings.enabled && settings.showArrow ? 1 : 0.42)
        .disabled(!settings.enabled || !settings.showArrow)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func refreshPermissions() {
        accessibilityAllowed = AXIsProcessTrusted()
        screenAllowed = CGPreflightScreenCaptureAccess()
    }
}

private func hexColor(_ value: UInt32, _ alpha: Double = 1) -> Color {
    Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
          blue: Double(value & 0xFF) / 255, opacity: alpha)
}

/// 2026-09-11 使用者：漸層背景俗氣 → 平面紙色＋TATWO 自己的紙紋噪點（同 tatwoGrainOverlay 的 tile）。
private struct ComputerUseSwatchGround: View {
    var body: some View {
        Rectangle()
            .fill(hexColor(0xF2ECE2))   // 使用者：噪點太強、顏色太深 → 淺紙色、噪點減弱
            .overlay {
                Rectangle()
                    // 使用者：App 的噪點比示意圖重太多 → 更細（半尺寸）、更淡。
                    .fill(ImagePaint(image: Image(nsImage: TatwoPaperGrain.tile), scale: 0.5))
                    .opacity(0.08)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
    }
}

/// The three arrow styles drawn in SwiftUI with the overlay's own geometry (34 × 38, y down).
struct ComputerUseArrowGlyph: View {
    let style: ComputerUseSettings.ArrowStyle
    let spin: Angle

    var body: some View {
        switch style {
        case .dart:
            let dart = Path(ComputerUsePointerOverlay.dartPath())
            ZStack {
                dart.fill(Color.white).shadow(color: .white.opacity(0.9), radius: 4)
                dart.stroke(Color.white, style: StrokeStyle(lineWidth: 3.2, lineJoin: .round))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1.5)
                dart.fill(hexColor(0x111111))
            }
        case .aurora, .clear:
            let arrow = Path(ComputerUsePointerOverlay.arrowPath())
            ZStack {
                if style == .aurora {
                    arrow.fill(LinearGradient(colors: [hexColor(0xF4A9D6), hexColor(0xA98BF0), hexColor(0x7FB0FF)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                        .blur(radius: 3.4)
                        .opacity(0.5)
                }
                arrow.fill(Color.white.opacity(0.18))
                if style == .aurora {
                    arrow.fill(AngularGradient(colors: [hexColor(0xF2A6D3), hexColor(0xA98BF0), hexColor(0x7FB0FF), hexColor(0xF2A6D3)],
                                               center: UnitPoint(x: 0.4, y: 0.45), angle: spin))
                        .opacity(0.5)
                } else {
                    arrow.fill(LinearGradient(colors: [hexColor(0xEFC5E0), hexColor(0xC1AEF2), hexColor(0xAAC7FF)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(0.22)
                }
                arrow.stroke(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.55), Color.white.opacity(0.22)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing),
                             style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .shadow(color: .black.opacity(0.13), radius: 4, y: 3)
        }
    }
}

/// The settings preview: the pointer glides along an upward arc with ease-out quart between keys of a mini
/// window (the same motion as the real overlay), with the label following.
private struct ComputerUseArrowPreview: View {
    let style: ComputerUseSettings.ArrowStyle
    let showLabel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let keys = ["AC", "±", "%", "÷", "7", "8", "9", "×"]
    private let order = [4, 1, 6, 7, 2, 0]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let segment = 1.6, glide = 0.55
                let index = Int(t / segment)
                let local = t - Double(index) * segment
                let from = keyCenter(order[(index + order.count - 1) % order.count], in: geo.size)
                let to = keyCenter(order[index % order.count], in: geo.size)
                let raw = reduceMotion ? 1 : min(1, local / glide)
                let p = arc(from: from, to: to, progress: 1 - pow(1 - raw, 4))
                ZStack(alignment: .topLeading) {
                    ComputerUseSwatchGround()
                    miniWindow(highlight: raw >= 1 ? order[index % order.count] : nil)
                        .offset(x: origin(geo.size).x, y: origin(geo.size).y)
                    ComputerUseArrowGlyph(style: style, spin: .degrees(reduceMotion ? 0 : t.truncatingRemainder(dividingBy: 6) * 60))
                        .frame(width: 34, height: 38)
                        .scaleEffect(0.88, anchor: .topLeading)
                        .offset(x: p.x - 4.3, y: p.y - 3.7)
                    if showLabel {
                        Text("TATWO 操作中 · 計算機")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hexColor(0x231E36))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                    .overlay(Capsule().fill(Color.white.opacity(0.18)))
                            }
                            .overlay {
                                Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0.5), Color.white.opacity(0.2)],
                                                                      startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.04), radius: 7, y: 4)
                            .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
                            .offset(x: p.x + 20, y: p.y + 24)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    /// The mini window is centred in the preview (2026-09-11 使用者：展示窗置中).
    private func origin(_ size: CGSize) -> CGPoint {
        CGPoint(x: (size.width - 230) / 2, y: (size.height - 116) / 2)
    }

    private func keyCenter(_ index: Int, in size: CGSize) -> CGPoint {
        let o = origin(size), column = CGFloat(index % 4), row = CGFloat(index / 4)
        return CGPoint(x: o.x + 9 + column * 55 + 27, y: o.y + 22 + 9 + row * 23 + 9)
    }

    private func arc(from: CGPoint, to: CGPoint, progress t: Double) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, dist = max(hypot(dx, dy), 1)
        var nx = -dy / dist, ny = dx / dist
        if ny > 0 { nx = -nx; ny = -ny }   // bow upward on screen (y down)
        let bow = min(60, dist * 0.22)
        let c = CGPoint(x: (from.x + to.x) / 2 + nx * bow, y: (from.y + to.y) / 2 + ny * bow)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * to.x, y: u * u * from.y + 2 * u * t * c.y + t * t * to.y)
    }

    private func miniWindow(highlight: Int?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Circle().fill(hexColor(0xE8E2D8)).frame(width: 7, height: 7) } ; Spacer() }
                .padding(.horizontal, 8)
                .frame(height: 22)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(50), spacing: 5), count: 4), spacing: 5) {
                ForEach(keys.indices, id: \.self) { i in
                    Text(keys[i])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hexColor(0x6B6158))
                        .frame(width: 50, height: 18)
                        .background(highlight == i ? hexColor(0xE7D6CF) : hexColor(0xF1ECE4),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(9)
            Spacer(minLength: 0)
        }
        .frame(width: 230, height: 116)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: hexColor(0x3C2814, 0.14), radius: 10, y: 8)
    }
}
