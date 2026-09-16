import SwiftUI

/// Center the whole dot-plus group, including when its scrollable content is short.
struct WorkspaceSpaceControls<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: WorkspaceSpaceControlMetrics.itemSpacing) {
                    content()
                }
                .frame(minWidth: geometry.size.width, alignment: .center)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: WorkspaceSpaceControlMetrics.cellHeight)
    }
}
