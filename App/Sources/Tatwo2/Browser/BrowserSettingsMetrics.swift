import Foundation

/// Matches the existing settings spacing and password-card material geometry.
enum BrowserSettingsMetrics {
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsSectionSpacing")
    static let sectionSpacing: CGFloat = BrowserSidebarMetrics.settingsSectionSpacing
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsRowSpacing")
    static let rowSpacing: CGFloat = BrowserSidebarMetrics.settingsRowSpacing
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsCardHorizontalPadding")
    static let cardPadding: CGFloat = BrowserSidebarMetrics.settingsCardHorizontalPadding
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsCardRadius")
    static let cardRadius: CGFloat = BrowserSidebarMetrics.settingsCardRadius
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsPagePadding")
    static let pagePadding: CGFloat = BrowserSidebarMetrics.settingsPagePadding
    @available(*, deprecated, renamed: "BrowserSidebarMetrics.settingsManagementHeight")
    static let managementHeight: CGFloat = BrowserSidebarMetrics.settingsManagementHeight
}
