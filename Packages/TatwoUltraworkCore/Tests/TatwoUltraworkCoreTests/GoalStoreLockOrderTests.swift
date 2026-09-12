import Dispatch
import Foundation
import XCTest

@testable import TatwoUltraworkCore

final class GoalStoreLockOrderTests: XCTestCase {
  func testLegalLifecycleGlobalRecordOrder() throws {
    try TatwoGoalStoreLockOrder.withOperation {
      XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [])
      try TatwoGoalStoreLockOrder.withLifecycleScope {
        XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [.lifecycle])
        try TatwoGoalStoreLockOrder.withGlobalScope {
          XCTAssertEqual(
            TatwoGoalStoreLockOrder.heldKinds,
            [.lifecycle, .global])
          try TatwoGoalStoreLockOrder.withRecordScope(recordID: "goal-a") {
            XCTAssertEqual(
              TatwoGoalStoreLockOrder.heldKinds,
              [.lifecycle, .global, .record])
          }
          XCTAssertEqual(
            TatwoGoalStoreLockOrder.heldKinds,
            [.lifecycle, .global])
        }
        XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [.lifecycle])
      }
      XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [])
    }
    XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [])
    XCTAssertNil(TatwoGoalStoreLockOrder.activeOperationMode)
  }

  func testReverseOrderAndActiveReentryReturnTypedErrors() throws {
    let standard = TatwoGoalStoreLockOrder.OperationState(mode: .standard)
    let root = standard.rootCursor()

    XCTAssertThrowsError(
      try standard.acquire(from: root, kind: .global)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .outOfOrder(requested: .global, held: []))
    }

    let lifecycle = try standard.acquire(from: root, kind: .lifecycle)
    XCTAssertThrowsError(
      try standard.acquire(from: lifecycle, kind: .lifecycle)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .unsupportedReentry(kind: .lifecycle))
    }
    XCTAssertThrowsError(
      try standard.acquire(from: lifecycle, kind: .record, recordID: "goal-a")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .outOfOrder(requested: .record, held: [.lifecycle]))
    }

    let global = try standard.acquire(from: lifecycle, kind: .global)
    XCTAssertThrowsError(
      try standard.acquire(from: global, kind: .global)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .unsupportedReentry(kind: .global))
    }

    let record = try standard.acquire(
      from: global,
      kind: .record,
      recordID: "goal-a")
    XCTAssertThrowsError(
      try standard.acquire(from: record, kind: .record, recordID: "goal-a")
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .secondRecordLock(
          existingRecordID: "goal-a",
          requestedRecordID: "goal-a"))
    }

    try standard.release(record)
    try standard.release(global)
    try standard.release(lifecycle)
    try standard.finishRootAfterSuccess(root)

    let globalOnly = TatwoGoalStoreLockOrder.OperationState(mode: .globalOnly)
    let globalOnlyRoot = globalOnly.rootCursor()
    let globalOnlyLease = try globalOnly.acquire(
      from: globalOnlyRoot,
      kind: .global)
    XCTAssertThrowsError(
      try globalOnly.acquire(from: globalOnlyLease, kind: .lifecycle)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .outOfOrder(requested: .lifecycle, held: [.global]))
    }
    try globalOnly.release(globalOnlyLease)
    try globalOnly.finishRootAfterSuccess(globalOnlyRoot)
  }

  func testSiblingGlobalTasksCannotEnterBodiesInParallel() async throws {
    let start = AsyncGate()
    let release = AsyncGate()
    let bodyCount = AsyncCounter()
    let failureCount = AsyncCounter()
    let identities = IdentityRecorder()

    try await TatwoGoalStoreLockOrder.withOperation {
      try await TatwoGoalStoreLockOrder.withLifecycleScope {
        let parentIdentity = requireIdentity(
          TatwoGoalStoreLockOrder.debugIdentity)
        let first = Task { () -> TatwoGoalStoreLockOrderError? in
          await start.wait()
          if let identity = TatwoGoalStoreLockOrder.debugIdentity {
            await identities.record(identity)
          }
          do {
            try await TatwoGoalStoreLockOrder.withGlobalScope {
              await bodyCount.increment()
              await release.wait()
            }
            return nil
          } catch {
            await failureCount.increment()
            return error as? TatwoGoalStoreLockOrderError
          }
        }
        let second = Task { () -> TatwoGoalStoreLockOrderError? in
          await start.wait()
          if let identity = TatwoGoalStoreLockOrder.debugIdentity {
            await identities.record(identity)
          }
          do {
            try await TatwoGoalStoreLockOrder.withGlobalScope {
              await bodyCount.increment()
              await release.wait()
            }
            return nil
          } catch {
            await failureCount.increment()
            return error as? TatwoGoalStoreLockOrderError
          }
        }

        await start.signal()
        var raceLinearized = false
        for _ in 0..<2_000 {
          let bodies = await bodyCount.read()
          let failures = await failureCount.read()
          let identityCount = await identities.read().count
          if bodies == 1, failures == 1, identityCount == 2 {
            raceLinearized = true
            break
          }
          try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(raceLinearized, "Sibling global race did not linearize")

        let inheritedIdentities = await identities.read()
        XCTAssertEqual(inheritedIdentities.count, 2)
        for identity in inheritedIdentities {
          XCTAssertEqual(identity.stateID, parentIdentity.stateID)
          XCTAssertEqual(identity.cursorID, parentIdentity.cursorID)
        }

        await release.signal()
        let firstError = await first.value
        let secondError = await second.value
        let errors = [firstError, secondError]
        XCTAssertEqual(errors.compactMap { $0 }.count, 1)
        XCTAssertTrue(
          errors.contains(.parentAlreadyHasActiveChild(parent: .lifecycle)))
      }
    }
    let finalBodyCount = await bodyCount.read()
    XCTAssertEqual(finalBodyCount, 1)
  }

  func testSiblingRecordTasksHaveOneOperationWideWinner() async throws {
    let start = AsyncGate()
    let release = AsyncGate()
    let bodyCount = AsyncCounter()
    let failureCount = AsyncCounter()
    let identities = IdentityRecorder()

    try await TatwoGoalStoreLockOrder.withOperation {
      try await TatwoGoalStoreLockOrder.withLifecycleScope {
        try await TatwoGoalStoreLockOrder.withGlobalScope {
          let parentIdentity = requireIdentity(
            TatwoGoalStoreLockOrder.debugIdentity)
          let first = Task { () -> TatwoGoalStoreLockOrderError? in
            await start.wait()
            if let identity = TatwoGoalStoreLockOrder.debugIdentity {
              await identities.record(identity)
            }
            do {
              try await TatwoGoalStoreLockOrder.withRecordScope(
                recordID: "goal-a"
              ) {
                await bodyCount.increment()
                await release.wait()
              }
              return nil
            } catch {
              await failureCount.increment()
              return error as? TatwoGoalStoreLockOrderError
            }
          }
          let second = Task { () -> TatwoGoalStoreLockOrderError? in
            await start.wait()
            if let identity = TatwoGoalStoreLockOrder.debugIdentity {
              await identities.record(identity)
            }
            do {
              try await TatwoGoalStoreLockOrder.withRecordScope(
                recordID: "goal-b"
              ) {
                await bodyCount.increment()
                await release.wait()
              }
              return nil
            } catch {
              await failureCount.increment()
              return error as? TatwoGoalStoreLockOrderError
            }
          }

          await start.signal()
          var raceLinearized = false
          for _ in 0..<2_000 {
            let bodies = await bodyCount.read()
            let failures = await failureCount.read()
            let identityCount = await identities.read().count
            if bodies == 1, failures == 1, identityCount == 2 {
              raceLinearized = true
              break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
          }
          XCTAssertTrue(raceLinearized, "Sibling record race did not linearize")

          let inheritedIdentities = await identities.read()
          XCTAssertEqual(inheritedIdentities.count, 2)
          for identity in inheritedIdentities {
            XCTAssertEqual(identity.stateID, parentIdentity.stateID)
            XCTAssertEqual(identity.cursorID, parentIdentity.cursorID)
          }

          await release.signal()
          let firstError = await first.value
          let secondError = await second.value
          let errors = [firstError, secondError]
          XCTAssertEqual(errors.compactMap { $0 }.count, 1)
          XCTAssertTrue(
            errors.contains(
              .secondRecordLock(
                existingRecordID: firstError == nil ? "goal-a" : "goal-b",
                requestedRecordID: firstError == nil ? "goal-b" : "goal-a")))
        }
      }
    }
    let finalBodyCount = await bodyCount.read()
    XCTAssertEqual(finalBodyCount, 1)
  }

  func testSequentialSecondRecordIsRejectedAfterFirstRelease() throws {
    try TatwoGoalStoreLockOrder.withOperation {
      try TatwoGoalStoreLockOrder.withLifecycleScope {
        try TatwoGoalStoreLockOrder.withGlobalScope {
          try TatwoGoalStoreLockOrder.withRecordScope(recordID: "goal-a") {}
          XCTAssertThrowsError(
            try TatwoGoalStoreLockOrder.withRecordScope(recordID: "goal-b") {}
          ) { error in
            XCTAssertEqual(
              error as? TatwoGoalStoreLockOrderError,
              .secondRecordLock(
                existingRecordID: "goal-a",
                requestedRecordID: "goal-b"))
          }
        }
      }
    }
  }

  func testEscapedChildAfterParentReleaseFailsBeforeBody() async throws {
    let proceed = AsyncGate()
    let bodyCount = AsyncCounter()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)

    try await TatwoGoalStoreLockOrder.withOperation {
      try TatwoGoalStoreLockOrder.withLifecycleScope {
        let child = Task { () -> TatwoGoalStoreLockOrderError? in
          await proceed.wait()
          do {
            try await TatwoGoalStoreLockOrder.withGlobalScope {
              await bodyCount.increment()
            }
            return nil
          } catch {
            return error as? TatwoGoalStoreLockOrderError
          }
        }
        childBox.set(child)
      }

      await proceed.signal()
      let childError = await requireTask(childBox.get()).value
      XCTAssertEqual(childError, .parentLeaseReleased(kind: .lifecycle))
      let finalBodyCount = await bodyCount.read()
      XCTAssertEqual(finalBodyCount, 0)
    }
  }

  func testEscapedChildAfterOperationCloseFailsBeforeBody() async throws {
    let proceed = AsyncGate()
    let bodyCount = AsyncCounter()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)

    try await TatwoGoalStoreLockOrder.withOperation {
      let child = Task { () -> TatwoGoalStoreLockOrderError? in
        await proceed.wait()
        do {
          try await TatwoGoalStoreLockOrder.withLifecycleScope {
            await bodyCount.increment()
          }
          return nil
        } catch {
          return error as? TatwoGoalStoreLockOrderError
        }
      }
      childBox.set(child)
      await Task.yield()
    }

    await proceed.signal()
    let childError = await requireTask(childBox.get()).value
    guard case .staleGeneration = childError else {
      return XCTFail("Expected staleGeneration, got \(String(describing: childError))")
    }
    let finalBodyCount = await bodyCount.read()
    XCTAssertEqual(finalBodyCount, 0)
  }

  func testReturningParentWithActiveDescendantPoisonsOperation() async {
    let entered = AsyncGate()
    let release = AsyncGate()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)
    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    var operationError: TatwoGoalStoreLockOrderError?

    do {
      try await TatwoGoalStoreLockOrder.withOperation {
        stateBox.set(TatwoGoalStoreLockOrder.currentStateForTesting)
        try await TatwoGoalStoreLockOrder.withLifecycleScope {
          let child = Task { () -> TatwoGoalStoreLockOrderError? in
            do {
              try await TatwoGoalStoreLockOrder.withGlobalScope {
                await entered.signal()
                await release.wait()
              }
              return nil
            } catch {
              return error as? TatwoGoalStoreLockOrderError
            }
          }
          childBox.set(child)
          await entered.wait()
        }
      }
      XCTFail("Expected parent close to fail closed")
    } catch {
      operationError = error as? TatwoGoalStoreLockOrderError
    }

    XCTAssertEqual(
      operationError,
      .nonLIFORelease(expected: .global, attempted: .lifecycle))
    let snapshot = requireState(stateBox.get()).debugSnapshot()
    XCTAssertEqual(snapshot.phase, .poisoned)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)

    await release.signal()
    let childError = await requireTask(childBox.get()).value
    guard case .staleGeneration = childError else {
      return XCTFail("Expected staleGeneration, got \(String(describing: childError))")
    }
  }

  func testReturningRootWithActiveDescendantPoisonsOperation() async {
    let entered = AsyncGate()
    let release = AsyncGate()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)
    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    var operationError: TatwoGoalStoreLockOrderError?

    do {
      try await TatwoGoalStoreLockOrder.withOperation {
        stateBox.set(TatwoGoalStoreLockOrder.currentStateForTesting)
        let child = Task { () -> TatwoGoalStoreLockOrderError? in
          do {
            try await TatwoGoalStoreLockOrder.withLifecycleScope {
              await entered.signal()
              await release.wait()
            }
            return nil
          } catch {
            return error as? TatwoGoalStoreLockOrderError
          }
        }
        childBox.set(child)
        await entered.wait()
      }
      XCTFail("Expected root close to fail closed")
    } catch {
      operationError = error as? TatwoGoalStoreLockOrderError
    }

    XCTAssertEqual(
      operationError,
      .operationClosedWithActiveLeases(count: 1))
    let snapshot = requireState(stateBox.get()).debugSnapshot()
    XCTAssertEqual(snapshot.phase, .poisoned)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)

    await release.signal()
    let childError = await requireTask(childBox.get()).value
    guard case .staleGeneration = childError else {
      return XCTFail("Expected staleGeneration, got \(String(describing: childError))")
    }
  }

  func testSyncBodyAndReleaseFailuresArePreservedAsComposite() async {
    let entered = BlockingSignal()
    let release = AsyncGate()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)
    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    var receivedError: Error?

    do {
      try TatwoGoalStoreLockOrder.withOperation {
        stateBox.set(TatwoGoalStoreLockOrder.currentStateForTesting)
        try TatwoGoalStoreLockOrder.withLifecycleScope {
          let child = Task { () -> TatwoGoalStoreLockOrderError? in
            do {
              try await TatwoGoalStoreLockOrder.withGlobalScope {
                entered.signal()
                await release.wait()
              }
              return nil
            } catch {
              return error as? TatwoGoalStoreLockOrderError
            }
          }
          childBox.set(child)
          XCTAssertTrue(
            entered.wait(timeoutSeconds: 2),
            "Sync child did not acquire its active descendant lease")
          throw SyncBodyMarker.expected
        }
      }
      XCTFail("Expected composite body and release failure")
    } catch {
      receivedError = error
    }

    let composite = receivedError as? TatwoGoalStoreLockScopeCompositeError
    XCTAssertEqual(composite?.bodyError as? SyncBodyMarker, .expected)
    XCTAssertEqual(
      composite?.releaseError,
      .nonLIFORelease(expected: .global, attempted: .lifecycle))
    let snapshot = requireState(stateBox.get()).debugSnapshot()
    XCTAssertEqual(snapshot.phase, .poisoned)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)

    await release.signal()
    let childError = await requireTask(childBox.get()).value
    guard case .staleGeneration = childError else {
      return XCTFail("Expected staleGeneration, got \(String(describing: childError))")
    }
  }

  func testAsyncBodyAndReleaseFailuresArePreservedAsComposite() async {
    let entered = AsyncGate()
    let release = AsyncGate()
    let childBox = LockedBox<Task<TatwoGoalStoreLockOrderError?, Never>?>(nil)
    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    var receivedError: Error?

    do {
      try await TatwoGoalStoreLockOrder.withOperation {
        stateBox.set(TatwoGoalStoreLockOrder.currentStateForTesting)
        try await TatwoGoalStoreLockOrder.withLifecycleScope {
          let child = Task { () -> TatwoGoalStoreLockOrderError? in
            do {
              try await TatwoGoalStoreLockOrder.withGlobalScope {
                await entered.signal()
                await release.wait()
              }
              return nil
            } catch {
              return error as? TatwoGoalStoreLockOrderError
            }
          }
          childBox.set(child)
          await entered.wait()
          throw AsyncBodyMarker.expected
        }
      }
      XCTFail("Expected composite body and release failure")
    } catch {
      receivedError = error
    }

    let composite = receivedError as? TatwoGoalStoreLockScopeCompositeError
    XCTAssertEqual(composite?.bodyError as? AsyncBodyMarker, .expected)
    XCTAssertEqual(
      composite?.releaseError,
      .nonLIFORelease(expected: .global, attempted: .lifecycle))
    let snapshot = requireState(stateBox.get()).debugSnapshot()
    XCTAssertEqual(snapshot.phase, .poisoned)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)

    await release.signal()
    let childError = await requireTask(childBox.get()).value
    guard case .staleGeneration = childError else {
      return XCTFail("Expected staleGeneration, got \(String(describing: childError))")
    }
  }

  func testCloseAcquireRaceHasOnlyLinearizedOutcomes() async {
    for _ in 0..<40 {
      let state = TatwoGoalStoreLockOrder.OperationState(mode: .standard)
      let root = state.rootCursor()
      let start = AsyncGate()
      let closeFinished = AsyncGate()

      let closeTask = Task { () -> TatwoGoalStoreLockOrderError? in
        await start.wait()
        do {
          try state.finishRootAfterSuccess(root)
          await closeFinished.signal()
          return nil
        } catch {
          await closeFinished.signal()
          return error as? TatwoGoalStoreLockOrderError
        }
      }
      let acquireTask = Task { () -> Bool in
        await start.wait()
        do {
          let child = try state.acquire(from: root, kind: .lifecycle)
          await closeFinished.wait()
          try? state.release(child)
          return true
        } catch {
          return false
        }
      }

      await start.signal()
      let closeError = await closeTask.value
      let bodyRan = await acquireTask.value
      let snapshot = state.debugSnapshot()

      if closeError == nil {
        XCTAssertFalse(bodyRan)
        XCTAssertEqual(snapshot.phase, .closed)
        XCTAssertEqual(snapshot.activeLeaseCount, 0)
      } else {
        XCTAssertEqual(
          closeError,
          .operationClosedWithActiveLeases(count: 1))
        XCTAssertTrue(bodyRan)
        XCTAssertEqual(snapshot.phase, .poisoned)
        XCTAssertEqual(snapshot.activeLeaseCount, 0)
      }
    }
  }

  func testThrowClosesStateAndInvalidatesCapturedCursor() throws {
    enum Marker: Error { case expected }

    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    let cursorBox = LockedBox<TatwoGoalStoreLockOrder.Cursor?>(nil)

    XCTAssertThrowsError(
      try TatwoGoalStoreLockOrder.withOperation {
        let state = requireState(TatwoGoalStoreLockOrder.currentStateForTesting)
        stateBox.set(state)
        cursorBox.set(state.rootCursor())
        try TatwoGoalStoreLockOrder.withLifecycleScope {
          throw Marker.expected
        }
      }
    ) { error in
      XCTAssertTrue(error is Marker)
    }

    let state = requireState(stateBox.get())
    let snapshot = state.debugSnapshot()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)
    XCTAssertThrowsError(
      try state.acquire(
        from: requireCursor(cursorBox.get()),
        kind: .lifecycle)
    ) { error in
      guard case .staleGeneration = error as? TatwoGoalStoreLockOrderError else {
        return XCTFail("Expected staleGeneration, got \(error)")
      }
    }
    XCTAssertEqual(TatwoGoalStoreLockOrder.heldKinds, [])
    XCTAssertNil(TatwoGoalStoreLockOrder.activeOperationMode)
  }

  func testCancellationClosesStateAndInvalidatesCapturedCursor() async {
    let entered = AsyncGate()
    let proceed = AsyncGate()
    let stateBox = LockedBox<TatwoGoalStoreLockOrder.OperationState?>(nil)
    let cursorBox = LockedBox<TatwoGoalStoreLockOrder.Cursor?>(nil)

    let task = Task { () -> Error? in
      do {
        try await TatwoGoalStoreLockOrder.withOperation {
          guard let state = TatwoGoalStoreLockOrder.currentStateForTesting else {
            fatalError("Expected operation state")
          }
          stateBox.set(state)
          cursorBox.set(state.rootCursor())
          try await TatwoGoalStoreLockOrder.withLifecycleScope {
            await entered.signal()
            await proceed.wait()
            try Task.checkCancellation()
          }
        }
        return nil
      } catch {
        return error
      }
    }

    await entered.wait()
    task.cancel()
    await proceed.signal()
    let error = await task.value
    XCTAssertTrue(error is CancellationError)

    let state = requireState(stateBox.get())
    let snapshot = state.debugSnapshot()
    XCTAssertEqual(snapshot.phase, .closed)
    XCTAssertEqual(snapshot.activeLeaseCount, 0)
    XCTAssertThrowsError(
      try state.acquire(
        from: requireCursor(cursorBox.get()),
        kind: .lifecycle)
    ) { error in
      guard case .staleGeneration = error as? TatwoGoalStoreLockOrderError else {
        return XCTFail("Expected staleGeneration, got \(error)")
      }
    }
  }

  func testDetachedTaskHasNoCursorAndBodyDoesNotRun() async throws {
    let bodyCount = AsyncCounter()

    try await TatwoGoalStoreLockOrder.withOperation {
      try await TatwoGoalStoreLockOrder.withLifecycleScope {
        let error = await Task.detached {
          do {
            try await TatwoGoalStoreLockOrder.withGlobalScope {
              await bodyCount.increment()
            }
            return Optional<TatwoGoalStoreLockOrderError>.none
          } catch {
            return error as? TatwoGoalStoreLockOrderError
          }
        }.value
        XCTAssertEqual(error, .missingOperationContext(requested: .global))
        let finalBodyCount = await bodyCount.read()
        XCTAssertEqual(finalBodyCount, 0)
      }
    }
  }

  func testManualReleaseValidationRejectsNonLIFODoubleAndForgedCursors() throws {
    let nonLIFOState = TatwoGoalStoreLockOrder.OperationState(mode: .standard)
    let nonLIFORoot = nonLIFOState.rootCursor()
    let nonLIFOLifecycle = try nonLIFOState.acquire(
      from: nonLIFORoot,
      kind: .lifecycle)
    _ = try nonLIFOState.acquire(from: nonLIFOLifecycle, kind: .global)
    XCTAssertThrowsError(try nonLIFOState.release(nonLIFOLifecycle)) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .nonLIFORelease(expected: .global, attempted: .lifecycle))
    }
    XCTAssertEqual(nonLIFOState.debugSnapshot().phase, .poisoned)
    XCTAssertEqual(nonLIFOState.debugSnapshot().activeLeaseCount, 0)

    let doubleState = TatwoGoalStoreLockOrder.OperationState(mode: .standard)
    let doubleRoot = doubleState.rootCursor()
    let doubleLifecycle = try doubleState.acquire(
      from: doubleRoot,
      kind: .lifecycle)
    try doubleState.release(doubleLifecycle)
    XCTAssertThrowsError(try doubleState.release(doubleLifecycle)) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .doubleRelease(kind: .lifecycle))
    }

    let identityState = TatwoGoalStoreLockOrder.OperationState(mode: .standard)
    let identityRoot = identityState.rootCursor()
    let wrongOperation = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: UUID(),
      generation: identityRoot.generation,
      cursorID: UUID(),
      path: identityRoot.path)
    XCTAssertThrowsError(
      try identityState.acquire(from: wrongOperation, kind: .lifecycle)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperation(
          expected: identityState.operationID,
          actual: wrongOperation.operationID))
    }

    let wrongGeneration = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: identityRoot.operationID,
      generation: identityRoot.generation &+ 1,
      cursorID: UUID(),
      path: identityRoot.path)
    XCTAssertThrowsError(
      try identityState.acquire(from: wrongGeneration, kind: .lifecycle)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .staleGeneration(
          expected: identityRoot.generation,
          actual: wrongGeneration.generation))
    }

    let lifecycle = try identityState.acquire(
      from: identityRoot,
      kind: .lifecycle)
    let wrongOperationRelease = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: UUID(),
      generation: lifecycle.generation,
      cursorID: UUID(),
      path: lifecycle.path)
    XCTAssertThrowsError(
      try identityState.release(wrongOperationRelease)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperation(
          expected: identityState.operationID,
          actual: wrongOperationRelease.operationID))
    }
    XCTAssertEqual(identityState.debugSnapshot().activeLeaseCount, 1)

    let wrongGenerationRelease = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: lifecycle.operationID,
      generation: lifecycle.generation &+ 1,
      cursorID: UUID(),
      path: lifecycle.path)
    XCTAssertThrowsError(
      try identityState.release(wrongGenerationRelease)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .staleGeneration(
          expected: lifecycle.generation,
          actual: wrongGenerationRelease.generation))
    }
    XCTAssertEqual(identityState.debugSnapshot().activeLeaseCount, 1)

    let lifecycleReference = requireReference(lifecycle.path.last)
    let wrongTokenReference = TatwoGoalStoreLockOrder.LeaseReference(
      token: UUID(),
      parentToken: lifecycleReference.parentToken,
      kind: lifecycleReference.kind,
      recordID: lifecycleReference.recordID)
    let wrongToken = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: lifecycle.operationID,
      generation: lifecycle.generation,
      cursorID: UUID(),
      path: [wrongTokenReference])
    XCTAssertThrowsError(try identityState.release(wrongToken)) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .releaseTokenMismatch(kind: .lifecycle))
    }
    XCTAssertEqual(identityState.debugSnapshot().activeLeaseCount, 1)

    let global = try identityState.acquire(from: lifecycle, kind: .global)
    let globalReference = requireReference(global.path.last)
    let wrongParentReference = TatwoGoalStoreLockOrder.LeaseReference(
      token: globalReference.token,
      parentToken: nil,
      kind: globalReference.kind,
      recordID: globalReference.recordID)
    let wrongParent = TatwoGoalStoreLockOrder.Cursor(
      state: identityState,
      operationID: global.operationID,
      generation: global.generation,
      cursorID: UUID(),
      path: [lifecycleReference, wrongParentReference])
    XCTAssertThrowsError(try identityState.release(wrongParent)) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .parentLeaseMismatch(kind: .global))
    }
    XCTAssertEqual(identityState.debugSnapshot().activeLeaseCount, 2)

    try identityState.release(global)
    try identityState.release(lifecycle)
    try identityState.finishRootAfterSuccess(identityRoot)
  }

  func testCrossOperationStateCursorFailsAcquireReleaseAndRootValidation() throws {
    let operationID = UUID()
    let first = TatwoGoalStoreLockOrder.OperationState(
      operationID: operationID,
      mode: .standard)
    let second = TatwoGoalStoreLockOrder.OperationState(
      operationID: operationID,
      mode: .standard)
    let firstRoot = first.rootCursor()
    let secondRoot = second.rootCursor()

    XCTAssertThrowsError(
      try second.acquire(from: firstRoot, kind: .lifecycle)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperationState)
    }
    XCTAssertEqual(first.debugSnapshot().activeLeaseCount, 0)
    XCTAssertEqual(second.debugSnapshot().activeLeaseCount, 0)

    let firstLifecycle = try first.acquire(
      from: firstRoot,
      kind: .lifecycle)
    XCTAssertThrowsError(try second.release(firstLifecycle)) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperationState)
    }
    XCTAssertEqual(first.debugSnapshot().activeLeaseCount, 1)
    XCTAssertEqual(second.debugSnapshot().activeLeaseCount, 0)

    XCTAssertThrowsError(
      try second.finishRootAfterSuccess(firstRoot)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperationState)
    }
    XCTAssertEqual(second.debugSnapshot().phase, .open)
    XCTAssertEqual(second.debugSnapshot().activeLeaseCount, 0)

    XCTAssertThrowsError(
      try second.finishRootAfterFailure(firstRoot)
    ) { error in
      XCTAssertEqual(
        error as? TatwoGoalStoreLockOrderError,
        .wrongOperationState)
    }
    XCTAssertEqual(second.debugSnapshot().phase, .open)
    XCTAssertEqual(second.debugSnapshot().activeLeaseCount, 0)

    try first.release(firstLifecycle)
    try first.finishRootAfterSuccess(firstRoot)
    try second.finishRootAfterSuccess(secondRoot)
  }

  func testLexicalCursorsShareStateButHaveDistinctCursorIDs() async throws {
    try await TatwoGoalStoreLockOrder.withOperation {
      let rootIdentity = requireIdentity(TatwoGoalStoreLockOrder.debugIdentity)
      try await TatwoGoalStoreLockOrder.withLifecycleScope {
        let lifecycleIdentity = requireIdentity(
          TatwoGoalStoreLockOrder.debugIdentity)
        XCTAssertEqual(lifecycleIdentity.stateID, rootIdentity.stateID)
        XCTAssertNotEqual(lifecycleIdentity.cursorID, rootIdentity.cursorID)

        let identities = try await Task {
          guard let inherited = TatwoGoalStoreLockOrder.debugIdentity else {
            fatalError("Expected inherited debug identity")
          }
          let nested = try TatwoGoalStoreLockOrder.withGlobalScope {
            guard let identity = TatwoGoalStoreLockOrder.debugIdentity else {
              fatalError("Expected nested debug identity")
            }
            return identity
          }
          return (inherited, nested)
        }.value

        XCTAssertEqual(identities.0.stateID, lifecycleIdentity.stateID)
        XCTAssertEqual(identities.0.cursorID, lifecycleIdentity.cursorID)
        XCTAssertEqual(identities.1.stateID, lifecycleIdentity.stateID)
        XCTAssertNotEqual(identities.1.cursorID, lifecycleIdentity.cursorID)
        XCTAssertEqual(identities.1.heldKinds, [.lifecycle, .global])
      }
    }
  }

  func testBootstrapScopeRemainsNarrowAndRequiresHeldGlobal() throws {
    try TatwoGoalStoreLockOrder.withOperation(mode: .lifecycleBootstrap) {
      XCTAssertThrowsError(
        try TatwoGoalStoreLockOrder.withLifecycleBootstrapScope {}
      ) { error in
        XCTAssertEqual(
          error as? TatwoGoalStoreLockOrderError,
          .bootstrapRequiresHeldGlobal(held: []))
      }

      try TatwoGoalStoreLockOrder.withGlobalScope {
        try TatwoGoalStoreLockOrder.withLifecycleBootstrapScope {
          XCTAssertEqual(
            TatwoGoalStoreLockOrder.heldKinds,
            [.global, .lifecycleBootstrap])
        }
      }
    }

    try TatwoGoalStoreLockOrder.withOperation(mode: .globalOnly) {
      try TatwoGoalStoreLockOrder.withGlobalScope {
        XCTAssertThrowsError(
          try TatwoGoalStoreLockOrder.withLifecycleBootstrapScope {}
        ) { error in
          XCTAssertEqual(
            error as? TatwoGoalStoreLockOrderError,
            .bootstrapNotAllowed(mode: .globalOnly))
        }
      }
    }
  }

  private func requireTask<T: Sendable>(
    _ task: Task<T, Never>?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Task<T, Never> {
    guard let task else {
      XCTFail("Expected task", file: file, line: line)
      fatalError("Expected task")
    }
    return task
  }

  private func requireState(
    _ state: TatwoGoalStoreLockOrder.OperationState?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> TatwoGoalStoreLockOrder.OperationState {
    guard let state else {
      XCTFail("Expected operation state", file: file, line: line)
      fatalError("Expected operation state")
    }
    return state
  }

  private func requireCursor(
    _ cursor: TatwoGoalStoreLockOrder.Cursor?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> TatwoGoalStoreLockOrder.Cursor {
    guard let cursor else {
      XCTFail("Expected cursor", file: file, line: line)
      fatalError("Expected cursor")
    }
    return cursor
  }

  private func requireReference(
    _ reference: TatwoGoalStoreLockOrder.LeaseReference?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> TatwoGoalStoreLockOrder.LeaseReference {
    guard let reference else {
      XCTFail("Expected lease reference", file: file, line: line)
      fatalError("Expected lease reference")
    }
    return reference
  }

  private func requireIdentity(
    _ identity: TatwoGoalStoreLockOrder.DebugIdentity?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> TatwoGoalStoreLockOrder.DebugIdentity {
    guard let identity else {
      XCTFail("Expected debug identity", file: file, line: line)
      fatalError("Expected debug identity")
    }
    return identity
  }
}

private enum SyncBodyMarker: Error, Equatable, Sendable {
  case expected
}

private enum AsyncBodyMarker: Error, Equatable, Sendable {
  case expected
}

private actor AsyncGate {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isSignaled { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func signal() {
    guard !isSignaled else { return }
    isSignaled = true
    let pending = waiters
    waiters.removeAll(keepingCapacity: false)
    for continuation in pending {
      continuation.resume()
    }
  }
}

private actor IdentityRecorder {
  private var identities: [TatwoGoalStoreLockOrder.DebugIdentity] = []

  func record(_ identity: TatwoGoalStoreLockOrder.DebugIdentity) {
    identities.append(identity)
  }

  func read() -> [TatwoGoalStoreLockOrder.DebugIdentity] {
    identities
  }
}

private actor AsyncCounter {
  private var value = 0

  func increment() {
    value += 1
  }

  func read() -> Int {
    value
  }
}

private final class BlockingSignal: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)

  func signal() {
    semaphore.signal()
  }

  func wait(timeoutSeconds: Double) -> Bool {
    semaphore.wait(
      timeout: .now() + timeoutSeconds) == .success
  }
}

private final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ newValue: Value) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
}
