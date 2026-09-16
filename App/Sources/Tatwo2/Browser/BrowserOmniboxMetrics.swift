import SwiftUI

/// W67 compact address chrome. Layout translations, not new glass colours.
enum BrowserOmniboxMetrics {
    static let zero: CGFloat = 0
    static let collapsedHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 48
    static let expandedFieldHeight: CGFloat = 36
    static let panelMinimumHeight: CGFloat = 68
    static let panelMaximumWidth: CGFloat = 560
    static let suggestionMaximumHeight: CGFloat = 240
    static let suggestionRowHeight: CGFloat = 32
    static let horizontalInset: CGFloat = 8
    static let controlGap: CGFloat = 4
    static let panelGap: CGFloat = 4
    static let panelPadding: CGFloat = 8
    static let collapsedRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
    static let strokeWidth: CGFloat = 1
    static let domainFontSize: CGFloat = 13
    static let editorFontSize: CGFloat = 13
    static let hintFontSize: CGFloat = 11
    static let iconSize: CGFloat = 14
    static let chromeZIndex: Double = 1
    static let expansionDuration: Double = 0.18
    static let historyDebounce: Duration = .milliseconds(120)
}
