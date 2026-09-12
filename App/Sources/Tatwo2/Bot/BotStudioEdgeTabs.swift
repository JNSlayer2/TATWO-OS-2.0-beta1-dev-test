import SwiftUI
import AppKit

// 工作室書籤（2026-09-09 使用者正名；原稱「外部書籤／書側標籤」）。
//
// **位置是硬規則**：它必須在 app 外筐——child window 掛在主窗右緣外側、
// ordered .below 塞進 app 底下，只露外緣。歷來多次被誤做進 app 內部，
// 每次都要重講一遍；改這個檔之前先看這一段，不要把它畫回視圖裡。
// 唯一例外是快照 export（抓不到子視窗），退回窗內貼緣版 InsetRail。
//
// 外觀不要改：梯形＋栗皮茶＋呼吸圓點是 2026-08-22 定案的樣子。

@MainActor
final class BotStudioEdgeTabsController {
    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var resizeObserver: NSObjectProtocol?

    func attach(to window: NSWindow, state: BotStudioState) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: BotStudioEdgeTabsPanelView(state: state))
        window.addChildWindow(panel, ordered: .below)
        self.panel = panel
        self.parentWindow = window
        reposition()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    private func reposition() {
        guard let panel, let parent = parentWindow else { return }
        let frame = parent.frame
        // 往內塞 10pt（被 app 蓋住），只露外緣標籤。
        panel.setFrame(
            NSRect(x: frame.maxX - 10, y: frame.minY, width: 46, height: frame.height),
            display: true)
    }

    func detach() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
    }
}

final class BotStudioEdgeTabsTrackerView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

struct BotStudioEdgeTabsMounter: NSViewRepresentable {
    let state: BotStudioState

    @MainActor
    final class Coordinator {
        let controller = BotStudioEdgeTabsController()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BotStudioEdgeTabsTrackerView {
        let view = BotStudioEdgeTabsTrackerView()
        let controller = context.coordinator.controller
        let state = state
        view.onWindowChange = { window in
            if let window { controller.attach(to: window, state: state) }
            else { controller.detach() }
        }
        return view
    }

    func updateNSView(_ nsView: BotStudioEdgeTabsTrackerView, context: Context) { }

    static func dismantleNSView(_ nsView: BotStudioEdgeTabsTrackerView, coordinator: Coordinator) {
        coordinator.controller.detach()
    }
}

/// 外掛面板內容：工作室標籤（右圓角朝外、貼左緣咬住窗框）。
/// 平常收小、hover 變大；所有標籤固定高度。
struct BotStudioEdgeTabsPanelView: View {
    @ObservedObject var state: BotStudioState
    @State private var hoveredID: String?

    private let tabHeight: CGFloat = 78
    private var tabShape: BotSideTabTrapezoid { BotSideTabTrapezoid(attachedLeft: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: -8) {
            Spacer().frame(height: 44)
            ForEach(Array(state.studios.enumerated()), id: \.element.id) { index, studio in
                tab(studio)
                    .zIndex(hoveredID == studio.id ? 200 : Double(100 - index))
            }
            addTab
                .zIndex(0)
            Spacer()
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.14), value: hoveredID)
    }

    private func tab(_ studio: BotStudio) -> some View {
        let isOpen = state.mode == .studio && state.selectedStudioID == studio.id
        let hovered = hoveredID == studio.id
        return VStack(spacing: 4) {
            Text(String(studio.name.prefix(4)))
                .font(.system(size: hovered ? 10.5 : 9, weight: .semibold))
                .foregroundStyle(BotSideTabTheme.text)
                .frame(width: 15)
                .frame(maxHeight: .infinity)
                .multilineTextAlignment(.center)
            BotStudioBreathingDot(health: studio.health)
        }
        .padding(.vertical, 8)
        .frame(width: hovered ? 32 : 24, height: tabHeight)
        .background(
            BotSideTabTheme.fill(tabShape)
                .shadow(color: .black.opacity(0.20), radius: 3, x: 1.5, y: 1.5))
        .overlay(
            tabShape.stroke(BotSideTabTheme.stroke(highlighted: isOpen), lineWidth: isOpen ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = studio.id }
            else if hoveredID == studio.id { hoveredID = nil }
        }
        .onTapGesture { state.openStudio(studio.id) }
        .help("\(studio.name)　\(studio.target)")
    }

    private var addTab: some View {
        let hovered = hoveredID == "studio-add-tab"
        return VStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: hovered ? 11 : 9.5, weight: .bold))
                .foregroundStyle(BotSideTabTheme.text.opacity(0.85))
        }
        .padding(.vertical, 8)
        .frame(width: hovered ? 32 : 24, height: 34)
        .background(
            BotSideTabTheme.fill(tabShape, dimmed: true)
                .shadow(color: .black.opacity(0.14), radius: 3, x: 1.5, y: 1.5))
        .overlay(tabShape.stroke(BotSideTabTheme.stroke(highlighted: false), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredID = "studio-add-tab" }
            else if hoveredID == "studio-add-tab" { hoveredID = nil }
        }
        .onTapGesture { state.startBind() }
        .help("接一個新東西進來")
    }
}

/// 快照 export 抓不到 child window，退回窗內貼緣版（金樣驗收用）。
struct BotStudioEdgeTabsInsetRail: View {
    @ObservedObject var state: BotStudioState

    private var tabShape: BotSideTabTrapezoid { BotSideTabTrapezoid(attachedLeft: false) }

    var body: some View {
        VStack(spacing: -8) {
            Spacer().frame(height: 44)
            ForEach(Array(state.studios.enumerated()), id: \.element.id) { index, studio in
                VStack(spacing: 4) {
                    Text(String(studio.name.prefix(4)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BotSideTabTheme.text)
                        .frame(width: 15)
                        .frame(maxHeight: .infinity)
                        .multilineTextAlignment(.center)
                    BotStudioBreathingDot(health: studio.health)
                }
                .padding(.vertical, 8)
                .frame(width: 24, height: 78)
                .background(
                    BotSideTabTheme.fill(tabShape)
                        .shadow(color: .black.opacity(0.20), radius: 3, x: -1.5, y: 1.5))
                .overlay(tabShape.stroke(
                    BotSideTabTheme.stroke(highlighted: state.selectedStudioID == studio.id),
                    lineWidth: state.selectedStudioID == studio.id ? 1.5 : 1))
                .zIndex(Double(100 - index))
            }
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(BotSideTabTheme.text.opacity(0.85))
            }
            .padding(.vertical, 8)
            .frame(width: 24, height: 34)
            .background(
                BotSideTabTheme.fill(tabShape, dimmed: true)
                    .shadow(color: .black.opacity(0.14), radius: 3, x: -1.5, y: 1.5))
            .overlay(tabShape.stroke(BotSideTabTheme.stroke(highlighted: false), lineWidth: 1))
            .zIndex(0)
            Spacer()
        }
        .frame(width: 30)
    }
}

/// 呼吸圓點：跟 Gen-4 那顆同款（那顆是 fileprivate，這裡自帶一份，語義一致）。
/// 純繪製 pulse，不建立 SwiftUI 動畫交易，佈局動畫帶不動它。
struct BotStudioBreathingDot: View {
    let health: BotHealth

    private var coreColor: Color {
        switch health {
        case .run: Color.green.opacity(0.9)
        case .warn: Color.yellow.opacity(0.95)
        case .off: Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        ZStack {
            if health == .run {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = 0.5 + 0.5 * sin(t * (2 * .pi / 1.8))
                    Circle()
                        .fill(Color.green)
                        .frame(width: 9, height: 9)
                        .blur(radius: 2.5)
                        .opacity(0.15 + 0.7 * pulse)
                }
                .frame(width: 12, height: 12)
            } else if health == .warn {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 9, height: 9)
                    .blur(radius: 2.5)
                    .opacity(0.55)
            }
            Circle().fill(coreColor).frame(width: 5, height: 5)
        }
        .frame(width: 12, height: 12)
    }
}
