import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, execFileSync } from 'node:child_process';
import readline from 'node:readline';
import { once } from 'node:events';
import { stamp, reads, writes, StdioTransport, HTTPTransport } from '../Engines/gbrain-adapter/server.mjs';
import { redact, scanSecrets, cleanEnvironment, delay, health } from '../Engines/gbrain-adapter/service.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

const adapter = fileURLToPath(new URL('../Engines/gbrain-adapter/server.mjs', import.meta.url));
const supervisor = fileURLToPath(new URL('../Engines/gbrain-adapter/service.mjs', import.meta.url));
const fakeKey = 'sk-test-w80b-not-real';
const device = 'fixture-device';
async function stop(child) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const done = once(child, 'exit');
  const deadline = setTimeout(() => child.kill('SIGKILL'), 10000);
  child.stdin.end(); child.kill('SIGTERM');
  try { await done; } finally { clearTimeout(deadline); }
}
test('W80b writes receive trusted device metadata; reads remain byte-equivalent', () => {
  const input = { slug: 'fixture/page', content: '---\ntitle: Fixture\ntags: [old]\ndevice: forged\n---\nbody' };
  const output = stamp('put_page', input, device);
  assert.match(output.content, /device: "fixture-device"/);
  assert.match(output.content, /"old","device","device:fixture-device"/);
  assert.doesNotMatch(output.content, /forged/);
  assert.equal(input.content.includes('forged'), true);
  assert.match(stamp('put_page', { content: 'body' }, device).content, /tags:/);
  assert.match(stamp('put_page', { content: '---\ntags:\n  - old\n---\nbody' }, device).content, /"old"/);
  const raw = stamp('put_raw_data', { data: { value: 42 } }, device);
  assert.equal(raw.data.device, device); assert.ok(raw.data.tags.includes('device'));
  const timeline = stamp('add_timeline_entry', { detail: 'original' }, device);
  assert.equal(timeline.source, `device:${device}`);
  assert.match(timeline.detail, /device:fixture-device/);
  const ingest = stamp('log_ingest', { source_ref: 'fixture', summary: 'fixture' }, device);
  assert.equal(ingest.source_ref, 'fixture');
  assert.match(ingest.summary, /"device","device:fixture-device"/);
  for (const name of reads) assert.equal(stamp(name, input, device), input);
});
test('W80b deny destructive, schema, generic SQL and unimplemented write routes', () => {
  for (const name of ['delete_page', 'purge_deleted_pages', 'query', 'reload_schema_pack', 'migrate_embeddings', 'request_tools', 'capture', 'forget']) {
    assert.throws(() => stamp(name, {}, device), /tool_not_allowed/);
    assert.equal(reads.has(name) || writes.has(name), false);
  }
  assert.throws(() => stamp('put_page', { content: '---\ntags: *alias\n---\nbody' }, device));
  assert.throws(() => stamp('put_page', { content: 'body' }, 'bad\nidentity'));
});
test('W80b no inherited DB credentials; log redaction and recursive leak detection', () => {
  const env = cleanEnvironment('/fixture/home', { PATH: '/bin', DATABASE_URL: 'never-forward', OPENAI_API_KEY: fakeKey, GBRAIN_DATABASE_URL: 'never-forward' });
  assert.equal(env.OPENAI_API_KEY, undefined); assert.equal(env.DATABASE_URL, undefined);
  assert.equal(env.GBRAIN_DATABASE_URL, undefined);
  assert.doesNotMatch(redact(`key ${fakeKey} Bearer fixture-token`, [fakeKey]), /not-real|fixture-token/);
  const root = testScratch('w80b-scan-');
  fs.writeFileSync(path.join(root, 'safe'), 'safe');
  assert.doesNotThrow(() => scanSecrets(root, [fakeKey]));
  fs.writeFileSync(path.join(root, 'synthetic-leak'), fakeKey);
  assert.throws(() => scanSecrets(root, [fakeKey]), /secret_on_disk/);
});
test('W80b HTTP transport rejects non-loopback, TLS downgrade targets and credentials', () => {
  for (const url of ['http://0.0.0.0:1234/mcp', 'https://127.0.0.1:1234/mcp', 'http://user:pass@127.0.0.1/mcp']) {
    assert.throws(() => new HTTPTransport(url, 'fixture'));
  }
});
test('W80b UI guards secondary credentials and no-key semantic search; helper sign precedes app seal', () => {
  const read = name => fs.readFileSync(fileURLToPath(new URL(`../${name}`, import.meta.url)), 'utf8');
  const ui = read('App/Sources/Tatwo2/New/OSDocumentsCard.swift');
  assert.match(ui, /\.disabled\(!service.isPrimary\)/);
  assert.match(ui, /\.disabled\(!service.isPrimary \|\| !service.openAIConfigured\)/);
  const service = read('App/Sources/Tatwo2/Facade/GBrainService.swift');
  assert.match(service, /guard isPrimary, !enabled \|\| openAIConfigured/);
  const build = read('scripts/build-app.sh');
  assert.ok(build.indexOf('bundle-gbrain.py" finalize') < build.indexOf('codesign --force --sign "$SIGN_IDENTITY"'));
  // Both identity and ad-hoc branches finalize the helper before the complete
  // nested-runtime signing pass, then prepare the manifest immediately after it.
  for (const identity of ['"$SIGN_IDENTITY"', '-']) {
    const finalize = build.indexOf(`bundle-gbrain.py" finalize "$APP" ${identity}`);
    const nested = build.indexOf(`runtime-sign.py" "$APP" ${identity}`);
    assert.ok(finalize >= 0 && nested > finalize, identity);
    assert.ok(build.slice(nested).startsWith(
      `runtime-sign.py" "$APP" ${identity}\n  bash "$ROOT/scripts/runtime-layer.sh" prepare "$APP"`), identity);
  }
  const packaging = read('scripts/bundle-gbrain.py');
  assert.match(packaging, /Contents\/Helpers\/gbrain/);
  assert.match(packaging, /officialDigest/); assert.match(packaging, /signedSHA256/);
});

const helper = process.env.W80B_GBRAIN_HELPER;
test('W80b actual PGLite: single owner, two stdio clients, metadata, denylist, secret scans before/after shutdown',
  { skip: !helper && 'Set W80B_GBRAIN_HELPER to the isolated, re-signed W80a helper', timeout: 180000 }, async () => {
    const root = testScratch('w80b-pglite-');
    const home = path.join(root, 'synthetic-home'); fs.mkdirSync(home);
    fs.writeFileSync(path.join(root, 'device.json'), JSON.stringify({ role: 'primary', name: device }));
    const env = { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home, OPENAI_API_KEY: fakeKey };
    const owner = spawn(process.execPath, [supervisor, root, helper], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let token, diagnostics = '';
    owner.stderr.on('data', data => { diagnostics += data; });
    readline.createInterface({ input: owner.stdout }).on('line', line => {
      const event = JSON.parse(line);
      if (event.token) { token = event.token; owner.stdin.write('stored\n'); }
    });
    let a, b;
    try {
      let state;
      for (let i = 0; i < 180; i++) {
        if (owner.exitCode !== null) assert.fail(`isolated service exited: ${diagnostics}`);
        try { state = JSON.parse(fs.readFileSync(path.join(root, 'gbrain/state.json'))); } catch {}
        if (state?.healthy && token) break;
        await delay(500);
      }
      assert.equal(state?.healthy, true, `service state: ${JSON.stringify(state)} ${diagnostics}`);
      const ownerPID = fs.readFileSync(path.join(root, 'gbrain/service.lock/owner'), 'utf8');
      const duplicate = spawn(process.execPath, [supervisor, root, helper], { env, stdio: 'ignore' });
      const code = await new Promise(resolve => duplicate.once('exit', resolve));
      assert.notEqual(code, 0);
      assert.equal(fs.readFileSync(path.join(root, 'gbrain/service.lock/owner'), 'utf8'), ownerPID);
      a = new StdioTransport(process.execPath, [adapter, root], { ...env, TATWO_GBRAIN_TOKEN: token });
      b = new StdioTransport(process.execPath, [adapter, root], { ...env, TATWO_GBRAIN_TOKEN: token });
      const init = { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } } };
      await Promise.all([a.request(init), b.request(init)]);
      await Promise.all([a.request({ jsonrpc: '2.0', method: 'notifications/initialized' }), b.request({ jsonrpc: '2.0', method: 'notifications/initialized' })]);
      const call = (client, id, name, args) => client.request({ jsonrpc: '2.0', id, method: 'tools/call', params: { name, arguments: args } });
      const written = await Promise.all([
        call(a, 2, 'put_page', { slug: 'fixture/a', content: '---\ntitle: Fixture A\ntype: note\n---\nalpha content' }),
        call(b, 2, 'put_page', { slug: 'fixture/b', content: '---\ntitle: Fixture B\ntype: note\n---\nbeta content' }),
      ]);
      for (const result of written) assert.ok(!result.error && !result.result?.isError, JSON.stringify(result));
      const pages = await Promise.all([call(a, 3, 'get_page', { slug: 'fixture/b' }), call(b, 3, 'get_page', { slug: 'fixture/a' })]);
      for (const page of pages) {
        assert.match(JSON.stringify(page), /device:fixture-device/);
        assert.ok(!page.error && !page.result?.isError, JSON.stringify(page));
      }
      const search = await call(a, 6, 'search', { query: 'alpha' });
      assert.ok(!search.error && !search.result?.isError, JSON.stringify(search));
      assert.match(JSON.stringify(search), /fixture\/a/);
      for (const [tool, args] of [
        ['add_timeline_entry', { slug: 'fixture/a', date: '2026-01-02', summary: 'Fixture event', detail: 'Fixture detail' }],
        ['put_raw_data', { slug: 'fixture/a', source: 'fixture', data: { value: 42, device: 'forged', tags: ['device:forged'] } }],
        ['log_ingest', { source_type: 'fixture', source_ref: 'fixture:event', pages_updated: ['fixture/a'], summary: 'Fixture ingest' }],
      ]) {
        const result = await call(b, 7, tool, args);
        assert.ok(!result.error && !result.result?.isError, JSON.stringify(result));
      }
      for (const tool of ['get_timeline', 'get_raw_data']) {
        const result = await call(a, 8, tool, { slug: 'fixture/a' });
        assert.match(JSON.stringify(result), /device:fixture-device/);
        assert.doesNotMatch(JSON.stringify(result), /device:forged/);
      }
      const probe = new HTTPTransport(state.endpoint, token);
      try {
        const snapshot = await health(probe);
        assert.equal(snapshot.pageCount, 2);
        assert.equal(snapshot.lastWriteDevice, device);
        assert.ok(snapshot.lastWriteAt);
      } finally { await probe.close(); }
      assert.ok((await call(a, 4, 'delete_page', { slug: 'fixture/a' })).error);
      const tools = await a.request({ jsonrpc: '2.0', id: 5, method: 'tools/list' });
      assert.ok(tools.result.tools.length > 0);
      assert.ok(tools.result.tools.every(t => reads.has(t.name) || writes.has(t.name)));
      const unauthorized = await fetch(state.endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(init) });
      assert.equal(unauthorized.status, 401);
      scanSecrets(root, [fakeKey, token]);
      assert.ok(fs.existsSync(path.join(root, 'gbrain/brain')));
      console.log('W80b PGLite: one owner; two adapters wrote/read device tags; unauthenticated HTTP 401; secret scan clean');
    } finally {
      a?.close(); b?.close(); await stop(owner);
    }
    scanSecrets(root, [fakeKey, token]);
    assert.equal(fs.existsSync(path.join(root, 'gbrain/service.lock')), false);
    // Even a stale persisted preference cannot enable semantic search without a key.
    fs.writeFileSync(path.join(root, 'gbrain/preferences.json'), JSON.stringify({ semanticEnabled: true }));
    const keylessEnv = { ...env, TATWO_GBRAIN_TOKEN: token }; delete keylessEnv.OPENAI_API_KEY;
    const keyless = spawn(process.execPath, [supervisor, root, helper], { env: keylessEnv, stdio: ['pipe', 'ignore', 'pipe'] });
    let keylessError = ''; keyless.stderr.on('data', bytes => { keylessError += bytes; });
    try {
      let state;
      for (let i = 0; i < 120; i++) {
        if (keyless.exitCode !== null) assert.fail(keylessError);
        try { state = JSON.parse(fs.readFileSync(path.join(root, 'gbrain/state.json'))); } catch {}
        if (state?.healthy) break;
        await delay(250);
      }
      assert.equal(state?.healthy, true, keylessError);
      assert.equal(state?.semanticEnabled, false);
      const config = JSON.parse(fs.readFileSync(path.join(root, 'gbrain/home/.gbrain/config.json')));
      assert.equal(config.embedding_disabled, true);
    } finally {
      await stop(keyless);
    }
    scanSecrets(root, [fakeKey, token]);
  });

test('W80b official release digest matches pinned packager', { skip: !process.env.W80B_RELEASE_JSON }, () => {
  const release = JSON.parse(fs.readFileSync(process.env.W80B_RELEASE_JSON));
  const asset = release.assets.find(a => a.name === 'gbrain-darwin-arm64');
  const packaging = fs.readFileSync(fileURLToPath(new URL('../scripts/bundle-gbrain.py', import.meta.url)), 'utf8');
  assert.ok(packaging.includes(`DIGEST = "${asset.digest}"`));
  assert.equal(release.tag_name, 'v0.50.5.0');
});

test('W80b actual asset is cached, verified, placed in Helpers and re-signed in a synthetic bundle',
  { skip: !process.env.W80B_ASSET || !process.env.W80B_LICENSE || !process.env.W80B_RELEASE_JSON, timeout: 60000 }, () => {
    const root = testScratch('w80b-bundle-');
    const script = fileURLToPath(new URL('../scripts/bundle-gbrain.py', import.meta.url));
    const code = `
import importlib.util, os, sys, shutil, json
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("bundle", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
root = Path(sys.argv[2]); app = root / "Fixture.app"; cache = root / "cache"
counts = {"asset": 0}
def download(url, dest):
    if url == m.API: src = os.environ["W80B_RELEASE_JSON"]
    elif url.endswith("/LICENSE"): src = os.environ["W80B_LICENSE"]
    else:
        src = os.environ["W80B_ASSET"]; counts["asset"] += 1
    shutil.copyfile(src, dest)
m.download = download
m.prepare(app, cache); m.prepare(app, cache)
assert counts["asset"] == 1
assert (app / "Contents/Helpers/gbrain").is_file()
assert not (app / "Contents/Resources/gbrain/gbrain").exists()
m.finalize(app, "-")
manifest = json.loads((app / "Contents/Resources/gbrain/manifest.json").read_text())
assert manifest["officialDigest"] == m.DIGEST
assert manifest["signedSHA256"] == m.sha256(app / "Contents/Helpers/gbrain")
assert manifest["signedSHA256"] != manifest["originalSHA256"]
assert "MIT License" in (app / "Contents/Resources/gbrain/LICENSE").read_text()
print("W80b synthetic bundle: official digest verified, cache reused, Helpers signed before outer seal")
`;
    const result = execFileSync('python3', ['-E', '-c', code, script, root], { encoding: 'utf8', timeout: 55000, env: process.env });
    assert.match(result, /official digest verified/);
  });
