import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const install = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const publicInstall = readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');

test('install.sh and public/install.sh stay byte-identical', () => {
  assert.equal(install, publicInstall);
});

test('continuity check passes the designated requirement as inline text, not a file path', () => {
  // 2026-09-12：v2.0.1 驗收時發現 -R "$requirement" 會被 codesign 當成檔案路徑
  // （No such file or directory），等於每一次升級都會被判「簽章身分不相容」。
  assert.equal((install.match(/-R "=\$requirement"/g) ?? []).length, 2);
  assert.doesNotMatch(install, /-R "\$requirement"/);
});

test('codesign really rejects the bare form and accepts the = form (Apple-signed /usr/bin/true)', () => {
  const dr = spawnSync('codesign', ['-dr', '-', '/usr/bin/true'], { encoding: 'utf8' });
  const requirement = (dr.stdout + dr.stderr).split('\n').find(l => l.startsWith('designated => '))?.slice('designated => '.length);
  assert.ok(requirement, 'could not read designated requirement');
  const bare = spawnSync('codesign', ['--verify', '--strict', '-R', requirement, '/usr/bin/true'], { encoding: 'utf8' });
  assert.notEqual(bare.status, 0, 'bare form should fail');
  const inline = spawnSync('codesign', ['--verify', '--strict', '-R', `=${requirement}`, '/usr/bin/true'], { encoding: 'utf8' });
  assert.equal(inline.status, 0, inline.stderr);
});
