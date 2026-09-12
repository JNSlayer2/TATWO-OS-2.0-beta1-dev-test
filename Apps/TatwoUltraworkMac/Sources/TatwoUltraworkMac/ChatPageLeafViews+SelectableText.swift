import SwiftUI
import AppKit
import Foundation
import QuickLook
import TatwoUltraworkCore

// 2026-08-23 使用者回報「複製完有殘影」＋「點空白沒辦法取消全選」：
// 每則訊息是獨立 NSTextView，點空白區焦點不會移動、選取就殘留。
// 全域滑鼠監聽：按下任何不在當前選取文字區內的位置就清除選取，
// 並保證整個 transcript 同時間只有一則訊息帶反白。
// 2026-08-23 使用者三修「全選還是超級爛」：整套改成跨訊息拖選——
// 任意處按下拖曳，跨多則訊息連續反白（boundary 訊息取局部 range、中間
// 訊息全選），Cmd+C 聚合複製、Cmd+A 全選可見訊息、點任何地方清空。
// highlight 用 temporary attribute（非 native selection，失焦不變灰）。
@MainActor
private final class ChatFlowSelectionCoordinator {
    static let shared = ChatFlowSelectionCoordinator()

    private weak var activeTextView: NSTextView?
    private var mouseMonitor: Any?
    private var dragMonitor: Any?
    private var keyMonitor: Any?
    private weak var sessionWindow: NSWindow?
    private var anchorPoint: NSPoint = .zero
    private var selection: [(view: ChatFlowTextView, range: NSRange)] = []

    var hasSelection: Bool { !selection.isEmpty }

    // MARK: 舊 native 選取（保留給雙擊選字/三擊選段）

    func noteSelectionChanged(_ textView: NSTextView) {
        guard textView.selectedRange().length > 0 else {
            if activeTextView === textView { activeTextView = nil }
            return
        }
        clearHighlights()
        if activeTextView !== textView, let previous = activeTextView {
            previous.setSelectedRange(NSRange(location: 0, length: 0))
        }
        activeTextView = textView
        installMonitorsIfNeeded()
    }

    // MARK: 跨訊息拖選 session

    func beginDragSession(from event: NSEvent) {
        clearAll()
        guard let window = event.window else { return }
        sessionWindow = window
        anchorPoint = event.locationInWindow
        installMonitorsIfNeeded()
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]
        ) { [weak self] dragEvent in
            guard let self else { return dragEvent }
            if dragEvent.type == .leftMouseUp {
                self.endDragSession()
            } else {
                self.updateDragSession(to: dragEvent.locationInWindow)
            }
            return dragEvent
        }
    }

    private func endDragSession() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    private func updateDragSession(to current: NSPoint) {
        guard let window = sessionWindow else { return }
        // 3px 內視為 click，不起選取。
        if abs(current.x - anchorPoint.x) < 3, abs(current.y - anchorPoint.y) < 3 {
            return
        }
        let views = Self.flowTextViews(in: window)
        guard !views.isEmpty else { return }
        let top = anchorPoint.y >= current.y ? anchorPoint : current
        let bottom = anchorPoint.y >= current.y ? current : anchorPoint
        var next: [(view: ChatFlowTextView, range: NSRange)] = []
        for view in views {
            guard let superview = view.superview else { continue }
            let frame = superview.convert(view.frame, to: nil)
            let length = (view.textStorage?.length) ?? 0
            guard length > 0 else { continue }
            let containsTop = frame.maxY >= top.y && frame.minY <= top.y
            let containsBottom = frame.maxY >= bottom.y && frame.minY <= bottom.y
            let fullyInside = frame.maxY <= top.y && frame.minY >= bottom.y
            var range: NSRange?
            if containsTop && containsBottom {
                let a = view.characterIndexForInsertion(
                    at: view.convert(top, from: nil))
                let b = view.characterIndexForInsertion(
                    at: view.convert(bottom, from: nil))
                let lower = max(0, min(a, b))
                let upper = min(length, max(a, b))
                if upper > lower {
                    range = NSRange(location: lower, length: upper - lower)
                }
            } else if containsTop {
                let index = max(0, min(length, view.characterIndexForInsertion(
                    at: view.convert(top, from: nil))))
                if length > index {
                    range = NSRange(location: index, length: length - index)
                }
            } else if containsBottom {
                let index = max(0, min(length, view.characterIndexForInsertion(
                    at: view.convert(bottom, from: nil))))
                if index > 0 {
                    range = NSRange(location: 0, length: index)
                }
            } else if fullyInside {
                range = NSRange(location: 0, length: length)
            }
            if let range {
                next.append((view, range))
            }
        }
        applyHighlights(next)
    }

    private func applyHighlights(
        _ next: [(view: ChatFlowTextView, range: NSRange)]
    ) {
        for (view, _) in selection {
            removeHighlight(from: view)
        }
        selection = next
        let color = ChatFlowSelectionColor.temporaryHighlight()
        for (view, range) in next {
            view.layoutManager?.addTemporaryAttribute(
                .backgroundColor, value: color, forCharacterRange: range)
        }
    }

    private func removeHighlight(from view: ChatFlowTextView) {
        guard let storage = view.textStorage else { return }
        view.layoutManager?.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    private func clearHighlights() {
        for (view, _) in selection {
            removeHighlight(from: view)
        }
        selection = []
    }

    private func clearAll() {
        clearHighlights()
        activeTextView?.setSelectedRange(NSRange(location: 0, length: 0))
        activeTextView = nil
        endDragSession()
    }

    // MARK: 複製與全選

    func copySelection() {
        let ordered = selection.sorted { lhs, rhs in
            windowFrame(of: lhs.view).maxY > windowFrame(of: rhs.view).maxY
        }
        let parts: [String] = ordered.compactMap { view, range in
            guard let storage = view.textStorage,
                  range.location + range.length <= storage.length
            else { return nil }
            return (storage.string as NSString).substring(with: range)
        }
        guard !parts.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(parts.joined(separator: "\n"), forType: .string)
    }

    func selectAllVisible(in window: NSWindow) {
        clearAll()
        sessionWindow = window
        installMonitorsIfNeeded()
        let all: [(view: ChatFlowTextView, range: NSRange)] =
            Self.flowTextViews(in: window).compactMap { view in
                let length = view.textStorage?.length ?? 0
                guard length > 0 else { return nil }
                return (view, NSRange(location: 0, length: length))
            }
        applyHighlights(all)
    }

    private func windowFrame(of view: NSView) -> NSRect {
        view.superview?.convert(view.frame, to: nil) ?? .zero
    }

    private static func flowTextViews(in window: NSWindow) -> [ChatFlowTextView] {
        guard let root = window.contentView else { return [] }
        var result: [ChatFlowTextView] = []
        collect(&result, in: root)
        // 由上到下（AppKit window 座標 y 向上，大者在上）。
        return result.sorted {
            ($0.superview?.convert($0.frame, to: nil).maxY ?? 0)
                > ($1.superview?.convert($1.frame, to: nil).maxY ?? 0)
        }
    }

    private static func collect(
        _ result: inout [ChatFlowTextView], in view: NSView
    ) {
        if let flow = view as? ChatFlowTextView { result.append(flow) }
        for subview in view.subviews {
            collect(&result, in: subview)
        }
    }

    // MARK: 監聽

    private func installMonitorsIfNeeded() {
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        // 拖選起手（beginDragSession 已 clearAll）以外的任何按下都清空。
        if event.type == .leftMouseDown, dragMonitor != nil { return }
        if let textView = activeTextView {
            guard let window = textView.window, event.window === window else {
                clearAll()
                return
            }
            let point = textView.convert(event.locationInWindow, from: nil)
            if !textView.bounds.contains(point) {
                clearAll()
            }
            return
        }
        if hasSelection, event.type == .rightMouseDown { return }
        if hasSelection { clearHighlights() }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // 編輯中的輸入框優先（composer 打字/選字不被劫持）。
        let editingResponder = event.window?.firstResponder as? NSTextView
        let composerIsEditing = editingResponder.map {
            !($0 is ChatFlowTextView) && $0.isEditable
        } ?? false
        if key == "c" {
            if composerIsEditing, editingResponder?.selectedRange().length ?? 0 > 0 {
                return event
            }
            if hasSelection {
                copySelection()
                return nil
            }
            return event
        }
        if key == "a" {
            if composerIsEditing { return event }
            guard let window = event.window,
                  !Self.flowTextViews(in: window).isEmpty
            else { return event }
            selectAllVisible(in: window)
            return nil
        }
        return event
    }
}

enum ChatTranscriptLinkPolicy {
    static func safeURL(from link: Any) -> URL? {
        let url: URL?
        switch link {
        case let value as URL:
            url = value
        case let value as NSURL:
            url = value as URL
        case let value as String:
            url = URL(string: value)
        case let value as NSString:
            url = URL(string: value as String)
        default:
            url = nil
        }
        guard EmbeddedBrowserNavigationPolicy.decision(for: url) == .allow
        else { return nil }
        return url
    }
}

@MainActor
final class ChatCodeBlockAccessoryView: NSView {
    let code: String
    let language: String
    let copyButton: NSButton
    let horizontalViewerButton: NSButton
    var copyAction: ((String) -> Void)?
    var viewerAction: ((String, String) -> Void)?

    init(code: String, language: String) {
        self.code = code
        self.language = language
        copyButton = NSButton(
            title: "複製",
            target: nil,
            action: nil)
        horizontalViewerButton = NSButton(
            title: "橫向檢視",
            target: nil,
            action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: 24))

        copyButton.bezelStyle = .roundRect
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyCode(_:))
        copyButton.setAccessibilityLabel("複製程式碼")

        horizontalViewerButton.bezelStyle = .roundRect
        horizontalViewerButton.controlSize = .small
        horizontalViewerButton.target = self
        horizontalViewerButton.action = #selector(openHorizontalViewer(_:))
        horizontalViewerButton.setAccessibilityLabel("水平檢視程式碼")

        addSubview(copyButton)
        addSubview(horizontalViewerButton)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        copyButton.frame = NSRect(x: 0, y: 0, width: 50, height: 24)
        horizontalViewerButton.frame =
            NSRect(x: 54, y: 0, width: 78, height: 24)
    }

    @objc private func copyCode(_ sender: Any?) {
        copyAction?(code)
    }

    @objc private func openHorizontalViewer(_ sender: Any?) {
        viewerAction?(code, language)
    }
}

@MainActor
enum ChatCodeBlockHorizontalViewer {
    static func makeScrollView(code: String) -> NSScrollView {
        let codeView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        codeView.isEditable = false
        codeView.isSelectable = true
        codeView.isRichText = false
        codeView.isHorizontallyResizable = true
        codeView.isVerticallyResizable = true
        codeView.textContainer?.widthTracksTextView = false
        codeView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        codeView.textContainer?.lineFragmentPadding = 8
        codeView.font = NSFont.monospacedSystemFont(
            ofSize: TatwoChatTranscriptVisualMetrics.codePointSize,
            weight: .regular)
        codeView.string = code
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        codeView.defaultParagraphStyle = style

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = codeView
        return scrollView
    }
}

final class ChatFlowTextView: NSTextView, NSTextViewDelegate {
    // 2026-08-23 使用者回報「複製鍵又壞了」：NSTextView 攔走右鍵，SwiftUI
    // .contextMenu 的「複製訊息」不再出現。把整則複製直接塞進原生選單。
    var copyAllText: String = ""
    var renderedContentFingerprint:
        ChatSelectableFlowTextContentFingerprint?
    var renderedAttributedObjectID: ObjectIdentifier?
    var streamingPlainTextController:
        ChatStreamingPlainTextStorageController?
    var safeLinkOpener: (URL) -> Bool = {
        NSWorkspace.shared.open($0)
    }
    private(set) var codeBlockAccessoryViews:
        [(range: NSRange, view: ChatCodeBlockAccessoryView)] = []
    private var codeViewerPanel: NSPanel?

    override func mouseDown(with event: NSEvent) {
        // 單擊拖曳走跨訊息選取；雙擊/三擊保留原生選字/選段。
        if event.clickCount > 1 {
            super.mouseDown(with: event)
            return
        }
        if safeLink(at: event) != nil {
            // Let AppKit preserve ordinary click-vs-drag semantics. The
            // delegate below consumes the action and opens only policy-approved
            // public http/https destinations.
            super.mouseDown(with: event)
            return
        }
        ChatFlowSelectionCoordinator.shared.beginDragSession(from: event)
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = ChatTranscriptLinkPolicy.safeURL(from: link) else {
            // Returning true consumes unsafe links so AppKit cannot fall back to
            // opening a file/custom/private-network URL.
            return true
        }
        _ = safeLinkOpener(url)
        return true
    }

    func synchronizeCodeBlockAccessories() {
        for entry in codeBlockAccessoryViews {
            entry.view.removeFromSuperview()
        }
        codeBlockAccessoryViews = []
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.enumerateAttribute(
            .chatTranscriptCodeContent,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            guard let code = value as? String else { return }
            let language =
                storage.attribute(
                    .chatTranscriptCodeLanguage,
                    at: range.location,
                    effectiveRange: nil
                ) as? String ?? ""
            let accessory = ChatCodeBlockAccessoryView(
                code: code,
                language: language)
            accessory.copyAction = { code in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(code, forType: .string)
            }
            accessory.viewerAction = { [weak self] code, language in
                self?.presentHorizontalCodeViewer(
                    code: code,
                    language: language)
            }
            addSubview(accessory)
            codeBlockAccessoryViews.append((range, accessory))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        positionCodeBlockAccessories()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if menu.items.isEmpty == false {
            menu.insertItem(NSMenuItem.separator(), at: 0)
        }
        if !copyAllText.isEmpty {
            let item = NSMenuItem(
                title: "複製訊息",
                action: #selector(copyWholeMessage(_:)),
                keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
        if ChatFlowSelectionCoordinator.shared.hasSelection {
            let item = NSMenuItem(
                title: "複製選取",
                action: #selector(copySelectionFromCoordinator(_:)),
                keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    @objc private func copySelectionFromCoordinator(_ sender: Any?) {
        ChatFlowSelectionCoordinator.shared.copySelection()
    }

    @objc private func copyWholeMessage(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyAllText, forType: .string)
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(
            ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        ChatFlowSelectionCoordinator.shared.noteSelectionChanged(self)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        return resigned
    }

    private func safeLink(at event: NSEvent) -> URL? {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0
        else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        point.x -= origin.x
        point.y -= origin.y
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer)
        guard glyphRect.contains(point) else { return nil }
        let characterIndex =
            layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length,
              let link = textStorage.attribute(
                .link,
                at: characterIndex,
                effectiveRange: nil)
        else { return nil }
        return ChatTranscriptLinkPolicy.safeURL(from: link)
    }

    private func positionCodeBlockAccessories() {
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for entry in codeBlockAccessoryViews {
            let glyphRange =
                layoutManager.glyphRange(
                    forCharacterRange: entry.range,
                    actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer)
            entry.view.frame.origin = NSPoint(
                x: max(
                    origin.x,
                    origin.x + rect.maxX - entry.view.frame.width - 6),
                y: origin.y + rect.minY + 4)
        }
    }

    private func presentHorizontalCodeViewer(
        code: String,
        language: String
    ) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        panel.title =
            language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "程式碼"
            : "程式碼 · \(language)"
        panel.contentView =
            ChatCodeBlockHorizontalViewer.makeScrollView(code: code)
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        codeViewerPanel = panel
    }
}

struct ChatStreamingPlainTextMetrics: Equatable {
    var fullAttributedReplacements = 0
    var incrementalAttributedAppends = 0
    var fullPayloadBuilds = 0
    var structuredAttributedReplacements = 0
    var layoutComputations = 0
    var fullLayoutComputations = 0
    var incrementalLayoutComputations = 0
    var layoutCacheHits = 0
    var textContainerResizes = 0
    var structuredWidthAdaptations = 0
    var lastLaidOutGlyphRange = NSRange(location: 0, length: 0)
}

struct ChatTranscriptPresentationIdentity: Equatable {
    let messageID: String
    let parserVersion: Int
    let pointSizeBits: UInt64
    let lineSpacingBits: UInt64
    let sessionBoundaryGeneration: UInt64

    init(
        messageID: String,
        parserVersion: Int,
        pointSize: CGFloat =
            TatwoChatTranscriptVisualMetrics.transcriptPointSize,
        lineSpacing: CGFloat =
            TatwoChatTranscriptVisualMetrics.transcriptLineSpacing,
        sessionBoundaryGeneration: UInt64
    ) {
        self.messageID = messageID
        self.parserVersion = parserVersion
        pointSizeBits = Double(pointSize).bitPattern
        lineSpacingBits = Double(lineSpacing).bitPattern
        self.sessionBoundaryGeneration = sessionBoundaryGeneration
    }
}

struct ChatStreamingTextLayoutMeasurement {
    let size: CGSize
    let didResizeTextContainer: Bool
    let laidOutGlyphRange: NSRange
}

@MainActor
protocol ChatStreamingTextLayoutMeasuring: AnyObject {
    func measure(
        width: CGFloat,
        container: NSTextContainer,
        layoutManager: NSLayoutManager
    ) -> ChatStreamingTextLayoutMeasurement
}

@MainActor
final class ChatDefaultStreamingTextLayoutMeasurer:
    ChatStreamingTextLayoutMeasuring
{
    func measure(
        width: CGFloat,
        container: NSTextContainer,
        layoutManager: NSLayoutManager
    ) -> ChatStreamingTextLayoutMeasurement {
        let size = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude)
        let didResize = container.size != size
        if didResize {
            container.size = size
        }
        layoutManager.ensureLayout(for: container)
        return ChatStreamingTextLayoutMeasurement(
            size: CGSize(
                width: width,
                height: ceil(layoutManager.usedRect(for: container).height)),
            didResizeTextContainer: didResize,
            laidOutGlyphRange: layoutManager.glyphRange(for: container))
    }
}

/// Keeps the NSTextStorage object and its laid-out prefix alive while one
/// assistant message streams. A growing source appends only the suffix; a true
/// rewrite or presentation change falls back to one correctness-first replace.
@MainActor
final class ChatStreamingPlainTextStorageController {
    private struct LayoutKey: Equatable {
        let fingerprint: ChatStableContentFingerprint
        let widthBits: UInt64
        let traits: ChatSelectableFlowTextLayoutTraits
    }

    private enum RenderMode {
        case plain
        case structured
        /// A parsed attributed prefix plus raw streaming suffix. This keeps the
        /// same NSTextStorage/glyph prefix alive until the coalesced parser
        /// publishes the next structured payload.
        case structuredWithPlainTail
    }

    private var presentationIdentity: ChatTranscriptPresentationIdentity?
    private var renderedSource = ""
    private var renderedFingerprint = ChatStableContentFingerprint.empty
    private var renderedRevision: UUID?
    private var renderMode: RenderMode?
    private var lastMutationWasIncrementalAppend = false
    private var lastLayoutKey: LayoutKey?
    private var lastLayoutSize: CGSize?
    private var structuredLayoutWidthBits: UInt64?
    private(set) var metrics = ChatStreamingPlainTextMetrics()
    private let layoutMeasurer: ChatStreamingTextLayoutMeasuring

    init(
        layoutMeasurer: ChatStreamingTextLayoutMeasuring =
            ChatDefaultStreamingTextLayoutMeasurer()
    ) {
        self.layoutMeasurer = layoutMeasurer
    }

    func apply(
        text: String,
        fingerprint: ChatStableContentFingerprint,
        presentationIdentity: ChatTranscriptPresentationIdentity,
        sourceRevision: UUID? = nil,
        appendBaseRevision: UUID? = nil,
        appendedDisplaySuffix: String? = nil,
        to textStorage: NSTextStorage,
        preservingStateOf textView: NSTextView? = nil
    ) {
        var appendedToStructuredPrefix = false
        if self.presentationIdentity == presentationIdentity,
           renderedFingerprint == fingerprint,
           renderedSource == text
        {
            return
        }

        if self.presentationIdentity == presentationIdentity,
           (renderMode == .plain
                || renderMode == .structured
                || renderMode == .structuredWithPlainTail),
           let sourceRevision,
           let appendBaseRevision,
           let appendedDisplaySuffix,
           renderedRevision == appendBaseRevision
        {
            if !appendedDisplaySuffix.isEmpty {
                textStorage.append(Self.attributed(appendedDisplaySuffix))
                metrics.incrementalAttributedAppends += 1
                lastMutationWasIncrementalAppend = true
            }
            renderedRevision = sourceRevision
            if renderMode != .plain {
                appendedToStructuredPrefix = true
            }
        } else {
            replaceTextStorage(
                with: Self.attributed(text),
                textStorage: textStorage,
                textView: textView)
            metrics.fullAttributedReplacements += 1
            metrics.fullPayloadBuilds += 1
            lastMutationWasIncrementalAppend = false
            (textView as? ChatFlowTextView)?
                .synchronizeCodeBlockAccessories()
        }

        self.presentationIdentity = presentationIdentity
        renderedSource = text
        renderedFingerprint = fingerprint
        renderedRevision = sourceRevision
        renderMode =
            appendedToStructuredPrefix ? .structuredWithPlainTail : .plain
        if !appendedToStructuredPrefix {
            structuredLayoutWidthBits = nil
        }
        lastLayoutKey = nil
        lastLayoutSize = nil
    }

    func applyStructured(
        sourceText: String,
        sourceFingerprint: ChatStableContentFingerprint,
        attributed: NSAttributedString,
        contentFingerprint: ChatSelectableFlowTextContentFingerprint,
        presentationIdentity: ChatTranscriptPresentationIdentity,
        sourceRevision: UUID? = nil,
        to textStorage: NSTextStorage,
        preservingStateOf textView: NSTextView? = nil
    ) {
        if self.presentationIdentity == presentationIdentity,
           renderMode == .structured,
           renderedFingerprint == sourceFingerprint,
           renderedSource == sourceText,
           (textView as? ChatFlowTextView)?.renderedContentFingerprint
                == contentFingerprint
        {
            return
        }
        replaceTextStorage(
            with: attributed,
            textStorage: textStorage,
            textView: textView)
        (textView as? ChatFlowTextView)?.renderedContentFingerprint =
            contentFingerprint
        (textView as? ChatFlowTextView)?.renderedAttributedObjectID =
            ObjectIdentifier(attributed)
        (textView as? ChatFlowTextView)?
            .synchronizeCodeBlockAccessories()
        metrics.fullAttributedReplacements += 1
        metrics.structuredAttributedReplacements += 1
        lastMutationWasIncrementalAppend = false
        self.presentationIdentity = presentationIdentity
        renderedSource = sourceText
        renderedFingerprint = sourceFingerprint
        renderedRevision = sourceRevision
        renderMode = .structured
        structuredLayoutWidthBits = nil
        lastLayoutKey = nil
        lastLayoutSize = nil
    }

    func measure(
        width: CGFloat,
        traits: ChatSelectableFlowTextLayoutTraits,
        container: NSTextContainer,
        layoutManager: NSLayoutManager
    ) -> CGSize {
        adaptStructuredLayoutIfNeeded(
            width: width,
            textStorage: layoutManager.textStorage)
        let key = LayoutKey(
            fingerprint: renderedFingerprint,
            widthBits: Double(width).bitPattern,
            traits: traits)
        if key == lastLayoutKey, let lastLayoutSize {
            metrics.layoutCacheHits += 1
            return lastLayoutSize
        }

        let measurement = layoutMeasurer.measure(
            width: width,
            container: container,
            layoutManager: layoutManager)
        let measured = measurement.size
        metrics.layoutComputations += 1
        if measurement.didResizeTextContainer {
            metrics.textContainerResizes += 1
        }
        metrics.lastLaidOutGlyphRange = measurement.laidOutGlyphRange
        if lastMutationWasIncrementalAppend,
           !measurement.didResizeTextContainer
        {
            metrics.incrementalLayoutComputations += 1
        } else {
            metrics.fullLayoutComputations += 1
        }
        lastMutationWasIncrementalAppend = false
        lastLayoutKey = key
        lastLayoutSize = measured
        return measured
    }

    private func adaptStructuredLayoutIfNeeded(
        width: CGFloat,
        textStorage: NSTextStorage?
    ) {
        guard renderMode == .structured
                || renderMode == .structuredWithPlainTail,
              let textStorage,
              textStorage.length > 0
        else { return }
        let normalizedWidth = max(1, width.rounded(.toNearestOrAwayFromZero))
        let widthBits = Double(normalizedWidth).bitPattern
        guard structuredLayoutWidthBits != widthBits else { return }

        var updates: [(NSRange, NSParagraphStyle)] = []
        textStorage.enumerateAttribute(
            .chatTranscriptTableColumnCount,
            in: NSRange(location: 0, length: textStorage.length),
            options: []
        ) { value, range, _ in
            guard let count = (value as? NSNumber)?.intValue,
                  count > 0
            else { return }
            let existing =
                (textStorage.attribute(
                    .paragraphStyle,
                    at: range.location,
                    effectiveRange: nil) as? NSParagraphStyle)
                ?? NSParagraphStyle.default
            let style = existing.mutableCopy() as! NSMutableParagraphStyle
            let alignments = style.tabStops.map(\.alignment)
            let usableWidth = max(1, normalizedWidth - 20)
            let columnWidth = usableWidth / CGFloat(count)
            style.defaultTabInterval = columnWidth
            style.tabStops = (1..<count).map { index in
                let alignmentIndex = index - 1
                let alignment =
                    alignments.indices.contains(alignmentIndex)
                    ? alignments[alignmentIndex]
                    : .left
                return NSTextTab(
                    textAlignment: alignment,
                    location: CGFloat(index) * columnWidth)
            }
            updates.append((range, style))
        }
        guard !updates.isEmpty else {
            structuredLayoutWidthBits = widthBits
            return
        }
        textStorage.beginEditing()
        for update in updates {
            textStorage.addAttribute(
                .paragraphStyle,
                value: update.1,
                range: update.0)
        }
        textStorage.endEditing()
        structuredLayoutWidthBits = widthBits
        metrics.structuredWidthAdaptations += 1
        lastLayoutKey = nil
        lastLayoutSize = nil
    }

    private func replaceTextStorage(
        with attributed: NSAttributedString,
        textStorage: NSTextStorage,
        textView: NSTextView?
    ) {
        let selectedRanges = textView?.selectedRanges ?? []
        let scrollOrigin = textView?.enclosingScrollView?
            .contentView.bounds.origin
        textStorage.setAttributedString(attributed)
        if let textView, !selectedRanges.isEmpty {
            let maximum = attributed.length
            let clamped = selectedRanges.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, maximum)
                let length = min(range.length, maximum - location)
                return NSValue(range: NSRange(
                    location: location,
                    length: length))
            }
            textView.selectedRanges = clamped
        }
        if let scrollOrigin,
           let clipView = textView?.enclosingScrollView?.contentView
        {
            clipView.scroll(to: scrollOrigin)
            textView?.enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    private static func attributed(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing =
            TatwoChatTranscriptVisualMetrics.transcriptLineSpacing
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize:
                        TatwoChatTranscriptVisualMetrics.transcriptPointSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
    }
}

// 2026-08-23 使用者裁決選取反白色：fable5 主題用淺橘（珊瑚橘疊暖紙），
// 極光主題用粉紫藍漸變（鏡像 pattern 無縫平鋪）。
private enum ChatFlowSelectionColor {
    @MainActor
    static func current() -> NSColor {
        switch TatwoThemeStore.shared.activeThemeID {
        case .fable5:
            // 對齊現有淺橘（user bubble＝赤陶 5% 疊牛皮紙）：選取要看得見
            // 但保持同一族淡雅——赤陶 14% 疊 canvas，不用飽和珊瑚橘。
            let palette = TatwoTheme.fable5.palette
            return blend(
                NSColor(palette.brandAccent),
                over: NSColor(palette.canvasBase),
                fraction: 0.14)
        case .aurora:
            return auroraGradientPattern
        }
    }

    private static func blend(
        _ tint: NSColor, over base: NSColor, fraction: CGFloat
    ) -> NSColor {
        let t = tint.usingColorSpace(.sRGB) ?? tint
        let b = base.usingColorSpace(.sRGB) ?? base
        return NSColor(
            srgbRed: b.redComponent + (t.redComponent - b.redComponent) * fraction,
            green: b.greenComponent + (t.greenComponent - b.greenComponent) * fraction,
            blue: b.blueComponent + (t.blueComponent - b.blueComponent) * fraction,
            alpha: 1)
    }

    /// 跨訊息拖選的 temporary attribute 用：pattern 色在 temporary background
    /// 不保證會畫（grok 邊界審查 #9/#12），給實色版本——極光取紫藍中間調。
    @MainActor
    static func temporaryHighlight() -> NSColor {
        switch TatwoThemeStore.shared.activeThemeID {
        case .fable5:
            return current()
        case .aurora:
            let palette = TatwoTheme.aurora.palette
            return blend(
                NSColor(palette.accentViolet),
                over: NSColor.white,
                fraction: 0.42)
        }
    }

    private static let auroraGradientPattern: NSColor = {
        let palette = TatwoTheme.aurora.palette
        let stops = [
            NSColor(palette.accentPink),
            NSColor(palette.accentViolet),
            NSColor(palette.accentBlue),
            NSColor(palette.accentViolet),
            NSColor(palette.accentPink),
        ].map { $0.withAlphaComponent(0.55) }
        let size = NSSize(width: 480, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let gradient = NSGradient(colors: stops) else { return false }
            gradient.draw(in: rect, angle: 0)
            return true
        }
        return NSColor(patternImage: image)
    }()
}

// 2026-08-23 使用者回報「全選一定要滑鼠指到字」：拖選只能從文字區內起手，
// 空白處（段間、訊息邊緣）按下沒反應。透明捕捉層鋪在整則訊息底下，
// 把空白處的左鍵按下轉發給最近的文字區（TextKit 會夾到最近字元開始拖選），
// 空白右鍵也回同一份原生選單（含「複製訊息」）。
private final class ChatRowSelectionCatcherView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // 空白處起手同樣進跨訊息拖選 session。
        ChatFlowSelectionCoordinator.shared.beginDragSession(from: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nearestFlowTextView(for: event)?.menu(for: event) ?? super.menu(for: event)
    }

    private func nearestFlowTextView(for event: NSEvent) -> ChatFlowTextView? {
        guard let root = window?.contentView else { return nil }
        var candidates: [ChatFlowTextView] = []
        collectFlowTextViews(&candidates, in: root)
        guard !candidates.isEmpty else { return nil }
        let point = event.locationInWindow
        return candidates.min { distanceSquared($0, point) < distanceSquared($1, point) }
    }

    private func collectFlowTextViews(
        _ result: inout [ChatFlowTextView], in view: NSView
    ) {
        if let flow = view as? ChatFlowTextView { result.append(flow) }
        for subview in view.subviews {
            collectFlowTextViews(&result, in: subview)
        }
    }

    private func distanceSquared(_ view: NSView, _ windowPoint: NSPoint) -> CGFloat {
        guard let superview = view.superview else { return .greatestFiniteMagnitude }
        let frame = superview.convert(view.frame, to: nil)
        let dx = max(frame.minX - windowPoint.x, windowPoint.x - frame.maxX, 0)
        let dy = max(frame.minY - windowPoint.y, windowPoint.y - frame.maxY, 0)
        return dx * dx + dy * dy
    }
}

struct ChatRowSelectionCatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChatRowSelectionCatcherView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ChatSelectableFlowTextContentFingerprint: Hashable {
    let text: ChatStableContentFingerprint
    let attributes: ChatStableContentFingerprint
    let attributedLength: Int
    let attributeRunCount: Int
    let isCacheable: Bool

    init(
        text: String,
        semanticLayoutDescriptor: String,
        attributedLength: Int,
        attributeRunCount: Int
    ) {
        self.text = ChatStableContentFingerprint(text)
        self.attributes =
            ChatStableContentFingerprint(semanticLayoutDescriptor)
        self.attributedLength = attributedLength
        self.attributeRunCount = attributeRunCount
        self.isCacheable = true
    }

    init(_ attributed: NSAttributedString) {
        text = ChatStableContentFingerprint(attributed.string)
        attributedLength = attributed.length
        var descriptors: [String] = []
        var allAttributesHaveStableDescriptors = true
        attributed.enumerateAttributes(
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { attributes, range, _ in
            let values = attributes.keys.sorted {
                $0.rawValue < $1.rawValue
            }.map { key in
                guard let descriptor =
                    Self.stableLayoutDescriptor(attributes[key])
                else {
                    allAttributesHaveStableDescriptors = false
                    return "\(key.rawValue)=uncacheable"
                }
                return "\(key.rawValue)=\(descriptor)"
            }.joined(separator: ";")
            descriptors.append(
                "\(range.location):\(range.length){\(values)}")
        }
        attributeRunCount = descriptors.count
        self.attributes = ChatStableContentFingerprint(
            descriptors.joined(separator: "|"))
        isCacheable = allAttributesHaveStableDescriptors
    }

    // Built with explicit `[String]` accumulation and interpolation instead of
    // one large heterogeneous array literal: the literal form made the Swift
    // type checker give up ("unable to type-check this expression in
    // reasonable time") and `String(_: CGFloat)` had no exact overload there.
    private static func stableLayoutDescriptor(_ value: Any?) -> String? {
        switch value {
        case nil:
            return "nil"
        case let font as NSFont:
            var parts: [String] = ["font"]
            parts.append(font.fontName)
            parts.append(font.familyName ?? "")
            parts.append(font.displayName ?? "")
            parts.append("\(font.pointSize)")
            parts.append("\(font.fontDescriptor.symbolicTraits.rawValue)")
            let matrix = font.matrix
            parts.append(
                "matrix="
                    + (0..<6).map { "\(matrix[$0])" }
                        .joined(separator: ","))
            if let variation = font.fontDescriptor.object(forKey: .variation) {
                guard let descriptor = stableFoundationDescriptor(variation)
                else { return nil }
                parts.append("variation=\(descriptor)")
            }
            if let features =
                font.fontDescriptor.object(forKey: .featureSettings)
            {
                guard let descriptor = stableFoundationDescriptor(features)
                else { return nil }
                parts.append("features=\(descriptor)")
            }
            return parts.joined(separator: ":")
        case let paragraph as NSParagraphStyle:
            // NSTextList/NSTextBlock can carry custom subclasses whose
            // descriptions include process-local pointers. Fail open for
            // rendering but bypass the cache instead of filling it with keys
            // that can never hit.
            guard paragraph.textLists.isEmpty,
                  paragraph.textBlocks.isEmpty
            else { return nil }
            var tabs: [String] = []
            tabs.reserveCapacity(paragraph.tabStops.count)
            for tab in paragraph.tabStops {
                guard let options =
                    stableFoundationDescriptor(tab.options)
                else { return nil }
                tabs.append(
                    "\(tab.alignment.rawValue),\(tab.location),\(options)")
            }
            var parts: [String] = ["paragraph"]
            parts.append("\(paragraph.alignment.rawValue)")
            parts.append("\(paragraph.lineBreakMode.rawValue)")
            parts.append("\(paragraph.baseWritingDirection.rawValue)")
            parts.append("\(paragraph.lineSpacing)")
            parts.append("\(paragraph.paragraphSpacing)")
            parts.append("\(paragraph.paragraphSpacingBefore)")
            parts.append("\(paragraph.firstLineHeadIndent)")
            parts.append("\(paragraph.headIndent)")
            parts.append("\(paragraph.tailIndent)")
            parts.append("\(paragraph.minimumLineHeight)")
            parts.append("\(paragraph.maximumLineHeight)")
            parts.append("\(paragraph.lineHeightMultiple)")
            parts.append("\(paragraph.defaultTabInterval)")
            parts.append("\(paragraph.hyphenationFactor)")
            parts.append("\(paragraph.tighteningFactorForTruncation)")
            parts.append("\(paragraph.allowsDefaultTighteningForTruncation)")
            parts.append(tabs.joined(separator: "+"))
            return parts.joined(separator: ":")
        case let attachment as NSTextAttachment:
            let bounds = attachment.bounds
            var parts: [String] = ["attachment"]
            parts.append("\(bounds.origin.x)")
            parts.append("\(bounds.origin.y)")
            parts.append("\(bounds.size.width)")
            parts.append("\(bounds.size.height)")
            if let imageSize = attachment.image?.size {
                parts.append("image=\(imageSize.width),\(imageSize.height)")
            }
            return parts.joined(separator: ":")
        case let color as NSColor:
            guard let rgb = color.usingColorSpace(.extendedSRGB) else {
                return nil
            }
            return [
                "color",
                "\(rgb.redComponent)",
                "\(rgb.greenComponent)",
                "\(rgb.blueComponent)",
                "\(rgb.alphaComponent)",
            ].joined(separator: ":")
        case let shadow as NSShadow:
            guard let color = stableLayoutDescriptor(shadow.shadowColor)
            else { return nil }
            return [
                "shadow",
                "\(shadow.shadowOffset.width)",
                "\(shadow.shadowOffset.height)",
                "\(shadow.shadowBlurRadius)",
                color,
            ].joined(separator: ":")
        case let number as NSNumber:
            return "number:\(number.stringValue)"
        case let value as NSString:
            return "string:\(value)"
        case let value as NSURL:
            return "url:\(value.absoluteString ?? "")"
        case let value as NSData:
            return "data:\((value as Data).base64EncodedString())"
        case let value?:
            return stableFoundationDescriptor(value)
        }
    }

    private static func stableFoundationDescriptor(_ value: Any) -> String? {
        switch value {
        case let value as String:
            return "string:\(value)"
        case let value as NSString:
            return "string:\(value)"
        case let value as NSNumber:
            return "number:\(value.stringValue)"
        case let value as URL:
            return "url:\(value.absoluteString)"
        case let value as NSURL:
            return "url:\(value.absoluteString ?? "")"
        case let value as Data:
            return "data:\(value.base64EncodedString())"
        case let values as [Any]:
            var descriptors: [String] = []
            descriptors.reserveCapacity(values.count)
            for value in values {
                guard let descriptor = stableFoundationDescriptor(value)
                else { return nil }
                descriptors.append(descriptor)
            }
            return "[\(descriptors.joined(separator: ","))]"
        case let values as NSDictionary:
            var descriptors: [String] = []
            for (key, value) in values {
                guard let keyDescriptor = stableFoundationDescriptor(key),
                      let valueDescriptor =
                        stableFoundationDescriptor(value)
                else { return nil }
                descriptors.append("\(keyDescriptor)=\(valueDescriptor)")
            }
            return "{\(descriptors.sorted().joined(separator: ","))}"
        default:
            // Never use `String(describing:)` for unknown objects here. Many
            // Cocoa descriptions embed a pointer, guaranteeing a permanent
            // miss and retaining one dead layout entry per pass.
            return nil
        }
    }
}

struct ChatSelectableFlowTextLayoutTraits: Hashable {
    let displayScaleBits: UInt64
    let dynamicTypeSize: String
    let layoutDirection: String
    let legibilityWeight: String
    let localeIdentifier: String
    let appearanceName: String
    let tracksAvailableWidth: Bool
    let lineFragmentPaddingBits: UInt64
    let insetWidthBits: UInt64
    let insetHeightBits: UInt64

    init(
        displayScale: CGFloat,
        dynamicTypeSize: String,
        layoutDirection: String,
        legibilityWeight: String,
        localeIdentifier: String,
        appearanceName: String,
        tracksAvailableWidth: Bool,
        lineFragmentPadding: CGFloat,
        inset: NSSize
    ) {
        displayScaleBits = Double(displayScale).bitPattern
        self.dynamicTypeSize = dynamicTypeSize
        self.layoutDirection = layoutDirection
        self.legibilityWeight = legibilityWeight
        self.localeIdentifier = localeIdentifier
        self.appearanceName = appearanceName
        self.tracksAvailableWidth = tracksAvailableWidth
        lineFragmentPaddingBits = Double(lineFragmentPadding).bitPattern
        insetWidthBits = Double(inset.width).bitPattern
        insetHeightBits = Double(inset.height).bitPattern
    }

    var displayScale: CGFloat {
        CGFloat(Double(bitPattern: displayScaleBits))
    }
}

struct ChatSelectableFlowTextLayoutKey: Hashable {
    let content: ChatSelectableFlowTextContentFingerprint
    let layoutWidthBits: UInt64
    let traits: ChatSelectableFlowTextLayoutTraits
    let semanticIdentity: UUID

    init(
        content: ChatSelectableFlowTextContentFingerprint,
        semanticIdentity: UUID,
        width: CGFloat,
        traits: ChatSelectableFlowTextLayoutTraits
    ) {
        self.content = content
        self.traits = traits
        self.semanticIdentity = semanticIdentity
        layoutWidthBits = Double(Self.canonicalLayoutWidth(
            width,
            displayScale: traits.displayScale)).bitPattern
    }

    var layoutWidth: CGFloat {
        CGFloat(Double(bitPattern: layoutWidthBits))
    }

    private static func canonicalLayoutWidth(
        _ width: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        let scale = displayScale.isFinite && displayScale > 0
            ? displayScale
            : 1
        return (width * scale).rounded(.toNearestOrAwayFromZero) / scale
    }
}

struct ChatSelectableFlowTextLayoutCacheMetrics: Equatable {
    var hits = 0
    var misses = 0
    var measurements = 0
    var evictions = 0
    var uncacheableBypasses = 0
    var entryCount = 0
}

/// TextKit layout results are deterministic for the keyed content/width/traits.
/// A bounded LRU avoids repeating CoreTypesetter work during nested SwiftUI
/// layout passes without retaining an unbounded transcript history.
final class ChatSelectableFlowTextLayoutCache: @unchecked Sendable {
    static let shared = ChatSelectableFlowTextLayoutCache()

    private struct Entry {
        let size: CGSize
    }

    let maximumEntryCount: Int

    private let lock = NSLock()
    private let entries =
        ChatTranscriptLRUStorage<ChatSelectableFlowTextLayoutKey, Entry>()
    private var counters = ChatSelectableFlowTextLayoutCacheMetrics()

    init(maximumEntryCount: Int = 512) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func resolve(
        key: ChatSelectableFlowTextLayoutKey,
        prepare: () -> Void = {},
        measure: () -> CGSize
    ) -> CGSize {
        // View-local state must be synchronized even when the measured size is
        // served by a cache entry created for another NSTextView.
        prepare()
        guard key.content.isCacheable else {
            let size = measure()
            lock.lock()
            counters.misses += 1
            counters.measurements += 1
            counters.uncacheableBypasses += 1
            counters.entryCount = entries.count
            lock.unlock()
            return size
        }
        lock.lock()
        if let entry = entries.value(forKey: key) {
            counters.hits += 1
            counters.entryCount = entries.count
            lock.unlock()
            return entry.size
        }
        counters.misses += 1
        lock.unlock()

        let size = measure()

        lock.lock()
        defer { lock.unlock() }
        counters.measurements += 1
        if let racedEntry = entries.value(forKey: key) {
            // One caller lookup is either a hit or a miss, never both.
            counters.entryCount = entries.count
            return racedEntry.size
        }
        entries.updateValue(Entry(size: size), forKey: key)
        while entries.count > maximumEntryCount {
            guard entries.removeLeastRecentlyUsed() != nil else { break }
            counters.evictions += 1
        }
        counters.entryCount = entries.count
        return size
    }

    func metricsSnapshot() -> ChatSelectableFlowTextLayoutCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        counters.entryCount = entries.count
        return counters
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        counters = ChatSelectableFlowTextLayoutCacheMetrics()
    }
}

/// Owns the process-wide pressure hook for transcript caches. A warning or
/// critical event drops only reproducible derived/layout values; message and
/// journal truth remain untouched. Session switches intentionally keep bounded
/// entries so returning to a long transcript does not guarantee remeasurement.
enum ChatTranscriptPerformanceCacheCoordinator {
    static let resetNotification = Notification.Name(
        "TatwoChatTranscriptPerformanceCachesDidReset")
    private static let boundaryLock = NSLock()
    private nonisolated(unsafe) static var boundaryGeneration: UInt64 = 0

    private static let memoryPressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility))
        source.setEventHandler {
            scheduleMemoryPressureReset()
        }
        source.activate()
        return source
    }()

    static func activateMemoryPressureMonitoring() {
        _ = memoryPressureSource
    }

    static func sessionBoundaryDidChange() {
        // Intentionally preserve bounded, content-keyed entries. Clearing here
        // made every thread/discussion switch guarantee a fresh text layout.
        boundaryLock.lock()
        boundaryGeneration &+= 1
        boundaryLock.unlock()
    }

    static var currentSessionBoundaryGeneration: UInt64 {
        boundaryLock.lock()
        defer { boundaryLock.unlock() }
        return boundaryGeneration
    }

    static func scheduleMemoryPressureReset() {
        Task { @MainActor in
            resetSharedCaches()
        }
    }

    @MainActor
    static func resetSharedCaches() {
        MainActor.preconditionIsolated()
        ChatMessageDerivedValueCache.shared.reset()
        ChatTranscriptFlowPayloadCache.shared.reset()
        ChatSelectableFlowTextLayoutCache.shared.reset()
        NotificationCenter.default.post(name: resetNotification, object: nil)
    }
}

struct ChatSelectableFlowText: NSViewRepresentable {
    let attributed: NSAttributedString
    var copyAllText: String = ""
    var tracksAvailableWidth = false
    private let contentFingerprint:
        ChatSelectableFlowTextContentFingerprint
    private let layoutSemanticIdentity: UUID
    // 2026-08-23 極光主題選取仍顯示橘色的根因：representable 不觀察主題，
    // updateNSView 不會因切主題重跑，選取色停在建立當下的主題。
    @ObservedObject private var themeStore = TatwoThemeStore.shared

    init(
        attributed: NSAttributedString,
        contentFingerprint: ChatSelectableFlowTextContentFingerprint? = nil,
        layoutSemanticIdentity: UUID,
        copyAllText: String = "",
        tracksAvailableWidth: Bool = false
    ) {
        self.attributed = attributed
        self.copyAllText = copyAllText
        self.tracksAvailableWidth = tracksAvailableWidth
        self.layoutSemanticIdentity = layoutSemanticIdentity
        self.contentFingerprint =
            contentFingerprint
            ?? ChatSelectableFlowTextContentFingerprint(attributed)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = ChatFlowTextView()
        textView.delegate = textView
        textView.copyAllText = copyAllText
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = tracksAvailableWidth
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: ChatFlowSelectionColor.current(),
        ]
        textView.textStorage?.setAttributedString(attributed)
        textView.renderedContentFingerprint = contentFingerprint
        textView.renderedAttributedObjectID = ObjectIdentifier(attributed)
        textView.synchronizeCodeBlockAccessories()
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        (textView as? ChatFlowTextView)?.copyAllText = copyAllText
        textView.textContainer?.widthTracksTextView = tracksAvailableWidth
        textView.selectedTextAttributes = [
            .backgroundColor: ChatFlowSelectionColor.current(),
        ]
        let flowTextView = textView as? ChatFlowTextView
        let attributedObjectID = ObjectIdentifier(attributed)
        if !contentFingerprint.isCacheable
            || flowTextView?.renderedContentFingerprint != contentFingerprint
            || flowTextView?.renderedAttributedObjectID != attributedObjectID
        {
            textView.textStorage?.setAttributedString(attributed)
            flowTextView?.renderedContentFingerprint = contentFingerprint
            flowTextView?.renderedAttributedObjectID = attributedObjectID
            flowTextView?.synchronizeCodeBlockAccessories()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }
        let width = proposal.width ?? ChatUILayout.chatColumnMaxWidth
        guard width.isFinite, width > 0 else { return nil }
        let traits = ChatSelectableFlowTextLayoutTraits(
            displayScale: context.environment.displayScale,
            dynamicTypeSize:
                String(describing: context.environment.dynamicTypeSize),
            layoutDirection:
                String(describing: context.environment.layoutDirection),
            legibilityWeight:
                String(describing: context.environment.legibilityWeight),
            localeIdentifier: context.environment.locale.identifier,
            appearanceName: textView.effectiveAppearance.name.rawValue,
            tracksAvailableWidth: tracksAvailableWidth,
            lineFragmentPadding: container.lineFragmentPadding,
            inset: textView.textContainerInset)
        let key = ChatSelectableFlowTextLayoutKey(
            content: contentFingerprint,
            semanticIdentity: layoutSemanticIdentity,
            width: width,
            traits: traits)
        let containerSize = NSSize(
            width: key.layoutWidth, height: .greatestFiniteMagnitude)
        let measured = ChatSelectableFlowTextLayoutCache.shared.resolve(
            key: key,
            prepare: {
                // Apply width on every pass, including cache hits. A hit can
                // originate from a different NSTextView with identical content.
                if container.size != containerSize {
                    container.size = containerSize
                }
            }
        ) {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            return CGSize(width: key.layoutWidth, height: ceil(used.height))
        }
        return CGSize(width: width, height: measured.height)
    }
}

/// Plaintext fallback used while a long assistant response is still changing.
/// Unlike the immutable structured renderer, this representable deliberately
/// keeps one NSTextStorage and incrementally appends newly arrived tokens.
struct ChatStreamingPlainTextFlowText: NSViewRepresentable {
    let text: String
    let sourceFingerprint: ChatStableContentFingerprint
    let sourceRevision: UUID
    let displayAppendBaseRevision: UUID?
    let displayAppendSuffix: String?
    let presentationIdentity: ChatTranscriptPresentationIdentity
    let structuredPayload: ChatTranscriptFlowComposer.Payload?
    var copyAllText: String = ""
    var tracksAvailableWidth = false

    func makeNSView(context: Context) -> NSTextView {
        let textView = ChatFlowTextView()
        textView.delegate = textView
        textView.copyAllText = copyAllText
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = tracksAvailableWidth
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: ChatFlowSelectionColor.current(),
        ]
        let controller = ChatStreamingPlainTextStorageController()
        textView.streamingPlainTextController = controller
        if let storage = textView.textStorage {
            applyPayload(
                controller: controller,
                textView: textView,
                storage: storage)
        }
        textView.synchronizeCodeBlockAccessories()
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard let flowTextView = textView as? ChatFlowTextView,
              let storage = textView.textStorage
        else { return }
        flowTextView.copyAllText = copyAllText
        textView.textContainer?.widthTracksTextView = tracksAvailableWidth
        textView.selectedTextAttributes = [
            .backgroundColor: ChatFlowSelectionColor.current(),
        ]
        let controller =
            flowTextView.streamingPlainTextController
            ?? ChatStreamingPlainTextStorageController()
        flowTextView.streamingPlainTextController = controller
        applyPayload(
            controller: controller,
            textView: textView,
            storage: storage)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let flowTextView = textView as? ChatFlowTextView,
              let controller =
                flowTextView.streamingPlainTextController,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }
        let width = proposal.width ?? ChatUILayout.chatColumnMaxWidth
        guard width.isFinite, width > 0 else { return nil }
        let traits = ChatSelectableFlowTextLayoutTraits(
            displayScale: context.environment.displayScale,
            dynamicTypeSize:
                String(describing: context.environment.dynamicTypeSize),
            layoutDirection:
                String(describing: context.environment.layoutDirection),
            legibilityWeight:
                String(describing: context.environment.legibilityWeight),
            localeIdentifier: context.environment.locale.identifier,
            appearanceName: textView.effectiveAppearance.name.rawValue,
            tracksAvailableWidth: tracksAvailableWidth,
            lineFragmentPadding: container.lineFragmentPadding,
            inset: textView.textContainerInset)
        return controller.measure(
            width: width,
            traits: traits,
            container: container,
            layoutManager: layoutManager)
    }

    private func applyPayload(
        controller: ChatStreamingPlainTextStorageController,
        textView: NSTextView,
        storage: NSTextStorage
    ) {
        if let structuredPayload {
            controller.applyStructured(
                sourceText: text,
                sourceFingerprint: sourceFingerprint,
                attributed: structuredPayload.attributed,
                contentFingerprint: structuredPayload.fingerprint,
                presentationIdentity: presentationIdentity,
                sourceRevision: sourceRevision,
                to: storage,
                preservingStateOf: textView)
        } else {
            controller.apply(
                text: text,
                fingerprint: sourceFingerprint,
                presentationIdentity: presentationIdentity,
                sourceRevision: sourceRevision,
                appendBaseRevision: displayAppendBaseRevision,
                appendedDisplaySuffix: displayAppendSuffix,
                to: storage,
                preservingStateOf: textView)
        }
    }
}
