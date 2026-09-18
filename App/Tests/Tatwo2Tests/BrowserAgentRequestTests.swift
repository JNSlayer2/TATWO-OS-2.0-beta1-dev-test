import Foundation
import XCTest
@testable import Tatwo2

/// Pure request-lifetime and geometry checks; no browser, input, model or App launch.
final class BrowserAgentRequestTests: XCTestCase {
    private let caller = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    func testCEFClickUsesAnIntegerPointInsideFractionalTarget() throws {
        let point = try XCTUnwrap(BrowserAgentBridge.clickPoint(
            rect: ["x": 1.7, "y": 20.7, "width": 0.4, "height": 0.4],
            viewport: ["width": 200, "height": 100], size: NSSize(width: 200, height: 100)))
        // The former midpoint (1.9, 20.9) would truncate to (1, 20), outside.
        XCTAssertEqual(point, NSPoint(x: 2, y: 21))
        XCTAssertEqual(point.x, point.x.rounded())
        XCTAssertEqual(point.y, point.y.rounded())
    }

    func testCEFClickRejectsVisibleSliversWithoutRepresentablePoint() {
        for rect: [String: Any] in [
            ["x": 0.25, "y": 1, "width": 0.25, "height": 2],
            ["x": 10.25, "y": 1, "width": 0.5, "height": 2],
            ["x": 9.1, "y": 1, "width": 0.9, "height": 2],
            ["x": 1, "y": 1.25, "width": 2, "height": 0.5],
            ["x": 199.6, "y": 1, "width": 1, "height": 2],
        ] {
            XCTAssertNil(BrowserAgentBridge.clickPoint(rect: rect,
                viewport: ["width": 200, "height": 100], size: NSSize(width: 200, height: 100)))
        }
    }

    func testCEFClickClampsRoundingInsideHalfOpenVisibleBounds() {
        let viewport: [String: Any] = ["width": 200, "height": 100]
        let size = NSSize(width: 200, height: 100)
        XCTAssertEqual(BrowserAgentBridge.clickPoint(
            rect: ["x": 10, "y": 20, "width": 1, "height": 1], viewport: viewport, size: size),
            NSPoint(x: 10, y: 20))
        XCTAssertEqual(BrowserAgentBridge.clickPoint(
            rect: ["x": -0.8, "y": 18, "width": 1.1, "height": 2], viewport: viewport, size: size),
            NSPoint(x: 0, y: 19))
        XCTAssertEqual(BrowserAgentBridge.clickPoint(
            rect: ["x": -30, "y": 20, "width": 40, "height": 20], viewport: viewport, size: size),
            NSPoint(x: 5, y: 30))
    }

    func testCEFClickRejectsBooleanMalformedAndOverflowingGeometry() {
        let valid: [String: Any] = ["x": 10, "y": 20, "width": 40, "height": 20]
        let viewport: [String: Any] = ["width": 200, "height": 100]
        let size = NSSize(width: 200, height: 100)
        for key in ["x", "y", "width", "height"] {
            for value: Any in [true, "1", NSNull(), Double.nan, Double.infinity] {
                var rect = valid
                rect[key] = value
                XCTAssertNil(BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: size))
            }
        }
        for key in ["width", "height"] {
            var malformed = viewport
            malformed[key] = true
            XCTAssertNil(BrowserAgentBridge.clickPoint(rect: valid, viewport: malformed, size: size))
        }
        XCTAssertNil(BrowserAgentBridge.clickPoint(
            rect: ["x": Double.greatestFiniteMagnitude, "y": 1,
                   "width": Double.greatestFiniteMagnitude, "height": 2],
            viewport: viewport, size: size))
        XCTAssertNil(BrowserAgentBridge.clickPoint(rect: valid, viewport: viewport,
            size: NSSize(width: 210, height: 100)))
    }

    func testCEFClickCannotProduceCoordinatesOutsideNativeIntRange() {
        let boundary = Double(Int32.max)
        let viewport: [String: Any] = ["width": boundary + 100, "height": 100]
        let size = NSSize(width: boundary + 100, height: 100)
        XCTAssertNil(BrowserAgentBridge.clickPoint(
            rect: ["x": boundary + 10, "y": 20, "width": 20, "height": 2],
            viewport: viewport, size: size))
        XCTAssertEqual(BrowserAgentBridge.clickPoint(
            rect: ["x": boundary - 1, "y": 20, "width": 3, "height": 2],
            viewport: viewport, size: size), NSPoint(x: boundary, y: 21))
    }

    func testCEFClickSubpixelMatrixUsesOnlyAvailableNativePoints() throws {
        // Pure geometry coverage, not pixel/DOM/native GUI acceptance.
        for x in stride(from: -1.0, through: 6.0, by: 0.25) {
            for width in [0.25, 0.5, 1.0, 2.25] {
                let point = BrowserAgentBridge.clickPoint(
                    rect: ["x": x, "y": 1.25, "width": width, "height": 2.0],
                    viewport: ["width": 6, "height": 4], size: NSSize(width: 6, height: 4))
                let available = (0..<6).filter { Double($0) >= x && Double($0) < x + width }
                if available.isEmpty { XCTAssertNil(point) }
                else {
                    let point = try XCTUnwrap(point)
                    XCTAssertTrue(available.contains { CGFloat($0) == point.x })
                    XCTAssertEqual(point.x, point.x.rounded())
                    XCTAssertEqual(point.y, point.y.rounded())
                    XCTAssertGreaterThanOrEqual(point.y, 1.25)
                    XCTAssertLessThan(point.y, 3.25)
                }
            }
        }
    }

    func testActionMethodsRequireExplicitObservationToken() throws {
        let id = UUID()
        for method in ["browser_click", "browser_type", "browser_scroll"] {
            for raw in [id.uuidString, id.uuidString.lowercased()] {
                XCTAssertEqual(try BrowserAgentRequest.observationID(for: method, params: ["observationID": raw]), id)
            }
            for value: Any in [NSNull(), true, 1, "", "not-an-observation", " " + id.uuidString] {
                XCTAssertThrowsError(try BrowserAgentRequest.observationID(for: method, params: ["observationID": value]))
            }
            XCTAssertThrowsError(try BrowserAgentRequest.observationID(for: method, params: [:]))
        }
    }

    func testNavigationAndReadCannotCarryActionObservation() throws {
        for method in ["browser_start", "browser_stop", "browser_open", "browser_search", "browser_read", "browser_screenshot"] {
            XCTAssertNil(try BrowserAgentRequest.observationID(for: method, params: [:]))
            XCTAssertThrowsError(try BrowserAgentRequest.observationID(for: method, params: ["observationID": UUID().uuidString]))
        }
    }

    func testRequestRetainsItsOwnObservationAfterNewRequestAndFinish() throws {
        let oldID = UUID(), newID = UUID()
        let old = BrowserAgentRequest(caller: caller, scope: "same-chat", epoch: 1, observationID: oldID, now: 100)
        let current = BrowserAgentRequest(caller: caller, scope: "same-chat", epoch: 1, observationID: newID, now: 100)
        old.finish()
        XCTAssertEqual(old.observationID, oldID)
        XCTAssertEqual(current.observationID, newID)
        XCTAssertThrowsError(try old.validate(currentScope: current.scope, currentEpoch: 1, connected: true, now: 101))
        XCTAssertNoThrow(try current.validate(currentScope: current.scope, currentEpoch: 1, connected: true, now: 101))
    }

    private func fingerprint(_ data: [String: Any], surface: UUID? = nil, navigation: String = "document-1",
                             url: String = "https://example.invalid/fixture", geometry: [Double] = [800, 600, 2]) throws -> String {
        try BrowserAgentSnapshotFingerprint.make(snapshot: data, surfaceID: surface ?? caller,
            navigationID: navigation, url: url, geometry: geometry)
    }

    func testFingerprintCanonicalizesUnorderedFormsButPreservesFieldOrder() throws {
        let first: [String: Any] = ["elementID": "cef-1", "fields": [["elementID": "cef-2"], ["elementID": "cef-3"]]]
        let second: [String: Any] = ["elementID": "cef-4", "fields": []]
        let original = try fingerprint(["forms": [first, second]])
        XCTAssertEqual(original, try fingerprint(["forms": [second, first]]))
        let reordered: [String: Any] = ["elementID": "cef-1", "fields": [["elementID": "cef-3"], ["elementID": "cef-2"]]]
        XCTAssertNotEqual(original, try fingerprint(["forms": [reordered, second]]))
    }

    func testFingerprintIncludesSurfaceNavigationURLGeometryAndDOM() throws {
        let snapshot: [String: Any] = ["title": "fixture", "viewport": ["width": 800, "height": 600, "scrollY": 0],
                                      "controls": [["elementID": "cef-1", "label": "Send"]]]
        let original = try fingerprint(snapshot)
        XCTAssertEqual(original.count, 64)
        XCTAssertEqual(original, try fingerprint(snapshot))
        XCTAssertNotEqual(original, try fingerprint(snapshot, surface: UUID()))
        XCTAssertNotEqual(original, try fingerprint(snapshot, navigation: "document-2"))
        XCTAssertNotEqual(original, try fingerprint(snapshot, url: "https://example.invalid/other"))
        XCTAssertNotEqual(original, try fingerprint(snapshot, geometry: [801, 600, 2]))
        XCTAssertNotEqual(original, try fingerprint(snapshot, geometry: [800, 600, 1]))
        var changed = snapshot
        changed["viewport"] = ["width": 800, "height": 600, "scrollY": 10]
        XCTAssertNotEqual(original, try fingerprint(changed))
        changed = snapshot
        changed["controls"] = [["elementID": "cef-2", "label": "Send"]]
        XCTAssertNotEqual(original, try fingerprint(changed), "Replacement nodes cannot inherit the old observation.")
    }

    func testFingerprintRejectsMalformedGeometryAndSnapshot() {
        for geometry: [Double] in [[], [.nan], [.infinity], [-.infinity]] {
            XCTAssertThrowsError(try fingerprint(["title": "fixture"], geometry: geometry))
        }
        XCTAssertThrowsError(try fingerprint(["title": "fixture"], navigation: ""))
        XCTAssertThrowsError(try fingerprint(["forms": [["invalid": Date()]]]))
        XCTAssertThrowsError(try fingerprint(["invalid": Double.nan]))
    }

    func testUnknownSelectorNeverFallsBackToAnotherPageLabel() {
        let controls: [[String: Any]] = [
            ["elementID": "cef-1", "label": "Send"], ["elementID": "cef-2", "label": "cef-99"],
        ]
        XCTAssertNil(BrowserAgentBridge.uniqueElement(controls, selector: "cef-99", label: "Send"))
        XCTAssertEqual(BrowserAgentBridge.uniqueElement(controls, selector: "cef-1", label: "Different")?["elementID"] as? String, "cef-1")
        XCTAssertEqual(BrowserAgentBridge.uniqueElement(controls, selector: nil, label: "Send")?["elementID"] as? String, "cef-1")
        XCTAssertNil(BrowserAgentBridge.uniqueElement(controls + [["elementID": "cef-3", "label": "Send"]],
            selector: nil, label: "Send"))
    }

    func testReaderProjectsWKSelectorsWithoutInternalBindingData() throws {
        let snapshot: [String: Any] = [
            "title": "fixture", "documentID": UUID().uuidString, "fingerprint": "internal-only",
            "controls": [["elementID": "wk-1", "kind": "input", "label": "Name"],
                         ["elementID": "wk-01", "label": "invalid"],
                         ["elementID": "wk--1", "label": "invalid"]],
            "forms": [["elementID": "wk-2", "action": "https://example.invalid/private-fixture", "fields": []]],
        ]
        let result = BrowserAgentBridge.readSnapshot(snapshot, url: "https://example.invalid/form?fixture=value", maxChars: 8000)
        let elements = try XCTUnwrap(result["elements"] as? [[String: Any]])
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements[0]["selector"] as? String, "wk-1")
        for key in ["documentID", "fingerprint", "forms", "geometry"] { XCTAssertNil(result[key]) }
        XCTAssertEqual(result["url"] as? String, "https://example.invalid/form")
    }

    func testWebScriptQuotesDataAndRequiresFreshSingleUseBeforeMutation() throws {
        let text = "繁中「引號」'\"\\\\\n🙂"
        let expected = "{\"documentID\":\"fixture\",\"text\":\"read only\"}"
        let id = UUID()
        let script = try BrowserAgentPageScript.action(expectedJSON: expected, observationID: id,
            kind: "type", elementID: "wk-1", text: text, expiresAtMilliseconds: 123456)
        let prefix = try XCTUnwrap(script.range(of: "const args = "))
        let end = try XCTUnwrap(script.range(of: ";\n", range: prefix.upperBound..<script.endIndex))
        let json = String(script[prefix.upperBound..<end.lowerBound])
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(arguments["text"] as? String, text)
        XCTAssertEqual(arguments["expected"] as? String, expected)
        XCTAssertEqual(arguments["id"] as? String, id.uuidString)
        let freshCheck = try XCTUnwrap(script.range(of: "JSON.stringify(capture()) !== args.expected"))
        let consumed = try XCTUnwrap(script.range(of: "state.used.set(args.id"))
        let firstInput = try XCTUnwrap(script.range(of: "window.scrollBy(0,args.dy)"))
        XCTAssertLessThan(freshCheck.lowerBound, consumed.lowerBound)
        XCTAssertLessThan(consumed.lowerBound, firstInput.lowerBound)
        XCTAssertTrue(script.contains("state.used.has(args.id)"))
        XCTAssertTrue(script.contains("Date.now() >= args.expires"))
        XCTAssertTrue(script.contains("new WeakMap()"))
    }

    func testWebScriptRejectsUnsupportedActionAndNonfiniteDeadline() {
        XCTAssertThrowsError(try BrowserAgentPageScript.action(expectedJSON: "{}", observationID: UUID(),
            kind: "unsupported", expiresAtMilliseconds: 123456))
        for deadline: Double in [.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try BrowserAgentPageScript.action(expectedJSON: "{}", observationID: UUID(),
                kind: "click", expiresAtMilliseconds: deadline))
        }
    }

    func testBlockedAgentDestinationReportsPolicyInsteadOfDispatchTimeout() throws {
        for text in ["http://127.0.0.1:3000/songs", "http://localhost:3000/songs",
                     "http://[::1]:3000/songs", "http://10.0.0.1/", "file:///fixture"] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertThrowsError(try BrowserAgentNavigation.validateDestination(url)) {
                XCTAssertTrue(String(describing: $0).hasPrefix("browser_navigation_blocked_by_policy"))
                XCTAssertFalse(String(describing: $0).contains("timed_out"))
            }
        }
    }

    func testPublicAgentDestinationStillReachesNativeValidation() throws {
        try BrowserAgentNavigation.validateDestination(XCTUnwrap(URL(string: "https://example.com/")))
    }

    private func request(epoch: UInt64 = 7) -> BrowserAgentRequest {
        BrowserAgentRequest(caller: caller, scope: "test-chat|test-project|test-space", epoch: epoch, now: 100)
    }

    func testNativeReadinessWaitDoesNotFinishOrConsumeTheRequest() throws {
        let original = request()
        let url = URL(string: "https://example.invalid/fixture")!
        let navigation = BrowserAgentNavigation(url: url, request: original)
        var clock: TimeInterval = 100
        var sleeps = 0
        XCTAssertFalse(navigation.hasAttempted)
        try navigation.waitForAttempt(timeout: 1, now: { clock }, sleep: { interval in
            clock += interval
            sleeps += 1
            if sleeps == 2 {
                do {
                    let consumed = try navigation.consumeAttempt(for: url)
                    XCTAssertTrue(consumed)
                } catch {
                    XCTFail("Expected the original navigation attempt to be consumed: \(error)")
                }
            }
        }, validate: {
            try original.validate(currentScope: original.scope, currentEpoch: 7,
                                  connected: true, now: clock)
        })
        XCTAssertEqual(sleeps, 2)
        XCTAssertTrue(navigation.hasAttempted)
        XCTAssertFalse(try navigation.consumeAttempt(for: url))
        try original.validate(currentScope: original.scope, currentEpoch: 7, connected: true, now: clock)
    }

    func testNativeReadinessWaitStopsWhenOriginalRequestIsRevoked() {
        let original = request()
        let navigation = BrowserAgentNavigation(url: URL(string: "https://example.invalid/fixture")!, request: original)
        var sleeps = 0
        XCTAssertThrowsError(try navigation.waitForAttempt(now: { 100 }, sleep: { _ in
            sleeps += 1
            original.finish()
        }, validate: {
            try original.validate(currentScope: original.scope, currentEpoch: 7, connected: true, now: 100)
        })) {
            XCTAssertEqual(String(describing: $0), "browser_request_revoked")
        }
        XCTAssertEqual(sleeps, 1)
        XCTAssertFalse(navigation.hasAttempted)
    }

    func testNativeReadinessTimeoutDoesNotPretendNavigationWasSent() {
        let navigation = BrowserAgentNavigation(url: URL(string: "https://example.invalid/fixture")!, request: request())
        var clock: TimeInterval = 100
        XCTAssertThrowsError(try navigation.waitForAttempt(timeout: 0.1, now: { clock },
            sleep: { clock += $0 }, validate: {})) {
            XCTAssertEqual(String(describing: $0), "browser_navigation_dispatch_timed_out")
        }
        XCTAssertEqual(clock, 100.1, accuracy: 0.0001)
        XCTAssertFalse(navigation.hasAttempted)
    }

    func testNativeReadinessWaitNeverExtendsOriginalDeadline() {
        let navigation = BrowserAgentNavigation(url: URL(string: "https://example.invalid/fixture")!, request: request())
        var clock: TimeInterval = 139.99
        XCTAssertThrowsError(try navigation.waitForAttempt(timeout: 100, now: { clock },
            sleep: { clock += $0 }, validate: {}))
        XCTAssertEqual(clock, 140, accuracy: 0.0001)
        XCTAssertFalse(navigation.hasAttempted)
    }

    func testDeferredNavigationPreservesTheOriginalRequest() throws {
        let original = request()
        let navigation = BrowserAgentNavigation(url: URL(string: "https://example.invalid/fixture")!, request: original)
        let newer = request()
        XCTAssertTrue(navigation.request === original)
        XCTAssertFalse(navigation.request === newer)
        original.finish()
        XCTAssertThrowsError(try navigation.request.validate(
            currentScope: newer.scope, currentEpoch: 7, connected: true, now: 110))
    }

    func testUIAndDirectNavigationShareOneAttempt() throws {
        let url = URL(string: "https://example.invalid/fixture")!
        let navigation = BrowserAgentNavigation(url: url, request: request())
        let uiCopy = navigation
        XCTAssertTrue(try uiCopy.consumeAttempt(for: url))
        XCTAssertFalse(try navigation.consumeAttempt(for: url))
        XCTAssertFalse(try uiCopy.consumeAttempt(for: url))
    }

    func testChangedNavigationURLDoesNotConsumeTheOriginalAttempt() throws {
        let url = URL(string: "https://example.invalid/fixture")!
        let navigation = BrowserAgentNavigation(url: url, request: request())
        XCTAssertThrowsError(try navigation.consumeAttempt(for: URL(string: "https://example.invalid/other")!))
        XCTAssertTrue(try navigation.consumeAttempt(for: url))
    }

    func testUncertainNavigationCannotAutomaticallyReplay() throws {
        let url = URL(string: "https://example.invalid/fixture")!
        let navigation = BrowserAgentNavigation(url: url, request: request())
        XCTAssertThrowsError(try {
            XCTAssertTrue(try navigation.consumeAttempt(for: url))
            throw BrowserAgentRequestError("delivery_unknown")
        }())
        XCTAssertFalse(try navigation.consumeAttempt(for: url))
    }

    func testDistinctExplicitNavigationsDoNotShareDeduplication() throws {
        let url = URL(string: "https://example.invalid/fixture")!
        let first = BrowserAgentNavigation(url: url, request: request())
        let second = BrowserAgentNavigation(url: url, request: request())
        XCTAssertTrue(try first.consumeAttempt(for: url))
        XCTAssertTrue(try second.consumeAttempt(for: url))
    }

    func testDeferredCommandKeepsItsNavigationBinding() throws {
        let url = URL(string: "https://example.invalid/fixture")!
        let navigation = BrowserAgentNavigation(url: url, request: request())
        let command = EmbeddedBrowserCommand(action: .load(url), agentNavigation: navigation)
        let copy = command
        XCTAssertTrue(copy.agentNavigation === navigation)
        XCTAssertEqual(copy, command)
        XCTAssertNil(EmbeddedBrowserCommand(action: .load(url)).agentNavigation)
        XCTAssertNotEqual(command, EmbeddedBrowserCommand(action: .load(url), agentNavigation: navigation))
    }

    func testOnlyCommittedNativeURLsCanEnterSavedTabs() {
        let pending = "https://example.invalid/pending"
        let committed = "https://example.invalid/committed"
        func state(_ phase: EmbeddedBrowserLoadPhase, committedURL: String?) -> EmbeddedBrowserNavigationState {
            EmbeddedBrowserNavigationState(urlString: pending, canGoBack: false, canGoForward: false,
                visibleError: nil, phase: phase, committedMainFrameURLString: committedURL)
        }
        for phase: EmbeddedBrowserLoadPhase in [.blank, .creating, .loading, .navigationFailed, .closed] {
            XCTAssertNil(EmbeddedBrowserView.committedURLForPersistence(state(phase, committedURL: committed)))
        }
        XCTAssertNil(EmbeddedBrowserView.committedURLForPersistence(state(.finished, committedURL: nil)))
        for phase: EmbeddedBrowserLoadPhase in [.committed, .finished] {
            XCTAssertEqual(EmbeddedBrowserView.committedURLForPersistence(state(phase, committedURL: committed)),
                           URL(string: committed))
        }
    }

    func testCallerMustBeAnExplicitUUID() throws {
        XCTAssertEqual(try BrowserAgentRequest.caller(from: ["callerThreadID": caller.uuidString]), caller)
        XCTAssertEqual(try BrowserAgentRequest.caller(from: ["callerThreadID": caller.uuidString.lowercased()]), caller)
        for params: [String: Any] in [[:], ["callerThreadID": true], ["callerThreadID": NSNull()],
                                     ["callerThreadID": ""], ["callerThreadID": "not-a-uuid"], ["_threadID": caller.uuidString]] {
            XCTAssertThrowsError(try BrowserAgentRequest.caller(from: params))
        }
    }

    func testCurrentRequestRequiresScopeEpochConnectionAndDeadline() throws {
        let value = request()
        try value.validate(currentScope: value.scope, currentEpoch: 7, connected: true, now: 100)
        try value.validate(currentScope: value.scope, currentEpoch: 7, connected: true, now: 139.999)
    }

    func testChatProjectSpaceChangeOrMissingScopeIsRejected() {
        let value = request()
        for scope: String? in [nil, "", "other-chat|test-project|test-space",
                              "test-chat|other-project|test-space", "test-chat|test-project|other-space"] {
            XCTAssertThrowsError(try value.validate(currentScope: scope, currentEpoch: 7, connected: true, now: 110))
        }
    }

    func testLocalRevocationInvalidatesCapturedRequestEvenAfterScopeReturns() {
        let old = request()
        for epoch: UInt64 in [0, 6, 8, 9, .max] {
            XCTAssertThrowsError(try old.validate(currentScope: old.scope, currentEpoch: epoch, connected: true, now: 110)) {
                XCTAssertEqual(String(describing: $0), "browser_request_revoked")
            }
        }
    }

    func testFinishedCallbackCannotUseNewRequestOrReusedConnection() throws {
        let old = request()
        old.finish()
        old.finish()
        let newer = request()
        try newer.validate(currentScope: newer.scope, currentEpoch: 7, connected: true, now: 110)
        XCTAssertThrowsError(try old.validate(currentScope: newer.scope, currentEpoch: 7, connected: true, now: 110))
    }

    func testDisconnectAndTimeoutNeverBecomeSuccess() {
        let value = request()
        XCTAssertThrowsError(try value.validate(currentScope: value.scope, currentEpoch: 7, connected: false, now: 110))
        for now: TimeInterval in [140, 141, .infinity, .nan] {
            XCTAssertThrowsError(try value.validate(currentScope: value.scope, currentEpoch: 7, connected: true, now: now))
        }
    }
}
