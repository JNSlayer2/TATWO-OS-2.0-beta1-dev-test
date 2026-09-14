import Foundation

/// Shared by Chat, CLI, Bot and new workspace templates.
enum WorkspaceSidebarMetrics {
    // 2026-09-11 使用者：整體試用舊版 Bot 分頁的比例（Gen-4 側欄 250pt）。
    // 註：2026-08-26 曾回饋 250pt 讓三分頁與搜尋列過窄，這是試用版。
    static let width: CGFloat = 250
    static let browserFocusWidth: CGFloat = 132
    // LiquidGlassPanelCard supplies the common 18pt outer inset.
    // 2026-09-11 使用者：Chat/CLI/Bot 分頁條整體再調高（新模板同規格）；搜尋等下方內容跟著上移。
    static let headerTopInset: CGFloat = 22
    static let sectionSpacing: CGFloat = 10
}

/// Browser work space sidebar rows and cards. Values come from the approved mockup
/// (docs/reviews/browser-workspace-mockup-v9-session-space.html); change them there first.
enum BrowserSidebarMetrics {
    static let workspaceRowFontSize: CGFloat = 13.5
    static let workspaceRowMinHeight: CGFloat = 34
    static let workspaceFaviconSize: CGFloat = 16
    static let chatTabWidth: CGFloat = 180
    static let controlHitSize: CGFloat = 32
    static let rowFontSize: CGFloat = 13          // folder / tab title
    static let metaFontSize: CGFloat = 11.5       // host / secondary line
    static let rowVerticalPadding: CGFloat = 7
    static let rowHorizontalPadding: CGFloat = 8
    static let rowIconWidth: CGFloat = 18
    static let rowSpacing: CGFloat = 9
    static let rowCornerRadius: CGFloat = 9
    static let childLeadingInset: CGFloat = 30    // tab rows nested under a folder
    static let childGap: CGFloat = 2
    static let dividerHorizontalInset: CGFloat = 6
    static let dividerVerticalInset: CGFloat = 10
    static let captionPadding: CGFloat = 8
    static let spaceDotSize: CGFloat = 5
    static let spaceDotStroke: CGFloat = 1.2
    static let spaceDotHitWidth: CGFloat = 24
    static let spaceDotHitHeight: CGFloat = 28
    /// Session lane card in the content area.
    static let laneCardWidth: CGFloat = 520
    static let laneCardPadding: CGFloat = 20
    static let laneCardOuterInset: CGFloat = 24
    static let laneCardCornerRadius: CGFloat = 15
    static let laneRowSpacing: CGFloat = 12
    static let laneThumbSize = CGSize(width: 64, height: 44)
    static let laneThumbCornerRadius: CGFloat = 7

    /// W49 import sheet: engineering translation of the existing sidebar/card scale.
    /// Animation/visual acceptance remains a separate human gate.
    static let importSheetWidth: CGFloat = 560
    static let importSheetHeight: CGFloat = 640
    static let importTitleSize: CGFloat = 24
    static let importHeroSize: CGFloat = 48
    static let importProgressSize: CGFloat = 64
    static let importProgressStroke: CGFloat = 5
    static let importStepCount = 4
    static let importSourceColumns = 2
    static let importAnimationDuration: TimeInterval = 0.25
    /// Diagnostics sheet (W55).
    static let diagnosticsIdealWidth: CGFloat = 820
    static let diagnosticsMinHeight: CGFloat = 520
    static let diagnosticsIdealHeight: CGFloat = 680
}
