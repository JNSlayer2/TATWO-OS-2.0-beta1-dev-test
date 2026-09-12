import AppKit
import SwiftUI
import XCTest
@testable import Tatwo2

@MainActor
final class ChatSlashRailKeyboardTests: XCTestCase {
    private struct Rail: View {
        @ObservedObject var model: ChatPageModel
        var body: some View {
            ChatPage(model: model).slashCommandRail(model.matchingSlashCommands)
                .frame(width: 260, height: 50)
        }
    }

    func testKeyboardSelectionScrollsNarrowRailBothWays() throws {
        _ = NSApplication.shared
        var environment = ProcessInfo.processInfo.environment
        environment["TATWO_ULTRAWORK_EXPORT_CHAT_SCENE"] = "dispatch"
        let model = ChatPageModel(environment: environment)
        model.prompt = "/"
        let host = NSHostingView(rootView: Rail(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 50)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
        }
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        settle()
        let scroll = try XCTUnwrap(scrollView(in: host))
        let initialX = scroll.contentView.bounds.minX
        let count = model.matchingSlashCommands.count
        XCTAssertGreaterThan(count, 4)
        for _ in 0..<count {
            XCTAssertTrue(model.handleSlashSuggestionKey(.next))
            settle()
        }
        XCTAssertEqual(model.slashCommandSelectedIndex, count - 1)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, initialX + 200,
                             "The highlighted offscreen command must scroll into view.")
        for _ in 1..<count {
            XCTAssertTrue(model.handleSlashSuggestionKey(.prev))
            settle()
        }
        XCTAssertEqual(model.slashCommandSelectedIndex, 0)
        XCTAssertLessThan(scroll.contentView.bounds.minX, initialX + 100)
        XCTAssertTrue(model.handleSlashSuggestionKey(.commit))
        XCTAssertTrue(model.prompt.hasPrefix("/feedback"))
    }
}
