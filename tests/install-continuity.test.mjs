import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
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
  assert.match(install, /ditto -x -k "\$ZIP" "\$TEMP\/unpacked"/);
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

test('prefetch skips only ZIP; remote checksum and SHA comparison remain mandatory', () => {
  assert.match(install, /if \[\[ -n "\$\{TATWO_OS_PREFETCHED_ZIP:-\}" \]\]; then/);
  assert.match(install, /\[\[ -f "\$TATWO_OS_PREFETCHED_ZIP" \]\] \|\| fail/);
  assert.match(install, /ZIP="\$TATWO_OS_PREFETCHED_ZIP"\nelse\n  curl[^\n]*"\$ZIP" "\$ZIP_URL"\nfi/);
  assert.match(install, /fi\ncurl[^\n]*"\$TEMP\/TATWO-OS\.zip\.sha256" "\$SHA_URL"/);
  assert.match(install, /ACTUAL="\$\(shasum -a 256 "\$ZIP"\)"/);
  assert.match(install, /\[\[ "\$ACTUAL" == "\$EXPECTED" \]\] \|\| fail/);
  assert.match(install, /unzip -Z1 "\$ZIP"/);
});

test('real installer download/checksum block accepts cache, rejects tampering and preserves terminal download', () => {
  // Execute the exact transport/integrity slice; never enter /Applications or signing/replacement.
  const block = install.slice(install.indexOf('ZIP="$TEMP/TATWO-OS.zip"'), install.indexOf("printf '校驗成功"));
  for (const mode of ['prefetched', 'tampered', 'terminal', 'missing']) {
    const dir = mkdtempSync(join(tmpdir(), 'w16-install-'));
    const cached = join(dir, "cached app's.zip");
    const bytes = Buffer.from('W16 trusted archive fixture');
    const digest = createHash('sha256').update(bytes).digest('hex');
    if (mode !== 'missing') writeFileSync(cached, mode === 'tampered' ? 'bad ZIP' : bytes);
    const script = `
      set -euo pipefail
      fail() { echo "$1" >&2; exit 1; }
      curl() {
        local output="" url=""
        while [ "$#" -gt 0 ]; do
          case "$1" in -o) shift; output="$1";; https:*) url="$1";; esac
          shift
        done
        echo "$url"
        case "$url" in
          *.sha256) printf '%s  TATWO-OS.zip\\n' "$FIXTURE_SHA" > "$output";;
          *) cp "$FIXTURE_ZIP" "$output";;
        esac
      }
      ${block}
    `;
    const result = spawnSync('bash', ['-c', script], { encoding: 'utf8', env: {
      ...process.env, TEMP: dir, FIXTURE_ZIP: cached, FIXTURE_SHA: digest,
      ZIP_URL: 'https://fixture.invalid/TATWO-OS.zip',
      SHA_URL: 'https://fixture.invalid/TATWO-OS.zip.sha256',
      TATWO_OS_PREFETCHED_ZIP: mode === 'terminal' ? '' : cached,
    } });
    assert.equal(result.status, ['tampered', 'missing'].includes(mode) ? 1 : 0, result.stderr);
    const calls = result.stdout.trim().split('\n').filter(Boolean);
    assert.equal(calls.filter(url => url.endsWith('.sha256')).length, mode === 'missing' ? 0 : 1);
    assert.equal(calls.filter(url => url.endsWith('.zip')).length, mode === 'terminal' ? 1 : 0);
    if (mode === 'tampered') assert.match(result.stderr, /SHA-256 不符/);
  }
});
