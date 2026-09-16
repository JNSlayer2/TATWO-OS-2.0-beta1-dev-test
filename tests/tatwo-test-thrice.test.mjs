import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import reporter, { readResults, compareRounds, sourceIdentity } from '../scripts/tatwo-test-thrice.mjs';
import { testScratch, stageFixtureFiles } from './helpers/test-scratch.mjs';

const checkout = fileURLToPath(new URL('../', import.meta.url));
function record(file, name, status) {
  return { kind: 'result', key: JSON.stringify([file, [name], 1]),
    file, names: [name], occurrence: 1, status, suite: false };
}
function round(records, cancelled = 0) {
  const count = status => records.filter(row => row.status === status).length;
  return { records, summary: { kind: 'summary', success: count('fail') === 0,
    counts: { tests: records.length, passed: count('pass'), failed: count('fail') - cancelled,
      cancelled, skipped: count('skip'), todo: count('todo'), suites: 0 } } };
}
const serialized = value => [...value.records, value.summary].map(row => JSON.stringify(row)).join('\n') + '\n';

test('scratch roots are unique, outside the checkout and do not share writable state', () => {
  const first = testScratch('w65-scratch-'), second = testScratch('w65-scratch-');
  assert.notEqual(first, second);
  assert.equal(path.relative(checkout, first).startsWith('..'), true);
  fs.writeFileSync(path.join(first, 'keep'), 'first');
  assert.deepEqual(fs.readdirSync(second), []);
  assert.equal(fs.readFileSync(path.join(first, 'keep'), 'utf8'), 'first');
  assert.throws(() => testScratch('../escape'), /single path component/);
});

test('staged probes use exact source bytes and isolate script-derived build output', () => {
  const files = ['scripts/browser-perf.sh', 'scripts/tatwo-build-lock.sh',
    'App/Sources/Tatwo2/Browser/Diagnostics/BrowserProcessSampler.swift'];
  const root = stageFixtureFiles(files);
  for (const file of files) {
    assert.deepEqual(fs.readFileSync(path.join(root, file)), fs.readFileSync(path.join(checkout, file)));
  }
  fs.mkdirSync(path.join(root, '.build'));
  fs.writeFileSync(path.join(root, '.build', 'probe'), 'owned fixture');
  assert.equal(fs.readFileSync(path.join(root, '.build', 'probe'), 'utf8'), 'owned fixture');
  assert.throws(() => stageFixtureFiles(['../escape']), /checkout-relative/);
});

test('result parser rejects missing summaries, duplicate identities and incomplete totals', () => {
  const value = round([record('a.test.mjs', 'sample', 'pass')]);
  assert.equal(readResults(serialized(value)).records.length, 1);
  assert.throws(() => readResults(JSON.stringify(value.records[0])), /terminal Node summary/);
  const duplicate = round([value.records[0], value.records[0]]);
  assert.throws(() => readResults(serialized(duplicate)), /duplicate result identity/);
  const mismatch = structuredClone(value);
  mismatch.summary.counts.tests = 2;
  assert.throws(() => readResults(serialized(mismatch)), /incomplete result stream/);
  assert.throws(() => readResults(serialized(round([]))), /incomplete result stream/);
  const skipped = round([record('a.test.mjs', 'sample', 'skip')]);
  assert.equal(readResults(serialized(skipped)).summary.counts.passed, 0);
});

test('three-round comparison distinguishes persistent, flipping, missing and cancelled tests', () => {
  const fail = record('a.test.mjs', 'same title', 'fail');
  const pass = record('b.test.mjs', 'same title', 'pass');
  const flipping = status => record('c.test.mjs', 'changing', status);
  const result = compareRounds([
    round([fail, pass, flipping('fail')]), round([fail, pass, flipping('pass')]),
    round([fail, pass, flipping('fail')]),
  ]);
  assert.equal(result.failures.length, 1);
  assert.equal(result.failures[0].file, 'a.test.mjs');
  assert.deepEqual(result.flaky[0].states, ['fail', 'pass', 'fail']);
  assert.equal(result.exitCode, 1);
  assert.equal(compareRounds([round([pass]), round([pass]), round([pass])]).exitCode, 0);
  assert.equal(compareRounds([round([flipping('fail')]), round([flipping('pass')]),
    round([flipping('fail')])]).exitCode, 3);
  assert.equal(compareRounds([round([pass]), round([]), round([pass])]).exitCode, 2);
  assert.equal(compareRounds([round([]), round([]), round([])]).exitCode, 2);
  assert.equal(compareRounds([round([fail], 1), round([fail], 1), round([fail], 1)]).exitCode, 2);
  assert.throws(() => compareRounds([round([pass])]), /exactly three/);
});

test('structured reporter preserves parent names and same-title occurrences', async () => {
  const file = path.join(checkout, 'tests', 'sample.test.mjs');
  const events = [
    { type: 'test:start', data: { file, name: 'fixture', nesting: 0, testId: 1 } },
    { type: 'test:start', data: { file, name: 'sample', nesting: 1, testId: 2, parentId: 1 } },
    { type: 'test:pass', data: { file, name: 'sample', nesting: 1, testId: 2, parentId: 1, details: { type: 'test' } } },
    { type: 'test:start', data: { file, name: 'sample', nesting: 1, testId: 3, parentId: 1 } },
    { type: 'test:fail', data: { file, name: 'sample', nesting: 1, testId: 3, parentId: 1, details: { type: 'test' } } },
  ];
  const records = [];
  for await (const line of reporter(events)) records.push(JSON.parse(line));
  assert.deepEqual(records.map(row => row.names), [['fixture', 'sample'], ['fixture', 'sample']]);
  assert.deepEqual(records.map(row => row.occurrence), [1, 2]);
  assert.notEqual(records[0].key, records[1].key);
});

function fixtureRepo(files) {
  const outer = testScratch('w65-thrice-');
  const root = path.join(outer, 'repo');
  fs.mkdirSync(path.join(root, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests'));
  for (const file of ['tatwo-test-thrice.sh', 'tatwo-test-thrice.mjs']) {
    fs.copyFileSync(path.join(checkout, 'scripts', file), path.join(root, 'scripts', file));
  }
  for (const [file, content] of Object.entries(files)) fs.writeFileSync(path.join(root, 'tests', file), content);
  fs.writeFileSync(path.join(root, 'version.txt'), 'initial\n');
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  const git = args => {
    const result = spawnSync('git', ['-c', 'core.hooksPath=/dev/null', ...args],
      { cwd: root, env, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  };
  git(['init', '-q']);
  git(['add', '.']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture' + '@example.invalid',
    '-c', 'commit.gpgSign=false', 'commit', '-qm', 'fixture']);
  return { root, outer, env };
}
function runFixture(fixture, out = path.join(fixture.outer, 'evidence')) {
  const result = spawnSync('bash', [path.join(fixture.root, 'scripts/tatwo-test-thrice.sh'), out], {
    cwd: fixture.root, encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024,
    env: { ...fixture.env, W65_FIXTURE_COUNTER: path.join(fixture.outer, 'counter') },
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return { ...result, out };
}
const prelude = "import test from 'node:test'; import assert from 'node:assert/strict';\n";
const changing = `import fs from 'node:fs';
const counter = process.env.W65_FIXTURE_COUNTER;
const attempt = fs.existsSync(counter) ? Number(fs.readFileSync(counter, 'utf8')) + 1 : 1;
fs.writeFileSync(counter, String(attempt));
test('changing', () => assert.equal(attempt, 2));
`;

// 這支工具靠 Node 的 test:summary 事件判斷一輪有沒有跑完（Node 22 起才有）。
// 缺少它不是可以繞過的細節：截斷的執行（磁碟滿、記憶體不足被砍）同樣會送出
// 已跑到的每一筆紀錄，唯一分辨方式就是收尾摘要在不在。因此在 Node 20 這類
// 舊版上，實跑 runner 的測試以能力閘略過，而不是放寬工具的判斷。
const needsNode22 = Number(process.versions.node.split('.')[0]) < 22
  ? { skip: `需要 Node >= 22 的 test:summary 事件；此機為 ${process.versions.node}` }
  : {};

test('real thrice runner executes every file three times even after failures and separates identical titles', needsNode22, () => {
  const fixture = fixtureRepo({
    'a.test.mjs': prelude + "test('same title', () => assert.fail('fixture'));\n",
    'b.test.mjs': prelude + "test('same title', () => assert.ok(true));\n" + changing,
  });
  const result = runFixture(fixture);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  const summary = JSON.parse(fs.readFileSync(path.join(result.out, 'summary.json'), 'utf8'));
  assert.equal(summary.rounds.length, 3);
  assert.ok(summary.rounds.every(round => round.summary.counts.tests === 3));
  assert.equal(summary.failures.length, 1);
  assert.equal(summary.failures[0].file, 'tests/a.test.mjs');
  assert.deepEqual(summary.flaky[0].states, ['fail', 'pass', 'fail']);
  assert.equal(fs.readFileSync(path.join(fixture.outer, 'counter'), 'utf8'), '3');
  assert.match(result.stdout, /ROUND 3 FAILURES OUTSIDE INTERSECTION \(1\)/);
  for (let i = 1; i <= 3; i++) assert.match(fs.readFileSync(path.join(result.out, `round-${i}.tap`), 'utf8'), /# tests 3/);
});

test('real thrice runner distinguishes stable clean from an empty intersection with intermittent failures', needsNode22, () => {
  for (const [body, expected] of [
    ["test('sample', () => assert.ok(true));\n", 0], [changing, 3],
  ]) {
    const fixture = fixtureRepo({ 'sample.test.mjs': prelude + body });
    const result = runFixture(fixture);
    assert.equal(result.status, expected, result.stdout + result.stderr);
    const summary = JSON.parse(fs.readFileSync(path.join(result.out, 'summary.json'), 'utf8'));
    assert.equal(summary.failures.length, 0);
    assert.equal(summary.rounds.length, 3);
    assert.equal(summary.flaky.length, expected === 3 ? 1 : 0);
  }
});

test('real thrice runner rejects source drift and never overwrites an existing evidence directory', needsNode22, () => {
  const fixture = fixtureRepo({ 'sample.test.mjs': prelude +
    "import fs from 'node:fs'; test('sample', () => fs.appendFileSync('version.txt', 'changed'));\n" });
  const before = sourceIdentity(fixture.root);
  const result = runFixture(fixture);
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stderr, /source drift during round 1/);
  assert.notEqual(sourceIdentity(fixture.root).sha256, before.sha256);
  assert.equal(fs.existsSync(path.join(result.out, 'round-2.tap')), false);
  const existing = path.join(fixture.outer, 'keep');
  fs.mkdirSync(existing);
  fs.writeFileSync(path.join(existing, 'sentinel'), 'keep');
  const rejected = runFixture(fixture, existing);
  assert.equal(rejected.status, 2);
  assert.deepEqual(fs.readdirSync(existing), ['sentinel']);
  assert.equal(fs.readFileSync(path.join(existing, 'sentinel'), 'utf8'), 'keep');
});
