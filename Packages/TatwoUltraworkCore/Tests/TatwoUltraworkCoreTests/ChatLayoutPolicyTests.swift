import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class ChatLayoutPolicyTests: XCTestCase {
  private let boundaryWidths: [CGFloat] = [760, 899, 1039, 1040, 1599, 1600]

  func testBoundaryMatrixKeepsMainColumnCenteredWithSymmetricReserves() {
    for layoutWidth in boundaryWidths {
      for railPinned in [false, true] {
        for sidebarVisible in [false, true] {
          let result = ChatLayoutPolicy.resolve(
            layoutWidth: layoutWidth,
            railPinned: railPinned,
            sidebarVisible: sidebarVisible)

          let sidebarWidth = min(max(layoutWidth * 0.28, 220), 280)
          let sidebarOccupancy = sidebarVisible ? sidebarWidth + 12 : 0
          let expectedCenter = (sidebarOccupancy + layoutWidth) / 2
          let actualCenter = (
            sidebarOccupancy
              + result.leadingReserve
              + layoutWidth
              - result.trailingReserve
          ) / 2

          XCTAssertEqual(
            result.leadingReserve,
            result.trailingReserve,
            accuracy: 0.0001,
            "asymmetric reserve at width=\(layoutWidth), railPinned=\(railPinned), sidebarVisible=\(sidebarVisible)")
          XCTAssertEqual(
            actualCenter - expectedCenter,
            0,
            accuracy: 0.0001,
            "center bias at width=\(layoutWidth), railPinned=\(railPinned), sidebarVisible=\(sidebarVisible)")
          XCTAssertGreaterThanOrEqual(result.contentMaxWidth, 320)
          XCTAssertLessThanOrEqual(result.contentMaxWidth, 820)
        }
      }
    }
  }

  func testPinnedRailReserveIsSymmetricAndKeepsContentClearOfTheRail() {
    for layoutWidth in boundaryWidths {
      let sidebarWidth = min(max(layoutWidth * 0.28, 220), 280)
      let result = ChatLayoutPolicy.resolve(
        layoutWidth: layoutWidth,
        railPinned: true,
        sidebarVisible: false)

      XCTAssertEqual(result.leadingReserve, sidebarWidth + 18)
      XCTAssertEqual(result.trailingReserve, sidebarWidth + 18)
    }
  }

  func test1599And1600UseIdenticalOverlayOnlyMainColumnGeometry() {
    for railPinned in [false, true] {
      for sidebarVisible in [false, true] {
        let beforeFormerThreshold = ChatLayoutPolicy.resolve(
          layoutWidth: 1599,
          railPinned: railPinned,
          sidebarVisible: sidebarVisible)
        let atFormerThreshold = ChatLayoutPolicy.resolve(
          layoutWidth: 1600,
          railPinned: railPinned,
          sidebarVisible: sidebarVisible)

        XCTAssertEqual(atFormerThreshold.leadingReserve, beforeFormerThreshold.leadingReserve)
        XCTAssertEqual(atFormerThreshold.trailingReserve, beforeFormerThreshold.trailingReserve)
        XCTAssertEqual(atFormerThreshold.contentMaxWidth, beforeFormerThreshold.contentMaxWidth)
      }
    }
  }
}
