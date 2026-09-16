import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('Bot unpinned rail control reserves the native traffic-light cluster', () => {
  const source = readFileSync(join(repo, 'App/Sources/Tatwo2/Bot/BotPage.swift'), 'utf8');
  assert.match(source, /if !sidebarIsPinned \{[\s\S]*?\.padding\(\.leading, WindowChromeMetrics\.appControlLeadingX\)/);
});
test('native window buttons remain visible with fresh-install unpinned sidebar and after navigation', {
  skip: process.platform !== 'darwin', timeout: 90_000,
}, () => {
  const root = testScratch('window-traffic-lights-');
  const source = readFileSync(join(repo, 'App/Sources/Tatwo2/CLI/CLITerminalWindows.swift'), 'utf8');
  const sync = source.slice(source.indexOf('struct WindowTrafficLightVisibilitySync:'));
  const call = sync.includes('let sidebarPinned: Bool')
    ? 'WindowTrafficLightVisibilitySync(sidebarPinned: pinned)' : 'WindowTrafficLightVisibilitySync()';
  const fixture = join(root, 'main.swift');
  writeFileSync(fixture, `import SwiftUI
import AppKit
${sync}
struct Root: View {
 let pinned: Bool
 var body: some View { Text("Window controls").frame(width: 500, height: 300).background(${call}) }
}
@main struct Checks {
 @MainActor static func pump() {
   let end = Date().addingTimeInterval(0.2)
   while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
 }
 @MainActor static func main() {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory); app.finishLaunching()
  let window = NSWindow(contentRect: NSRect(x:100,y:120,width:500,height:300),
    styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false
  for pinned in [false, true, false] {
    window.contentViewController = NSHostingController(rootView:Root(pinned:pinned))
    window.orderFrontRegardless(); pump()
    precondition(window.isVisible, "native window must be onscreen")
    // Exercise the same async attachment SwiftUI invokes, with a guaranteed
    // attached view (a zero-sized background need not get a layout in a probe).
    let coordinator = WindowTrafficLightVisibilitySync.Coordinator()
    coordinator.attach(to: window.contentView!, sidebarPinned: pinned)
    pump()
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      guard let button = window.standardWindowButton(type) else { fatalError("missing standard button") }
      precondition(!button.isHidden && !button.isHiddenOrHasHiddenAncestor,
        "sidebar pin must not hide window controls")
      let frame = button.convert(button.bounds, to:nil)
      let point = NSPoint(x:frame.midX,y:frame.midY)
      guard let frameView = window.contentView?.superview,
            let hit = frameView.hitTest(frameView.convert(point, from:nil)) else { fatalError("button not hit-testable") }
      precondition(hit === button || hit.isDescendant(of:button), "button is occluded")
    }
    withExtendedLifetime(coordinator) {}
  }
  let p = Process(); p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
  p.arguments=["-x","-o","-l",String(window.windowNumber),${JSON.stringify(join(root, 'window.png'))}]
  try! p.run(); p.waitUntilExit()
  precondition(p.terminationStatus == 0 && FileManager.default.fileExists(atPath: ${JSON.stringify(join(root, 'window.png'))}),
    "native visual evidence must be captured")
  window.orderOut(nil)
  print("TRAFFIC LIGHTS PASS")
 }
}`);
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', fixture, '-o', binary],
    { encoding: 'utf8', timeout: 60_000 });
  const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 15_000 });
  assert.equal(result.status, 0, `${result.signal}\n${result.stderr}`);
  assert.match(result.stdout, /TRAFFIC LIGHTS PASS/);
});
