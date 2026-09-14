import AppKit
import UniformTypeIdentifiers

// Fake CEF transport, actual production AppKit controller. No browser/profile/network/files.
typealias TatwoCEFFileDialogCompletion = ([String]?) -> Void
enum TatwoCEFBrowserActor { case human, agent }
@MainActor final class TatwoCEFBrowserView: NSView {
    var browserActor = TatwoCEFBrowserActor.human
    var agentControlled = false
    var navigationGeneration: UInt64 = 1
    var currentURLString: String? = "https://example.test/fixture.pdf"
    var onFileDialog: ((Int, String, String, [String], Bool, @escaping TatwoCEFFileDialogCompletion) -> Void)?
    var onFullscreenModeChange: ((Bool) -> Void)?
    var onWebFeaturesInvalidated: (() -> Void)?
    var pdfReply: ((String?) -> Void)?
    var printCount = 0
    func exitContentFullscreen() { onFullscreenModeChange?(false) }
    func printToPDF(completion: @escaping (String?) -> Void) { printCount += 1; pdfReply = completion }
    func downloadCurrentPDF(completion: @escaping (String?) -> Void) { pdfReply = completion }
}
@MainActor enum BrowserHumanInteraction {
    static func oneLine(_ value: String) -> String { value }
}
// INSERT coordinator

@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        precondition(BrowserWebFeatures.contentTypes([".pdf", "application/pdf"]) == [.pdf])
        precondition(BrowserWebFeatures.contentTypes(["image/*", "audio/*", "video/*", "text/*"]) ==
                     [.image, .audio, .movie, .text])
        precondition(BrowserWebFeatures.contentTypes([".png", "*/*"]).isEmpty)
        precondition(BrowserWebFeatures.contentTypes([]).isEmpty)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        // A narrow panel intentionally excludes the fullscreen view's midpoint.
        let container = NSView(frame: NSRect(x: 800, y: 0, width: 200, height: 600))
        root.addSubview(container)
        let browser = TatwoCEFBrowserView(frame: container.bounds)
        container.addSubview(browser)
        let editor = NSTextView(frame: browser.bounds)
        editor.autoresizingMask = [.width, .height]
        browser.addSubview(editor)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderBack(nil)
        window.makeFirstResponder(editor)
        let features = BrowserWebFeatures(browser: browser, container: container)
        for _ in 0..<3 {
            browser.onFullscreenModeChange?(true)
            precondition(browser.superview !== container && browser.frame == root.bounds)
            precondition(BrowserWebFeatures.focusOwner(for: editor) === container)
            precondition(window.firstResponder === editor)
            browser.exitContentFullscreen()
            precondition(browser.superview === container && browser.frame == container.bounds)
            precondition(root.subviews.count == 1 && window.firstResponder === editor)
        }
        // Rejected native dialogs never mount a picker.
        var refused = 0
        browser.agentControlled = true
        browser.onFileDialog?(0, "", "", [], false) { paths in
            precondition(paths == nil); refused += 1
        }
        browser.agentControlled = false
        browser.browserActor = .agent
        browser.onFileDialog?(3, "", "", [], false) { paths in
            precondition(paths == nil); refused += 1
        }
        precondition(refused == 2 && window.attachedSheet == nil)
        browser.onFullscreenModeChange?(true)
        precondition(browser.superview === container) // agent cannot cover host UI
        browser.browserActor = .human
        features.requestPDF()
        precondition(browser.printCount == 1)
        let late = browser.pdfReply
        browser.onWebFeaturesInvalidated?() // Swift revocation precedes CEF cancellation callback
        late?(nil)
        precondition(window.attachedSheet == nil)
        features.requestPDF(download: true)
        let staleDocument = browser.pdfReply
        browser.navigationGeneration += 1
        staleDocument?(nil)
        precondition(window.attachedSheet == nil)
        browser.onFullscreenModeChange?(true)
        features.invalidate()
        precondition(browser.superview === container && root.subviews.count == 1)
        window.contentView = nil
        window.close()
        print("W57d AppKit coordinator fixture passed: filters/fullscreen/focus/restore/agent/revocation")
    }
}
