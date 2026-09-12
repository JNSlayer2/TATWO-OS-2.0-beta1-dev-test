import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Tatwo2

/// Native, offscreen UI proposal; never opens another main App or writes live data.
@MainActor
final class ChatCompactPreviewSnapshotTests: XCTestCase {
    func testCompactChatProposal() throws {
        guard let output = ProcessInfo.processInfo.environment["TATWO_CHAT_COMPACT_EVIDENCE_DIR"] else {
            throw XCTSkip("Set TATWO_CHAT_COMPACT_EVIDENCE_DIR for the UI proposal.")
        }
        _ = NSApplication.shared
        let index = TurnArtifactIndex(
            threadID: UUID(), turnID: "preview", endedAt: Date(),
            artifacts: (1...9).map {
                TurnArtifact(path: "Sources/Feature\($0).swift", kind: "file",
                             claimed: true, exists: true, sizeBytes: 1024)
            }, truncated: false)
        let timeline = ChatInlineWorkTimeline(
            turnID: "preview", messages: [],
            presentation: .init(state: .running, text: "檢查修改與測試", isActive: true),
            modelID: nil)
        var previewEnvironment = ProcessInfo.processInfo.environment
        previewEnvironment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] = "dispatch"
        let model = ChatPageModel(environment: previewEnvironment)
        let root = VStack(alignment: .leading, spacing: 20) {
            DispatchCard(model: model)
            ChatArtifactsCard(index: index, onView: {}, onOpen: { _ in })
            ChatInlineWorkTimelineView(timeline: timeline, assistantRoute: .resolve("codex"),
                                       rowWidth: 720)
            ChatTypingIndicatorRow(route: .resolve("codex"), rowWidth: 720)
        }
        .padding(24)
        .frame(width: 800, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("chat-compact-proposal.png"))
        let receipt = [
            "surface": "Chat compact components",
            "mode": "offscreen-fixture-not-live-acceptance",
            "viewport": "800x300",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "sourceStamp": ProcessInfo.processInfo.environment["TATWO_SPACE_SOURCE_STAMP"] ?? "unbound"
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("chat-compact-proposal.json"))
    }
}
