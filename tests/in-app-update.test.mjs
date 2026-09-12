import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const updater = readFileSync(new URL('../App/Sources/Tatwo2/Facade/InAppUpdater.swift', import.meta.url), 'utf8');
const card = readFileSync(new URL('../App/Sources/Tatwo2/New/UpdateAvailableCard.swift', import.meta.url), 'utf8');
const stubs = readFileSync(new URL('../App/Sources/Tatwo2/Facade/OS1Stubs.swift', import.meta.url), 'utf8');

test('update card offers a one-click update and keeps the terminal path as an advanced fallback', () => {
  assert.match(card, /Button\(updateButtonTitle\) \{ updater\.update\(to: release\.tag_name\) \}/);
  assert.match(card, /\.buttonStyle\(\.borderedProminent\)/);
  assert.match(card, /DisclosureGroup\("進階：用終端機更新"\)/);
  assert.match(card, /GitHubReleaseUpdateChecker\.installCommand/);
  assert.match(stubs, /InAppUpdater\.shared\.consumeResultOnLaunch\(\)/);
});

test('updater reuses install.sh from the same public repository and never re-implements verification', () => {
  assert.match(updater, /https:\/\/raw\.githubusercontent\.com\/\\\(repository\)\/main\/install\.sh/);
  assert.match(updater, /\/bin\/launchctl/);
  assert.match(updater, /"submit", "-l", label/);
  assert.match(updater, /NSApp\.terminate\(nil\)/);
  assert.match(updater, /TATWO_OS_VERSION="\$TAG" bash "\$SCRIPT"/);
  assert.doesNotMatch(updater, /codesign|shasum|unzip|spctl/);
  assert.match(updater, /\^v\?\[0-9\]\+\[\.\]\[0-9\]\+/);
});

// 把 Swift 裡的 helper 模板還原成真的 bash 腳本，用假的 install.sh 跑一遍。
function renderHelper({ pid, resultPath, logPath, destination, label }) {
  const begin = updater.indexOf('// UPDATE-HELPER-BEGIN');
  const end = updater.indexOf('// UPDATE-HELPER-END');
  const block = updater.slice(begin, end);
  const body = block.slice(block.indexOf('"""') + 3, block.lastIndexOf('"""'));
  const lines = body.split('\n');
  const indent = lines.find(line => line.trim().length)?.match(/^\s*/)[0].length ?? 0;
  return lines.map(line => line.slice(indent)).join('\n')
    .replace(/\\\\n/g, '\\n')
    .replace('\\(pid)', String(pid))
    .replace("'\\(tag)'", "'v9.9.9'")
    .replace("'\\(installURL)'", "'https://invalid.example/install.sh'")
    .replace("'\\(resultPath)'", `'${resultPath}'`)
    .replace("'\\(logPath)'", `'${logPath}'`)
    .replace("'\\(destination)'", `'${destination}'`)
    .replace("'\\(label)'", `'${label}'`)
    .replace('\\(helperWaitSeconds)', '10');
}

function run(fakeInstallExit) {
  const dir = mkdtempSync(join(tmpdir(), 'tatwo-update-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  // 假 open / launchctl：只留紀錄，不真的開 App、不動 launchd。
  writeFileSync(join(bin, 'open'), `#!/bin/sh\necho "$@" >> '${join(dir, 'open.calls')}'\n`);
  writeFileSync(join(bin, 'launchctl'), `#!/bin/sh\necho "$@" >> '${join(dir, 'launchctl.calls')}'\n`);
  chmodSync(join(bin, 'open'), 0o755);
  chmodSync(join(bin, 'launchctl'), 0o755);
  const install = join(dir, 'install.sh');
  writeFileSync(install, `#!/bin/bash\necho "install version=$TATWO_OS_VERSION" >> '${join(dir, 'install.calls')}'\nexit ${fakeInstallExit}\n`);
  const destination = join(dir, 'TATWO OS.app');
  mkdirSync(destination);
  // 假 App 用 bash 背景起，交給 launchd 收屍；node 自己 spawn 的子進程在 spawnSync 期間
  // 不會被回收，變成殭屍後 kill -0 仍成功，helper 會誤判 App 還在。
  const app = { pid: Number(spawnSync('bash', ['-c', 'sleep 2 >/dev/null 2>&1 & echo $!']).stdout.toString().trim()) };
  assert.ok(app.pid > 0);
  const script = join(dir, 'helper.sh');
  writeFileSync(script, renderHelper({
    pid: app.pid, resultPath: join(dir, 'result.json'), logPath: join(dir, 'update.log'),
    destination, label: 'ai.tatwo.tatwo2.updater.test',
  }).replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin', `export PATH='${bin}':/usr/bin:/bin:/usr/sbin:/sbin`));
  const started = Date.now();
  const result = spawnSync('bash', [script], { env: { ...process.env, TATWO2_UPDATE_INSTALL_SCRIPT: install }, timeout: 30_000 });
  return { dir, result, waited: Date.now() - started };
}

test('helper waits for the app to exit, pins the version, then records success', () => {
  const { dir, result, waited } = run(0);
  assert.equal(result.status, 0, result.stderr.toString());
  assert.ok(waited >= 1500, `helper must wait for the app pid to exit (waited ${waited}ms)`);
  assert.match(readFileSync(join(dir, 'install.calls'), 'utf8'), /install version=v9\.9\.9/);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'result.json'), 'utf8')), { ok: true, tag: 'v9.9.9', message: 'installed' });
  assert.ok(!existsSync(join(dir, 'open.calls')), 'install.sh opens the new app itself; helper must not open on success');
});

test('helper reports install failure, reopens the kept app, and never claims success', () => {
  const { dir, result } = run(3);
  assert.equal(result.status, 1);
  assert.deepEqual(JSON.parse(readFileSync(join(dir, 'result.json'), 'utf8')), { ok: false, tag: 'v9.9.9', message: 'install_failed_exit_3' });
  assert.match(readFileSync(join(dir, 'open.calls'), 'utf8'), /TATWO OS\.app/);
});
