import Foundation
import XCTest
import TatwoUltraworkCore

@testable import TatwoUltraworkMac

final class ChatSentAttachmentPreviewTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDisplayTurnStoresImageMarkerAndParserRestoresOriginalAttachment() throws {
        let path = "/tmp/TATWO image & proof.png"

        let displayTurn = ChatAttachmentTranscript.displayTurn(
            text: "請讀圖",
            attachmentPaths: [path])
        let attachments = ChatAttachmentTranscript.attachments(in: displayTurn)

        XCTAssertTrue(displayTurn.contains("<image "))
        XCTAssertTrue(displayTurn.contains("name=[TATWO image &amp; proof.png]"))
        XCTAssertTrue(displayTurn.contains(#"path="/tmp/TATWO image &amp; proof.png""#))
        XCTAssertEqual(
            attachments,
            [ChatAttachmentTranscript.Attachment(path: path, name: "TATWO image & proof.png")])
    }

    func testDisplayTurnDoesNotAddDuplicateMarkerForSamePath() {
        let path = "/tmp/proof.png"

        let displayTurn = ChatAttachmentTranscript.displayTurn(
            text: "請讀圖",
            attachmentPaths: [path, path])

        XCTAssertEqual(
            ChatAttachmentTranscript.attachments(in: displayTurn),
            [ChatAttachmentTranscript.Attachment(path: path, name: "proof.png")])
    }

    func testStoredImageUsesRelativeAssetMarkerAndKeepsHumanDisplayName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-chat-marker-\(UUID().uuidString)", isDirectory: true)
        let store = TatwoImageAssetStore(rootURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let asset = try store.ingest(
            data: Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
            suggestedName: "原始截圖.png")

        let displayTurn = ChatAttachmentTranscript.displayTurn(
            text: "請讀圖",
            attachmentPaths: [asset.url.path],
            attachmentDisplayNames: [asset.url.path: "原始截圖.png"],
            imageStore: store)
        let attachments = ChatAttachmentTranscript.attachments(
            in: displayTurn,
            imageStore: store)

        XCTAssertTrue(displayTurn.contains(#"asset="\#(asset.relativePath)""#))
        XCTAssertFalse(displayTurn.contains(asset.url.path))
        XCTAssertEqual(
            attachments,
            [ChatAttachmentTranscript.Attachment(path: asset.url.path, name: "原始截圖.png")])
    }

    func testLegacyAbsoluteImageMarkerMigratesIntoPersistentAssetStore() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-chat-legacy-\(UUID().uuidString)", isDirectory: true)
        let source = fixture.appendingPathComponent("legacy.png")
        let store = TatwoImageAssetStore(
            rootURL: fixture.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            .write(to: source)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let legacy = #"<image name=[舊圖片.png] path="\#(source.path)">"#
        let migrated = ChatAttachmentTranscript.migratingLegacyImageMarkers(
            in: legacy,
            imageStore: store)
        try FileManager.default.removeItem(at: source)
        let attachment = try XCTUnwrap(
            ChatAttachmentTranscript.attachments(in: migrated, imageStore: store).first)

        XCTAssertTrue(migrated.contains(#"asset=""#))
        XCTAssertFalse(migrated.contains(source.path))
        XCTAssertEqual(attachment.name, "舊圖片.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.path))
    }

    func testImageDispatchSelectionPrioritizesCurrentAndReportsMissingAndTruncation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tatwo-chat-dispatch-\(UUID().uuidString)", isDirectory: true)
        let store = TatwoImageAssetStore(rootURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var historicalTurns: [String] = []
        var historicalPaths: [String] = []
        for index in 0..<9 {
            let data = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
                + Data([UInt8(index)])
            let asset = try store.ingest(data: data, suggestedName: "\(index).png")
            historicalPaths.append(asset.url.path)
            historicalTurns.append(
                ChatAttachmentTranscript.displayTurn(
                    text: "turn \(index)",
                    attachmentPaths: [asset.url.path],
                    imageStore: store))
        }
        let missingAsset = "missing.png"
        historicalTurns.append(#"<image name=[missing.png] asset="\#(missingAsset)">"#)

        let selection = ChatImageDispatchSelector.select(
            currentPaths: [historicalPaths[0]],
            transcriptTexts: historicalTurns,
            imageStore: store,
            limit: 8)

        XCTAssertEqual(selection.paths.first, historicalPaths[0])
        XCTAssertEqual(selection.paths.count, 8)
        XCTAssertEqual(selection.missingNames, ["missing.png"])
        XCTAssertEqual(selection.omittedCount, 1)
    }

    func testHistoricalImagesAreOnlyBridgedForExplicitImageRecall() {
        XCTAssertFalse(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "Plan 模式健檢：不要執行，只回答目前模式",
            interactionMode: .plan,
            targetRuntimeAdapter: .claudeCLI,
            targetHasResumableSession: true))
        XCTAssertFalse(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "繼續整理剛才的規劃",
            interactionMode: .standard,
            targetRuntimeAdapter: .gatewayDirect,
            targetHasResumableSession: false))
        XCTAssertTrue(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "上一張貼上的圖片中央寫什麼？",
            interactionMode: .standard,
            targetRuntimeAdapter: .gatewayDirect,
            targetHasResumableSession: false))
        XCTAssertTrue(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "請讀取上一則訊息的附件圖片，只回圖片中央最大的驗收字串。",
            interactionMode: .standard,
            targetRuntimeAdapter: .gatewayDirect,
            targetHasResumableSession: false))
        XCTAssertTrue(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "請讀取本 thread 第一則訊息的附件圖片。",
            interactionMode: .standard,
            targetRuntimeAdapter: .codexExec,
            targetHasResumableSession: false))
        XCTAssertTrue(ChatHistoricalImageBridgePolicy.shouldBridge(
            visibleTurn: "切回 GPT 後請再讀上一則訊息的附件圖片。",
            interactionMode: .standard,
            targetRuntimeAdapter: .codexExec,
            targetHasResumableSession: true))
    }

    func testPreviewTextNeverContainsTranscriptMarkerOrAbsolutePath() {
        XCTAssertEqual(
            ChatAttachmentTranscript.previewText(
                userText: "",
                attachmentPaths: ["/Users/example/private proof.png"]),
            "圖片附件 · private proof.png")
        XCTAssertEqual(
            ChatAttachmentTranscript.previewText(
                userText: "請讀這張圖",
                attachmentPaths: ["/Users/example/private proof.png"]),
            "請讀這張圖")
        XCTAssertEqual(
            ChatAttachmentTranscript.previewText(
                userText: "",
                attachmentPaths: ["/tmp/hash.png"],
                attachmentDisplayNames: ["/tmp/hash.png": "旅遊照片.png"]),
            "圖片附件 · 旅遊照片.png")
    }

    func testSendCapturesAttachmentsBeforeClearingComposerAndForwardsSnapshot() throws {
        let source = try ChatPageSourceScanner.combinedSource(repoRoot: repoRoot)

        XCTAssertTrue(source.contains("let attachmentPaths = droppedPaths"))
        XCTAssertTrue(source.contains("attachmentDisplayNames: attachmentDisplayNames"))
        XCTAssertTrue(source.contains("imageStore: imageAssetStore"))
        XCTAssertTrue(source.contains("attachmentDisplayNames: attachmentDisplayNames"))
        XCTAssertTrue(source.contains("visibleTurn: commandDisplayTurn"))
        XCTAssertTrue(source.contains("droppedPaths: attachmentPaths"))
        XCTAssertTrue(source.contains(
            "updateSelectedThreadPreview(previewTurn, sessionID: nil)"))
        XCTAssertFalse(source.contains(
            "updateSelectedThreadPreview(displayTurn, sessionID: nil)"))
    }

    func testAttachmentTileUsesClickableQuickLookPreview() throws {
        let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")

        XCTAssertTrue(source.contains("@State private var previewURL: URL?"))
        XCTAssertTrue(source.contains("Button {"))
        XCTAssertTrue(source.contains("previewURL = attachment.url"))
        XCTAssertTrue(source.contains(".quickLookPreview($previewURL)"))
        XCTAssertTrue(source.contains(#""點擊預覽 \(attachment.displayName)""#))
        XCTAssertFalse(source.contains(".help(attachment.path)"))
    }

    func testAttachmentStripExpandsAndMissingAttachmentIsVisible() throws {
        let source = try ChatSourceFamily.read("ChatPageLeafViews.swift")

        XCTAssertTrue(source.contains("@State private var isExpanded = false"))
        XCTAssertTrue(source.contains("isExpanded.toggle()"))
        XCTAssertTrue(source.contains("\"收合附件\""))
        XCTAssertTrue(source.contains("Text(\"附件遺失\")"))
        XCTAssertTrue(source.contains("guard !attachment.isMissing else { return }"))
    }
}
