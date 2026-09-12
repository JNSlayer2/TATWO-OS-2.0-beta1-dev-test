import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import readline from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

test('iPad MCP caller binding, image response and consent error propagation', { timeout: 15_000 }, async () => {
  const output = path.join(root, 'output', 'ipad-use-tests');
  mkdirSync(output, { recursive: true });
  const scratch = mkdtempSync(path.join(output, 'mcp-'));
  const socketPath = path.join(scratch, 'os.sock');
  const owner = '00000000-0000-0000-0000-000000000001';
  const calls = [];
  const sockets = new Set();
  const server = net.createServer({ allowHalfOpen: true }, socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    let buffer = '';
    socket.on('data', chunk => { buffer += chunk; });
    socket.on('end', () => {
      const request = JSON.parse(buffer);
      calls.push(request);
      const response = request.method === 'ipad_touch'
        ? { ok: false, error: 'ipad_ui_consent_required_for_this_thread' }
        : { ok: true, result: request.method === 'ipad_screenshot'
          ? { imageBase64: 'ZmFrZQ==', mimeType: 'image/png', window: { width: 820, height: 1180 } }
          : { authorizedForCaller: false } };
      socket.end(`${JSON.stringify({ id: request.id, ...response })}\n`);
    });
  });
  let child;
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
    child = spawn(process.execPath, [path.join(root, 'Engines/os-mcp/server.mjs')], {
      env: { ...process.env, TATWO2_OS_SOCKET: socketPath, TATWO2_THREAD_ID: owner },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let sequence = 0;
    async function request(method, params = {}) {
      child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: ++sequence, method, params })}\n`);
      return JSON.parse((await lines.next()).value);
    }
    const listing = await request('tools/list');
    const tools = listing.result.tools.filter(tool => tool.name.startsWith('ipad_'));
    assert.deepEqual(tools.map(tool => tool.name), ['ipad_prepare', 'ipad_status', 'ipad_screenshot', 'ipad_open_app', 'ipad_touch', 'ipad_stop']);
    assert.equal(tools.find(tool => tool.name === 'ipad_touch').inputSchema.properties.points.maxItems, 2);
    await request('tools/call', { name: 'ipad_prepare', arguments: { callerThreadID: 'spoofed' } });
    assert.equal(calls.at(-1).method, 'ipad_prepare');
    assert.equal(calls.at(-1).params.callerThreadID, owner);
    await request('tools/call', { name: 'ipad_status', arguments: { callerThreadID: 'spoofed' } });
    assert.equal(calls.at(-1).params.callerThreadID, owner);
    const screenshot = await request('tools/call', { name: 'ipad_screenshot', arguments: {} });
    assert.deepEqual(screenshot.result.content[0], { type: 'image', data: 'ZmFrZQ==', mimeType: 'image/png' });
    assert.equal(JSON.parse(screenshot.result.content[1].text).window.width, 820);
    await request('tools/call', { name: 'ipad_open_app', arguments: { bundleIdentifier: 'com.apple.mobilesafari', callerThreadID: 'spoofed' } });
    assert.equal(calls.at(-1).method, 'ipad_open_app');
    assert.equal(calls.at(-1).params.bundleIdentifier, 'com.apple.mobilesafari');
    assert.equal(calls.at(-1).params.callerThreadID, owner);
    const rejected = await request('tools/call', { name: 'ipad_touch', arguments: { points: [{ x: 1, y: 2 }], durationMs: 100 } });
    assert.equal(rejected.result.isError, true);
    assert.match(rejected.result.content[0].text, /ipad_ui_consent_required_for_this_thread/);
    const forbidden = await request('tools/call', { name: 'ipad_authorize', arguments: {} });
    assert.equal(forbidden.result.isError, true);
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.stdin.end();
    assert.equal(await exited, 0);
  } finally {
    child?.kill();
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    rmSync(scratch, { recursive: true, force: true });
  }
});
