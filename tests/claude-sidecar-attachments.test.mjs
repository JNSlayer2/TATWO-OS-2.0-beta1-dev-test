import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
test('Claude attachment-only request contains an image, not an empty text block', { timeout: 10_000 }, async () => {
  const root = await fs.mkdtemp(path.join(repo, 'output/lightweight-repair/claude-attachments.'));
  const sdk = path.join(root, 'node_modules/@anthropic-ai/claude-agent-sdk');
  await fs.mkdir(sdk, { recursive: true });
  await fs.writeFile(path.join(sdk, 'package.json'), JSON.stringify({ type: 'module', exports: './index.mjs' }));
  await fs.writeFile(path.join(sdk, 'index.mjs'), `
export function query({ prompt }) {
  return (async function*() {
    for await (const message of prompt) {
      yield { type: 'fixture_input', message };
    }
  })();
}
`);
  // Byte-for-byte production sidecar; only its SDK is an inert input recorder.
  const sidecar = path.join(root, 'sidecar.mjs');
  await fs.copyFile(path.join(repo, 'Engines/claude-sidecar/sidecar.mjs'), sidecar);
  const image = path.join(root, '圖片.png');
  const bytes = Buffer.from('fixture image bytes');
  await fs.writeFile(image, bytes);
  const child = spawn(process.execPath, [sidecar, '--cwd', root], {
    env: { HOME: root, PATH: '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '', buffer = '', timer;
  const messages = [];
  const ready = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.stdout.on('data', chunk => {
      stdout += chunk;
      buffer += chunk;
      while (buffer.includes('\n')) {
        const end = buffer.indexOf('\n');
        const event = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        if (event.msg?.type === 'fixture_input') messages.push(event.msg.message);
        if (messages.length === 3) resolve();
      }
    });
    timer = setTimeout(() => reject(new Error(stdout + stderr)), 5000);
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  try {
    child.stdin.write(JSON.stringify({ op: 'send', uuid: 'one', text: '', attachments: [image] }) + '\n');
    child.stdin.write(JSON.stringify({ op: 'send', uuid: 'two', text: '看這張', attachments: [image] }) + '\n');
    child.stdin.write(JSON.stringify({ op: 'send', uuid: 'three', text: '', attachments: [path.join(root, 'missing.png')] }) + '\n');
    await ready;
    assert.deepEqual(messages[0].message.content, [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: bytes.toString('base64') } },
    ]);
    assert.equal(messages[1].message.content[1].text, '看這張');
    assert.match(messages[2].message.content[0].text, /附件讀取失敗/);
    assert.equal(messages[0].uuid, 'one');
    const ended = once(child, 'exit');
    child.stdin.end();
    const [code] = await ended;
    assert.equal(code, 0, stderr);
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  }
});
