import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

test('dedicated browser keeps window-responder shortcuts without capturing embedded chat focus', {
  skip: process.platform !== 'darwin', timeout: 90000,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-focus-scope-'));
  const source = readFileSync('App/Sources/Tatwo2/Browser/BrowserDailyNavigationControls.swift', 'utf8')
    .split('struct BrowserDailyNavigationControls: View')[0];
  writeFileSync(join(dir, 'Checks.swift'), source + `
@MainActor enum BrowserWebFeatures {
    static func focusOwner(for view: NSView) -> NSView { view }
}
@MainActor final class TestWindow: NSWindow {
    var key = true
    override var isKeyWindow: Bool { key }
}
@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        window.contentView = root
        let probe = BrowserDailyFocusScope.Probe(frame: NSRect(x: 0, y: 0, width: 250, height: 400))
        root.addSubview(probe)
        var focused = false
        probe.update = { focused = $0 }
        window.makeFirstResponder(window)
        probe.check()
        precondition(!focused)
        probe.acceptsWindowResponder = true
        probe.check()
        precondition(focused)
        window.key = false
        probe.check()
        precondition(!focused)
        window.key = true
        probe.isHidden = true
        probe.check()
        precondition(!focused)
        probe.isHidden = false
        let chat = NSTextView(frame: NSRect(x: 300, y: 0, width: 250, height: 300))
        root.addSubview(chat)
        window.makeFirstResponder(chat)
        probe.check()
        precondition(!focused)
        let page = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 250))
        root.addSubview(page)
        window.makeFirstResponder(page)
        probe.acceptsWindowResponder = false
        probe.check()
        precondition(focused)
        probe.removeFromSuperview()
        probe.check()
        precondition(!focused)
        window.close()
        print("window, key-window, hidden, unrelated editor, embedded browser and teardown focus checks passed")
    }
}
`);
  const binary = join(dir, 'checks');
  const build = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', join(dir, 'Checks.swift'), '-o', binary], { encoding: 'utf8', timeout: 60000 });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(binary, [], { encoding: 'utf8', timeout: 15000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  process.stdout.write(run.stdout);
});
