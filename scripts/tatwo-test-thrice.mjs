import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Used as a Node test reporter as well as the CLI below. Keep test output in
// TAP; only structured result events belong in this machine-readable stream.
export default async function* reporter(source) {
  const parents = new Map();
  const nesting = [];
  const occurrences = new Map();
  for await (const { type, data } of source) {
    if (type === 'test:start') {
      const ancestors = parents.get(data.parentId) ?? nesting.slice(0, data.nesting);
      const names = [...ancestors, data.name];
      if (data.testId !== undefined) parents.set(data.testId, names);
      nesting[data.nesting] = data.name;
      nesting.length = data.nesting + 1;
    } else if (type === 'test:pass' || type === 'test:fail') {
      const file = data.file ? path.relative(process.cwd(), data.file) : '<unknown-file>';
      const names = parents.get(data.testId) ?? [...nesting.slice(0, data.nesting), data.name];
      const base = JSON.stringify([file, names]);
      const occurrence = (occurrences.get(base) ?? 0) + 1;
      occurrences.set(base, occurrence);
      yield JSON.stringify({ kind: 'result', key: JSON.stringify([file, names, occurrence]),
        file, names, occurrence, line: data.line, column: data.column,
        status: data.skip ? 'skip' : data.todo ? 'todo' : type === 'test:pass' ? 'pass' : 'fail',
        suite: data.details?.type === 'suite', duration_ms: data.details?.duration_ms,
        failureType: data.details?.error?.failureType,
      }) + '\n';
    } else if (type === 'test:summary' && !data.file) {
      yield JSON.stringify({ kind: 'summary', counts: data.counts,
        success: data.success, duration_ms: data.duration_ms }) + '\n';
    }
  }
}

export function readResults(text) {
  const events = text.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const records = events.filter(event => event.kind === 'result');
  const summaries = events.filter(event => event.kind === 'summary');
  // A missing terminal summary is how a truncated run is detected: a process
  // killed mid-suite (disk full, OOM) still emits every record it got to. Never
  // synthesise one from the records — that makes a half-finished run look whole.
  // Node only emits `test:summary` from v22 on, so say so instead of failing
  // with a cryptic message.
  if (summaries.length !== 1) {
    const hint = summaries.length === 0 && Number(process.versions.node.split('.')[0]) < 22
      ? ` (Node >= 22 required for test:summary events; running ${process.versions.node})` : '';
    throw new Error('expected exactly one terminal Node summary' + hint);
  }
  const summary = summaries[0];
  const tests = records.filter(record => !record.suite);
  if (tests.length !== summary.counts.tests || !tests.length) {
    throw new Error(`incomplete result stream: ${tests.length} results / ${summary.counts.tests} tests`);
  }
  if (new Set(records.map(record => record.key)).size !== records.length) {
    throw new Error('duplicate result identity');
  }
  for (const [status, counter] of [['pass', 'passed'], ['skip', 'skipped'], ['todo', 'todo']]) {
    if (tests.filter(record => record.status === status).length !== summary.counts[counter]) {
      throw new Error(`result/summary mismatch: ${counter}`);
    }
  }
  if (tests.filter(record => record.status === 'fail').length !== summary.counts.failed + summary.counts.cancelled) {
    throw new Error('result/summary mismatch: failed/cancelled');
  }
  return { records, summary };
}

export function compareRounds(rounds) {
  if (rounds.length !== 3) throw new Error('exactly three complete rounds are required');
  const maps = rounds.map(round => new Map(round.records.map(record => [record.key, record])));
  const keys = [...new Set(maps.flatMap(map => [...map.keys()]))].sort();
  const inventory = keys.map(key => {
    const record = maps.map(map => map.get(key)).find(Boolean);
    return { key, file: record.file, names: record.names, occurrence: record.occurrence,
      suite: record.suite, states: maps.map(map => map.get(key)?.status ?? 'missing') };
  });
  const failures = inventory.filter(row => row.states.every(status => status === 'fail'));
  const differences = inventory.filter(row => new Set(row.states).size > 1);
  const flaky = differences.filter(row => row.states.includes('pass') && row.states.includes('fail'));
  const missing = differences.filter(row => row.states.includes('missing'));
  const unstableFailures = inventory.filter(row => row.states.includes('fail') && !failures.includes(row));
  const directives = inventory.filter(row => row.states.includes('skip') || row.states.includes('todo'));
  const cancelled = rounds.some(round => round.summary.counts.cancelled > 0);
  const empty = rounds.some(round => round.summary.counts.tests === 0);
  // Intermittent failures are NOT established regressions, but are not a clean
  // PASS either. Never turn an intersection of empty/missing runs into green.
  const exitCode = missing.length || cancelled || empty ? 2 : failures.length ? 1 : differences.length ? 3 : 0;
  return { inventory, failures, differences, flaky, missing, unstableFailures, directives, cancelled, empty, exitCode };
}

export function sourceIdentity(root) {
  const git = args => execFileSync('git', ['-C', root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const head = git(['rev-parse', 'HEAD']).trim();
  const files = [...new Set(git(['ls-files', '-z', '--cached', '--others', '--exclude-standard']).split('\0').filter(Boolean))].sort();
  const hash = createHash('sha256');
  for (const relative of files) {
    const file = path.join(root, relative);
    hash.update(relative + '\0');
    let stat;
    try { stat = fs.lstatSync(file); }
    catch (error) { if (error.code !== 'ENOENT') throw error; hash.update('missing\0'); continue; }
    hash.update(String(stat.mode) + '\0');
    if (stat.isSymbolicLink()) hash.update('link\0' + fs.readlinkSync(file));
    else if (stat.isFile()) hash.update(fs.readFileSync(file));
    else throw new Error(`unsupported source entry: ${relative}`);
    hash.update('\0');
  }
  return { head, sha256: hash.digest('hex'), files: files.length };
}

function sameIdentity(left, right) {
  return left.head === right.head && left.sha256 === right.sha256 && left.files === right.files;
}

function label(row) {
  return `${row.file} :: ${row.names.join(' > ')}${row.occurrence > 1 ? ` [${row.occurrence}]` : ''}`;
}

export function formatReport(rounds, result, identity) {
  const lines = [`SOURCE ${identity.head} sha256=${identity.sha256}`, 'COMMAND node --test --test-concurrency=2 tests/*.test.mjs'];
  for (const [i, round] of rounds.entries()) {
    const c = round.summary.counts;
    lines.push(`ROUND ${i + 1}: tests=${c.tests} pass=${c.passed} fail=${c.failed} cancelled=${c.cancelled} skip=${c.skipped} todo=${c.todo} exit=${round.exitCode}`);
  }
  lines.push(`CONSISTENT_FAILURES (${result.failures.length}; intersection of all three rounds):`);
  lines.push(...(result.failures.length ? result.failures.map(row => `- ${label(row)}`) : ['(none)']));
  lines.push(`ROUND_DIFFERENCES (${result.differences.length}; pass/fail flips=${result.flaky.length}):`);
  lines.push(...(result.differences.length ? result.differences.map(row => `- [${row.states.join(', ')}] ${label(row)}`) : ['(none)']));
  for (let i = 0; i < 3; i++) {
    const extras = result.unstableFailures.filter(row => row.states[i] === 'fail');
    lines.push(`ROUND ${i + 1} FAILURES OUTSIDE INTERSECTION (${extras.length}):`);
    lines.push(...(extras.length ? extras.map(row => `- ${label(row)}`) : ['(none)']));
  }
  lines.push(`SKIP_TODO (${result.directives.length}; not PASS):`);
  lines.push(...(result.directives.length ? result.directives.map(row => `- [${row.states.join(', ')}] ${label(row)}`) : ['(none)']));
  lines.push(`EXIT ${result.exitCode} (0=stable no failures, 1=consistent failures, 2=incomplete/drift, 3=unstable only)`);
  return lines.join('\n') + '\n';
}

async function runNode(root, files, out, number) {
  const stem = path.join(out, `round-${number}`);
  const args = ['--test', '--test-concurrency=2', '--test-reporter=tap',
    `--test-reporter=${fileURLToPath(import.meta.url)}`,
    `--test-reporter-destination=${stem}.tap`, `--test-reporter-destination=${stem}.jsonl`, ...files];
  const fd = fs.openSync(`${stem}.stderr.log`, 'wx');
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  env.TATWO_TEST_SCRATCH_LOG = `${stem}.scratch.jsonl`;
  const start = new Date().toISOString();
  let child;
  const handlers = new Map(['SIGINT', 'SIGTERM'].map(signal => [signal, () => child?.kill(signal)]));
  try {
    const status = await new Promise((resolve, reject) => {
      child = spawn(process.execPath, args, { cwd: root, env, stdio: ['ignore', fd, fd] });
      child.once('error', reject);
      child.once('close', (code, signal) => resolve({ exitCode: code, signal }));
      for (const [signal, handler] of handlers) process.once(signal, handler);
    });
    fs.writeFileSync(`${stem}.status.json`, JSON.stringify({ ...status, start, end: new Date().toISOString(), args }, null, 2) + '\n');
    if (status.signal || ![0, 1].includes(status.exitCode)) throw new Error(`round ${number} did not finish normally: ${JSON.stringify(status)}`);
    const results = readResults(fs.readFileSync(`${stem}.jsonl`, 'utf8'));
    if (results.summary.success !== (status.exitCode === 0)) throw new Error(`round ${number} exit/summary mismatch`);
    return { ...results, ...status };
  } finally {
    fs.closeSync(fd);
    for (const [signal, handler] of handlers) process.removeListener(signal, handler);
  }
}

async function main(args) {
  if (args.length > 1 || args.some(arg => arg.startsWith('-'))) {
    console.error('Usage: scripts/tatwo-test-thrice.sh [new-output-directory-outside-repository]');
    return args.length === 1 && ['-h', '--help'].includes(args[0]) ? 0 : 2;
  }
  const root = fs.realpathSync(fileURLToPath(new URL('../', import.meta.url)));
  let out;
  try {
    const base = args[0] ? path.dirname(path.resolve(args[0])) : fs.realpathSync(os.tmpdir());
    const parent = fs.realpathSync(base);
    if (parent === root || parent.startsWith(root + path.sep)) throw new Error('evidence must be outside the source tree');
    if (args[0]) { const candidate = path.join(parent, path.basename(args[0])); fs.mkdirSync(candidate, { mode: 0o700 }); out = candidate; }
    else out = fs.mkdtempSync(path.join(parent, 'tatwo-test-thrice-'));
    const files = fs.readdirSync(path.join(root, 'tests')).filter(name => name.endsWith('.test.mjs')).sort().map(name => `tests/${name}`);
    if (!files.length) throw new Error('no tests/*.test.mjs files');
    const identity = sourceIdentity(root);
    fs.writeFileSync(path.join(out, 'source.json'), JSON.stringify({ ...identity, node: process.version, testFiles: files }, null, 2) + '\n');
    console.log(`EVIDENCE ${out}`);
    const rounds = [];
    for (let number = 1; number <= 3; number++) {
      if (!sameIdentity(identity, sourceIdentity(root))) throw new Error(`source drift before round ${number}`);
      console.log(`RUN ${number}/3 (${files.length} complete test files)`);
      rounds.push(await runNode(root, files, out, number));
      if (!sameIdentity(identity, sourceIdentity(root))) throw new Error(`source drift during round ${number}`);
    }
    const result = compareRounds(rounds);
    fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify({ identity, rounds: rounds.map(({ summary, exitCode }) => ({ summary, exitCode })), ...result }, null, 2) + '\n');
    const report = formatReport(rounds, result, identity);
    fs.writeFileSync(path.join(out, 'summary.txt'), report);
    process.stdout.write(report);
    return result.exitCode;
  } catch (error) {
    const message = `INCOMPLETE: ${error.message}\nEXIT 2\n`;
    if (out && fs.existsSync(out)) fs.writeFileSync(path.join(out, 'incomplete.txt'), message);
    process.stderr.write(message);
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = await main(process.argv.slice(2));
}
