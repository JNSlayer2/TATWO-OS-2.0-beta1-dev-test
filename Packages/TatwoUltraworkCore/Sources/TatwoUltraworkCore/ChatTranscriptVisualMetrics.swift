import Foundation

public enum TatwoChatTranscriptVisualMetrics {
  public static let composerPointSize: CGFloat = 14
  public static let sidebarHeaderPointSize: CGFloat = 12.5
  public static let sidebarProjectPointSize: CGFloat = 13
  public static let sidebarThreadTitlePointSize: CGFloat = 13
  public static let sidebarThreadPreviewPointSize: CGFloat = 12
  public static let transcriptPointSize: CGFloat = 13
  public static let transcriptMetaPointSize: CGFloat = 11.5
  public static let bodyPointSize: CGFloat = 13
  public static let codePointSize: CGFloat = 13
  public static let tableHeaderPointSize: CGFloat = 13
  public static let transcriptLineSpacing: CGFloat = 2.5
  public static let messageSpacing: CGFloat = 14
  public static let headingPointSizes: [CGFloat] = [20, 17, 15.5, 14.5, 13.5, 13]

  public static let userBubbleCornerRadius: CGFloat = 11
  public static let userBubbleHorizontalPadding: CGFloat = 12
  public static let userBubbleVerticalPadding: CGFloat = 9
  public static let userBubbleMaximumWidthFraction: CGFloat = 0.70
  public static let userBubbleAbsoluteMaximumWidth: CGFloat = 574
  public static let userBubbleMinimumWidth: CGFloat = 42
  public static let userBubbleTintOpacity: Double = 0.05
  public static let userBubbleHighlightOpacity: Double = 0.008
  public static let userBubbleStrokeOpacity: Double = 0.075
  public static let estimatedCJKCharacterWidth: CGFloat = 13
  public static let estimatedLatinCharacterWidth: CGFloat = 6.8

  public static let windowComposerTextMinimumHeight: CGFloat = 30
  public static let windowComposerTextIdealHeight: CGFloat = 34
  public static let windowComposerTextMaximumHeight: CGFloat = 220
  public static let panelComposerTextMinimumHeight: CGFloat = 28
  public static let panelComposerTextIdealHeight: CGFloat = 32
  public static let panelComposerTextMaximumHeight: CGFloat = 180
  public static let windowComposerMinimumHeight: CGFloat = 82
  public static let panelComposerMinimumHeight: CGFloat = 78

  public static func headingPointSize(level: Int) -> CGFloat {
    let index = min(max(level, 1), headingPointSizes.count) - 1
    return headingPointSizes[index]
  }

  public static func userBubbleMaximumWidth(rowWidth: CGFloat) -> CGFloat {
    min(
      userBubbleAbsoluteMaximumWidth,
      max(
        userBubbleMinimumWidth,
        rowWidth * userBubbleMaximumWidthFraction))
  }
}
