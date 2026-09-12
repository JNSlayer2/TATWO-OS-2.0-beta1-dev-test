import AppKit
import ApplicationServices

enum ComputerUsePointer {
    enum Kind: String, Sendable {
        case click, scroll, drag
        case doubleClick = "double_click"
        case rightClick = "right_click"
    }
    enum Location: Sendable {
        case element(Int)
        case point(Double, Double)
    }
    struct Request: Sendable {
        let kind: Kind
        let from: Location
        let to: Location?
        let dx: Int32
        let dy: Int32
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func index(_ value: Any?) throws -> Int {
        guard let number = number(value), number >= 0, number <= Double(Int32.max), number.rounded() == number else {
            throw ComputerUseFailure("computer_invalid_element_index")
        }
        return Int(number)
    }
    static func request(action: String, params: [String: Any]) throws -> Request {
        guard let kind = Kind(rawValue: action) else { throw ComputerUseFailure("computer_invalid_action") }
        var fields: Set<String> = ["sessionID", "observationID", "callerThreadID", "action", "element", "x", "y", "image"]
        if kind == .scroll { fields.formUnion(["dx", "dy"]) }
        if kind == .drag { fields.formUnion(["toElement", "toX", "toY"]) }
        guard Set(params.keys).isSubset(of: fields) else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
        func location(_ element: String, _ x: String, _ y: String) throws -> Location {
            if let value = params[element] {
                guard params[x] == nil, params[y] == nil else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
                return .element(try index(value))
            }
            guard let x = number(params[x]), let y = number(params[y]), x >= 0, y >= 0, x < 2048, y < 2048 else {
                throw ComputerUseFailure("computer_invalid_pointer_arguments")
            }
            return .point(x, y)
        }
        func delta(_ key: String) throws -> Int32 {
            guard let value = number(params[key]), value.rounded() == value, abs(value) <= 1200 else {
                throw ComputerUseFailure("computer_invalid_pointer_arguments")
            }
            return Int32(value)
        }
        let dx: Int32 = kind == .scroll ? try delta("dx") : 0
        let dy: Int32 = kind == .scroll ? try delta("dy") : 0
        if kind == .scroll && dx == 0 && dy == 0 { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
        return Request(kind: kind, from: try location("element", "x", "y"),
                       to: kind == .drag ? try location("toElement", "toX", "toY") : nil, dx: dx, dy: dy)
    }

    static func screenPoint(x: Double, y: Double, imageWidth: Int, imageHeight: Int, frame: CGRect) throws -> CGPoint {
        guard (1...2048).contains(imageWidth), (1...2048).contains(imageHeight),
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(imageWidth), y < Double(imageHeight),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { throw ComputerUseFailure("computer_pointer_outside_observation") }
        let scale = frame.width / Double(imageWidth)
        let point = CGPoint(x: frame.minX + x * scale, y: frame.minY + y * scale)
        guard frame.contains(point) else { throw ComputerUseFailure("computer_pointer_outside_observation") }
        return point
    }
    static func imageFrame(_ rect: CGRect, windowFrame: CGRect, imageWidth: Int) -> CGRect {
        let scale = Double(imageWidth) / windowFrame.width
        return CGRect(x: (rect.minX - windowFrame.minX) * scale, y: (rect.minY - windowFrame.minY) * scale,
                      width: rect.width * scale, height: rect.height * scale)
    }

    enum DragEvent: Equatable { case down, moved, up }
    /// The production sender and tests share this choreography. Up is cleanup,
    /// deliberately outside the revoked gate; it must run even if dispatch throws.
    static func drag(from: CGPoint, to: CGPoint, check: () throws -> Void,
                     send: (DragEvent, CGPoint) throws -> Void, release: (CGPoint) -> Void,
                     wait: () throws -> Void = { Thread.sleep(forTimeInterval: 0.025) }) throws {
        var point = from
        var mayBeDown = false
        defer { if mayBeDown { release(point) } }
        try check()
        mayBeDown = true
        try send(.down, point)
        for step in 1...12 {
            try wait()
            try check()
            let next = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 12,
                               y: from.y + (to.y - from.y) * Double(step) / 12)
            try send(.moved, next)
            point = next // A rejected dispatch must not move the cleanup/drop location.

        }
    }

    static func input(_ request: Request, observation: ComputerUseSession.Observation,
                      grant: ComputerUseSession.Grant, gate: ComputerUseSession,
                      check: () throws -> Void, element: (Int) throws -> AXUIElement,
                      deadline: TimeInterval) throws {
        guard let state = observation.state, let window = state.window else {
            throw ComputerUseFailure("computer_pointer_outside_observation")
        }
        func geometry() throws -> CGRect {
            guard let current = try? ComputerUseNative.frame(window, deadline: deadline),
                  ComputerUseNative.sameFrame(current, state.frame) else {
                throw ComputerUseFailure("computer_element_stale")
            }
            return current
        }
        func point(_ location: Location) throws -> CGPoint {
            let bounds = try geometry()
            switch location {
            case .point(let x, let y):
                return try screenPoint(x: x, y: y, imageWidth: observation.imageWidth,
                                       imageHeight: observation.imageHeight, frame: bounds)
            case .element(let index):
                let rect = try ComputerUseNative.frame(element(index), deadline: deadline)
                return CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        let from = try point(request.from)
        guard let source = CGEventSource(stateID: .privateState) else { throw ComputerUseFailure("computer_input_unavailable") }
        func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left, click: Int = 1) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: button) else {
                throw ComputerUseFailure("computer_input_unavailable")
            }
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            return event
        }
        switch request.kind {
        case .click, .doubleClick, .rightClick:
            let right = request.kind == .rightClick
            if ComputerUseBackgroundEvents.available {
                // Background: the target believes it is active for this click; cursor and front App untouched.
                try check()
                _ = try geometry()
                let target = try ComputerUseBackgroundEvents.target(pid: grant.pid, at: from)
                ComputerUseBackgroundEvents.activate(target)
                Thread.sleep(forTimeInterval: 0.06)
                for count in 1...(request.kind == .doubleClick ? 2 : 1) {
                    try check()
                    let number = ComputerUseBackgroundEvents.nextEventNumber()
                    try gate.dispatch(observationID: observation.id, for: grant) {
                        ComputerUseBackgroundEvents.mouse(target, right ? .rightDown : .leftDown, at: from,
                                                          click: Int32(count), eventNumber: number)
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                    ComputerUseBackgroundEvents.mouse(target, right ? .rightUp : .leftUp, at: from,
                                                      click: Int32(count), eventNumber: number)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                ComputerUseBackgroundEvents.noteLastPoint(from)
                // A context menu stays open only while the App believes it is active; the next action or
                // Stop re-activates/deactivates anyway.
                if !right {
                    Thread.sleep(forTimeInterval: 0.12)
                    ComputerUseBackgroundEvents.deactivate(target)
                }
                return
            }
            for count in 1...(request.kind == .doubleClick ? 2 : 1) {
                try check()
                _ = try geometry()
                let down = try mouse(right ? .rightMouseDown : .leftMouseDown, from, right ? .right : .left, click: count)
                let up = try mouse(right ? .rightMouseUp : .leftMouseUp, from, right ? .right : .left, click: count)
                try gate.dispatch(observationID: observation.id, for: grant) {
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
            }
        case .scroll:
            try check()
            if ComputerUseBackgroundEvents.available {
                // Background wheel through synthetic app focus (CU02-F2: the old cursor-borrowing path raised
                // Finder and the user's mouse move then read as a takeover).
                _ = try geometry()
                let target = try ComputerUseBackgroundEvents.target(pid: grant.pid, at: from)
                ComputerUseBackgroundEvents.activate(target)
                Thread.sleep(forTimeInterval: 0.06)
                try gate.dispatch(observationID: observation.id, for: grant) {
                    ComputerUseBackgroundEvents.scroll(target, at: from, dx: request.dx, dy: request.dy)
                }
                Thread.sleep(forTimeInterval: 0.12)
                ComputerUseBackgroundEvents.deactivate(target)
                ComputerUseBackgroundEvents.noteLastPoint(from)
                return
            }
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                      wheelCount: 2, wheel1: -request.dy, wheel2: -request.dx, wheel3: 0) else {
                throw ComputerUseFailure("computer_input_unavailable")
            }
            event.location = from
            event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
            try gate.dispatch(observationID: observation.id, for: grant) { event.post(tap: .cghidEventTap) }
        case .drag:
            guard let destination = request.to else { throw ComputerUseFailure("computer_invalid_pointer_arguments") }
            let to = try point(destination)
            if ComputerUseBackgroundEvents.available {
                let target = try ComputerUseBackgroundEvents.target(pid: grant.pid, at: from)
                let number = ComputerUseBackgroundEvents.nextEventNumber()
                ComputerUseBackgroundEvents.activate(target)
                Thread.sleep(forTimeInterval: 0.06)
                defer {
                    Thread.sleep(forTimeInterval: 0.12)
                    ComputerUseBackgroundEvents.deactivate(target)
                }
                try drag(from: from, to: to, check: {
                    try check()
                    _ = try geometry()
                }, send: { kind, point in
                    try gate.dispatch(observationID: observation.id, for: grant) {
                        ComputerUseBackgroundEvents.mouse(target, kind == .down ? .leftDown : .leftDragged,
                                                          at: point, eventNumber: number)
                    }
                }, release: { point in
                    ComputerUseBackgroundEvents.mouse(target, .leftUp, at: point, eventNumber: number)
                })
                ComputerUseBackgroundEvents.noteLastPoint(to)
                return
            }
            // Allocate cleanup before down; allocation failure can never strand a button.
            let up = try mouse(.leftMouseUp, from)
            try drag(from: from, to: to, check: {
                try check()
                _ = try geometry()
            }, send: { kind, point in
                let event = try mouse(kind == .down ? .leftMouseDown : .leftMouseDragged, point)
                try gate.dispatch(observationID: observation.id, for: grant) { event.post(tap: .cghidEventTap) }
            }, release: { point in
                up.location = point
                up.post(tap: .cghidEventTap)
            })
        }
    }
}
