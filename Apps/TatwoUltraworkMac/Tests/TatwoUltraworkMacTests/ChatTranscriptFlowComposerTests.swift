import XCTest
@testable import TatwoUltraworkMac
import TatwoUltraworkCore

// 2026-08-23 跨段選取工程的回歸鎖：文字流 block 必須合併成單一
// attributed string（NSTextView 才能跨段反白），code block 不得混入。
final class ChatTranscriptFlowComposerTests: XCTestCase {
    func testFlowKindClassification() {
        XCTAssertTrue(ChatTranscriptFlowComposer.isFlowKind(.paragraph))
        XCTAssertTrue(ChatTranscriptFlowComposer.isFlowKind(.heading(level: 2)))
        XCTAssertTrue(ChatTranscriptFlowComposer.isFlowKind(.unorderedListItem(depth: 0)))
        XCTAssertTrue(ChatTranscriptFlowComposer.isFlowKind(.orderedListItem(depth: 0, ordinal: 3)))
        XCTAssertFalse(ChatTranscriptFlowComposer.isFlowKind(.codeBlock(language: "swift")))
        XCTAssertFalse(ChatTranscriptFlowComposer.isFlowKind(.horizontalRule))
    }

    func testMultiParagraphDocumentMergesIntoSingleRun() {
        let document = TatwoAssistantTranscriptPresentation.document(
            markdown: "第一段文字\n\n第二段文字\n\n- 清單一\n- 清單二")
        let flowBlocks = document.blocks.filter {
            ChatTranscriptFlowComposer.isFlowKind($0.kind)
        }
        XCTAssertEqual(flowBlocks.count, document.blocks.count)

        let merged = ChatTranscriptFlowComposer.attributedText(
            blocks: flowBlocks, previousKind: nil)
        let text = merged.string
        XCTAssertTrue(text.contains("第一段文字"))
        XCTAssertTrue(text.contains("第二段文字"))
        XCTAssertTrue(text.contains("清單一"))
        XCTAssertTrue(text.contains("•"))
        // 段落間以 newline 相接（同一 storage 內＝可跨段反白）
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        // 尾端不掛多餘 newline
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    func testInlineBoldAndCodeSurviveConversion() {
        let document = TatwoAssistantTranscriptPresentation.document(
            markdown: "普通 **粗體** 與 `code` 內容")
        let merged = ChatTranscriptFlowComposer.attributedText(
            blocks: document.blocks, previousKind: nil)
        var sawBold = false
        var sawMono = false
        merged.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: merged.length)
        ) { value, _, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { sawBold = true }
            if traits.contains(.monoSpace) { sawMono = true }
        }
        XCTAssertTrue(sawBold)
        XCTAssertTrue(sawMono)
    }
}
