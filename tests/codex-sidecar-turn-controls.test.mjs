import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

test('resident Codex sidecar binds model, effort and speed to each queued turn', { timeout: 20_000 }, async () => {
  const output = path.join(root, 'output', 'lightweight-repair');
  await fs.mkdir(output, { recursive: true });
  const fixture = await fs.mkdtemp(path.join(output, 'turn-controls-'));
  const bin = path.join(fixture, 'bin');
  const home = path.join(fixture, 'home');
  await fs.mkdir(bin);
  await fs.mkdir(home);
  const capture = path.join(fixture, 'requests.jsonl');
  const executable = path.join(bin, 'codex');
  await fs.writeFile(executable, `#!${process.execPath}
const fs = require('node:fs');
if (process.argv.includes('--version')) { console.log('codex-fixture 1'); process.exit(0); }
const rl = require('node:readline').createInterface({ input: process.stdin });
let turn = 0;
const send = value => process.stdout.write(JSON.stringify(value)+'\\n');
rl.on('line', line => {
  const request = JSON.parse(line);
  fs.appendFileSync(process.env.CONTROL_CAPTURE, line+'\\n');
  if (request.method === 'initialize') send({id:request.id,result:{}});
  if (request.method === 'thread/start') send({id:request.id,result:{thread:{id:'fixture-thread',model:'native-default'}}});
  if (request.method === 'turn/start') {
    if (request.params.effort === 'rejected-for-fixture') {
      send({id:request.id,error:{code:-32602,message:'unsupported effort fixture'}});
      return;
    }
    const id = 'fixture-turn-'+(++turn);
    send({id:request.id,result:{turn:{id}}});
    send({method:'thread/settings/updated',params:{threadId:'fixture-thread',threadSettings:{
      model:request.params.model,effort:request.params.effort,serviceTier:request.params.serviceTier
    }}});
    send({method:'turn/started',params:{turn:{id}}});
    setTimeout(() => {
      send({method:'item/agentMessage/delta',params:{delta:'fixture response'}});
      send({method:'turn/completed',params:{turn:{id,status:'completed'}}});
    },25);
  }
});
rl.on('close',()=>process.exit(0));
`, { mode: 0o700 });
  // Do not inherit real auth, MCP configuration or provider environment.
  const child = spawn(process.execPath, [path.join(root, 'Engines/codex-sidecar/sidecar.mjs'),
    '--cwd', fixture, '--model', 'gpt-5.6-sol'], {
    env: {
      PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: home, CODEX_HOME: path.join(home, '.codex'),
      TATWO2_CODEX_SOURCE_HOME: path.join(home, 'empty-source'),
      CONTROL_CAPTURE: capture,
    }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  let completed = 0;
  let failures = 0;
  child.stderr.on('data', chunk => { stderr += chunk; });
  let buffer = '';
  const done = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => {
      if (completed !== 4 || failures !== 1) reject(new Error(`early exit ${code}\n${stdout}\n${stderr}`));
    });
    child.stdout.on('data', chunk => {
      stdout += chunk;
      buffer += chunk;
      while (buffer.includes('\n')) {
        const end = buffer.indexOf('\n');
        const event = JSON.parse(buffer.slice(0, end));
        buffer = buffer.slice(end + 1);
        if (event.ev === 'sdk' && event.msg?.type === 'result') completed++;
        if (event.ev === 'error') failures++;
        if (completed === 4 && failures === 1) resolve();
      }
    });
  });
  let timeout;
  try {
    for (const command of [
      { op: 'send', text: 'first', uuid: 'one', model: 'gpt-6-astra', effort: 'medium', serviceTier: 'priority' },
      { op: 'send', text: 'second', uuid: 'two', model: 'gpt-5.6-sol', effort: 'high', serviceTier: 'default',
        attachments: [path.join(fixture, '中 文.png'), path.join(fixture, 'notes.txt')] },
      { op: 'send', text: '', uuid: 'three', model: 'gpt-6-astra', effort: 'low', serviceTier: 'priority',
        attachments: [path.join(fixture, 'image-only.jpg')] },
      { op: 'send', text: 'rejected', uuid: 'four', model: 'gpt-6-astra', effort: 'rejected-for-fixture' },
      { op: 'send', text: 'invalid', uuid: 'bad', effort: 123 },
    ]) child.stdin.write(`${JSON.stringify(command)}\n`);
    await Promise.race([done, new Promise((_, reject) => {
      timeout = setTimeout(() => reject(new Error(`sidecar fixture timeout\n${stdout}\n${stderr}`)), 10_000);
    })]);
    const requests = (await fs.readFile(capture, 'utf8')).trim().split('\n').map(JSON.parse);
    const turns = requests.filter(request => request.method === 'turn/start').map(request => request.params);
    assert.deepEqual(turns.map(({ model, effort, serviceTier, clientUserMessageId }) =>
      ({ model, effort, serviceTier, clientUserMessageId })), [
      { model: 'gpt-6-astra', effort: 'medium', serviceTier: 'priority', clientUserMessageId: 'one' },
      { model: 'gpt-5.6-sol', effort: 'high', serviceTier: 'default', clientUserMessageId: 'two' },
      { model: 'gpt-6-astra', effort: 'low', serviceTier: 'priority', clientUserMessageId: 'three' },
      { model: 'gpt-6-astra', effort: 'rejected-for-fixture', serviceTier: undefined, clientUserMessageId: 'four' },
    ]);
    assert.equal(requests.filter(request => request.method === 'initialize').length, 1);
    assert.deepEqual(turns[1].input, [
      { type: 'text', text: 'second', text_elements: [] },
      { type: 'localImage', path: path.join(fixture, '中 文.png') },
      { type: 'text', text: `附件檔案：${JSON.stringify(path.join(fixture, 'notes.txt'))}`, text_elements: [] },
    ]);
    assert.deepEqual(turns[2].input, [
      { type: 'localImage', path: path.join(fixture, 'image-only.jpg') },
    ]);
    assert.equal(requests.filter(request => request.method === 'thread/start').length, 1);
    assert.equal(requests.find(request => request.method === 'thread/start').params.model, 'gpt-5.6-sol');
    const nativeModels = stdout.trim().split('\n').map(JSON.parse)
      .filter(event => event.ev === 'sdk' && event.msg?.subtype === 'model' && event.msg.model)
      .map(event => event.msg.model);
    assert.deepEqual(nativeModels, ['gpt-6-astra', 'gpt-5.6-sol', 'gpt-6-astra']);
    const terminalErrors = stdout.trim().split('\n').map(JSON.parse)
      .filter(event => event.ev === 'sdk' && event.msg?.type === 'result' && event.msg.is_error);
    assert.equal(terminalErrors.length, 1);
    assert.match(terminalErrors[0].msg.result, /unsupported effort fixture/);
    assert.match(stdout, /must be non-empty strings/);
    const exited = once(child, 'exit');
    child.stdin.end();
    const [code] = await exited;
    assert.equal(code, 0, stderr);
  } finally {
    clearTimeout(timeout);
    // Fixture artifacts stay in ignored output for inspection. Only our child
    // is stopped on failure; no user files or engine processes are cleaned.
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
  }
});
