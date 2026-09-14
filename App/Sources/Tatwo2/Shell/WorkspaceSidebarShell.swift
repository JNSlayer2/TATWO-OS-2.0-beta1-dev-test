import SwiftUI

/// Workspace pages supply content, never their own sidebar width or outer padding.
struct WorkspaceSidebarShell<Content: View>: View {
    private let width: CGFloat
    private let content: Content

    init(width: CGFloat = WorkspaceSidebarMetrics.width, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        LiquidGlassPanelCard(cornerRadius: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
    }
}
