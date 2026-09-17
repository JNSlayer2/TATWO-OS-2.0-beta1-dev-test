import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';
import { testScratch } from './helpers/test-scratch.mjs';
import { delay } from '../Engines/gbrain-adapter/service.mjs';

test('W82 production onboarding: clean HOME, preview, identity, rules, exact removal and secondary isolation',
  { timeout: 180_000 }, async () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'TATWO2_TEST_BINARY is required; never skip acceptance');
    assert.ok(process.env.W80B_GBRAIN_HELPER, 'real W80b helper is required; never fake PGLite');
    const root = testScratch('w82-onboarding-');
    const home = path.join(root, 'isolated-process-home');
    fs.mkdirSync(home);
    const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
      encoding: 'utf8', timeout: 90_000,
      env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, CFFIXED_USER_HOME: home,
        TATWO2_W82_TEST_ROOT: root, TATWO2_LIVE_ROOT: path.join(root, 'live'),
        TATWO2_OS_ROOT: path.join(root, 'unused-entry'),
        TATWO2_OS_UPSTREAM_PATH: path.join(root, 'unused-runtime.md') },
    });
    assert.match(output, /W82TEST SUMMARY failures=0/);
    for (const label of ['preview has no filesystem writes', 'first device primary identity',
      'existing identity never reruns', 'secondary creates neither constitution nor database',
      'remove restores original hash claude-cli', 'remove restores original hash codex-cli',
      'stale preview fails before entrance write', 'paired primary defaults to secondary']) {
      assert.ok(output.includes('W82TEST PASS ' + label), label);
    }
    console.log(output.trim());
    const entry = path.join(root, 'home', 'AI', 'TATWO OS');
    const service = spawn(process.execPath, [
      fileURLToPath(new URL('../Engines/gbrain-adapter/service.mjs', import.meta.url)),
      entry, process.env.W80B_GBRAIN_HELPER,
    ], { env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home },
      stdio: ['pipe', 'pipe', 'pipe'] });
    const lines = readline.createInterface({ input: service.stdout });
    // Synthetic in-memory token sink, exactly like W80b; never touch the real Keychain.
    lines.on('line', line => {
      try { if (JSON.parse(line).token) service.stdin.write('stored\n'); } catch {}
    });
    let diagnostics = '';
    service.stderr.on('data', bytes => { diagnostics += bytes; });
    try {
      let state;
      for (let i = 0; i < 180; i++) {
        assert.equal(service.exitCode, null, diagnostics);
        try { state = JSON.parse(fs.readFileSync(path.join(entry, 'gbrain/state.json'))); } catch {}
        if (state?.healthy) break;
        await delay(500);
      }
      assert.equal(state?.healthy, true, JSON.stringify(state) + diagnostics);
      const config = JSON.parse(fs.readFileSync(path.join(entry, 'gbrain/home/.gbrain/config.json')));
      assert.equal(config.engine, 'pglite');
      assert.equal(config.database_path, path.join(entry, 'gbrain/brain'));
      assert.ok(fs.statSync(config.database_path).isDirectory());
      console.log('W82TEST PASS real W80b init --pglite at onboarding entrance');
    } finally {
      lines.close();
      if (service.exitCode === null) {
        const stopped = once(service, 'exit');
        service.stdin.end();
        service.kill('SIGTERM');
        const timer = setTimeout(() => service.kill('SIGKILL'), 10_000);
        await stopped;
        clearTimeout(timer);
      }
    }
  });

test('W82 keeps installer copies byte-identical and first-run work in App', () => {
  assert.deepEqual(fs.readFileSync('install.sh'), fs.readFileSync('public/install.sh'));
  const shell = fs.readFileSync('App/Sources/Tatwo2/Shell/AppShell.swift', 'utf8');
  assert.match(shell, /OSOnboardingGate/);
  assert.match(shell, /guard onboardingReady, chatModel == nil/);
  const view = fs.readFileSync('App/Sources/Tatwo2/Onboarding/OSOnboardingView.swift', 'utf8');
  assert.match(view, /"歡迎", "環境偵測", "命名與角色", "工作環境", "引擎掃描", "產生預覽", "偏好", "邊界", "完成"/);
  assert.match(view, /移除 OS 管理區塊/);
});
