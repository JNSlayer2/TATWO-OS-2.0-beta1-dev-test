import AppKit
import XCTest
@testable import Tatwo2

final class ComputerUsePointerTests: XCTestCase {
    func testPixelToScreenConversionWithRetinaAndNegativeScreenOrigin() throws {
        let frame = CGRect(x: -900, y: 100, width: 800, height: 600)
        let point = try ComputerUsePointer.screenPoint(x: 400, y: 200, imageWidth: 1600, imageHeight: 1200, frame: frame)
        XCTAssertEqual(point, CGPoint(x: -700, y: 200))
        let back = ComputerUsePointer.imageFrame(CGRect(origin: point, size: CGSize(width: 10, height: 20)),
                                                 windowFrame: frame, imageWidth: 1600)
        XCTAssertEqual(back, CGRect(x: 400, y: 200, width: 20, height: 40))
        for (x, y) in [(-1.0, 0.0), (1600, 0), (0, 1200), (.nan, 0), (.infinity, 0)] {
            XCTAssertThrowsError(try ComputerUsePointer.screenPoint(x: x, y: y, imageWidth: 1600, imageHeight: 1200, frame: frame))
        }
        XCTAssertThrowsError(try ComputerUsePointer.screenPoint(x: 0, y: 0, imageWidth: 0, imageHeight: 0, frame: frame))
    }

    func testLocationsAreExclusiveAndScrollSupportsBothAxes() throws {
        for action in ["click", "double_click", "right_click"] {
            XCTAssertNoThrow(try ComputerUsePointer.request(action: action, params: ["element": 4]))
            XCTAssertNoThrow(try ComputerUsePointer.request(action: action, params: ["x": 1.5, "y": 2]))
            XCTAssertThrowsError(try ComputerUsePointer.request(action: action, params: ["element": 4, "x": 1, "y": 2]))
        }
        let request = try ComputerUsePointer.request(action: "scroll", params: ["element": 0, "dx": 120, "dy": -20])
        XCTAssertEqual(request.dx, 120)
        XCTAssertEqual(request.dy, -20)
        for params: [String: Any] in [["element": true], ["element": -1], ["element": 1.5], ["x": true, "y": 1], ["x": 2048, "y": 1]] {
            XCTAssertThrowsError(try ComputerUsePointer.request(action: "click", params: params))
        }
        XCTAssertNoThrow(try ComputerUsePointer.request(action: "drag", params: ["element": 2, "toX": 300, "toY": 400]))
        XCTAssertThrowsError(try ComputerUsePointer.request(action: "drag", params: ["element": 2]))
    }

    func testDragHasTwelveMovesAndAlwaysReleases() throws {
        var events: [ComputerUsePointer.DragEvent] = []
        var end = CGPoint.zero
        try ComputerUsePointer.drag(from: .zero, to: CGPoint(x: 120, y: 60), check: {}, send: { kind, point in
            events.append(kind); end = point
        }, release: { point in events.append(.up); end = point }, wait: {})
        XCTAssertEqual(events, [.down] + Array(repeating: .moved, count: 12) + [.up])
        XCTAssertEqual(end, CGPoint(x: 120, y: 60))
    }

    func testEveryMidDragStopReleasesDespiteRevokedDispatchGate() throws {
        for stopAfter in 0...11 {
            let gate = ComputerUseSession()
            let grant = try gate.authorize(owner: UUID(), scope: "test", pid: getpid(), expectedEpoch: gate.currentEpoch)
            let observation = try gate.publish(fingerprint: "", for: grant)
            try gate.beginAction(observationID: observation.id.uuidString, fingerprint: "", for: grant)
            var events: [ComputerUsePointer.DragEvent] = []
            var moves = 0
            XCTAssertThrowsError(try ComputerUsePointer.drag(from: .zero, to: CGPoint(x: 120, y: 60),
                check: { try gate.validate(grant) }, send: { kind, _ in
                    try gate.dispatch(observationID: observation.id, for: grant) { events.append(kind) }
                    if kind == .moved { moves += 1 }
                    if moves == stopAfter { gate.stop() }
                }, release: { _ in events.append(.up) }, wait: {}))
            XCTAssertEqual(events.first, .down)
            XCTAssertEqual(events.last, .up)
            XCTAssertEqual(events.filter { $0 == .up }.count, 1)
        }
    }

    func testUncertainDownOrWaitFailureStillReleasesAndPreflightStopDoesNotPress() {
        for failure in ["down", "wait", "check"] {
            var events: [ComputerUsePointer.DragEvent] = []
            XCTAssertThrowsError(try ComputerUsePointer.drag(from: .zero, to: .zero, check: {
                if failure == "check" { throw ComputerUseFailure("stopped") }
            }, send: { kind, _ in
                events.append(kind)
                if failure == "down" { throw ComputerUseFailure("uncertain") }
            }, release: { _ in events.append(.up) }, wait: {
                if failure == "wait" { throw ComputerUseFailure("cancelled") }
            }))
            XCTAssertEqual(events, failure == "check" ? [] : [.down, .up])
        }
    }
    func testDragDispatchRejectionReleasesAtLastDeliveredPoint() {
        let start = CGPoint(x: 10, y: 20)
        var released: CGPoint?
        XCTAssertThrowsError(try ComputerUsePointer.drag(from: start, to: CGPoint(x: 200, y: 300), check: {},
            send: { kind, _ in
                if kind == .moved { throw ComputerUseFailure("stopped_before_dispatch") }
            }, release: { released = $0 }, wait: {}))
        XCTAssertEqual(released, start)
    }

}
