import AppKit
import Foundation

/// Exercises the production resolver without opening a website, launching a
/// browser helper, registering sockets, or showing windows on the user's desktop.
enum BrowserRoutingAcceptance {
    @MainActor private final class FixtureWindow: NSWindow {
        var fixtureVisible = true
        var fixtureMiniaturized = false
        override var isVisible: Bool { fixtureVisible }
        override var isMiniaturized: Bool { fixtureMiniaturized }
    }
    private final class SurfaceView: NSView {}

    @MainActor static func run() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["TATWO2_ISSUE_TEST_ROOT"],
              env["TATWO2_LIVE_ROOT"] == root + "/live",
              FileManager.default.fileExists(atPath: root + "/fixture-only") else { return false }
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("BROWSERROUTINGTEST \(ok ? "PASS" : "FAIL") \(name)")
        }
        var clock: TimeInterval = 0
        var routes: [EmbeddedBrowserEngine] = []
        var sleeps: [TimeInterval] = []
        func reset() { clock = 0; routes = []; sleeps = [] }
        func wait(_ engine: EmbeddedBrowserEngine, readyAfter: Int, timeout: TimeInterval = 20) -> String? {
            BrowserAgentBridge.waitForSurface(engine: engine, timeout: timeout,
                now: { clock }, sleep: { sleeps.append($0); clock += $0 }, find: {
                    routes.append($0)
                    return routes.count >= readyAfter ? "surface" : nil
                })
        }
        check("ready CEF resolves immediately", wait(.chromiumCEF, readyAfter: 1) == "surface" && sleeps.isEmpty)
        check("CEF never probes WebKit", routes == [.chromiumCEF])
        reset()
        check("ready WebKit resolves immediately", wait(.webKitLegacy, readyAfter: 1) == "surface" && sleeps.isEmpty)
        check("WebKit never probes CEF", routes == [.webKitLegacy])
        reset()
        check("unavailable CEF neither polls nor falls back", wait(.chromiumUnavailable, readyAfter: 1) == nil && routes.isEmpty && sleeps.isEmpty)
        reset()
        check("CEF mount is awaited on its own route", wait(.chromiumCEF, readyAfter: 4) == "surface" && routes.count == 4 && clock < 0.2)
        check("pending CEF probes only CEF", routes.allSatisfy { $0 == .chromiumCEF })
        reset()
        check("WebKit mount uses the same bounded wait", wait(.webKitLegacy, readyAfter: 3) == "surface" && sleeps.count == 2)
        reset()
        check("mount deadline is one budget, not ten plus twenty seconds", wait(.chromiumCEF, readyAfter: .max, timeout: 0.12) == nil && abs(clock - 0.12) < 0.000001)
        check("last sleep respects remaining deadline", sleeps.allSatisfy { $0 > 0 && $0 <= 0.05 })
        reset()
        check("zero timeout still performs one immediate probe", wait(.webKitLegacy, readyAfter: 1, timeout: 0) == "surface" && sleeps.isEmpty)
        reset()
        check("negative timeout does not sleep", wait(.webKitLegacy, readyAfter: 2, timeout: -1) == nil && routes.count == 1 && sleeps.isEmpty)

        func window() -> FixtureWindow {
            let result = FixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                                       styleMask: .borderless, backing: .buffered, defer: true)
            result.isReleasedWhenClosed = false
            return result
        }
        let main = window(), other = window(), inspector = window()
        let first = SurfaceView(frame: main.contentView!.bounds)
        let second = SurfaceView(frame: other.contentView!.bounds)
        main.contentView!.addSubview(first); other.contentView!.addSubview(second)
        func find(_ root: NSView) -> SurfaceView? {
            BrowserAgentBridge.uniqueVisibleSurface(in: root) { $0 as? SurfaceView }
        }
        func resolve(_ windows: [NSWindow], main: NSWindow? = nil, key: NSWindow? = nil) -> SurfaceView? {
            BrowserAgentBridge.surfaceInCurrentWindow(windows: windows, mainWindow: main, keyWindow: key, find: find)
        }
        check("current document wins over earlier window enumeration", resolve([other, main], main: main) === first)
        check("key inspector does not redirect the document", resolve([inspector, other, main], main: main, key: inspector) === first)
        check("key window works without a main document", resolve([other, main], key: main) === first)
        check("mounting document cannot fall through to a different window", resolve([other, inspector], main: inspector) == nil)
        check("mounting key window cannot fall through", resolve([other, inspector], key: inspector) == nil)
        check("one visible browser works without taking focus", resolve([main, inspector]) === first)
        check("two unfocused browser windows are ambiguous", resolve([main, other]) == nil)
        main.fixtureMiniaturized = true
        check("minimized current document does not select another page", resolve([other, main], main: main) == nil)
        main.fixtureMiniaturized = false
        main.fixtureVisible = false
        check("hidden current document does not select another page", resolve([other, main], main: main) == nil)
        check("hidden windows excluded from unique fallback", resolve([main, other]) === second)
        main.fixtureVisible = true
        first.isHidden = true
        check("hidden browser view is excluded", resolve([main], main: main) == nil)
        first.isHidden = false
        let group = NSView(frame: main.contentView!.bounds)
        let third = SurfaceView(frame: group.bounds)
        main.contentView!.addSubview(group); group.addSubview(third)
        check("multiple browser views in one document are ambiguous", resolve([main], main: main) == nil)
        let fourth = SurfaceView(frame: group.bounds)
        group.addSubview(fourth)
        check("nested ambiguity cannot hide behind a valid sibling", resolve([main], main: main) == nil)
        group.isHidden = true
        check("hidden ancestor excludes its entire browser subtree", resolve([main], main: main) === first)
        let detached = SurfaceView(frame: .zero)
        check("detached browser is never selected", find(detached) == nil)
        // No orderFront/orderBack/run or activation: fixture windows remain offscreen.
        print("BROWSERROUTINGTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
