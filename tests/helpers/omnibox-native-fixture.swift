import AppKit
import SwiftUI

// Synthetic inputs only; the toolbar, interaction policy, glass and metrics are
// production source. No actual browser, history, profile or settings are opened.
struct BrowserAddressSuggestion: Identifiable { let id: String; let title: String; let url: String }
struct BrowserHistoryEntry { let url: URL; let title: String }
actor BrowserHistoryStore {
    static let shared = BrowserHistoryStore()
    static func suggestions(_ entries: [BrowserHistoryEntry], matching: String) -> [BrowserHistoryEntry] { [] }
    func entries() -> [BrowserHistoryEntry] { [] }
}
struct BrowserShortcutMap {
    enum Action { case focusAddressBar }
    struct Combo { let display: String }
    static let changed = Notification.Name("w67.fixture.shortcutChanged")
    let hint: String?
    func combos(for action: Action) -> [Combo] { hint.map { [Combo(display: $0)] } ?? [] }
}
struct BrowserGeneralSettings {
    struct Engine {
        let title = "Search"
        func queryURL(_ text: String) -> URL { URL(string: "https://example.com/search")! }
    }
    let searchEngine = Engine()
    let shortcuts = BrowserShortcutMap(hint: nil)
    static func load() -> Self { .init() }
}
struct EmbeddedBrowserNavigationState {
    var urlString: String? = "https://example.com/a/long/path?fixture=1"
    let canGoBack = true, canGoForward = false, isLoading = false
}
enum EmbeddedBrowserCommand {
    enum Action { case goBack, goForward, stopLoading, reload }
}
struct NonWindowDraggingView: View { var body: some View { Color.clear } }
enum LiquidGlassTokens { static let shapeStyle = RoundedCornerStyle.continuous }

@MainActor final class W67Probe: ObservableObject {
    @Published var address = "https://example.com/a/long/path?fixture=1"
    @Published var focusSerial = 0
    var pageClicks = 0, annotationClicks = 0, submissions = 0
    var submitted = "", selectedTab = ""
}
struct W67Page: NSViewRepresentable {
    let probe: W67Probe
    func makeNSView(context: Context) -> Page { Page(probe: probe) }
    func updateNSView(_ view: Page, context: Context) {}
    final class Page: NSView {
        let probe: W67Probe
        init(probe: W67Probe) { self.probe = probe; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        // The isolated accessory fixture is not the user's active app. Accept
        // its first mouse just like a browser canvas, so delivery is measurable.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self); probe.pageClicks += 1
        }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemTeal.setFill(); bounds.fill()
            for x in stride(from: CGFloat.zero, to: bounds.width, by: 80) {
                NSColor.systemOrange.setFill()
                NSRect(x: x, y: 0, width: 24, height: bounds.height).fill()
            }
        }
    }
}
struct W67Fixture: View {
    @ObservedObject var probe: W67Probe
    @FocusState private var focused: Bool
    @State private var addressExpansionRequested = false
    let chatContext: Bool
    var header: some View {
        HStack(alignment: .top, spacing: BrowserOmniboxMetrics.controlGap) {
            EmbeddedBrowserToolbar(addressText: $probe.address, addressFieldFocused: $focused,
                state: .init(), enabled: true,
                onSubmit: { probe.submitted = probe.address; probe.submissions += 1; focused = false },
                onCommand: { _ in },
                openTabs: [.init(id: "fixture-tab", title: "Example tab", url: "https://example.com")],
                onSelectTab: { probe.selectedTab = $0 }, expansionRequest: $addressExpansionRequested)
            Menu { Button("Fixture action") {} } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: BrowserOmniboxMetrics.collapsedHeight, minHeight: BrowserOmniboxMetrics.collapsedHeight)
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("瀏覽器功能")
                .modifier(BrowserOmniboxGlass(cornerRadius: BrowserOmniboxMetrics.collapsedRadius))
            Button("註解") { probe.annotationClicks += 1 }
                .buttonStyle(.plain)
                .frame(minWidth: BrowserOmniboxMetrics.collapsedHeight, minHeight: BrowserOmniboxMetrics.collapsedHeight)
                .padding(.horizontal, BrowserOmniboxMetrics.horizontalInset).fixedSize()
                .modifier(BrowserOmniboxGlass(cornerRadius: BrowserOmniboxMetrics.collapsedRadius))
        }.foregroundStyle(LiquidGlassTokens.browserOmniboxInk)
         .zIndex(BrowserOmniboxMetrics.chromeZIndex)
    }
    var body: some View {
        Group {
            if chatContext {
                VStack(spacing: 0) { header; W67Page(probe: probe) }
            } else {
                W67Page(probe: probe).overlay(alignment: .top) { header }
            }
        }.onChange(of: probe.focusSerial) { _, _ in addressExpansionRequested = true }
    }
}
final class W67Window: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@main struct W67NativeChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0, geometry: [[String: Any]] = []
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("FAIL: " + message) }
            checks += 1; print("PASS: " + message); fflush(stdout)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
        func editable(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { editable($0) }.first
        }
        check(BrowserOmniboxMetrics.collapsedHeight < BrowserOmniboxMetrics.expandedFieldHeight, "collapsed < expanded token height")
        check(BrowserOmniboxPresentation.domain(for: "https://example.com/secret?q=private") == "example.com", "collapsed domain excludes path and query")
        check(BrowserOmniboxPresentation.symbol(for: "http://example.com") != "lock.fill", "HTTP not presented as locked")
        check(EmbeddedBrowserToolbar.focusAddressHint(map: .init(hint: nil)) == nil, "unbound shortcut has no key")
        check(EmbeddedBrowserToolbar.focusAddressHint(map: .init(hint: "⌥U")) == "⌥U", "custom shortcut comes from binding")
        for dark in [false, true] {
            for width: CGFloat in [260, 380, 700] {
                for chatContext in [false, true] {
                    let probe = W67Probe()
                    let host = NSHostingView(rootView: W67Fixture(probe: probe, chatContext: chatContext)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    let window = W67Window(contentRect: NSRect(x: 80, y: 80, width: width, height: 400),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    settle(); host.layoutSubtreeIfNeeded()
                    let tag = "\(dark ? "dark" : "light")-\(Int(width))-\(chatContext ? "chat" : "workspace")"
                    func click(_ x: CGFloat, _ top: CGFloat) {
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            let event = NSEvent.mouseEvent(with: type,
                                location: NSPoint(x: x, y: 400 - top), modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                            app.sendEvent(event)
                        }
                        settle(); host.layoutSubtreeIfNeeded()
                    }
                    func snapshot(_ state: String) throws {
                        guard width == 700, !chatContext else { return }
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap unavailable") }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("\(tag)-\(state).png"))
                    }
                    check(editable(host) == nil, "\(tag) initially collapsed")
                    try snapshot("collapsed")
                    click(width / 2, 12)
                    guard let field = editable(host) else { fatalError("\(tag) click did not expand") }
                    check(field.stringValue == probe.address, "\(tag) click shows full committed URL")
                    let frame = host.convert(field.bounds, from: field)
                    check(frame.minX >= 0 && frame.maxX <= width + 1, "\(tag) editor stays inside viewport")
                    check(frame.width >= 100, "\(tag) editor retains usable width")
                    geometry.append(["surface": tag, "editorWidth": frame.width, "editorHeight": frame.height,
                        "collapsedHeight": BrowserOmniboxMetrics.collapsedHeight, "viewport": [width, 400]])
                    try snapshot("expanded")
                    // Drive the real NSTextView field editor, then the real Esc handler.
                    guard let editor = window.firstResponder as? NSTextView else { fatalError("\(tag) input not focused") }
                    check(editor.selectedRange() == NSRange(location: 0, length: (probe.address as NSString).length), "\(tag) opening selects entire URL")
                    editor.insertText("discard draft", replacementRange: editor.selectedRange())
                    settle()
                    check(probe.address == "discard draft", "\(tag) native typing updates draft")
                    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                    settle()
                    check(editable(host) == nil && probe.address == EmbeddedBrowserNavigationState().urlString,
                        "\(tag) Esc restores original URL and collapses")
                    probe.focusSerial += 1; settle()
                    check(editable(host) != nil, "\(tag) existing focus command opens editor")
                    func traceNativeClick(_ stage: String) {
                        func surfaces(_ view: NSView) {
                            if view is W67Page.Page || view is BrowserOmniboxDismissMonitor.MonitorView {
                                print("TRACE \(stage) \(type(of: view)) frame=\(view.frame) bounds=\(view.bounds) window=\(view.window?.windowNumber ?? -1)")
                            }
                            view.subviews.forEach(surfaces)
                        }
                        let point = host.convert(NSPoint(x: width / 2, y: 50), from: nil)
                        print("TRACE \(stage) active=\(app.isActive) key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder)) hit=\(String(describing: host.hitTest(point)))")
                        surfaces(host); fflush(stdout)
                    }
                    traceNativeClick("before-page-click")
                    click(width / 2, 350)
                    traceNativeClick("after-page-click")
                    let collapsedAfterDirectClick = editable(host) == nil
                    let deliveredAfterDirectClick = probe.pageClicks
                    if !collapsedAfterDirectClick || deliveredAfterDirectClick != 1 {
                        // Diagnostic only: preserve the original failure below.
                        // Compare direct injection with AppKit's actual event queue.
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            app.postEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: width / 2, y: 50),
                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                                clickCount: 1, pressure: 1)!, atStart: false)
                        }
                        while let event = app.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                            until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                            app.sendEvent(event)
                        }
                        settle(); traceNativeClick("after-queued-diagnostic")
                        print("TRACE queued collapsed=\(editable(host) == nil) pageClicks=\(probe.pageClicks)"); fflush(stdout)
                    }
                    check(collapsedAfterDirectClick, "\(tag) native page click collapses (pageClicks=\(deliveredAfterDirectClick))")
                    check(deliveredAfterDirectClick == 1, "\(tag) native page click is delivered (actual=\(deliveredAfterDirectClick))")
                    click(width / 2, 12)
                    guard let editor = window.firstResponder as? NSTextView else { fatalError("input not focused after reopen") }
                    editor.selectAll(nil); editor.insertText("example", replacementRange: editor.selectedRange())
                    settle()
                    // first suggestion follows field (32), hint, panel padding and gaps.
                    click(110, 112 + BrowserOmniboxMetrics.suggestionRowHeight)
                    check(probe.selectedTab == "fixture-tab" && editable(host) == nil, "\(tag) mouse suggestion selects existing tab")
                    click(width / 2, 12)
                    guard let searchEditor = window.firstResponder as? NSTextView else { fatalError("search not focused") }
                    searchEditor.insertText("繁體中文 C++", replacementRange: searchEditor.selectedRange())
                    settle()
                    searchEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    settle()
                    check(probe.submissions == 1 && probe.submitted == "繁體中文 C++", "\(tag) Enter sends new query once, not old URL")
                    click(width / 2, 12)
                    guard let clickEditor = window.firstResponder as? NSTextView else { fatalError("suggestion not focused") }
                    clickEditor.insertText("搜尋測試", replacementRange: clickEditor.selectedRange())
                    settle(); click(110, 112)
                    check(probe.submissions == 2 && probe.submitted == "https://example.com/search" && editable(host) == nil,
                        "\(tag) primary search click submits before focus dismissal")
                    click(width - 20, 12)
                    check(probe.annotationClicks == 1, "\(tag) annotation remains clickable")
                    window.close(); settle()
                }
            }
        }
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("geometry.json"))
        print("W67 NATIVE RESULT checks=\(checks) failures=0")
    }
}
