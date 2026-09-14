import Foundation
import ApplicationServices

struct ComputerUseFailure: Error, LocalizedError {
    let code: String
    var errorDescription: String? { code }
    init(_ code: String) { self.code = code }
}

/// The App owns this grant. Tool arguments can present a token, never create one.
/// Kept separate from the socket/model queues so local stop cannot queue behind AX
/// capture, a model response, or the MCP transport timeout.
final class ComputerUseSession: @unchecked Sendable {
    enum Lane: String, Sendable {
        case externalApplication
        case builtInBrowser
    }

    struct Grant: Equatable, Sendable {
        let id: UUID
        let owner: UUID
        let scope: String
        let pid: Int32
        let lane: Lane
        let epoch: UInt64
        let expiresAt: TimeInterval
    }
    struct Observation: @unchecked Sendable {
        let id: UUID
        let fingerprint: String
        let capturedAt: TimeInterval
        let imageWidth: Int
        let imageHeight: Int
        let elements: [AXUIElement]
        let state: ComputerUseNative.State?

        func element(at index: Int) throws -> AXUIElement {
            guard elements.indices.contains(index) else { throw ComputerUseFailure("computer_element_stale") }
            return elements[index]
        }
    }

    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var grant: Grant?
    /// After the operated App dies mid-session its grant is cleared; for a short window afterwards a
    /// follow-up call gets the clear computer_target_closed instead of the ambiguous consent_required,
    /// so the model reports "the App closed" rather than "re-consent" (CU10 appclose 2026-09-11).
    private var targetClosedUntil: TimeInterval = 0
    private var observation: Observation?
    // The consumed observation is also the action identity. A late callback
    // must not dispatch under, or clear, a newer action within the same grant.
    private var activeObservationID: UUID?

    var currentEpoch: UInt64 { locked { epoch } }

    func authorize(owner: UUID, scope: String, pid: Int32, expectedEpoch: UInt64,
                   lane: Lane = .externalApplication,
                   expiresAt: TimeInterval? = nil,
                   now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Grant {
        try locked {
            guard epoch == expectedEpoch else { throw ComputerUseFailure("computer_consent_cancelled") }
            guard grant == nil, pid > 1, (expiresAt ?? .greatestFiniteMagnitude) > now else { throw ComputerUseFailure("computer_busy_or_invalid_target") }
            epoch &+= 1
            targetClosedUntil = 0
            let value = Grant(id: UUID(), owner: owner, scope: scope, pid: pid,
                              lane: lane, epoch: epoch, expiresAt: expiresAt ?? .greatestFiniteMagnitude)
            grant = value
            return value
        }
    }

    func require(owner: UUID, scope: String, token: String,
                 lane: Lane = .externalApplication,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Grant {
        try locked {
            guard let grant, grant.owner == owner, grant.scope == scope,
                  grant.id.uuidString == token, grant.epoch == epoch, now < grant.expiresAt,
                  grant.lane == lane
            else { throw ComputerUseFailure(now < targetClosedUntil ? "computer_target_closed" : "computer_consent_required") }
            return grant
        }
    }

    func publish(fingerprint: String, for expected: Grant, imageWidth: Int = 0, imageHeight: Int = 0,
                 elements: [AXUIElement] = [], state: ComputerUseNative.State? = nil,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Observation {
        try locked {
            try check(expected, now: now)
            guard activeObservationID == nil else { throw ComputerUseFailure("computer_action_in_flight") }
            guard (imageWidth == 0 && imageHeight == 0)
                || ((1...2048).contains(imageWidth) && (1...2048).contains(imageHeight)) else {
                throw ComputerUseFailure("computer_invalid_capture_geometry")
            }
            let value = Observation(id: UUID(), fingerprint: fingerprint, capturedAt: now,
                                    imageWidth: imageWidth, imageHeight: imageHeight, elements: elements, state: state)
            observation = value
            return value
        }
    }

    @discardableResult
    func beginAction(observationID: String, fingerprint: String, for expected: Grant,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Observation {
        try locked {
            try check(expected, now: now)
            guard activeObservationID == nil, let observed = observation,
                  observed.id.uuidString == observationID
            else { throw ComputerUseFailure(expected.lane == .externalApplication
                ? "computer_stale_observation" : "computer_observe_again") }
            if expected.lane == .builtInBrowser {
                guard now >= observed.capturedAt, now - observed.capturedAt <= 30,
                      observed.fingerprint == fingerprint else {
                    // Preserve the browser's existing fingerprint/age gate.
                    // A wrong token cannot erase a newer observation.
                    observation = nil
                    throw ComputerUseFailure("computer_observe_again")
                }
            }
            // Consumed before the first event, including on partial delivery/failure.
            observation = nil
            activeObservationID = observed.id
            return observed
        }
    }

    func endAction(observationID: UUID, for expected: Grant) {
        locked {
            if grant == expected, activeObservationID == observationID {
                activeObservationID = nil
            }
        }
    }

    /// Dispatch only tiny native event pairs here, never AX, I/O, waits or awaits.
    /// Revocation and dispatch are ordered by this same lock.
    func dispatch<T>(observationID: UUID, for expected: Grant, _ body: () throws -> T) throws -> T {
        try locked {
            try check(expected, now: ProcessInfo.processInfo.systemUptime)
            guard activeObservationID == observationID else { throw ComputerUseFailure("computer_observe_again") }
            return try body()
        }
    }

    /// Observed browser actions may have multiple bounded native stages. Each
    /// stage must retain the original request and this consumed observation ID;
    /// cleanup ends only that action. Backend callbacks must never re-enter the
    /// session lock synchronously from body.
    func dispatchObservedBrowser<T>(observationID: UUID, for expected: Grant,
                                    _ body: () throws -> T) throws -> T {
        guard expected.lane == .builtInBrowser else {
            throw ComputerUseFailure("browser_input_lane_unavailable")
        }
        return try dispatch(observationID: observationID, for: expected, body)
    }

    /// Existing browser DOM/navigation commands only enqueue bounded local
    /// work here. No waits, capture, or callbacks inside this lock. This orders
    /// their dispatch against local Stop and the shared input owner; it does
    /// not replace the observation-consumption requirement for native gestures.
    func dispatchBrowser<T>(for expected: Grant, _ body: () throws -> T) throws -> T {
        try locked {
            try check(expected, now: ProcessInfo.processInfo.systemUptime)
            guard expected.lane == .builtInBrowser, activeObservationID == nil else {
                throw ComputerUseFailure("browser_input_lane_unavailable")
            }
            // Navigation/DOM input can change pixels or element targets even
            // when enqueue later throws or delivery is uncertain. Invalidate
            // before invoking the backend, never resurrect on failure.
            observation = nil
            return try body()
        }
    }

    func validate(_ expected: Grant) throws {
        try locked { try check(expected, now: ProcessInfo.processInfo.systemUptime) }
    }

    func stop(owner: UUID? = nil) {
        locked {
            guard owner == nil || grant == nil || grant?.owner == owner else { return }
            epoch &+= 1
            grant = nil
            observation = nil
            activeObservationID = nil
        }
    }

    /// Mark that the operated App just died, so a follow-up call gets computer_target_closed (not
    /// consent_required) for the next 30 s. Cleared by the next reserve().
    func markTargetClosed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        locked { targetClosedUntil = now + 30 }
    }

    func stop(ifCurrent expected: Grant) {
        locked {
            guard grant == expected else { return }
            epoch &+= 1
            grant = nil
            observation = nil
            activeObservationID = nil
        }
    }

    private func check(_ expected: Grant, now: TimeInterval) throws {
        guard grant == expected, epoch == expected.epoch, now < expected.expiresAt else {
            throw ComputerUseFailure("computer_stopped_or_expired")
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
