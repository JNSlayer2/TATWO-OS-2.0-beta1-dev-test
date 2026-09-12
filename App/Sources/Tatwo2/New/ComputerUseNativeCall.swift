import Foundation

/// Framework objects cross their documented completion handler back to the
/// MainActor; they are not shared with the input worker.
struct ComputerUseNativeValue<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A timed-out framework call may still be running. Release its waiting MCP
/// request, but retain the single native slot until the actual callback arrives.
/// This prevents both an indefinitely occupied bridge slot and unbounded retry
/// calls into an unresponsive framework. Stop never pretends to cancel that I/O.
@MainActor
final class ComputerUseNativeCall {
    private(set) var pendingID: UUID?

    func run<Value: Sendable>(
        deadline: TimeInterval,
        name: String,
        start: (@escaping @Sendable (Value?, Error?) -> Void) -> Void
    ) async throws -> Value {
        guard pendingID == nil else { throw ComputerUseFailure("computer_native_operation_still_pending") }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ComputerUseFailure("computer_request_deadline_exceeded") }
        let id = UUID()
        pendingID = id
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ComputerUseNativeReply<Value>(continuation)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remaining) {
                reply.finish(.failure(ComputerUseFailure("computer_\(name)_timeout_delivery_unknown")))
            }
            start { [weak self] value, error in
                Task { @MainActor in
                    if self?.pendingID == id { self?.pendingID = nil }
                    if let error { reply.finish(.failure(error)) }
                    else if let value { reply.finish(.success(value)) }
                    else { reply.finish(.failure(ComputerUseFailure("computer_\(name)_empty_result"))) }
                }
            }
        }
    }
}

private final class ComputerUseNativeReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
