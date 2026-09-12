import XCTest

@testable import TatwoUltraworkCore

final class ChatSliderPointerLifecycleTests: XCTestCase {
  func testReleaseConversionFailureEndsAtLastKnownCoordinateExactlyOnce() {
    var lifecycle = TatwoChatSliderPointerLifecycle()

    XCTAssertEqual(
      lifecycle.pointerDown(at: 42).callbacks,
      [.began(42), .changed(42)]
    )
    XCTAssertEqual(lifecycle.pointerDragged(to: nil).callbacks, [])
    XCTAssertEqual(lifecycle.pointerUp(at: nil).callbacks, [.ended(42)])
    XCTAssertEqual(lifecycle.pointerUp(at: 99).callbacks, [])
  }

  func testRepresentableDismantleAfterSuccessfulMouseUpDoesNotCancelHandedOffSettle() {
    var awaitingOwnership = TatwoChatSliderPointerLifecycle()
    XCTAssertTrue(awaitingOwnership.attachInfrastructure().installInfrastructure)
    _ = awaitingOwnership.pointerDown(at: 20)
    XCTAssertEqual(awaitingOwnership.pointerUp(at: 30).callbacks, [.ended(30)])

    let immediateDismantle = awaitingOwnership.dismantleRepresentable()
    XCTAssertEqual(immediateDismantle.callbacks, [])
    XCTAssertTrue(immediateDismantle.removeInfrastructure)

    var settling = TatwoChatSliderPointerLifecycle()
    XCTAssertTrue(settling.attachInfrastructure().installInfrastructure)
    _ = settling.pointerDown(at: 20)
    _ = settling.pointerUp(at: 30)
    settling.synchronizePendingSettle(true)

    let ownedSettleDismantle = settling.dismantleRepresentable()
    XCTAssertEqual(ownedSettleDismantle.callbacks, [])
    XCTAssertTrue(ownedSettleDismantle.removeInfrastructure)
  }

  func testLifecycleInvalidationCancelsTrackingAndPendingSettleOnlyOnce() {
    var tracking = TatwoChatSliderPointerLifecycle()
    _ = tracking.pointerDown(at: 10)
    XCTAssertEqual(tracking.invalidateLifecycle().callbacks, [.cancelled])
    XCTAssertEqual(tracking.invalidateLifecycle().callbacks, [])

    var settling = TatwoChatSliderPointerLifecycle()
    _ = settling.pointerDown(at: 10)
    _ = settling.pointerUp(at: 12)
    settling.synchronizePendingSettle(true)
    XCTAssertEqual(settling.invalidateLifecycle().callbacks, [.cancelled])
    XCTAssertEqual(settling.invalidateLifecycle().callbacks, [])
  }

  func testWindowCloseCancelsOnceThenRemovesInfrastructureOnce() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.attachInfrastructure()
    _ = lifecycle.pointerDown(at: 10)
    _ = lifecycle.pointerUp(at: 12)
    lifecycle.synchronizePendingSettle(true)

    XCTAssertEqual(lifecycle.invalidateLifecycle().callbacks, [.cancelled])
    let detach = lifecycle.detachFromWindow()
    XCTAssertEqual(detach.callbacks, [])
    XCTAssertTrue(detach.removeInfrastructure)

    XCTAssertEqual(lifecycle.invalidateLifecycle().callbacks, [])
    XCTAssertFalse(lifecycle.detachFromWindow().removeInfrastructure)
  }

  func testDetachCancelsOnlyActivePointerAndRemovesInfrastructureOnce() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    XCTAssertTrue(lifecycle.attachInfrastructure().installInfrastructure)
    _ = lifecycle.pointerDown(at: 11)

    let firstDetach = lifecycle.detachFromWindow()
    XCTAssertEqual(firstDetach.callbacks, [.cancelled])
    XCTAssertTrue(firstDetach.removeInfrastructure)

    let secondDetach = lifecycle.detachFromWindow()
    XCTAssertEqual(secondDetach.callbacks, [])
    XCTAssertFalse(secondDetach.removeInfrastructure)

    XCTAssertTrue(lifecycle.attachInfrastructure().installInfrastructure)
  }

  func testNewMouseDownCancelsPriorSettleThenOwnsFreshSequence() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.pointerDown(at: 10)
    _ = lifecycle.pointerUp(at: 15)
    lifecycle.synchronizePendingSettle(true)

    XCTAssertEqual(
      lifecycle.pointerDown(at: 80).callbacks,
      [.cancelled, .began(80), .changed(80)]
    )

    lifecycle.synchronizePendingSettle(true)
    XCTAssertEqual(lifecycle.phase, .tracking(lastKnownX: 80))
    XCTAssertEqual(lifecycle.pointerUp(at: nil).callbacks, [.ended(80)])
  }

  func testLostReleaseNewMouseDownCancelsTrackingThenOwnsFreshSequence() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.pointerDown(at: 10)
    _ = lifecycle.pointerDragged(to: 24)
    XCTAssertEqual(lifecycle.phase, .tracking(lastKnownX: 24))

    XCTAssertEqual(
      lifecycle.pointerDown(at: 80).callbacks,
      [.cancelled, .began(80), .changed(80)]
    )
    XCTAssertEqual(lifecycle.phase, .tracking(lastKnownX: 80))
  }

  func testReleasedAwaitingSettleInvalidationCancelsExactlyOnce() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.pointerDown(at: 10)
    _ = lifecycle.pointerUp(at: 12)
    XCTAssertEqual(lifecycle.phase, .releasedAwaitingSettle)

    XCTAssertEqual(lifecycle.invalidateLifecycle().callbacks, [.cancelled])
    XCTAssertEqual(lifecycle.phase, .idle)
    XCTAssertEqual(lifecycle.invalidateLifecycle().callbacks, [])
  }

  func testCompletedSettleReturnsIdleAndFreshMouseDownHasNoStaleCancellation() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.pointerDown(at: 10)
    _ = lifecycle.pointerUp(at: 12)
    lifecycle.synchronizePendingSettle(true)
    XCTAssertEqual(lifecycle.phase, .settling)

    lifecycle.synchronizePendingSettle(false)
    XCTAssertEqual(lifecycle.phase, .idle)
    XCTAssertEqual(
      lifecycle.pointerDown(at: 80).callbacks,
      [.began(80), .changed(80)]
    )
    XCTAssertEqual(lifecycle.phase, .tracking(lastKnownX: 80))
  }

  func testCallbacksStaySilentAfterTheyAreCleared() {
    var lifecycle = TatwoChatSliderPointerLifecycle()
    _ = lifecycle.attachInfrastructure()
    _ = lifecycle.pointerDown(at: 25)
    _ = lifecycle.dismantleRepresentable()
    lifecycle.clearCallbacks()

    XCTAssertEqual(lifecycle.pointerDown(at: 75).callbacks, [])
    XCTAssertEqual(lifecycle.pointerDragged(to: 80).callbacks, [])
    XCTAssertEqual(lifecycle.pointerUp(at: 90).callbacks, [])
    XCTAssertEqual(lifecycle.invalidateLifecycle().callbacks, [])
  }

  func testInfrastructureAttachDetachIsIdempotentAcrossReopen() {
    var lifecycle = TatwoChatSliderPointerLifecycle()

    XCTAssertTrue(lifecycle.attachInfrastructure().installInfrastructure)
    XCTAssertFalse(lifecycle.attachInfrastructure().installInfrastructure)
    XCTAssertTrue(lifecycle.dismantleRepresentable().removeInfrastructure)
    XCTAssertFalse(lifecycle.dismantleRepresentable().removeInfrastructure)
    XCTAssertTrue(lifecycle.attachInfrastructure().installInfrastructure)
  }
}
