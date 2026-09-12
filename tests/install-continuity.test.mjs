import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, writeFileSync, mkdirSync, copyFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

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

test('W20 real assembly: local reuse, runtime fetch/cache, old release and sealed fallback', () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const dir = mkdtempSync(join(tmpdir(), 'w20-install-'));
  const app = join(dir, 'TATWO OS.app'), contents = join(app, 'Contents');
  const paths = readFileSync(join(root, 'scripts/runtime-layer.txt'), 'utf8').trim().split('\n');
  const run = (cmd, args) => {
    const result = spawnSync(cmd, args, { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  for (const path of paths) {
    mkdirSync(join(contents, path, ...(path.startsWith('Frameworks/') ? ['Resources'] : [])), { recursive: true });
    writeFileSync(join(contents, path, path.startsWith('Frameworks/') ? 'Resources/fixture.txt' : 'fixture'), `runtime ${path}`);
  }
  const framework = join(contents, 'Frameworks/Chromium Embedded Framework.framework');
  mkdirSync(join(framework, 'Resources'), { recursive: true });
  copyFileSync('/usr/bin/true', join(framework, 'RuntimeExecutable'));
  writeFileSync(join(framework, 'Resources/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>example.fixture.runtime</string>
    <key>CFBundleExecutable</key><string>RuntimeExecutable</string>
    <key>CFBundlePackageType</key><string>FMWK</string></dict></plist>`);
  run('codesign', ['--force', '--sign', '-', framework]);
  mkdirSync(join(contents, 'MacOS'));
  copyFileSync('/usr/bin/true', join(contents, 'MacOS/tatwo2'));
  writeFileSync(join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string>
    <key>CFBundleExecutable</key><string>tatwo2</string>
    <key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  run('bash', [join(root, 'scripts/runtime-layer.sh'), 'prepare', app]);
  run('codesign', ['--force', '--sign', '-', '--requirements', '=designated => identifier "ai.tatwo.tatwo2"', app]);
  const assets = join(dir, 'assets');
  run('bash', [join(root, 'scripts/runtime-layer.sh'), 'split', app, assets]);
  run('ditto', ['-c', '-k', '--norsrc', '--keepParent', app, join(assets, 'TATWO-OS.zip')]);
  writeFileSync(join(assets, 'TATWO-OS.zip.sha256'),
    createHash('sha256').update(readFileSync(join(assets, 'TATWO-OS.zip'))).digest('hex') + '  TATWO-OS.zip\n');
  const runtimeName = readdirSync(assets).find(n => /^TATWO-OS-runtime-.*\.zip$/.test(n));
  const repo = 'fixture/repo', base = `https://github.com/${repo}/releases/download/v9.9.9`;
  const functions = install.slice(install.indexOf('download_full() {'), install.indexOf('# RUNTIME-ASSEMBLY-END'));
  const selection = install.slice(install.indexOf('SOURCE="$TEMP/split/TATWO OS.app"'),
    install.indexOf('# Do not silently move development copies'));
  for (const mode of ['reuse', 'changed', 'cached', 'missing', 'corrupt', 'old-release', 'bad-prefetch', 'no-runtime-asset']) {
    const temp = join(dir, mode), dest = join(temp, 'installed.app');
    mkdirSync(temp);
    run('ditto', [app, dest]);
    if (['changed', 'cached'].includes(mode)) {
      writeFileSync(join(dest, 'Contents', paths[0], 'fixture'), 'older valid runtime');
      run('bash', [join(root, 'scripts/runtime-layer.sh'), 'prepare', dest]);
      run('codesign', ['--force', '--sign', '-', '--requirements', '=designated => identifier "ai.tatwo.tatwo2"', dest]);
    }
    if (mode === 'missing') {
      // Move, never delete, the fixture runtime to simulate a missing local cache.
      run('mv', [join(dest, 'Contents', paths[0]), join(temp, 'retained-runtime')]);
    }
    if (mode === 'corrupt') writeFileSync(join(dest, 'Contents', paths[0], 'fixture'), 'corrupted local cache');
    writeFileSync(join(temp, 'release.json'), JSON.stringify({
      assets: readdirSync(assets).filter(n => n.endsWith('.zip') || n.endsWith('.sha256'))
        .map(name => ({ name, browser_download_url: `${base}/${name}` })),
    }));
    const result = spawnSync('bash', ['-c', `
      set -euo pipefail
      fail() { echo "$1" >&2; exit 1; }
      curl() {
        local output="" url=""
        while [ "$#" -gt 0 ]; do
          case "$1" in -o) shift; output="$1";; https:*) url="$1";; esac
          shift
        done
        echo "\${url##*/}" >> "$TEMP/download.calls"
        cp "$ASSETS/\${url##*/}" "$output"
      }
      codesign() {
        # Fixture-only identity presentation; verification/DR/-R use REAL codesign.
        if [[ "$1" == -dv ]]; then echo 'Authority=Fixture'; else /usr/bin/codesign "$@"; fi
      }
      ${functions}
      ${selection}
      printf '%s' "$SOURCE" > "$TEMP/selected"
    `], { encoding: 'utf8', env: {
      ...process.env, TEMP: temp, DEST: dest, ASSETS: assets, REPO: repo,
      ZIP_URL: `${base}/TATWO-OS.zip`, SHA_URL: `${base}/TATWO-OS.zip.sha256`,
      APP_URL: mode === 'old-release' ? '' : `${base}/TATWO-OS-app.zip`,
      RUNTIME_NAMES: mode === 'no-runtime-asset' ? ' ' : ` ${runtimeName} `,
      TATWO_OS_PREFETCHED_ZIP: '',
      TATWO_OS_PREFETCHED_APP_ZIP: mode === 'bad-prefetch' ? join(temp, 'missing.zip')
        : mode === 'cached' ? join(assets, 'TATWO-OS-app.zip') : '',
      TATWO_OS_PREFETCHED_RUNTIME_ZIP: mode === 'cached' ? join(assets, runtimeName) : '',
    } });
    assert.equal(result.status, 0, `${mode}: ${result.stderr}`);
    const calls = readFileSync(join(temp, 'download.calls'), 'utf8').trim().split('\n');
    const fallback = ['missing', 'corrupt', 'bad-prefetch', 'no-runtime-asset'].includes(mode);
    assert.equal(calls.filter(n => n === runtimeName).length, ['changed', 'missing'].includes(mode) ? 1 : 0, mode);
    assert.equal(calls.filter(n => n === `${runtimeName}.sha256`).length, ['changed', 'cached', 'missing'].includes(mode) ? 1 : 0, mode);
    assert.equal(calls.filter(n => n === 'TATWO-OS.zip').length, fallback || mode === 'old-release' ? 1 : 0, `${mode}: ${result.stderr}`);
    assert.equal(calls.filter(n => n === 'TATWO-OS-app.zip').length,
      ['cached', 'old-release', 'bad-prefetch'].includes(mode) ? 0 : 1, mode);
    if (fallback) assert.match(result.stderr, /執行環境層與簽章不符，改用完整下載/);
    const selected = readFileSync(join(temp, 'selected'), 'utf8');
    assert.ok(selected.includes(fallback || mode === 'old-release' ? '/unpacked/' : '/split/'), mode);
    run('codesign', ['--verify', '--deep', '--strict', selected]);
    assert.ok(existsSync(dest), 'installed app never replaced by the fixture');
  }
});

test('large archive downloads resume and retry on slow links (curl 92 seen on the room mini)', () => {
  const fresh = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
  const bigDownloads = fresh.split('\n').filter(line => line.includes('-o "$ZIP" "$ZIP_URL"') || line.includes('-o "$output" "$url"'));
  assert.equal(bigDownloads.length, 2);
  for (const line of bigDownloads) {
    assert.match(line, /--http1\.1/);
    assert.match(line, /-C - /);
    assert.match(line, /--retry 5 --retry-all-errors/);
  }
});
