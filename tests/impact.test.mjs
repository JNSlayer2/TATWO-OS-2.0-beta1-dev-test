import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { codeImpact, formatImpact } from '../scripts/impact.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const cli = path.join(repo, 'scripts/impact.mjs');
const server = path.join(repo, 'Engines/os-mcp/server.mjs');
const impactTool = 'code_impact';
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'impact-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true })); // Task-owned temporary fixtures only.
  return {
    root,
    write(file, text) {
      fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
      fs.writeFileSync(path.join(root, file), text);
    },
  };
}
function rpc(cwd, requests, script = server, env = process.env) {
  const result = spawnSync(process.execPath, [script], {
    cwd, env, encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
    input: requests.map((params, i) => JSON.stringify({
      jsonrpc: '2.0', id: i + 1, method: params ? 'tools/call' : 'tools/list', params,
    })).join('\n') + '\n',
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
  return result.stdout.trim().split('\n').map(line => JSON.parse(line).result);
}

test('one definition, exactly three references, grouped counts and word boundaries', async t => {
  const f = fixture(t);
  f.write('Types.swift', 'struct Actor {}\n');
  f.write('Uses.swift', 'let one: Actor\nlet two = Actor()\nlet noise: BrowserActorPolicy\nlet noise2: ActorExtra\n');
  f.write('odd:name with space\nand newline/Third.swift', 'let three: Actor\n');
  f.write('tests/related.test.mjs', 'read("Types.swift"); read("Uses.swift");\n');
  f.write('tests/unrelated.test.mjs', 'const noise = "Actors";\n');
  for (const dir of ['.build', '.build-debug', 'dist', 'evidence', 'node_modules', '.git', 'nested/.build-other']) {
    f.write(`${dir}/Ignored.swift`, 'let ignored: Actor\n');
  }
  f.write('.build-cache.swift', 'let ignored: Actor\n');
  fs.symlinkSync(path.join(f.root, 'Uses.swift'), path.join(f.root, 'Linked.swift'));
  const result = await codeImpact('Actor', { root: f.root, lang: 'swift' });
  assert.equal(result.complete, true);
  assert.equal(result.total, 4);
  assert.equal(result.definitionTotal, 1);
  assert.equal(result.referenceTotal, 3);
  assert.equal(result.definitions[0].file, 'Types.swift');
  assert.deepEqual(result.references.map(g => g.count).sort(), [1, 2]);
  assert.equal(result.references.flatMap(g => g.matches).length, 3);
  assert.doesNotMatch(JSON.stringify(result.references), /BrowserActorPolicy|ActorExtra|Ignored|Linked/);
  assert.deepEqual(result.affectedTests, ['tests/related.test.mjs']);
  assert.equal(result.coverage.scannedFiles, 3);
  assert.match(formatImpact(result), /① 定義處[\s\S]*② 直接引用點[\s\S]*③ 受影響的測試檔/);
});

test('invalid symbols, languages and limits are rejected before any spawn', async () => {
  let calls = 0;
  const spawnImpl = () => { calls += 1; throw new Error('must_not_spawn'); };
  for (const symbol of ['a; rm -rf /', '$(id)', '`id`', 'Actor\n', '../Actor', '-Actor', '', 'a'.repeat(121), null, 3]) {
    await assert.rejects(codeImpact(symbol, { spawnImpl }), /impact_invalid_symbol/);
  }
  for (const lang of ['swift;id', '', null]) {
    await assert.rejects(codeImpact('Actor', { lang, spawnImpl }), /impact_invalid_lang/);
  }
  for (const limit of [0, 201, 1.5, '80', null, NaN]) {
    await assert.rejects(codeImpact('Actor', { limit, spawnImpl }), /impact_invalid_limit/);
  }
  assert.equal(calls, 0);
  const invalid = spawnSync(process.execPath, [cli, 'a; rm -rf /', '--json'], { encoding: 'utf8' });
  assert.equal(invalid.status, 1);
  assert.equal(JSON.parse(invalid.stdout).error, 'impact_invalid_symbol');
});

test('counts every hit beyond 200; definitions have priority; tests use even hidden Swift hits', async t => {
  const f = fixture(t);
  f.write('A.swift', Array(230).fill('consume(Actor.self)').join('\n') + '\n');
  f.write('Z.swift', 'struct Actor {}\n');
  f.write('ZZ.swift', 'consume(Actor.self)\n');
  f.write('tests/dependency.test.mjs', 'read("ZZ.swift");\n');
  const result = await codeImpact('Actor', { root: f.root, limit: 3, lang: 'swift' });
  assert.equal(result.total, 232);
  assert.equal(result.totalExact, true);
  assert.equal(result.truncated, true);
  assert.match(formatImpact(result), /已截斷，實際 232 筆/);
  assert.equal(result.definitions.length, 1);
  assert.equal(result.references[0].count, 230);
  assert.equal(result.references[0].matches.length, 2);
  assert.ok(!result.references.some(group => group.file === 'ZZ.swift'));
  assert.deepEqual(result.affectedTests, ['tests/dependency.test.mjs']);
  const full = await codeImpact('Actor', { root: f.root });
  assert.equal(full.limit, 200);
  assert.equal(full.definitions.length + full.references.flatMap(g => g.matches).length, 200);
  const json = spawnSync(process.execPath, [cli, 'Actor', '--json', '--limit', '3'], { cwd: f.root, encoding: 'utf8' });
  assert.equal(json.status, 0);
  assert.equal(JSON.parse(json.stdout).truncated, true);
  assert.equal(JSON.parse(json.stdout).total, 232);
});

test('rg absence falls back to real grep -rn with array args, exclusions and matching parity', async t => {
  const f = fixture(t);
  f.write('Types.swift', 'enum Actor { case human }\nlet one: Actor\nlet noise: ActorPolicy\n');
  f.write('name: with space\nnewline/Other.swift', 'let two: Actor\n');
  f.write('dist/Noise.swift', 'let noise: Actor\n');
  f.write('tests/type.test.mjs', 'read("Types.swift");\n');
  const calls = [];
  const spawnImpl = (command, args, options) => {
    calls.push({ command, args, shell: options.shell });
    return spawn(command === 'rg' ? path.join(f.root, 'missing-rg') : command, args, options);
  };
  const fallback = await codeImpact('Actor', { root: f.root, spawnImpl, lang: 'swift' });
  const normal = await codeImpact('Actor', { root: f.root, lang: 'swift' });
  assert.equal(fallback.backend, 'grep');
  assert.equal(fallback.complete, true);
  for (const key of ['total', 'definitions', 'references', 'affectedTests']) assert.deepEqual(fallback[key], normal[key]);
  assert.equal(calls.filter(c => c.command === 'rg').length, 1);
  assert.ok(calls.every(c => Array.isArray(c.args) && c.shell === false));
  assert.ok(calls.some(c => c.command === 'grep' && c.args.includes('-rnHI')));
});

test('language filtering, simple Swift/ObjC/JS definitions and no-match result', async t => {
  const f = fixture(t);
  f.write('Model.swift', 'struct Actor {}\n');
  f.write('Model.h', '@interface Actor : NSObject\n');
  f.write('Model.mm', 'Actor *instance;\n');
  f.write('module.mjs', 'export class Actor {}\n');
  f.write('tests/symbol.test.mjs', 'expect("Actor");\n');
  for (const [lang, total, definitions] of [['swift', 1, 1], ['objc', 2, 1], ['js', 2, 1], ['auto', 5, 3]]) {
    const result = await codeImpact('Actor', { root: f.root, lang });
    assert.equal(result.total, total, lang);
    assert.equal(result.definitionTotal, definitions, lang);
    assert.deepEqual(result.affectedTests, ['tests/symbol.test.mjs'], lang);
  }
  for (const line of ['func Target() {}', 'var Target: Int', 'case Target', '- (void)Target;', '@property int Target;', 'function Target() {}']) {
    f.write('Definitions.swift', line + '\n');
    assert.equal((await codeImpact('Target', { root: f.root })).definitionTotal, 1, line);
  }
  const empty = await codeImpact('Absent', { root: f.root });
  assert.equal(empty.total, 0);
  assert.equal(empty.complete, true);
  assert.equal(empty.truncated, false);
});

test('timeouts and missing roots expose partial coverage rather than pretending completion', async t => {
  const f = fixture(t);
  f.write('Types.swift', 'struct Actor {}\n');
  const spawnImpl = (_command, _args, options) => spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], options);
  const result = await codeImpact('Actor', { root: f.root, spawnImpl, timeoutMs: 100 });
  assert.equal(result.complete, false);
  assert.equal(result.totalExact, false);
  assert.equal(result.coverage.scannedFiles, 0);
  assert.match(formatImpact(result), /未掃完/);
  assert.deepEqual(result.errors, [{ stage: 'search', code: 'timeout' }]);
  const missing = await codeImpact('Actor', { root: path.join(f.root, 'missing') });
  assert.equal(missing.complete, false);
  assert.equal(missing.coverage.enumerationComplete, false);
});

test('MCP advertises tool 39, rejects invalid arguments, and returns structured JSON from its cwd without App socket', t => {
  const f = fixture(t);
  f.write('Types.swift', 'struct Actor {}\n' + Array(100).fill('use(Actor.self)').join('\n') + '\n');
  const bad = [{ symbol: 'a; rm -rf /' }, { symbol: 'Actor', limit: 201 }, { symbol: 'Actor', lang: null },
    { symbol: 'Actor', root: '/' }, { symbol: 'Actor', callerThreadID: 'spoof' }, {}];
  const results = rpc(f.root, [null, { name: impactTool, arguments: { symbol: 'Actor' } },
    ...bad.map(args => ({ name: impactTool, arguments: args }))],
  server, { ...process.env, TATWO2_OS_SOCKET: path.join(f.root, 'absent.sock') });
  assert.equal(results[0].tools.length, 39);
  const tool = results[0].tools.find(tool => tool.name === impactTool);
  assert.deepEqual(tool.inputSchema.required, ['symbol']);
  assert.equal(tool.inputSchema.properties.symbol.pattern, '^[A-Za-z_][A-Za-z0-9_]*$');
  assert.equal(tool.inputSchema.properties.symbol.maxLength, 120);
  assert.equal(tool.inputSchema.properties.limit.default, 80);
  assert.match(tool.description, /純文字[\s\S]*不解析語法[\s\S]*protocol/);
  const result = results[1].structuredContent;
  assert.equal(result.total, 101);
  assert.equal(result.limit, 80);
  assert.equal(result.complete, true);
  assert.equal(result.truncated, true);
  assert.deepEqual(JSON.parse(results[1].content[0].text), result);
  for (const result of results.slice(2)) assert.equal(result.isError, true);
});

test('bundle-relative scanner works without repository scripts; packaging requires and copies it', t => {
  const f = fixture(t);
  f.write('Types.swift', 'struct Actor {}\n');
  f.write('Contents/Resources/os-mcp/server.mjs', fs.readFileSync(server));
  f.write('Contents/Resources/os-mcp/impact.mjs', fs.readFileSync(cli));
  const bundled = path.join(f.root, 'Contents/Resources/os-mcp/server.mjs');
  const [result] = rpc(f.root, [{ name: impactTool, arguments: { symbol: 'Actor', lang: 'swift' } }], bundled);
  assert.equal(result.structuredContent.total, 1);
  const packaging = fs.readFileSync(path.join(repo, 'scripts/build-app.sh'), 'utf8');
  assert.match(packaging, /inputs\+=\([^)]*scripts\/impact\.mjs/);
  assert.match(packaging, /cp "scripts\/impact\.mjs" "\$CONTENTS\/Resources\/os-mcp\/impact\.mjs"/);
});

test('real repo CLI smoke: node scripts/impact.mjs BrowserActor exits zero with a hit', () => {
  const result = spawnSync(process.execPath, ['scripts/impact.mjs', 'BrowserActor'], {
    cwd: repo, encoding: 'utf8', timeout: 30_000, maxBuffer: 4 * 1024 * 1024,
  });
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stderr}`);
  assert.match(result.stdout, /BrowserActor\.swift:\d+/);
  assert.match(result.stdout, /complete=true/);
});

// Regression: the CLI main-guard compared path.resolve(argv[1]) against the module
// URL, which differ whenever the invocation path crosses a symlink (macOS /tmp ->
// /private/tmp). main() then never ran, yet the process still exited 0 with no
// output, so a caller would read "no impact found" from a scan that never happened.
test('CLI invoked through a symlinked path still runs and reports', t => {
  const f = fixture(t);
  f.write('Types.swift', 'struct Widget {}\n');
  f.write('Uses.swift', 'let a = Widget()\n');
  const link = path.join(f.root, 'linked-impact.mjs');
  fs.symlinkSync(cli, link);
  const viaLink = spawnSync(process.execPath, [link, 'Widget'], {
    cwd: f.root, encoding: 'utf8', timeout: 30_000,
  });
  assert.equal(viaLink.status, 0, viaLink.stderr);
  assert.match(viaLink.stdout, /Widget/, 'symlinked invocation produced no output');
  assert.match(viaLink.stdout, /complete=true/);
});
