import AppKit
import Foundation

/// Synthetic public HTML only, under BrowserRuntimeAcceptance's empty-profile
/// gate. No real account, OAuth token, or production browser profile is used.
@MainActor
enum BrowserPopupAcceptance {
    private struct Failure: Error {
        let label: String
    }

    private static func publicHTML(_ html: String) -> String {
        let encoded = Data(html.utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return "https://httpbin.org/base64/" + encoded
    }

    static var pageURL: String {
        let child = publicHTML("""
        <!doctype html><title>Popup fixture</title><h1>Public login fixture</h1>
        <button onclick="opener.postMessage(document.cookie.includes('tatwo_popup_probe=1')?'shared-cookie-ok':'cookie-missing',location.origin);window.close()">Finish login</button>
        """)
        return publicHTML("""
        <!doctype html><title>Popup acceptance</title><h1>Popup acceptance</h1>
        <p id="result">Waiting for callback</p>
        <script>
        let child;
        document.cookie='tatwo_popup_probe=1;SameSite=Lax;Path=/';
        function start(blank) {
          document.getElementById('result').textContent='Waiting for callback';
          child=window.open(blank?'about:blank':'\(child)','login');
          if(blank&&child) child.location.href='\(child)';
        }
        onmessage=e=>{if(e.origin===location.origin&&e.source===child)document.getElementById('result').textContent=e.data};
        window.open('https://httpbin.org/html','automatic');
        </script>
        <button onclick="start(false)">Direct popup</button>
        <button onclick="start(true)">Blank popup</button>
        <button onclick="window.open('http://127.0.0.1:1','private')">Private popup</button>
        <button onclick="window.open('file:///etc/hosts','file')">File popup</button>
        """)
    }

    private static func popups(excluding parent: TatwoCEFBrowserView) -> [TatwoCEFBrowserView] {
        NSApp.windows.compactMap { $0.contentView as? TatwoCEFBrowserView }
            .filter { $0 !== parent && $0.window?.isVisible == true }
    }

    private static func click(_ label: String, in browser: TatwoCEFBrowserView) async throws {
        let snapshot = try await BrowserRuntimeAcceptance.snapshot(browser)
        guard let target = BrowserAgentBridge.uniqueElement(
            BrowserAgentBridge.clickElements(snapshot), selector: nil, label: label),
            let rect = target["rect"] as? [String: Any],
            let viewport = snapshot["viewport"] as? [String: Any],
            let point = BrowserAgentBridge.clickPoint(
                rect: rect, viewport: viewport, size: browser.bounds.size)
        else { throw Failure(label: "missing_control_\(label)") }
        guard browser.sendClick(at: point, navigationGeneration: browser.navigationGeneration)
        else { throw Failure(label: "click_rejected_\(label)") }
    }

    private static func open(_ label: String, from parent: TatwoCEFBrowserView) async throws -> TatwoCEFBrowserView {
        try await click(label, in: parent)
        let loaded = await BrowserRuntimeAcceptance.waitUntil {
            let views = popups(excluding: parent)
            return views.count == 1 && URL(string: views[0].currentURLString ?? "")?.host == "httpbin.org"
        }
        guard loaded, let child = popups(excluding: parent).first
        else { throw Failure(label: "popup_not_loaded_\(label)") }
        return child
    }

    static func run(browser: TatwoCEFBrowserView, hostWindow: NSWindow,
                    check: (String, Bool) throws -> Void) async throws {
        try check("automatic_popup_blocked_without_hiding_parent", popups(excluding: browser).isEmpty)
        let parentURL = browser.currentURLString
        let generation = browser.navigationGeneration
        for label in ["Direct popup", "Blank popup"] {
            let popup = try await open(label, from: browser)
            try check(label + "_has_separate_surface", popup !== browser && popup.window !== hostWindow)
            try check(label + "_shows_real_origin", popup.window?.title == "https://httpbin.org")
            try check(label + "_does_not_navigate_parent",
                      browser.currentURLString == parentURL && browser.navigationGeneration == generation)
            try await click("Finish login", in: popup)
            let closed = await BrowserRuntimeAcceptance.waitUntil { popups(excluding: browser).isEmpty }
            try check(label + "_script_close_completes", closed && popup.currentURLString == nil)
            let after = try await BrowserRuntimeAcceptance.snapshot(browser)
            let text = BrowserAgentBridge.readSnapshot(
                after, url: parentURL ?? "", maxChars: 8000)["text"] as? String ?? ""
            try check(label + "_opener_callback_and_shared_cookies", text.contains("shared-cookie-ok"))
        }
        for label in ["Private popup", "File popup"] {
            try await click(label, in: browser)
            try? await Task.sleep(for: .milliseconds(250))
            try check(label + "_rejected", popups(excluding: browser).isEmpty)
            _ = try await BrowserRuntimeAcceptance.snapshot(browser)
            try check(label + "_parent_still_readable", browser.currentURLString == parentURL)
        }
        let manuallyClosed = try await open("Direct popup", from: browser)
        manuallyClosed.window?.performClose(nil)
        let closed = await BrowserRuntimeAcceptance.waitUntil { popups(excluding: browser).isEmpty }
        try check("native_window_close_completes", closed && manuallyClosed.currentURLString == nil)
        try check("popup_closes_without_closing_host", hostWindow.isVisible)
        let childAtParentClose = try await open("Direct popup", from: browser)
        let parentClosed = await BrowserRuntimeAcceptance.bounded(fallback: false) { finish in
            browser.closeBrowser { finish(true) }
        }
        let childClosed = await BrowserRuntimeAcceptance.waitUntil { childAtParentClose.currentURLString == nil }
        try check("closing_parent_releases_popup", parentClosed && childClosed &&
                  popups(excluding: browser).isEmpty && hostWindow.isVisible)
    }
}
