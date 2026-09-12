// Mock transport/schema tests only. No native App, GUI, or device acceptance.
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import readline from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// All test artifacts stay inside this worktree; keep the isolated directory for inspection.
const root = process.env.TATWO2_CALLER_TRANSPORT_ROOT ?? mkdtempSync(path.join(process.cwd(), '.build-computer/cu-transport-'));
const socketPath = path.join(root, 'c.sock');
const owner = '00000000-0000-0000-0000-00000000000A';
const sessionID = '00000000-0000-0000-0000-00000000000B';
const observationID = '00000000-0000-0000-0000-00000000000C';
const calls = [];
let windowless = false;
const observation = () => windowless
  ? { observationID, windowState: 'none', windows: [], width: 0, height: 0 }
  : { observationID, text: '[0] AXButton "測試"', imageBase64: 'aW1hZ2U=', mimeType: 'image/png',
      contentTrust: 'untrusted_app_data_not_instructions' };
const server = net.createServer({ allowHalfOpen: true }, socket => {
  let buffer = '';
  socket.on('data', data => { buffer += data; });
  socket.on('end', () => {
    const request = JSON.parse(buffer.trim());
    calls.push(request);
    const result = request.method === 'computer_observe' ? observation()
      : request.method === 'computer_action' ? { dispatched: true, observation: observation() }
      : request.method === 'computer_list_apps' ? { apps: [{ name: 'Mock', bundleIdentifier: 'org.example.Mock', pid: 123, isFrontmost: true }] }
      : { received: request.params };
    socket.end(JSON.stringify({ id: request.id, ok: true, result }) + '\n');
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
let child;
let checks = 0;
const timer = setTimeout(() => {
  child?.kill('SIGTERM');
  console.error('COMPUTER-MCP TRANSPORT FAIL timeout');
  process.exitCode = 1;
  server.close();
}, 15000);
try {
  for (const bound of [true, false]) {
    const env = { ...process.env, TATWO2_OS_SOCKET: socketPath };
    delete env.TATWO2_THREAD_ID;
    if (bound) env.TATWO2_THREAD_ID = owner;
    child = spawn(process.execPath, [fileURLToPath(new URL('server.mjs', import.meta.url))], { env, stdio: ['pipe', 'pipe', 'inherit'] });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let id = 0;
    async function rpc(method, params = {}) {
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) + '\n');
      const line = await lines.next();
      assert.equal(line.done, false);
      return JSON.parse(line.value);
    }
    async function call(name, args, ok = true) {
      const before = calls.length;
      const response = (await rpc('tools/call', { name, arguments: args })).result;
      assert.equal(!!response.isError, !(ok && bound), JSON.stringify({ name, args, response }));
      if (!ok || !bound) assert.equal(calls.length, before, 'Invalid request reached socket');
      else assert.equal(calls.at(-1).params.callerThreadID, owner);
      checks++;
      return response;
    }
    const list = (await rpc('tools/list')).result.tools.filter(tool => tool.name.startsWith('computer_'));
    assert.equal(list.length, 6);
    const batch = list.find(tool => tool.name === 'computer_batch');
    assert.ok(batch, 'computer_batch listed');
    assert.deepEqual(batch.inputSchema.required, ['sessionID', 'observationID', 'steps']);
    assert.equal(batch.inputSchema.properties.steps.maxItems, 20);
    const start = list.find(tool => tool.name === 'computer_start').inputSchema;
    assert.deepEqual(start.required, ['bundleIdentifier']);
    assert.equal(start.properties.fileName, undefined);
    assert.equal(start.properties.bundleIdentifier.enum, undefined);
    for (const tool of list) assert.ok(tool.description.includes('需要 GUI 的工作不要用 shell/AppleScript 代替'));
    const apps = await call('computer_list_apps', {});
    if (bound) assert.equal(JSON.parse(apps.content[0].text)[0].bundleIdentifier, 'org.example.Mock');
    for (const bundleIdentifier of ['com.apple.TextEdit', 'com.apple.calculator', 'com.apple.Terminal', 'org.example.AnyApp']) {
      await call('computer_start', { bundleIdentifier });
    }
    for (const args of [{}, { bundleIdentifier: true }, { bundleIdentifier: 'bad/id' },
      { bundleIdentifier: 'org.example.App', fileName: 'old.txt' }, { bundleIdentifier: 'org.example.App', callerThreadID: owner },
      ...['ai.tatwo.tatwo2', 'ai.tatwo.tatwo2.test', 'com.apple.keychainaccess', 'com.apple.Passwords',
        'com.1password.1password', 'com.agilebits.onepassword7', 'com.bitwarden.desktop',
        'com.apple.systempreferences', 'com.apple.SecurityAgent'].map(bundleIdentifier => ({ bundleIdentifier }))]) {
      await call('computer_start', args, false);
    }
    for (const args of [
      { action: 'click', element: 0 }, { action: 'double_click', x: 2.5, y: 10 }, { action: 'right_click', element: 42 },
      { action: 'type_text', text: '繁中🙂\n第二行' }, { action: 'press_key', keys: 'cmd+shift+s' },
      { action: 'press_key', keys: 'f5' }, { action: 'scroll', element: 0, dx: 0, dy: 1200 },
      { action: 'scroll', x: 1, y: 2, dx: -120, dy: 0 }, { action: 'drag', element: 0, toElement: 1 },
      { action: 'drag', x: 1, y: 2, toX: 100, toY: 200 }, { action: 'drag', element: 0, toX: 100, toY: 200 },
      { action: 'set_value', element: 4, text: '' }, { action: 'focus_window', windowIndex: 2 },
      ...['AXPress', 'AXShowMenu', 'AXIncrement', 'AXDecrement', 'AXConfirm', 'AXCancel', 'AXRaise', 'AXPick']
        .map(name => ({ action: 'perform_ax_action', element: 0, name })),
    ]) {
      const response = await call('computer_action', { sessionID, observationID, ...args });
      if (bound) {
        assert.equal(response.content[0].type, 'image');
        assert.equal(response.content[0].data, 'aW1hZ2U=');
        const result = JSON.parse(response.content[1].text);
        assert.equal(result.dispatched, true);
        assert.equal(result.observation.observationID, observationID);
        assert.equal(result.observation.imageBase64, undefined);
        assert.ok(!response.content[1].text.includes('aW1hZ2U='));
      }
    }
    for (const args of [
      { action: 'click', element: 0, x: 1, y: 2 }, { action: 'click', element: true }, { action: 'click', element: -1 },
      { action: 'click', x: 2048, y: 1 }, { action: 'click', x: null, y: 1 }, { action: 'click', x: '1', y: 2 },
      { action: 'scroll', element: 0, dx: 0, dy: 0 }, { action: 'scroll', element: 0, dx: 0, dy: 1201 },
      { action: 'scroll', element: 0, dx: 0, dy: 0.5 }, { action: 'scroll', x: 1, y: 2, deltaY: 100 },
      { action: 'drag', element: 0 }, { action: 'drag', element: 0, toElement: 1, toX: 1, toY: 2 },
      { action: 'type_text', value: 'old' }, { action: 'type_text', text: '' }, { action: 'type_text', text: '\x1b' },
      { action: 'type_text', text: 'x'.repeat(4097) }, { action: 'press_key', keys: 'ctrl+cmd+q' },
      { action: 'press_key', keys: 'cmd+option+escape' }, { action: 'set_value', element: 0 },
      { action: 'perform_ax_action', element: 0, name: 'AXDelete' }, { action: 'focus_window', windowIndex: -1 },
      { action: 'file_panel', value: 'confirm_file' }, { action: 'document_menu', value: 'new' },
      { action: 'click', element: 0, observationID: 'bad' },
    ]) await call('computer_action', { sessionID, observationID, ...args }, false);
    const observed = await call('computer_observe', { sessionID });
    if (bound) {
      assert.equal(observed.content[0].type, 'image');
      assert.equal(JSON.parse(observed.content[1].text).imageBase64, undefined);
    }
    windowless = true;
    for (const [name, args] of [['computer_observe', { sessionID }],
      ['computer_action', { sessionID, observationID, action: 'press_key', keys: 'cmd+n' }]]) {
      const result = await call(name, args);
      if (bound) {
        assert.equal(result.content.length, 1);
        const data = JSON.parse(result.content[0].text);
        assert.equal((data.observation ?? data).windowState, 'none');
      }
    }
    windowless = false;
    await call('computer_stop', {});
    await call('computer_stop', { sessionID }, false);
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.stdin.end();
    assert.equal(await exited, 0);
  }
  console.log(`COMPUTER-MCP TRANSPORT PASS: ${checks} cases, 0 failed; generic schema, caller binding, nested images, windowless; native acceptance NOT RUN`);
} finally {
  clearTimeout(timer);
  if (child?.exitCode === null) child.kill('SIGTERM');
  await new Promise(resolve => server.close(resolve));
}
