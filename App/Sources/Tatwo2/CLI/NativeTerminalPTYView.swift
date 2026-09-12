import AppKit
import SwiftUI
import SwiftTerm

/// SwiftTerm stays behind this AppKit wrapper; neither Chat/Bot nor SwiftUI imports it.
struct NativeTerminalPTYPalette {
    var background: NSColor?
    var defaultInk: NSColor
    static let terminalBlack = Self(background: .black, defaultInk: .white)
    static let lightGlass = Self(background: nil, defaultInk: .labelColor)
}

@MainActor
struct NativeTerminalPTYView: NSViewRepresentable {
    static let defaultFontSize: CGFloat = CLIWorkbenchMetrics.terminalFont
    static let defaultContentInset: CGFloat = CLIWorkbenchMetrics.inset
    let session: CLIWorkbenchTerminalSession
    var lines: [TatwoTerminalLine] = [] // Legacy call compatibility; never parsed/rendered here.
    var fontSize: CGFloat = Self.defaultFontSize
    var contentInset: CGFloat = Self.defaultContentInset
    var palette: NativeTerminalPTYPalette = .lightGlass
    var focused = false

    func makeNSView(context: Context) -> NativeTerminalPTYNSView {
        if let display = session.display { return display }
        let display = NativeTerminalPTYNSView(session: session)
        session.display = display
        if !session.isRunning && !session.isStarting {
            Task { @MainActor [weak display] in
                let text = await session.store.loadScrollback(session.id)
                guard !session.isRunning else { return }
                display?.feed(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            }
        }
        return display
    }
    func updateNSView(_ view: NativeTerminalPTYNSView, context: Context) {
        view.update(fontSize: fontSize, inset: contentInset, palette: palette, focused: focused)
        view.editingOptions = session.editingOptions
    }
}

/// A single retained display per session. View/window removal detaches only the tmux client.
@MainActor
final class NativeTerminalPTYNSView: NSView, @preconcurrency TerminalViewDelegate {
    let terminal: TerminalView
    private weak var session: CLIWorkbenchTerminalSession?
    private var eventMonitor: Any?
    private var inset: CGFloat = CLIWorkbenchMetrics.inset
    private var focused = false
    private var historyScroll = CLIWorkbenchScrollAccumulator()
    var editingOptions = CLIWorkbenchEditingOptions()

    init(session: CLIWorkbenchTerminalSession) {
        self.session = session
        let display = CLIWorkbenchTerminalView(frame: .zero,
            font: .monospacedSystemFont(ofSize: CLIWorkbenchMetrics.terminalFont, weight: .regular),
            options: TerminalOptions(scrollback: 5000))
        display.onMouseFocus = { [weak session] in session?.onFocus?() }
        terminal = display
        super.init(frame: .zero)
        terminal.terminalDelegate = self
        terminal.optionAsMetaKey = false // Native Option characters and CJK input method, not forced Meta.
        addSubview(terminal)
        wantsLayer = true
        setAccessibilityIdentifier("cli-native-terminal-\(session.id)")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window, self.window != nil else { return event }
            if event.type == .scrollWheel {
                // Ask the actual window hit test, not retained/overlapping hidden
                // pane bounds. Scrolling does not require or steal keyboard focus.
                guard let content = self.window?.contentView,
                      let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                      hit === self.terminal || hit.isDescendant(of: self.terminal) else { return event }
                return self.scrollHistory(with: event) ? nil : event
            }
            guard self.window?.firstResponder === self.terminal else { return event }
            if let byte = Self.inputSourceInterruptByte(keyCode: event.keyCode,
                flags: event.modifierFlags, characters: event.charactersIgnoringModifiers,
                marked: self.terminal.hasMarkedText()) {
                self.session?.send(bytes: [byte])
                return nil
            }
            if let byte = Self.editingByte(keyCode: event.keyCode, flags: event.modifierFlags,
                marked: self.terminal.hasMarkedText(), options: self.editingOptions) {
                self.session?.send(bytes: [byte])
                return nil
            }
            return event
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }

    private func scrollHistory(with event: NSEvent) -> Bool {
        // tmux's outer alternate screen is not the shell's history. SwiftTerm's
        // fallback sends arrow keys there, which recalls shell commands instead.
        // Keep real application mouse reporting and exited/local history native.
        let state = terminal.getTerminal()
        let shiftBypasses = event.modifierFlags.contains(.shift) && !state.mouseShiftCapture
        let reportsMouse = terminal.allowMouseReporting && !shiftBypasses && state.mouseMode != .off
        guard session?.isRunning == true, !reportsMouse else {
            historyScroll = CLIWorkbenchScrollAccumulator()
            return false
        }
        let font = terminal.font
        let lineHeight = max(1, font.ascender - font.descender + font.leading)
        let lines = historyScroll.consume(delta: event.scrollingDeltaY * terminal.scrollSensitivity,
            precise: event.hasPreciseScrollingDeltas, lineHeight: lineHeight)
        if lines != 0 { session?.scrollHistory(lines: lines) }
        return true
    }

    /// SwiftTerm's legacy control mapping accepts ASCII only. With Zhuyin selected,
    /// the physical C key can report ㄏ instead. Repair only that unrepresentable
    /// Ctrl-C case; leave Latin layouts, other shortcuts and marked text to AppKit.
    static func inputSourceInterruptByte(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                                         characters: String?, marked: Bool) -> UInt8? {
        guard !marked, keyCode == 8,
              flags.intersection([.command, .option, .control, .shift]) == .control,
              characters?.unicodeScalars.contains(where: { $0.value > 0x7f }) == true else { return nil }
        return 0x03
    }

    /// Pure decision seam: independent toggles, exact modifier match, marked text always bypasses.
    static func editingByte(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                            marked: Bool, options: CLIWorkbenchEditingOptions) -> UInt8? {
        guard !marked, keyCode == 51 else { return nil }
        let modifiers = flags.intersection([.command, .option, .control, .shift])
        if modifiers == .command && options.deleteToLineStart { return 0x15 }
        if modifiers == .option && options.deletePreviousWord { return 0x17 }
        return nil
    }
    func update(fontSize: CGFloat, inset: CGFloat, palette: NativeTerminalPTYPalette, focused: Bool) {
        if terminal.font.pointSize != fontSize { terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        self.inset = inset
        let background = palette.background ?? NSColor(TatwoActivePalette.current.surfaceFill)
        if terminal.nativeBackgroundColor != background { terminal.nativeBackgroundColor = background }
        if terminal.nativeForegroundColor != palette.defaultInk { terminal.nativeForegroundColor = palette.defaultInk }
        layer?.backgroundColor = background.cgColor
        let focusChanged = self.focused != focused
        self.focused = focused
        if focusChanged && focused { window?.makeFirstResponder(terminal) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        terminal.frame = bounds.insetBy(dx: inset, dy: inset)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { session?.detach() }
        else {
            session?.attach()
            if focused { window?.makeFirstResponder(terminal) }
        }
    }
    func feed(_ data: Data) { terminal.feed(byteArray: Array(data)[...]) }
    var selectedText: String? { terminal.getSelection() }
    @discardableResult func find(_ text: String, backwards: Bool) -> Bool {
        backwards ? terminal.findPrevious(text) : terminal.findNext(text)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session?.resize(columns: newCols, rows: newRows)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { session?.send(Data(data)) }
    func setTerminalTitle(source: TerminalView, title: String) {} // OS title/ownership are authoritative.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: TerminalView, content: Data) {} // OSC52 cannot write without user copy.
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func bell(source: TerminalView) { NSSound.beep() }
}

/// Only the hit-tested terminal may claim focus. Hidden retained panes must not
/// listen to window-wide mouse events while compact/maximized bounds overlap.
@MainActor
private final class CLIWorkbenchTerminalView: TerminalView {
    var onMouseFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onMouseFocus?()
        super.mouseDown(with: event)
    }
}

/// Fractional trackpad movement survives between events; no process per event.
struct CLIWorkbenchScrollAccumulator {
    private var remainder: CGFloat = 0
    mutating func consume(delta: CGFloat, precise: Bool, lineHeight: CGFloat) -> Int {
        guard delta.isFinite, delta != 0, lineHeight.isFinite, lineHeight > 0 else { return 0 }
        if !precise {
            remainder = 0
            let bounded = max(-256, min(256, delta.rounded()))
            return bounded == 0 ? (delta > 0 ? 1 : -1) : Int(bounded)
        }
        remainder = max(-256 * lineHeight, min(256 * lineHeight, remainder + delta))
        let lines = Int(remainder / lineHeight)
        remainder -= CGFloat(lines) * lineHeight
        return lines
    }
}
