import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = path => readFileSync(join(root, path), 'utf8');
const app = 'App/Sources/Tatwo2/Browser/';

test('actual popup AppKit controller retains CEF, routes search-field keys, restores focus and preserves fullscreen geometry', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-popup-features-'));
  const transport = source('tests/fixtures/browser-web-features-checks.swift').split('// INSERT coordinator')[0]
    .replace('    var printCount = 0', String.raw`
    var printCount = 0
    var reloadCount = 0
    var stopCount = 0
    var findStopCount = 0
    var zoomLevel = 0.0
    var finds: [String] = []
    var onFindResult: ((Int, Int) -> Void)?
    var onDailyShortcut: ((String) -> Void)?
    var onBrowserKeyEquivalent: ((NSEvent) -> Bool)?
    var onContextMenuAction: ((String, String) -> Void)?
    var onPopupRequested: ((String) -> Void)?
    func printPage() { printCount += 1 }
    func goBack() {}
    func goForward() {}
    func reload() { reloadCount += 1 }
    func stopLoading() { stopCount += 1 }
    func findText(_ text: String, forward: Bool, matchCase: Bool) { finds.append(text) }
    func stopFinding() { findStopCount += 1 }
    func setZoomLevel(_ level: Double) { zoomLevel = level }
    func performContextEdit(_ action: String) {}
    func downloadImageURL(_ url: String) {}
`);
  const popup = source(app + 'BrowserPopupFeatures.swift').replace('import TatwoCEFBridge', '');
  const features = source(app + 'BrowserWebFeatures.swift').replace('import TatwoCEFBridge', '');
  const nav = source(app + 'BrowserDailyNavigationControls.swift');
  const comboStart = nav.indexOf('extension BrowserKeyCombo {');
  const comboEnd = nav.indexOf('    var equivalent:', comboStart);
  assert.ok(comboStart >= 0 && comboEnd > comboStart);
  const combo = nav.slice(comboStart, comboEnd) + '\n}\n';
  // Keep real settings decoding while redirecting this process's settings file.
  const settings = source(app + 'BrowserGeneralSettings.swift').replace(
    'FileManager.default.homeDirectoryForCurrentUser',
    'URL(fileURLWithPath: CommandLine.arguments[1])');
  writeFileSync(join(dir, 'Settings.swift'), settings);
  writeFileSync(join(dir, 'Checks.swift'), transport + features + popup + combo + String.raw`
// Keep the test process behind the user's app while exercising AppKit dispatch.
@MainActor final class FixtureWindow: NSWindow { override var isKeyWindow: Bool { true } }
@MainActor final class MenuTrap: NSObject {
    var calls = 0
    @objc func find(_ sender: Any?) { calls += 1 }
}
@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let browser = TatwoCEFBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let editor = NSTextView(frame: browser.bounds)
        browser.addSubview(editor)
        let window = FixtureWindow(contentRect: browser.bounds, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = browser
        window.orderBack(nil)
        window.makeFirstResponder(editor)
        BrowserPopupFeatures.attach(to: browser)
        let root = window.contentView!
        precondition(root !== browser && browser.superview === root)
        precondition(window.firstResponder === editor)
        BrowserPopupFeatures.attach(to: browser)
        precondition(window.contentView === root) // Retention hook is idempotent.
        let bar = root.subviews.compactMap { $0 as? NSStackView }.first!
        let search = bar.arrangedSubviews.compactMap { $0 as? NSSearchField }.first!
        let trap = MenuTrap()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Host menu find", action: #selector(MenuTrap.find(_:)), keyEquivalent: "f")
        item.keyEquivalentModifierMask = .command
        item.target = trap
        menu.addItem(item)
        NSApp.mainMenu = menu
        func key(_ char: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                            characters: char, charactersIgnoringModifiers: char,
                            isARepeat: false, keyCode: 0)!
        }
        let flags = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
        precondition(BrowserKeyCombo(event: flags) == nil)
        let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        precondition(BrowserKeyCombo(event: mouse) == nil)
        precondition(window.isKeyWindow)
        NSApp.postEvent(key("f"), atStart: true)
        if let event = NSApp.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 0.1),
                                       inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        precondition(!bar.isHidden)
        precondition(trap.calls == 0)
        let fieldEditor = window.firstResponder as! NSTextView
        precondition(fieldEditor.delegate === search)
        search.stringValue = "popup fixture"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(browser.finds.last == "popup fixture")
        // CEF does not receive keys while the AppKit search field owns focus.
        precondition(root.performKeyEquivalent(with: key("r")))
        precondition(browser.reloadCount == 1)
        precondition(root.performKeyEquivalent(with: key("p")))
        precondition(browser.printCount == 1)
        precondition(search.delegate?.control?(search, textView: fieldEditor,
                                              doCommandBy: NSSelectorFromString("cancelOperation:")) == true)
        precondition(bar.isHidden && window.firstResponder === editor && browser.findStopCount == 1)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let foreign = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: otherWindow.windowNumber, context: nil,
                            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 0)!
        precondition(!root.performKeyEquivalent(with: foreign) && bar.isHidden)
        otherWindow.close()
        // CEF translates key events and may omit their original AppKit window.
        let translated = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                            timestamp: 0, windowNumber: 0, context: nil, characters: "f",
                            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 0)!
        precondition(root.performKeyEquivalent(with: translated))
        browser.onDailyShortcut?("escape")
        precondition(bar.isHidden)
        precondition(browser.onBrowserKeyEquivalent?(translated) == true)
        browser.onDailyShortcut?("escape")
        precondition(bar.isHidden && window.firstResponder === editor && browser.findStopCount == 3)
        browser.onDailyShortcut?("escape")
        precondition(browser.stopCount == 1)

        // Native popup context-menu links go through the inherited host callback.
        var opened: [String] = []
        browser.onPopupRequested = { opened.append($0) }
        let originalURL = browser.currentURLString
        browser.onContextMenuAction?("open", "https://example.test/child")
        browser.onContextMenuAction?("search", "A+B")
        precondition(opened.first == "https://example.test/child" && opened.last!.contains("q=A%2BB"))
        precondition(browser.currentURLString == originalURL)
        browser.onDailyShortcut?("menu:printPage")
        precondition(browser.printCount == 2)

        // Real BrowserWebFeatures reparents CEF into a fullscreen cover. Popup
        // layout may still run while the find bar is visible, but must not resize it.
        precondition(browser.onBrowserKeyEquivalent?(key("f")) == true)
        browser.onFullscreenModeChange?(true)
        precondition(browser.superview !== root)
        let fullFrame = browser.frame
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        precondition(browser.frame == fullFrame)
        browser.exitContentFullscreen()
        precondition(browser.superview === root)

        browser.agentControlled = true
        precondition(browser.onBrowserKeyEquivalent?(key("p")) == false)
        browser.onDailyShortcut?("menu:printPage")
        browser.onContextMenuAction?("open", "https://example.test/rejected")
        precondition(browser.printCount == 2 && opened.count == 2)
        browser.agentControlled = false
        window.orderOut(nil)
        precondition(browser.onBrowserKeyEquivalent?(key("p")) == false)
        browser.onWebFeaturesInvalidated?()
        window.contentView = nil
        window.close()
        print("popup AppKit actions/focus/fullscreen/retention/actor checks passed")
    }
}
`);
  const binary = join(dir, 'checks');
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    app + 'BrowserShortcuts.swift', join(dir, 'Settings.swift'), join(dir, 'Checks.swift'), '-o', binary],
  {cwd: root, encoding: 'utf8', timeout: 90000});
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [dir], {encoding: 'utf8', timeout: 15000});
  assert.equal(run.status, 0, run.stdout + run.stderr);
  process.stdout.write(run.stdout);
});
