import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(join(root, file), 'utf8');
const design = read('App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift');
const constants = read('App/Sources/Tatwo2/Chat/ChatPageConstants.swift');
const panels = read('App/Sources/Tatwo2/Chat/ChatPage+Panels.swift');
const controller = read('App/Sources/Tatwo2/Space/SpaceWorkspaceController.swift');
function section(source, start, end) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `Missing fixture boundaries: ${start} / ${end}`);
  return source.slice(from, to);
}
const mode = section(constants, 'enum ChatRunMode:', 'enum ChatCollaborationLevel:');
const store = section(design, '@MainActor', '// MARK: - End local fixture model');

test('workspace design is SwiftUI-only, in-memory and has no browser transport', () => {
  assert.doesNotMatch(design, /EmbeddedBrowser|CEF|URLSession|WKWebView|[hH][tT][tT][pP]/);
  assert.deepEqual([...design.matchAll(/^import (.+)$/gm)].map(m => m[1]), ['SwiftUI']);
  assert.doesNotMatch(design, /FileManager|UserDefaults|AppStorage|SceneStorage|NSWorkspace|openURL|Process\(|Task\s*\{|Timer|Data\(contentsOf|write\s*\(/);
  assert.ok(design.split('\n').length <= 700);
  assert.match(design, /TatwoActivePalette\.current/);
  assert.match(design, /LiquidGlassTokens\.radiusCard/);
  assert.doesNotMatch(design, /Color\s*\(|Color\.(black|white|blue|red)|\.ultraThinMaterial/);
});

test('browser visibility is opt-in and the default controller fallback stays three modes', () => {
  assert.match(mode, /case chat, cli, bot, browser/);
  assert.match(mode, /case \.browser: "Browser"/);
  assert.match(mode, /case \.browser: "globe"/);
  assert.match(mode, /environment\["TATWO_BROWSER_WORKSPACE_PREVIEW"\] == "1"/);
  assert.match(mode, /modes\.filter \{ \$0 != \.browser \|\| enabled \}/);
  assert.match(mode, /previewFilteredModes\(\s*SpaceWorkspaceController\.shared\.visibleModes, enabled: browserPreviewEnabled\)/);
  // W33 replaced the literal fallback with allCases; browser must still be gated here.
  assert.match(controller, /\?\? ChatRunMode\.allCases/);
  assert.match(controller, /filter \{ \$0 != \.browser \|\| ProcessInfo[^}]*TATWO_BROWSER_WORKSPACE_PREVIEW[^}]*\}/);
});

test('mainPane gates design, fails closed on forced selection and excludes composer', () => {
  assert.match(panels, /else if model\.mode == \.browser \{\s*if ChatRunMode\.browserPreviewEnabled \{\s*BrowserWorkSpaceDesignView\(\)\s*\.frame\(maxWidth: \.infinity, maxHeight: \.infinity\)/);
  assert.match(panels, /Color\.clear\s*\.onAppear \{ model\.mode = \.chat \}/);
  assert.match(panels, /if model\.mode != \.cli, model\.mode != \.bot, model\.mode != \.browser \{\s*composer/);
});

test('design exposes local tab, suggestion, assistant and command interactions', () => {
  for (const pattern of [
    /\.draggable\(String\(tab\.id\)\)/, /\.dropDestination\(for: String\.self\)/,
    /store\.close\(tab\.id\)/, /sidebarExpanded\.toggle\(\)/,
    /onKeyPress\(\.upArrow\)/, /onKeyPress\(\.downArrow\)/,
    /aiDraft\.contains\("@"\)/, /referenceButton\("檔案/,
    /keyboardShortcut\("k", modifiers: \.command\)/, /\.onExitCommand/,
    /Text\("切換分頁"\)/, /Text\("歷史"\)/, /Text\("動作"\)/,
    /設計稿：未連線/,
  ]) assert.match(design, pattern);
});

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: 'utf8', timeout: 120_000, maxBuffer: 4 * 1024 * 1024, ...options,
  });
  assert.equal(result.status, 0, `${command}: ${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

test('swiftc fixture initializes and mutates the actual local store with network and file writes denied', {
  skip: process.platform !== 'darwin' ? 'Requires macOS SwiftUI toolchain' : false,
}, () => {
  // Test artifacts stay in a temporary directory; no app launch or project storage.
  const dir = mkdtempSync(join(tmpdir(), 'w34-browser-fixture-'));
  const source = join(dir, 'Fixture.swift');
  const binary = join(dir, 'fixture');
  writeFileSync(source, `import SwiftUI
import Foundation
enum TatwoChatCommandMode { case chat, cli }
@MainActor final class SpaceWorkspaceController {
    static let shared = SpaceWorkspaceController()
    var visibleModes: [ChatRunMode] = [.chat, .cli, .bot, .browser]
    // Custom work spaces resolve their label through the controller (W33).
    func displayName(for id: String) -> String { id }
}
${mode}
${store}
@main struct Fixture {
    @MainActor static func main() {
        let enabled = ProcessInfo.processInfo.environment["TATWO_BROWSER_WORKSPACE_PREVIEW"] == "1"
        precondition(ChatRunMode.browserPreviewEnabled == enabled)
        precondition(ChatRunMode.visibleChatTabs.contains(.browser) == enabled)
        precondition(ChatRunMode.previewFilteredModes([.chat, .cli, .bot, .browser], enabled: false) == [.chat, .cli, .bot])
        let store = BrowserDesignStore()
        precondition(store.insertingReference("分頁", into: "first @ then @") == "first @ then [分頁] ")
        precondition(store.insertingReference("檔案", into: "no mention") == "no mention")
        precondition(store.selectedTab.address.isEmpty)
        store.select(2)
        precondition(store.selectedTab.title == "設計週刊")
        store.select(-1)
        precondition(store.selectedID == 2)
        precondition(store.suggestions(for: " ").isEmpty)
        precondition(store.suggestions(for: "hello").map(\\.section) == ["歷史", "已開分頁", "搜尋建議"])
        precondition(store.move(3, before: 1))
        precondition(store.tabs.map(\\.id) == [0, 3, 1, 2])
        precondition(!store.move(99, before: 1))
        precondition(!store.move(1, before: 1))
        precondition(store.move(0, before: 2))
        precondition(store.tabs.map(\\.id) == [3, 1, 0, 2])
        store.addTab()
        let added = store.selectedID
        precondition(store.selectedTab.address.isEmpty)
        store.showPlaceholder("  ")
        precondition(store.selectedTab.address.isEmpty)
        store.showPlaceholder("本地問題")
        precondition(store.selectedTab.title == "本地問題")
        store.close(added)
        precondition(store.selectedID != added)
        for id in store.tabs.map(\\.id) { store.close(id) }
        precondition(store.tabs.count == 1 && store.selectedTab.address.isEmpty)
        store.close(-1)
        precondition(store.tabs.count == 1)
        print("offline fixture passed; preview=\\(enabled)")
    }
}
`);
  run('swiftc', ['-parse-as-library', '-num-threads', '2', source, '-o', binary]);
  const profile = '(version 1)(allow default)(deny network*)(deny file-write*)';
  for (const value of [undefined, '0', '1', 'true']) {
    const env = { ...process.env };
    if (value === undefined) delete env.TATWO_BROWSER_WORKSPACE_PREVIEW;
    else env.TATWO_BROWSER_WORKSPACE_PREVIEW = value;
    assert.match(run('/usr/bin/sandbox-exec', ['-p', profile, binary], { env }), /offline fixture passed/);
  }
});

test('swiftc typechecks the complete design view against isolated palette/token signatures', {
  skip: process.platform !== 'darwin' ? 'Requires macOS SwiftUI toolchain' : false,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w34-browser-view-'));
  // Signature doubles only: not a theme render, integrated build, or visual approval.
  const stubs = join(dir, 'VisualSignatures.swift');
  writeFileSync(stubs, `import SwiftUI
struct TatwoThemePalette {
    let brandAccent: Color = .primary
    let canvasBase: Color = .primary
    let surfaceFill: Color = .primary
}
enum TatwoActivePalette { static var current: TatwoThemePalette { .init() } }
enum LiquidGlassTokens {
    static let radiusCard: CGFloat = 20
    static let radiusChip: CGFloat = 12
    static let radiusPrimary: CGFloat = 34
    static let shadowRadius: CGFloat = 14
    static let shadowOffsetX: CGFloat = 0
    static let shadowOffsetY: CGFloat = 4
    static let tintOpacity: Double = 0.18
    static let chipFillOpacity: Double = 0.07
    static let shadowOpacity: Double = 0.04
    static let nodeCardTintOpacity: Double = 0.68
}`);
  run('swiftc', ['-typecheck', '-num-threads', '2', stubs,
    join(root, 'App/Sources/Tatwo2/Browser/BrowserWorkSpaceDesignView.swift')]);
});
