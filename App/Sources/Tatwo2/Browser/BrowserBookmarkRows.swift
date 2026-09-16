import SwiftUI

/// Selection and close are siblings: closing must never reopen the bookmark.
struct BrowserBookmarkRow: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let bookmark: BrowserWorkSpaceStore.Bookmark
    let folderID: UUID
    @State private var hovering = false

    var body: some View {
        let tab = store.tab(forBookmark: bookmark.id)
        let selected = tab.map { store.selectedID == $0.id } ?? false
        let status = tab.map { $0.loading ? "載入中" : $0.sleeping ? "睡眠中" : "已開啟" } ?? "未開啟"
        HStack(spacing: BrowserSidebarMetrics.childGap) {
            BrowserTabRow(variant: .workspace, title: bookmark.title,
                tabID: tab?.registryID?.uuidString ?? bookmark.id.uuidString,
                favicon: tab?.faviconPNG, selected: selected, sleeping: tab?.sleeping ?? false,
                loading: tab?.loading ?? false, workspaceIconFill: LiquidGlassTokens.browserFolderFill,
                workspaceIconForeground: LiquidGlassTokens.browserFieldFill,
                onSelect: { store.openBookmark(bookmark, folderID: folderID) })
                .accessibilityIdentifier("browser.bookmark.\(bookmark.id)")
                .accessibilityValue(status)
            if tab != nil {
                BrowserBookmarkCloseButton(hovering: hovering,
                    label: "關閉這個書籤的分頁", identifier: "browser.bookmark.close.\(bookmark.id)") {
                    store.closeBookmark(bookmark.id)
                }
            }
        }
        .background(selected ? LiquidGlassTokens.browserFieldFill : .clear,
            in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.rowCornerRadius))
        .padding(.leading, BrowserSidebarMetrics.workspaceFaviconSize)
        .help(bookmark.url)
        .onHover { hovering = $0 }
    }
}

struct BrowserBookmarkFolderRow: View {
    @ObservedObject var store: BrowserWorkSpaceStore
    let folder: BrowserWorkSpaceStore.Folder
    @State private var hovering = false

    var body: some View {
        HStack(spacing: BrowserSidebarMetrics.childGap) {
            Button { store.toggleFolder(folder.id) } label: {
                HStack(spacing: BrowserSidebarMetrics.rowSpacing) {
                    Image(systemName: "folder.fill").foregroundStyle(LiquidGlassTokens.browserFolderFill)
                        .frame(width: BrowserSidebarMetrics.rowIconWidth)
                    HStack(spacing: BrowserSidebarMetrics.childGap) {
                        Text(folder.name).fontWeight(.bold).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: BrowserSidebarMetrics.faviconFontSize, weight: .bold))
                            .rotationEffect(.degrees(folder.chevronExpanded ? BrowserSidebarMetrics.chevronExpandedAngle : BrowserSidebarMetrics.chevronCollapsedAngle))
                    }
                    Spacer(minLength: BrowserSidebarMetrics.zero)
                }
                .padding(BrowserSidebarMetrics.rowHorizontalPadding).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(folder.name)
            .accessibilityIdentifier("browser.folder.\(folder.id)")
            if store.folderHasOpenTabs(folder.id) {
                BrowserBookmarkCloseButton(hovering: hovering,
                    label: "關閉這個資料夾的所有分頁", identifier: "browser.folder.close.\(folder.id)") {
                    store.closeFolderTabs(folder.id)
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct BrowserBookmarkCloseButton: View {
    let hovering: Bool
    let label: String
    let identifier: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: BrowserSidebarMetrics.closeGlyphSize, weight: .semibold))
                .frame(width: BrowserSidebarMetrics.closeButtonSize, height: BrowserSidebarMetrics.closeButtonSize)
                .background(LiquidGlassTokens.browserFolderFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(LiquidGlassTokens.browserInk)
        .focused($focused)
        .accessibilityLabel(label).accessibilityIdentifier(identifier)
        .help(label)
        .opacity(hovering || focused ? BrowserSidebarMetrics.visibleOpacity : BrowserSidebarMetrics.hiddenOpacity)
        .allowsHitTesting(hovering || focused)
    }
}
