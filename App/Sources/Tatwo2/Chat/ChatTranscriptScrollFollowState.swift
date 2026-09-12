// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ChatTranscriptScrollFollowState.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

public struct ChatTranscriptScrollFollowState: Sendable, Equatable {
  public static let detachThreshold: CGFloat = 80
  /// 2026-09-11 使用者：「跳至最新」太敏感、沒東西也一直出現 → 離底部超過這段距離才顯示。
  public static let jumpButtonThreshold: CGFloat = 360

  public private(set) var isFollowingLatest: Bool
  private var distanceFromBottom: CGFloat = 0

  public init(isFollowingLatest: Bool = true) {
    self.isFollowingLatest = isFollowingLatest
  }

  public var shouldAutoScrollOnContentChange: Bool {
    isFollowingLatest
  }

  public var showsJumpToLatest: Bool {
    !isFollowingLatest && distanceFromBottom > Self.jumpButtonThreshold
  }

  public mutating func update(
    bottomY: CGFloat,
    viewportHeight: CGFloat
  ) {
    // Lazy layout can temporarily publish its default zero preference.
    // Missing geometry is not evidence that the reader returned to the bottom.
    guard bottomY.isFinite, viewportHeight.isFinite,
      bottomY > 0, viewportHeight > 0 else { return }
    distanceFromBottom = max(0, bottomY - viewportHeight)
    // Geometry never detaches an active follower (streaming/reflow grows the distance before the
    // queued scroll runs); only explicit input does. A detached reader who scrolls back to the
    // bottom follows again — streaming only moves the bottom away, so it can't re-attach by itself.
    if !isFollowingLatest, distanceFromBottom <= Self.detachThreshold {
      isFollowingLatest = true
    }
  }

  public mutating func jumpToLatest() {
    isFollowingLatest = true
  }

  public mutating func detachFromLatest() {
    isFollowingLatest = false
  }
}
