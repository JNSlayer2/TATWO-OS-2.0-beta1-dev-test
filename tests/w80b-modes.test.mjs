import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { supervise, delay } from '../Engines/gbrain-adapter/service.mjs';
import { sshArguments, sshCommand } from '../Engines/gbrain-adapter/server.mjs';
import { testScratch } from './helpers/test-scratch.mjs';

const supervisor = fileURLToPath(new URL('../Engines/gbrain-adapter/service.mjs', import.meta.url));
test('W80b secondary refuses every local database mode before executing a helper', async () => {
  for (const mode of ['pglite', 'legacy']) {
    const root = testScratch('w80b-secondary-');
    fs.mkdirSync(path.join(root, 'gbrain'));
    fs.writeFileSync(path.join(root, 'device.json'), JSON.stringify({ role: 'secondary', name: 'fixture' }));
    fs.writeFileSync(path.join(root, 'gbrain/connection.json'), JSON.stringify({ mode }));
    await assert.rejects(supervise({ root, helper: '/fixture-must-not-execute' }), /secondary_no_database/);
    assert.equal(fs.existsSync(path.join(root, 'gbrain/brain')), false);
  }
});
test('W80b SSH uses paired host trust, validates target/port and quotes remote wrapper arguments', () => {
  const config = { host: '127.0.0.1', user: 'fixture', sshPort: 2222, command: '/fixture/with spaces/wrapper', args: ["a'b"] };
  const args = sshArguments(config);
  assert.ok(args.includes('StrictHostKeyChecking=yes')); assert.ok(args.includes('BatchMode=yes'));
  assert.ok(args.includes('2222')); assert.ok(args.includes('fixture'));
  assert.equal(sshCommand(config), "'/fixture/with spaces/wrapper' 'a'\\''b'");
  assert.throws(() => sshArguments({ ...config, host: '-oProxyCommand=bad' }));
  assert.throws(() => sshArguments({ ...config, user: 'bad user' }));
  assert.throws(() => sshArguments({ ...config, sshPort: 0 }));
});
test('W80b existing stdio service stays on its wrapper and never invokes the new helper', { timeout: 30000 }, async () => {
  const root = testScratch('w80b-legacy-');
  const home = path.join(root, 'home'); fs.mkdirSync(home);
  const directory = path.join(root, 'gbrain'); fs.mkdirSync(directory);
  fs.writeFileSync(path.join(root, 'device.json'), JSON.stringify({ role: 'primary', name: 'fixture' }));
  const wrapper = path.join(root, 'legacy.mjs');
  const seen = path.join(root, 'seen.jsonl');
  fs.writeFileSync(wrapper, `
import fs from 'node:fs';
import readline from 'node:readline';
for await (const line of readline.createInterface({input:process.stdin})) {
  const r = JSON.parse(line); if (r.id === undefined) continue;
  fs.appendFileSync(process.env.SEEN, JSON.stringify({method:r.method, tool:r.params?.name})+'\\n');
  let result = r.method === 'initialize' ? {protocolVersion:'2024-11-05', capabilities:{}, serverInfo:{name:'fixture',version:'1'}} :
    {content:[{type:'text',text:JSON.stringify(r.params?.name === 'get_stats' ? {page_count:7} : [])}]};
  console.log(JSON.stringify({jsonrpc:'2.0',id:r.id,result}));
}
`);
  fs.writeFileSync(path.join(directory, 'connection.json'), JSON.stringify({ mode: 'legacy', command: process.execPath, args: [wrapper] }));
  const owner = spawn(process.execPath, [supervisor, root, '/fixture-must-not-execute'], {
    env: { HOME: home, PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, SEEN: seen }, stdio: ['pipe', 'ignore', 'pipe'],
  });
  let error = ''; owner.stderr.on('data', bytes => { error += bytes; });
  try {
    let state;
    for (let i = 0; i < 80; i++) {
      try { state = JSON.parse(fs.readFileSync(path.join(directory, 'state.json'))); } catch {}
      if (state?.healthy) break;
      if (owner.exitCode !== null) assert.fail(error);
      await delay(100);
    }
    assert.equal(state?.mode, 'legacy'); assert.equal(state?.healthy, true, error);
    assert.equal(state?.pageCount, 7);
    assert.equal(fs.existsSync(path.join(directory, 'brain')), false);
    assert.equal(fs.existsSync(path.join(directory, 'home')), false);
    const calls = fs.readFileSync(seen, 'utf8').trim().split('\n').map(JSON.parse);
    assert.ok(calls.every(call => ['initialize', 'tools/call'].includes(call.method)));
    assert.ok(calls.filter(c => c.tool).every(c => ['get_stats', 'list_pages', 'get_ingest_log'].includes(c.tool)));
  } finally {
    if (owner.exitCode === null && owner.signalCode === null) {
      const done = once(owner, 'exit'); owner.stdin.end(); owner.kill('SIGTERM'); await done;
    }
  }
});
test('W80b Grok registry selection reaches isolated MCP config and replaces quoted legacy GBrain', { timeout: 10000 }, async () => {
  const root = testScratch('w80b-grok-');
  const isolated = path.join(root, 'isolated'); fs.mkdirSync(path.join(isolated, '.grok'), { recursive: true });
  const config = path.join(isolated, '.grok/config.toml');
  fs.writeFileSync(config, '[mcp_servers.fixture_on]\ncommand = "unused"\nenabled = false\n[mcp_servers.fixture_off]\ncommand = "unused"\nenabled = true\n[mcp_servers."gbrain_allai"]\ncommand = "old-wrapper"\n');
  const selection = { engine: 'grok', configured: ['fixture_on', 'fixture_off', 'gbrain_allai'], enabled: ['fixture_on', 'gbrain_allai'],
    servers: { gbrain_allai: { command: process.execPath, args: ['/fixture/adapter.mjs', root] } } };
  const sidecar = fileURLToPath(new URL('../Engines/grok-sidecar/sidecar.mjs', import.meta.url));
  const child = spawn(process.execPath, [sidecar, '--cwd', root, '--mcp-config', JSON.stringify(selection)], {
    env: { HOME: root, TMPDIR: process.env.TMPDIR, PATH: process.env.PATH, TATWO2_GROK_HOME: isolated }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  child.stdout.resume(); child.stderr.resume();
  const done = once(child, 'exit'); child.stdin.end(); await done;
  const result = fs.readFileSync(config, 'utf8');
  assert.match(result, /\[mcp_servers.fixture_on\]\nenabled = true/);
  assert.match(result, /\[mcp_servers.fixture_off\]\nenabled = false/);
  assert.match(result, /\[mcp_servers.gbrain_allai\][\s\S]*enabled = true/);
  assert.doesNotMatch(result, /old-wrapper/);
  assert.equal((result.match(/\[mcp_servers.gbrain_allai\]/g) ?? []).length, 1);
  assert.equal(fs.existsSync(path.join(root, '.grok/config.toml')), false);
});
