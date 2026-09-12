import Foundation
import Network
import XCTest

private struct TatwoPoint: Decodable {
    let x: Double
    let y: Double
}

private struct TatwoTouch: Decodable {
    let points: [TatwoPoint]
    let durationMs: Double
    let expectedBundleIdentifier: String
    let expectedWindow: TatwoWindow
}

private struct TatwoWindow: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

@MainActor
private final class TatwoDeviceServer {
    private let token: String
    private let listener: NWListener
    private let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var selectedApp: XCUIApplication?
    private var selectedBundleID: String?
    private var sessionID: String?
    private(set) var stopped = false

    init(token: String) throws {
        self.token = token
        listener = try NWListener(using: .tcp, on: 8117)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var request = accumulated
                if let data { request.append(data) }
                if let parsed = self.parse(request) {
                    self.respond(to: parsed, connection: connection)
                } else if error == nil, !complete, request.count < 1_048_576 {
                    self.receive(connection, accumulated: request)
                } else {
                    self.send(status: 400, type: "application/json", body: self.json(["error": "invalid_request"]), on: connection)
                }
            }
        }
    }

    private func parse(_ data: Data) -> (method: String, path: String, headers: [String: String], body: Data)? {
        let marker = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: marker),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...1_048_576).contains(length) else { return nil }
        let bodyStart = split.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return (String(requestLine[0]), String(requestLine[1]), headers, data.subdata(in: bodyStart..<(bodyStart + length)))
    }

    private func respond(to request: (method: String, path: String, headers: [String: String], body: Data), connection: NWConnection) {
        if request.method == "GET", request.path == "/v1/identity" {
            send(status: 200, type: "application/json", body: json(["name": "TATWO iPad use", "protocol": 2]), on: connection)
            return
        }
        guard request.headers["x-tatwo-token"] == token else {
            send(status: 401, type: "application/json", body: json(["error": "unauthorized"]), on: connection)
            return
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/status"):
            send(status: 200, type: "application/json", body: json(["ready": true, "name": "TATWO iPad use", "protocol": 2]), on: connection)
        case ("POST", "/v1/session"):
            sessionID = UUID().uuidString
            send(status: 200, type: "application/json", body: json(["sessionID": sessionID!]), on: connection)
        case ("POST", "/v1/app"):
            guard sessionID != nil,
                  let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let identifier = body["bundleIdentifier"] as? String,
                  identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"#, options: .regularExpression) != nil else {
                send(status: 422, type: "application/json", body: json(["error": "ipad_invalid_app"]), on: connection)
                return
            }
            let app = XCUIApplication(bundleIdentifier: identifier)
            app.activate()
            guard app.state == .runningForeground else {
                send(status: 409, type: "application/json", body: json(["error": "ipad_app_not_foreground"]), on: connection)
                return
            }
            selectedApp = app
            selectedBundleID = identifier
            send(status: 200, type: "application/json", body: json(foregroundInfo()), on: connection)
        case ("GET", "/v1/foreground"):
            send(status: 200, type: "application/json", body: json(foregroundInfo()), on: connection)
        case ("GET", "/v1/screenshot"):
            guard sessionID != nil else {
                send(status: 401, type: "application/json", body: json(["error": "unauthorized"]), on: connection)
                return
            }
            send(status: 200, type: "image/png", body: XCUIScreen.main.screenshot().pngRepresentation, on: connection)
        case ("POST", "/v1/touch"):
            handleTouch(request.body, connection: connection)
        case ("POST", "/v1/stop"):
            send(status: 200, type: "application/json", body: json(["stopped": true]), on: connection) { [weak self] in
                self?.listener.cancel()
                self?.stopped = true
            }
        default:
            send(status: 404, type: "application/json", body: json(["error": "unknown_operation"]), on: connection)
        }
    }

    private func handleTouch(_ body: Data, connection: NWConnection) {
        guard sessionID != nil, let app = foregroundApp else {
            send(status: 409, type: "application/json", body: json(["error": "ipad_app_not_foreground"]), on: connection)
            return
        }
        guard
              let touch = try? JSONDecoder().decode(TatwoTouch.self, from: body),
              (1...2).contains(touch.points.count), touch.durationMs >= 50, touch.durationMs <= 5_000 else {
            send(status: 422, type: "application/json", body: json(["error": "invalid_touch"]), on: connection)
            return
        }
        let frame = app.frame
        guard touch.expectedBundleIdentifier == foregroundInfo()["bundleIdentifier"] as? String,
              touch.expectedWindow.x == frame.minX, touch.expectedWindow.y == frame.minY,
              touch.expectedWindow.width == frame.width, touch.expectedWindow.height == frame.height else {
            send(status: 409, type: "application/json", body: json(["error": "ipad_foreground_changed"]), on: connection)
            return
        }
        guard frame.width > 0, frame.height > 0,
              touch.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x < frame.width && $0.y >= 0 && $0.y < frame.height }) else {
            send(status: 422, type: "application/json", body: json(["error": "invalid_point"]), on: connection)
            return
        }
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let first = origin.withOffset(CGVector(dx: touch.points[0].x, dy: touch.points[0].y))
        if touch.points.count == 1 {
            first.tap()
        } else {
            let last = origin.withOffset(CGVector(dx: touch.points[1].x, dy: touch.points[1].y))
            first.press(forDuration: 0.05, thenDragTo: last)
        }
        send(status: 200, type: "application/json", body: json(["delivered": true, "pencilPressure": false]), on: connection)
    }

    private var foregroundApp: XCUIApplication? {
        if let selectedApp, selectedApp.state == .runningForeground { return selectedApp }
        return home.state == .runningForeground ? home : nil
    }

    private func foregroundInfo() -> [String: Any] {
        guard let app = foregroundApp else {
            // Screenshots remain available after a person switches apps. Do not
            // invent touch coordinates for an application we have not selected.
            return ["bundleIdentifier": "", "coordinateSpaceAvailable": false]
        }
        let frame = app.frame
        return ["bundleIdentifier": app === home ? "com.apple.springboard" : (selectedBundleID ?? ""),
                "coordinateSpaceAvailable": true,
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private func send(status: Int, type: String, body: Data, on connection: NWConnection, completion: (@MainActor () -> Void)? = nil) {
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            Task { @MainActor in completion?() }
        })
    }
}

@MainActor
final class TatwoIPadDeviceTests: XCTestCase {
    func testServeTatwoIPadUse() throws {
        continueAfterFailure = false
        guard let token = ProcessInfo.processInfo.environment["TATWO_IPAD_USE_TOKEN"], token.count >= 32 else {
            throw XCTSkip("TATWO iPad USE requires an ephemeral session token")
        }
        let server = try TatwoDeviceServer(token: token)
        server.start()
        while !server.stopped {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }
}
