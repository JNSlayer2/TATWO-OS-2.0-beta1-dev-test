import XCTest

@testable import TatwoUltraworkCore

final class ChatTranscriptVisualMetricsTests: XCTestCase {
  func testTypographyUsesCompactCodexLikeScale() {
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.transcriptPointSize, 13)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.composerPointSize, 14)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.transcriptLineSpacing, 2.5)
    XCTAssertEqual(
      TatwoChatTranscriptVisualMetrics.headingPointSizes,
      [20, 17, 15.5, 14.5, 13.5, 13])
  }

  func testUserBubbleUsesQuietCompactGeometry() {
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.userBubbleCornerRadius, 11)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.userBubbleHorizontalPadding, 12)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.userBubbleVerticalPadding, 9)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.userBubbleTintOpacity, 0.05)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.userBubbleStrokeOpacity, 0.075)
  }

  func testUserBubbleWidthTracksSeventyPercentOfReadableColumn() {
    XCTAssertEqual(
      TatwoChatTranscriptVisualMetrics.userBubbleMaximumWidth(rowWidth: 560),
      392,
      accuracy: 0.001)
    XCTAssertEqual(
      TatwoChatTranscriptVisualMetrics.userBubbleMaximumWidth(rowWidth: 820),
      574,
      accuracy: 0.001)
  }

  func testIdleComposerBaselineStaysNearNinetyPoints() {
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.windowComposerMinimumHeight, 82)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.panelComposerMinimumHeight, 78)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.windowComposerTextMaximumHeight, 220)
    XCTAssertEqual(TatwoChatTranscriptVisualMetrics.panelComposerTextMaximumHeight, 180)
    XCTAssertLessThan(TatwoChatTranscriptVisualMetrics.windowComposerTextMinimumHeight, 42)
    XCTAssertLessThan(TatwoChatTranscriptVisualMetrics.panelComposerTextMinimumHeight, 38)
  }
}
