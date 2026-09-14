import AppKit
import SwiftUI

/// Shared tab label and selection treatment; callers retain their own menus and drag actions.
struct BrowserTabRow: View {
    enum Variant { case workspace, session }
    var variant: Variant = .session
    let title: String
    var host: String? = nil
    var favicon: Data? = nil
    let selected: Bool
    var sleeping = false
    var leadingInset = BrowserSidebarMetrics.childLeadingInset
    var workspaceIconFill: Color = .secondary
    var workspaceIconForeground: Color = .white
    let onSelect: () -> Void

    private var iconSize: CGFloat { variant == .workspace ? BrowserSidebarMetrics.workspaceFaviconSize : BrowserSidebarMetrics.rowIconWidth }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                Group {
                    if let favicon, let image = NSImage(data: favicon) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(variant == .workspace ? workspaceIconForeground : .primary)
                .frame(width: iconSize, height: iconSize)
                .background(variant == .workspace ? workspaceIconFill : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                    Text(title).font(.system(size: variant == .workspace ? BrowserSidebarMetrics.workspaceRowFontSize : BrowserSidebarMetrics.rowFontSize)).lineLimit(1)
                    if variant == .session, let host {
                        Text(host).font(.system(size: BrowserSidebarMetrics.metaFontSize))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, BrowserSidebarMetrics.rowVerticalPadding)
            .padding(.trailing, variant == .workspace ? 0 : BrowserSidebarMetrics.rowHorizontalPadding)
            .padding(.leading, variant == .workspace ? BrowserSidebarMetrics.rowHorizontalPadding : leadingInset)
            .frame(minHeight: variant == .workspace ? BrowserSidebarMetrics.workspaceRowMinHeight : 0)
            .contentShape(Rectangle())
            .background(selected && variant == .session ? Color(red: 246 / 255, green: 242 / 255, blue: 234 / 255) : .clear,
                in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(sleeping ? .tertiary : .primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bot ownership is visible in Session space, without introducing a bot browser surface.
struct BrowserBotTabRows: View {
    let tabs: [BrowserTab]
    var body: some View {
        ForEach(tabs) { tab in
            BrowserTabRow(title: tab.title, host: tab.url?.host ?? "about:blank",
                favicon: tab.faviconPNG, selected: false, sleeping: tab.isSleeping, onSelect: {})
                .disabled(true)
        }
    }
}
