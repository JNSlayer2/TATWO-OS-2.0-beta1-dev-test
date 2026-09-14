import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = path => readFileSync(join(root, path), 'utf8');
const native = 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/';
const app = 'App/Sources/Tatwo2/Browser/';
const bridge = read(native + 'TatwoCEFBridge.mm');
const swift = read(app + 'BrowserWebFeatures.swift');
function slice(start, end) {
  const a = bridge.indexOf(start), b = bridge.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `missing production section ${start}`);
  return bridge.slice(a, b);
}

test('W57d four native handler surfaces, reduced Chrome 151 UA and unavailable ABI', () => {
  // CefPrintHandler is Linux-only; macOS uses Print plus CefPdfPrintCallback for fallback.
  for (const name of ['CefDialogHandler', 'CefDisplayHandler', 'CefKeyboardHandler', 'CefPdfPrintCallback',
    'OnFileDialog', 'OnFullscreenModeChange', 'OnPreKeyEvent', 'OnPdfPrintFinished']) {
    assert.ok(bridge.includes(name), name);
  }
  assert.match(bridge, /GetDialogHandler\(\) override \{ return this; \}/);
  assert.match(bridge, /CefString\(&settings\.user_agent\)\.FromASCII\(W57dUserAgent\(\)\)/);
  assert.match(bridge, /Chrome\/151\.0\.0\.0 Safari\/537\.36/);
  assert.match(bridge, /static_assert\(CHROME_VERSION_MAJOR == 151/);
  for (const method of ['cancelWebFeatures', 'exitContentFullscreen', 'printPage',
    'printToPDFWithCompletion', 'downloadCurrentPDFWithCompletion']) {
    assert.ok(read(native + 'include/TatwoCEFBridge.h').includes(method), method);
    assert.ok(read(native + 'TatwoCEFBridgeUnavailable.m').includes(method), method);
  }
});

test('W57d file dialogs fail closed for agents and stale replies, native panels are per-window', () => {
  const dialog = slice('bool TatwoClient::OnFileDialog(', '// Only a completed regular .pdf');
  assert.match(dialog, /callback->Cancel\(\);\s+return true/);
  assert.match(dialog, /W57dCurrent\(client->owner_, generation\)/);
  assert.match(dialog, /file_dialog_serial_ != dialog_serial/);
  assert.match(dialog, /file_dialog_callback_ = nullptr;[\s\S]*pending->Continue\(selected\)/);
  assert.match(bridge, /browserActor == TatwoCEFBrowserActorHuman && !view.agentControlled/);
  for (const name of ['NSOpenPanel()', 'NSSavePanel()', 'allowedContentTypes', 'allowsMultipleSelection',
    'beginSheetModal(for: window)', 'picker?.cancel(nil)', 'panelCompletion = nil']) assert.ok(swift.includes(name), name);
  assert.match(swift, /browser\.browserActor == \.human && !browser\.agentControlled/);
  assert.match(swift, /open\.canChooseDirectories = mode == 2/);
  for (const [start, end] of [
    ['uint64_t BeginNavigationFrameTelemetry(TatwoCEFBrowserView *view,\n                                       BrowserState *state,\n                                       NSString *reason) {', 'bool IsActiveMountCallback('],
    ['- (void)beginAgentInteraction {', '- (BOOL)restoreHumanInteraction'],
    ['- (void)closeBrowserWithCompletion:', '@end'],
    ['void TatwoClient::OnBeforeClose(', 'bool W57dCurrent('],
    ['  void OnRenderProcessTerminated(', ' private:'],
  ]) assert.match(slice(start, end), /W57dInvalidate\(/);
  const invalidate = slice('void W57dInvalidate(TatwoCEFBrowserView *view) {', 'bool TatwoClient::OnFileDialog(');
  assert.ok(invalidate.indexOf('onWebFeaturesInvalidated()') < invalidate.indexOf('W57dCancel()'));
  assert.match(swift, /self\.presentationSerial == serial/); // revocation must not open an error sheet
});

test('W57d fullscreen restores owner geometry/focus and handles Escape even outside renderer focus', () => {
  assert.match(bridge, /windows_key_code == 27 && browser->GetHost\(\)->IsFullscreen\(\)/);
  assert.match(bridge, /GetHost\(\)->ExitFullscreen\(true\)/);
  for (const contract of ['root.addSubview(cover, positioned: .above', 'container.addSubview(browser)',
    'event.window === browser.window', 'event.keyCode == 53', 'NSEvent.removeMonitor(fullscreenKeys)',
    'cover.owner = container', 'cover.removeFromSuperview()', 'makeFirstResponder(responder)']) {
    assert.ok(swift.includes(contract), contract);
  }
  assert.match(read(app + 'BrowserDailyNavigationControls.swift'), /BrowserWebFeatures\.focusOwner\(for: view\)/);
  assert.match(read(app + 'ChromiumCEFBackend.swift'), /if browserView\.superview === self \{ browserView\.frame = bounds \}/);
  assert.match(read(app + 'ChromiumCEFBackend.swift'), /if hidden, !entry\.container\.isHidden \{ entry\.container\.browserView\?\.cancelWebFeatures\(\) \}/);
  assert.doesNotMatch(swift, /window\.delegate\s*=/);
});

test('W57d host shortcuts are consumed before page JS, Tab and editing stay native', () => {
  const keys = slice('  bool OnPreKeyEvent(', '  void OnFindResult(');
  for (const name of ['@"focusAddress"', '@"newTab"', '@"closeTab"', '@"reload"', '@"print"', '@"printPDF"']) {
    assert.ok(keys.includes(name), name);
  }
  assert.match(keys, /if \(os_event && ActorRequestPolicy\(owner_\)\.human/);
  assert.match(keys, /\*is_keyboard_shortcut = true/);
  assert.match(keys, /performKeyEquivalent:\(__bridge NSEvent \*\)os_event/);
  assert.doesNotMatch(keys, /windows_key_code == 9\b|sendEvent:/);
  // W57e: keys are bound through the settings shortcut map; host-forwarded kinds map to combos.
  const shortcuts = read(app + 'BrowserShortcuts.swift');
  for (const kind of ['"print"', '"printPDF"', '"focusAddress"', '"newTab"', '"closeTab"', '"reload"']) assert.ok(shortcuts.includes(`case ${kind}`), kind);
  assert.match(shortcuts, /case printPage|, printPage/);
  const controls = read(app + 'BrowserDailyNavigationControls.swift');
  assert.match(controls, /BrowserShortcutMap\.legacyCombo\(shortcutKind\)/);
  for (const file of ['EmbeddedBrowserView.swift', 'BrowserWorkSpaceDesignView.swift']) {
    const text = read(app + file);
    assert.ok(text.includes('onAction: performBrowserAction'), file);
    assert.ok(text.includes('case .printPage:'), file);
  }
});

test('W57d Print/PDF fallback remains human, document-bound and signature-checked; DRM is explicit', () => {
  assert.match(bridge, /GetHost\(\)->Print\(\)/);
  assert.match(bridge, /GetHost\(\)->PrintToPDF\(ToCefString\(path\), settings/);
  assert.match(bridge, /mkdtemp\(buffer\.data\(\)\)/);
  assert.match(bridge, /W57dCurrent\(weak_view, generation\) && W57dIsPDF\(path\)/);
  assert.match(bridge, /std::string\(header, 5\) == "%PDF-"/);
  assert.match(bridge, /pdf_download_id_ = item->GetId\(\)/);
  assert.match(bridge, /W57dDownloadUpdate\(download_item\)/);
  assert.match(swift, /NSWorkspace\.shared\.open/);
  assert.match(swift, /com\.apple\.Preview/);
  const drm = 'DRM 影片（Widevine）：不支援';
  for (const file of [app + 'Diagnostics/BrowserDiagnosticsView.swift',
    app + 'Diagnostics/BrowserDiagnosticsReport.swift', 'docs/reviews/2.0.7-browser-acceptance.md']) {
    assert.ok(read(file).includes(drm), file);
  }
  assert.doesNotMatch(bridge, /RegisterWidevineCdm|widevinecdm\.dylib/);
});

test('W57d production UA pure function and file dialog callback fixture', {
  skip: process.platform !== 'darwin', timeout: 90000,
}, () => {
  const dir = join(root, '.build/w57d/web-fixture');
  mkdirSync(dir, {recursive: true});
  let source = read('tests/fixtures/browser-web-features.mm.in');
  for (const [name, code] of Object.entries({
    ua: slice('constexpr const char *W57dUserAgent()', 'static_assert(CHROME_VERSION_MAJOR'),
    current: slice('bool W57dCurrent(', 'void TatwoClient::W57dCancel()'),
    cancel: slice('void TatwoClient::W57dCancel()', 'void W57dInvalidate(TatwoCEFBrowserView *view) {'),
    dialog: slice('bool TatwoClient::OnFileDialog(', '// Only a completed regular .pdf'),
  })) source = source.replace(`// INSERT ${name}`, code);
  writeFileSync(join(dir, 'fixture.mm'), source);
  const build = spawnSync('xcrun', ['clang++', '-std=c++20', '-fobjc-arc', '-fblocks',
    '-framework', 'Foundation', join(dir, 'fixture.mm'), '-o', join(dir, 'fixture')],
  {cwd: root, encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, `${build.error ?? ''}\n${build.stderr}`);
  const run = spawnSync(join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 15000});
  assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /W57d UA and dialog fixture passed/);
  console.log(run.stdout.trim());
});

test('W57d actual AppKit coordinator: filters, fullscreen owner/focus/restore and silent PDF revocation', {
  skip: process.platform !== 'darwin', timeout: 90000,
}, () => {
  const dir = join(root, '.build/w57d/coordinator-fixture');
  mkdirSync(dir, {recursive: true});
  const source = read('tests/fixtures/browser-web-features-checks.swift')
    .replace('// INSERT coordinator', swift.replace('import TatwoCEFBridge\n', ''));
  writeFileSync(join(dir, 'fixture.swift'), source);
  const build = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '5', '-num-threads', '2',
    join(dir, 'fixture.swift'), '-o', join(dir, 'fixture')], {encoding: 'utf8', timeout: 60000});
  assert.equal(build.status, 0, `${build.error ?? ''}\n${build.stderr}`);
  const run = spawnSync(join(dir, 'fixture'), [], {encoding: 'utf8', timeout: 15000});
  assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /W57d AppKit coordinator fixture passed/);
  console.log(run.stdout.trim());
});
