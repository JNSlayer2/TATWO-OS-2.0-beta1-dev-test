import AppKit
import WebKit

/// Exercises the coordinator's production policy handlers without loading a
/// page or inventing WKNavigationAction/WKFrameInfo runtime internals.
@MainActor
enum BrowserNavigationAcceptance {
    private struct Action {
        let url: URL
        let main: Bool
        let download: Bool
        init(_ url: String, main: Bool, download: Bool = false) {
            self.url = URL(string: url)!
            self.main = main
            self.download = download
        }
    }

    private struct Response {
        let fixtureResponse: URLResponse
        let main: Bool
        let displayable: Bool
        init(_ url: String, main: Bool, status: Int = 200,
             displayable: Bool = true, attachment: Bool = false) {
            self.main = main
            self.displayable = displayable
            fixtureResponse = HTTPURLResponse(
                url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: attachment
                    ? ["Content-Disposition": "attachment; filename=fixture.txt"] : [:])!
        }
    }

    private final class Probe {
        var allowed = false
        var state: EmbeddedBrowserNavigationState?
    }

    static func run() -> Bool {
        var passed = 0, failed = 0
        func check(_ label: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("BROWSERNAVIGATIONTEST \(ok ? "PASS" : "FAIL") \(label)")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        let probe = Probe()
        let coordinator = EmbeddedBrowserWebView.Coordinator(
            profile: .ephemeral(UUID()),
            annotationStore: EmbeddedBrowserAnnotationStore(
                fileURL: URL(fileURLWithPath: "/dev/null")),
            navigationJournalStore: EmbeddedBrowserNavigationJournalStore(
                profileRoot: URL(fileURLWithPath: "/dev/null")),
            onNavigationStateChange: { probe.state = $0 })
        func reset(loading: Bool = false) {
            coordinator.phase = loading ? .loading : .finished
            coordinator.isLoading = loading
            coordinator.committedMainFrameURLString = "https://example.com/"
            coordinator.httpStatusCode = 200
            coordinator.visibleError = nil
            coordinator.structuredError = nil
            probe.allowed = false
        }
        func pageIntact(loading: Bool = false) -> Bool {
            coordinator.publishState(for: view)
            return coordinator.phase == (loading ? .loading : .finished)
                && coordinator.isLoading == loading
                && coordinator.httpStatusCode == 200
                && coordinator.visibleError == nil
                && coordinator.structuredError == nil
                && coordinator.committedMainFrameURLString == "https://example.com/"
                && (loading || probe.state.map {
                    EmbeddedBrowserSurfacePresentation.condition(for: $0) == .none
                } == true)
        }
        func action(_ value: Action) {
            probe.allowed = coordinator.navigationActionPolicy(
                url: value.url, targetIsMainFrame: value.main,
                shouldDownload: value.download, in: view) == .allow
        }
        func response(_ value: Response) {
            probe.allowed = coordinator.navigationResponsePolicy(
                response: value.fixtureResponse, isMainFrame: value.main,
                canShowMIMEType: value.displayable, in: view) == .allow
        }
        for url in ["about:blank", "file:///fixture.txt", "https://localhost/",
                    "http://127.0.0.1/", "http://" + [192, 168, 1, 1].map(String.init).joined(separator: ".") + "/"] {
            reset()
            action(Action(url, main: false))
            check("denied iframe stays denied: \(url)", !probe.allowed)
            check("denied iframe preserves main page: \(url)", pageIntact())
        }
        reset(loading: true)
        action(Action("about:blank", main: false))
        check("iframe refusal cannot stop main-page loading", pageIntact(loading: true))
        reset()
        action(Action("https://example.com/login", main: false))
        check("public iframe navigation still allowed", probe.allowed && pageIntact())
        reset()
        action(Action("https://example.com/file", main: false, download: true))
        check("iframe download denied without replacing page",
              !probe.allowed && pageIntact())
        reset()
        action(Action("file:///fixture.txt", main: true))
        check("unsafe main navigation remains visibly blocked",
              !probe.allowed && coordinator.phase == .blockedBySecurity
              && coordinator.structuredError?.kind == .security)
        for status in [204, 401, 500] {
            reset()
            response(Response("https://example.com/frame", main: false, status: status))
            check("iframe HTTP \(status) cannot overwrite main status",
                  probe.allowed && pageIntact())
        }
        for value in [
            Response("file:///fixture.txt", main: false),
            Response("https://example.com/file", main: false, attachment: true),
            Response("https://example.com/file", main: false, displayable: false),
        ] {
            reset()
            response(value)
            check("unsafe iframe response denied without replacing page",
                  !probe.allowed && pageIntact())
        }
        reset()
        response(Response("https://example.com/", main: true, status: 503))
        check("main HTTP failure is retained", probe.allowed
              && coordinator.httpStatusCode == 503)
        reset()
        response(Response("https://example.com/file", main: true, attachment: true))
        check("main download refusal remains visible", !probe.allowed
              && coordinator.phase == .blockedBySecurity)
        reset()
        response(Response("https://example.com/", main: true))
        check("ordinary main response still allowed", probe.allowed && pageIntact())
        check("fixture never loaded a page", view.url == nil && !view.isLoading)
        print("BROWSERNAVIGATIONTEST RESULT passed=\(passed) failed=\(failed) skipped=0")
        return failed == 0
    }
}
