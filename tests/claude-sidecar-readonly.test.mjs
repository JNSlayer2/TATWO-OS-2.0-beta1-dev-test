import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const sidecar = path.join(repo, 'Engines/claude-sidecar/sidecar.mjs');
const readTools = ['Read', 'Grep', 'Glob'];
const deniedTools = ['Bash', 'Edit', 'Write', 'NotebookEdit', 'Task', 'Agent', 'Skill',
  'WebFetch', 'mcp__tatwo2_os__run_background', 'mcp__tatwo2_browser__click', 'unknown_tool'];
const writableMCP = {
  engine: 'claude', threadID: 'fixture-owner',
  servers: { writable: { command: '/fixture/do-not-execute', args: ['write'],
    env: { FIXTURE_VALUE: 'inert' } } },
};

// Execute the actual sidecar entrypoint. Only its SDK import is replaced, before
// any vendor code can load; no real model, settings, credentials or MCP is used.
async function runFixture(t, { mode = 'readOnly', resume, mcpConfig = writableMCP,
  tools = [...readTools, ...deniedTools], allow = true } = {}) {
  const output = path.join(repo, 'output/lightweight-repair');
  await fs.mkdir(output, { recursive: true });
  const root = await fs.mkdtemp(path.join(output, 'claude-readonly.'));
  const sdkFile = path.join(root, 'fake-sdk.mjs');
  const capture = path.join(root, 'capture.json');
  await fs.writeFile(sdkFile, `
import fs from 'node:fs';
export function query({ options }) {
  fs.writeFileSync(process.env.CAPTURE, JSON.stringify(options));
  return (async function* () {
    const results = [];
    for (const [index, tool] of JSON.parse(process.env.FIXTURE_TOOLS).entries()) {
      const input = { fixture: tool, file_path: '/synthetic/read-target' };
      const result = await options.canUseTool(tool, input, {
        requestId: String(index), signal: new AbortController().signal,
      });
      results.push({ tool, input, result });
    }
    yield { type: 'fixture_permissions', results };
  })();
}
`);
  const loader = path.join(root, 'loader.mjs');
  await fs.writeFile(loader, `
export async function resolve(specifier, context, nextResolve) {
  if (specifier === '@anthropic-ai/claude-agent-sdk') {
    return { url: ${JSON.stringify(pathToFileURL(sdkFile).href)}, shortCircuit: true };
  }
  return nextResolve(specifier, context);
}
`);
  const args = ['--no-warnings', '--loader', loader, sidecar,
    '--cwd', root, '--model', 'fixture-model', '--system-prompt', 'fixture rules'];
  if (mode !== null) args.push('--permission-mode', mode);
  if (resume) args.push('--resume', resume);
  if (mcpConfig !== null) args.push('--mcp-config', JSON.stringify(mcpConfig));
  const child = spawn(process.execPath, args, {
    cwd: root,
    env: { HOME: root, TMPDIR: root, PATH: '/usr/bin:/bin',
      CLAUDE_CONFIG_DIR: root, CAPTURE: capture, FIXTURE_TOOLS: JSON.stringify(tools),
      TATWO2_OS_SOCKET: '/fixture/no-os.sock', TATWO2_BROWSER_SOCKET: '/fixture/no-browser.sock' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const exit = once(child, 'close');
  const events = [];
  let buffer = '', stderr = '';
  child.stdout.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n');
      const event = JSON.parse(buffer.slice(0, end));
      buffer = buffer.slice(end + 1);
      events.push(event);
      if (event.ev === 'permission_request') {
        child.stdin.write(JSON.stringify({ op: 'permission', id: event.id,
          allow, message: 'fixture denied' }) + '\n');
      }
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.stdin.on('error', () => {}); // Child may finish before a pipe reply flushes.
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    await exit;
  });
  const [code, signal] = await exit;
  assert.equal(signal, null);
  assert.equal(stderr, '');
  let options;
  try { options = JSON.parse(await fs.readFile(capture, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  return { code, events, options, results: events.find(e => e.msg?.type === 'fixture_permissions')?.msg.results };
}

function assertReadOnly(f, resume) {
  assert.equal(f.code, 0);
  assert.equal(f.options.permissionMode, 'dontAsk');
  assert.deepEqual(f.options.tools, readTools);
  assert.equal(Object.hasOwn(f.options, 'allowedTools'), false);
  assert.deepEqual(f.options.settingSources, []);
  assert.equal(f.options.strictMcpConfig, true);
  assert.deepEqual(f.options.mcpServers, {});
  assert.deepEqual(f.options.hooks, {});
  assert.deepEqual(f.options.plugins, []);
  assert.deepEqual(f.options.skills, []);
  assert.deepEqual(f.options.agents, {});
  assert.deepEqual(f.options.settings, {
    disableAllHooks: true, disableBundledSkills: true,
    disableSkillShellExecution: true, disableClaudeAiConnectors: true,
  });
  assert.equal(f.options.resume, resume);
  assert.equal(f.options.model, 'fixture-model');
  assert.equal(f.options.systemPrompt.append, 'fixture rules');
  assert.equal(f.events.some(e => e.ev === 'permission_request'), false,
    'read-only never asks the host to elevate permission');
  for (const { tool, input, result } of f.results) {
    assert.equal(result.behavior, readTools.includes(tool) ? 'allow' : 'deny', tool);
    if (readTools.includes(tool)) assert.deepEqual(result.updatedInput, input);
    else assert.match(result.message, /不能提升權限/);
  }
}

test('readOnly mounts only native read tools despite supplied writable MCP and bridge endpoints',
  { timeout: 10_000 }, async t => assertReadOnly(await runFixture(t)));

test('readOnly resume keeps the same closed tool/settings surface',
  { timeout: 10_000 }, async t => {
    const resume = 'synthetic-previous-writable-session';
    assertReadOnly(await runFixture(t, { resume }), resume);
  });

test('readOnly without mcp-config remains strict and bridge-free',
  { timeout: 10_000 }, async t => assertReadOnly(await runFixture(t, { mcpConfig: null })));

for (const mode of ['default', 'acceptEdits', 'bypassPermissions']) {
  test(`${mode} preserves its existing SDK options, MCP wiring and host approval callback`,
    { timeout: 10_000 }, async t => {
      const f = await runFixture(t, { mode, tools: ['Bash', 'mcp__writable__write'] });
      assert.equal(f.code, 0);
      assert.equal(f.options.permissionMode, mode);
      assert.deepEqual(f.options.settingSources, ['user', 'project']);
      assert.equal(f.options.strictMcpConfig, true);
      assert.deepEqual(Object.keys(f.options.mcpServers).sort(), ['tatwo2_browser', 'tatwo2_os', 'writable']);
      assert.equal(f.options.mcpServers.writable.command, writableMCP.servers.writable.command);
      for (const server of Object.values(f.options.mcpServers)) {
        assert.equal(server.env.TATWO2_THREAD_ID, writableMCP.threadID);
      }
      assert.equal(f.options.mcpServers.tatwo2_os.env.TATWO2_OS_SOCKET, '/fixture/no-os.sock');
      assert.equal(f.options.mcpServers.tatwo2_browser.env.TATWO2_BROWSER_SOCKET, '/fixture/no-browser.sock');
      for (const name of ['tools', 'allowedTools', 'hooks', 'plugins', 'skills', 'agents', 'settings']) {
        assert.equal(Object.hasOwn(f.options, name), false, `${mode}: no new normal override ${name}`);
      }
      assert.equal(f.events.filter(e => e.ev === 'permission_request').length, 2);
      for (const { input, result } of f.results) assert.deepEqual(result, { behavior: 'allow', updatedInput: input });
    });
}

test('implicit default without mcp-config preserves normal bridges and denied host reply',
  { timeout: 10_000 }, async t => {
    const f = await runFixture(t, { mode: null, mcpConfig: null, tools: ['Edit'], allow: false });
    assert.equal(f.code, 0);
    assert.equal(f.options.permissionMode, 'default');
    assert.equal(Object.hasOwn(f.options, 'strictMcpConfig'), false);
    assert.deepEqual(Object.keys(f.options.mcpServers).sort(), ['tatwo2_browser', 'tatwo2_os']);
    assert.deepEqual(f.results[0].result, { behavior: 'deny', message: 'fixture denied' });
  });

test('unknown permission mode is rejected before SDK query',
  { timeout: 10_000 }, async t => {
    const f = await runFixture(t, { mode: 'readMostly' });
    assert.equal(f.code, 1);
    assert.equal(f.options, undefined);
    assert.equal(f.results, undefined);
    assert.ok(f.events.some(e => e.ev === 'error' && /unknown permission mode readMostly/.test(e.message)));
  });
