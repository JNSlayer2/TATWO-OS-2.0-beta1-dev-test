import AppKit
import SwiftUI

/// LiquidGlassTokens — 單一真相源 (Single Source of Truth)
///
/// 全部數值出自 Liquid Glass Dashboard export：
/// docs/plans/lgd-export-20260706.json (current.snapshot.computed，「玻璃 1」)
/// docs/plans/lgd-export-20260706.css  (.liquid-glass-layer[data-id=glass-mqw4itdu-p5boy])
///
/// SwiftUI 原生無 shader 對應的欄位（distortion / chromaticAberration）以
/// material 內建折射近似替代，不自造假 shader；差異見收據降級聲明。
enum LiquidGlassTokens {
    // W54_V10_TOKENS_BEGIN
    static let browserInk = Color(red: 42 / 255, green: 39 / 255, blue: 36 / 255)
    static let browserSecondaryInk = Color(red: 93 / 255, green: 86 / 255, blue: 77 / 255)
    static let browserMutedInk = Color(red: 139 / 255, green: 128 / 255, blue: 116 / 255)
    static let browserFieldFill = Color(red: 246 / 255, green: 242 / 255, blue: 234 / 255)
    static let browserFolderFill = Color(red: 154 / 255, green: 163 / 255, blue: 173 / 255)
    static let browserShadowColor = Color(red: 120 / 255, green: 90 / 255, blue: 70 / 255)
    static let browserChipFill = Color(red: 228 / 255, green: 222 / 255, blue: 209 / 255)
    static let browserGroundFill = Color(red: 233 / 255, green: 227 / 255, blue: 215 / 255)
    static let browserSuccessFill = Color(red: 58 / 255, green: 90 / 255, blue: 63 / 255)
    static let browserDownloadBadge = Color(red: 181 / 255, green: 101 / 255, blue: 74 / 255)
    static let islandNoticeWidth: CGFloat = 346
    static let islandNoticeRadius: CGFloat = 22
    static let islandNoticeFill = Color(red: 21 / 255, green: 20 / 255, blue: 18 / 255)
    static let islandNoticeTitleColor = Color(red: 243 / 255, green: 239 / 255, blue: 232 / 255)
    static let islandNoticeDetailColor = Color(red: 184 / 255, green: 176 / 255, blue: 164 / 255)
    static let islandNoticeCountdownColor = Color(red: 142 / 255, green: 134 / 255, blue: 122 / 255)
    static let islandNoticeButtonFill = Color(red: 42 / 255, green: 40 / 255, blue: 37 / 255)
    static let islandNoticeAllowFill = Color(red: 58 / 255, green: 90 / 255, blue: 63 / 255)
    static let islandNoticeTitleSize: CGFloat = 13.5
    static let islandNoticeDetailSize: CGFloat = 11.5
    static let islandNoticeCountdownSize: CGFloat = 10.5
    static let islandNoticeButtonSize: CGFloat = 30
    static let islandNoticeButtonFontSize: CGFloat = 14
    static let islandNoticeInfoSize: CGFloat = 26
    static let islandNoticeInfoFontSize: CGFloat = 13
    static let islandNoticeColumnSpacing: CGFloat = 12
    static let islandNoticeLineSpacing: CGFloat = 2
    static let islandNoticeButtonSpacing: CGFloat = 6
    static let islandNoticeVerticalPadding: CGFloat = 12
    static let islandNoticeLeadingPadding: CGFloat = 16
    static let islandNoticeTrailingPadding: CGFloat = 14
    static let islandNoticeTopInset: CGFloat = 36 // keep the notch clear
    static let islandNoticeShadowOpacity: Double = 0.35
    static let islandNoticeShadowRadius: CGFloat = 25 // CSS blur 50, native radius
    static let islandNoticeShadowY: CGFloat = 18
    static let islandBlankWidth: CGFloat = 596
    static let islandBlankHeight: CGFloat = 124
    // W54_V10_TOKENS_END

    // W67_OMNIBOX_TOKENS_BEGIN
    // Same Dashboard glass material/alpha in both appearances; never route
    // this floating chrome through the opaque matte-theme surface.
    static let browserOmniboxMaterial: Material = .ultraThinMaterial
    static var browserOmniboxLightTint: Color { tint }
    static var browserOmniboxDarkTint: Color { Color(nsColor: .windowBackgroundColor) }
    static let browserOmniboxInk = Color.primary
    static let browserOmniboxMutedInk = Color.secondary
    static let browserOmniboxBorder = Color.primary
    static var browserOmniboxTintOpacity: Double { tintOpacity }
    static var browserOmniboxBorderOpacity: Double { strokeOpacity }
    static var browserOmniboxSelectionOpacity: Double { tintOpacity }
    static func browserOmniboxTint(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: browserOmniboxDarkTint
        default: browserOmniboxLightTint
        }
    }
    // W67_OMNIBOX_TOKENS_END


    // MARK: - Dashboard 原值（Shape / Radius / Tint / Alpha）

    /// Dashboard: shape = 「Rectangle」
    static let shapeStyle: RoundedCornerStyle = .continuous

    /// Dashboard: radiusPx = 34.0（主面板 / sheet 圓角族基準值）；乘主題 radiusScale（fable5 0.5 較方正貼近 Claude）。
    static var radiusPrimary: CGFloat { 34 * TatwoActivePalette.current.radiusScale }

    /// 工程轉譯：卡片圓角，由 34 等比縮小；乘主題 radiusScale。
    static var radiusCard: CGFloat { 20 * TatwoActivePalette.current.radiusScale }

    /// 工程轉譯：小卡 / chip 圓角，由 34 等比縮小；乘主題 radiusScale。
    static var radiusChip: CGFloat { 12 * TatwoActivePalette.current.radiusScale }

    /// Dashboard: glassTint = 「#ffffff」
    static let tint: Color = Color(red: 1, green: 1, blue: 1)

    /// Dashboard: layer.alpha = 0.18（玻璃底 tint 疊層強度）
    static let tintOpacity: Double = 0.18

    // MARK: - Dashboard 原值（Blur / Saturation）

    /// Dashboard: blur = 2.2（作為 material 模糊強度基準檔，非直接可調 sigma）
    static let blurReference: Double = 2.2

    /// Dashboard: saturation = 1.0
    static let saturationReference: Double = 1.0

    // MARK: - 降級聲明（原生無 shader 對應，material 折射近似）

    /// Dashboard: distortion = 1.25 — SwiftUI 原生無 shader 對應，
    /// 由 .ultraThinMaterial 內建折射近似替代；不自造假 shader。見收據降級聲明。
    static let distortionReference: Double = 1.25

    /// Dashboard: chromaticAberration = 0.75 — SwiftUI 原生無 shader 對應，
    /// 由 material 內建折射近似替代；不自造假 shader。見收據降級聲明。
    static let chromaticAberrationReference: Double = 0.75

    // MARK: - Dashboard 原值（Shadow）

    /// Dashboard: shadowIntensity = 0.04
    static let shadowOpacity: Double = 0.04

    /// Dashboard: shadowOffsetX = 0.0
    static let shadowOffsetX: CGFloat = 0

    /// Dashboard: shadowOffsetY = 4.0（docs/plans export 的 current.snapshot.computed；
    /// plan 文字另有 offset 0/0 簡述，工程以 Dashboard export 檔案真值為準）
    static let shadowOffsetY: CGFloat = 4

    /// Dashboard: shadowBlur = 14.0
    static let shadowRadius: CGFloat = 14

    // MARK: - 工程轉譯（standard，非 Dashboard 單一欄位）

    /// 工程轉譯：玻璃邊框亮度，standard 折算
    static let strokeOpacity: Double = 0.22

    /// 工程轉譯：淺色淺底畫布背景色（取代黑底架構圖）；改由 active palette 驅動（隨主題）。
    static var canvasBackground: Color { TatwoActivePalette.current.canvasBase }

    /// 工程轉譯：架構圖節點卡玻璃底不透明度（比主面板更淺，standard 折算）
    static let nodeCardTintOpacity: Double = 0.68

    /// Dashboard: layer.alpha = 0.18 + glassTint #ffffff；工程小卡使用同一 tint 族
    static let subtleFillOpacity: Double = 0.045

    /// Dashboard: layer.alpha = 0.18 + glassTint #ffffff；工程互動 chip 使用同一 tint 族
    static let chipFillOpacity: Double = 0.070

    /// 工程轉譯：降飽和走線基準，呼應 Dashboard saturation = 1.0 且適配淺底畫布
    static let routeLineOpacity: Double = 0.22

    /// 工程轉譯：pulse 柔和光點主 opacity，取代舊式硬跳格亮條
    static let routePulseOpacity: Double = 0.62

    // MARK: - 主題配色（2026-07-12：改由 TatwoTheme active palette 驅動，支援極光/fable5 切換）
    // 這四色 + canvasBackground 一律讀 active palette；切主題時根視圖 observe TatwoThemeStore 觸發全樹重繪。
    // 語意狀態色（綠/橙/紅/.secondary）不在此、永不隨主題變。

    /// 品牌粉（低飽和玫瑰粉）
    static var accentPink: Color { TatwoActivePalette.current.accentPink }
    /// 品牌紫（柔和薰衣草紫）
    static var accentViolet: Color { TatwoActivePalette.current.accentViolet }
    /// 品牌藍（柔和天藍）
    static var accentBlue: Color { TatwoActivePalette.current.accentBlue }
    /// 主色錨點（pill/選取/強調用；比三色更飽和一階）
    static var brandAccent: Color { TatwoActivePalette.current.brandAccent }

    // MARK: Loops 狀態語意色（2026-08-21 使用者回饋「配色不協調」）
    //
    // Loops／PLG 面板原本混用原生 .green/.orange/.red 與 brandAccent，
    // 在兩個主題下都刺眼打架。自此面板狀態色收斂為唯一一組語意 token：
    //   active＝brandAccent、queued/planned＝secondary、
    //   positive（完成/通過）、caution（等待/receipt-gated）、critical（受阻/rollback）。
    // 極光＝冷調（青綠/柔琥珀/柔紅）配紫藍粉世界；
    // fable5＝直接取圖鑑色階（鼠尾草綠/古金/深鏽紅），與牛皮紙同一個古典世界。

    /// 完成／通過。
    static var loopsPositive: Color {
        TatwoActivePalette.current.usesGlass
            ? Color(red: 0.30, green: 0.66, blue: 0.56)
            : Color(red: 0.443, green: 0.529, blue: 0.400)
    }

    /// 等待驗收／receipt-gated／暫停。
    static var loopsCaution: Color {
        TatwoActivePalette.current.usesGlass
            ? Color(red: 0.80, green: 0.60, blue: 0.30)
            : Color(red: 0.722, green: 0.573, blue: 0.318)
    }

    /// 受阻／rollback（真語意紅；fable5 的 brandAccent 赤陶是品牌色不是警示色）。
    static var loopsCritical: Color {
        TatwoActivePalette.current.usesGlass
            ? Color(red: 0.83, green: 0.36, blue: 0.38)
            : Color(red: 0.604, green: 0.267, blue: 0.208)
    }

    /// ultrawork bar / pill / 強調控制的斜向紫藍粉漸變（粉→紫→藍）
    static var ultraworkGradient: LinearGradient {
        LinearGradient(
            colors: [accentPink, accentViolet, accentBlue],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 全視窗背景「極光」漸變（Arc 式：大而柔的多團 radial 疊合，均勻無線性接縫、無色塊）。
    /// 2026-07-12：使用者「顏色一塊一塊超難看／Arc 打得非常均勻」→ 從對角 LinearGradient 改為柔光疊合。
    /// 用途是 app-wide 底色氛圍，玻璃卡/rail 透明疊其上讓同一片極光連續穿過（不再各自成色塊）。
    /// strength 由呼叫端調（window=1.0；menu-bar panel 小面積砍半避免過濃 #23）。回傳 View（多層 radial）。
    static func canvasGradient(_ strength: Double = 1.0) -> some View {
        // 乘上主題 ambient：aurora=1.0 冷 airy；fable5=1.15 暖而有存在感（切主題一眼有別）。
        let a = strength * TatwoActivePalette.current.ambient
        return ZStack {
            RadialGradient(
                gradient: Gradient(colors: [accentPink.opacity(0.13 * a), accentPink.opacity(0)]),
                center: UnitPoint(x: 0.10, y: -0.06), startRadius: 0, endRadius: 820)
            RadialGradient(
                gradient: Gradient(colors: [accentBlue.opacity(0.12 * a), accentBlue.opacity(0)]),
                center: UnitPoint(x: 1.04, y: 1.06), startRadius: 0, endRadius: 940)
            RadialGradient(
                gradient: Gradient(colors: [accentViolet.opacity(0.07 * a), accentViolet.opacity(0)]),
                center: UnitPoint(x: 0.60, y: 0.48), startRadius: 0, endRadius: 780)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 焦點玻璃面板辨識度（對齊使用者參考圖 #31：粉藍漸變填充 + 清透玻璃 rim）
    // 三焦點（聊天輸入筐 / 右資訊卡 / 左工作區）與 ultrawork bar 共用同一組，確保「一樣的設計」。
    //
    // 【來源聲明 os.md §3.6】以下 fillOpacity / rim / highlight 為 **工程轉譯（fog-adjusted）**，
    // 非 Dashboard 單一欄位原值：Dashboard 真值 tint=#fff/alpha .18/blur 2.2/distortion 1.25/
    // chromatic .75 由 LiquidGlassPanelMaterial(WebGL) 承載；此處三值是為了在 SwiftUI 疊層達成
    // 參考圖 #31「粉藍漸變 + 清透玻璃切邊」觀感所加的工程合成層，可依實機觀感微調，不冒充 Dashboard 原參數。

    /// #31：玻璃面板的粉藍漸變「身份填充」強度（疊在 frost 下，給紫粉辨識度，非小塊淡霧）
    /// 2026-07-12：使用者「顏色很重」→ 0.34→0.18，克制。
    static let glassIdentityFillOpacity: Double = 0.18

    /// #31：清透玻璃邊框 rim（左上白高光 → 紫 → 藍），比舊弱白邊亮，讀成一圈玻璃切邊
    static var glassRimGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.82),
                accentViolet.opacity(0.44),
                accentBlue.opacity(0.58)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// #31：玻璃上緣內高光（讓面板頂邊反光，像真玻璃切面）
    static var glassTopHighlight: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
            startPoint: .top, endPoint: .center)
    }

    // MARK: - Loops 算力共享呼吸光暈（左頁標題「浮動光」）
    //
    // 【來源聲明 os.md §3.6】讀自 Liquid Glass Dashboard live storage，2026-07-27，
    // `lgd doctor` pass；layer「玻璃 1」id=glass-mqw4itdu-p5boy：
    //   glassTint #ffffff / alpha 0.18 / shadowBlur 14.0 / shadowIntensity 0.04
    //   shadowOffsetX 0.0 / shadowOffsetY 4.0 / radiusPx 34.0 / blur 2.2
    //
    // Dashboard **沒有** glow / halo / 動畫時間軸這類欄位（可調欄位只有 shape、尺寸、
    // tint、saturation、distortion、blur、chromaticAberration、shadow 四項、layer alpha）。
    // 因此以下拆成兩類，不混為一談：
    //
    //  A. Dashboard 真值直接映射（不可憑感覺改）
    //     - glowRadius        ← shadowBlur 14.0
    //     - glowPeakOpacity   ← layer alpha 0.18（玻璃疊層強度上限，光暈最亮不超過它）
    //     - glowTroughOpacity ← shadowIntensity 0.04（同一層最弱疊層，呼吸下限）
    //
    //  B. 工程近似（**非 Dashboard 真值**，Dashboard 無對應欄位）
    //     - glowBreathPeriod：Dashboard 完全沒有時間軸參數 → 週期自訂。
    //       codebase 既有脈動先例是 WorkingLightRow 的 0.8s；但那是 10pt 小圓點，
    //       同樣速度套到整條標題列會顯得躁動，故放慢到 2.6s 讀成「呼吸」而非「閃爍」。
    //     - glow 色相：Dashboard glassTint 是 #ffffff 無彩，不帶狀態語意；
    //       改用既有 brandAccent token（隨主題走）讓「算力共享中」有辨識度。
    //     - 光暈不帶 Y 位移（Dashboard shadowOffsetY 4.0 是投影的打光方向，
    //       而呼吸光暈是四面均勻的 halo，故兩軸都取 0，與 shadowOffsetX 0.0 一致）。

    /// Dashboard 真值：shadowBlur = 14.0 → 光暈擴散半徑（未經任何縮放）
    static let loopsGlowRadius: CGFloat = 14

    /// 淺底對比補償倍率。
    ///
    /// 2026-07-27 設計裁決（os.md §3.6 允許工程縮放但必須標註）：
    /// Dashboard 的 alpha 真值是在玻璃疊層情境下量的；本 app 的牛皮紙淺色底
    /// 讓同樣的 alpha 讀不出來（實測 0.18 在 1440×900 下低於感知門檻）。
    /// 故對「呼吸上下限」整組等比放大 1.8 倍，**半徑、週期、幾何一律不放大**。
    static let loopsGlowContrastCompensation: Double = 1.8

    /// 可測的來源聲明字串——防止日後有人把這兩個值誤當成 Dashboard 原值搬走。
    static let loopsGlowOpacityProvenance =
        "Dashboard 玻璃層 alpha 0.18 × 1.8 淺底對比補償，工程放大非 Dashboard 真值"

    /// 呼吸最亮 = Dashboard layer alpha 0.18 × 1.8 = 0.32
    /// **工程放大，非 Dashboard 真值**（見 loopsGlowOpacityProvenance）。
    static let loopsGlowPeakOpacity: Double = 0.32

    /// 呼吸最暗 = Dashboard shadowIntensity 0.04 × 1.8 ≈ 0.07（與峰值等比，維持原本明暗比）
    /// **工程放大，非 Dashboard 真值**。
    static let loopsGlowTroughOpacity: Double = 0.07

    /// 工程近似（Dashboard 無時間軸欄位）：一次完整呼吸的單程秒數。
    static let loopsGlowBreathPeriod: Double = 2.6

    // MARK: 幾何與色相（全為工程值；Dashboard 無 halo 形狀／飽和度欄位）
    //
    // 2026-07-27 設計裁決：第一版做成滿寬圓角矩形色帶，被判讀成「標題欄 highlight」
    // 而不是「光」。改為只包住標題內容的橫向橢圓 radial，向外羽化到全透明。
    // Dashboard 錨定的 radius / peak / trough / period 一律不動，只改形狀與色相。

    /// 工程值：光暈超出標題文字邊界的羽化距離（設計指定 12–16pt）。
    static let loopsGlowSpread: CGFloat = 14

    /// 工程值：橫向拉伸倍率，讓 radial 讀成橫躺的橢圓燈暈而不是正圓光點。
    static let loopsGlowHorizontalStretch: CGFloat = 1.45

    /// 工程值：相對 brandAccent 的飽和度縮放。
    /// 原色直接用會讀成「選取態色塊」；降飽和才像燈暈。
    static let loopsGlowSaturationScale: CGFloat = 0.42

    /// 工程值：相對 brandAccent 的亮度調整。
    ///
    /// 2026-07-27 設計指令原文是「降飽和/提亮」，但那個直覺來自深色底的燈暈。
    /// 這個 app 的底是牛皮紙淺色（canvasBase 接近米白），把光暈再提亮會讓它趨近底色，
    /// 實測完全不可見（已用 opacity 1.0 診斷確認幾何正確、純粹是對比度不足）。
    /// 淺底要讓「光」被看見，必須比底稍深而不是更亮 → 此值 < 1（設計裁決已核准）。
    static let loopsGlowBrightnessBoost: CGFloat = 0.86

    /// 工程值：共享中時終端 icon 的暖色 tint 縮放（同色相，比光暈實一階）。
    ///
    /// icon 是小面積實心字形，用光暈那組（sat .42）會糊掉看不出換色；
    /// 但也不能直接用 brandAccent 原色——那是「啟動」按鈕與選取態的既有語彙，
    /// 會讓 icon 讀成可點擊控制項。故取兩者之間。
    static let loopsGlowIconSaturationScale: CGFloat = 0.78
    static let loopsGlowIconBrightnessScale: CGFloat = 0.90

    /// brandAccent 的 HSB 衍生色：色相永遠跟著主題走，只縮放飽和度與亮度。
    private static func accentVariant(
        saturationScale: CGFloat,
        brightnessScale: CGFloat
    ) -> Color {
        let base = NSColor(brandAccent).usingColorSpace(.deviceRGB) ?? .systemPink
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(
            NSColor(
                hue: hue,
                saturation: max(0, min(1, saturation * saturationScale)),
                brightness: max(0, min(1, brightness * brightnessScale)),
                alpha: 1))
    }

    /// 光暈底色：brandAccent 同色相、低飽和、微沉。
    /// 色相跟著主題走，但不直接用 brandAccent 原色（那會變色塊）。
    static var loopsGlowColor: Color {
        accentVariant(
            saturationScale: loopsGlowSaturationScale,
            brightnessScale: loopsGlowBrightnessBoost)
    }

    /// 算力共享中時，標題左側終端 icon 的暖色 tint。
    /// 給光暈一個實心錨點——餘光掃過時的第二訊號。非共享時 icon 回原色（不套此值）。
    static var loopsGlowIconTint: Color {
        accentVariant(
            saturationScale: loopsGlowIconSaturationScale,
            brightnessScale: loopsGlowIconBrightnessScale)
    }
}

extension View {
    /// 全 app 預設主題的淡雅漸變底：底層淺色 + 上疊紫藍粉低透明漸變。放在最外層視窗背景。
    func tatwoCanvasBackground(strength: Double = 1.0) -> some View {
        self.background {
            ZStack {
                LiquidGlassTokens.canvasBackground
                LiquidGlassTokens.canvasGradient(strength)
            }
            .ignoresSafeArea()
        }
    }
}

extension View {
    /// 全 App 表面底：usesGlass=true → 液態玻璃（Dashboard 玻璃1）；false → 扁平牛皮紙（fable5 深度改造，無 blur/透明）。
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat = LiquidGlassTokens.radiusPrimary) -> some View {
        if TatwoActivePalette.current.usesGlass {
            tatwoGlassSurface(cornerRadius: cornerRadius)
        } else {
            tatwoMatteSurface(cornerRadius: cornerRadius)
        }
    }

    /// 液態玻璃表面（極光）：frost + 白 tint + 白高光邊 + 選配噪點。
    func tatwoGlassSurface(cornerRadius: CGFloat) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                            .fill(LiquidGlassTokens.tint.opacity(LiquidGlassTokens.tintOpacity))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                            .strokeBorder(Color.white.opacity(LiquidGlassTokens.strokeOpacity), lineWidth: 1)
                    }
                    .tatwoGrainOverlay(cornerRadius: cornerRadius)
            }
            .shadow(
                color: .black.opacity(LiquidGlassTokens.shadowOpacity),
                radius: LiquidGlassTokens.shadowRadius,
                x: LiquidGlassTokens.shadowOffsetX,
                y: LiquidGlassTokens.shadowOffsetY
            )
    }

    /// 扁平牛皮紙表面（fable5）：不透明暖紙實底 + 暖褐細邊 + 噪點紙紋 + 暖柔陰影。無 material/blur/白高光。
    func tatwoMatteSurface(cornerRadius: CGFloat) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(TatwoActivePalette.current.surfaceFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                            .strokeBorder(TatwoActivePalette.current.surfaceBorder.opacity(0.85), lineWidth: 1)
                    }
                    .tatwoGrainOverlay(cornerRadius: cornerRadius)
            }
            .shadow(color: Color(red: 0.36, green: 0.30, blue: 0.22).opacity(0.12), radius: 9, x: 0, y: 3)
    }

    /// 主題自適應材質底（給散落的 `.background(.ultraThinMaterial, in: shape)` 小卡/chip 統一改用）：
    /// aurora=系統材質玻璃；fable5=扁平牛皮紙實底+暖邊+噪點（不再漏玻璃塊）。
    /// 2026-08-20 極光 P4：加 material 參數承接 .thin/.regular 呼叫點。
    @ViewBuilder
    func tatwoAdaptiveMaterial(
        cornerRadius: CGFloat,
        material: Material = .ultraThinMaterial
    ) -> some View {
        if TatwoActivePalette.current.usesGlass {
            self.background(
                material,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle))
        } else {
            self.tatwoMatteSurface(cornerRadius: cornerRadius)
        }
    }

    /// 主題自適應囊底（Capsule 版，2026-08-20 極光 P4）：
    /// aurora=系統材質；fable5=暖紙實底+暖邊。取代裸 `.background(材質, in: Capsule())`。
    @ViewBuilder
    func tatwoAdaptiveCapsule(material: Material = .ultraThinMaterial) -> some View {
        if TatwoActivePalette.current.usesGlass {
            self.background(material, in: Capsule())
        } else {
            self
                .background(Capsule().fill(TatwoActivePalette.current.surfaceFill))
                .overlay(
                    Capsule().strokeBorder(
                        TatwoActivePalette.current.surfaceBorder.opacity(0.75),
                        lineWidth: 1))
        }
    }

    /// 噪點紙紋 overlay（grain=0 時 no-op）。
    @ViewBuilder
    func tatwoGrainOverlay(cornerRadius: CGFloat) -> some View {
        if TatwoActivePalette.current.grain > 0.0001 {
            self.overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: LiquidGlassTokens.shapeStyle)
                    .fill(ImagePaint(image: Image(nsImage: TatwoPaperGrain.tile), scale: 1))
                    .opacity(TatwoActivePalette.current.grain)
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
            }
        } else {
            self
        }
    }
}
