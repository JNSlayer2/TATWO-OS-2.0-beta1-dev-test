import Foundation
import Testing
@testable import TatwoUltraworkCore

@Suite("Chat initial load scheduler")
struct ChatInitialLoadSchedulerTests {
  private enum ProbeError: Error {
    case expectedFailure
  }

  private final class FakeBridgeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func load(waitForRelease: () -> Void) -> (count: Int, ranOnMainThread: Bool) {
      lock.lock()
      invocationCount += 1
      let count = invocationCount
      lock.unlock()
      waitForRelease()
      return (count, Thread.isMainThread)
    }
  }

  @Test("initializer returns without synchronously waiting for bridge load")
  @MainActor
  func initializerDoesNotSynchronouslyWaitForBridgeLoad() async {
    let fakeBridge = FakeBridgeProbe()
    let releaseBridge = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
      releaseBridge.signal()
    }

    let startedAt = Date()
    let task = TatwoChatInitialLoadScheduler().start {
      fakeBridge.load {
        releaseBridge.wait()
      }
    }
    let returnLatency = Date().timeIntervalSince(startedAt)

    #expect(returnLatency < 0.15)
    let result = await task.value
    #expect(result.count == 1)
    #expect(result.ranOnMainThread == false)
  }

  private actor AsyncLoadProbe {
    private var activeCount = 0
    private var maxActiveCount = 0
    private var startedIDs: [String] = []
    private var cancelledIDs: [String] = []

    func run(id: String, delay: Duration) async throws -> String {
      activeCount += 1
      maxActiveCount = max(maxActiveCount, activeCount)
      startedIDs.append(id)
      defer { activeCount -= 1 }
      do {
        try await Task.sleep(for: delay)
        return id
      } catch {
        cancelledIDs.append(id)
        throw error
      }
    }

    func hasStarted(_ id: String) -> Bool {
      startedIDs.contains(id)
    }

    func hasCancelled(_ id: String) -> Bool {
      cancelledIDs.contains(id)
    }

    func snapshot() -> (started: [String], cancelled: [String], maxActive: Int) {
      (startedIDs, cancelledIDs, maxActiveCount)
    }
  }

  @Test("rapid starts cancel the active load, replace pending work, and apply only the latest value")
  @MainActor
  func rapidStartsAreSerializedAndLatestWins() async {
    let probe = AsyncLoadProbe()
    var appliedValues: [String] = []
    var loadingChanges: [Bool] = []
    let controller = TatwoLatestAsyncLoadController<String> { isLoading in
      loadingChanges.append(isLoading)
    }

    controller.start(
      operation: { try await probe.run(id: "first", delay: .seconds(5)) },
      apply: { appliedValues.append($0) })
    while !(await probe.hasStarted("first")) {
      await Task.yield()
    }

    controller.start(
      operation: { try await probe.run(id: "second", delay: .seconds(5)) },
      apply: { appliedValues.append($0) })
    controller.start(
      operation: { try await probe.run(id: "third", delay: .milliseconds(20)) },
      apply: { appliedValues.append($0) })

    while controller.isLoading {
      await Task.yield()
    }

    let snapshot = await probe.snapshot()
    #expect(appliedValues == ["third"])
    #expect(snapshot.started == ["first", "third"])
    #expect(snapshot.cancelled == ["first"])
    #expect(snapshot.maxActive == 1)
    #expect(loadingChanges == [true, false])
  }

  @Test("cancelling propagates to the detached child, suppresses apply, and settles loading")
  @MainActor
  func cancellationPropagatesAndSettlesLoading() async {
    let probe = AsyncLoadProbe()
    var appliedValues: [String] = []
    var loadingChanges: [Bool] = []
    let controller = TatwoLatestAsyncLoadController<String> { isLoading in
      loadingChanges.append(isLoading)
    }

    controller.start(
      operation: { try await probe.run(id: "cancelled", delay: .seconds(5)) },
      apply: { appliedValues.append($0) })
    while !(await probe.hasStarted("cancelled")) {
      await Task.yield()
    }

    controller.cancel()

    while !(await probe.hasCancelled("cancelled")) {
      await Task.yield()
    }

    #expect(controller.isLoading == false)
    #expect(appliedValues.isEmpty)
    #expect(loadingChanges == [true, false])
  }

  @Test("a load restarted immediately after cancellation drains the replacement without getting stuck")
  @MainActor
  func restartImmediatelyAfterCancellationStillAppliesReplacement() async throws {
    let probe = AsyncLoadProbe()
    var appliedValues: [String] = []
    let controller = TatwoLatestAsyncLoadController<String>()

    controller.start(
      operation: { try await probe.run(id: "cancelled", delay: .seconds(5)) },
      apply: { appliedValues.append($0) })
    while !(await probe.hasStarted("cancelled")) {
      await Task.yield()
    }

    controller.cancel()
    controller.start(
      operation: { try await probe.run(id: "replacement", delay: .milliseconds(20)) },
      apply: { appliedValues.append($0) })

    for _ in 0..<100 where controller.isLoading {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(controller.isLoading == false)
    #expect(appliedValues == ["replacement"])
    #expect(await probe.hasCancelled("cancelled"))
    #expect(await probe.hasStarted("replacement"))
  }

  @Test("a failed latest load settles loading without applying a value")
  @MainActor
  func failureSettlesLoading() async {
    var appliedValues: [String] = []
    var loadingChanges: [Bool] = []
    let controller = TatwoLatestAsyncLoadController<String> { isLoading in
      loadingChanges.append(isLoading)
    }

    controller.start(
      operation: { throw ProbeError.expectedFailure },
      apply: { appliedValues.append($0) })

    while controller.isLoading {
      await Task.yield()
    }

    #expect(appliedValues.isEmpty)
    #expect(loadingChanges == [true, false])
  }

  @Test("switching away from retained Chat does not stop, while closing its container stops once")
  @MainActor
  func retainedChatStopsOnlyWhenContainerCloses() {
    var stopCount = 0
    let lifecycle = TatwoRetainedChatLifecycle(initiallySelectedChat: true)
    lifecycle.registerStopHandler {
      stopCount += 1
    }

    lifecycle.pageSelectionChanged(isChatSelected: false)
    #expect(stopCount == 0)
    #expect(lifecycle.hasCreatedChat)

    #expect(lifecycle.closeContainer())
    #expect(stopCount == 1)
    #expect(lifecycle.closeContainer() == false)
    #expect(stopCount == 1)
  }

  @Test("a retained Chat registering during close teardown is stopped exactly once")
  @MainActor
  func lateLifecycleRegistrationStillStopsOnce() {
    var stopCount = 0
    let lifecycle = TatwoRetainedChatLifecycle(initiallySelectedChat: true)

    #expect(lifecycle.closeContainer())
    lifecycle.registerStopHandler {
      stopCount += 1
    }

    #expect(stopCount == 1)
    #expect(lifecycle.closeContainer() == false)
    #expect(stopCount == 1)
  }
}
