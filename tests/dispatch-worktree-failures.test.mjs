import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync, spawnSync } from 'node:child_process';

// Compile the production methods, not a reimplementation. All git repositories
// are fresh ignored fixtures; no model, account, app, or existing worktree is used.
const repo = process.cwd();
const source = fs.readFileSync('App/Sources/Tatwo2/Facade/DispatchEngine.swift', 'utf8');
function section(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a);
  return source.slice(a, b);
}
// Ordinary-folder tests must be outside any enclosing repository; otherwise git
// discovers the real checkout above the fixture and tests the wrong behavior.
const cleanGitEnvironment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
const scratch = fs.realpathSync(os.tmpdir());
const enclosing = spawnSync('/usr/bin/git', ['-C', scratch, 'rev-parse', '--git-dir'], {
  encoding: 'utf8', timeout: 5000, env: { ...cleanGitEnvironment, LC_ALL: 'C' },
});
assert.ifError(enclosing.error);
assert.equal(enclosing.status, 128, 'fixture scratch must be outside any enclosing repository');
assert.match(enclosing.stderr, /fatal: not a git repository/);
for (let dir = scratch; ; dir = path.dirname(dir)) {
  let marker;
  try { marker = fs.lstatSync(path.join(dir, '.git')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  assert.equal(marker, undefined, 'fixture scratch must not be below any .git marker');
  if (path.dirname(dir) === dir) break;
}
const root = fs.mkdtempSync(path.join(scratch, 'dispatch-worktree.'));
const binary = path.join(root, 'probe');
fs.writeFileSync(path.join(root, 'probe.swift'), `
import Foundation
struct DispatchGitFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
@MainActor final class ChatPageModel {
${section('    nonisolated static func excludeRoomWorktrees', '    /// 便利呼叫')}
${section('    static func prepareRoomWorktree', '    /// 房間收尾')}
}
MainActor.assumeIsolated {
    do {
        let result = try ChatPageModel.prepareRoomWorktree(
            workdir: CommandLine.arguments[1], roomID: CommandLine.arguments[2])
        print("CREATED:" + result)
    } catch {
        print("REJECTED:" + String(describing: error))
        exit(2)
    }
}
`);
execFileSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
/usr/bin/nice -n 10 xcrun swiftc -num-threads 2 "$1" -o "$2"
`, 'dispatch-worktree', path.join(root, 'probe.swift'), binary], {
  cwd: repo, timeout: 150000, env: { ...process.env, TMPDIR: root }, stdio: 'pipe',
});

const id = '01234567-89AB-CDEF-0123-456789ABCDEF';
function git(cwd, ...args) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith('GIT_')));
  return execFileSync('/usr/bin/git', ['-c', 'core.hooksPath=/dev/null', '-C', cwd, ...args],
    { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}
function directory(name) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir);
  return dir;
}
function repository(name, commit = true) {
  const dir = directory(name);
  git(dir, 'init', '-b', 'main');
  if (commit) git(dir, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-m', 'fixture');
  return dir;
}
function run(cwd, roomID = id, environment = {}) {
  const result = spawnSync(binary, [cwd, roomID], {
    encoding: 'utf8', timeout: 15000,
    env: { ...process.env, TMPDIR: root, ...environment },
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}
function rejected(result) {
  assert.equal(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stdout, /^REJECTED:/);
  assert.doesNotMatch(result.stdout, /CREATED:/);
}

test('git worktree is real, clean, isolated, and does not invoke checkout hooks', () => {
  const dir = repository('valid');
  const hookMarker = path.join(dir, 'hook-ran');
  fs.writeFileSync(path.join(dir, '.git/hooks/post-checkout'), '#!/bin/sh\ntouch "' + hookMarker + '"\n', { mode: 0o700 });
  const result = run(dir);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const worktree = path.join(dir, '.tatwo2/wt', id);
  assert.equal(git(worktree, 'branch', '--show-current'), 'tatwo2-room-01234567');
  assert.equal(git(dir, 'status', '--porcelain'), '');
  assert.equal(fs.existsSync(hookMarker), false);
});

test('branch collision rejects instead of returning an uncreated worktree', () => {
  const dir = repository('branch-collision');
  git(dir, 'branch', 'tatwo2-room-01234567');
  const before = git(dir, 'worktree', 'list', '--porcelain');
  rejected(run(dir));
  assert.equal(git(dir, 'worktree', 'list', '--porcelain'), before);
  assert.equal(fs.existsSync(path.join(dir, '.tatwo2/wt', id)), false);
});

test('git-supported unborn worktree remains usable without inventing a commit', () => {
  const dir = repository('unborn', false);
  const result = run(dir);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const worktree = path.join(dir, '.tatwo2/wt', id);
  assert.equal(git(worktree, 'branch', '--show-current'), 'tatwo2-room-01234567');
  assert.ok(git(dir, 'worktree', 'list', '--porcelain').includes(worktree));
});

test('existing worktree directory and user content remain untouched on failure', () => {
  const dir = repository('occupied');
  const worktree = path.join(dir, '.tatwo2/wt', id);
  fs.mkdirSync(worktree, { recursive: true });
  fs.writeFileSync(path.join(worktree, 'keep.txt'), 'user work');
  rejected(run(dir));
  assert.equal(fs.readFileSync(path.join(worktree, 'keep.txt'), 'utf8'), 'user work');
});

test('missing project is not recreated as an empty successful room', () => {
  const dir = path.join(root, 'missing');
  rejected(run(dir));
  assert.equal(fs.existsSync(dir), false);
});

test('ordinary folders retain supported room creation but cannot reuse a room', () => {
  const dir = directory('ordinary');
  assert.equal(run(dir).status, 0);
  const room = path.join(dir, '.tatwo2/rooms', id);
  fs.writeFileSync(path.join(room, 'keep.txt'), 'user work');
  rejected(run(dir));
  assert.equal(fs.readFileSync(path.join(room, 'keep.txt'), 'utf8'), 'user work');
});

test('filesystem creation errors are propagated, not reported as success', () => {
  const dir = directory('blocked');
  fs.writeFileSync(path.join(dir, '.tatwo2'), 'not a directory');
  rejected(run(dir));
  assert.equal(fs.readFileSync(path.join(dir, '.tatwo2'), 'utf8'), 'not a directory');
});

test('bare or damaged repositories cannot fall back to an ordinary room', () => {
  const bare = directory('bare');
  git(bare, 'init', '--bare');
  rejected(run(bare));
  assert.equal(fs.existsSync(path.join(bare, '.tatwo2')), false);
  const damaged = directory('damaged');
  fs.writeFileSync(path.join(damaged, '.git'), 'gitdir: /nonexistent/dispatch-fixture-gitdir\n');
  rejected(run(damaged));
  assert.equal(fs.existsSync(path.join(damaged, '.tatwo2')), false);
  const nested = path.join(damaged, 'nested');
  fs.mkdirSync(nested);
  rejected(run(nested));
  assert.equal(fs.existsSync(path.join(nested, '.tatwo2')), false);
  const damagedDirectory = directory('damaged-directory');
  fs.mkdirSync(path.join(damagedDirectory, '.git'));
  rejected(run(damagedDirectory));
  assert.equal(fs.existsSync(path.join(damagedDirectory, '.tatwo2')), false);
});

test('invalid room IDs cannot escape the managed room directory', () => {
  const dir = directory('invalid');
  rejected(run(dir, '../escape'));
  assert.equal(fs.existsSync(path.join(dir, '.tatwo2')), false);
});

test('inherited git overrides cannot redirect creation or exclusion into another repo', () => {
  const dir = repository('intended');
  const other = repository('unrelated');
  const exclude = path.join(other, '.git/info/exclude');
  const before = fs.readFileSync(exclude, 'utf8');
  const result = run(dir, id, { GIT_DIR: path.join(other, '.git'), GIT_WORK_TREE: other });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(fs.readFileSync(exclude, 'utf8'), before);
  assert.equal(git(other, 'branch', '--list', 'tatwo2-room-*'), '');
  assert.equal(git(path.join(dir, '.tatwo2/wt', id), 'branch', '--show-current'), 'tatwo2-room-01234567');
});

test('linked-worktree exclusion stays idempotent under inherited git overrides', () => {
  const dir = repository('linked-parent');
  assert.equal(run(dir).status, 0);
  const worktree = path.join(dir, '.tatwo2/wt', id);
  const other = repository('linked-unrelated');
  const exclude = path.join(dir, '.git/info/exclude');
  const before = fs.readFileSync(exclude, 'utf8');
  const otherExclude = fs.readFileSync(path.join(other, '.git/info/exclude'), 'utf8');
  const next = '11234567-89AB-CDEF-0123-456789ABCDEF';
  assert.equal(run(worktree, next, { GIT_DIR: path.join(other, '.git') }).status, 0);
  assert.equal(fs.readFileSync(exclude, 'utf8'), before);
  assert.equal(fs.readFileSync(path.join(other, '.git/info/exclude'), 'utf8'), otherExclude);
  assert.equal(git(path.join(worktree, '.tatwo2/wt', next), 'branch', '--show-current'), 'tatwo2-room-11234567');
});

test('fixture refuses a scratch root inside the production checkout before creating anything', () => {
  // Represent the enclosing production checkout with an owned repository.
  // No other test can add entries while this guard compares before/after.
  const unsafeCheckout = repository('unsafe-checkout');
  const unsafeScratch = path.join(unsafeCheckout, 'scratch');
  fs.mkdirSync(unsafeScratch);
  const before = fs.readdirSync(unsafeScratch).sort();
  const result = spawnSync(process.execPath, ['--test', path.join(repo, 'tests/dispatch-worktree-failures.test.mjs')], {
    cwd: repo, encoding: 'utf8', timeout: 10000,
    env: { ...cleanGitEnvironment, NODE_TEST_CONTEXT: undefined, TMPDIR: unsafeScratch },
  });
  assert.ifError(result.error);
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout + result.stderr, /fixture scratch must be outside any enclosing repository/);
  assert.deepEqual(fs.readdirSync(unsafeScratch).sort(), before);
});
