import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Tatwo2

/// Offscreen native fixture images. This does not launch a second OS or prove
/// interactive clipboard, drag, live task, persistence or child-window behavior.
@MainActor
final class SpaceSetupPreviewSnapshotTests: XCTestCase {
    func testNativeReviewImages() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["TATWO_SPACE_PREVIEW_EVIDENCE_DIR"] else {
            throw XCTSkip("Set TATWO_SPACE_PREVIEW_EVIDENCE_DIR for native fixture images.")
        }
        XCTAssertNotNil(environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"],
                        "Offscreen capture must use the existing inline-rail export mode.")
        guard environment["TATWO_ULTRAWORK_EXPORT_WINDOW_SNAPSHOT"] != nil else { return }
        XCTAssertEqual(environment["TATWO_SPACE_SETUP_UI_PREVIEW"], "1")
        XCTAssertEqual(environment["TATWO_ULTRAWORK_EXPORT_BOT_SIDEBAR"], "1")
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // Match the formal Chat baseline without changing the running App's theme.
        // The test runner supplies the existing theme override in its own process.
        _ = TatwoThemeStore.shared

        let preview = SpaceSetupPreviewState.shared
        let tattoo = preview.domains[0]
        let admin = preview.domains[1]
        preview.selectDomain(tattoo.id)
        tattoo.draft = ""
        tattoo.openBuilder()
        var receipts: [[String: String]] = []
        receipts.append(try capture("builder-wide", size: .init(width: 1280, height: 900),
                                    directory: directory))
        receipts.append(try capture("builder-narrow", size: .init(width: 900, height: 700),
                                    directory: directory))

        tattoo.screen = .settings
        tattoo.moveTab(.bot, before: .chat)
        tattoo.setPreviewTaskRunning(true, for: .bot)
        tattoo.toggle(.bot)
        receipts.append(try capture("settings-pending-disable", size: .init(width: 780, height: 560),
                                    directory: directory, settings: true))
        tattoo.toggle(.bot)
        tattoo.setPreviewTaskRunning(false, for: .bot)
        tattoo.openBuilder()
        tattoo.draft = "【名稱】\n刺青後台\n【主要功能】\n預約與作品管理"
        tattoo.previewResult()
        let item = try XCTUnwrap(tattoo.selectedInterface)
        tattoo.selectInterface(item.id, conversation: true)
        receipts.append(try capture("shared-bot-conversation", size: .init(width: 1280, height: 900),
                                    directory: directory))

        preview.selectDomain(admin.id)
        admin.openBuilder()
        admin.draft = "行政 Space 的未送出草稿"
        XCTAssertTrue(admin.interfaces.isEmpty)
        receipts.append(try capture("admin-isolated-draft", size: .init(width: 1280, height: 900),
                                    directory: directory))
        preview.selectDomain(tattoo.id)
        XCTAssertEqual(tattoo.selectedInterface?.conversationID, item.conversationID)
        receipts.append(try capture("tattoo-restored", size: .init(width: 1280, height: 900),
                                    directory: directory))
        let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("native-fixture-images.json"), options: .atomic)
    }

    private func capture(_ name: String, size: NSSize, directory: URL,
                         settings: Bool = false) throws -> [String: String] {
        // Capture the actual Bot root including its original horizontal mode
        // pills and sidebar, not a standalone imitation of the OS navigation.
        let root = Group {
            if settings {
                // Settings belongs in the original Settings chrome, not the Bot pane.
                // The shell has no live ChatPageModel or issue-store side effects.
                TatwoSettingsShell(section: .constant(.space)) {
                    SpaceSetupPreviewView(opensSettings: true)
                }
            } else {
                BotPageRootView(sceneID: "add-space", contentMode: .addSpace)
            }
        }
            .frame(width: size.width, height: size.height)
            // A standalone fixture lacks the shell's canvas. Capture that actual
            // native backdrop too, rather than transparent black-on-alpha pixels.
            .background(TatwoBackground())
            .environment(\.colorScheme, .light)
        // Main-window capture cannot include a child panel. Show its existing
        // 46pt rail / 10pt underlap geometry OUTSIDE the main-window canvas.
        // This is an offscreen composition, not native child-window acceptance.
        let captureSize = NSSize(width: size.width + (settings ? 0 : 36), height: size.height)
        let exteriorCapture = ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            if !settings {
                SpaceSetupEdgeRail()
                    .frame(width: 46, height: size.height)
                    .offset(x: size.width - 10)
            }
            root
                .clipShape(RoundedRectangle(cornerRadius: settings ? 0 : 12))
        }
        .frame(width: captureSize.width, height: captureSize.height, alignment: .topLeading)
        let hosting = NSHostingView(rootView: exteriorCapture)
        hosting.frame = NSRect(origin: .zero, size: captureSize)
        // A non-visible AppKit host supplies native NSTextView layout and materials.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let backdrop = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        XCTAssertGreaterThan(backdrop.alphaComponent, 0.99, "Native canvas must be opaque.")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url, options: .atomic)
        return [
            "surface": name,
            "shell": settings ? "TatwoSettingsShell" : "BotPageRootView",
            "mode": "offscreen-native-fixture-not-interactive-acceptance",
            "path": url.path,
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "viewport": "\(Int(captureSize.width))x\(Int(captureSize.height))",
            "mainWindowViewport": "\(Int(size.width))x\(Int(size.height))",
            "edgeRail": settings ? "none" : "outside-main-window-offscreen-composition",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sourceStamp": ProcessInfo.processInfo.environment["TATWO_SPACE_SOURCE_STAMP"] ?? "unbound",
            "theme": TatwoThemeStore.shared.activeThemeID.rawValue
        ]
    }
}
