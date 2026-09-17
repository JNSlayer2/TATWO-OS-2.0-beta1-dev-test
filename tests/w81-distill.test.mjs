import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import readline from 'node:readline';
import { once } from 'node:events';
import { StdioTransport } from '../Engines/gbrain-adapter/server.mjs';
import { delay } from '../Engines/gbrain-adapter/service.mjs';

const read = file => fs.readFileSync(new URL(`../App/Sources/Tatwo2/${file}`, import.meta.url), 'utf8');
const binary = process.env.TATWO2_TEST_BINARY;
const headings = ['這段做了什麼', '架構現況', '決策與理由', '教訓', '下一步'];
const finalBody = headings.map(title => `## ${title}\n使用者改過這一句，保留　空白、兩個空格  、Cafe\u0301 與 emoji 🧪。`).join('\n\n');
function fixture() {
  const root = fs.mkdtempSync(path.join(tmpdir(), 'w81-'));
  const at = name => path.join(root, name);
  for (const name of ['h', 'l', 'e', 'entry', 'docs']) fs.mkdirSync(at(name));
  fs.writeFileSync(at('owned-fixture'), 'synthetic W81 fixture only\n');
  const env = {
    PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: at('h'), CFFIXED_USER_HOME: at('h'),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    TATWO2_W81_TEST_ROOT: root, TATWO2_SOURCETEST: '1',
    TATWO_STAGING_ROOT: root, TATWO_STAGING_SCRATCH_HOME: at('h'),
    TATWO2_LIVE_ROOT: at('l'), TATWO2_ENGINES_ROOT: at('e'),
    CODEX_HOME: at('e/codex'), TATWO2_CODEX_SOURCE_HOME: at('e/codex'),
    CLAUDE_CONFIG_DIR: at('e/claude'), CLAUDE_SECURESTORAGE_CONFIG_DIR: at('e/claude'),
    TATWO2_OS_SOCKET: at('o.sock'), TATWO2_BROWSER_SOCKET: at('b.sock'),
    TATWO_OS_ROOT: at('entry'), TATWO2_OS_ROOT: at('entry'), TATWO2_DOCS_ROOT: at('docs'),
    TATWO2_OS_UPSTREAM_PATH: at('docs/os-upstream.md'), TATWO2_SKILLET_PATH: at('entry/skillet.md'),
  };
  return { root, at, env };
}
function run(env) {
  assert.ok(binary && fs.existsSync(binary), 'Set TATWO2_TEST_BINARY to the current build; never skip.');
  const result = spawnSync(binary, [], { env, encoding: 'utf8', timeout: 150_000, maxBuffer: 2 * 1024 * 1024 });
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  assert.match(output, /W81TEST SUMMARY failures=0/);
  console.log(output.split('\n').filter(line => line.startsWith('W81TEST')).join('\n'));
  return output;
}

test('W81 production Swift: draft, repeated rewrite, exact edits, primary submit, cancel/reopen, guards',
  { timeout: 180_000 }, () => {
    const { env } = fixture();
    const output = run(env);
    for (const name of [
      'bare-command-opens-canvas', 'argument-command-opens-canvas', 'ai-draft-exact',
      'ai-multiple-rewrites', 'nested-fence-preserved', 'example-and-incomplete-fence-ignored',
      'human-edit-byte-exact', 'raw-json-roundtrip', 'ordinary-confirm-cannot-submit',
      'close-reopen-no-write', 'no-destination-rejected', 'unavailable-gbrain-rejected',
      'gbrain-normalization-rejected', 'stale-snapshot-rejected', 'human-submit-boundary',
      'primary-write-byte-exact', 'stale-preview-no-overwrite', 'submitted-edit-blocked',
      'submission-survives-reopen-no-rewrite', 'repeat-submission-rejected',
    ]) assert.ok(output.includes(`W81TEST PASS ${name}\n`), name);
  });

test('W81 shared canvas keeps destinations unselected, unavailable disabled, and only human click writes', () => {
  const actions = read('Facade/DistillCanvas.swift');
  const canvas = read('Chat/ChatPage+Plan.swift');
  const engine = read('Facade/ChatLiveEngine+Plan.swift');
  assert.match(actions, /@State private var gbrain = false/);
  assert.match(actions, /@State private var skillet = false/);
  assert.match(actions, /Toggle\("GBrain", isOn: \$gbrain\)\.disabled\(!service\.healthy\)/);
  assert.match(actions, /GBrain 不可用：/);
  assert.match(actions, /Button\(busy \? "送出中…" : "送出"\) \{ submit\(\) \}/);
  assert.match(actions, /guard onSubmission\(artifact\.planID, snapshot\)[\s\S]*service\.putDistillation\(snapshot\)/);
  assert.match(actions, /previewContent\.map \{ DistillCanvas.byteEqual\(\$0, content\)/);
  assert.match(actions, /writeFromDevice\(id: "skillet", text: content, base: base/);
  assert.match(actions, /dispatch\.pushSubmission[\s\S]*method: "inbox_receive"/);
  assert.doesNotMatch(actions, /inbox\.enqueue|method: "document_propose"/);
  assert.match(canvas, /artifact.kind == "distill"[\s\S]*DistillPlanActions/);
  assert.match(engine, /plan.kind == "distill"[\s\S]*Self.distillDiscussionRules/);
  assert.match(read('Chat/ChatPage.swift'), /onDistillSubmission: model.saveDistillSubmission/);
  for (const name of ['w81-proposal-in-primary-inbox', 'w81-proposal-byte-exact',
    'w81-both-skillets-unchanged', 'w81-source-worktree-unchanged']) {
    assert.ok(read('SelfTest.swift').includes(`check("${name}"`));
  }
});

test('W81 real GBrain: Swift submit → W80 adapter → isolated PGLite → exact body + trusted source device',
  { timeout: 240_000 }, async () => {
    const helper = process.env.W80B_GBRAIN_HELPER;
    assert.ok(helper && fs.existsSync(helper), 'W80B_GBRAIN_HELPER is required; never skip.');
    const { root, at, env } = fixture();
    const ownerRoot = at('brain-owner'); fs.mkdirSync(ownerRoot);
    fs.writeFileSync(path.join(ownerRoot, 'device.json'), JSON.stringify({ role: 'primary', name: 'fixture-device' }));
    fs.writeFileSync(at('gbrain-draft.txt'), finalBody);
    const supervisor = path.resolve('Engines/gbrain-adapter/service.mjs');
    const adapter = path.resolve('Engines/gbrain-adapter/server.mjs');
    const owner = spawn(process.execPath, [supervisor, ownerRoot, helper],
      { env: { PATH: env.PATH, TMPDIR: env.TMPDIR, HOME: env.HOME }, stdio: ['pipe', 'pipe', 'pipe'] });
    let token, diagnostics = '', client;
    owner.stderr.on('data', data => { diagnostics += data; });
    readline.createInterface({ input: owner.stdout }).on('line', line => {
      const event = JSON.parse(line);
      if (event.token) { token = event.token; owner.stdin.write('stored\n'); }
    });
    try {
      let state;
      for (let i = 0; i < 180; i++) {
        assert.equal(owner.exitCode, null, `isolated owner exited: ${diagnostics}`);
        try { state = JSON.parse(fs.readFileSync(path.join(ownerRoot, 'gbrain/state.json'))); } catch {}
        if (state?.healthy && token) break;
        await delay(500);
      }
      assert.equal(state?.healthy, true, diagnostics);
      run({ ...env, TATWO_GBRAIN_TOKEN: token,
        TATWO2_W81_GBRAIN_DEFINITION: JSON.stringify({ command: process.execPath, args: [adapter, ownerRoot] }) });
      client = new StdioTransport(process.execPath, [adapter, ownerRoot], { ...env, TATWO_GBRAIN_TOKEN: token });
      await client.request({ jsonrpc: '2.0', id: 1, method: 'initialize',
        params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } } });
      await client.request({ jsonrpc: '2.0', method: 'notifications/initialized' });
      const readback = await client.request({ jsonrpc: '2.0', id: 2, method: 'tools/call',
        params: { name: 'get_page', arguments: { slug: 'distill/w81-fixture' } } });
      assert.ok(!readback.error && !readback.result?.isError, JSON.stringify(readback));
      const page = readback.result.structuredContent ??
        JSON.parse(readback.result.content.find(row => row.type === 'text').text);
      assert.equal(page.compiled_truth, finalBody);
      assert.equal(page.title, 'Synthetic distillation');
      assert.equal(page.frontmatter.device, 'fixture-device');
      assert.ok(page.tags.includes('device:fixture-device'));
      fs.writeFileSync(at('roundtrip-evidence.json'), JSON.stringify({ slug: page.slug, exact: true,
        device: page.frontmatter.device, bytes: Buffer.byteLength(finalBody) }, null, 2));
      console.log(`W81 real roundtrip evidence: ${root}`);
    } finally {
      client?.close();
      if (owner.exitCode === null && owner.signalCode === null) {
        const exited = once(owner, 'exit');
        const timer = setTimeout(() => owner.kill('SIGKILL'), 10_000);
        owner.stdin.end(); owner.kill('SIGTERM');
        try { await exited; } finally { clearTimeout(timer); }
      }
    }
  });
