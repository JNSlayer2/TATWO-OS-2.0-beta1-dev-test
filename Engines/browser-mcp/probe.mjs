#!/usr/bin/env node
// TATWO2_BROWSERTEST node 直連 probe；不經 MCP stdio。
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
const socketPath = process.env.TATWO2_BROWSER_SOCKET || path.join(os.homedir(), 'Library', 'Application Support', 'tatwo2', 'live', 'browser-v2.sock');
let id = 1;
function call(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let data = '';
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.end(JSON.stringify({ id: id++, method, params }) + '\n'));
    socket.on('data', chunk => { data += chunk; });
    socket.on('error', reject);
    socket.on('close', () => {
      try {
        const reply = JSON.parse(data.trim());
        if (!reply.ok) reject(new Error(reply.error)); else resolve(reply.result);
      } catch (error) { reject(error); }
    });
  });
}
try {
  console.log('BROWSERTEST open=' + JSON.stringify(await call('browser_open', { url: 'https://example.com' })));
  const read = await call('browser_read', { maxChars: 8000 });
  console.log('BROWSERTEST read=' + JSON.stringify(read));
  if (!String(read.text || '').includes('Example Domain')) process.exitCode = 1;
  else console.log('BROWSERTEST PASS Example Domain');
} catch (error) {
  console.error('BROWSERTEST FAIL ' + String(error?.stack || error));
  process.exitCode = 1;
}
