// Transport-only test: fake app socket, real MCP stdio server; no engine/LLM calls.
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import path from 'node:path';

const root = process.env.TATWO2_CALLER_TRANSPORT_ROOT;
assert.ok(root, 'TATWO2_CALLER_TRANSPORT_ROOT must be an existing isolated directory');
const socketPath = path.join(root, 'caller.sock');
const calls = [];
const server = net.createServer({ allowHalfOpen: true }, socket => {
  let buffer = '';
  socket.on('data', chunk => { buffer += chunk; });
  socket.on('end', () => {
    const request = JSON.parse(buffer.trim());
    calls.push(request);
    socket.end(JSON.stringify({ id: request.id, ok: true, result: request.params }) + '\n');
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
const timer = setTimeout(() => { console.error('CALLER-MCP FAIL timeout'); process.exit(1); }, 15000);
try {
  for (const bound of [true, false]) {
    const env = { ...process.env, TATWO2_OS_SOCKET: socketPath };
    delete env.TATWO2_THREAD_ID;
    if (bound) env.TATWO2_THREAD_ID = '00000000-0000-0000-0000-00000000000A';
    const child = spawn(process.execPath, [new URL('server.mjs', import.meta.url).pathname], { env, stdio: ['pipe', 'pipe', 'inherit'] });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let id = 0;
    async function rpc(method, params = {}) {
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) + '\n');
      return JSON.parse((await lines.next()).value);
    }
    const list = await rpc('tools/list');
    assert.ok(list.result.tools.some(t => t.name === 'whoami'));
    assert.ok(list.result.tools.find(t => t.name === 'run_background').inputSchema.properties.requestKey);
    for (const tool of list.result.tools) {
      const countBefore = calls.length;
      const reply = await rpc('tools/call', { name: tool.name, arguments: { callerThreadID: 'spoofed' } });
      // These stricter lanes reject supplied identity instead of stripping it.
      if (tool.name.startsWith('computer_') || tool.name === 'os_binding_status') {
        assert.equal(reply.result.isError, true);
        assert.equal(calls.length, countBefore);
        continue;
      }
      assert.ok(!reply.result.isError);
      const last = calls.at(-1);
      assert.equal(last.params.callerThreadID, bound ? env.TATWO2_THREAD_ID : undefined);
      if (tool.name.startsWith('bot_')) assert.equal(last.params._threadID, bound ? env.TATWO2_THREAD_ID : undefined);
    }
    const exited = new Promise(resolve => child.once('exit', resolve));
    child.stdin.end();
    assert.equal(await exited, 0);
    console.log(`CALLER-MCP PASS ${bound ? 'bound' : 'unbound'} all_tools=${list.result.tools.length} spoof_ignored=true`);
  }
} finally {
  clearTimeout(timer);
  await new Promise(resolve => server.close(resolve));
}
console.log('CALLER-MCP PASS');
