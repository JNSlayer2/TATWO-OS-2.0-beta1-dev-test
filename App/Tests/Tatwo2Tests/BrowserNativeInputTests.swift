import AppKit
import JavaScriptCore
import XCTest
@testable import Tatwo2

final class BrowserNativeInputTests: XCTestCase {
    func testBrowserLoopbackPolicyRemainsClosed() {
        for url in ["http://127.0.0.1:8765/", "http://[::1]:8765/"] {
            XCTAssertEqual(EmbeddedBrowserNavigationPolicy.decision(for: URL(string: url)),
                           .block(.nonPublicIPAddress))
        }
        XCTAssertEqual(EmbeddedBrowserNavigationPolicy.decision(for: URL(string: "http://localhost:8765/")),
                       .block(.localHostname))
    }

    func testBrowserDragStopAtEveryStageAlwaysReleasesAndConsumesObservation() throws {
        for stopAt in 0..<14 {
            let session = ComputerUseSession()
            let grant = try session.authorize(owner: UUID(), scope: "test", pid: 42,
                expectedEpoch: session.currentEpoch, lane: .builtInBrowser)
            let observation = try session.publish(fingerprint: "page", for: grant)
            try session.beginAction(observationID: observation.id.uuidString, fingerprint: "page", for: grant)
            var calls = 0, releases = 0
            XCTAssertThrowsError(try BrowserNativeInput.pointer(from: .zero, to: NSPoint(x: 24, y: 12),
                dragging: true, send: { _, _ in
                    if calls == stopAt { session.stop(owner: grant.owner) }
                    calls += 1
                    try session.dispatchObservedBrowser(observationID: observation.id, for: grant) {}
                }, release: { _ in releases += 1 }, pause: {}))
            session.endAction(observationID: observation.id, for: grant)
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(calls, stopAt + 1, "No moves after Stop")
            XCTAssertThrowsError(try session.beginAction(observationID: observation.id.uuidString,
                fingerprint: "page", for: grant))
        }
    }

    func testBrowserDragSenderErrorReleasesOriginalLastPoint() {
        var points: [NSPoint] = [], released: NSPoint?
        XCTAssertThrowsError(try BrowserNativeInput.pointer(from: .zero, to: NSPoint(x: 24, y: 12),
            dragging: true, send: { phase, point in
                points.append(point)
                if phase == .move { throw BrowserAgentRequestError("injected_after_send") }
            }, release: { released = $0 }, pause: {}))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(released, NSPoint(x: 2, y: 1))
    }

    func testBrowserDragHasTwelveMovesAndNoRedundantCleanupOnSuccess() throws {
        var phases: [BrowserNativeInput.Phase] = [], points: [NSPoint] = []
        try BrowserNativeInput.pointer(from: NSPoint(x: 2, y: 3), to: NSPoint(x: 26, y: 15),
            dragging: true, send: { phases.append($0); points.append($1) },
            release: { _ in XCTFail("Unexpected cleanup") }, pause: {})
        XCTAssertEqual(phases, [.down] + Array(repeating: .move, count: 12) + [.up])
        XCTAssertEqual(points.last, NSPoint(x: 26, y: 15))
    }

    func testBrowserPixelAndFlippedViewConversions() throws {
        let point = try BrowserNativeInput.screenshotPoint(x: 300, y: 100,
            pixels: NSSize(width: 1200, height: 800), view: NSSize(width: 600, height: 400))
        XCTAssertEqual(point, NSPoint(x: 150, y: 50))
        let bounds = NSRect(x: 10, y: 20, width: 600, height: 400)
        XCTAssertEqual(BrowserNativeInput.viewPoint(point, bounds: bounds, flipped: true), NSPoint(x: 160, y: 70))
        XCTAssertEqual(BrowserNativeInput.viewPoint(point, bounds: bounds, flipped: false), NSPoint(x: 160, y: 370))
        for x in [-1, 1200, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try BrowserNativeInput.screenshotPoint(x: x, y: 0,
                pixels: NSSize(width: 1200, height: 800), view: NSSize(width: 600, height: 400)))
        }
    }

    func testBrowserCoordinatesRequireTheirExactScreenshotNotALaterRead() throws {
        let id = UUID(), size = NSSize(width: 400, height: 300)
        let geometry = BrowserNativeInput.ScreenshotGeometry(id: id, fingerprint: "page", pixels: size)
        XCTAssertNoThrow(try geometry.point(x: 1, y: 1, view: size, observationID: id, currentFingerprint: "page"))
        for token in [nil, UUID()] {
            XCTAssertThrowsError(try geometry.point(x: 1, y: 1, view: size, observationID: token, currentFingerprint: "page"))
        }
        XCTAssertThrowsError(try geometry.point(x: 1, y: 1, view: size, observationID: id, currentFingerprint: "changed"))
    }

    func testBrowserKeysMatchExternalNamesWithoutUsingGlobalEvents() throws {
        for name in BrowserNativeInput.codes.keys { XCTAssertNoThrow(try BrowserNativeInput.parseKey(name)) }
        let selectAll = try BrowserNativeInput.parseKey("cmd+a")
        XCTAssertEqual(selectAll.code, 0)
        XCTAssertEqual(selectAll.flags, .command)
        XCTAssertEqual(selectAll.windowsCode, 65)
        XCTAssertEqual(try BrowserNativeInput.parseKey("shift+tab").characters, "\t")
        XCTAssertEqual(try BrowserNativeInput.parseKey("cmd++").characters, "+")
        XCTAssertEqual(try BrowserNativeInput.parseKey("up").windowsCode, 38)
        for invalid in ["", "cmd+", "cmd+cmd+a", "unknown", "ctrl+cmd+q", "cmd+option+escape",
                        "cmd+q", "cmd+w", "cmd+n", "cmd+option+c"] {
            XCTAssertThrowsError(try BrowserNativeInput.parseKey(invalid))
        }
    }

    func testBrowserPasswordOrOpaqueFocusRefused() throws {
        for value: Any? in [false, nil, "true", 1, NSNull()] {
            XCTAssertThrowsError(try BrowserNativeInput.requireSafeFocus(value))
        }
        XCTAssertNoThrow(try BrowserNativeInput.requireSafeFocus(true))
        let script = BrowserAgentPageScript.safeFocus()
        for required in ["document.activeElement", "shadowRoot", "!sensitive(el)", "iframe,frame,object,embed"] {
            XCTAssertTrue(script.contains(required))
        }
    }

    func testBrowserFocusProbeExecutesAgainstPasswordAndShadowFocusFixtures() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            var document={};
            function field(type, name='input') {
              return {type,localName:name,isConnected:true, getAttribute:()=>'',matches:()=>false};
            }
            document.activeElement=field('text');
            """)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript(BrowserAgentPageScript.safeFocus())).toBool())
        for fixture in [
            "document.activeElement=field('password')",
            "document.activeElement=field('text');document.activeElement.autocomplete='one-time-code'",
            "document.activeElement=null",
            "document.activeElement=field('text','custom-editor')",
            "document.activeElement=field('text');document.activeElement.matches=()=>true",
            "document.activeElement=field('text');document.activeElement.shadowRoot={activeElement:field('password')}"
        ] {
            context.evaluateScript(fixture)
            XCTAssertFalse(try XCTUnwrap(context.evaluateScript(BrowserAgentPageScript.safeFocus())).toBool(), fixture)
            XCTAssertNil(context.exception)
        }
    }

    func testBrowserNewActionsRequireObservationAndSelectTreatsValueAsData() throws {
        for method in BrowserAgentRequest.observedActions {
            XCTAssertThrowsError(try BrowserAgentRequest.observationID(for: method, params: [:]))
            let id = UUID()
            XCTAssertEqual(try BrowserAgentRequest.observationID(for: method,
                params: ["observationID": id.uuidString]), id)
        }
        let script = try BrowserAgentPageScript.action(expectedJSON: "{}", observationID: UUID(),
            kind: "select", elementID: "wk-1", text: "\";throw new Error('page');",
            expiresAtMilliseconds: 1)
        XCTAssertTrue(script.contains("HTMLSelectElement.prototype"))
        XCTAssertTrue(script.contains("options.length!==1"))
        XCTAssertTrue(script.contains("state.used.set"))
    }
}
