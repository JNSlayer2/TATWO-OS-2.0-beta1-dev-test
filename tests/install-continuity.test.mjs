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

test('archives never carry AppleDouble sidecars and the installer extracts with ditto', () => {
  const pkg = readFileSync(new URL('../scripts/package-release.sh', import.meta.url), 'utf8');
  assert.match(pkg, /xattr -cr "\$OUT\/TATWO OS\.app"/);
  assert.match(pkg, /ditto -c -k --norsrc --keepParent/);
  assert.match(install, /ditto -x -k "\$TEMP\/TATWO-OS\.zip" "\$TEMP\/unpacked"/);
  assert.doesNotMatch(install, /unzip -q /);
  // 實證：帶 xattr 的檔案，不加 --norsrc 會在 zip 裡多出 ._ 檔；加了就沒有。
  const dir = spawnSync('mktemp', ['-d'], { encoding: 'utf8' }).stdout.trim();
  spawnSync('bash', ['-c', `mkdir -p "${dir}/A.app" && echo x > "${dir}/A.app/f" && xattr -w com.example.k v "${dir}/A.app/f"`]);
  spawnSync('ditto', ['-c', '-k', '--keepParent', `${dir}/A.app`, `${dir}/with.zip`]);
  spawnSync('ditto', ['-c', '-k', '--norsrc', '--keepParent', `${dir}/A.app`, `${dir}/without.zip`]);
  const list = z => spawnSync('unzip', ['-Z1', z], { encoding: 'utf8' }).stdout;
  assert.match(list(`${dir}/with.zip`), /\._f/);
  assert.doesNotMatch(list(`${dir}/without.zip`), /\._f/);
});
