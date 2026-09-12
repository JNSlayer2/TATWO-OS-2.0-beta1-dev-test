// 照搬自 Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/ChatPageLeafViews+TranscriptFlow.swift；改動 4 行（原因：移除舊 Core import，改接同名 Facade 假資料）
import SwiftUI
import AppKit
import Foundation
import QuickLook

private enum ChatAssistantTranscriptMetrics {
    static let nestedListIndent: CGFloat = 22
    static let maximumVisibleListDepth = 4
    static let listMarkerMinimumWidth: CGFloat = 28

    static func headingFont(level: Int) -> Font {
        ChatTypography.systemUI(
            TatwoChatTranscriptVisualMetrics.headingPointSize(level: level),
            weight: level == 1 ? .bold : .semibold)
    }

    static func topPadding(
        for kind: TatwoAssistantTranscriptBlockKind,
        previousKind: TatwoAssistantTranscriptBlockKind?,
        isFirst: Bool
    ) -> CGFloat {
        guard !isFirst else { return 0 }
        switch kind {
        case .heading(let level):
            switch level {
            case 1: return 12
            case 2: return 10
            default: return 8
            }
        case .paragraph, .fallback:
            return previousKind?.listDepth == nil ? 4 : 7
        case .codeBlock:
            return 7
        case .table:
            return 8
        case .blockquote:
            return 6
        case .horizontalRule:
            return 8
        case .unorderedListItem(let depth), .orderedListItem(let depth, _):
            guard let previousDepth = previousKind?.listDepth else { return 7 }
            return depth > previousDepth ? 3 : 2
        }
    }

    static func bottomPadding(
        for kind: TatwoAssistantTranscriptBlockKind,
        isLast: Bool
    ) -> CGFloat {
        guard !isLast else { return 0 }
        switch kind {
        case .heading:
            return 3
        case .paragraph, .fallback:
            return 2
        case .codeBlock:
            return 4
        case .table:
            return 5
        case .blockquote:
            return 3
        case .horizontalRule:
            return 8
        case .unorderedListItem, .orderedListItem:
            return 1
        }
    }
}

// 2026-08-23 使用者回報「全選反白遇到分段會選不了」：SwiftUI 每個段落是
// 獨立 Text，選取跨不過 view 邊界。所有 transcript block 都合併到同一
// NSTextView（原生跨段選取＋Cmd+C），視覺語義由 attributed paragraph
// attributes 表達，避免 code/table/blockquote/hr 讓 SwiftUI 換樹重量。
struct ChatTranscriptRenderIdentity: Hashable {
    let messageID: String
    let sourceText: String
    let textFingerprint: ChatStableContentFingerprint

    static func == (
        lhs: ChatTranscriptRenderIdentity,
        rhs: ChatTranscriptRenderIdentity
    ) -> Bool {
        lhs.messageID == rhs.messageID
            && lhs.textFingerprint == rhs.textFingerprint
            && lhs.sourceText == rhs.sourceText
    }

    func hash(into hasher: inout Hasher) {
        // Do not traverse a long transcript during every SwiftUI lookup.
        // Exact source comparison is the collision guard.
        hasher.combine(messageID)
        hasher.combine(textFingerprint)
    }

    var estimatedResidentBytes: Int {
        messageID.utf8.count
            + textFingerprint.utf8Count
            + 96
    }

    /// Static transcript surfaces (for example the Plan inspector) do not
    /// carry a message ID, but they still provide the complete source text.
    /// Give those surfaces a stable content identity so repeated SwiftUI body
    /// passes reuse the exact attributed payload and its layout measurements.
    static func staticTranscript(_ source: String) -> Self? {
        guard !source.isEmpty else { return nil }
        return Self(
            messageID: "static-transcript",
            sourceText: source,
            textFingerprint: ChatStableContentFingerprint(source))
    }
}

struct ChatAssistantTranscriptBlockView: View {
    let document: TatwoAssistantTranscriptDocument
    var renderIdentity: ChatTranscriptRenderIdentity?
    var copyAllText: String = ""
    var tracksAvailableWidth = false

    private struct Segment: Identifiable {
        enum Payload {
            case flow([TatwoAssistantTranscriptBlock])
            case card(TatwoAssistantTranscriptBlock)
        }

        let id: TatwoAssistantTranscriptBlockID
        let payload: Payload
        let previousKind: TatwoAssistantTranscriptBlockKind?
        let isFirst: Bool
        let isLast: Bool
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var flowBuffer: [TatwoAssistantTranscriptBlock] = []
        var previousKind: TatwoAssistantTranscriptBlockKind?

        func flushFlow() {
            guard let first = flowBuffer.first else { return }
            result.append(Segment(
                id: first.id,
                payload: .flow(flowBuffer),
                previousKind: previousKind,
                isFirst: false,
                isLast: false))
            previousKind = flowBuffer.last?.kind
            flowBuffer = []
        }

        for block in document.blocks {
            if ChatTranscriptFlowComposer.isFlowKind(block.kind) {
                flowBuffer.append(block)
            } else {
                flushFlow()
                result.append(Segment(
                    id: block.id,
                    payload: .card(block),
                    previousKind: previousKind,
                    isFirst: false,
                    isLast: false))
                previousKind = block.kind
            }
        }
        flushFlow()

        return result.enumerated().map { index, segment in
            Segment(
                id: segment.id,
                payload: segment.payload,
                previousKind: segment.previousKind,
                isFirst: index == 0,
                isLast: index == result.count - 1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(segments) { segment in
                switch segment.payload {
                case .flow(let blocks):
                    if !blocks.isEmpty {
                        flowSegment(blocks, segment: segment)
                    }
                case .card(let block):
                    ChatAssistantTranscriptBlockRow(
                        block: block,
                        previousKind: segment.previousKind,
                        isFirst: segment.isFirst,
                        isLast: segment.isLast)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keep imperative payload selection outside the ViewBuilder expression.
    /// SwiftUI's builder accepts the returned view, while this ordinary function
    /// can safely choose the cached or correctness-first payload first.
    private func flowSegment(
        _ blocks: [TatwoAssistantTranscriptBlock],
        segment: Segment
    ) -> some View {
        let first = blocks[0]
        let last = blocks[blocks.count - 1]
        let payload: ChatTranscriptFlowComposer.Payload
        if let renderIdentity =
            renderIdentity
                ?? ChatTranscriptRenderIdentity.staticTranscript(copyAllText)
        {
            payload = ChatTranscriptFlowComposer.cachedAttributedPayload(
                blocks: blocks,
                previousKind: segment.previousKind,
                renderIdentity: renderIdentity,
                segmentFirstID: first.id,
                segmentLastID: last.id)
        } else {
            // Legacy/static call sites without a stable message fingerprint stay
            // correctness-first and do not retain an attributed payload.
            payload = ChatTranscriptFlowComposer.attributedPayload(
                blocks: blocks,
                previousKind: segment.previousKind)
        }
        return ChatSelectableFlowText(
            attributed: payload.attributed,
            contentFingerprint: payload.fingerprint,
            layoutSemanticIdentity: payload.layoutSemanticIdentity,
            copyAllText: copyAllText,
            tracksAvailableWidth: tracksAvailableWidth)
            .padding(.top, ChatAssistantTranscriptMetrics.topPadding(
                for: first.kind,
                previousKind: segment.previousKind,
                isFirst: segment.isFirst))
            .padding(.bottom, ChatAssistantTranscriptMetrics.bottomPadding(
                for: last.kind,
                isLast: segment.isLast))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NSAttributedString.Key {
    static let chatTranscriptCodeContent =
        NSAttributedString.Key("tatwo.chat.code.content")
    static let chatTranscriptCodeLanguage =
        NSAttributedString.Key("tatwo.chat.code.language")
    static let chatTranscriptTableColumnCount =
        NSAttributedString.Key("tatwo.chat.table.column-count")
    static let chatTranscriptBlockSemantic =
        NSAttributedString.Key("tatwo.chat.block.semantic")
}

enum ChatTranscriptFlowComposer {
    final class Payload {
        let attributed: NSAttributedString
        let fingerprint: ChatSelectableFlowTextContentFingerprint
        /// Exact identity of this semantic attributed payload. Cached redraws
        /// reuse it; independently reconstructed payloads receive a new token,
        /// so a fingerprint collision cannot return another payload's height.
        let layoutSemanticIdentity: UUID

        init(
            attributed: NSAttributedString,
            fingerprint: ChatSelectableFlowTextContentFingerprint
        ) {
            self.attributed = attributed
            self.fingerprint = fingerprint
            self.layoutSemanticIdentity = UUID()
        }

        var estimatedResidentBytes: Int {
            max(512, attributed.length * 6 + 512)
        }
    }

    static func isFlowKind(_ kind: TatwoAssistantTranscriptBlockKind) -> Bool {
        switch kind {
        case .heading, .paragraph, .fallback, .unorderedListItem,
             .orderedListItem:
            return true
        case .codeBlock, .table, .blockquote, .horizontalRule:
            return false
        }
    }

    static func attributedText(
        blocks: [TatwoAssistantTranscriptBlock],
        previousKind: TatwoAssistantTranscriptBlockKind?
    ) -> NSAttributedString {
        attributedPayload(
            blocks: blocks,
            previousKind: previousKind
        ).attributed
    }

    static func attributedPayload(
        blocks: [TatwoAssistantTranscriptBlock],
        previousKind: TatwoAssistantTranscriptBlockKind?
    ) -> Payload {
        let result = NSMutableAttributedString()
        var priorKind = previousKind
        var layoutDescriptors = [
            "flow-layout-v2-tabular-digits",
            "previous=\(String(describing: previousKind))",
        ]
        var semanticRunCount = 0
        for (index, block) in blocks.enumerated() {
            result.append(paragraph(
                for: block,
                previousKind: priorKind,
                isFirstInSegment: index == 0,
                isLastInSegment: index == blocks.count - 1,
                appendNewline: index < blocks.count - 1))
            layoutDescriptors.append(
                "block=\(String(describing: block.kind))")
            for run in block.content.runs {
                semanticRunCount += 1
                layoutDescriptors.append(
                    "run=\(block.content[run.range].characters.count)"
                        + ":\(String(describing: run.inlinePresentationIntent))"
                        + ":\(run.link?.absoluteString ?? "")")
            }
            priorKind = block.kind
        }
        return Payload(
            attributed: result,
            fingerprint: ChatSelectableFlowTextContentFingerprint(
                text: result.string,
                semanticLayoutDescriptor:
                    layoutDescriptors.joined(separator: "|"),
                attributedLength: result.length,
                attributeRunCount: semanticRunCount))
    }

    static func cachedAttributedPayload(
        blocks: [TatwoAssistantTranscriptBlock],
        previousKind: TatwoAssistantTranscriptBlockKind?,
        renderIdentity: ChatTranscriptRenderIdentity,
        segmentFirstID: TatwoAssistantTranscriptBlockID,
        segmentLastID: TatwoAssistantTranscriptBlockID
    ) -> Payload {
        ChatTranscriptFlowPayloadCache.shared.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: renderIdentity,
                variant: .flow(
                    firstID: segmentFirstID,
                    lastID: segmentLastID,
                    blockCount: blocks.count))
        ) {
            attributedPayload(
                blocks: blocks,
                previousKind: previousKind)
        }
    }

    static func cachedSingleFlowPayload(
        document: TatwoAssistantTranscriptDocument,
        renderIdentity: ChatTranscriptRenderIdentity
    ) -> Payload? {
        guard let first = document.blocks.first,
              let last = document.blocks.last,
              document.blocks.allSatisfy({
                  isFlowKind($0.kind)
              })
        else { return nil }
        return cachedAttributedPayload(
            blocks: document.blocks,
            previousKind: nil,
            renderIdentity: renderIdentity,
            segmentFirstID: first.id,
            segmentLastID: last.id)
    }

    static func cachedDocumentPayload(
        document: TatwoAssistantTranscriptDocument,
        renderIdentity: ChatTranscriptRenderIdentity
    ) -> Payload? {
        guard let first = document.blocks.first,
              let last = document.blocks.last
        else { return nil }
        return ChatTranscriptFlowPayloadCache.shared.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: renderIdentity,
                variant: .document(
                    firstID: first.id,
                    lastID: last.id,
                    blockCount: document.blocks.count))
        ) {
            attributedPayload(
                blocks: document.blocks,
                previousKind: nil)
        }
    }

    private static func paragraph(
        for block: TatwoAssistantTranscriptBlock,
        previousKind: TatwoAssistantTranscriptBlockKind?,
        isFirstInSegment: Bool,
        isLastInSegment: Bool,
        appendNewline: Bool
    ) -> NSAttributedString {
        let baseFont = baseFont(for: block.kind)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TatwoChatTranscriptVisualMetrics.transcriptLineSpacing
        style.lineBreakMode = .byWordWrapping
        // 段間距沿用原本 SwiftUI padding 規則：上一段 bottomPadding＋
        // 下一段 topPadding（TextKit 的 spacing / spacingBefore 相加，語義一致）。
        // segment 頭尾的 padding 改由外層 SwiftUI padding 提供。
        style.paragraphSpacingBefore = isFirstInSegment
            ? 0
            : ChatAssistantTranscriptMetrics.topPadding(
                for: block.kind, previousKind: previousKind, isFirst: false)
        style.paragraphSpacing = isLastInSegment
            ? 0
            : ChatAssistantTranscriptMetrics.bottomPadding(for: block.kind, isLast: false)

        let body = NSMutableAttributedString()
        switch block.kind {
        case .codeBlock(let language):
            style.lineBreakMode = .byClipping
            style.firstLineHeadIndent = 10
            style.headIndent = 10
            style.tailIndent = -10
            style.textBlocks = [
                transcriptTextBlock(
                    // 圓角淡底改由 ChatFlowTextView 畫（NSTextBlock 只能畫方框）。
                    background: .clear,
                    border: .clear,
                    padding: 12)
            ]
            if let language,
               !language.trimmingCharacters(
                    in: .whitespacesAndNewlines
               ).isEmpty
            {
                body.append(NSAttributedString(
                    string: language + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
            }
            body.append(inlineRuns(block.content, baseFont: baseFont))
            let codeRange = NSRange(location: 0, length: body.length)
            body.addAttributes(
                [
                    .chatTranscriptCodeContent:
                        block.plainText as NSString,
                    .chatTranscriptCodeLanguage:
                        (language ?? "") as NSString,
                    .chatTranscriptBlockSemantic: "code" as NSString,
                ],
                range: codeRange)
        case .table(let table):
            configureTableTabs(table, style: style)
            appendTable(table, to: body)
            body.addAttributes(
                [
                    .chatTranscriptTableColumnCount:
                        NSNumber(value: max(
                            table.header.count,
                            table.rows.map(\.count).max() ?? 0)),
                    .chatTranscriptBlockSemantic: "table" as NSString,
                ],
                range: NSRange(location: 0, length: body.length))
        case .blockquote:
            style.firstLineHeadIndent = 14
            style.headIndent = 14
            style.textBlocks = [
                transcriptTextBlock(
                    background:
                        NSColor.controlBackgroundColor.withAlphaComponent(0.16),
                    border: NSColor.systemBlue.withAlphaComponent(0.48),
                    padding: 8)
            ]
            body.append(inlineRuns(block.content, baseFont: baseFont))
            body.addAttributes(
                [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .chatTranscriptBlockSemantic: "blockquote" as NSString,
                ],
                range: NSRange(location: 0, length: body.length))
        case .horizontalRule:
            style.textBlocks = [
                transcriptTextBlock(
                    background: NSColor.clear,
                    border: NSColor.separatorColor.withAlphaComponent(0.72),
                    padding: 0)
            ]
            body.append(NSAttributedString(
                string: "\u{200B}",
                attributes: [
                    .font: baseFont,
                    .foregroundColor:
                        NSColor.separatorColor.withAlphaComponent(0.82),
                    .chatTranscriptBlockSemantic: "horizontal-rule" as NSString,
                ]))
        case .heading, .paragraph, .fallback, .unorderedListItem,
             .orderedListItem:
            if let listDepth = block.kind.listDepth {
                let indent = CGFloat(min(
                    listDepth,
                    ChatAssistantTranscriptMetrics.maximumVisibleListDepth))
                    * ChatAssistantTranscriptMetrics.nestedListIndent
                let markerColumn =
                    indent
                    + ChatAssistantTranscriptMetrics.listMarkerMinimumWidth
                let contentStart = markerColumn + 8
                style.tabStops = [
                    NSTextTab(
                        textAlignment: .right,
                        location: markerColumn),
                    NSTextTab(
                        textAlignment: .left,
                        location: contentStart),
                ]
                style.firstLineHeadIndent = 0
                style.headIndent = contentStart
                let marker: String
                switch block.kind {
                case .orderedListItem(_, let ordinal):
                    marker = "\(ordinal)."
                default:
                    marker = listDepth == 0 ? "•" : "◦"
                }
                body.append(NSAttributedString(
                    string: "\t\(marker)\t",
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize:
                                TatwoChatTranscriptVisualMetrics
                                    .transcriptPointSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
            }
            body.append(inlineRuns(block.content, baseFont: baseFont))
        }
        if appendNewline {
            body.append(NSAttributedString(
                string: "\n",
                attributes: [.font: baseFont]))
        }
        body.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: body.length))
        return body
    }

    private static func transcriptTextBlock(
        background: NSColor,
        border: NSColor,
        padding: CGFloat
    ) -> NSTextBlock {
        let block = NSTextBlock()
        block.setContentWidth(100, type: .percentageValueType)
        block.setWidth(
            padding,
            type: .absoluteValueType,
            for: .padding)
        block.setWidth(
            1,
            type: .absoluteValueType,
            for: .border)
        block.backgroundColor = background
        block.setBorderColor(border)
        return block
    }

    private static func configureTableTabs(
        _ table: TatwoAssistantTranscriptTable,
        style: NSMutableParagraphStyle
    ) {
        let columnCount = max(
            table.header.count,
            table.rows.map(\.count).max() ?? 0)
        let columnWidth = max(
            96,
            ChatUILayout.chatColumnMaxWidth
                / CGFloat(max(1, columnCount)))
        style.defaultTabInterval = columnWidth
        style.tabStops = (1..<max(1, columnCount)).map { index in
            let alignment =
                table.alignments.indices.contains(index)
                ? table.alignments[index]
                : .leading
            return NSTextTab(
                textAlignment: textAlignment(alignment),
                location: CGFloat(index) * columnWidth)
        }
    }

    private static func appendTable(
        _ table: TatwoAssistantTranscriptTable,
        to result: NSMutableAttributedString
    ) {
        let rows = [table.header] + table.rows
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                if columnIndex > 0 {
                    result.append(NSAttributedString(string: "\t"))
                }
                let font =
                    rowIndex == 0
                    ? NSFont.systemFont(
                        ofSize:
                            TatwoChatTranscriptVisualMetrics
                                .tableHeaderPointSize,
                        weight: .semibold)
                    : NSFont.systemFont(
                        ofSize:
                            TatwoChatTranscriptVisualMetrics
                                .transcriptPointSize)
                result.append(inlineRuns(cell, baseFont: font))
            }
            if rowIndex < rows.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
    }

    private static func textAlignment(
        _ alignment: TatwoAssistantTranscriptTableAlignment
    ) -> NSTextAlignment {
        switch alignment {
        case .center:
            return .center
        case .trailing:
            return .right
        case .unspecified, .leading:
            return .left
        }
    }

    private static func baseFont(
        for kind: TatwoAssistantTranscriptBlockKind
    ) -> NSFont {
        switch kind {
        case .heading(let level):
            return NSFont.systemFont(
                ofSize: TatwoChatTranscriptVisualMetrics.headingPointSize(level: level),
                weight: level == 1 ? .bold : .semibold)
        case .codeBlock:
            return NSFont.monospacedSystemFont(
                ofSize: TatwoChatTranscriptVisualMetrics.codePointSize,
                weight: .regular)
        case .paragraph, .fallback, .unorderedListItem, .orderedListItem,
             .table, .blockquote, .horizontalRule:
            return NSFont.monospacedDigitSystemFont(
                ofSize: TatwoChatTranscriptVisualMetrics.transcriptPointSize,
                weight: .regular)
        }
    }

    static func plainAttributedText(_ text: String) -> NSAttributedString {
        plainPayload(text).attributed
    }

    static func plainPayload(_ text: String) -> Payload {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = TatwoChatTranscriptVisualMetrics.transcriptLineSpacing
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: TatwoChatTranscriptVisualMetrics.transcriptPointSize,
                    weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ])
        return Payload(
            attributed: attributed,
            fingerprint: ChatSelectableFlowTextContentFingerprint(
                text: text,
                semanticLayoutDescriptor:
                    "plain-layout-v2-tabular-digits"
                    + ":\(TatwoChatTranscriptVisualMetrics.transcriptPointSize)"
                    + ":\(TatwoChatTranscriptVisualMetrics.transcriptLineSpacing)"
                    + ":\(style.lineBreakMode.rawValue)",
                attributedLength: attributed.length,
                attributeRunCount: attributed.length == 0 ? 0 : 1))
    }

    static func cachedPlainPayload(
        _ text: String,
        renderIdentity: ChatTranscriptRenderIdentity
    ) -> Payload {
        ChatTranscriptFlowPayloadCache.shared.resolve(
            key: ChatTranscriptFlowPayloadCacheKey(
                renderIdentity: renderIdentity,
                variant: .plain)
        ) {
            plainPayload(text)
        }
    }

    private static func inlineRuns(
        _ content: AttributedString,
        baseFont: NSFont
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in content.runs {
            let text = String(content.characters[run.range])
            var font = baseFont
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(
                    ofSize: baseFont.pointSize, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}

struct ChatTranscriptFlowPayloadCacheKey: Hashable {
    enum Variant: Hashable {
        case plain
        case flow(
            firstID: TatwoAssistantTranscriptBlockID,
            lastID: TatwoAssistantTranscriptBlockID,
            blockCount: Int)
        case document(
            firstID: TatwoAssistantTranscriptBlockID,
            lastID: TatwoAssistantTranscriptBlockID,
            blockCount: Int)
    }

    let renderIdentity: ChatTranscriptRenderIdentity
    let variant: Variant
    let parserVersion: Int

    init(
        renderIdentity: ChatTranscriptRenderIdentity,
        variant: Variant,
        parserVersion: Int =
            TatwoAssistantTranscriptCache.defaultParserVersion
    ) {
        self.renderIdentity = renderIdentity
        self.variant = variant
        self.parserVersion = parserVersion
    }

    var estimatedResidentBytes: Int {
        renderIdentity.estimatedResidentBytes + 128
    }
}

struct ChatTranscriptFlowPayloadCacheMetrics: Equatable {
    var hits = 0
    var misses = 0
    var computations = 0
    var evictions = 0
    var oversizedBypasses = 0
    var entryCount = 0
    var residentBytes = 0
}

/// Reuses the exact immutable attributed-string object across repeated SwiftUI
/// body evaluations. Lookup hashing uses fixed-size fingerprints; exact source
/// text remains in equality as a collision guard and is included in the byte
/// bound, so a hit never rebuilds the attributed payload.
final class ChatTranscriptFlowPayloadCache: @unchecked Sendable {
    static let shared = ChatTranscriptFlowPayloadCache()

    private struct Entry {
        let payload: ChatTranscriptFlowComposer.Payload
        let residentBytes: Int
    }

    let maximumEntryCount: Int
    let maximumResidentBytes: Int

    private let lock = NSLock()
    private let entries =
        ChatTranscriptLRUStorage<ChatTranscriptFlowPayloadCacheKey, Entry>()
    private var residentByteCount = 0
    private var counters = ChatTranscriptFlowPayloadCacheMetrics()

    init(
        maximumEntryCount: Int = 512,
        maximumResidentBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.maximumResidentBytes = max(1, maximumResidentBytes)
    }

    func resolve(
        key: ChatTranscriptFlowPayloadCacheKey,
        build: () -> ChatTranscriptFlowComposer.Payload
    ) -> ChatTranscriptFlowComposer.Payload {
        lock.lock()
        if let entry = entries.value(forKey: key) {
            counters.hits += 1
            updateFootprintMetrics()
            lock.unlock()
            return entry.payload
        }
        counters.misses += 1
        lock.unlock()

        let payload = build()
        let bytes =
            key.estimatedResidentBytes
            + payload.estimatedResidentBytes

        lock.lock()
        defer { lock.unlock() }
        counters.computations += 1
        if let racedEntry = entries.value(forKey: key) {
            // The original lookup was a miss; do not report a second logical
            // hit merely because another thread inserted while this one built.
            updateFootprintMetrics()
            return racedEntry.payload
        }
        guard bytes <= maximumResidentBytes else {
            counters.oversizedBypasses += 1
            updateFootprintMetrics()
            return payload
        }
        let inserted = Entry(payload: payload, residentBytes: bytes)
        if let replaced = entries.updateValue(inserted, forKey: key) {
            residentByteCount -= replaced.residentBytes
        }
        residentByteCount += inserted.residentBytes
        evictIfNeeded()
        updateFootprintMetrics()
        return payload
    }

    func metricsSnapshot() -> ChatTranscriptFlowPayloadCacheMetrics {
        lock.lock()
        defer { lock.unlock() }
        updateFootprintMetrics()
        return counters
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        residentByteCount = 0
        counters = ChatTranscriptFlowPayloadCacheMetrics()
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount
            || residentByteCount > maximumResidentBytes
        {
            guard let removed = entries.removeLeastRecentlyUsed()
            else { break }
            residentByteCount -= removed.value.residentBytes
            counters.evictions += 1
        }
    }

    private func updateFootprintMetrics() {
        counters.entryCount = entries.count
        counters.residentBytes = residentByteCount
    }
}

private struct ChatAssistantTranscriptBlockRow: View {
    let block: TatwoAssistantTranscriptBlock
    let previousKind: TatwoAssistantTranscriptBlockKind?
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        Group {
            switch block.kind.renderKind {
            case .heading(let level):
                Text(block.content)
                    .font(ChatAssistantTranscriptMetrics.headingFont(level: level))
                    .lineSpacing(ChatUILayout.transcriptLineSpacing)
            case .paragraph, .fallback:
                Text(block.content)
                    .font(ChatTypography.transcriptAssistant)
                    .lineSpacing(ChatUILayout.transcriptLineSpacing)
            case .codeBlock(let language):
                ChatAssistantTranscriptCodeBlock(
                    content: block.content,
                    plainText: block.plainText,
                    language: language)
            case .unorderedListItem(let depth):
                listRow(marker: depth == 0 ? "•" : "◦", depth: depth)
            case .orderedListItem(let depth, let ordinal):
                listRow(marker: "\(ordinal).", depth: depth)
            case .table(let table):
                tableView(table)
            case .blockquote:
                blockquoteView
            case .horizontalRule:
                Divider()
                    .overlay(Color.secondary.opacity(0.22))
            }
        }
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(ChatTypography.transcriptAssistant)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(
                    minWidth: ChatAssistantTranscriptMetrics.listMarkerMinimumWidth,
                    alignment: .trailing)
            Text(block.content)
                .font(ChatTypography.transcriptAssistant)
                .lineSpacing(ChatUILayout.transcriptLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(
            .leading,
            CGFloat(min(depth, ChatAssistantTranscriptMetrics.maximumVisibleListDepth))
                * ChatAssistantTranscriptMetrics.nestedListIndent)
    }

    private func tableView(
        _ table: TatwoAssistantTranscriptTable
    ) -> some View {
        VStack(spacing: 0) {
            tableRow(
                table.header,
                table: table,
                isHeader: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { entry in
                Divider()
                    .overlay(Color.secondary.opacity(0.16))
                tableRow(
                    entry.element,
                    table: table,
                    isHeader: false)
            }
        }
        .background(
            Color.white.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private func tableRow(
        _ cells: [AttributedString],
        table: TatwoAssistantTranscriptTable,
        isHeader: Bool
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { entry in
                if entry.offset > 0 {
                    Divider()
                        .overlay(Color.secondary.opacity(0.14))
                }
                Text(entry.element)
                    .font(
                        isHeader
                            ? ChatTypography.systemUI(
                                TatwoChatTranscriptVisualMetrics.tableHeaderPointSize,
                                weight: .semibold)
                            : ChatTypography.transcriptAssistant)
                    .lineSpacing(ChatUILayout.transcriptLineSpacing)
                    .frame(
                        maxWidth: .infinity,
                        alignment: tableCellAlignment(
                            table.alignments.indices.contains(entry.offset)
                                ? table.alignments[entry.offset]
                                : .unspecified))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
        }
    }

    private func tableCellAlignment(
        _ alignment: TatwoAssistantTranscriptTableAlignment
    ) -> Alignment {
        switch alignment {
        case .center:
            .center
        case .trailing:
            .trailing
        case .unspecified, .leading:
            .leading
        }
    }

    private var blockquoteView: some View {
        Text(block.content)
            .font(ChatTypography.transcriptAssistant)
            .foregroundStyle(.secondary)
            .lineSpacing(ChatUILayout.transcriptLineSpacing)
            .padding(.leading, 14)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.42))
                    .frame(width: 3)
            }
    }

    private var topPadding: CGFloat {
        ChatAssistantTranscriptMetrics.topPadding(
            for: block.kind, previousKind: previousKind, isFirst: isFirst)
    }

    private var bottomPadding: CGFloat {
        ChatAssistantTranscriptMetrics.bottomPadding(
            for: block.kind, isLast: isLast)
    }
}

private struct ChatAssistantTranscriptCodeBlock: View {
    let content: AttributedString
    let plainText: String
    let language: String?

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(.system(
                    size: TatwoChatTranscriptVisualMetrics.codePointSize,
                    weight: .regular,
                    design: .monospaced))
                .lineSpacing(ChatUILayout.transcriptLineSpacing)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .padding(.top, 34)
                .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.black.opacity(0.20),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            if let language,
               !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(language)
                    .font(ChatTypography.transcriptMeta)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 12)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plainText, forType: .string)
                    didCopy = true
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .background(
                    Color.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(didCopy ? "已複製" : "複製程式碼")
                .accessibilityLabel(didCopy ? "程式碼已複製" : "複製程式碼")
                .padding(.trailing, 7)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
                if !hovering {
                    didCopy = false
                }
            }
        }
    }
}
