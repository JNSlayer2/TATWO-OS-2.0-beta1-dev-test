import Foundation

public struct ChatTranscriptScrollFollowState: Sendable, Equatable {
  public static let detachThreshold: CGFloat = 80

  public private(set) var isFollowingLatest: Bool

  public init(isFollowingLatest: Bool = true) {
    self.isFollowingLatest = isFollowingLatest
  }

  public var shouldAutoScrollOnContentChange: Bool {
    isFollowingLatest
  }

  public var showsJumpToLatest: Bool {
    !isFollowingLatest
  }

  public mutating func update(
    bottomY: CGFloat,
    viewportHeight: CGFloat
  ) {
    let distanceFromBottom = max(
      0,
      bottomY - max(0, viewportHeight))
    isFollowingLatest = distanceFromBottom <= Self.detachThreshold
  }

  public mutating func jumpToLatest() {
    isFollowingLatest = true
  }
}
