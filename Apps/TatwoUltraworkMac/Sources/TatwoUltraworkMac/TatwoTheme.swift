import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// TATWO 主題系統（2026-07-12 使用者定案：預設極光 + fable5 紀念主題，設定/主題/選擇主題可切換）。
//
// 設計原則（承 skill §5.1/§5.3）：
// - palette 是主題唯一可變資料；LiquidGlassTokens 的 accent/brand/canvas 一律讀 active palette。
// - 語意狀態色（綠就緒/橙執行/紅錯誤/.secondary）不進 palette、永不隨主題變。
// - 玻璃 shader 參數（R34/alpha.18/blur2.2…）恆定，不隨主題變；主題只換「色」不換「材質幾何」。

enum TatwoThemeID: String, CaseIterable, Codable, Sendable {
    case aurora   // 預設：紫藍粉極光
    case fable5   // fable5 與 sol 協作紀念

    var displayName: String {
        switch self {
        case .aurora: return "極光"
        case .fable5: return "Fable5 紀念"
        }
    }

    var subtitle: String {
        switch self {
        case .aurora: return "紫藍粉・淡雅預設"
        case .fable5: return "古典植物圖鑑・限定紀念"
        }
    }
}

struct TatwoThemePalette: Sendable {
    let accentPink: Color
    let accentViolet: Color
    let accentBlue: Color
    /// 選取/pill/強調錨點（比三色更飽和一階）。切主題時 UI 上最明顯的差異來源。
    let brandAccent: Color
    /// 淺底畫布基色（玻璃卡疊其上）；冷/暖傾向讓整片背景一眼有別。
    let canvasBase: Color
    /// 背景極光氛圍強度乘數（1.0=預設；紀念主題可略強營造氛圍，不至於「顏色很重」）。
    let ambient: Double
    /// 紙紋噪點強度（0=無；fable5 用細噪點做「牛皮紙」質感，套在底板與玻璃按鈕上）。使用者 2026-07-12。
    let grain: Double
    /// 表面材質：true=液態玻璃(frost+blur+translucent)；false=扁平牛皮紙(不透明實底+暖邊，無 blur)。
    /// 使用者 2026-07-12：「fable5 主題就不要玻璃了 深度改造」——fable5 走 matte 貼近 Claude 暖紙美學。
    let usesGlass: Bool
    /// matte 卡片/按鈕實底色（僅 usesGlass=false 時用）。
    let surfaceFill: Color
    /// matte 卡片/按鈕暖邊色（僅 usesGlass=false 時用）。
    let surfaceBorder: Color
    /// 圓角縮放（1.0=極光原值圓潤；fable5=0.5 較方正，貼近 Claude R 角）。使用者 2026-07-12「claude的r角比較方正」。
    let radiusScale: Double
}

struct TatwoTheme: Identifiable, Sendable {
    let id: TatwoThemeID
    let palette: TatwoThemePalette
    /// 限定紀念文字；僅特定主題有（fable5），其餘為 nil。顯示在設定/主題卡與 About。
    let commemorativeText: String?

    // 預設極光：冷色紫藍粉，airy 清透、無紙紋。沿用 2026-07-11 定案，切回預設 0 視覺變化。
    static let aurora = TatwoTheme(
        id: .aurora,
        palette: TatwoThemePalette(
            accentPink: Color(red: 0.937, green: 0.773, blue: 0.878),
            accentViolet: Color(red: 0.757, green: 0.682, blue: 0.949),
            accentBlue: Color(red: 0.667, green: 0.780, blue: 1.0),
            brandAccent: Color(red: 0.545, green: 0.451, blue: 0.925),
            canvasBase: Color(red: 0.965, green: 0.965, blue: 0.972),
            ambient: 1.0,
            grain: 0.0,
            usesGlass: true,
            surfaceFill: Color.white,
            surfaceBorder: Color.white,
            radiusScale: 1.0
        ),
        commemorativeText: nil
    )

    // fable5 紀念：古典自然史／植物圖鑑（使用者 #56/#57 風格）——做舊牛皮紙底 + 細噪點紙紋 + 和諧植物色階。
    // 色階呼應圖鑑：珊瑚橘（花）、鼠尾草綠（葉）、古金（花蕊）、赤陶（蝶翅紅）。與冷色極光是「另一個古典世界」。紀念 fable5 與 sol 協作。
    static let fable5 = TatwoTheme(
        id: .fable5,
        palette: TatwoThemePalette(
            accentPink: Color(red: 0.867, green: 0.565, blue: 0.478),   // 珊瑚橘（褪色花）
            accentViolet: Color(red: 0.502, green: 0.576, blue: 0.463), // 鼠尾草綠（圖鑑葉）
            accentBlue: Color(red: 0.831, green: 0.686, blue: 0.416),   // 古金 / 赭黃（花蕊）
            brandAccent: Color(red: 0.729, green: 0.400, blue: 0.310),  // 赤陶／鏽紅錨點（古典暖，非語意紅）
            canvasBase: Color(red: 0.914, green: 0.882, blue: 0.816),   // 做舊牛皮紙米底（比卡片略深，卡片浮起）
            ambient: 1.15,
            grain: 0.085,                                                // 造點略增，向小視窗(工具列)的Claude感靠攏(使用者:大視窗造點少一點)
            usesGlass: false,                                            // 深度改造：不要玻璃
            surfaceFill: Color(red: 0.968, green: 0.949, blue: 0.906),   // 卡片/按鈕＝較亮暖紙（扁平不透明）
            surfaceBorder: Color(red: 0.792, green: 0.729, blue: 0.639), // 暖褐邊（乾淨細線，非玻璃高光）
            radiusScale: 0.5                                             // Claude 式方正 R 角
        ),
        commemorativeText: "紀念 fable5 與 sol 協作搭建 · 始於 2026 年 6 月"
    )

    static func theme(for id: TatwoThemeID) -> TatwoTheme {
        switch id {
        case .aurora: return aurora
        case .fable5: return fable5
        }
    }

    static var all: [TatwoTheme] { TatwoThemeID.allCases.map(theme(for:)) }
}

/// 非隔離 active palette 快取：LiquidGlassTokens 的 static 取色器讀這裡，避免 @MainActor 汙染散落全 app 的 token 存取。
/// 只在主執行緒（TatwoThemeStore.didSet）寫入；讀是 value-type 複製，無資料競爭。
enum TatwoActivePalette {
    nonisolated(unsafe) static var current: TatwoThemePalette = TatwoTheme.aurora.palette
    nonisolated(unsafe) static var commemorativeText: String? = nil
}

@MainActor
final class TatwoThemeStore: ObservableObject {
    static let shared = TatwoThemeStore()
    private static let key = "tatwo.activeThemeID"

    @Published var activeThemeID: TatwoThemeID {
        didSet { apply() }
    }

    var active: TatwoTheme { TatwoTheme.theme(for: activeThemeID) }

    private init() {
        // headless 自驗 / 開發覆寫優先；否則讀持久化；再否則預設極光。
        let envID = ProcessInfo.processInfo.environment["TATWO_ULTRAWORK_THEME"]
            .flatMap(TatwoThemeID.init(rawValue:))
        let raw = UserDefaults.standard.string(forKey: Self.key)
        activeThemeID = envID ?? raw.flatMap(TatwoThemeID.init(rawValue:)) ?? .aurora
        apply()
    }

    func select(_ id: TatwoThemeID) {
        guard id != activeThemeID else { return }
        activeThemeID = id
    }

    private func apply() {
        let theme = active
        TatwoActivePalette.current = theme.palette
        TatwoActivePalette.commemorativeText = theme.commemorativeText
        UserDefaults.standard.set(activeThemeID.rawValue, forKey: Self.key)
    }
}

// MARK: - 牛皮紙噪點紙紋（fable5 質感；使用者 2026-07-12「噪點、牛皮紙、和諧色階可用在底板跟按鈕」）

/// 單色噪點 tile：全 app 共用、只用 Core Image 生成一次並緩存。tile 可平鋪填滿任意大小。
enum TatwoPaperGrain {
    nonisolated(unsafe) static let tile: NSImage = makeTile(side: 180)

    private static func makeTile(side: Int) -> NSImage {
        let size = NSSize(width: side, height: side)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else {
            return NSImage(size: size)
        }
        // 去飽和 → 單色顆粒；裁成有限 tile。
        let mono = noise.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        let cropped = mono.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let rep = NSCIImageRep(ciImage: cropped)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        img.cacheMode = .always
        return img
    }
}

/// 底板用噪點層：放進 ZStack 以 .multiply 疊在 backdrop/漸變之上、內容之下。grain=0（極光）時不渲染。
struct TatwoPaperGrainLayer: View {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    var body: some View {
        let g = TatwoActivePalette.current.grain
        if g > 0.0001 {
            Image(nsImage: TatwoPaperGrain.tile)
                .resizable(resizingMode: .tile)
                .opacity(g)
                .blendMode(.multiply)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// 依 active 主題在某形狀內疊噪點紙紋（用於玻璃卡/按鈕）；grain=0 時 no-op。
    @ViewBuilder
    func tatwoPaperGrain(cornerRadius: CGFloat) -> some View {
        let g = TatwoActivePalette.current.grain
        if g > 0.0001 {
            self.overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(ImagePaint(image: Image(nsImage: TatwoPaperGrain.tile), scale: 1))
                    .opacity(g)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
