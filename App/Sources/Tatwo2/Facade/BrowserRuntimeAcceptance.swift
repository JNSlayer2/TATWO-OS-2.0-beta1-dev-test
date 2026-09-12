import AppKit
import Foundation

/// Opt-in integration check against a public echo form or sign-in entry. Uses an empty,
/// explicitly supplied fixture root, never the user's browser/account profile.
@MainActor
enum BrowserRuntimeAcceptance {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private final class Reply<T> {
        var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func finish(_ value: T) {
            let pending = continuation
            continuation = nil
            pending?.resume(returning: value)
        }
    }
    static func bounded<T>(
        fallback: T, _ start: (@escaping (T) -> Void) -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            let reply = Reply(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { reply.finish(fallback) }
            start { reply.finish($0) }
        }
    }
    static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
    static func snapshot(_ browser: TatwoCEFBrowserView) async throws -> [String: Any] {
        let result: (String?, String?) = await bounded(fallback: (nil, "fixture_snapshot_timeout")) { finish in
            browser.captureVisibleSnapshot { finish(($0, $1)) }
        }
        guard let json = result.0, let data = json.data(using: .utf8),
              let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(result.1 ?? "fixture_snapshot_missing")
        }
        return snapshot
    }
    private static func type(
        _ text: String, into field: [String: Any], browser: TatwoCEFBrowserView
    ) async throws {
        guard let id = field["elementID"] as? String else { throw Failure("fixture_field_missing_id") }
        let result: (Bool, String?) = await bounded(fallback: (false, "fixture_type_timeout")) { finish in
            browser.typeText(text, elementID: id, navigationGeneration: browser.navigationGeneration,
                             submit: false) { finish(($0, $1)) }
        }
        guard result.0 else { throw Failure(result.1 ?? "fixture_type_failed") }
    }

    static func run() async -> Bool {
        let env = ProcessInfo.processInfo.environment
        let tradingView = env["TATWO2_BROWSER_LOGIN_ENTRY_TEST"] == "1"
        let popupTest = env["TATWO2_BROWSER_POPUP_TEST"] == "1"
        guard let root = env["TATWO2_ISSUE_TEST_ROOT"],
              env["HOME"] == root, env["TATWO2_LIVE_ROOT"] == root + "/live",
              FileManager.default.fileExists(atPath: root + "/fixture-only"),
              !FileManager.default.fileExists(atPath: root + "/cef-root") else {
            print("BROWSERRUNTIMETEST FAIL fresh_explicit_fixture_root_required")
            return false
        }
        var passed = 0
        var browser: TatwoCEFBrowserView?
        var window: NSWindow?
        var success = false
        func require(_ label: String, _ ok: Bool) throws {
            print("BROWSERRUNTIMETEST \(ok ? "PASS" : "FAIL") \(label)")
            guard ok else { throw Failure(label) }
            passed += 1
        }
        do {
            try require("compiled_actual_chromium", TatwoCEFRuntime.compiled)
            try require("CEF_application_host", NSApp is TatwoCEFApplication)
            guard let helper = EmbeddedBrowserEnginePolicy.helperExecutableURL(in: .main) else {
                throw Failure("fixture_helper_missing")
            }
            try FileManager.default.createDirectory(
                atPath: root + "/cef-root", withIntermediateDirectories: true)
            try TatwoCEFRuntime.initialize(
                withRootCachePath: root + "/cef-root", helperExecutablePath: helper.path,
                logFilePath: root + "/cef.log",
                bundledDenyListPath: BrowserBundledHostDenyList.verifiedResourceURL().path)
            let view = try TatwoCEFBrowserView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 420),
                persistentProfile: nil, initialURL: popupTest ? BrowserPopupAcceptance.pageURL
                    : (tradingView ? "https://www.tradingview.com/accounts/signin/"
                        : "https://httpbin.org/forms/post"))
            browser = view
            var phase: TatwoCEFBrowserPhase = .creating
            var status = 0
            view.stateHandler = { _, _, _, _, _, newPhase, httpStatus, _, _, _ in
                phase = newPhase
                status = httpStatus
            }
            let fixtureWindow = NSWindow(
                contentRect: NSRect(x: 80, y: 80, width: 800, height: 420),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            fixtureWindow.title = "TATWO Browser — isolated acceptance"
            fixtureWindow.isReleasedWhenClosed = false
            fixtureWindow.contentView = view
            window = fixtureWindow
            fixtureWindow.orderFront(nil) // Do not activate or steal keyboard focus.
            let loaded = await waitUntil {
                phase == .finished || phase == .blockedBySecurity || phase == .navigationFailed
                    || phase == .rendererFailed || phase == .startupFailed
            }
            print("BROWSERRUNTIMETEST ENTRY phase=\(phase.rawValue) status=\(status) waitCompleted=\(loaded)")
            try require(popupTest ? "public_popup_fixture_loaded" :
                        (tradingView ? "public_signin_entry_loaded" : "public_form_loaded"),
                        loaded && phase == .finished && status == 200)
            if env["TATWO2_BROWSER_LOGIN_INSPECT"] == "1" {
                print("BROWSERINSPECT READY public signin only; no account acceptance")
                try? await Task.sleep(for: .seconds(45))
            } else if popupTest {
                try await BrowserPopupAcceptance.run(
                    browser: view, hostWindow: fixtureWindow, check: require)
            } else if tradingView {
                // No account interaction or input; this is not account-login acceptance.
                try? await Task.sleep(for: .seconds(2))
                let entry = try await snapshot(view)
                let reader = BrowserAgentBridge.readSnapshot(
                    entry, url: view.currentURLString ?? "", maxChars: 12000)
                try JSONSerialization.data(withJSONObject: reader, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: root + "/public-signin-entry.json"))
                try require("signin_entry_snapshot_available",
                            !(reader["text"] as? String ?? "").isEmpty)
                let controls = BrowserAgentBridge.clickElements(entry)
                guard let email = BrowserAgentBridge.uniqueElement(
                        controls, selector: nil, label: "Email"),
                      let rect = email["rect"] as? [String: Any],
                      let viewport = entry["viewport"] as? [String: Any],
                      let point = BrowserAgentBridge.clickPoint(
                        rect: rect, viewport: viewport, size: view.bounds.size) else {
                    throw Failure("email_signin_control_missing")
                }
                try require("email_signin_click_accepted",
                            view.sendClick(at: point, navigationGeneration: view.navigationGeneration))
                var passwordVisible = false
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(200))
                    let form = try await snapshot(view)
                    let fields = (form["forms"] as? [[String: Any]] ?? [])
                        .flatMap { $0["fields"] as? [[String: Any]] ?? [] }
                    if fields.contains(where: { $0["type"] as? String == "password" }) {
                        passwordVisible = true
                        break
                    }
                    if phase == .blockedBySecurity || phase == .navigationFailed { break }
                }
                try require("email_login_form_visible_without_OS_block",
                            passwordVisible && phase != .blockedBySecurity)
            } else {
            let first = try await snapshot(view)
            // Only the initial public form, before typing; never save the echo response.
            try JSONSerialization.data(withJSONObject: first, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: root + "/public-form-safe-snapshot.json"))
            let fields = (first["forms"] as? [[String: Any]] ?? [])
                .flatMap { $0["fields"] as? [[String: Any]] ?? [] }
            guard let name = BrowserAgentBridge.uniqueElement(fields, selector: nil, label: "Customer name"),
                  let email = fields.first(where: { $0["type"] as? String == "email" }) else {
                throw Failure("visible_form_fields_missing")
            }
            try require("actual_snapshot_exposes_later_field", name["elementID"] as? String != email["elementID"] as? String)
            let nameText = "輕量瀏覽器 🐱"
            let emailText = "fixture@example.invalid"
            try await type(nameText, into: name, browser: view)
            try require("CDP_name_input_completed", true)
            try await type(emailText, into: email, browser: view)
            try require("CDP_later_email_input_completed", true)
            let afterTyping = try await snapshot(view)
            let reader = BrowserAgentBridge.readSnapshot(afterTyping, url: view.currentURLString ?? "", maxChars: 8000)
            let visibleText = reader["text"] as? String ?? ""
            try require("reader_does_not_echo_input_values",
                        !visibleText.contains(nameText) && !visibleText.contains(emailText))
            let beforeScroll = (first["viewport"] as? [String: Any])?["scrollY"] as? Double ?? 0
            try require("native_scroll_accepted",
                        view.sendScrollDeltaY(400, navigationGeneration: view.navigationGeneration))
            try? await Task.sleep(for: .milliseconds(350))
            let afterScroll = try await snapshot(view)
            let afterScrollY = (afterScroll["viewport"] as? [String: Any])?["scrollY"] as? Double ?? 0
            try require("actual_page_scrolled", afterScrollY > beforeScroll)
            guard let submit = BrowserAgentBridge.uniqueElement(
                    BrowserAgentBridge.clickElements(afterScroll), selector: nil, label: "Submit order"),
                  let rect = submit["rect"] as? [String: Any],
                  let viewport = afterScroll["viewport"] as? [String: Any],
                  let point = BrowserAgentBridge.clickPoint(rect: rect, viewport: viewport, size: view.bounds.size) else {
                throw Failure("visible_submit_button_missing")
            }
            let generation = view.navigationGeneration
            try require("native_submit_click_accepted",
                        view.sendClick(at: point, navigationGeneration: generation))
            let submitted = await waitUntil {
                view.navigationGeneration > generation && phase == .finished
            }
            try require("public_echo_post_completed", submitted
                        && URL(string: view.currentURLString ?? "")?.path == "/post" && status == 200)
            let echo = try await snapshot(view)
            let echoText = (echo["blocks"] as? [[String: Any]] ?? [])
                .filter { $0["quarantined"] as? Bool != true }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            let echoed = echoText.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let form = echoed?["form"] as? [String: Any]
            try require("server_echo_confirms_exact_two_field_values",
                        form?["custname"] as? String == nameText && form?["custemail"] as? String == emailText)
            // Never print the echo document: it includes network/request metadata.
            }
            success = true
        } catch {
            print("BROWSERRUNTIMETEST ERROR \(error)")
        }
        if let browser {
            let closed = await bounded(fallback: false) { finish in
                browser.closeBrowser { finish(true) }
            }
            print("BROWSERRUNTIMETEST \(closed ? "PASS" : "FAIL") native_close_confirmed")
            if closed { passed += 1 } else { success = false }
            let hostPreserved = window?.isVisible == true
            print("BROWSERRUNTIMETEST \(hostPreserved ? "PASS" : "FAIL") close_preserves_host_window")
            if hostPreserved { passed += 1 } else { success = false }
            browser.removeFromSuperview()
        }
        window?.close()
        TatwoCEFRuntime.shutdown()
        print("BROWSERRUNTIMETEST RESULT passed=\(passed) failed=\(success ? 0 : 1) skipped=0")
        return success
    }
}
