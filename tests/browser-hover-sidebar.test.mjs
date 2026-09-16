import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFileSync(path.join(repo, 'App/Sources/Tatwo2/Chat', name), 'utf8');
const page = read('ChatPage.swift'), sidebar = read('ChatPage+Sidebar.swift');
const section = (text, start, end) => text.slice(text.indexOf(start), text.indexOf(end, text.indexOf(start)));

test('collapsed Browser uses the shared edge overlay without reserving canvas width', () => {
  const gate = section(page, 'let showChatProjectHoverRail', 'let layoutPolicy');
  assert.match(gate, /model.mode != \.browser \|\| ChatRunMode.browserPreviewEnabled/);
  assert.match(gate, /!workspaceOwnsSidebar/);
  assert.match(page, /showChatProjectHoverRail && !showSidebar && !showOSMenu/);
  assert.match(page, /model.mode != \.browser \|\| !browserWorkSpaceStore.focusMode/);
  const hover = section(sidebar, 'func chatProjectHoverSurface', 'func updateChatProjectHover');
  assert.match(hover, /\bsidebar\s*[\s\S]*?\.frame\(width: width\)/);
  assert.doesNotMatch(hover, /if model.mode == \.cli|else \{ chatSidebar \}/);
  assert.match(sidebar, /WorkspaceSidebarModePicker\(modes: ChatRunMode.visibleChatTabs/);
});

test('Browser hover is independent of Chat pin preference and resets at lifecycle boundaries', () => {
  assert.match(sidebar, /model.mode == \.browser \? !browserWorkSpaceStore.focusMode : sidebarPinnedPref \|\| Self.envRailPinned/);
  assert.match(page, /onChange\(of: model.mode\)[^{]*\{[^\n]*\n\s*resetChatProjectHover\(\)/);
  assert.match(page, /onChange\(of: browserWorkSpaceStore.focusMode\)[^{]*\{[^\n]*\n\s*resetChatProjectHover\(\)/);
  assert.match(page, /onDisappear \{\s*resetChatProjectHover\(\)/);
  assert.match(sidebar, /func resetChatProjectHover\(\)[\s\S]*?chatProjectHoverCloseWorkItem\?\.cancel\(\)[\s\S]*?isChatProjectRailHovering = false/);
  assert.match(sidebar, /!isChatProjectRailInteractionActive else \{ return \}/);
  assert.match(page, /sidebarInteractionActive\)[\s\S]*?updateChatProjectHover\(chatProjectPointerInside\)/);
  const browser = readFileSync(path.join(repo, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift'), 'utf8');
  assert.match(browser, /onChange\(of: downloadsPresented \|\| diagnosticsPresented \|\| editingFolderID != nil\)/);
});

test('native shared hover opens without click, retains rows, closes on exit and cancels stale closes', {
  skip: process.platform !== 'darwin', timeout: 90_000,
}, () => {
  const root = process.env.BROWSER_HOVER_EVIDENCE ?? testScratch('browser-hover-');
  mkdirSync(root, { recursive: true });
  const bridge = section(read('ChatPageAppKitBridges.swift'), 'struct ChatProjectHoverTrackingView:', '// #2 skill');
  const methods = section(sidebar, '    func chatProjectHoverSurface', '    /// Gen-4 export-only');
  const pinned = section(sidebar, '    var isChatProjectRailPinned:', '    var cliVisibleProjectIDs:');
  const expanded = section(sidebar, '    var isChatProjectRailExpanded:', '    @ViewBuilder');
  const constants = section(page, '    let chatProjectRailEdgeGuardWidth:', '\n    /// WORK_OS.md');
  writeFileSync(path.join(root, 'Production.swift'), `import AppKit\nimport SwiftUI\n${bridge}\nextension HoverFixture {\n${pinned}${expanded}${methods}\n}`);
  writeFileSync(path.join(root, 'Fixture.swift'), `import AppKit
import SwiftUI
enum Mode { case browser, chat }
@MainActor final class Probe: ObservableObject {
    @Published var mode = Mode.browser
    @Published var focusMode = true
    @Published var chatPinned = true
    @Published var sidebarInteractionActive = false
    var expanded: () -> Bool = { false }
    var hover: (Bool) -> Void = { _ in }
    var reset: () -> Void = {}
}
struct HoverFixture: View {
    @ObservedObject var model: Probe
    var browserWorkSpaceStore: Probe { model }
    var sidebarPinnedPref: Bool { model.chatPinned }
    static let envRailPinned = false
    @State var isChatProjectRailHovering = false
    @State var chatProjectPointerInside = false
    @State var chatProjectHoverGeneration = 0
    @State var chatProjectHoverCloseWorkItem: DispatchWorkItem?
${constants}
    var sidebar: some View {
        VStack { Text("Browser sidebar"); Button("Synthetic tab") {} ; Spacer() }
            .frame(maxWidth: .infinity).background(Color.gray.opacity(0.3))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            chatProjectHoverSurface(width: 250)
        }
        .onAppear {
            model.expanded = { isChatProjectRailExpanded }
            model.hover = updateChatProjectHover
            model.reset = resetChatProjectHover
        }
        .onChange(of: model.mode) { _, _ in resetChatProjectHover() }
        .onChange(of: model.focusMode) { _, _ in resetChatProjectHover() }
        .onChange(of: model.sidebarInteractionActive) { _, active in
            if !active { updateChatProjectHover(chatProjectPointerInside) }
        }
    }
}
@main struct Checks {
    @MainActor static func settle(_ seconds: Double = 0.1) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let probe = Probe()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HoverFixture(model: probe))
        window.contentView = host; window.orderFrontRegardless(); settle()
        func move(_ x: CGFloat) {
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 240),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            app.sendEvent(event); settle()
        }
        func snapshot(_ name: String) throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
        }
        precondition(!probe.expanded(), "Chat pin must not expand collapsed Browser")
        try snapshot("collapsed")
        move(19); settle(0.3)
        precondition(probe.expanded(), "left edge hover must open without clicking")
        try snapshot("hover-open")
        move(160); settle(0.65)
        precondition(probe.expanded(), "moving into sidebar rows must retain it")
        move(500); settle(0.7)
        precondition(!probe.expanded(), "leaving must collapse despite Chat pinned preference")
        try snapshot("hover-exit")
        move(19); settle(0.3); move(500); move(19); settle(0.7)
        precondition(probe.expanded(), "reentry cancels pending close")
        probe.sidebarInteractionActive = true; settle()
        move(500); settle(0.7)
        precondition(probe.expanded(), "downloads, diagnostics or naming retain the presenter")
        probe.sidebarInteractionActive = false; settle(0.7)
        precondition(!probe.expanded(), "closing presentation while outside resumes automatic collapse")
        move(19); settle(0.3)
        probe.hover(false); probe.focusMode = false; settle(0.7)
        precondition(probe.expanded(), "explicit pin survives pending hover close")
        probe.focusMode = true; settle(0.1)
        precondition(!probe.expanded(), "explicit collapse clears temporary hover")
        probe.hover(true); probe.mode = .chat; probe.chatPinned = false; settle()
        precondition(!probe.expanded(), "mode change clears Browser hover")
        // Exercise teardown reset without real mouse-enter events from a
        // remounted SwiftUI tracker reopening a still-visible fixture.
        window.orderOut(nil); settle()
        probe.hover(true); probe.hover(false); probe.reset(); settle(0.7)
        precondition(!probe.expanded(), "reset cancels pending callbacks")
        window.orderOut(nil)
        print("BROWSER HOVER NATIVE PASS: 11 assertions")
    }
}`);
  const run = (command, args) => {
    const result = spawnSync(command, args, { cwd: repo, encoding: 'utf8', timeout: 70_000, maxBuffer: 2 * 1024 * 1024 });
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    return result.stdout;
  };
  const lock = path.join(repo, 'scripts/tatwo-build-lock.sh');
  const acquired = run('bash', [lock, 'acquire', '--pid', String(process.pid), '--timeout', '20']);
  const token = acquired.match(/^token=([0-9a-f]+)$/m)?.[1];
  assert.ok(token);
  try {
    run('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', path.join(root, 'Production.swift'), path.join(root, 'Fixture.swift'), '-o', path.join(root, 'checks')]);
    const output = run(path.join(root, 'checks'), [root]);
    writeFileSync(path.join(root, 'result.log'), output);
    assert.match(output, /BROWSER HOVER NATIVE PASS/);
  } finally {
    run('bash', [lock, 'release', '--pid', String(process.pid), '--token', token]);
  }
});
