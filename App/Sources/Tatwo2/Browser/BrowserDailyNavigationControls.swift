import AppKit
import SwiftUI

/// The probe occupies exactly the browser panel, not the surrounding chat/CLI hosting view.
/// No application-wide key monitor: SwiftUI owns shortcut registration and teardown.
struct BrowserDailyFocusScope: NSViewRepresentable {
    @Binding var focused: Bool
    final class Probe: NSView {
        var update: ((Bool) -> Void)?
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
            guard let window, window.isKeyWindow, var view = window.firstResponder as? NSView else {
                update?(false); return
            }
            if let editor = view as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView { view = control }
            view = BrowserWebFeatures.focusOwner(for: view)
            // An app-wide hosting/root responder is not evidence that this browser has focus.
            guard view !== self, !isDescendant(of: view) else { update?(false); return }
            let rect = convert(view.bounds, from: view)
            update?(!isHiddenOrHasHiddenAncestor && bounds.contains(NSPoint(x: rect.midX, y: rect.midY)))
        }
    }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.update = { value in if focused != value { focused = value } }
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) { view.update = { if focused != $0 { focused = $0 } } }
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
            guard focused else { return }
            switch shortcutKind {
            case "escape":
                // Find bar open → close it first; otherwise Esc stops loading.
                if findPresented { onCommand(.stopFinding); findPresented = false } else { onCommand(.stopLoading) }
            default:
                // The legacy bridge reports key kinds, NOT user-configured actions.
                // It currently consumes unbound keys too; returning them requires a bridge contract change.
                guard let combo = BrowserShortcutMap.legacyCombo(shortcutKind) else { return }
                for action in BrowserAction.allCases {
                    if let index = map.combos(for: action).firstIndex(where: { $0.matches(combo) }) {
                        perform(action, number: index + 1); return
                    }
                }
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
        case .findInPage: findPresented = true
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
        }.buttonStyle(.borderless).padding(8).onAppear { focused = true }
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
    init?(event: NSEvent) {
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
    var eventModifiers: EventModifiers {
        modifiers.reduce(into: EventModifiers()) { result, name in
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
