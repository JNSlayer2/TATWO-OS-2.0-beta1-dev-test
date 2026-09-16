import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomBytes } from 'node:crypto';
import { deflateSync } from 'node:zlib';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));

// A valid, non-private 1280x720 RGB noise screenshot (~2.7 MB), not a tiny argv fixture.
function screenshot() {
  const chunk = (name, data) => {
    const body = Buffer.concat([Buffer.from(name), data]);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const size = Buffer.alloc(4), checksum = Buffer.alloc(4);
    size.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([size, body, checksum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1280); header.writeUInt32BE(720, 4); header[8] = 8; header[9] = 2;
  const rows = [];
  for (let y = 0; y < 720; y++) rows.push(Buffer.from([0]), randomBytes(1280 * 3));
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'),
    chunk('IHDR', header), chunk('IDAT', deflateSync(Buffer.concat(rows))), chunk('IEND', Buffer.alloc(0))]);
}

async function fixture(t, { hold = false, missingBinary = false } = {}) {
  const output = testScratch('grok-sidecar-attachments-');
  await fs.mkdir(output, { recursive: true });
  const root = await fs.mkdtemp(path.join(output, 'grok-attachments.'));
  const tmp = path.join(root, 'tmp');
  await fs.mkdir(tmp);
  const executable = path.join(root, 'fake-grok.cjs');
  const capture = path.join(root, 'capture.jsonl');
  await fs.writeFile(executable, `#!${process.execPath}
const fs = require('node:fs'), path = require('node:path');
const args = process.argv.slice(2);
const at = args.indexOf('--prompt-file');
const file = at < 0 ? null : args[at + 1];
// Delay reading so the test proves prompt lifetime, not merely argv assembly.
setTimeout(() => {
  fs.appendFileSync(process.env.CAPTURE, JSON.stringify({
    args, file, blocks: file ? JSON.parse(fs.readFileSync(file, 'utf8')) : null,
    fileMode: file ? fs.statSync(file).mode & 511 : null,
    dirMode: file ? fs.statSync(path.dirname(file)).mode & 511 : null,
    isolated: !process.env.ANTHROPIC_API_KEY && !process.env.CLAUDE_HOME,
    home: process.env.HOME
  }) + '\\n');
  if (process.env.HOLD !== '1') {
    console.log(JSON.stringify({type:'text',data:'recorded'}));
    console.log(JSON.stringify({type:'end',sessionId:'fixture-session'}));
  } else {
    const timer = setInterval(() => {}, 1000);
    process.on('SIGINT', () => {
      fs.writeFileSync(process.env.CAPTURE + '.interrupt', String(!file || fs.existsSync(file)));
      clearInterval(timer);
      process.exit(130);
    });
  }
}, 20);
`, { mode: 0o700 });
  const child = spawn(process.execPath, [
    path.join(repo, 'Engines/grok-sidecar/sidecar.mjs'), '--cwd', root,
    '--model', 'fixture-model', '--system-prompt', 'fixture rules',
  ], {
    // No inherited auth, MCP, provider or real home settings.
    env: { HOME: root, TMPDIR: tmp, PATH: '/usr/bin:/bin',
      TATWO2_GROK_HOME: root, TATWO2_GROK_BIN: missingBinary ? path.join(root, 'absent') : executable,
      CAPTURE: capture, HOLD: hold ? '1' : '0',
      ANTHROPIC_API_KEY: 'inert-isolation-marker', CLAUDE_HOME: '/inert/forbidden',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const events = [];
  let buffer = '', stderr = '';
  child.stdout.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n');
      events.push(JSON.parse(buffer.slice(0, end)));
      buffer = buffer.slice(end + 1);
    }
  });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const exit = once(child, 'exit');
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) child.stdin.end();
    await exit;
    assert.equal(stderr, '');
  });
  const send = command => child.stdin.write(JSON.stringify(command) + '\n');
  const wait = async predicate => {
    const deadline = Date.now() + 5000;
    while (!await predicate()) {
      if (Date.now() > deadline) throw new Error(`fixture timed out: ${JSON.stringify(events)} ${stderr}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  };
  const results = () => events.filter(event => event.msg?.type === 'result');
  const records = async () => {
    try { return (await fs.readFile(capture, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  };
  const turn = async command => {
    const count = results().length;
    send({ op: 'send', uuid: `turn-${count}`, ...command });
    await wait(() => results().length === count + 1);
    // Cleanup runs synchronously after the result event; observe the actual filesystem.
    await wait(async () => (await fs.readdir(tmp)).length === 0);
    return results().at(-1).msg;
  };
  return { root, tmp, capture, turn, send, wait, records, events, results, exit };
}

test('text-only remains -p; native model/rules and session resume are preserved', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  assert.equal((await f.turn({ text: '你好' })).is_error, false);
  await f.turn({ text: '繼續' });
  const [first, second] = await f.records();
  assert.deepEqual(first.args.slice(0, 2), ['-p', '你好']);
  assert.equal(first.args[first.args.indexOf('-m') + 1], 'fixture-model');
  assert.equal(first.args[first.args.indexOf('--rules') + 1], 'fixture rules');
  assert.equal(second.args[second.args.indexOf('--resume') + 1], 'fixture-session');
  assert.equal(first.isolated, true);
  assert.equal(first.home, f.root);
});

test('image-only uses a private file of native content blocks, never empty -p', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const image = path.join(f.root, '中 文.PNG'), bytes = Buffer.from('fixture bytes');
  await fs.writeFile(image, bytes);
  await f.turn({ text: '', attachments: [image] });
  const [record] = await f.records();
  assert.deepEqual(record.blocks, [{ type: 'image', data: bytes.toString('base64'), mimeType: 'image/png' }]);
  assert.equal(record.args.includes('-p'), false);
  assert.equal(record.fileMode, 0o600); assert.equal(record.dirMode, 0o700);
  assert.deepEqual(await fs.readFile(image), bytes);
  await assert.rejects(fs.stat(record.file), { code: 'ENOENT' });
});

test('mixed text, multiple images and quoted document references retain every attachment', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const names = ['一.jpg', '二.gif', '三.webp', '筆記 "引用".txt'];
  for (const name of names) await fs.writeFile(path.join(f.root, name), `fixture:${name}`);
  await f.turn({ text: '比較', attachments: [...names, names[0]] });
  const [record] = await f.records();
  assert.equal(record.blocks.length, 4);
  assert.equal(record.blocks[0].text, `比較\n附件檔案：${JSON.stringify(path.join(f.root, names[3]))}`);
  assert.deepEqual(record.blocks.slice(1).map(block => block.mimeType), ['image/jpeg', 'image/gif', 'image/webp']);
  for (let i = 0; i < 3; i++) assert.equal(Buffer.from(record.blocks[i + 1].data, 'base64').toString(), `fixture:${names[i]}`);
});

test('ordinary files stay explicit file references rather than fake image blocks', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const file = path.join(f.root, 'notes.md');
  await fs.writeFile(file, 'notes');
  await f.turn({ text: '', attachments: [file] });
  const [record] = await f.records();
  assert.deepEqual(record.args.slice(0, 2), ['-p', `附件檔案：${JSON.stringify(file)}`]);
  assert.equal(record.file, null);
});

test('missing, unreadable, empty, unsupported and invalid attachments reject before spawning', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const denied = path.join(f.root, 'denied.png');
  await fs.writeFile(denied, 'inaccessible', { mode: 0o000 });
  const empty = path.join(f.root, 'empty.png'); await fs.writeFile(empty, '');
  const unsupported = path.join(f.root, 'image.heic'); await fs.writeFile(unsupported, 'bytes');
  for (const attachments of [[path.join(f.root, 'missing.png')], [denied], [empty], [unsupported], [f.root], [''], [null], {}]) {
    const result = await f.turn({ text: 'must not fall back', attachments });
    assert.equal(result.is_error, true);
    assert.match(result.result, /附件無法讀取或圖片格式不支援/);
  }
  assert.deepEqual(await f.records(), []);
  // Failed local assembly must not invent a native session or count as an executed turn.
  await f.turn({ text: 'recovered' });
  const [record] = await f.records();
  assert.equal(record.args.includes('-c'), false);
  assert.equal(record.args.includes('--resume'), false);
});

test('a realistic-size PNG reaches the child intact without base64 argv or retained temp files', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  const bytes = screenshot(), file = path.join(f.root, '1280x720.png');
  assert.ok(bytes.length > 2_500_000);
  await fs.writeFile(file, bytes);
  await f.turn({ text: '看截圖', attachments: [file] });
  const [record] = await f.records();
  assert.ok(Buffer.byteLength(record.args.join('\0')) < 4096);
  assert.deepEqual(Buffer.from(record.blocks[1].data, 'base64'), bytes);
  assert.deepEqual(await fs.readdir(f.tmp), []);
});

test('spawn failure cleans only owned prompt storage and preserves the source image', { timeout: 10_000 }, async t => {
  const f = await fixture(t, { missingBinary: true });
  const file = path.join(f.root, 'input.png'); await fs.writeFile(file, 'fixture');
  assert.equal((await f.turn({ attachments: [file] })).is_error, true);
  assert.equal(await fs.readFile(file, 'utf8'), 'fixture');
  assert.deepEqual(await fs.readdir(f.tmp), []);
});

for (const op of ['interrupt', 'close']) {
  test(`${op} retains the prompt until the native child exits, then cleans it`, { timeout: 10_000 }, async t => {
    const f = await fixture(t, { hold: true });
    const file = path.join(f.root, 'input.png'); await fs.writeFile(file, 'fixture');
    f.send({ op: 'send', text: '', attachments: [file] });
    await f.wait(async () => (await f.records()).length === 1);
    f.send({ op });
    await f.wait(() => f.results().length === 1);
    await f.wait(async () => (await fs.readdir(f.tmp)).length === 0);
    assert.equal(await fs.readFile(f.capture + '.interrupt', 'utf8'), 'true');
    assert.equal(await fs.readFile(file, 'utf8'), 'fixture');
    if (op === 'close') await f.exit;
  });
}
