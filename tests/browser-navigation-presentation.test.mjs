import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(path.join(repo, p), 'utf8');
const hash = s => createHash('sha256').update(s).digest('hex');
const between = (text, start, end) => {
  const a = text.indexOf(start), b = text.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a);
  return text.slice(a, b);
};

test('actual browser navigation row renders without squeezing out the address field', {
  skip: process.env.TATWO_BROWSER_ADDRESS_NATIVE !== '1'
    ? 'Lead compiler approval required (TATWO_BROWSER_ADDRESS_NATIVE=1)' : false,
}, () => {
  assert.equal(process.platform, 'darwin');
  const run = (cmd, args) => {
    const result = spawnSync(cmd, args, {
      cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024,
    });
    assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
    return result.stdout;
  };
  assert.equal(run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).trim(), '1');
  const output = path.join(repo, 'output/lightweight-repair');
  mkdirSync(output, { recursive: true });
  const root = mkdtempSync(path.join(output, 'browser-navigation-ui.'));
  const sourcePaths = [
    'App/Sources/Tatwo2/Browser/EmbeddedBrowserView.swift',
    'App/Sources/Tatwo2/Browser/EmbeddedBrowserSecurity.swift',
    'App/Sources/Tatwo2/Pages/PluginsPage.swift',
  ];
  const sources = sourcePaths.map(read);
  const row = between(sources[0], '    private var browserNavigationBar:', '    private var browserToolbar:');
  const command = between(sources[1], 'struct EmbeddedBrowserCommand:', 'enum EmbeddedBrowserLoadPhase:');
  const backing = sources[2].slice(sources[2].indexOf('struct NonWindowDraggingView:'));
  assert.ok(backing.startsWith('struct NonWindowDraggingView:'));
  const fixture = `
import SwiftUI
import AppKit
${command}
${backing}
private struct FixtureProfile { let registryKey = UUID() }
private struct FixtureAccess { func isReady(for key: UUID) -> Bool { true } }
private struct NavigationFixture: View {
    @State private var addressText = "https://example.com/a/long/path?query=browser-navigation"
    @FocusState private var addressFieldFocused: Bool
    @FocusState private var startPageFieldFocused: Bool
    private let currentURLString = "https://example.com/a/long/path?query=browser-navigation"
    private let canGoBack = true
    private let canGoForward = false
    private let isBrowserRuntimeVisible = true
    private let browserProfile = FixtureProfile()
    private let profileAccessState = FixtureAccess()
    let validationMessage: String?
    private func loadAddress() {}
    private func issue(_ action: EmbeddedBrowserCommand.Action) {}
    var body: some View { browserNavigationBar }
${row}
}
@MainActor func renderFixture() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    var checks = 0
    var fields: [[String: Any]] = []
    func check(_ value: Bool, _ message: String) {
        precondition(value, message); checks += 1
        print("PASS: " + message)
    }
    func findField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = findField(child) { return found } }
        return nil
    }
    for width: CGFloat in [260, 380, 640] {
        let error: String? = width == 380 ? "瀏覽器尚未就緒，請稍後再試。" : nil
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
            Text("導覽列隔離預覽・不連網站").font(.caption2).foregroundStyle(.secondary)
            NavigationFixture(validationMessage: error)
        }.frame(width: width, height: 92, alignment: .topLeading)
          .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 92),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        guard let field = findField(host) else { fatalError("native address text field not found") }
        let frame = host.convert(field.bounds, from: field)
        check(frame.minX >= 0 && frame.maxX <= width + 1, "address stays inside \\(Int(width))pt viewport")
        check(frame.width >= 100, "address retains usable width at \\(Int(width))pt")
        check(frame.minY >= 0 && frame.maxY <= host.bounds.height + 1, "address not vertically clipped")
        fields.append(["width": width, "addressX": frame.minX, "addressWidth": frame.width])
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            root.appendingPathComponent("navigation-\\(Int(width)).png"))
        window.close()
    }
    try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("geometry.json"))
    print("BROWSERNAVIGATION RESULT checks=\\(checks) failures=0")
}
try MainActor.assumeIsolated { try renderFixture() }
`;
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('/bin/bash', [lock, 'acquire', '--pid', String(process.pid), '--timeout', '1']);
  const token = acquired.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token);
  try {
    assert.equal(run('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level']).trim(), '1');
    const main = path.join(root, 'main.swift'), binary = path.join(root, 'navigation-fixture');
    writeFileSync(main, fixture);
    run('/usr/bin/xcrun', ['swiftc', '-j', '1', '-swift-version', '5', main, '-o', binary]);
    const result = run(binary, [root]);
    assert.match(result, /BROWSERNAVIGATION RESULT checks=9 failures=0/);
    for (let i = 0; i < sourcePaths.length; i++) {
      assert.equal(hash(read(sourcePaths[i])), hash(sources[i]), 'source drift: ' + sourcePaths[i]);
    }
    writeFileSync(path.join(root, 'receipt.json'), JSON.stringify({
      at: new Date().toISOString(),
      sourceSHA256: Object.fromEntries(sourcePaths.map((p, i) => [p, hash(sources[i])])),
      fixtureSHA256: hash(fixture),
      pngSHA256: Object.fromEntries([260, 380, 640].map(width => {
        const name = `navigation-${width}.png`;
        return [name, hash(readFileSync(path.join(root, name)))];
      })),
      result,
      scope: 'Exact production navigation row, command shape and non-dragging backing. Synthetic profile/readiness/actions. Isolated native windows only, no CEF, actual browser window, login or formal UI acceptance.',
    }, null, 2));
    console.log(result.trim());
    console.log('Evidence:', root);
  } finally {
    run('/bin/bash', [lock, 'release', '--pid', String(process.pid), '--token', token]);
  }
});
