import Foundation

// Concatenated with the controller by the test runner only. No test-only setters
// or bypasses are compiled into the shipping App.
extension IPadUseController {
    fileprivate func fixtureSession(owner: UUID, allowTouch: Bool) {
        connected = true
        authorized = true
        self.owner = owner
        sessionID = UUID().uuidString
        touchAuthorized = allowTouch
    }
}

@main
struct IPadUseChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: \(name)") }
            passed += 1
            print("PASS: \(name)")
        }
        check(IPadUseDevice.validAddress("fd00::1"), "ULA address")
        check(!IPadUseDevice.validAddress("2001:db8::1"), "reject non-local IPv6")
        check(!IPadUseDevice.validAddress("127.0.0.1"), "reject arbitrary IPv4 endpoint")
        check(!IPadUseDevice.validAddress("localhost"), "reject DNS endpoint")
        check(!IPadUseDevice.validAddress("fe80::1"), "reject unscoped link-local endpoint")
        check(!IPadUseDevice.validAddress("fd00::1]/evil"), "reject URL injection")
        let valid: [String: Any] = ["points": [["x": 10, "y": 20], ["x": 30, "y": 40]], "durationMs": 200]
        let payload = try IPadUseController.touchPayload(valid, width: 820, height: 1180)
        check((payload["points"] as? [[String: Any]])?.count == 2, "single bounded segment")
        check(payload["durationMs"] as? NSNumber == 200, "duration preserved")
        check(payload["pencilPressure"] == nil, "touch not Pencil")
        for identifier in ["com.apple.mobilesafari", "com.example.drawing", "org.example.notes"] {
            check(try IPadUseController.appPayload(["bundleIdentifier": identifier])["bundleIdentifier"] as? String == identifier,
                  "device consent supports app \(identifier)")
        }
        for params: [String: Any] in [
            ["bundleIdentifier": ""], ["bundleIdentifier": "app; command"],
            ["bundleIdentifier": "../app"], ["bundleIdentifier": "com.example.app", "token": "override"]
        ] {
            do {
                _ = try IPadUseController.appPayload(params)
                fatalError("invalid app target accepted")
            } catch { check(true, "reject malformed or extra app parameters") }
        }
        let viewport: [String: Any] = ["bundleIdentifier": "com.example.notes", "x": 0.0, "y": 10.0,
                                      "width": 820.0, "height": 1180.0]
        check(IPadUseController.stableWindow(before: viewport, after: viewport)?["y"] == 10, "viewport carries screen origin")
        var changed = viewport
        changed["bundleIdentifier"] = "com.example.other"
        check(IPadUseController.stableWindow(before: viewport, after: changed) == nil, "app switch invalidates coordinate metadata")
        changed = viewport
        changed["width"] = 1180.0
        check(IPadUseController.stableWindow(before: viewport, after: changed) == nil, "rotation invalidates coordinate metadata")
        check(IPadUseController.stableWindow(before: [:], after: [:]) == nil, "unknown foreground does not invent coordinates")
        changed = viewport
        changed["height"] = Double.infinity
        check(IPadUseController.stableWindow(before: changed, after: changed) == nil, "nonfinite viewport rejected")
        let invalid: [[String: Any]] = [
            ["points": [], "durationMs": 100],
            ["points": [["x": -1, "y": 20]], "durationMs": 100],
            ["points": [["x": 820, "y": 20]], "durationMs": 100],
            ["points": [["x": 20, "y": 1180]], "durationMs": 100],
            ["points": [["x": true, "y": 20]], "durationMs": 100],
            ["points": [["x": Double.nan, "y": 20]], "durationMs": 100],
            ["points": [["x": 20, "y": 20, "pressure": 0.9]], "durationMs": 100],
            ["points": [["x": 20, "y": 20]], "durationMs": 100, "pointerType": "pen"],
            ["points": [["x": 20, "y": 20]], "durationMs": 5001],
            ["points": [["x": 20, "y": 20]], "durationMs": true],
            ["points": Array(repeating: ["x": 20, "y": 20], count: 3), "durationMs": 100]
        ]
        for (index, payload) in invalid.enumerated() {
            do {
                _ = try IPadUseController.touchPayload(payload, width: 820, height: 1180)
                fatalError("invalid payload accepted: \(index)")
            } catch { check(true, "reject invalid payload \(index)") }
        }
        let fixture: [String: Any] = ["result": ["devices": [[
            "identifier": UUID().uuidString,
            "hardwareProperties": ["deviceType": "iPad"],
            "deviceProperties": ["name": "Fixture iPad"],
            "connectionProperties": ["transportType": "wired", "pairingState": "paired", "tunnelState": "connected", "tunnelIPAddress": "fd00::1"]
        ]]]]
        check(try IPadUseDevice.decode(JSONSerialization.data(withJSONObject: fixture)).count == 1, "discover paired wired iPad")
        let wire = String(data: try JSONSerialization.data(withJSONObject: fixture), encoding: .utf8)!
        for replaced in [wire.replacingOccurrences(of: "wired", with: "network"), wire.replacingOccurrences(of: "paired", with: "unpaired"), wire.replacingOccurrences(of: "connected", with: "unavailable")] {
            check(try IPadUseDevice.decode(Data(replaced.utf8)).isEmpty, "reject disconnected or untrusted transport")
        }
        let controller = IPadUseController()
        let caller = UUID()
        let status = controller.status(caller: caller)
        check(status["authorizedForCaller"] as? Bool == false, "starts unauthorized")
        check(status["pencilPressure"] as? String == "unsupported", "honest pressure capability")
        for method in ["ipad_screenshot", "ipad_touch", "ipad_stop"] {
            do {
                _ = try await controller.perform(method, params: [:], caller: caller)
                fatalError("unauthorized operation accepted")
            } catch { check(String(describing: error) == "ipad_ui_consent_required_for_this_thread", "deny \(method) without consent") }
        }
        controller.stop()
        check(controller.status(caller: caller)["connected"] as? Bool == false, "stop idempotent")
        controller.fixtureSession(owner: caller, allowTouch: false)
        check(controller.status(caller: caller)["authorizedForCaller"] as? Bool == true, "owner may read authorized session")
        check(controller.status(caller: UUID())["authorizedForCaller"] as? Bool == false, "other thread does not inherit device consent")
        check(controller.status(caller: caller)["touchAuthorizedForCaller"] as? Bool == false, "read-only authorization stays read-only")
        let unrelatedDevice = IPadUseDevice(id: UUID().uuidString, name: "Other iPad", address: "fd00::1")
        await controller.connectAndAuthorize(unrelatedDevice, threadID: UUID())
        check(controller.status(caller: caller)["authorizedForCaller"] as? Bool == true,
              "quick connect cannot take another thread's authorization")
        await controller.connectAndAuthorize(unrelatedDevice, threadID: caller)
        check(controller.status(caller: caller)["touchAuthorizedForCaller"] as? Bool == false,
              "quick connect cannot authorize a different device than the consent")
        await controller.authorize(threadID: caller, allowTouch: false)
        check(controller.status(caller: caller)["authorizedForCaller"] as? Bool == true, "same owner authorization is idempotent without a device request")
        do {
            _ = try await controller.perform("ipad_touch", params: valid, caller: caller)
            fatalError("read-only session accepted touch")
        } catch {
            check(String(describing: error) == "ipad_touch_consent_required", "read-only session denies touch without network access")
        }
        if ProcessInfo.processInfo.environment["TATWO_IPAD_LONG_SESSION_TEST"] == "1" {
            print("WAIT: authorized session idle for 305 seconds")
            fflush(stdout)
            try await Task.sleep(for: .seconds(305))
        }
        check(controller.status(caller: caller)["authorizedForCaller"] as? Bool == true, "waiting preserves session authorization")
        check(controller.status(caller: caller)["authorizationExpired"] as? Bool == false, "no wall-clock consent expiry")
        let stopped = try await controller.perform("ipad_stop", params: [:], caller: caller)
        check(stopped["authorizationRevoked"] as? Bool == true, "owner can still stop")
        check(controller.status(caller: caller)["authorizedForCaller"] as? Bool == false, "stop immediately revokes authorization")
        check(controller.status(caller: caller)["connected"] as? Bool == false, "stop disconnects")
        controller.fixtureSession(owner: caller, allowTouch: true)
        check(controller.status(caller: caller)["touchAuthorizedForCaller"] as? Bool == true, "new explicit session restores touch permission")
        controller.stop()
        let failureLog = FileManager.default.temporaryDirectory.appendingPathComponent("device-exit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: failureLog) }
        try Data("Timed out while enabling automation mode.".utf8).write(to: failureLog)
        check(IPadUseController.deviceExitMessage(logURL: failureLog).contains("這不代表裝置被鎖定"),
              "automation timeout is not misreported as a locked iPad")
        try Data("Missing test product at private location".utf8).write(to: failureLog)
        check(IPadUseController.deviceExitMessage(logURL: failureLog).contains("重新建立"),
              "missing test product offers setup recovery without exposing raw paths")
        try Data("unknown device failure with private details".utf8).write(to: failureLog)
        let genericFailure = IPadUseController.deviceExitMessage(logURL: failureLog)
        check(!genericFailure.contains("private details") && !genericFailure.contains("解鎖")
                && !genericFailure.contains("信任"),
              "unknown failures neither expose private logs nor invent lock or trust diagnoses")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("tatwo-source-\(UUID().uuidString).xctestrun")
        let fixtureBundle: [String: Any] = ["TatwoIPadDevice": [
            "BlueprintName": "TatwoIPadDevice",
            "TestBundlePath": "__TESTROOT__/TatwoIPadDevice.xctest",
            "TestHostBundleIdentifier": "ai.tatwo.ipaduse.device.xctrunner",
            "EnvironmentVariables": ["SAFE": "1"]
        ]]
        try PropertyListSerialization.data(fromPropertyList: fixtureBundle, format: .binary, options: 0).write(to: source)
        check(IPadUseController.isTatwoTestBundle(source), "accept TATWO device identity")
        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-\(UUID().uuidString).xctestrun")
        try PropertyListSerialization.data(fromPropertyList: ["Foreign": ["TestHostBundleIdentifier": "example.foreign"]], format: .binary, options: 0).write(to: foreign)
        check(!IPadUseController.isTatwoTestBundle(foreign), "reject foreign device identity")
        let prepared = try IPadUseController.prepareTestBundle(source, token: String(repeating: "a", count: 64))
        let preparedRoot = try PropertyListSerialization.propertyList(from: Data(contentsOf: prepared), format: nil) as! [String: Any]
        let preparedConfiguration = preparedRoot["TatwoIPadDevice"] as! [String: Any]
        check((preparedConfiguration["TestBundlePath"] as? String)?.contains("__TESTROOT__") == false, "resolve test root before private copy")
        check((preparedConfiguration["EnvironmentVariables"] as? [String: String])?["TATWO_IPAD_USE_TOKEN"]?.count == 64, "inject ephemeral token")
        let permissions = try FileManager.default.attributesOfItem(atPath: prepared.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue & 0o077 == 0, "private runtime test bundle")
        check(IPadUseController.recoveryToken(from: prepared) == String(repeating: "a", count: 64), "owned private bundle supports stop-only recovery")
        check(IPadUseController.recoveryToken(from: source) == nil, "recovery refuses paths outside private session directory")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: prepared.path)
        check(IPadUseController.recoveryToken(from: prepared) == nil, "recovery refuses public-readable session file")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: prepared.path)
        let link = prepared.deletingLastPathComponent().appendingPathComponent("session-link-\(UUID().uuidString).xctestrun")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prepared)
        check(IPadUseController.recoveryToken(from: link) == nil, "recovery refuses symlink substitution")
        try FileManager.default.removeItem(at: link)
        check(IPadUseController.recoveryOwnerIsActive(pid: 0), "invalid owner never permits recovery")
        check(IPadUseController.recoveryOwnerIsActive(pid: 1), "another live process blocks takeover")
        check(!IPadUseController.recoveryOwnerIsActive(pid: Int(getpid())), "same-process stopped-runner retry is allowed")
        check(IPadUseController.recoveryOwnerIsActive(pid: Int.max), "overflowing PID fails closed")
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: foreign)
        try? FileManager.default.removeItem(at: prepared)
        print("RESULT tests=\(passed) failed=0 skipped=0")
    }
}
