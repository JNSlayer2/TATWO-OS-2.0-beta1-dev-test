import AppKit
import SwiftUI

/// Shared tab label and selection treatment; callers retain their own menus and drag actions.
struct BrowserTabRow: View {
    enum Variant { case workspace, session }
    var variant: Variant = .session
    let title: String
    let tabID: String
    var host: String? = nil
    var favicon: Data? = nil
    let selected: Bool
    var sleeping = false
    var loading = false
    var leadingInset = BrowserSidebarMetrics.childLeadingInset
    var workspaceIconFill: Color = .secondary
    var workspaceIconForeground: Color = .white
    let onSelect: () -> Void

    private var iconSize: CGFloat { variant == .workspace ? BrowserSidebarMetrics.workspaceFaviconSize : BrowserSidebarMetrics.rowIconWidth }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                Group {
                    if loading {
                        ProgressView().controlSize(.mini).accessibilityLabel("載入中")
                    } else if let favicon, let image = NSImage(data: favicon) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "globe").foregroundStyle(.secondary) }
                }
                .font(.system(size: BrowserSidebarMetrics.faviconFontSize, weight: .bold))
                .foregroundStyle(variant == .workspace ? workspaceIconForeground : .primary)
                .frame(width: iconSize, height: iconSize)
                .background(variant == .workspace ? workspaceIconFill : .clear,
                    in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.faviconCornerRadius))
                VStack(alignment: .leading, spacing: BrowserSidebarMetrics.childGap) {
                    Text(title).font(.system(size: variant == .workspace ? BrowserSidebarMetrics.workspaceRowFontSize : BrowserSidebarMetrics.rowFontSize)).lineLimit(1)
                    if variant == .session, let host {
                        Text(host).font(.system(size: BrowserSidebarMetrics.metaFontSize))
                            .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(1)
                    }
                }
                if sleeping {
                    Text("睡眠中").font(.system(size: BrowserSidebarMetrics.sleepingFontSize))
                        .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(BrowserSidebarMetrics.singleLine)
                }
                Spacer(minLength: BrowserSidebarMetrics.zero)
                if variant == .workspace, selected, let host, !host.isEmpty {
                    Text(host).font(.system(size: BrowserSidebarMetrics.selectedHostFontSize))
                        .foregroundStyle(selected ? LiquidGlassTokens.browserMutedInk : Color.secondary).lineLimit(BrowserSidebarMetrics.singleLine)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, BrowserSidebarMetrics.rowVerticalPadding)
            .padding(.trailing, variant == .workspace ? BrowserSidebarMetrics.zero : BrowserSidebarMetrics.rowHorizontalPadding)
            .padding(.leading, variant == .workspace ? BrowserSidebarMetrics.rowHorizontalPadding : leadingInset)
            .frame(minHeight: variant == .workspace ? BrowserSidebarMetrics.workspaceRowMinHeight : BrowserSidebarMetrics.zero)
            .contentShape(Rectangle())
            .background(selected && variant == .session ? LiquidGlassTokens.browserFieldFill : .clear,
                in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? LiquidGlassTokens.browserInk : Color.primary)
        .opacity(sleeping ? BrowserSidebarMetrics.sleepingOpacity : BrowserSidebarMetrics.visibleOpacity)
        .accessibilityLabel(title)
        .accessibilityIdentifier("browser.tab.\(tabID)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Bot ownership is visible in Session space, without introducing a bot browser surface.
struct BrowserBotTabRows: View {
    let tabs: [BrowserTab]
    var body: some View {
        ForEach(tabs) { tab in
            BrowserTabRow(title: tab.title, tabID: tab.id.uuidString, host: tab.url?.host ?? "about:blank",
                favicon: tab.faviconPNG, selected: false, sleeping: tab.isSleeping, onSelect: {})
                .disabled(true)
        }
    }
}
