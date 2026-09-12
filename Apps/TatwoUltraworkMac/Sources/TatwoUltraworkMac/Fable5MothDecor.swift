import SwiftUI

// fable5 紀念主題的「蛾」裝飾（使用者 2026-07-12：fable5 的蛾很標誌性，加到左列工作區做裝飾）。
// 向量插畫（Path），隨主題上色、任意縮放、無外部依賴；復古自然史圖鑑風（呼應 #56 蝶蛾）。
// 提供數款款式供挑選（TatwoMothStyle）。放在左 rail 底部當低調 watermark。

enum TatwoMothStyle: String, CaseIterable, Identifiable {
    case luna      // 月神蛾：長尾、圓潤
    case emperor   // 帝王蛾：寬翅、眼斑
    case lineart   // 線描：細線、通透
    var id: String { rawValue }
}

/// 對稱蛾形狀（右半以 normalized 座標繪製，左半鏡射）。style 決定翅形。
struct TatwoMothShape: Shape {
    var style: TatwoMothStyle = .luna

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }

        // 身體（中央紡錘）
        p.addEllipse(in: CGRect(x: rect.minX + 0.468 * w, y: rect.minY + 0.30 * h,
                                width: 0.064 * w, height: 0.46 * h))

        // 右半翅（依 style），再鏡射到左半
        for sign in [CGFloat(1), CGFloat(-1)] {
            func X(_ x: CGFloat) -> CGFloat { 0.5 + sign * (x - 0.5) }
            func M(_ x: CGFloat, _ y: CGFloat) -> CGPoint { P(X(x), y) }

            switch style {
            case .luna:
                // 前翅（上，圓潤）
                p.move(to: M(0.5, 0.33))
                p.addCurve(to: M(0.90, 0.24), control1: M(0.66, 0.18), control2: M(0.84, 0.16))
                p.addCurve(to: M(0.70, 0.47), control1: M(0.96, 0.33), control2: M(0.86, 0.45))
                p.addCurve(to: M(0.5, 0.42), control1: M(0.62, 0.48), control2: M(0.55, 0.45))
                p.closeSubpath()
                // 後翅（下，帶長尾）
                p.move(to: M(0.5, 0.48))
                p.addCurve(to: M(0.80, 0.60), control1: M(0.64, 0.48), control2: M(0.76, 0.53))
                p.addCurve(to: M(0.60, 0.86), control1: M(0.83, 0.72), control2: M(0.70, 0.82))
                p.addCurve(to: M(0.5, 0.60), control1: M(0.55, 0.78), control2: M(0.5, 0.66))
                p.closeSubpath()

            case .emperor:
                // 前翅（寬、尖角）
                p.move(to: M(0.5, 0.32))
                p.addCurve(to: M(0.96, 0.22), control1: M(0.68, 0.16), control2: M(0.90, 0.12))
                p.addCurve(to: M(0.74, 0.50), control1: M(1.00, 0.36), control2: M(0.90, 0.48))
                p.addCurve(to: M(0.5, 0.43), control1: M(0.64, 0.51), control2: M(0.56, 0.47))
                p.closeSubpath()
                // 後翅（寬圓）
                p.move(to: M(0.5, 0.49))
                p.addCurve(to: M(0.86, 0.60), control1: M(0.66, 0.49), control2: M(0.82, 0.52))
                p.addCurve(to: M(0.60, 0.78), control1: M(0.90, 0.72), control2: M(0.74, 0.80))
                p.addCurve(to: M(0.5, 0.62), control1: M(0.54, 0.76), control2: M(0.5, 0.58))
                p.closeSubpath()

            case .lineart:
                // 與 luna 同形，交由 stroke 呈現（見 Decor 的 style 分支）
                p.move(to: M(0.5, 0.33))
                p.addCurve(to: M(0.90, 0.24), control1: M(0.66, 0.18), control2: M(0.84, 0.16))
                p.addCurve(to: M(0.70, 0.47), control1: M(0.96, 0.33), control2: M(0.86, 0.45))
                p.addCurve(to: M(0.5, 0.42), control1: M(0.62, 0.48), control2: M(0.55, 0.45))
                p.closeSubpath()
                p.move(to: M(0.5, 0.48))
                p.addCurve(to: M(0.80, 0.60), control1: M(0.64, 0.48), control2: M(0.76, 0.53))
                p.addCurve(to: M(0.60, 0.86), control1: M(0.83, 0.72), control2: M(0.70, 0.82))
                p.addCurve(to: M(0.5, 0.60), control1: M(0.55, 0.78), control2: M(0.5, 0.66))
                p.closeSubpath()
            }
        }
        return p
    }
}

/// 觸角（兩條羽狀曲線）。
struct TatwoMothAntennae: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        for sign in [CGFloat(1), CGFloat(-1)] {
            func X(_ x: CGFloat) -> CGFloat { 0.5 + sign * (x - 0.5) }
            p.move(to: P(0.5, 0.31))
            p.addCurve(to: P(X(0.30), 0.12),
                       control1: P(X(0.52), 0.22), control2: P(X(0.40), 0.14))
        }
        return p
    }
}

/// 蛾裝飾組件：翅面（填充或線描）+ 觸角 + 翅上眼斑（emperor）。用 fable5 和諧色階上色。
struct TatwoMothDecor: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var style: TatwoMothStyle = .luna
    /// 整體不透明度（rail watermark 用低值）。
    var opacity: Double = 0.5

    private var ink: Color { LiquidGlassTokens.brandAccent }          // 赤陶
    private var wing: Color { LiquidGlassTokens.accentViolet }        // 鼠尾草綠
    private var accent: Color { LiquidGlassTokens.accentBlue }        // 古金

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                if style == .lineart {
                    TatwoMothShape(style: style).path(in: rect)
                        .stroke(ink, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                } else {
                    TatwoMothShape(style: style).path(in: rect)
                        .fill(
                            LinearGradient(colors: [wing.opacity(0.9), ink.opacity(0.85)],
                                           startPoint: .top, endPoint: .bottom))
                        .overlay {
                            TatwoMothShape(style: style).path(in: rect)
                                .stroke(ink.opacity(0.9), lineWidth: 0.8)
                        }
                    if style == .emperor {
                        // 前翅眼斑
                        ForEach([CGFloat(0.30), CGFloat(0.70)], id: \.self) { fx in
                            Circle().fill(accent)
                                .frame(width: rect.width * 0.06, height: rect.width * 0.06)
                                .position(x: rect.width * fx, y: rect.height * 0.33)
                        }
                    }
                }
                TatwoMothAntennae().path(in: rect)
                    .stroke(ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}
