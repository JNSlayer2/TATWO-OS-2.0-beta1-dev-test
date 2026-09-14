import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const base = 'App/Sources/Tatwo2/Browser/Import/';
const files = readdirSync(join(root, base)).filter(p => p.endsWith('.swift')).map(p => base + p);
const read = p => readFileSync(join(root, p), 'utf8');
const sources = files.map(read).join('\n');

test('W49: independent sheet entrypoint and protected integration surfaces', () => {
  assert.doesNotMatch(sources, /\bBrowserWorkSpaceDesignView\b(?!\.)[({]/);
  const shell = read('App/Sources/Tatwo2/Shell/AppShell.swift');
  assert.match(shell, /tatwo\.browser\.openImport/);
  assert.match(shell, /\.sheet\(item: \$browserImportRequest\).*BrowserImportFlowView/);
  assert.match(shell, /userInfo\?\["spaceID"\] as\? UUID/);
  // Room-scoping guard removed after integration: those files are legitimately shared now.
});

test('W49b: consent-based Safe Storage import, CSV fallback, no secret logs or extension installation', () => {
  assert.doesNotMatch(sources, /sqlite3_key|SecItemUpdate|SecItemDelete|kSecUseAuthenticationUISkip/);
  assert.doesNotMatch(sources, /\b(?:print|NSLog|debugPrint|os_log)\s*\(/);
  assert.match(sources, /userSelectedFile/);
  assert.match(sources, /vault\.importCredentials/);
  const importer = read(base + 'ChromiumImporter.swift');
  for (const text of ['SecItemCopyMatching', 'kSecClassGenericPassword', 'kSecAttrService',
    'kSecAttrAccount', 'errSecItemNotFound', 'keychainDenied', 'CCKeyDerivationPBKDF',
    'saltysalt', '1003', 'CCCrypt', 'kCCOptionPKCS7Padding', 'password_value', 'Login Data']) {
    assert.ok(importer.includes(text), text);
  }
  assert.match(importer, /func readLogins\(profile: BrowserImportProfile\) throws -> \[ImportedLogin\]/);
  const coordinator = read(base + 'BrowserImportCoordinator.swift');
  assert.match(coordinator, /importer\.readLogins\(profile:/);
  assert.doesNotMatch(coordinator, /case \.keychainNotice: return hasPasswordFile/);
  const inventory = importer.slice(importer.indexOf('func extensions('));
  assert.doesNotMatch(inventory, /copyItem|createDirectory|\.write\(|moveItem/);
  assert.match(importer, /SQLITE_OPEN_READONLY/);
  assert.match(importer, /withCopy/);
  assert.match(importer, /-wal/);
  assert.match(importer, /defer \{ try\? fm\.removeItem\(at: directory\) \}/);
  const view = read(base + 'BrowserImportFlowView.swift');
  for (const text of ['accessibilityReduceMotion', '.easeInOut', '未安裝', '僅書籤', '打開系統設定',
    '列出但不導入（2.0.7 尚未支援）', '打開 Browser space', 'interactiveDismissDisabled',
    '或從 CSV 檔匯入…', 'macOS 會詢問是否允許 TATWO OS 讀取', '的密碼保護金鑰，請按『永遠允許』']) assert.ok(view.includes(text), text);
  assert.ok(view.indexOf('或從 CSV 檔匯入…') < view.indexOf('private var passwordNotice'), 'CSV belongs to scene two');
  assert.doesNotMatch(view, /不讀取其他瀏覽器的密碼保護金鑰|請先在.*匯出 CSV/);
  assert.doesNotMatch(view, /\.padding\(\d|\.font\(\.system\(size:\s*\d|\.frame\(width:\s*\d/);
});

test('W49: real Swift importers, coordinator, stores and view; synthetic profiles only', {
  timeout: 180000, skip: process.platform !== 'darwin' ? 'macOS Swift/SQLite/AppKit fixture' : false,
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w49-import-check-'));
  try {
    const profile = read('App/Sources/Tatwo2/Browser/EmbeddedBrowserProfile.swift');
    const start = profile.indexOf('struct EmbeddedBrowserPasswordFormMetadata:');
    const end = profile.indexOf('\nenum EmbeddedBrowserPasswordFormMetadataExtractor', start);
    assert.ok(start >= 0 && end > start);
    const metadata = join(dir, 'metadata.swift');
    writeFileSync(metadata, profile.slice(start, end));
    const binary = join(dir, 'fixture');
    const compile = spawnSync('swiftc', [
      '-parse-as-library', '-swift-version', '6', '-num-threads', '2',
      ...files, 'App/Sources/Tatwo2/Browser/BrowserPasswordVault.swift',
      'App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift',
      'App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift',
      'App/Sources/Tatwo2/Visual/WorkspaceSidebarMetrics.swift',
      metadata, 'tests/fixtures/browser-import-checks.swift', '-o', binary,
    ], { cwd: root, encoding: 'utf8', timeout: 130000 });
    assert.equal(compile.status, 0, `${compile.error ?? ''}\n${compile.stdout}\n${compile.stderr}`);
    const run = spawnSync(binary, [dir], { cwd: root, encoding: 'utf8', timeout: 40000 });
    assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
    assert.match(run.stdout, /W49 import fixture passed: \d+ checks/);
    console.log(run.stdout.trim());
  } finally {
    // Only this invocation's synthetic scratch; never source profiles/work products.
    rmSync(dir, { recursive: true, force: true });
  }
});
