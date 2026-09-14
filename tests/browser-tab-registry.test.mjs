import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => readFileSync(join(root, p), 'utf8');

test('one owner registry, no stored facade dictionary or workspace demo folders', () => {
  const facade = read('App/Sources/Tatwo2/Facade/BrowserLaneRegistry.swift');
  const model = read('App/Sources/Tatwo2/Facade/ChatPageModel.swift');
  assert.doesNotMatch(facade + model, /(?:@Published\s+)?var browserLanesBySession[^\n]*=\s*\[:\]/);
  assert.match(facade, /browserTabRegistry\.storeLanes/);
  assert.match(facade, /browserTabRegistry\.closeAll\(ownedBy:/);
  assert.match(model, /browserTabRegistry\.changes\.sink/);
  for (const path of ['Chat/ChatPage.swift', 'Browser/BrowserWorkSpaceDesignView.swift']) {
    assert.doesNotMatch(read(`App/Sources/Tatwo2/${path}`), /"新聞"|"工具"|"參考資料"|"待讀"|"購物"/);
  }
});

test('swiftc registry fixture: ownership, adapters, durability, debounce and migration', {
  timeout: 120000, skip: process.platform !== 'darwin',
}, () => {
  const dir = mkdtempSync(join(tmpdir(), 'w46-registry-'));
  const binary = join(dir, 'fixture');
  const compile = spawnSync('swiftc', ['-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    'App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift',
    'App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift',
    'App/Sources/Tatwo2/Facade/BrowserLaneRegistry.swift',
    'tests/fixtures/browser-tab-registry-checks.swift', '-o', binary],
    { cwd: root, encoding: 'utf8', timeout: 90000 });
  assert.equal(compile.status, 0, compile.stderr);
  const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 15000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stdout, /W46 registry fixture passed/);
});

test('W46-fix: registry saves off the main actor and keeps unseen tabs on stale snapshots', () => {
  const registry = readFileSync(new URL('../App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift', import.meta.url), 'utf8');
  assert.match(registry, /Task\.detached\(priority: \.utility\)/);
  assert.match(registry, /private nonisolated static func write\(_ payload: SavePayload, to storageURL: URL\) throws/);
  assert.match(registry, /storedLaneIDs\[sessionID\] = Set\(replacement\.compactMap/);
});
