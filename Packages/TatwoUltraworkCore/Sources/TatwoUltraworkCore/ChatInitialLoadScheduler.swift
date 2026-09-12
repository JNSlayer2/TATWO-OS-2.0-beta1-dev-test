import Foundation

public struct TatwoChatInitialLoadScheduler: Sendable {
  public init() {}

  public func start<Value: Sendable>(
    priority: TaskPriority = .userInitiated,
    operation: @escaping @Sendable () -> Value
  ) -> Task<Value, Never> {
    Task.detached(priority: priority, operation: operation)
  }
}

@MainActor
public final class TatwoLatestAsyncLoadController<Value: Sendable> {
  public typealias Operation = @Sendable () async throws -> Value
  public typealias Apply = @MainActor (Value) -> Void

  private struct Request {
    let id: UInt64
    let priority: TaskPriority
    let operation: Operation
    let apply: Apply
  }

  public private(set) var isLoading = false

  private let onLoadingChanged: @MainActor (Bool) -> Void
  private var latestRequestID: UInt64 = 0
  private var pendingRequest: Request?
  private var currentChild: Task<Value, Error>?
  private var workerTask: Task<Void, Never>?

  public init(onLoadingChanged: @escaping @MainActor (Bool) -> Void = { _ in }) {
    self.onLoadingChanged = onLoadingChanged
  }

  public func start(
    priority: TaskPriority = .userInitiated,
    operation: @escaping Operation,
    apply: @escaping Apply
  ) {
    latestRequestID &+= 1
    pendingRequest = Request(
      id: latestRequestID,
      priority: priority,
      operation: operation,
      apply: apply)
    setLoading(true)
    currentChild?.cancel()
    guard workerTask == nil else { return }
    workerTask = Task { @MainActor [weak self] in
      await self?.drainRequests()
    }
  }

  public func cancel() {
    latestRequestID &+= 1
    pendingRequest = nil
    currentChild?.cancel()
    setLoading(false)
  }

  private func drainRequests() async {
    while !Task.isCancelled, let request = pendingRequest {
      pendingRequest = nil
      let operation = request.operation
      let child = Task.detached(priority: request.priority) {
        try Task.checkCancellation()
        let value = try await operation()
        try Task.checkCancellation()
        return value
      }
      currentChild = child
      let result = await withTaskCancellationHandler {
        await child.result
      } onCancel: {
        child.cancel()
      }
      currentChild = nil

      guard !Task.isCancelled else { break }
      guard request.id == latestRequestID, pendingRequest == nil else { continue }
      if case .success(let value) = result {
        request.apply(value)
      }
      setLoading(false)
    }

    workerTask = nil
    currentChild = nil
    if pendingRequest != nil, !Task.isCancelled {
      workerTask = Task { @MainActor [weak self] in
        await self?.drainRequests()
      }
    } else if pendingRequest == nil {
      setLoading(false)
    }
  }

  private func setLoading(_ value: Bool) {
    guard isLoading != value else { return }
    isLoading = value
    onLoadingChanged(value)
  }
}

@MainActor
public final class TatwoRetainedChatLifecycle {
  public private(set) var hasCreatedChat: Bool
  public private(set) var isContainerOpen = true

  private var stopHandler: (@MainActor () -> Void)?

  public init(initiallySelectedChat: Bool) {
    hasCreatedChat = initiallySelectedChat
  }

  public func registerStopHandler(_ handler: @escaping @MainActor () -> Void) {
    guard isContainerOpen else {
      if hasCreatedChat {
        handler()
      }
      return
    }
    stopHandler = handler
  }

  public func pageSelectionChanged(isChatSelected: Bool) {
    guard isContainerOpen else { return }
    if isChatSelected {
      hasCreatedChat = true
    }
  }

  @discardableResult
  public func closeContainer() -> Bool {
    guard isContainerOpen else { return false }
    isContainerOpen = false
    guard hasCreatedChat else { return false }
    stopHandler?()
    stopHandler = nil
    return true
  }
}
