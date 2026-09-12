// 照搬自 Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/ChatSliderPointerLifecycle.swift；改動 2 行（原因：改接 Tatwo2 同名 Facade 假資料）
import Foundation

package enum TatwoChatSliderPointerCallback: Equatable, Sendable {
  case began(CGFloat)
  case changed(CGFloat)
  case ended(CGFloat)
  case cancelled
}

package struct TatwoChatSliderPointerTransition: Equatable, Sendable {
  package var callbacks: [TatwoChatSliderPointerCallback]
  package var installInfrastructure: Bool
  package var removeInfrastructure: Bool

  package init(
    callbacks: [TatwoChatSliderPointerCallback] = [],
    installInfrastructure: Bool = false,
    removeInfrastructure: Bool = false
  ) {
    self.callbacks = callbacks
    self.installInfrastructure = installInfrastructure
    self.removeInfrastructure = removeInfrastructure
  }
}

package struct TatwoChatSliderPointerLifecycle: Sendable {
  package enum Phase: Equatable, Sendable {
    case idle
    case tracking(lastKnownX: CGFloat)
    case releasedAwaitingSettle
    case settling
  }

  package private(set) var phase: Phase = .idle
  package private(set) var infrastructureInstalled = false
  package private(set) var callbacksActive = true

  package init() {}

  package mutating func attachInfrastructure() -> TatwoChatSliderPointerTransition {
    guard !infrastructureInstalled else {
      return TatwoChatSliderPointerTransition()
    }
    infrastructureInstalled = true
    return TatwoChatSliderPointerTransition(installInfrastructure: true)
  }

  package mutating func infrastructureInstallationFailed() {
    infrastructureInstalled = false
  }

  package mutating func synchronizePendingSettle(_ isPending: Bool) {
    guard callbacksActive else { return }
    if isPending {
      if case .tracking = phase {
        return
      }
      phase = .settling
    } else if phase == .settling || phase == .releasedAwaitingSettle {
      phase = .idle
    }
  }

  package mutating func pointerDown(at x: CGFloat) -> TatwoChatSliderPointerTransition {
    guard callbacksActive else {
      return TatwoChatSliderPointerTransition()
    }
    var callbacks: [TatwoChatSliderPointerCallback] = []
    if phase != .idle {
      callbacks.append(.cancelled)
    }
    phase = .tracking(lastKnownX: x)
    callbacks.append(.began(x))
    callbacks.append(.changed(x))
    return TatwoChatSliderPointerTransition(callbacks: callbacks)
  }

  package mutating func pointerDragged(to x: CGFloat?) -> TatwoChatSliderPointerTransition {
    guard callbacksActive, let x, case .tracking = phase else {
      return TatwoChatSliderPointerTransition()
    }
    phase = .tracking(lastKnownX: x)
    return TatwoChatSliderPointerTransition(callbacks: [.changed(x)])
  }

  package mutating func pointerUp(at x: CGFloat?) -> TatwoChatSliderPointerTransition {
    guard callbacksActive, case let .tracking(lastKnownX) = phase else {
      return TatwoChatSliderPointerTransition()
    }
    let releaseX = x ?? lastKnownX
    phase = .releasedAwaitingSettle
    return TatwoChatSliderPointerTransition(callbacks: [.ended(releaseX)])
  }

  package mutating func invalidateLifecycle() -> TatwoChatSliderPointerTransition {
    guard callbacksActive, phase != .idle else {
      return TatwoChatSliderPointerTransition()
    }
    phase = .idle
    return TatwoChatSliderPointerTransition(callbacks: [.cancelled])
  }

  package mutating func detachFromWindow() -> TatwoChatSliderPointerTransition {
    dismantleRepresentable()
  }

  package mutating func dismantleRepresentable() -> TatwoChatSliderPointerTransition {
    var callbacks: [TatwoChatSliderPointerCallback] = []
    if callbacksActive, case .tracking = phase {
      callbacks.append(.cancelled)
    }
    phase = .idle
    let removeInfrastructure = infrastructureInstalled
    infrastructureInstalled = false
    return TatwoChatSliderPointerTransition(
      callbacks: callbacks,
      removeInfrastructure: removeInfrastructure
    )
  }

  package mutating func clearCallbacks() {
    callbacksActive = false
    phase = .idle
  }
}
