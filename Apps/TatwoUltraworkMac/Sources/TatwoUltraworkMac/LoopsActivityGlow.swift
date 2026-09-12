import SwiftUI

/// 左頁標題「浮動光」＝這個 session 的算力正在被 loops 共享。
///
/// 參數來源見 `LiquidGlassTokens` 的「Loops 算力共享呼吸光暈」區塊：
/// 半徑／明暗上下限取自 Dashboard 真值（shadowBlur 14 / alpha 0.18 / shadowIntensity 0.04），
/// 呼吸週期與色相是工程近似（Dashboard 無時間軸與狀態色欄位），該區塊已逐條標註。
///
/// 省資源做法：整個效果只有**一個** animatable 值（`breathing` 這顆 Bool）在 easeInOut
/// 之間來回插值，body 不會每幀重跑；`active == false` 時整個 overlay 從樹上移除，
/// repeatForever 動畫隨之停止，閒置時零成本。不使用 TimelineView 逐幀重繪。
struct TatwoLoopsSharingGlow: ViewModifier {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    let active: Bool

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            if active {
                halo
            }
        }
    }

    /// 橫躺的橢圓燈暈：中心壓在標題內容上，向外羽化到全透明。
    ///
    /// 幾何刻意不用任何 Shape.fill——第一版用圓角矩形被判讀成「標題欄 highlight」。
    /// RadialGradient 末端 stop 是 opacity 0，加上 blur 之後不存在硬邊或矩形輪廓。
    /// 負 padding 讓光暈超出標題文字邊界（設計指定 12–16pt），所以是「文字在發光」
    /// 而不是「一塊底色」。
    private var halo: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // 以較長邊為基準，讓光暈確實蓋過整段標題文字再往外收。
            let radius = max(width, height) * 0.5
            // 落差分佈：核心維持接近實心到 0.55，之後才快速羽化到 0。
            //
            // 這不是在偷調 alpha——圖層 opacity 仍嚴格等於錨定的 peak 0.18。
            // 先前把 stop 一路壓到 0.55/0.18 再乘 0.18，等於實際峰值只有 0.03 左右，
            // 在牛皮紙底上完全讀不到。核心飽滿、邊緣仍為 opacity 0，
            // 既無硬邊也讓錨定值真的發揮到 0.18。
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: LiquidGlassTokens.loopsGlowColor, location: 0),
                    .init(color: LiquidGlassTokens.loopsGlowColor, location: 0.35),
                    .init(color: LiquidGlassTokens.loopsGlowColor.opacity(0.78), location: 0.55),
                    .init(color: LiquidGlassTokens.loopsGlowColor.opacity(0.34), location: 0.78),
                    .init(color: LiquidGlassTokens.loopsGlowColor.opacity(0), location: 1)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: max(1, radius))
            .frame(width: width, height: height)
            // 橫向拉寬成橢圓：標題是一段橫躺文字，正圓會在上下溢出、左右不足。
            .scaleEffect(x: LiquidGlassTokens.loopsGlowHorizontalStretch, y: 1, anchor: .center)
        }
        .padding(-LiquidGlassTokens.loopsGlowSpread)
        .blur(radius: LiquidGlassTokens.loopsGlowRadius)
        .opacity(currentOpacity)
        .animation(breathAnimation, value: breathing)
        .allowsHitTesting(false)
        .onAppear { breathing = true }
        .onDisappear { breathing = false }
    }

    /// 快照匯出：離屏 NSHostingView 是一次性 render，repeatForever 動畫不會推進，
    /// 光暈會卡在呼吸下限（0.04）＝ PNG 上幾乎看不見，主導無從驗收。
    /// 匯出時改用確定性的峰值——顯示的是設計本來就規定的上限值，不是為了好看調亮。
    private static var isSnapshotExport: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil
            || env["TATWO_ULTRAWORK_EXPORT_PANEL_SNAPSHOT"] != nil
    }

    private var currentOpacity: Double {
        if Self.isSnapshotExport {
            return LiquidGlassTokens.loopsGlowPeakOpacity
        }
        guard !reduceMotion else {
            // 減少動態：不呼吸，停在上下限中點，仍看得出「有東西在跑」。
            return (LiquidGlassTokens.loopsGlowPeakOpacity
                + LiquidGlassTokens.loopsGlowTroughOpacity) / 2
        }
        return breathing
            ? LiquidGlassTokens.loopsGlowPeakOpacity
            : LiquidGlassTokens.loopsGlowTroughOpacity
    }

    private var breathAnimation: Animation? {
        guard !reduceMotion, !Self.isSnapshotExport else { return nil }
        return .easeInOut(duration: LiquidGlassTokens.loopsGlowBreathPeriod)
            .repeatForever(autoreverses: true)
    }
}

extension View {
    /// 有 loops 進行中時，在這個視圖底下加一層柔和呼吸光暈。
    func tatwoLoopsSharingGlow(active: Bool) -> some View {
        modifier(TatwoLoopsSharingGlow(active: active))
    }
}
