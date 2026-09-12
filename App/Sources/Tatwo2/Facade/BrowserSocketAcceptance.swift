import AppKit
import Darwin
import Foundation

/// Real local sockets, isolated library, no browser navigation or native model.
enum BrowserSocketAcceptance {
    @MainActor static func run() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_BROWSER_SOCKET"] == path + "/browser.sock",
              env["TATWO2_LIVE_ROOT"] == path + "/live",
              env["TATWO2_ENGINES_ROOT"] == path + "/engines",
              FileManager.default.fileExists(atPath: path + "/fixture-only")
        else { return false }
        let root = URL(fileURLWithPath: path)
        var passed = 0, failed = 0
        func check(_ name: String, _ success: Bool) {
            if success { passed += 1 } else { failed += 1 }
            print("BROWSERSOCKETTEST \(success ? "PASS" : "FAIL") \(name)")
        }
        func kind(_ path: String) -> String {
            switch BrowserAgentBridge.probeSocket(at: path) {
            case .absent: return "absent"
            case .alive: return "alive"
            case .stale: return "stale"
            case .unknown: return "unknown"
            }
        }
        func address(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
            var value = sockaddr_un()
            value.sun_family = sa_family_t(AF_UNIX)
            guard path.utf8.count < MemoryLayout.size(ofValue: value.sun_path) else { return -1 }
            withUnsafeMutablePointer(to: &value.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
            }
            return withUnsafePointer(to: &value) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        let socketPath = path + "/browser.sock"
        check("missing path is absent", kind(socketPath) == "absent")
        let file = root.appendingPathComponent("ordinary-file")
        try? Data("preserve me".utf8).write(to: file)
        check("ordinary file is not classified as stale", kind(file.path) == "unknown")
        check("non-directory path is not classified as absent", kind(file.path + "/child") == "unknown")
        let symlink = path + "/symbolic-link"
        try? FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: file.path)
        check("symlink is unknown even with an existing destination", kind(symlink) == "unknown")
        let dangling = path + "/dangling"
        try? FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: path + "/missing")
        check("dangling symlink is not classified as absent", kind(dangling) == "unknown")
        check("overlong socket path is unknown", kind(path + String(repeating: "x", count: 110)) == "unknown")
        let stalePath = path + "/stale.sock"
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        check("fixture can bind a socket", stale >= 0 && address(stalePath, { Darwin.bind(stale, $0, $1) }) == 0)
        if stale >= 0 { close(stale) }
        check("closed listener is stale", kind(stalePath) == "stale")
        check("probe leaves stale socket in place", FileManager.default.fileExists(atPath: stalePath))

        let engine = ChatLiveEngine(store: ChatLiveStore(root: root.appendingPathComponent("live")), environment: env)
        let model = ChatPageModel(environment: env, botCoreFixture: (engine, BotStore(root: root.appendingPathComponent("live"))))
        BrowserAgentBridge.shared.start(model: model)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        check("new listener becomes alive", kind(socketPath) == "alive")
        func connectClient() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            var timeout = timeval(tv_sec: 6, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            if address(socketPath, { connect(fd, $0, $1) }) != 0 { close(fd); return -1 }
            return fd
        }
        func request(_ body: String, eof: Bool = false) -> [String: Any]? {
            let fd = connectClient()
            guard fd >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.write(contentsOf: Data(body.utf8))
            if eof { _ = shutdown(fd, SHUT_WR) }
            guard let response = try? handle.readToEnd() else { return nil }
            return (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        }
        let body = "{\"id\":17,\"method\":\"fixture_unknown_method\",\"params\":{}}"
        let start = ProcessInfo.processInfo.systemUptime
        let response = request(body + "\n")
        check("newline request gets response without client EOF", response?["id"] as? Int == 17)
        check("newline response is immediate", ProcessInfo.processInfo.systemUptime - start < 1.5)
        check("unsupported method is explicit", response?["error"] as? String == "unsupported_method")
        check("legacy EOF-terminated request still works", request(body, eof: true)?["id"] as? Int == 17)
        let silent = connectClient()
        check("silent peer fixture connected", silent >= 0)
        let resumedAt = ProcessInfo.processInfo.systemUptime
        let resumed = request(body + "\n")
        check("silent peer cannot wedge later requests", resumed?["id"] as? Int == 17)
        check("silent peer has a bounded wait", ProcessInfo.processInfo.systemUptime - resumedAt < 5)
        if silent >= 0 { close(silent) }
        check("malformed input returns a clear error", request("not-json\n")?["error"] as? String == "bad_request")
        check("oversized input is rejected before dispatch",
              request(String(repeating: "x", count: 1_048_577))?["error"] as? String == "request_incomplete_or_too_large")
        check("listener recovers after oversized input", request(body + "\n")?["id"] as? Int == 17)
        check("listener remains alive after malformed input", kind(socketPath) == "alive")
        check("probe preserved ordinary file", (try? String(contentsOf: file, encoding: .utf8)) == "preserve me")
        check("isolated test never starts a model", engine.doc.threads.allSatisfy { engine.sidecarProcessID(threadID: $0.id) == nil })
        print("BROWSERSOCKETTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
