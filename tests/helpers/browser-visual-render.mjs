import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Optional native component evidence. Data is synthetic; no CEF, navigation,
// real profiles, credentials, downloads, or system settings are exercised.
export function writeBrowserVisualRenderer(directory) {
  const design = readFileSync(new URL('../../App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift', import.meta.url), 'utf8');
  const start = design.indexOf('    private var downloadsPopover:');
  const end = design.indexOf('    // MARK: - Sidebar sections:', start);
  if (start < 0 || end < 0) throw new Error('Production download view boundaries missing');
  const destination = join(directory, 'W54VisualRenderer.swift');
  writeFileSync(destination, String.raw`
import AppKit
import SwiftUI

@MainActor struct W54AddressFixture: View {
    @State private var address = "https://example.com/"
    @FocusState private var focused: Bool
    var body: some View {
        EmbeddedBrowserToolbar(addressText: $address, addressFieldFocused: $focused,
            state: .init(urlString: "https://example.com/"), enabled: true,
            onSubmit: {}, onCommand: { _ in })
    }
}
@MainActor struct W54DownloadsFixture: View {
    @State private var downloadQuery = ""
    @State private var downloadsContentHeight = BrowserSidebarMetrics.zero
    @State private var selectedDownloadID: String?
    @State private var hoveredDownloadID: String?
    @ObservedObject private var downloadStore = BrowserDownloadStore.shared
    private let store = BrowserWorkSpaceStore(registry: BrowserTabRegistry())
    private var palette: TatwoThemePalette { .init() }
    var body: some View { downloadsPopover }
` + design.slice(start, end) + String.raw`
}
@MainActor struct W54SettingsControlsFixture: View {
    @State private var choice = "Google"
    var body: some View {
        VStack(alignment: .leading, spacing: BrowserSidebarMetrics.settingsRowSpacing) {
            BrowserSettingsSectionHeading(title: "Browser work space", number: 1)
            BrowserSettingsKVRow(title: "預設搜尋引擎", value: choice) {
                Picker("預設搜尋引擎", selection: $choice) {
                    Text("Google").tag("Google")
                    Text("DuckDuckGo").tag("DuckDuckGo")
                }
            }
            BrowserSettingsKVRow(title: "下載位置", value: "~/Downloads") {
                Button("在 Finder 顯示") {}
            }
            BrowserSettingsKVRow(title: "從其他瀏覽器導入", value: "Chrome、Arc、Brave、Edge、Opera、Vivaldi；Safari 僅書籤") {
                Button("從其他瀏覽器導入…") {}
            }
            BrowserSettingsSectionHeading(title: "引擎與安全", number: 5)
            HStack {
                Text("人用分頁")
                Spacer()
                Text("AI 操作分頁")
                BrowserSettingsPolicyValue(value: "封鎖")
            }
        }
        .foregroundStyle(LiquidGlassTokens.browserInk)
        .padding(.vertical, BrowserSidebarMetrics.settingsCardVerticalPadding)
        .padding(.horizontal, BrowserSidebarMetrics.settingsCardHorizontalPadding)
        .background(LiquidGlassTokens.browserFieldFill, in: RoundedRectangle(cornerRadius: BrowserSidebarMetrics.settingsCardRadius))
    }
}
@main struct W54VisualRenderer {
    @MainActor static func checkSidebar(root: URL, dark: Bool) throws {
        let registry = BrowserTabRegistry()
        let store = BrowserWorkSpaceStore(registry: registry)
        let host = NSHostingView(rootView: ChatPage(store: store)
            .frame(width: 250, height: 520, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 250, height: 520),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
        }
        func click(_ x: CGFloat) {
            let top = WindowChromeMetrics.trafficLightTopInset + WindowChromeMetrics.nativeTrafficLightDiameter / 2
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 520 - top),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.sendEvent(event)
            }
            settle()
        }
        func snapshot(_ state: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No header bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: root.appendingPathComponent("sidebar-header-\(dark ? "dark" : "light")-\(state).png"))
        }
        settle()
        let origin = WindowChromeMetrics.appControlLeadingX
        let toggle = origin + WorkspaceSidebarMetrics.spaceSwitcherMenuWidth
            + WorkspaceSidebarMetrics.sidebarControlGap + WorkspaceSidebarMetrics.sidebarControlSize / 2
        let pin = toggle + WorkspaceSidebarMetrics.sidebarControlGap + WorkspaceSidebarMetrics.sidebarControlSize
        precondition(pin + WorkspaceSidebarMetrics.sidebarControlSize / 2 <= WorkspaceSidebarMetrics.width)
        try snapshot("expanded")
        click(toggle)
        precondition(store.focusMode, "real collapse button must receive the title-band click")
        try snapshot("collapsed")
        click(origin + WorkspaceSidebarMetrics.sidebarControlSize / 2)
        precondition(!store.focusMode, "collapsed sidebar must have a clickable expand button")
        click(pin)
        precondition(store.sidebarPinned && !store.focusMode, "pin click must pin the sidebar")
        click(toggle)
        precondition(!store.focusMode, "disabled collapse button must not collapse pinned sidebar")
        click(pin)
        precondition(!store.sidebarPinned, "unpin click must work")
        print("W66 NATIVE HEADER PASS \(dark ? "dark" : "light"): collapse, expand, pin, disabled collapse, unpin")
    }
    @MainActor static func render<V: View>(_ view: V, shot shotName: String, size: NSSize, dark: Bool = false, root: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top).background(LiquidGlassTokens.browserGroundFill))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(shotName + ".png"))
        window.close()
    }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registry = BrowserTabRegistry()
        let store = BrowserWorkSpaceStore(registry: registry)
        let owner = BrowserTabOwner.workSpace(spaceID: registry.spaces.first { !$0.isSessionSpace }!.id)
        let first = registry.openTab(owner: owner, url: URL(string: "https://example.com"), title: "Example Domain")
        let sleeping = registry.openTab(owner: owner, url: URL(string: "https://docs.example.com"), title: "參考文件")
        registry.markSleeping(sleeping.id, true)
        registry.select(first.id)
        registry.markSleeping(first.id, false)
        BrowserDownloadStore.shared.update(id: "w54-progress", filename: "fixture-download.zip", received: 62, total: 100, done: false)
        BrowserDownloadStore.shared.update(id: "w54-complete", filename: "fixture-report.pdf", received: 3000, total: 3000, done: true)
        try render(BrowserWorkSpaceSidebarList(store: store), shot: "sidebar",
                   size: NSSize(width: 226, height: 420), root: root)
        try render(W54AddressFixture(), shot: "omnibox", size: NSSize(width: 700, height: 62), root: root)
        try render(W54DownloadsFixture(), shot: "downloads", size: NSSize(width: 226, height: 520), root: root)
        for dark in [false, true] {
            try checkSidebar(root: root, dark: dark)
            try render(W54SettingsControlsFixture(), shot: dark ? "settings-controls-dark" : "settings-controls",
                       size: NSSize(width: 568, height: 280), dark: dark, root: root)
        }
        print("W54 native component snapshots: synthetic data, not full App/CEF or AX acceptance")
    }
}
`);
  return destination;
}
