import SwiftUI

/// Sidebar controls stay reachable when collapsed; they never close or pin tabs.
struct BrowserSidebarControls: View {
    @ObservedObject var store: BrowserWorkSpaceStore

    var body: some View {
        HStack(spacing: WorkspaceSidebarMetrics.sidebarControlGap) {
            Button { store.focusMode.toggle() } label: {
                Image(systemName: "sidebar.leading")
                    .frame(width: WorkspaceSidebarMetrics.sidebarControlSize, height: WorkspaceSidebarMetrics.sidebarControlSize)
                    .contentShape(Rectangle())
            }
            .disabled(store.sidebarPinned)
            .accessibilityLabel(store.focusMode ? "展開側欄" : "收合側欄")
            .accessibilityIdentifier("browser.sidebarToggle")
            .help(store.sidebarPinned ? "側欄已固定，先取消固定才能收合" : "收合或展開側欄")
            if !store.focusMode {
                Button { store.sidebarPinned.toggle() } label: {
                    Image(systemName: store.sidebarPinned ? "pin.fill" : "pin")
                        .frame(width: WorkspaceSidebarMetrics.sidebarControlSize, height: WorkspaceSidebarMetrics.sidebarControlSize)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(store.sidebarPinned ? "取消固定側欄" : "固定側欄")
                .accessibilityIdentifier("browser.sidebarPin")
                .accessibilityValue(store.sidebarPinned ? "已固定" : "未固定")
                .help(store.sidebarPinned ? "取消固定側欄" : "固定側欄，不再自動收合")
            }
        }
        .font(.system(size: WorkspaceSidebarMetrics.sidebarControlIconSize))
        .buttonStyle(.plain)
    }
}
