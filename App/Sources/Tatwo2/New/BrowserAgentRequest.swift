import Foundation
import CryptoKit

struct BrowserAgentRequestError: Error, CustomStringConvertible {
    let description: String
    init(_ code: String) { description = code }
}

/// A single socket request's identity and lifetime, not an input grant.
/// Capture this object in callbacks; never look up a later request's context.
final class BrowserAgentRequest: @unchecked Sendable {
    let caller: UUID
    let scope: String
    let epoch: UInt64
    let deadline: TimeInterval
    let clientFD: Int32
    let inputGrant: ComputerUseSession.Grant?
    let observationID: UUID?
    let pageTools: Bool
    let aiVaultLogin: Bool
    private let lock = NSLock()
    private var finished = false

    init(caller: UUID, scope: String, epoch: UInt64, clientFD: Int32 = -1,
         inputGrant: ComputerUseSession.Grant? = nil,
         observationID: UUID? = nil,
         pageTools: Bool = false,
         aiVaultLogin: Bool = false,
         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.caller = caller
        self.scope = scope
        self.epoch = epoch
        self.clientFD = clientFD
        self.inputGrant = inputGrant
        self.observationID = observationID
        self.pageTools = pageTools
        self.aiVaultLogin = aiVaultLogin
        // WebMCP may spend 20 seconds at Island followed by a 30-second renderer
        // call. Keep the native-input lane's existing 40-second lifetime.
        self.deadline = now + (pageTools ? 60 : 40)
    }

    static func caller(from params: [String: Any]) throws -> UUID {
        guard let raw = params["callerThreadID"] as? String, let caller = UUID(uuidString: raw) else {
            throw BrowserAgentRequestError("browser_caller_required")
        }
        return caller
    }

    static func observationID(for method: String, params: [String: Any]) throws -> UUID? {
        if observedActions.contains(method) {
            guard let raw = params["observationID"] as? String,
                  let id = UUID(uuidString: raw),
                  id.uuidString.caseInsensitiveCompare(raw) == .orderedSame else {
                throw BrowserAgentRequestError("browser_observation_required")
            }
            return id
        }
        guard params["observationID"] == nil else {
            throw BrowserAgentRequestError("browser_unexpected_observation")
        }
        return nil
    }

    static let observedActions: Set<String> = [
        "browser_click", "browser_type", "browser_scroll", "browser_drag", "browser_press_key", "browser_select"
    ]

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }

    func validate(currentScope: String?, currentEpoch: UInt64, connected: Bool,
                  now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, currentEpoch == epoch else {
            throw BrowserAgentRequestError("browser_request_revoked")
        }
        guard connected else { throw BrowserAgentRequestError("browser_request_disconnected") }
        guard now < deadline else { throw BrowserAgentRequestError("browser_request_timed_out") }
        guard currentScope == scope else { throw BrowserAgentRequestError("browser_chat_context_changed") }
    }
}

/// Internal state digest, never page-provided authority or model-visible raw
/// DOM. Preserve ordered page content but canonicalize unordered form maps.
enum BrowserAgentSnapshotFingerprint {
    static func make(snapshot: [String: Any], surfaceID: UUID, navigationID: String,
                     url: String, geometry: [Double]) throws -> String {
        guard !navigationID.isEmpty, !geometry.isEmpty, geometry.allSatisfy(\.isFinite) else {
            throw BrowserAgentRequestError("browser_geometry_unavailable")
        }
        guard JSONSerialization.isValidJSONObject(snapshot) else {
            throw BrowserAgentRequestError("browser_snapshot_invalid")
        }
        var canonical = snapshot
        if let forms = snapshot["forms"] as? [[String: Any]] {
            canonical["forms"] = try forms.map { form -> (Data, [String: Any]) in
                (try JSONSerialization.data(withJSONObject: form, options: [.sortedKeys]), form)
            }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 }
        }
        let value: [String: Any] = [
            "surface": surfaceID.uuidString, "navigation": navigationID,
            "url": url, "geometry": geometry, "snapshot": canonical,
        ]
        guard JSONSerialization.isValidJSONObject(value) else {
            throw BrowserAgentRequestError("browser_snapshot_invalid")
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw BrowserAgentRequestError("browser_snapshot_too_large")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Carries one original navigation through both the SwiftUI mount and the
/// direct bridge path. This is deduplication, not authority: consume only inside
/// the originating request's validated input gate.
final class BrowserAgentNavigation: @unchecked Sendable {
    let url: URL
    let request: BrowserAgentRequest
    private let lock = NSLock()
    private var attempted = false

    init(url: URL, request: BrowserAgentRequest) {
        self.url = url
        self.request = request
    }

    static func validateDestination(_ url: URL) throws {
        switch EmbeddedBrowserNavigationPolicy.decision(for: url, actor: .strict) {
        case .allow: return
        case let .block(reason):
            throw BrowserAgentRequestError("browser_navigation_blocked_by_policy: " +
                EmbeddedBrowserVisibleError.blockedNavigation(reason).message)
        case .askOncePerHost:
            throw BrowserAgentRequestError("browser_navigation_blocked_by_policy")
        }
    }

    /// Attempt bookkeeping only, never permission or proof of a loaded page.
    var hasAttempted: Bool {
        lock.lock(); defer { lock.unlock() }
        return attempted
    }

    /// Keep the socket request alive while native creation is pending. Finishing
    /// it as soon as an NSView exists would revoke its still-queued navigation.
    /// This runs on the bridge worker, never while holding the local input lock.
    func waitForAttempt(
        timeout: TimeInterval = 15,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        validate: () throws -> Void
    ) throws {
        let deadline = min(request.deadline, now() + max(0, timeout))
        while true {
            try validate()
            if hasAttempted { return }
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw BrowserAgentRequestError("browser_navigation_dispatch_timed_out")
            }
            sleep(min(0.05, remaining))
        }
    }

    func consumeAttempt(for actualURL: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard actualURL.absoluteString == url.absoluteString else {
            throw BrowserAgentRequestError("browser_navigation_target_changed")
        }
        guard !attempted else { return false }
        // Consume before native enqueue. An exception is not proof that the
        // navigation never reached the backend, so do not automatically retry.
        attempted = true
        return true
    }
}
