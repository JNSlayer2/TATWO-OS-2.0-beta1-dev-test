import AppKit
import Carbon
import SwiftUI

/// The probe occupies exactly the browser panel, not the surrounding chat/CLI hosting view.
/// No application-wide key monitor: SwiftUI owns shortcut registration and teardown.
struct BrowserDailyFocusScope: NSViewRepresentable {
    @Binding var focused: Bool
    var acceptsWindowResponder = false
    final class Probe: NSView {
        var update: ((Bool) -> Void)?
        var acceptsWindowResponder = false
        var windowUpdate: NSObjectProtocol?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowUpdate { NotificationCenter.default.removeObserver(windowUpdate) }
            windowUpdate = nil
            guard let window else { return }
            windowUpdate = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func check() {
            guard let window, window.isKeyWindow, window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor else {
                update?(false); return
            }
            // In the dedicated Browser workspace, dismissing native chrome
            // can leave NSWindow as first responder. Keep its shortcuts usable;
            // embedded chat browsers retain the stricter descendant-only rule.
            if acceptsWindowResponder, window.firstResponder === window {
                update?(true); return
            }
            guard var view = window.firstResponder as? NSView else { update?(false); return }
            if let editor = view as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView { view = control }
            view = BrowserWebFeatures.focusOwner(for: view)
            // An app-wide hosting/root responder is not evidence that this browser has focus.
            guard view !== self, !isDescendant(of: view) else {
                update?(acceptsWindowResponder); return
            }
            let rect = convert(view.bounds, from: view)
            update?(!isHiddenOrHasHiddenAncestor && bounds.contains(NSPoint(x: rect.midX, y: rect.midY)))
        }
    }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.acceptsWindowResponder = acceptsWindowResponder
        probe.update = { value in if focused != value { focused = value } }
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.acceptsWindowResponder = acceptsWindowResponder
        view.update = { if focused != $0 { focused = $0 } }
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        if let observer = view.windowUpdate { NotificationCenter.default.removeObserver(observer) }
        view.windowUpdate = nil; view.update = nil
    }
}

struct BrowserDailyNavigationControls: View {
    let focused: Bool
    let shortcutSerial: Int
    let shortcutKind: String
    let hasTab: Bool
    let editingAddress: Bool
    let url: String?
    @Binding var findPresented: Bool
    let onCommand: (EmbeddedBrowserCommand.Action) -> Void
    let onReopen: () -> Void
    let onTabNumber: (Int) -> Void
    var onAction: (BrowserAction) -> Void = { _ in }
    @State private var map = BrowserGeneralSettings.load().shortcuts
    var body: some View {
        Group {
            ForEach(BrowserAction.allCases, id: \.self) { action in
                ForEach(Array(map.combos(for: action).enumerated()), id: \.offset) { index, combo in
                    Button("") { perform(action, number: index + 1) }
                        .keyboardShortcut(combo.equivalent, modifiers: combo.eventModifiers)
                        .disabled(!hasTab && action.requiresTab)
                }
            }
            Button("") { onCommand(.stopLoading) }.keyboardShortcut(.escape, modifiers: [])
                .disabled(!hasTab || editingAddress || findPresented || NSApp.keyWindow?.firstResponder is NSTextInputClient)
        }
        .disabled(!focused).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: BrowserShortcutMap.changed)) { _ in
            map = BrowserGeneralSettings.load().shortcuts
        }
        .onChange(of: shortcutSerial) { _, _ in
            // The native host already requires the selected, visible human page.
            // SwiftUI's focus probe can lag that AppKit event by one update.
            switch shortcutKind {
            case "escape":
                // Find bar open → close it first; otherwise Esc stops loading.
                if findPresented { onCommand(.stopFinding); findPresented = false } else { onCommand(.stopLoading) }
            default:
                guard let invocation = BrowserShortcutInvocation(message: shortcutKind) else { return }
                perform(invocation.action, number: invocation.number)
            }
        }
    }
    private func perform(_ action: BrowserAction, number: Int) {
        if !hasTab && action.requiresTab { return }
        switch action {
        case .back: onCommand(.goBack)
        case .forward: onCommand(.goForward)
        case .reload: onCommand(.reload)
        case .stopLoading: onCommand(.stopLoading)
        case .reopenClosedTab: onReopen()
        case .findInPage: onAction(.findInPage); findPresented = true
        case .zoomIn: zoom(1)
        case .zoomOut: zoom(-1)
        case .zoomReset: onCommand(.zoom(0))
        case .tabNumber: onTabNumber(number)
        default: onAction(action)
        }
    }
    private func zoom(_ delta: Double) {
        let host = URL(string: url ?? "")?.host?.lowercased() ?? ""
        let current = BrowserGeneralSettings.load().zoomByHost[host] ?? 0
        onCommand(.zoom(BrowserDailyNavigation.zoom(current, delta: delta)))
    }
}

/// Only the annotation toggle is active inside its sheet; other browser actions stay disabled.
struct BrowserAnnotationShortcutDismiss: View {
    @Environment(\.dismiss) private var dismiss
    @State private var map = BrowserGeneralSettings.load().shortcuts
    var body: some View {
        Group {
            if let combo = map.bindings[.toggleAnnotations] {
                Button("") { dismiss() }.keyboardShortcut(combo.equivalent, modifiers: combo.eventModifiers)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: BrowserShortcutMap.changed)) { _ in
            map = BrowserGeneralSettings.load().shortcuts
        }
    }
}

struct BrowserFindBar: View {
    @Binding var presented: Bool
    let count: Int
    let activeIndex: Int
    let onCommand: (EmbeddedBrowserCommand.Action) -> Void
    var focusRequest = 0
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            TextField("在網頁中尋找", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                .onChange(of: text) { _, _ in find(true) }.onSubmit { find(true) }
                .onExitCommand(perform: close)
            Text("\(activeIndex)／\(count)").monospacedDigit().accessibilityLabel("第 \(activeIndex) 筆，共 \(count) 筆")
            Button { find(false) } label: { Image(systemName: "chevron.up") }.help("上一個")
            Button { find(true) } label: { Image(systemName: "chevron.down") }.help("下一個")
            Button(action: close) { Image(systemName: "xmark") }.help("關閉頁內搜尋")
        }.buttonStyle(.borderless).padding(8).task(id: focusRequest) {
            // Let the containing browser release address-bar focus and mount
            // this field before asking AppKit to change the first responder.
            await Task.yield()
            focused = true
        }
    }
    private func find(_ forward: Bool) { onCommand(.find(text, forward: forward, matchCase: false)) }
    private func close() { onCommand(.stopFinding); presented = false }
}

struct BrowserAddressSuggestion: Identifiable {
    let id: String
    let title: String
    let url: String
}

extension BrowserKeyCombo {
    /// Preserve custom bindings first. IMEs may report a non-Latin character for
    /// Command keys; translate using the user's ASCII layout, not US key positions.
    static func invocation(event: NSEvent, shortcuts: BrowserShortcutMap,
                           translate: (UInt16, NSEvent.ModifierFlags) -> String? = asciiKey) -> BrowserShortcutInvocation? {
        guard let combo = Self(event: event), !combo.modifiers.isEmpty else { return nil }
        if let direct = shortcuts.invocation(for: combo) { return direct }
        guard combo.modifiers.contains("command"), combo.key.unicodeScalars.contains(where: { $0.value > 127 }),
              let key = translate(event.keyCode, event.modifierFlags) else { return nil }
        return shortcuts.invocation(for: Self(key: key, modifiers: combo.modifiers))
    }

    private static func asciiKey(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var modifiers: UInt32 = 0
        // Like charactersIgnoringModifiers, do not turn Option-F into a symbol
        // or Control-F into a control character. Matching keeps all modifiers.
        for (flag, legacy): (NSEvent.ModifierFlags, Int) in [(.command, cmdKey), (.shift, shiftKey)] {
            if flags.contains(flag) { modifiers |= UInt32(legacy) }
        }
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        guard UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers >> 8,
                             UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                             &dead, characters.count, &length, &characters) == noErr, length == 1 else { return nil }
        return String(utf16CodeUnits: characters, count: length).lowercased()
    }

    init?(event: NSEvent) {
        // CEF may report modifier transitions as raw key input. AppKit raises
        // an Objective-C exception if characters are read from flagsChanged
        // or other non-key events; Swift cannot catch that exception.
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let key: String
        switch event.keyCode {
        case 53: key = "escape"
        case 48: key = "tab"
        case 49: key = "space"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            key = chars
        }
        var modifiers: [String] = []
        for (flag, name): (NSEvent.ModifierFlags, String) in [(.command, "command"), (.shift, "shift"), (.option, "option"), (.control, "control")] {
            if event.modifierFlags.contains(flag) { modifiers.append(name) }
        }
        self.init(key: key, modifiers: modifiers)
    }
    var equivalent: KeyEquivalent {
        switch key {
        case "escape": .escape
        case "tab": .tab
        case "space": .space
        default: KeyEquivalent(key.first ?? " ")
        }
    }
    var eventModifiers: SwiftUI.EventModifiers {
        modifiers.reduce(into: SwiftUI.EventModifiers()) { result, name in
            switch name {
            case "command": result.insert(.command)
            case "shift": result.insert(.shift)
            case "option": result.insert(.option)
            case "control": result.insert(.control)
            default: break
            }
        }
    }
}
