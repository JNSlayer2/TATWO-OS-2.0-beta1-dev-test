import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('real MCP stdio forwards read selectors and explicit submit without leaking extra snapshot fields', async t => {
  const root = fs.mkdtempSync(path.join(repo, 'output/lightweight-repair/mcpmeta.'));
  const socketPath = path.join(root, 'b.sock');
  const requests = [];
  let reply = {};
  const server = net.createServer(socket => {
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => { buffer += chunk; });
    socket.on('end', () => {
      const request = JSON.parse(buffer);
      requests.push(request);
      socket.end(JSON.stringify({ id: request.id, ok: true, result: reply }) + '\n');
    });
  });
  server.listen(socketPath);
  await once(server, 'listening');
  const child = spawn(process.execPath, ['Engines/browser-mcp/server.mjs'], {
    cwd: repo, env: { ...process.env, TATWO2_BROWSER_SOCKET: socketPath },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stderr = '';
  child.stderr.on('data', chunk => { stderr += chunk; });
  const pending = new Map();
  const lines = readline.createInterface({ input: child.stdout });
  lines.on('line', line => {
    const response = JSON.parse(line);
    pending.get(response.id)?.(response);
    pending.delete(response.id);
  });
  let nextID = 1;
  async function rpc(method, params) {
    const id = nextID++;
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`MCP response timeout: ${method}; ${stderr}`)), 5000);
      pending.set(id, response => { clearTimeout(timer); resolve(response); });
    });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    return result;
  }
  t.after(async () => {
    child.stdin.end();
    if (child.exitCode === null) await once(child, 'exit');
    lines.close();
    await new Promise(resolve => server.close(resolve));
  });
  const catalog = await rpc('tools/list');
  const typeTool = catalog.result.tools.find(tool => tool.name === 'browser_type');
  assert.deepEqual(typeTool.inputSchema.properties.submit, { type: 'boolean', default: false });
  assert.equal(typeTool.inputSchema.additionalProperties, false);
  assert.match(catalog.result.tools.find(tool => tool.name === 'browser_read').description, /untrusted/);
  reply = {
    title: 'Fixture form', url: 'https://example.com/', text: 'Public text',
    elements: [
      { selector: 'cef-11', kind: 'text', label: 'Name', value: 'SECRET_VALUE', rect: { x: 1 } },
      { selector: 'cef-12', kind: 'password', label: 'Password', sensitive: true },
      { selector: 'cef-20', kind: 'button', label: '"\nSign in', disabled: true },
    ],
    cookies: 'SECRET_COOKIE',
    truncated: { text: true, elements: false, snapshot: true },
  };
  const read = await rpc('tools/call', { name: 'browser_read', arguments: { maxChars: 1200 } });
  const text = read.result.content[0].text;
  assert.match(text, /Public text/);
  assert.match(text, /"selector":"cef-11"/);
  assert.match(text, /"sensitive":true/);
  assert.match(text, /"disabled":true/);
  assert.match(text, /\\nSign in/);
  assert.match(text, /\[Truncated: text, snapshot\]/);
  assert.doesNotMatch(text, /SECRET|rect/);
  assert.deepEqual(requests.at(-1).params, { maxChars: 1200 });
  const input = '繁體中文 🐱 "); doNotExecute(); //';
  reply = { typed: true, characters: input.length };
  await rpc('tools/call', { name: 'browser_type', arguments: { selector: 'cef-11', text: input, submit: true } });
  assert.deepEqual(requests.at(-1).params, { selector: 'cef-11', text: input, submit: true });
  await rpc('tools/call', { name: 'browser_type', arguments: { selector: 'cef-11', text: input } });
  assert.equal(Object.hasOwn(requests.at(-1).params, 'submit'), false);
  reply = { title: 'Legacy', url: 'https://example.com/', text: 'Plain text' };
  const legacy = await rpc('tools/call', { name: 'browser_read', arguments: {} });
  assert.equal(legacy.result.content[0].text, 'Title: Legacy\nURL: https://example.com/\nPlain text');
  const count = requests.length;
  const unknown = await rpc('tools/call', { name: 'browser_exec_arbitrary', arguments: {} });
  assert.equal(unknown.result.isError, true);
  assert.equal(requests.length, count);
});
