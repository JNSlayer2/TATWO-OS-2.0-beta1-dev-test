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
    static let browserContentGap: CGFloat = 0
    static let contentGap: CGFloat = 12
    static let spaceSwitcherHeight: CGFloat = 22
    static let spaceSwitcherWidth: CGFloat = 132
    static let spaceSwitcherFontSize: CGFloat = 12.5
    static let spaceSwitcherChevronSize: CGFloat = 10
    static let spaceSwitcherSpacing: CGFloat = 6
    static let spaceSwitcherHorizontalInset: CGFloat = 8
    // 側欄開關與固定鈕：與空間切換器同一條紅綠燈帶，跟在膠囊右側。
    static let sidebarControlSize: CGFloat = 22
    static let sidebarControlIconSize: CGFloat = 12
    static let sidebarControlGap: CGFloat = 4
    /// 膠囊自己的寬度：整列總寬扣掉兩顆鈕與間隙，整列才不會撐出紅綠燈帶。
    static let spaceSwitcherMenuWidth: CGFloat =
        spaceSwitcherWidth - 2 * (sidebarControlSize + sidebarControlGap)
}

/// Bot's approved 6pt dots / 8pt gaps. Browser uses the same centered cells;
/// a session space remains a ring, never a filled ordinary-space dot.
enum WorkspaceSpaceControlMetrics {
    static let dotSize: CGFloat = 6
    static let visualGap: CGFloat = 8
    static let itemSpacing: CGFloat = 0
    static let cellWidth: CGFloat = dotSize + visualGap
    static let cellHeight: CGFloat = 28
    static let plusFontSize: CGFloat = 9
    static let ringStroke: CGFloat = 1.2
    static let zero: CGFloat = 0
    static let footerAccessoryWidth: CGFloat = 28
}

/// Browser work space sidebar rows and cards. Values come from the approved mockup
/// (docs/reviews/browser-workspace-mockup-v10.html); W54 changes presentation only.
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
    static let closeButtonSize: CGFloat = 20
    static let closeGlyphSize: CGFloat = 10
    /// Session lane card in the content area.
    static let laneCardWidth: CGFloat = 520
    static let laneCardPadding: CGFloat = 20
    static let laneCardOuterInset: CGFloat = 24
    static let laneCardCornerRadius: CGFloat = 15
    static let laneRowSpacing: CGFloat = 12
    static let laneThumbSize = CGSize(width: 64, height: 44)
    static let laneThumbCornerRadius: CGFloat = 7

    /// v10 live single-scene dialog; scrolling preserves long error/CSV details.
    static let importSheetWidth: CGFloat = 860
    static let importSheetHeight: CGFloat = 420
    static let importTitleSize: CGFloat = 16
    @available(*, deprecated, renamed: "importKeySize")
    static let importHeroSize: CGFloat = importKeySize
    static let importProgressSize: CGFloat = 40
    static let importProgressStroke: CGFloat = 5
    static let importStepCount = 4
    static let importSourceColumns = 4
    static let importAnimationDuration: TimeInterval = 0.25
    // Existing search/sidebar scale, centralized without changing its geometry.
    static let hairline: CGFloat = 1
    static let controlGap: CGFloat = 4
    static let extensionFontSize: CGFloat = 8.5
    static let searchFontSize: CGFloat = 14.5
    static let searchIconSize: CGFloat = 16
    static let searchTopInset: CGFloat = 13
    static let searchBottomInset: CGFloat = 11
    static let searchButtonSize: CGFloat = 30
    static let searchMaxWidth: CGFloat = 560
    static let searchGlowWidth: CGFloat = 780
    static let searchGlowHeight: CGFloat = 460
    static let searchGlowRadius: CGFloat = 230
    static let searchGlowOpacity: Double = 0.16
    static let searchButtonOpacity: Double = 0.45
    static let searchShadowOpacity: Double = 0.18
    static let searchShadowRadius: CGFloat = 17
    static let searchSuggestionsOffset: CGFloat = 104
    static let selectedRowShadowOpacity: Double = 0.14
    static let thumbnailFillOpacity: Double = 0.3
    static let tabSearchWidth: CGFloat = 480
    static let tabSearchMaxHeight: CGFloat = 320
    static let tabSearchScrimOpacity: Double = 0.85
    static let legacyProfileWidth: CGFloat = 220
    static let legacyImportNoteOpacity: Double = 0.25
    static let chevronExpandedAngle: Double = 90
    static let chevronCollapsedAngle: Double = 0
    static let chevronAnimationDuration: TimeInterval = 0.18
    static let importProgressInset: CGFloat = importProgressStroke / 2

    // MARK: - W54 v10 browser presentation (not navigation/security policy)
    static let zero: CGFloat = 0
    static let visibleOpacity: Double = 1
    static let hiddenOpacity: Double = 0
    static let singleLine = 1
    static let faviconFontSize: CGFloat = 10
    static let faviconCornerRadius: CGFloat = 4
    static let sleepingOpacity: Double = 0.55
    static let sleepingFontSize: CGFloat = 10.5
    static let selectedHostFontSize: CGFloat = 11
    static let addressSuggestionOpacity: Double = 0.15
    static let omniboxHeight: CGFloat = 34
    static let omniboxCornerRadius: CGFloat = 9
    static let omniboxFontSize: CGFloat = 12.5
    static let omniboxHintFontSize: CGFloat = 11
    static let omniboxHorizontalPadding: CGFloat = 12
    static let omniboxSpacing: CGFloat = 8
    static let omniboxLockWidth: CGFloat = 10
    static let omniboxLockHeight: CGFloat = 12
    static let omniboxOuterHorizontalPadding: CGFloat = 16
    static let omniboxOuterVerticalPadding: CGFloat = 12
    static let downloadsWidth: CGFloat = 226
    static let downloadsMaxListHeight: CGFloat = 420
    static let downloadsMinimumListHeight: CGFloat = 32
    static let downloadsCornerRadius: CGFloat = 12
    static let downloadsPadding: CGFloat = 10
    static let downloadsSpacing: CGFloat = 8
    static let downloadRowPadding: CGFloat = 6
    static let downloadRowSpacing: CGFloat = 5
    static let downloadRowCornerRadius: CGFloat = 8
    static let downloadTitleFontSize: CGFloat = 12.5
    static let downloadMetaFontSize: CGFloat = 11
    static let downloadActionFontSize: CGFloat = 11.5
    static let downloadActionSpacing: CGFloat = 10
    static let downloadProgressHeight: CGFloat = 4
    static let downloadProgressRadius: CGFloat = 2
    static let downloadProgressOpacity: Double = 0.8
    static let downloadBadgeSize: CGFloat = 6
    static let downloadBadgeOffsetX: CGFloat = 5
    static let downloadBadgeOffsetY: CGFloat = -2
    static let footerControlSize: CGFloat = 28
    static let stateIconSize: CGFloat = 22
    static let stateTitleFontSize: CGFloat = 12
    static let stateDetailMaxWidth: CGFloat = 420
    static let importSheetCornerRadius: CGFloat = 14
    static let importTopPadding: CGFloat = 18
    static let importHorizontalPadding: CGFloat = 20
    static let importBottomPadding: CGFloat = 16
    static let importBodyFontSize: CGFloat = 12.5
    static let importStepSpacing: CGFloat = 6
    static let importStepPadding: CGFloat = 6
    static let importStepRadius: CGFloat = 8
    static let importStepFillOpacity: Double = 0.14
    static let importStepBorderOpacity: Double = 0.35
    static let importStepBorderWidth: CGFloat = 1
    static let importPaneRadius: CGFloat = 11
    static let importPanePadding: CGFloat = 14
    static let importPaneMinHeight: CGFloat = 178
    static let importSourceFontSize: CGFloat = 12
    static let importSourceIconSize: CGFloat = 18
    static let importSourceVerticalPadding: CGFloat = 6
    static let importSourceHorizontalPadding: CGFloat = 8
    static let importSourceFillOpacity: Double = 0.10
    static let importSourceBorderOpacity: Double = 0.7
    static let importSourceBorderWidth: CGFloat = 1.5
    static let importDataColumns = 2
    static let importDataColumnSpacing: CGFloat = 18
    static let importDataRowSpacing: CGFloat = 6
    static let importKeySize: CGFloat = 44
    static let importKeyFontSize: CGFloat = 22
    static let importKeyRadius: CGFloat = 12
    static let importProgressFontSize: CGFloat = 10
    static let importProgressRotation: Double = -90
    static let importCompletionSize: CGFloat = 22
    static let importCompletionFontSize: CGFloat = 12
    static let settingsNavWidth: CGFloat = 168
    static let settingsSectionSpacing: CGFloat = 12
    static let settingsRowSpacing: CGFloat = 6
    static let settingsCardVerticalPadding: CGFloat = 12
    static let settingsCardHorizontalPadding: CGFloat = 14
    static let settingsCardRadius: CGFloat = 12
    static let settingsPagePadding: CGFloat = 22
    static let settingsManagementHeight: CGFloat = 420
    static let settingsBodyFontSize: CGFloat = 12.5
    static let settingsTitleFontSize: CGFloat = 13
    static let settingsPageTitleFontSize: CGFloat = 18
    static let settingsNumberSize: CGFloat = 18
    static let settingsNumberFontSize: CGFloat = 10.5
    static let settingsKeyWidth: CGFloat = 150
    static let settingsColumnSpacing: CGFloat = 12
    static let settingsSecurityColumnSpacing: CGFloat = 14
    static let settingsControlFontSize: CGFloat = 11.5
    static let settingsControlRadius: CGFloat = 7
    static let settingsControlVerticalPadding: CGFloat = 3
    static let settingsControlHorizontalPadding: CGFloat = 9
    static let settingsDisabledOpacity: Double = 0.5
    static let passwordRowSpacing: CGFloat = 4
    static let passwordDetailSpacing: CGFloat = 3
    static let passwordRowPadding: CGFloat = 8
    static let passwordDividerOpacity: Double = 0.4

    /// Diagnostics sheet (W55).
    static let diagnosticsIdealWidth: CGFloat = 820
    static let diagnosticsMinHeight: CGFloat = 520
    static let diagnosticsIdealHeight: CGFloat = 680
}
