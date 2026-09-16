import SwiftUI

/// One Dia-style control: open and keep the sidebar, or release and collapse it.
struct BrowserSidebarControls: View {
    @ObservedObject var store: BrowserWorkSpaceStore

    var body: some View {
        Button(action: store.toggleSidebar) {
            Image(systemName: "sidebar.leading")
                .frame(width: BrowserOmniboxMetrics.collapsedHeight, height: BrowserOmniboxMetrics.collapsedHeight)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(store.focusMode ? "展開並固定側欄" : "收合側欄")
        .accessibilityIdentifier("browser.sidebarToggle")
        .accessibilityValue(store.focusMode ? "已收合" : "已展開")
        .help(store.focusMode ? "展開並固定側欄" : "收合側欄")
        .font(.system(size: BrowserOmniboxMetrics.iconSize))
        .buttonStyle(.plain)
    }
}
