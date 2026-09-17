import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const app = join(repo, 'App/Sources/Tatwo2');
const read = file => readFileSync(join(repo, file), 'utf8');
let binary;

// Compile production Foundation code, not a JavaScript reimplementation.
function probe() {
  if (binary) return binary;
  const root = testScratch('w74-compiled-');
  const driver = join(root, 'checks.swift');
  binary = join(root, 'checks');
  writeFileSync(driver, String.raw`
import Foundation

@main struct W74Checks {
    static func main() throws {
        let args = CommandLine.arguments
        var result: [String: Any] = [:]
        switch args[1] {
        case "resolve":
            let env = try JSONDecoder().decode([String: String].self, from: Data(args[2].utf8))
            let entry = TatwoEntry(environment: env, preference: args[3] == "-" ? nil : args[3],
                                   homeDirectory: URL(fileURLWithPath: args[4]))
            result = ["root": entry.root.path, "status": entry.status.rawValue, "exists": entry.exists,
                      "constitution": entry.constitution.path, "skillet": entry.skillet.path,
                      "deviceJSON": entry.deviceJSON.path, "gbrainDir": entry.gbrainDir.path,
                      "noteDir": entry.noteDir.path, "repoRoot": entry.repoRoot.path,
                      "repoDocs": entry.repoDocs.path]
        case "list":
            result = Dictionary(uniqueKeysWithValues: OSDocuments.list().map { ($0.id, $0.path as Any) })
        case "read":
            do { result["text"] = try OSDocuments.read(id: args[2]) }
            catch { result["error"] = error.localizedDescription }
        case "write":
            do {
                let outcome = try OSDocuments.write(id: args[2], text: args[3])
                result["message"] = outcome.message
                switch outcome {
                case .saved: result["outcome"] = "saved"
                case .committed: result["outcome"] = "committed"
                case .secondary: result["outcome"] = "secondary"
                case .unchanged: result["outcome"] = "unchanged"
                case .commitFailed: result["outcome"] = "commitFailed"
                }
            } catch { result["error"] = error.localizedDescription }
        case "upstream":
            result = ["path": OSUpstream.overridePath, "text": OSUpstream.declaration() ?? ""]
        default: fatalError("unknown fixture command")
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
`);
  execFileSync('swiftc', [
    '-swift-version', '5', '-parse-as-library', '-num-threads', '2',
    ...['TatwoEntry', 'OSDocuments', 'OSUpstream', 'TatwoResources'].map(name => join(app, 'Facade', name + '.swift')),
    driver, '-o', binary,
  ], { encoding: 'utf8', timeout: 180_000 });
  return binary;
}

function environment(extra = {}) {
  return {
    ...Object.fromEntries(Object.entries(process.env)
      .filter(([key]) => !key.startsWith('TATWO') && !key.startsWith('GIT_'))),
    GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    ...extra,
  };
}
function run(args, env = {}) {
  return JSON.parse(execFileSync(probe(), args, {
    env: environment(env), encoding: 'utf8', timeout: 30_000,
  }));
}
function git(root, ...args) {
  return execFileSync('/usr/bin/git', ['-C', root, ...args], {
    env: environment(), encoding: 'utf8', timeout: 30_000,
  }).trim();
}
function fixture(role = null) {
  const root = testScratch('w74-documents-');
  const entry = join(root, 'AI', 'TATWO OS');
  const checkout = join(entry, 'tatwo2');
  const docs = join(checkout, 'docs');
  mkdirSync(docs, { recursive: true });
  for (const [file, text] of [
    [join(entry, 'os.md'), '# constitution\n'],
    [join(entry, 'skillet.md'), '# skillet\n'],
    [join(docs, 'todo.md'), '# todo\n'],
    [join(docs, 'issue.md'), '# issue\n'],
    [join(checkout, 'unrelated.txt'), 'original\n'],
  ]) writeFileSync(file, text);
  if (role !== null) writeFileSync(join(entry, 'device.json'), JSON.stringify({ role, name: 'Fixture Mini' }));
  const runtime = join(root, 'runtime', 'os', 'os-upstream.md');
  mkdirSync(join(root, 'runtime', 'os'), { recursive: true });
  writeFileSync(runtime, '# runtime upstream\n');
  git(checkout, 'init', '-q');
  git(checkout, 'config', 'user.name', 'W74 Fixture');
  git(checkout, 'config', 'user.email', 'fixture@example.invalid');
  git(checkout, 'config', 'commit.gpgSign', 'false');
  git(checkout, 'config', 'core.hooksPath', join(root, 'no-hooks'));
  git(checkout, 'add', '.');
  git(checkout, 'commit', '-qm', 'seed');
  return { root, entry, checkout, docs, runtime,
    env: { TATWO_OS_ROOT: entry, TATWO2_OS_UPSTREAM_PATH: runtime } };
}

test('resolver precedence, whitespace, tilde expansion and canonical child paths', () => {
  const home = testScratch('w74-home-');
  const resolve = (env, pref = '-') => run(['resolve', JSON.stringify(env), pref, home]);
  assert.equal(resolve({ TATWO_OS_ROOT: '/first', TATWO2_OS_ROOT: '/second' }, '/third').root, '/first');
  assert.equal(resolve({ TATWO_OS_ROOT: ' \n', TATWO2_OS_ROOT: '/second' }, '/third').root, '/second');
  assert.equal(resolve({}, '/third').root, '/third');
  const paths = resolve({});
  assert.equal(paths.root, join(home, 'AI', 'TATWO OS'));
  for (const [key, suffix] of Object.entries({
    constitution: 'os.md', skillet: 'skillet.md', deviceJSON: 'device.json',
    gbrainDir: 'gbrain', noteDir: 'note', repoRoot: 'tatwo2', repoDocs: 'tatwo2/docs',
  })) assert.equal(paths[key], join(paths.root, suffix));
  assert.equal(resolve({ TATWO_OS_ROOT: '~/AI/TATWO OS' }).root, paths.root);
  assert.equal(resolve({ TATWO_OS_ROOT: '', TATWO2_OS_ROOT: '' }, ' ').root, paths.root);
});

test('missing entrance, broken entrance/parent symlink, regular file and valid symlink differ', () => {
  const root = testScratch('w74-links-');
  const resolve = path => run(['resolve', JSON.stringify({ TATWO_OS_ROOT: path }), '-', root]);
  assert.equal(resolve(join(root, 'missing')).status, 'missing');
  symlinkSync(join(root, 'absent-target'), join(root, 'broken'));
  assert.equal(resolve(join(root, 'broken')).status, 'brokenSymbolicLink');
  assert.equal(resolve(join(root, 'broken', 'child')).status, 'brokenSymbolicLink');
  writeFileSync(join(root, 'plain-file'), 'not a directory');
  assert.equal(resolve(join(root, 'plain-file')).status, 'notDirectory');
  mkdirSync(join(root, 'real'));
  symlinkSync(join(root, 'real'), join(root, 'entrance'));
  const live = resolve(join(root, 'entrance'));
  assert.equal(live.exists, true);
  assert.equal(live.root, join(root, 'entrance')); // Preserve the user's logical entrance.
});

test('five real paths; list/read never seed missing files or runtime upstream', () => {
  const f = fixture();
  const absent = join(f.root, 'absent-upstream.md');
  const env = { ...f.env, TATWO2_OS_UPSTREAM_PATH: absent };
  assert.deepEqual(run(['list'], env), {
    os: join(f.entry, 'os.md'), skillet: join(f.entry, 'skillet.md'),
    todo: join(f.docs, 'todo.md'), issue: join(f.docs, 'issue.md'), 'os-upstream': absent,
  });
  assert.match(run(['read', 'os-upstream'], env).error, /入口缺少 os-upstream\.md/);
  assert.match(run(['write', 'os-upstream', 'must not create'], env).error, /入口缺少/);
  assert.equal(existsSync(absent), false);
  assert.equal(run(['upstream'], f.env).path, f.runtime);
  assert.equal(run(['read', 'os'], f.env).text, '# constitution\n');
});

test('missing document and missing/broken root reject saves without creating directories', () => {
  const root = testScratch('w74-missing-');
  const entry = join(root, 'entry');
  mkdirSync(entry);
  const env = { TATWO_OS_ROOT: entry, TATWO2_OS_UPSTREAM_PATH: join(root, 'runtime.md') };
  assert.match(run(['read', 'os'], env).error, /入口缺少 os\.md/);
  assert.match(run(['write', 'todo', 'must not create'], env).error, /入口缺少 todo\.md/);
  assert.deepEqual(readdirSync(entry), []);
  for (const name of ['absent', 'broken']) {
    if (name === 'broken') symlinkSync(join(root, 'missing-volume'), join(root, name));
    const result = run(['write', 'os', 'must not create'], { ...env, TATWO_OS_ROOT: join(root, name) });
    assert.match(result.error, /找不到入口/);
  }
  assert.equal(existsSync(join(root, 'absent')), false);
  assert.equal(existsSync(join(root, 'missing-volume')), false);
});

test('legacy per-document overrides stay readable while constitution stays at entrance', () => {
  const f = fixture();
  const override = join(f.root, 'legacy-docs');
  mkdirSync(override);
  writeFileSync(join(override, 'todo.md'), 'override todo');
  const skillet = join(f.root, 'legacy-skillet.md');
  writeFileSync(skillet, 'override skillet');
  const env = { ...f.env, TATWO2_DOCS_ROOT: override, TATWO2_SKILLET_PATH: skillet };
  assert.equal(run(['read', 'todo'], env).text, 'override todo');
  assert.equal(run(['read', 'skillet'], env).text, 'override skillet');
  assert.equal(run(['list'], env).os, join(f.entry, 'os.md'));
  assert.equal(run(['upstream'], { TATWO_OS_ROOT: f.entry, TATWO2_DOCS_ROOT: override }).path,
    join(override, 'os-upstream.md'));
});

for (const id of ['todo', 'issue']) {
  test(`primary saves ${id} and commits only that file, preserving other staged/unstaged work`, () => {
    const f = fixture('primary');
    const other = join(f.checkout, 'unrelated.txt');
    writeFileSync(other, 'staged\n');
    git(f.checkout, 'add', 'unrelated.txt');
    writeFileSync(other, 'unstaged\n');
    const staged = git(f.checkout, 'diff', '--cached', '--', 'unrelated.txt');
    const unstaged = git(f.checkout, 'diff', '--', 'unrelated.txt');
    const otherDoc = id === 'todo' ? 'issue' : 'todo';
    writeFileSync(join(f.docs, otherDoc + '.md'), 'another uncommitted document\n');
    const result = run(['write', id, '# user edit\n'], f.env);
    assert.equal(result.outcome, 'committed', result.message);
    assert.equal(git(f.checkout, 'show', '--format=', '--name-only', 'HEAD'), `docs/${id}.md`);
    assert.equal(git(f.checkout, 'log', '-1', '--format=%s'),
      `docs: 使用者經設定頁修改 ${id}.md（Fixture Mini）`);
    assert.equal(git(f.checkout, 'diff', '--cached', '--', 'unrelated.txt'), staged);
    assert.equal(git(f.checkout, 'diff', '--', 'unrelated.txt'), unstaged);
    assert.equal(readFileSync(other, 'utf8'), 'unstaged\n');
    assert.equal(git(f.checkout, 'diff', '--name-only', '--', `docs/${otherDoc}.md`), `docs/${otherDoc}.md`);
    const backups = readdirSync(join(f.docs, '.tatwo2-backups'));
    assert.equal(backups.length, 1);
    assert.equal(readFileSync(join(f.docs, '.tatwo2-backups', backups[0]), 'utf8'), `# ${id}\n`);
    assert.equal(run(['write', id, '# user edit\n'], f.env).outcome, 'unchanged');
  });
}

for (const role of [null, 'secondary', 'PRIMARY', 'invalid']) {
  test(`role ${role}: save locally with secondary notice, never commit or stage`, () => {
    const f = fixture(role);
    const head = git(f.checkout, 'rev-parse', 'HEAD');
    const index = readFileSync(join(f.checkout, '.git', 'index'));
    for (const id of ['todo', 'issue']) {
      const result = run(['write', id, '# secondary edit\n'], f.env);
      assert.equal(result.outcome, 'secondary');
      assert.match(result.message, /副設備：未提交/);
      assert.equal(readFileSync(join(f.docs, `${id}.md`), 'utf8'), '# secondary edit\n');
    }
    assert.equal(git(f.checkout, 'rev-parse', 'HEAD'), head);
    assert.deepEqual(readFileSync(join(f.checkout, '.git', 'index')), index);
  });
}

test('malformed device identity fails closed to secondary', () => {
  const f = fixture('primary');
  writeFileSync(join(f.entry, 'device.json'), 'invalid JSON');
  assert.equal(run(['write', 'todo', 'local only'], f.env).outcome, 'secondary');
  assert.equal(git(f.checkout, 'rev-list', '--count', 'HEAD'), '1');
});

test('logical entrance symlink saves into the target volume and commits its repo', () => {
  const f = fixture('primary');
  const link = join(f.root, 'linked entrance');
  symlinkSync(f.entry, link);
  const env = { ...f.env, TATWO_OS_ROOT: link };
  assert.equal(run(['list'], env).todo, join(link, 'tatwo2', 'docs', 'todo.md'));
  const result = run(['write', 'todo', '# through entrance\n'], env);
  assert.equal(result.outcome, 'committed', result.message);
  assert.equal(readFileSync(join(f.docs, 'todo.md'), 'utf8'), '# through entrance\n');
});

test('constitution/skillet/runtime saves back up beside source and do not commit', () => {
  const f = fixture('primary');
  for (const id of ['os', 'skillet', 'os-upstream']) {
    assert.equal(run(['write', id, '# changed\n'], f.env).outcome, 'saved');
  }
  assert.equal(git(f.checkout, 'rev-list', '--count', 'HEAD'), '1');
  const backups = readdirSync(join(f.entry, '.tatwo2-backups'));
  assert.equal(backups.length, 2);
  for (const [id, old] of [['os', '# constitution\n'], ['skillet', '# skillet\n']]) {
    const name = backups.find(name => name.startsWith(`${id}.md.`));
    assert.equal(readFileSync(join(f.entry, '.tatwo2-backups', name), 'utf8'), old);
  }
  assert.equal(readdirSync(join(f.root, 'runtime', 'os', '.tatwo2-backups')).length, 1);
  assert.equal(run(['upstream'], f.env).text, '# changed\n');
});

test('backups retain the oldest preimage after more than twenty saves', () => {
  const f = fixture();
  for (let i = 0; i < 22; i++) run(['write', 'os', `# revision ${i}\n`], f.env);
  const backupDir = join(f.entry, '.tatwo2-backups');
  const backups = readdirSync(backupDir);
  assert.equal(backups.length, 22);
  assert.ok(backups.some(file => readFileSync(join(backupDir, file), 'utf8') === '# constitution\n'));
});

test('commit failure reports saved-but-uncommitted without losing the new text or preimage', () => {
  const f = fixture('primary');
  // An index lock safely simulates git refusal; do not touch real repositories.
  writeFileSync(join(f.checkout, '.git', 'index.lock'), 'fixture lock');
  const result = run(['write', 'todo', '# saved despite commit failure\n'], f.env);
  assert.equal(result.outcome, 'commitFailed');
  assert.match(result.message, /已儲存但未提交/);
  assert.equal(readFileSync(join(f.docs, 'todo.md'), 'utf8'), '# saved despite commit failure\n');
  assert.equal(git(f.checkout, 'rev-list', '--count', 'HEAD'), '1');
  assert.equal(readdirSync(join(f.docs, '.tatwo2-backups')).length, 1);
});

test('primary never commits a legacy docs override outside entrance repo', () => {
  const f = fixture('primary');
  const outside = join(f.root, 'outside');
  mkdirSync(outside);
  writeFileSync(join(outside, 'todo.md'), 'original');
  const result = run(['write', 'todo', 'local edit'], { ...f.env, TATWO2_DOCS_ROOT: outside });
  assert.equal(result.outcome, 'commitFailed');
  assert.equal(git(f.checkout, 'rev-list', '--count', 'HEAD'), '1');
});

test('runtime default remains runtime; project fallback uses entrance repo docs', () => {
  const f = fixture();
  const live = join(f.root, 'other-runtime', 'live');
  const result = run(['upstream'], { TATWO_OS_ROOT: f.entry, TATWO2_LIVE_ROOT: live });
  assert.equal(result.path, join(f.root, 'other-runtime', 'os', 'os-upstream.md'));
  writeFileSync(join(f.docs, 'os-upstream.md'), '# repo fallback\n');
  assert.equal(run(['upstream'], { TATWO_OS_ROOT: f.entry, TATWO2_LIVE_ROOT: live }).text, '# repo fallback\n');
});

test('all scoped root consumers delegate; UI hides editor on read failure and exposes real paths', () => {
  for (const file of ['Facade/OSDocuments.swift', 'Facade/OSUpstreamBinding.swift',
    'Facade/OSUpstream.swift', 'Pages/WorkOSLiveEvidenceSection.swift']) {
    const text = read(`App/Sources/Tatwo2/${file}`);
    assert.match(text, /TatwoEntry\(/);
    assert.doesNotMatch(text, /Application Support\/tatwo2\/docs/);
  }
  const ui = read('App/Sources/Tatwo2/New/OSDocumentsCard.swift');
  assert.match(ui, /if !TatwoEntry\(\)\.exists/);
  assert.match(ui, /找不到入口/);
  assert.match(ui, /brokenSymbolicLink/);
  assert.match(ui, /if let error = model\.osDocumentReadErrors\[id\]/);
  assert.match(ui, /else if model\.osDocumentText\[id\] != nil/);
  assert.match(ui, /\.help\(doc\.path\)\.textSelection\(\.enabled\)/);
  assert.match(ui, /副設備：未提交/);
  assert.match(read('scripts/tatwo-skillet-md.py'), /return expand\("~\/AI\/TATWO OS"\)/);
  assert.match(read('scripts/tatwo-device-sync.sh'), /OS_ROOT="\$\{TATWO_OS_ROOT:-\$HOME\/AI\/TATWO OS\}"/);
  assert.equal(existsSync(join(repo, 'docs', '工程日誌.md')), true);
  assert.equal(existsSync(join(repo, 'docs', 'note.md')), false);
});
