// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ChatLayoutPolicy.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

/// Symmetric geometry for the Chat main column. Floating surfaces such as the
/// Thread info card remain overlays and never contribute a one-sided reserve.
public struct ChatLayoutPolicyResult: Sendable, Equatable {
  public let leadingReserve: CGFloat
  public let trailingReserve: CGFloat
  public let contentMaxWidth: CGFloat

  public init(
    leadingReserve: CGFloat,
    trailingReserve: CGFloat,
    contentMaxWidth: CGFloat
  ) {
    self.leadingReserve = leadingReserve
    self.trailingReserve = trailingReserve
    self.contentMaxWidth = contentMaxWidth
  }
}

public enum ChatLayoutPolicy {
  private static let contentWidthCap: CGFloat = 820
  private static let minimumContentWidth: CGFloat = 320
  private static let contentHorizontalInset: CGFloat = 36

  /// Resolves only the main-column canvas. The Thread info card is intentionally
  /// absent from this API because ChatPage always renders it as an overlay.
  public static func resolve(
    layoutWidth: CGFloat,
    railPinned: Bool,
    sidebarVisible: Bool
  ) -> ChatLayoutPolicyResult {
    let layoutWidth = max(0, layoutWidth)
    let sidebarWidth = WorkspaceSidebarMetrics.width
    let symmetricReserve: CGFloat
    if sidebarVisible {
      symmetricReserve = 0
    } else if railPinned {
      symmetricReserve = sidebarWidth + 18
    } else {
      symmetricReserve = layoutWidth < 900 ? 22 : 48
    }

    let sidebarReserve = sidebarVisible ? sidebarWidth + 12 : 0
    let mainAvailableWidth = max(
      minimumContentWidth,
      layoutWidth
        - sidebarReserve
        - symmetricReserve
        - symmetricReserve)
    let contentMaxWidth = min(
      contentWidthCap,
      max(minimumContentWidth, mainAvailableWidth - contentHorizontalInset))

    return ChatLayoutPolicyResult(
      leadingReserve: symmetricReserve,
      trailingReserve: symmetricReserve,
      contentMaxWidth: contentMaxWidth)
  }
}
