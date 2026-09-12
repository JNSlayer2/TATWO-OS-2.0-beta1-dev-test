import Foundation

/// Shared by Chat, CLI, Bot and new workspace templates.
enum WorkspaceSidebarMetrics {
    // 2026-09-11 使用者：整體試用舊版 Bot 分頁的比例（Gen-4 側欄 250pt）。
    // 註：2026-08-26 曾回饋 250pt 讓三分頁與搜尋列過窄，這是試用版。
    static let width: CGFloat = 250
    // LiquidGlassPanelCard supplies the common 18pt outer inset.
    // 2026-09-11 使用者：Chat/CLI/Bot 分頁條整體再調高（新模板同規格）；搜尋等下方內容跟著上移。
    static let headerTopInset: CGFloat = 22
    static let sectionSpacing: CGFloat = 10
}
