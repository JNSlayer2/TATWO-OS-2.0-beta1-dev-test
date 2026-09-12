import AppKit
import SwiftUI
import TatwoUltraworkCore

/// 終端配色。
///
/// 預設 `.terminalBlack` 維持這個 view 原本的黑底白字（獨立使用時行為不變）。
/// CLI 分頁改用 `.lightGlass`：ChatPage 的終端窗格早先已依使用者回饋 #33
/// 「CLI 太黑→改與全 app 一致的淺色玻璃」改成淺底，接 PTY 時不能把它退回黑底。
struct NativeTerminalPTYPalette {
    /// nil＝不填背景，讓底下的玻璃透出來。
    var background: NSColor?
    /// ANSI `.default` 的字色（一般正文）。
    var defaultInk: NSColor
    /// `.black`（最暗的一階）。
    var deepDim: NSColor
    /// `.brightBlack`（註解、次要字）。
    var dim: NSColor
    /// `.white`（淺灰字）。
    var faint: NSColor
    /// `.brightWhite`（最強調字）。
    var strong: NSColor
    /// 六組彩色往黑色混入的比例，讓彩字在淺底上也有對比度。0＝用原色。
    var chromaticDarkening: CGFloat

    /// 這個 view 原本的黑底白字，數值與改造前逐項相同。
    static let terminalBlack = NativeTerminalPTYPalette(
        background: .black,
        defaultInk: .white,
        deepDim: NSColor(calibratedWhite: 0.20, alpha: 1),
        dim: NSColor(calibratedWhite: 0.42, alpha: 1),
        faint: NSColor(calibratedWhite: 0.82, alpha: 1),
        strong: .white,
        chromaticDarkening: 0)

    /// 淺色玻璃底：深墨字 + 加深彩字。明暗階序相對黑底整個翻轉。
    static let lightGlass = NativeTerminalPTYPalette(
        background: nil,
        defaultInk: NSColor(calibratedWhite: 0.16, alpha: 1),
        deepDim: NSColor(calibratedWhite: 0.58, alpha: 1),
        dim: NSColor(calibratedWhite: 0.48, alpha: 1),
        faint: NSColor(calibratedWhite: 0.34, alpha: 1),
        strong: NSColor(calibratedWhite: 0.06, alpha: 1),
        chromaticDarkening: 0.28)
}

@MainActor
struct NativeTerminalPTYView: NSViewRepresentable {
    /// Matches `ChatTypography.terminalPointSize` (transcript meta). SF Mono at 13
    /// reads larger than the rest of the Chat UI.
    static let defaultFontSize: CGFloat = 11.5
    static let defaultContentInset: CGFloat = 12

    let session: TatwoNativePTYTerminalSession
    var lines: [TatwoTerminalLine]
    var fontSize: CGFloat = NativeTerminalPTYView.defaultFontSize
    var contentInset: CGFloat = NativeTerminalPTYView.defaultContentInset
    var palette: NativeTerminalPTYPalette = .terminalBlack

    func makeNSView(context _: Context) -> NativeTerminalPTYNSView {
        NativeTerminalPTYNSView(
            session: session,
            lines: lines,
            fontSize: fontSize,
            contentInset: contentInset,
            palette: palette
        )
    }

    func updateNSView(_ view: NativeTerminalPTYNSView, context _: Context) {
        view.update(
            session: session,
            lines: lines,
            fontSize: fontSize,
            contentInset: contentInset,
            palette: palette
        )
    }
}

@MainActor
final class NativeTerminalPTYNSView: NSView {
    private var session: TatwoNativePTYTerminalSession
    private var terminalLines: [TatwoTerminalLine]
    private var terminalFont: NSFont
    private var boldTerminalFont: NSFont
    private var palette: NativeTerminalPTYPalette
    private var contentInset: CGFloat
    private var cellWidth: CGFloat = 8
    private var lineHeight: CGFloat = 16
    private var lastColumns = 0
    private var lastRows = 0

    init(
        session: TatwoNativePTYTerminalSession,
        lines: [TatwoTerminalLine],
        fontSize: CGFloat,
        contentInset: CGFloat = NativeTerminalPTYView.defaultContentInset,
        palette: NativeTerminalPTYPalette = .terminalBlack
    ) {
        self.session = session
        self.terminalLines = lines
        self.palette = palette
        self.contentInset = max(0, contentInset)
        let font = NSFont.monospacedSystemFont(ofSize: max(9, fontSize), weight: .regular)
        self.terminalFont = font
        self.boldTerminalFont = NSFont.monospacedSystemFont(ofSize: max(9, fontSize), weight: .bold)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = palette.background?.cgColor ?? NSColor.clear.cgColor
        refreshMetrics()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(
        session: TatwoNativePTYTerminalSession,
        lines: [TatwoTerminalLine],
        fontSize: CGFloat,
        contentInset: CGFloat = NativeTerminalPTYView.defaultContentInset,
        palette: NativeTerminalPTYPalette = .terminalBlack
    ) {
        self.session = session
        terminalLines = lines
        if self.palette.background != palette.background {
            layer?.backgroundColor = palette.background?.cgColor ?? NSColor.clear.cgColor
        }
        self.palette = palette
        let inset = max(0, contentInset)
        let insetChanged = abs(self.contentInset - inset) > 0.01
        self.contentInset = inset
        let size = max(9, fontSize)
        if abs(terminalFont.pointSize - size) > 0.01 {
            terminalFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            boldTerminalFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            refreshMetrics()
            resizePTY()
        } else if insetChanged {
            resizePTY()
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resizePTY()
        guard let window else { return }
        if window.firstResponder == nil || window.firstResponder === window.contentView {
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizePTY()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // MARK: - 複製／貼上（2026-08-23）

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return
        }
        session.send(bytes: Array(text.utf8))
    }

    private func copyVisibleBuffer() {
        let text = terminalLines
            .map { line in line.spans.map(\.text).joined() }
            .joined(separator: "\n")
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let paste = NSMenuItem(title: "貼上", action: #selector(contextPaste), keyEquivalent: "")
        paste.target = self
        menu.addItem(paste)
        let copyAll = NSMenuItem(title: "複製畫面內容", action: #selector(contextCopyAll), keyEquivalent: "")
        copyAll.target = self
        menu.addItem(copyAll)
        return menu
    }

    @objc private func contextPaste() { pasteFromClipboard() }
    @objc private func contextCopyAll() { copyVisibleBuffer() }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            // 2026-08-23 使用者：「cli 分頁終端機無法複製貼上」——
            // Cmd+V 直送 PTY；Cmd+C 複製畫面內容（無選取機制的最小可用版）。
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                pasteFromClipboard()
                return
            case "c":
                copyVisibleBuffer()
                return
            default:
                super.keyDown(with: event)
                return
            }
        }

        if let special = specialKey(for: event.keyCode) {
            session.send(
                bytes: TatwoTerminalInputEncoder.bytes(
                    for: .special(special),
                    optionAsMeta: flags.contains(.option)
                )
            )
            return
        }

        if flags.contains(.control),
           let character = event.charactersIgnoringModifiers?.first {
            session.send(bytes: TatwoTerminalInputEncoder.bytes(for: .control(character)))
            return
        }

        let text = flags.contains(.option)
            ? event.charactersIgnoringModifiers
            : event.characters
        guard let text, !text.isEmpty else {
            super.keyDown(with: event)
            return
        }
        session.send(
            bytes: TatwoTerminalInputEncoder.bytes(
                for: .text(text),
                optionAsMeta: flags.contains(.option)
            )
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        if let background = palette.background {
            background.setFill()
            dirtyRect.fill()
        }

        guard lineHeight > 0 else { return }
        let visibleCount = max(1, Int(ceil((bounds.height - contentInset * 2) / lineHeight)))
        let visibleLines = terminalLines.suffix(visibleCount)

        for (row, line) in visibleLines.enumerated() {
            var x: CGFloat = contentInset
            let y = contentInset + CGFloat(row) * lineHeight
            for span in line.spans {
                let font = span.isBold ? boldTerminalFont : terminalFont
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color(for: span.foreground),
                ]
                NSString(string: span.text).draw(
                    at: NSPoint(x: x, y: y),
                    withAttributes: attributes
                )
                x += CGFloat(span.text.unicodeScalars.count) * cellWidth
            }
        }
    }

    private func refreshMetrics() {
        cellWidth = max(
            1,
            NSString(string: "M").size(withAttributes: [.font: terminalFont]).width
        )
        lineHeight = ceil(
            terminalFont.ascender - terminalFont.descender + terminalFont.leading
        )
    }

    private func resizePTY() {
        guard cellWidth > 0, lineHeight > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let columns = max(1, Int(floor((bounds.width - contentInset * 2) / cellWidth)))
        let rows = max(1, Int(floor((bounds.height - contentInset * 2) / lineHeight)))
        guard columns != lastColumns || rows != lastRows else { return }
        lastColumns = columns
        lastRows = rows
        session.resize(columns: columns, rows: rows)
    }

    private func specialKey(for keyCode: UInt16) -> TatwoTerminalSpecialKey? {
        switch keyCode {
        case 36, 76: return .carriageReturn
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 115: return .home
        case 116: return .pageUp
        case 117: return .deleteForward
        case 119: return .end
        case 121: return .pageDown
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default: return nil
        }
    }

    /// 彩色字往黑色混，讓同一組色在淺底上也有對比度。
    /// `terminalBlack` 的 darkening=0 → 原色不動，獨立使用時外觀完全不變。
    private func chromatic(_ color: NSColor) -> NSColor {
        guard palette.chromaticDarkening > 0 else { return color }
        return color.blended(withFraction: palette.chromaticDarkening, of: .black) ?? color
    }

    private func color(for color: TatwoTerminalColor) -> NSColor {
        switch color {
        case .default: return palette.defaultInk
        case .black: return palette.deepDim
        case .red: return chromatic(NSColor(calibratedRed: 0.86, green: 0.28, blue: 0.26, alpha: 1))
        case .green: return chromatic(NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.38, alpha: 1))
        case .yellow: return chromatic(NSColor(calibratedRed: 0.90, green: 0.76, blue: 0.30, alpha: 1))
        case .blue: return chromatic(NSColor(calibratedRed: 0.35, green: 0.55, blue: 0.92, alpha: 1))
        case .magenta: return chromatic(NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.86, alpha: 1))
        case .cyan: return chromatic(NSColor(calibratedRed: 0.30, green: 0.76, blue: 0.82, alpha: 1))
        case .white: return palette.faint
        case .brightBlack: return palette.dim
        case .brightRed: return chromatic(NSColor(calibratedRed: 1.0, green: 0.40, blue: 0.38, alpha: 1))
        case .brightGreen: return chromatic(NSColor(calibratedRed: 0.48, green: 0.94, blue: 0.50, alpha: 1))
        case .brightYellow: return chromatic(NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.44, alpha: 1))
        case .brightBlue: return chromatic(NSColor(calibratedRed: 0.48, green: 0.68, blue: 1.0, alpha: 1))
        case .brightMagenta: return chromatic(NSColor(calibratedRed: 0.92, green: 0.56, blue: 1.0, alpha: 1))
        case .brightCyan: return chromatic(NSColor(calibratedRed: 0.48, green: 0.94, blue: 1.0, alpha: 1))
        case .brightWhite: return palette.strong
        }
    }
}
