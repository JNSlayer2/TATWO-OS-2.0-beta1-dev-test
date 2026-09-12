import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

const steers = f => f.requests.filter(r => r.method === 'turn/steer');
const steerResults = f => f.events.filter(e => e.msg?.subtype === 'steer_result').map(e => e.msg);
const steer = (f, uuid, targetTurnUUID = 'work', extra = {}) =>
  f.command({ op: 'steer', uuid, targetTurnUUID, text: '改查這個問題', ...extra });
const goalSnapshot = (status, extra = {}) => ({ threadId: 'thread-fixture', objective: '完成本機測試',
  status, tokensUsed: 80, tokenBudget: null, timeUsedSeconds: 6, createdAt: 1, updatedAt: 2, ...extra });
const goalEvents = f => f.events.filter(e => e.msg?.subtype === 'goal').map(e => e.msg);
const goalRequests = f => f.requests.filter(r => r.method === 'thread/goal/set');

async function fixture(t) {
  const output = path.join(root, 'output/lightweight-repair');
  await fs.mkdir(output, { recursive: true });
  const dir = await fs.mkdtemp(path.join(output, 'cancel-'));
  // UNIX paths have a short platform limit. All artifacts are retained.
  const socketDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tatwo-cancel-'));
  const socketPath = path.join(socketDir, 'native.sock');
  await fs.mkdir(path.join(dir, 'bin'));
  await fs.mkdir(path.join(dir, 'home'));
  await fs.writeFile(path.join(dir, 'bin/codex'),
    `#!${process.execPath}\nrequire(${JSON.stringify(path.join(root, 'tests/fixtures/codex-cancellation-server.cjs'))});\n`,
    { mode: 0o700 });
  const child = spawn(process.execPath, [path.join(root, 'Engines/codex-sidecar/sidecar.mjs'), '--cwd', dir], {
    env: {
      PATH: `${dir}/bin:${path.dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: path.join(dir, 'home'), CODEX_HOME: path.join(dir, 'home/.codex'),
      TATWO2_CODEX_SOURCE_HOME: path.join(dir, 'empty-source'),
      CANCEL_SOCKET: socketPath, CANCEL_CAPTURE: path.join(dir, 'requests.jsonl'),
    }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const events = [];
  const requests = [];
  let stderr = '';
  let control;
  child.stderr.on('data', data => { stderr += data; });
  readline.createInterface({ input: child.stdout }).on('line', line => events.push(JSON.parse(line)));
  t.after(async () => {
    await fs.writeFile(path.join(dir, 'events.json'), JSON.stringify(events, null, 2));
    await fs.writeFile(path.join(dir, 'stderr.log'), stderr);
    control?.destroy();
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, 'exit');
      child.stdin.end();
      await exited;
    }
  });
  async function until(predicate, label) {
    const end = Date.now() + 2500;
    while (Date.now() < end) {
      if (predicate()) return;
      if (child.exitCode !== null) throw new Error(`fixture exit ${child.exitCode}: ${stderr}`);
      await delay(5);
    }
    assert.fail(`${label}\n${JSON.stringify({ requests, events, stderr })}`);
  }
  const deadline = Date.now() + 2500;
  while (!control && Date.now() < deadline) {
    control = await new Promise(resolve => {
      const s = net.createConnection(socketPath);
      s.once('connect', () => resolve(s));
      s.once('error', () => { s.destroy(); resolve(null); });
    });
    if (!control) await delay(10);
  }
  assert.ok(control, 'fixture native peer connects');
  readline.createInterface({ input: control }).on('line', line => requests.push(JSON.parse(line)));
  const command = value => child.stdin.write(JSON.stringify(value) + '\n');
  const native = value => control.write(JSON.stringify(value) + '\n');
  const reply = (request, result = {}) => native({ id: request.id, result });
  const notify = (method, params) => native({ method, params });
  const startRequests = () => requests.filter(r => r.method === 'turn/start');
  const interrupts = () => requests.filter(r => r.method === 'turn/interrupt');
  const results = () => events.filter(e => e.ev === 'sdk' && e.msg.type === 'result');
  async function boot({ deferGoalRead = false } = {}) {
    await until(() => requests.some(r => r.method === 'initialize'), 'initialize');
    reply(requests.find(r => r.method === 'initialize'));
    await until(() => requests.some(r => r.method === 'thread/start'), 'thread/start');
    reply(requests.find(r => r.method === 'thread/start'), { thread: { id: 'thread-fixture' } });
    await until(() => events.some(e => e.msg?.subtype === 'init'), 'init event');
    if (!deferGoalRead) {
      await until(() => requests.some(r => r.method === 'thread/goal/get'), 'initial Goal query');
      reply(requests.find(r => r.method === 'thread/goal/get'), { goal: null });
      await until(() => events.some(e => e.msg?.subtype === 'goal') || goalRequests({ requests }).length > 0,
        'initial Goal read or newer mutation');
    }
  }
  async function barrier() {
    const n = events.filter(e => e.ev === 'mcp_status').length;
    command({ op: 'mcp_status' });
    await until(() => events.filter(e => e.ev === 'mcp_status').length > n, 'command barrier');
  }
  const send = text => command({ op: 'send', text, uuid: text });
  const started = id => notify('turn/started', { threadId: 'thread-fixture', turn: { id } });
  const complete = (id, status = 'completed') =>
    notify('turn/completed', { threadId: 'thread-fixture', turn: { id, status } });
  return { command, native, reply, notify, until, boot, barrier, send, started, complete,
    requests, events, startRequests, interrupts, results };
}

test('preboot stop cancels old activation without RPC before init and preserves explicit later Goal', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.command({ op: 'goal_set', uuid: 'old', status: 'active', objective: 'old' });
  f.command({ op: 'interrupt' });
  f.command({ op: 'goal_set', uuid: 'later', status: 'active', objective: 'later' });
  await f.barrier();
  assert.equal(f.requests.filter(r => r.method?.startsWith('thread/goal/')).length, 0);
  const rejection = f.events.find(e => e.msg?.request_id === 'old');
  assert.equal(rejection.msg.accepted, false);
  assert.equal(rejection.msg.session_id, null, 'App must handle matched preboot rejection');
  await f.boot();
  await f.until(() => goalRequests(f).length === 1, 'later Goal survives deferred stop');
  assert.equal(goalRequests(f)[0].params.objective, 'later');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('active', { objective: 'later' }) });
  await f.until(() => f.events.some(e => e.msg?.request_id === 'later' && e.msg.accepted), 'later accepted');
  assert.equal(goalEvents(f).at(-1).goal.objective, 'later');
  assert.equal(f.startRequests().length, 0);
});

test('unknown boot Goal waits for one read then pauses before interrupting autonomous work', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot({ deferGoalRead: true });
  f.started('auto');
  await f.until(() => f.events.some(e => e.msg?.subtype === 'native_turn_started'), 'autonomous start');
  f.command({ op: 'interrupt' }); await f.barrier();
  assert.equal(f.interrupts().length, 0);
  assert.equal(f.requests.filter(r => r.method === 'thread/goal/get').length, 1);
  f.reply(f.requests.find(r => r.method === 'thread/goal/get'), { goal: goalSnapshot('active') });
  await f.until(() => goalRequests(f).length === 1, 'pause actual Goal');
  assert.equal(goalRequests(f)[0].params.status, 'paused');
  assert.equal(f.interrupts().length, 0, 'pause must be confirmed first');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('paused') });
  await f.until(() => f.interrupts().length === 1, 'interrupt after pause');
});

test('explicit second Stop interrupts a turn even while Goal query is hanging', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot({ deferGoalRead: true });
  f.started('auto');
  await f.until(() => f.events.some(e => e.msg?.subtype === 'native_turn_started'), 'autonomous start');
  f.command({ op: 'interrupt' }); await f.barrier();
  assert.equal(f.interrupts().length, 0);
  f.command({ op: 'interrupt' });
  await f.until(() => f.interrupts().length === 1, 'explicit retry stops actual turn');
  assert.equal(goalEvents(f).length, 0, 'unknown Goal was not fabricated as paused');
  f.reply(f.interrupts()[0]); f.complete('auto', 'interrupted');
  f.reply(f.requests.find(r => r.method === 'thread/goal/get'), { goal: goalSnapshot('active') });
  await f.until(() => goalRequests(f).length === 1, 'Goal is still paused when query recovers');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('paused') });
  await f.until(() => goalEvents(f).at(-1)?.goal?.status === 'paused', 'actual pause confirmed');
  assert.equal(f.interrupts().length, 1);
});

test('Stop after terminal completion still pauses an active native Goal', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('active') });
  f.started('auto'); f.complete('auto');
  await f.until(() => f.results().length === 1, 'turn ended');
  f.command({ op: 'interrupt' });
  await f.until(() => goalRequests(f).length === 1, 'Goal pause after turn end');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('paused') });
  await f.until(() => goalEvents(f).at(-1)?.goal?.status === 'paused', 'paused');
  assert.equal(f.interrupts().length, 0, 'completed turn not revived');
});

test('Goal activation applies native model medium Fast settings before native goal/set', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.command({ op: 'goal_set', uuid: 'configured', objective: 'work', status: 'active',
    model: 'gpt-6-astra', effort: 'medium', serviceTier: 'priority' });
  await f.until(() => f.requests.some(r => r.method === 'thread/settings/update'), 'native settings');
  const settings = f.requests.find(r => r.method === 'thread/settings/update');
  assert.deepEqual(settings.params, { threadId: 'thread-fixture', model: 'gpt-6-astra', effort: 'medium', serviceTier: 'priority' });
  assert.equal(goalRequests(f).length, 0, 'settings must ACK before activation');
  f.reply(settings);
  await f.until(() => goalRequests(f).length === 1, 'activation');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('active') });
  await f.until(() => f.events.some(e => e.msg?.request_id === 'configured' && e.msg.accepted), 'accepted');
  assert.equal(goalEvents(f).at(-1).goal.status, 'active');
  assert.equal(f.startRequests().length, 0, 'no duplicate scheduler');
});

test('rejected native settings cannot activate a Goal using silent defaults', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.command({ op: 'goal_set', uuid: 'bad-settings', status: 'active', model: 'fixture' });
  await f.until(() => f.requests.some(r => r.method === 'thread/settings/update'), 'settings');
  f.native({ id: f.requests.find(r => r.method === 'thread/settings/update').id,
    error: { code: -1, message: 'fixture rejected settings' } });
  await f.until(() => f.events.some(e => e.msg?.request_id === 'bad-settings'), 'explicit rejection');
  assert.equal(f.events.find(e => e.msg?.request_id === 'bad-settings').msg.accepted, false);
  assert.equal(goalRequests(f).length, 0);
  assert.equal(f.startRequests().length, 0);
});

test('Stop during settings cancels old Goal before any activation and preserves explicit later request', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.command({ op: 'goal_set', uuid: 'cancel-settings', status: 'active', model: 'fixture-old' });
  await f.until(() => f.requests.some(r => r.method === 'thread/settings/update'), 'settings awaiting ACK');
  f.command({ op: 'interrupt' }); await f.barrier();
  assert.equal(f.events.find(e => e.msg?.request_id === 'cancel-settings').msg.accepted, false);
  f.reply(f.requests.find(r => r.method === 'thread/settings/update'));
  f.command({ op: 'goal_set', uuid: 'new-goal', status: 'active', objective: 'new' });
  await f.until(() => goalRequests(f).length === 1, 'explicit new Goal');
  assert.equal(goalRequests(f)[0].params.objective, 'new', 'cancelled old activation never submitted');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('active', { objective: 'new' }) });
  await f.until(() => f.events.some(e => e.msg?.request_id === 'new-goal' && e.msg.accepted), 'new Goal accepted');
  assert.equal(f.events.filter(e => e.msg?.request_id === 'cancel-settings').length, 1);
});

test('read started during a Goal mutation cannot suppress the successful mutation snapshot', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.command({ op: 'goal_set', uuid: 'racing-read', status: 'active' });
  await f.until(() => goalRequests(f).length === 1, 'mutation pending');
  f.command({ op: 'goal_get' });
  await f.until(() => f.requests.filter(r => r.method === 'thread/goal/get').length === 2, 'refresh during mutation');
  f.reply(f.requests.filter(r => r.method === 'thread/goal/get')[1], { goal: null });
  await f.until(() => goalEvents(f).length === 2, 'old query result');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('active') });
  await f.until(() => f.events.some(e => e.msg?.request_id === 'racing-read' && e.msg.accepted), 'mutation accepted');
  assert.equal(goalEvents(f).at(-1).goal.status, 'active', 'valid mutation wins over old query');
});

test('malformed Goal mutation replies never acknowledge successful activation', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  const variants = [
    goalSnapshot('active', { tokensUsed: -1 }),
    goalSnapshot('paused'),
    goalSnapshot('active', { threadId: 'other-thread' }),
    { status: 'active' },
  ];
  for (const [i, goal] of variants.entries()) {
    f.command({ op: 'goal_set', uuid: `bad-${i}`, status: 'active' });
    await f.until(() => goalRequests(f).length === i + 1, 'mutation');
    f.reply(goalRequests(f)[i], { goal });
    await f.until(() => f.events.some(e => e.msg?.request_id === `bad-${i}`), 'invalid response rejected');
    assert.equal(f.events.find(e => e.msg?.request_id === `bad-${i}`).msg.accepted, false);
    assert.equal(goalEvents(f).at(-1).goal, null, 'invalid response never becomes a snapshot');
  }
});

test('native Goal query is once per boot and cannot overwrite a newer notification', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot({ deferGoalRead: true });
  await f.until(() => f.requests.some(r => r.method === 'thread/goal/get'), 'initial Goal read');
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('blocked') });
  await f.until(() => goalEvents(f).length === 1, 'Goal notification');
  f.reply(f.requests.find(r => r.method === 'thread/goal/get'), { goal: goalSnapshot('active') });
  await f.barrier();
  assert.equal(goalEvents(f).length, 1);
  assert.equal(goalEvents(f)[0].goal.status, 'blocked');
  f.notify('thread/goal/updated', { threadId: 'other-thread', goal: goalSnapshot('active') });
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('active', { threadId: 'other-thread' }) });
  await f.barrier();
  assert.equal(goalEvents(f).length, 1, 'unrelated Goal snapshots are ignored');
  assert.equal(f.requests.filter(r => r.method === 'thread/goal/get').length, 1, 'no Goal polling');
});

test('unsupported Goal API is unavailable rather than silently treated as no Goal', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot({ deferGoalRead: true });
  await f.until(() => f.requests.some(r => r.method === 'thread/goal/get'), 'Goal read');
  const read = f.requests.find(r => r.method === 'thread/goal/get');
  f.native({ id: read.id, error: { code: -32601, message: 'fixture method unsupported' } });
  await f.until(() => f.events.some(e => e.msg?.subtype === 'goal_unavailable'), 'unavailable event');
  assert.equal(goalEvents(f).length, 0);
  f.send('normal');
  await f.until(() => f.startRequests().length === 1, 'normal conversation still starts');
});

test('Goal command before boot submits once; active acknowledgement does not invent a turn', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.command({ op: 'goal_set', uuid: 'create', objective: '完成本機測試', status: 'active' });
  f.command({ op: 'goal_set', uuid: 'duplicate', status: 'active' });
  await f.boot();
  await f.until(() => goalRequests(f).length === 1, 'one native Goal mutation');
  assert.deepEqual(goalRequests(f)[0].params, { threadId: 'thread-fixture', status: 'active', objective: '完成本機測試' });
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('active') });
  await f.until(() => f.events.some(e => e.msg?.subtype === 'goal_result' && e.msg.request_id === 'create'), 'saved Goal');
  assert.equal(f.startRequests().length, 0, 'native scheduling owns continuation');
  const duplicate = f.events.find(e => e.msg?.subtype === 'goal_result' && e.msg.request_id === 'duplicate');
  assert.equal(duplicate.msg.accepted, false);
  f.started('autonomous');
  await f.until(() => f.events.some(e => e.msg?.subtype === 'native_turn_started'), 'real autonomous turn observed');
  f.notify('item/agentMessage/delta', { turnId: 'autonomous', delta: '原生自主回覆' });
  f.complete('autonomous');
  await f.until(() => f.results().length === 1, 'native completion');
  assert.equal(f.results()[0].msg.client_turn_id, 'native:autonomous');
  assert.equal(f.results()[0].msg.result, '原生自主回覆');
  assert.equal(goalEvents(f).at(-1).goal.status, 'active', 'one turn finishing is not Goal completion');
});

test('autonomous turn before Goal notification and late old start reply retains native identity', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start RPC remains pending');
  f.started('original');
  f.complete('original');
  f.started('next-native');
  await f.until(() => f.events.some(e => e.msg?.client_turn_id === 'native:next-native'), 'autonomous start without Goal event');
  f.reply(f.startRequests()[0], { turn: { id: 'original' } });
  f.notify('item/agentMessage/delta', { turnId: 'next-native', delta: 'fresh native text' });
  f.complete('next-native');
  await f.until(() => f.results().length === 2, 'autonomous result survives old start reply');
  assert.equal(f.results()[1].msg.client_turn_id, 'native:next-native');
  assert.equal(f.results()[1].msg.result, 'fresh native text');
  assert.equal(f.startRequests().length, 1);
});

test('blocked Goal is not resumed by ordinary chat or turn completion', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('blocked') });
  f.send('ordinary');
  await f.until(() => f.startRequests().length === 1, 'ordinary turn');
  f.reply(f.startRequests()[0], { turn: { id: 'ordinary-native' } }); f.started('ordinary-native');
  f.complete('ordinary-native');
  await f.until(() => f.results().length === 1, 'ordinary result');
  assert.equal(goalRequests(f).length, 0);
  assert.equal(goalEvents(f).at(-1).goal.status, 'blocked');
  f.notify('thread/goal/cleared', { threadId: 'thread-fixture' });
  await f.until(() => goalEvents(f).at(-1).goal === null, 'native clear');
});

test('stop pauses active Goal before interrupt and catches a continuation during pause', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('active') });
  f.started('goal-first');
  await f.until(() => f.events.some(e => e.msg?.subtype === 'native_turn_started'), 'first native turn');
  f.command({ op: 'interrupt' });
  await f.until(() => goalRequests(f).length === 1, 'native pause before interrupt');
  assert.equal(goalRequests(f)[0].params.status, 'paused');
  assert.equal(f.interrupts().length, 0);
  f.complete('goal-first');
  f.started('goal-racing');
  await f.until(() => f.events.some(e => e.msg?.client_turn_id === 'native:goal-racing'), 'racing native turn is still visible');
  f.reply(goalRequests(f)[0], { goal: goalSnapshot('paused') });
  await f.until(() => f.interrupts().length === 1, 'interrupt after pause confirmation');
  assert.equal(f.interrupts()[0].params.turnId, 'goal-racing');
  f.reply(f.interrupts()[0]); f.complete('goal-racing', 'interrupted');
  await f.until(() => f.results().length === 2, 'racing continuation stopped');
  assert.equal(goalEvents(f).at(-1).goal.status, 'paused');
  assert.equal(f.startRequests().length, 0);
});

test('Goal pause failure remains visible while its original turn is still interrupted', { timeout: 10_000 }, async t => {
  const f = await fixture(t); await f.boot();
  f.notify('thread/goal/updated', { threadId: 'thread-fixture', goal: goalSnapshot('active') });
  f.started('goal-first');
  await f.until(() => f.events.some(e => e.msg?.subtype === 'native_turn_started'), 'native turn observed before stop');
  f.command({ op: 'interrupt' });
  await f.until(() => goalRequests(f).length === 1, 'pause request');
  f.native({ id: goalRequests(f)[0].id, error: { code: -32000, message: 'fixture pause denied' } });
  await f.until(() => f.interrupts().length === 1, 'original turn interrupted despite failed pause');
  assert.ok(f.events.some(e => e.msg?.subtype === 'goal_unavailable' && /pause denied/.test(e.msg.message)));
  assert.equal(goalEvents(f).at(-1).goal.status, 'active', 'no fake paused status');
  assert.equal(f.results().length, 0, 'no fake terminal confirmation');
});

test('stop before boot drops prior sends, but accepts an explicit later send', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  f.send('discard');
  f.command({ op: 'interrupt' });
  f.send('new');
  await f.barrier();
  await f.boot();
  await f.until(() => f.startRequests().length === 1, 'one new start');
  assert.equal(f.startRequests()[0].params.clientUserMessageId, 'new');
  assert.equal(f.results().find(e => e.msg.client_turn_id === 'discard')?.msg.subtype, 'cancelled',
    'App receives terminal confirmation even when the cancelled turn never started');
});

test('native steering waits for acknowledgement and does not start another turn', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } });
  f.started('native-work');
  steer(f, 'steer-one', 'work', { attachments: ['/fixture/image.png'] });
  await f.until(() => steers(f).length === 1, 'native steer');
  assert.deepEqual(steers(f)[0].params, {
    threadId: 'thread-fixture', expectedTurnId: 'native-work', clientUserMessageId: 'steer-one',
    input: [{ type: 'text', text: '改查這個問題', text_elements: [] }, { type: 'localImage', path: '/fixture/image.png' }],
  });
  assert.equal(steerResults(f).length, 0, 'no premature accepted receipt');
  steer(f, 'duplicate');
  await f.until(() => steerResults(f).length === 1, 'duplicate rejected');
  assert.equal(steerResults(f)[0].accepted, false);
  f.reply(steers(f)[0], { turnId: 'native-work' });
  await f.until(() => steerResults(f).some(r => r.request_id === 'steer-one'), 'accepted');
  assert.equal(steerResults(f).find(r => r.request_id === 'steer-one').accepted, true);
  assert.equal(f.startRequests().length, 1);
  assert.equal(f.results().length, 0, 'steering is not turn completion');
});

test('steering before native ID waits for start event and is sent exactly once', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  steer(f, 'early'); await f.barrier();
  assert.equal(steers(f).length, 0);
  f.started('native-work');
  await f.until(() => steers(f).length === 1, 'deferred steer');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } });
  f.reply(steers(f)[0], { turnId: 'native-work' });
  await f.until(() => steerResults(f).length === 1, 'one acknowledgement');
  await f.barrier();
  assert.equal(steers(f).length, 1);
  assert.equal(steerResults(f)[0].accepted, true);
});

test('stop before start cancels pending steering without replay', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  steer(f, 'early'); f.command({ op: 'interrupt' });
  await f.until(() => steerResults(f).length === 1, 'steer cancelled');
  assert.equal(steerResults(f)[0].accepted, false);
  f.started('native-work');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } });
  await f.until(() => f.interrupts().length === 1, 'interrupt original turn');
  f.complete('native-work', 'interrupted');
  await f.until(() => f.results().length === 1, 'original turn ended');
  assert.equal(steers(f).length, 0);
  assert.equal(f.startRequests().length, 1);
});

for (const ackFirst of [true, false]) {
  test(`submitted steering survives stop with ack ${ackFirst ? 'before' : 'after'} terminal`, { timeout: 10_000 }, async t => {
    const f = await fixture(t);
    await f.boot(); f.send('work');
    await f.until(() => f.startRequests().length === 1, 'start');
    f.reply(f.startRequests()[0], { turn: { id: 'native-work' } }); f.started('native-work');
    steer(f, 'inflight');
    await f.until(() => steers(f).length === 1, 'submitted insertion');
    f.command({ op: 'interrupt' });
    await f.until(() => f.interrupts().length === 1, 'interrupt submitted');
    f.reply(f.interrupts()[0]);
    if (ackFirst) {
      f.reply(steers(f)[0], { turnId: 'native-work' });
      await f.until(() => steerResults(f).length === 1, 'native acknowledgement');
      assert.equal(f.results().length, 0, 'ack is not a terminal result');
    }
    f.complete('native-work', 'interrupted');
    await f.until(() => f.results().length === 1, 'confirmed cancellation');
    if (!ackFirst) {
      assert.equal(steerResults(f).length, 0, 'terminal cannot invent a rejection');
      f.send('successor');
      await f.until(() => f.startRequests().length === 2, 'explicit successor');
      f.reply(f.startRequests()[1], { turn: { id: 'native-successor' } }); f.started('native-successor');
      steer(f, 'successor-insertion', 'successor');
      await f.until(() => steers(f).length === 2, 'successor insertion');
      f.reply(steers(f)[0], { turnId: 'native-work' });
      await f.until(() => steerResults(f).length === 1, 'old native acknowledgement');
      f.reply(steers(f)[1], { turnId: 'native-successor' });
      await f.until(() => steerResults(f).length === 2, 'independent successor acknowledgement');
      assert.equal(steerResults(f)[1].request_id, 'successor-insertion');
      assert.equal(steerResults(f)[1].target_turn_id, 'successor');
    }
    assert.equal(steerResults(f)[0].request_id, 'inflight');
    assert.equal(steerResults(f)[0].target_turn_id, 'work');
    assert.equal(steerResults(f)[0].accepted, true);
    assert.equal(f.results().length, 1, 'old acknowledgement cannot end another turn');
    assert.equal(f.results()[0].msg.subtype, 'cancelled');
    assert.equal(f.interrupts().length, 1, 'no repeated interrupt');
    assert.equal(f.startRequests().length, ackFirst ? 1 : 2, 'no automatic replay');
  });
}

test('rejected steering preserves the active native turn and permits explicit retry', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } }); f.started('native-work');
  steer(f, 'bad');
  await f.until(() => steers(f).length === 1, 'steer');
  f.native({ id: steers(f)[0].id, error: { code: -32602, message: 'fixture rejection' } });
  await f.until(() => steerResults(f).length === 1, 'rejection');
  assert.equal(steerResults(f)[0].accepted, false);
  assert.match(steerResults(f)[0].message, /fixture rejection/);
  assert.equal(f.results().length, 0);
  steer(f, 'retry');
  await f.until(() => steers(f).length === 2, 'explicit retry');
  f.reply(steers(f)[1], { turnId: 'native-work' });
  await f.until(() => steerResults(f).length === 2, 'retry acknowledgement');
  assert.equal(steerResults(f)[1].accepted, true);
  assert.equal(f.startRequests().length, 1);
});

test('late steering acknowledgement is bound to the old turn, not its successor', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } }); f.started('native-work');
  steer(f, 'late');
  await f.until(() => steers(f).length === 1, 'steer');
  f.complete('native-work'); f.send('successor');
  await f.until(() => f.startRequests().length === 2, 'explicit new turn');
  f.reply(f.startRequests()[1], { turn: { id: 'native-successor' } }); f.started('native-successor');
  f.reply(steers(f)[0], { turnId: 'native-work' });
  await f.until(() => steerResults(f).length === 1, 'late receipt');
  assert.equal(steerResults(f)[0].target_turn_id, 'work');
  assert.equal(steerResults(f)[0].accepted, true);
  assert.equal(f.results().length, 1, 'successor is not ended');
  f.notify('item/agentMessage/delta', { turnId: 'native-successor', delta: 'successor text' });
  f.complete('native-successor');
  await f.until(() => f.results().length === 2, 'successor completes independently');
  assert.equal(f.results()[1].msg.result, 'successor text');
});

test('stale steering target is rejected and a mismatched reply is reported as unknown', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot(); f.send('work');
  await f.until(() => f.startRequests().length === 1, 'start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-work' } }); f.started('native-work');
  steer(f, 'stale', 'earlier-work');
  await f.until(() => steerResults(f).length === 1, 'stale rejection');
  assert.equal(steers(f).length, 0);
  steer(f, 'mismatch');
  await f.until(() => steers(f).length === 1, 'real steer');
  f.reply(steers(f)[0], { turnId: 'wrong-native-turn' });
  await f.until(() => steerResults(f).length === 2, 'unknown outcome');
  assert.equal(steerResults(f)[1].accepted, false);
  assert.equal(steerResults(f)[1].unknown, true);
  assert.equal(f.startRequests().length, 1);
});

test('stop during turn/start waits for ID and sends exactly one interrupt', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'pending start');
  f.send('discard');
  f.command({ op: 'interrupt' });
  f.command({ op: 'interrupt' });
  f.send('new');
  await f.barrier();
  f.started('native-old');
  await f.until(() => f.interrupts().length === 1, 'deferred interrupt');
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  f.reply(f.interrupts()[0]);
  f.complete('native-old', 'interrupted');
  await f.until(() => f.startRequests().length === 2, 'new send after cancellation');
  assert.deepEqual(f.startRequests().map(r => r.params.clientUserMessageId), ['old', 'new']);
  assert.equal(f.interrupts().length, 1);
  const stopped = f.results().find(e => e.msg.client_turn_id === 'old');
  assert.equal(stopped.msg.subtype, 'cancelled');
  assert.equal(stopped.msg.is_error, false);
  assert.equal(f.results().find(e => e.msg.client_turn_id === 'discard').msg.subtype, 'cancelled');
});

test('active stop clears queue; late old events cannot terminate the next turn', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  f.started('native-old');
  f.send('discard');
  f.command({ op: 'interrupt' });
  f.send('new');
  await f.until(() => f.interrupts().length === 1, 'active interrupt');
  f.reply(f.interrupts()[0]);
  f.complete('native-old', 'interrupted');
  await f.until(() => f.startRequests().length === 2, 'next start');
  assert.equal(f.startRequests()[1].params.clientUserMessageId, 'new');
  f.reply(f.startRequests()[1], { turn: { id: 'native-new' } });
  f.started('native-new');
  f.notify('item/agentMessage/delta', { turnId: 'native-old', delta: 'stale' });
  f.complete('native-old', 'interrupted');
  f.notify('item/agentMessage/delta', { turnId: 'native-new', delta: 'fresh' });
  f.complete('native-new');
  await f.until(() => f.results().some(e => e.msg.result === 'fresh'), 'new result survives stale events');
  assert.equal(f.results().filter(e => e.msg.client_turn_id !== 'discard').length, 2);
  assert.ok(!JSON.stringify(f.events).includes('stale'));
});

test('completion before start response cannot resurrect a turn or block the queue', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  f.send('new');
  await f.until(() => f.startRequests().length === 1, 'first start');
  f.started('native-old');
  f.complete('native-old');
  await f.until(() => f.results().length === 1, 'early completion');
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  await f.until(() => f.startRequests().length === 2, 'next start');
  f.reply(f.startRequests()[1], { turn: { id: 'native-new' } });
  f.started('native-new');
  f.complete('native-new');
  await f.until(() => f.results().length === 2, 'both completed');
  f.send('third');
  await f.until(() => f.startRequests().length === 3, 'no resurrected active turn');
});

test('rejected stopped start releases only its turn; explicit new work survives', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'first start');
  f.command({ op: 'interrupt' });
  f.send('new');
  await f.barrier();
  f.native({ id: f.startRequests()[0].id, error: { code: -32602, message: 'fixture rejected' } });
  await f.until(() => f.startRequests().length === 2, 'new after reject');
  assert.equal(f.startRequests()[1].params.clientUserMessageId, 'new');
  assert.equal(f.results()[0].msg.client_turn_id, 'old');
  assert.equal(f.results()[0].msg.is_error, true);
  assert.equal(f.interrupts().length, 0);
});

test('interrupt RPC failure is visible and does not silently run queued work', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'first start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  f.started('native-old');
  f.send('discard');
  f.command({ op: 'interrupt' });
  await f.until(() => f.interrupts().length === 1, 'interrupt');
  f.native({ id: f.interrupts()[0].id, error: { code: -1, message: 'fixture stop denied' } });
  await f.until(() => f.events.some(e => e.ev === 'error' && e.message.includes('fixture stop denied')), 'visible failure');
  assert.ok(f.events.some(e => e.ev === 'error' && e.terminal === false && e.client_turn_id === 'old'),
    'App can distinguish recoverable interrupt rejection from a terminal turn failure');
  assert.equal(f.results().filter(e => e.msg.client_turn_id === 'old').length, 0,
    'RPC rejection is not terminal cancellation of the active turn');
  f.command({ op: 'interrupt' });
  await f.until(() => f.interrupts().length === 2, 'explicit retry after failed interrupt');
  f.reply(f.interrupts()[1]);
  f.complete('native-old', 'interrupted');
  await f.until(() => f.results().some(e => e.msg.client_turn_id === 'old'), 'confirmed stop');
  assert.equal(f.startRequests().length, 1);
});

test('pending stop also works when the ID arrives only in the RPC reply', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'pending start');
  f.command({ op: 'interrupt' });
  await f.barrier();
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  await f.until(() => f.interrupts().length === 1, 'interrupt from RPC ID');
  assert.equal(f.interrupts()[0].params.turnId, 'native-old');
  f.reply(f.interrupts()[0]);
  f.complete('native-old', 'interrupted');
  await f.until(() => f.results().length === 1, 'confirmed stop');
});

test('already completed turn is not interrupted or revived by its late start reply', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'pending start');
  f.started('native-old');
  f.complete('native-old');
  await f.until(() => f.results().length === 1, 'early completion');
  f.command({ op: 'interrupt' });
  f.send('new');
  await f.barrier();
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  await f.until(() => f.startRequests().length === 2, 'new start');
  assert.equal(f.interrupts().length, 0);
  // Old duplicate notifications may arrive while the next start has no ID yet.
  f.started('native-old');
  f.complete('native-old');
  f.reply(f.startRequests()[1], { turn: { id: 'native-new' } });
  f.started('native-new');
  f.complete('native-new');
  await f.until(() => f.results().length === 2, 'new completion');
  assert.equal(f.results()[1].msg.client_turn_id, 'new');
});

test('stop declines pending and late approvals rather than authorizing more work', { timeout: 10_000 }, async t => {
  const f = await fixture(t);
  await f.boot();
  f.send('old');
  await f.until(() => f.startRequests().length === 1, 'first start');
  f.reply(f.startRequests()[0], { turn: { id: 'native-old' } });
  f.started('native-old');
  f.native({ id: 100, method: 'item/commandExecution/requestApproval',
    params: { threadId: 'thread-fixture', turnId: 'native-old', command: 'fixture-command' } });
  await f.until(() => f.events.some(e => e.ev === 'permission_request' && e.id === '100'), 'initial permission');
  f.command({ op: 'interrupt' });
  await f.until(() => f.requests.some(r => r.id === 100 && r.result), 'pending permission declined');
  assert.equal(f.requests.find(r => r.id === 100 && r.result).result.decision, 'decline');
  f.native({ id: 101, method: 'item/fileChange/requestApproval',
    params: { threadId: 'thread-fixture', turnId: 'native-old' } });
  await f.until(() => f.requests.some(r => r.id === 101 && r.result), 'late permission declined');
  assert.equal(f.requests.find(r => r.id === 101 && r.result).result.decision, 'decline');
  assert.ok(!f.events.some(e => e.ev === 'permission_request' && e.id === '101'));
  f.command({ op: 'permission', id: '100', allow: true });
  await f.barrier();
  assert.equal(f.requests.filter(r => r.id === 100 && r.result).length, 1,
    'late UI acceptance cannot authorize the declined request');
  f.native({ id: 102, method: 'mcpServer/elicitation/request',
    params: { threadId: 'thread-fixture', turnId: 'native-old' } });
  await f.until(() => f.requests.some(r => r.id === 102 && r.result), 'MCP request cancelled');
  assert.equal(f.requests.find(r => r.id === 102 && r.result).result.action, 'cancel');
});
