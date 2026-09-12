// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageAppKitBridges.swift；改動 2 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import AppKit

struct ChatProjectHoverTrackingView: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var passthrough = true

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.onHover = onHover
        view.passthrough = passthrough
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.onHover = onHover
        nsView.passthrough = passthrough
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        var passthrough = true
        private var trackingAreaRef: NSTrackingArea?
        private var localMonitor: Any?
        private var isHovering = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Hover tracking only. Do not eat clicks, text selection, or scrolls
            // from the chat canvas underneath the invisible reveal / exit zones.
            passthrough ? nil : self
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeLocalMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            installLocalMonitorIfNeeded()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                // The Chat project rail is intentionally revealed by hover, not
                // by a visible handle. Requiring the window to be key made the
                // rail feel broken in real app validation when the pointer moved
                // over LSUIElement / automation surfaces that can be visible but
                // not fully active; local monitors also miss those inactive-app
                // moves. Track while visible instead; `hitTest` still returns
                // nil so this view remains hover-only and does not steal
                // clicks/selection.
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil)
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func mouseEntered(with event: NSEvent) {
            setHovering(true)
        }

        override func mouseExited(with event: NSEvent) {
            setHovering(false)
        }

        private func installLocalMonitorIfNeeded() {
            guard localMonitor == nil else { return }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseMoved,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged
            ]) { [weak self] event in
                self?.handleLocalMouseEvent(event)
                return event
            }
        }

        private func removeLocalMonitor() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        private func handleLocalMouseEvent(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            setHovering(bounds.contains(point))
        }

        private func setHovering(_ hovering: Bool) {
            guard hovering != isHovering else { return }
            isHovering = hovering
            onHover?(hovering)
        }
    }
}

// #2 skill 建議鍵盤操作意圖：→/↓=下一個、←/↑=上一個/退選、Enter=插入選中。
enum ChatComposerSuggestionKey { case next, prev, commit }

struct ChatComposerTextView: NSViewRepresentable {
    @ObservedObject private var themeStore = TatwoThemeStore.shared
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    let isFocused: Bool
    let placeholder: String
    let isMonospaced: Bool
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void
    // #2 skill 建議鍵盤選取：回傳 true 代表這顆鍵被建議面板吃掉（Enter 就不送出）。
    var onSuggestionKey: ((ChatComposerSuggestionKey) -> Bool)?
    // #3 貼圖：Cmd+V / 拖入時只要辨識為圖片就進附件庫；回傳 true
    // 代表已處理，不讓 NSTextView 把 Finder 路徑落進文字。
    var onPasteImage: ((NSPasteboard) -> Bool)?
    var accessibilityTextLabel = "Chat message"
    var onArrowUpAtSingleVisualLine: (() -> Void)?
    var allowsProgrammaticBlur = false
    var resignsFocusOnSubmit = false
    var pointSize: CGFloat?
    var slashCommands = ChatComposerSlashCatalog.commands

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            contentHeight: $contentHeight,
            minimumHeight: minimumHeight,
            maximumHeight: maximumHeight,
            onSubmit: onSubmit,
            onFocusChange: onFocusChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
        scrollView.drawsBackground = false
        // Keep the composer scrollable by wheel/trackpad but never show the
        // AppKit scroller thumb. The visible thumb was easy to grab by mistake
        // and visually fought the Codex-like clean composer.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        // 觸 layoutManager 落在 TextKit 1：斜線指令膠囊需要 boundingRect + drawBackground。
        _ = textView.layoutManager
        textView.slashCommands = slashCommands
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onSuggestionKey = onSuggestionKey
        textView.onPasteImage = onPasteImage
        textView.accessibilityTextLabel = accessibilityTextLabel
        textView.onArrowUpAtSingleVisualLine =
            onArrowUpAtSingleVisualLine
        textView.resignsFocusOnSubmit = resignsFocusOnSubmit
        textView.slashCommands = slashCommands
        textView.onFocusChange = { focused in
            context.coordinator.onFocusChange(focused)
        }
        textView.delegate = context.coordinator
        textView.string = text
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.font = nsFont
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        scrollView.documentView = textView
        scrollView.composerTextView = textView
        DispatchQueue.main.async {
            context.coordinator.refreshContentHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.contentHeight = $contentHeight
        context.coordinator.minimumHeight = minimumHeight
        context.coordinator.maximumHeight = maximumHeight
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.wantsFocus = isFocused
        let coordinator = context.coordinator
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onSuggestionKey = onSuggestionKey
        textView.onPasteImage = onPasteImage
        textView.accessibilityTextLabel = accessibilityTextLabel
        textView.onArrowUpAtSingleVisualLine =
            onArrowUpAtSingleVisualLine
        textView.resignsFocusOnSubmit = resignsFocusOnSubmit
        textView.onFocusChange = { focused in
            context.coordinator.onFocusChange(focused)
        }
        if !textView.hasMarkedText(), textView.font != nsFont {
            textView.font = nsFont
            textView.invalidateSlashHighlightStyle()
        }
        // 只有「外部程式改了 binding」(text != coordinator 上次回報的值) 才寫回 textView；
        // 使用者正在打字時 updateNSView 可能拿到舊快照，若照舊無條件覆蓋會把剛打的字吃掉。
        if text != context.coordinator.lastReportedText, textView.string != text {
            textView.string = text
            context.coordinator.lastReportedText = text
            textView.invalidateSlashHighlightStyle()
        }
        textView.refreshSlashHighlight()
        context.coordinator.refreshContentHeight(for: textView)
        if isFocused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView, weak coordinator] in
                guard let textView,
                      let coordinator,
                      coordinator.wantsFocus == true
                else { return }
                textView.window?.makeFirstResponder(textView)
            }
        } else if textView.window?.firstResponder === textView {
            if allowsProgrammaticBlur {
                DispatchQueue.main.async {
                    [weak textView, weak coordinator] in
                    guard let textView,
                          let coordinator,
                          coordinator.wantsFocus == false,
                          textView.window?.firstResponder === textView
                    else { return }
                    textView.window?.makeFirstResponder(nil)
                }
            }
        }
        textView.needsDisplay = true
    }

    private var nsFont: NSFont {
        let resolvedPointSize =
            pointSize ?? ChatTypography.composerPointSize
        if isMonospaced {
            return NSFont.monospacedSystemFont(
                ofSize: resolvedPointSize,
                weight: .regular
            )
        }
        return NSFont.systemFont(
            ofSize: resolvedPointSize,
            weight: .regular
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var contentHeight: Binding<CGFloat>
        var minimumHeight: CGFloat
        var maximumHeight: CGFloat
        var onSubmit: () -> Void
        var onFocusChange: (Bool) -> Void
        var wantsFocus = false
        private var heightRevision: UInt64 = 0
        private var isMeasuringHeight = false
        // 最後一次「textView → binding」同步的值。用來分辨 updateNSView 收到的 text
        // 是「外部程式改的」(需寫回 textView) 還是「使用者剛打字的舊快照」(不可覆蓋，否則吃字)。
        var lastReportedText: String

        init(
            text: Binding<String>,
            contentHeight: Binding<CGFloat>,
            minimumHeight: CGFloat,
            maximumHeight: CGFloat,
            onSubmit: @escaping () -> Void,
            onFocusChange: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.contentHeight = contentHeight
            self.minimumHeight = minimumHeight
            self.maximumHeight = maximumHeight
            self.onSubmit = onSubmit
            self.onFocusChange = onFocusChange
            self.lastReportedText = text.wrappedValue
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastReportedText = textView.string
            text.wrappedValue = textView.string
            (textView as? ComposerNSTextView)?.refreshSlashHighlight()
            refreshContentHeight(for: textView)
            textView.needsDisplay = true
        }

        func refreshContentHeight(for textView: NSTextView) {
            guard !isMeasuringHeight else { return }
            // Invalidate queued measurements even when the new height already
            // equals the binding (e.g. sending/clearing a long draft).
            heightRevision &+= 1
            let revision = heightRevision
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  textView.bounds.width > 1
            else { return }
            isMeasuringHeight = true
            defer { isMeasuringHeight = false }
            let width = textView.bounds.width
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            let caretBottom = layoutManager.extraLineFragmentTextContainer === textContainer
                ? layoutManager.extraLineFragmentRect.maxY : 0
            let usedHeight = ceil(max(layoutManager.usedRect(for: textContainer).maxY, caretBottom))
            let documentHeight = max(usedHeight, minimumHeight)
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: documentHeight))
            }
            let clampedHeight = min(maximumHeight, documentHeight)
            guard abs(contentHeight.wrappedValue - clampedHeight) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.heightRevision == revision,
                      abs(self.contentHeight.wrappedValue - clampedHeight) > 0.5 else { return }
                self.contentHeight.wrappedValue = clampedHeight
            }
        }
    }

    final class ComposerScrollView: NSScrollView {
        weak var composerTextView: ComposerNSTextView?

        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if let composerTextView {
                window?.makeFirstResponder(composerTextView)
                composerTextView.mouseDown(with: event)
                return
            }
            super.mouseDown(with: event)
        }
    }

    final class ComposerNSTextView: NSTextView {
        override func setFrameSize(_ newSize: NSSize) {
            let oldWidth = frame.width
            super.setFrameSize(newSize)
            // AppKit can resize after updateNSView. Reflow then, rather than
            // waiting for another keystroke or unrelated SwiftUI update.
            if abs(frame.width - oldWidth) > 0.5 {
                (delegate as? Coordinator)?.refreshContentHeight(for: self)
            }
        }

        var placeholder: String = ""
        var onSubmit: (() -> Void)?
        var accessibilityTextLabel = "Chat message"
        var onArrowUpAtSingleVisualLine: (() -> Void)?
        var resignsFocusOnSubmit = false
        /// 斜線指令膠囊：已註冊指令清單與目前命中的字元範圍（畫圓角底＋accent 粗體）。
        var slashCommands: [String] = []
        private var slashHighlightRanges: [NSRange] = []
        private var slashHighlightBaseFontApplied = false

        func invalidateSlashHighlightStyle() {
            slashHighlightBaseFontApplied = false
        }

        func refreshSlashHighlight() {
            guard let textStorage, !hasMarkedText() else { return }
            let value = string
            let pointSize =
                font?.pointSize ?? ChatTypography.composerPointSize
            let baseFont = NSFont.systemFont(
                ofSize: pointSize, weight: .regular)
            var matches: [NSRange] = []
            var location = 0
            for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
                let rawLine = String(line)
                let whitespaceCount = rawLine.prefix { $0.isWhitespace }.utf16.count
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if let cmd = slashCommands.first(where: {
                    trimmed == $0 || trimmed.hasPrefix($0 + " ")
                }) {
                    matches.append(NSRange(
                        location: location + whitespaceCount,
                        length: (cmd as NSString).length))
                }
                location += rawLine.utf16.count + 1
            }
            if matches == slashHighlightRanges, slashHighlightBaseFontApplied {
                return
            }
            let fullRange = NSRange(location: 0, length: (value as NSString).length)
            textStorage.beginEditing()
            textStorage.setAttributes(
                [.font: baseFont, .foregroundColor: textColor ?? NSColor.labelColor],
                range: fullRange)
            for matched in matches {
                let pillFont: NSFont = {
                    let bold = NSFont.systemFont(
                        ofSize: pointSize, weight: .bold)
                    if let rounded = bold.fontDescriptor.withDesign(.rounded),
                       let f = NSFont(descriptor: rounded, size: pointSize) {
                        return f
                    }
                    return bold
                }()
                textStorage.setAttributes(
                    [.font: pillFont, .foregroundColor: NSColor(LiquidGlassTokens.brandAccent)],
                    range: matched)
            }
            textStorage.endEditing()
            typingAttributes = [
                .font: baseFont,
                .foregroundColor: textColor ?? NSColor.labelColor
            ]
            slashHighlightRanges = matches
            slashHighlightBaseFontApplied = true
            needsDisplay = true
        }

        override func drawBackground(in rect: NSRect) {
            super.drawBackground(in: rect)
            guard let layoutManager,
                  let textContainer else { return }
            for range in slashHighlightRanges {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil)
                var pill = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                pill.origin.x += textContainerOrigin.x
                pill.origin.y += textContainerOrigin.y
                pill = pill.insetBy(dx: -4, dy: -1.5)
                let accent = NSColor(LiquidGlassTokens.brandAccent)
                let path = NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6)
                accent.withAlphaComponent(0.12).setFill()
                path.fill()
                accent.withAlphaComponent(0.28).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        var onFocusChange: ((Bool) -> Void)?
        var onSuggestionKey: ((ChatComposerSuggestionKey) -> Bool)?
        var onPasteImage: ((NSPasteboard) -> Bool)?
        private var localKeyMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        // #3 貼圖：先讓附件管線辨識 Finder URL / raw image；未處理才貼純文字。
        override func paste(_ sender: Any?) {
            if onPasteImage?(NSPasteboard.general) == true {
                return
            }
            super.pasteAsPlainText(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if onPasteImage?(sender.draggingPasteboard) == true {
                return true
            }
            return super.performDragOperation(sender)
        }

        // #2 游標在文字結尾且無選取時，→ 才拿來選建議（不破壞一般游標移動）。
        private var cursorAtEnd: Bool {
            let r = selectedRange()
            return r.length == 0 && r.location == (string as NSString).length
        }

        /// 回傳 true 代表這顆鍵被 skill 建議面板消化，呼叫端不應再送出/移動游標。
        private func consumeAsSuggestionKey(_ event: NSEvent) -> Bool {
            guard let onSuggestionKey else { return false }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let wantsNewline = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 124, 125: // →/↓：游標在結尾才選下一個建議
                return cursorAtEnd ? onSuggestionKey(.next) : false
            case 123, 126: // ←/↑：有選中才退選（否則讓游標正常移動）
                return onSuggestionKey(.prev)
            default:
                break
            }
            if isReturn, !wantsNewline, !hasMarkedText() {
                return onSuggestionKey(.commit)
            }
            return false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeLocalKeyMonitor()
            } else {
                installLocalKeyMonitorIfNeeded()
            }
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { onFocusChange?(true) }
            needsDisplay = true
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { onFocusChange?(false) }
            needsDisplay = true
            return result
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            let blockedArrowModifiers: NSEvent.ModifierFlags = [
                .command, .control, .option, .shift
            ]
            if event.keyCode == 126,
               event.modifierFlags.intersection(blockedArrowModifiers).isEmpty,
               !hasMarkedText(),
               isSingleVisualLine,
               let onArrowUpAtSingleVisualLine
            {
                window?.makeFirstResponder(nil)
                onArrowUpAtSingleVisualLine()
                return
            }
            if consumeAsSuggestionKey(event) { return }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let wantsNewline = event.modifierFlags.contains(.shift)
            if isReturn, !wantsNewline, !hasMarkedText() {
                if resignsFocusOnSubmit {
                    window?.makeFirstResponder(nil)
                }
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .textArea
        }

        override func accessibilityLabel() -> String? {
            accessibilityTextLabel
        }

        @objc(accessibilityValue)
        func accessibilityValue() -> Any? {
            string
        }

        override func setAccessibilityValue(_ accessibilityValue: Any?) {
            guard let value = accessibilityValue as? String else {
                super.setAccessibilityValue(accessibilityValue)
                return
            }
            replaceComposerTextWithAccessibleValue(value)
        }

        private func replaceComposerTextWithAccessibleValue(_ value: String) {
            window?.makeFirstResponder(self)
            if string != value {
                if let textStorage {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font ?? NSFont.systemFont(
                            ofSize: ChatTypography.composerPointSize,
                            weight: .regular
                        ),
                        .foregroundColor: textColor ?? NSColor.labelColor
                    ]
                    textStorage.setAttributedString(NSAttributedString(string: value, attributes: attrs))
                } else {
                    string = value
                }
            }
            setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            needsDisplay = true
        }

        private var isSingleVisualLine: Bool {
            guard !string.contains("\n"),
                  let layoutManager,
                  let textContainer
            else {
                return !string.contains("\n")
            }
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else { return true }
            var lineCount = 0
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { _, _, _, _, stop in
                lineCount += 1
                if lineCount > 1 {
                    stop.pointee = true
                }
            }
            return lineCount <= 1
        }

        private func installLocalKeyMonitorIfNeeded() {
            guard localKeyMonitor == nil else { return }
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard event.window === self.window else { return event }
                guard self.window?.firstResponder === self else { return event }
                return self.handleFocusedKeyEvent(event)
            }
        }

        private func removeLocalKeyMonitor() {
            if let localKeyMonitor {
                NSEvent.removeMonitor(localKeyMonitor)
                self.localKeyMonitor = nil
            }
        }

        private func handleFocusedKeyEvent(_ event: NSEvent) -> NSEvent? {
            let blockedModifierMask: NSEvent.ModifierFlags = [.command, .control]
            if !event.modifierFlags.intersection(blockedModifierMask).isEmpty {
                return event
            }
            // #2 skill 建議面板優先吃 →/←/Enter（有選中時）；否則照常。
            if consumeAsSuggestionKey(event) { return nil }
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let wantsNewline = event.modifierFlags.contains(.shift)
            if isReturn, !wantsNewline, !hasMarkedText() {
                if resignsFocusOnSubmit {
                    window?.makeFirstResponder(nil)
                }
                onSubmit?()
                return nil
            }
            // Do not consume normal character keys here.  Computer Use and
            // AppKit can both deliver literal typing through the regular
            // NSTextView responder path; swallowing non-return keys in the
            // local monitor made the AX tree report a focused text area while
            // no visible characters were inserted.  The monitor only owns the
            // Codex-like Enter-to-send shortcut.
            return event
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !placeholder.isEmpty,
                  let font
            else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let origin = NSPoint(x: inset.width + padding, y: inset.height)
            placeholder.draw(
                at: origin,
                withAttributes: attrs)
        }
    }
}
