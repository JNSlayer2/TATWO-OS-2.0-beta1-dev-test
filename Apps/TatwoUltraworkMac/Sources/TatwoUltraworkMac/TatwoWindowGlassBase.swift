import AppKit
import SwiftUI

/// 極光最底層（2026-08-20 使用者裁決：「最底版也要有液態效果」）。
///
/// 設計語言：視窗底不再是一塊寫死的不透明純色，而是真 behind-window
/// 系統材質——island 驗證過的「原生材質路線」的視窗級對應；極光的
/// 顏色身份由其上的 canvasGradient 淡漸變承擔（玻璃管質感、漸變管
/// 身份）。fable5 紀念主題維持自己的不透明牛皮紙底（canvasBase），
/// 同時終結「fable5 坐在極光冷色視窗底上」的反向污染。
///
/// 防舊傷（使用者曾申訴透底破色／頂部切割／刺眼，見
/// ChatWindowCanvasBackdrop 沿革註解）：玻璃上鋪一層極光底色柔紗，
/// 桌面只留質感與明暗呼吸，不搶色、不干擾閱讀。
struct TatwoWindowGlassBase: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared

    var body: some View {
        Group {
            if TatwoActivePalette.current.usesGlass {
                ZStack {
                    TatwoBehindWindowMaterial()
                    LiquidGlassTokens.canvasBackground.opacity(0.55)
                    Rectangle().fill(Color.white.opacity(0.10))
                }
            } else {
                LiquidGlassTokens.canvasBackground
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 視窗級 behind-window 系統材質：取景真實桌面/後方視窗，明暗隨系統
/// 外觀自適應（appearance 交還系統，不鎖死）。
struct TatwoBehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        view.appearance = nil
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
