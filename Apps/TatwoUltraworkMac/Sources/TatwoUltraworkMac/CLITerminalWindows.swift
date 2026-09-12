import AppKit
import SwiftUI

// 2026-08-23 使用者：CLI 終端機右上功能群——
// ①「分離小視窗」：把分頁終端拆成獨立可調尺寸小視窗（可同時多個）；
// ②「專注」：整個 TATWO OS 縮到只剩該終端視窗（主視窗暫藏，關閉/離開專注即還原）。
// 分離窗與主窗吃同一個 PTY session／buffer（ChatPageModel 單一真相源）。

@MainActor
final class CLITerminalWindowManager: NSObject, NSWindowDelegate {
    static let shared = CLITerminalWindowManager()

    private var windows: [UUID: NSWindow] = [:]
    private weak var hiddenMainWindow: NSWindow?
    private var focusTabID: UUID?

    /// 分離小視窗（可多個並存；同分頁重複點＝把既有窗帶到前面）。
    func detach(tabID: UUID, title: String, model: ChatPageModel) {
        if let existing = windows[tabID] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 340),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 200)
        window.contentView = NSHostingView(
            rootView: DetachedCLITerminalRoot(model: model, tabID: tabID))
        window.delegate = self
        window.center()
        windows[tabID] = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 專注模式：分離該終端＋暫藏主視窗；小視窗可自由拖拽調尺寸。
    func focus(tabID: UUID, title: String, model: ChatPageModel) {
        let main = NSApp.mainWindow ?? NSApp.keyWindow
        detach(tabID: tabID, title: "\(title)（專注）", model: model)
        guard let terminalWindow = windows[tabID] else { return }
        if let main, main !== terminalWindow {
            hiddenMainWindow = main
            focusTabID = tabID
            main.orderOut(nil)
        }
        terminalWindow.makeKeyAndOrderFront(nil)
    }

    /// 離開專注：還原主視窗並關閉專注窗；純分離窗不受影響。
    func exitFocus() {
        let focusedWindow = focusTabID.flatMap { windows[$0] }
        focusTabID = nil
        hiddenMainWindow?.makeKeyAndOrderFront(nil)
        hiddenMainWindow = nil
        focusedWindow?.close()
    }

    var isInFocusMode: Bool { focusTabID != nil }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let entry = windows.first(where: { $0.value === window }) {
            windows[entry.key] = nil
            if focusTabID == entry.key {
                exitFocus()
            }
        }
    }
}

/// 分離窗內容：吃同一個 model 的 PTY／buffer；含小標頭（專注時可一鍵回主視窗）。
struct DetachedCLITerminalRoot: View {
    @ObservedObject var model: ChatPageModel
    let tabID: UUID

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(model.cliTabs.first(where: { $0.id == tabID })?.title ?? "CLI")
                    .font(.caption.weight(.black))
                Spacer(minLength: 0)
                if CLITerminalWindowManager.shared.isInFocusMode {
                    Button {
                        CLITerminalWindowManager.shared.exitFocus()
                    } label: {
                        Label("回主視窗", systemImage: "macwindow")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("離開專注模式，還原 TATWO OS 主視窗")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().opacity(0.35)
            if let ptySession = model.cliTabPTYSession(for: tabID) {
                NativeTerminalPTYView(
                    session: ptySession,
                    lines: model.cliTabLines(for: tabID),
                    fontSize: ChatTypography.terminalPointSize,
                    contentInset: ChatTypography.terminalContentInset,
                    palette: .lightGlass)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("此分頁已關閉或無 PTY")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 終端實底卡（2026-08-23 灰霧根治）：GlassCard 材質取樣＝8/14 三輪暗沉同源
/// 真兇；改實底＋淡染＋描邊，任何主題/桌布下不再起霧。
struct CLISolidCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor)))
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.02)))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        highlighted ? LiquidGlassTokens.brandAccent : Color.primary.opacity(0.14),
                        lineWidth: highlighted ? 1.5 : 1))
    }
}

/// 將共用的「左列常駐」狀態同步到目前 SwiftUI 所屬 NSWindow 的紅綠燈。
/// view 移窗或離開階層時會還原，避免其他視窗殘留隱藏狀態。
struct WindowTrafficLightVisibilitySync: NSViewRepresentable {
    let sidebarPinned: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(to: view, sidebarPinned: sidebarPinned)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, sidebarPinned: sidebarPinned)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?

        func attach(to view: NSView, sidebarPinned: Bool) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let nextWindow = view?.window else { return }
                if window !== nextWindow {
                    restore()
                    window = nextWindow
                }
                setTrafficLights(hidden: !sidebarPinned, in: nextWindow)
            }
        }

        func restore() {
            if let window { setTrafficLights(hidden: false, in: window) }
            window = nil
        }

        private func setTrafficLights(hidden: Bool, in window: NSWindow) {
            [.closeButton, .miniaturizeButton, .zoomButton].forEach {
                window.standardWindowButton($0)?.isHidden = hidden
            }
        }
    }
}
