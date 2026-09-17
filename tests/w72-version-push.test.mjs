import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';

const script = resolve('scripts/tatwo-device-sync.sh');
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'w72-version-'));
  const repo = join(root, 'repo');
  const home = join(root, 'home');
  mkdirSync(repo); mkdirSync(home);
  const env = { ...process.env, HOME: home, GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null', TATWO_SYNC_REPO: repo,
    TATWO_DEVICE_NAME: 'fixture', TATWO_APP_SUPPORT: join(root, 'support'),
    TATWO_OS_ROOT: join(root, 'os'), TATWO_LOOP_CHANNEL_ROOT: join(root, 'channel') };
  const git = (...args) => {
    const p = spawnSync('/usr/bin/git', ['-C', repo, ...args], { env, encoding: 'utf8' });
    assert.equal(p.status, 0, p.stderr);
    return p.stdout;
  };
  git('init'); git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'user.name', 'W72 fixture');
  writeFileSync(join(repo, 'tracked'), 'base\n');
  git('add', '.'); git('commit', '-m', 'fixture');
  writeFileSync(join(root, 'MANIFEST.md'),
    '# Synthetic W72 fixture\nOriginal source: generated test data only.\n' +
    'Retained in TMPDIR; no permanent deletion performed. No user data copied.\n');
  const snapshot = () => ({
    head: git('rev-parse', 'HEAD'),
    branch: git('symbolic-ref', 'HEAD'),
    status: git('status', '--porcelain', '--untracked-files=all'),
    cached: git('diff', '--cached', '--binary'),
    worktree: git('diff', '--binary'),
    index: readFileSync(join(repo, '.git/index')).toString('base64'),
    tracked: readFileSync(join(repo, 'tracked')).toString('base64'),
  });
  return { root, repo, env, git, snapshot };
}

for (const kind of ['unstaged', 'staged', 'untracked', 'mixed']) {
  test(`dirty version-push refuses ${kind}; HEAD/index/worktree/branch unchanged`, () => {
    const f = fixture();
    if (kind !== 'untracked') writeFileSync(join(f.repo, 'tracked'), 'changed\n');
    if (kind === 'staged' || kind === 'mixed') f.git('add', 'tracked');
    if (kind === 'mixed') writeFileSync(join(f.repo, 'tracked'), 'after staging\n');
    if (kind === 'untracked' || kind === 'mixed') writeFileSync(join(f.repo, 'untracked'), 'keep me\n');
    const before = f.snapshot();
    const p = spawnSync('/bin/bash', [script, 'version-push'], { env: f.env, encoding: 'utf8' });
    assert.notEqual(p.status, 0);
    assert.match(p.stdout + p.stderr, /先提交或暫存/);
    // Check raw index before running git status again (which can refresh it).
    assert.equal(readFileSync(join(f.repo, '.git/index')).toString('base64'), before.index);
    assert.deepEqual(f.snapshot(), before);
    if (kind === 'untracked' || kind === 'mixed') {
      assert.equal(readFileSync(join(f.repo, 'untracked'), 'utf8'), 'keep me\n');
    }
  });
}

test('clean version-push pushes existing HEAD only to dev/device', () => {
  const f = fixture();
  const bare = join(f.root, 'remote.git');
  f.git('init', '--bare', bare);
  f.git('remote', 'add', 'origin', bare);
  const before = f.snapshot();
  const p = spawnSync('/bin/bash', [script, 'version-push'], { env: f.env, encoding: 'utf8' });
  assert.equal(p.status, 0, p.stdout + p.stderr);
  assert.deepEqual(f.snapshot(), before);
  assert.match(f.git('ls-remote', 'origin', 'refs/heads/dev/fixture'), new RegExp(before.head.trim()));
});
