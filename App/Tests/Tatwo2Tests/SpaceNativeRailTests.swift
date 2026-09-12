import AppKit
import SwiftUI
import XCTest
@testable import Tatwo2

@MainActor
final class SpaceNativeRailTests: XCTestCase {
    func testRailMountedAfterVisibleWindowStaysOutsideAndDetaches() async throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.contentView = nil; parent.orderOut(nil) }
        let controller = BotEdgeTabsPanelController()
        controller.attach(to: parent, content: Text("+"))
        let rail = try XCTUnwrap(parent.childWindows?.first)
        XCTAssertTrue(rail.isVisible, "Late-mounted rail must not remain ordered out.")
        XCTAssertEqual(rail.frame.minX, parent.frame.maxX - 10, accuracy: 0.1)
        XCTAssertEqual(rail.frame.maxX, parent.frame.maxX + 36, accuracy: 0.1)
        controller.detach()
        XCTAssertFalse(rail.isVisible)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
    }
}
