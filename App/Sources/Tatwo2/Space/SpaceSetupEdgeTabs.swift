import AppKit
import SwiftUI

/// An actual child-window rail, using the existing Bot rail's geometry and theme.
/// Its content observes only preview state, never the live Bot page state.
struct SpaceSetupEdgeTabsMounter: NSViewRepresentable {
    var preview = SpaceSetupPreviewState.shared
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?
    @MainActor
    final class Coordinator {
        let controller = BotEdgeTabsPanelController()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BotEdgeTabsTrackerView {
        let view = BotEdgeTabsTrackerView()
        let controller = context.coordinator.controller
        view.onWindowChange = { window in
            controller.detach()
            if let window {
                controller.attach(to: window, content: SpaceSetupEdgeRail(preview: preview, onSelect: onSelect, onAdd: onAdd))
            }
        }
        return view
    }

    func updateNSView(_ nsView: BotEdgeTabsTrackerView, context: Context) {}

    static func dismantleNSView(_ nsView: BotEdgeTabsTrackerView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.controller.detach()
    }
}

struct SpaceSetupEdgeRail: View {
    @ObservedObject var preview = SpaceSetupPreviewState.shared
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?

    var body: some View {
        SpaceSetupDomainEdgeRail(domain: preview.selectedDomain, onSelect: onSelect, onAdd: onAdd)
            .id(preview.selectedDomainID)
    }
}

private struct SpaceSetupDomainEdgeRail: View {
    @ObservedObject var domain: SpaceSetupPreviewState.Domain
    var onSelect: ((String) -> Void)?
    var onAdd: (() -> Void)?
    @State private var hoveredID: String?
    private let shape = BotSideTabTrapezoid(attachedLeft: true)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 44)
            ScrollView(.vertical) {
              VStack(alignment: .leading, spacing: -8) {
                ForEach(Array(domain.interfaces.enumerated()), id: \.element.id) { index, item in
                Button {
                    if let onSelect { onSelect(item.id) } else { domain.selectInterface(item.id) }
                } label: {
                    Text("介面\n\(index + 1)")
                        .font(.system(size: hoveredID == item.id ? 10.5 : 9, weight: .semibold))
                        .foregroundStyle(BotSideTabTheme.text)
                        .multilineTextAlignment(.center)
                        .frame(width: 15)
                        .frame(width: hoveredID == item.id ? 32 : 24, height: 78)
                        .background(BotSideTabTheme.fill(shape))
                        .overlay(shape.stroke(
                            BotSideTabTheme.stroke(highlighted: domain.selectedInterfaceID == item.id),
                            lineWidth: domain.selectedInterfaceID == item.id ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .help("\(item.name)・\(domain.name)")
                .accessibilityLabel("\(domain.name) 的工作介面：\(item.name)")
                .onHover { hoveredID = $0 ? item.id : nil }
                }
              }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: domain.interfaces.isEmpty ? 0 : CGFloat(domain.interfaces.count) * 70 + 8)
            Button {
                if let onAdd { onAdd() } else { domain.openBuilder() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: hoveredID == "add" ? 11 : 9.5, weight: .bold))
                    .foregroundStyle(BotSideTabTheme.text)
                    .frame(width: hoveredID == "add" ? 32 : 24, height: 34)
                    .background(BotSideTabTheme.fill(shape, dimmed: true))
                    .overlay(shape.stroke(BotSideTabTheme.stroke(highlighted: false), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("在「\(domain.name)」新增工作介面")
            .accessibilityLabel("外標籤＋：新增目前 Space 的工作介面")
            .accessibilityIdentifier("space-preview-edge-add")
            .onHover { hoveredID = $0 ? "add" : nil }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
