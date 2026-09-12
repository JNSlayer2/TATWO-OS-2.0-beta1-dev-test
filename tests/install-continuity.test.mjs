import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, writeFileSync, mkdirSync, copyFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const install = readFileSync(new URL('../install.sh', import.meta.url), 'utf8');
const transport = install.split('# DOWNLOAD-RETRY-BEGIN\n')[1].split('# DOWNLOAD-RETRY-END')[0];
const publicInstall = readFileSync(new URL('../public/install.sh', import.meta.url), 'utf8');

test('install.sh and public/install.sh stay byte-identical', () => {
  assert.equal(install, publicInstall);
});

test('W22 production selection falls through delta, layer, then full without replacing installed App', () => {
  const selection = install.slice(install.indexOf('SOURCE="$TEMP/split/TATWO OS.app"'), install.indexOf('# Do not silently'));
  for (const [delta, layer, expected] of [[0, 0, 'delta'], [1, 0, 'delta layer'], [1, 1, 'delta layer full']]) {
    const temp = mkdtempSync(join(tmpdir(), 'w22-order-'));
    const result = spawnSync('bash', ['-c', `set -eu; TEMP=${JSON.stringify(temp)}; APP_URL=yes; STAGE="$TEMP/stage"
      TATWO_OS_PREFETCHED_DELTA_ZIP=yes; TATWO_OS_PREFETCHED_MANIFEST=yes
      assemble_delta() { echo delta >> "$TEMP/order"; return ${delta}; }
      assemble_runtime() { echo layer >> "$TEMP/order"; return ${layer}; }
      download_full() { echo full >> "$TEMP/order"; }; verify_signed_app() { :; }
      ${selection.replace('/Applications/.tatwo-update.XXXXXX', `${temp}/stage.XXXXXX`)}`], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(readFileSync(join(temp, 'order'), 'utf8').trim().replaceAll('\n', ' '), expected);
  }
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
  assert.doesNotMatch(pkg, /xattr -cr/);
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
  assert.match(install, /ditto "\$TATWO_OS_PREFETCHED_ZIP" "\$ZIP"\nelse\n  retry_download "\$ZIP" "\$ZIP_URL"\nfi/);
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
      ${transport}
      printf '%s  TATWO-OS.zip\\n' "$FIXTURE_SHA" > "$TEMP/install-ready"
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
  const functions = transport + install.slice(install.indexOf('download_full() {'), install.indexOf('# RUNTIME-ASSEMBLY-END'));
  const selection = install.slice(install.indexOf('SOURCE="$TEMP/split/TATWO OS.app"'),
    install.indexOf('# Do not silently move development copies')).replace('/Applications/.tatwo-update.XXXXXX', '$TEMP/stage.XXXXXX');
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
    writeFileSync(join(temp, 'install-ready'), readdirSync(assets).filter(n => n.endsWith('.zip')).map(n => createHash('sha256').update(readFileSync(join(assets,n))).digest('hex') + '  ' + n + '\n').join(''));
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
      TATWO_OS_PREFETCHED_ZIP: '', TATWO_OS_PREFETCHED_DELTA_ZIP: '', TATWO_OS_PREFETCHED_MANIFEST: '',
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

test('W26 curl 18 re-invokes curl and resumes from existing bytes on second attempt', () => {
  const dir = mkdtempSync(join(tmpdir(), 'w26-resume-'));
  const r = spawnSync('bash', ['-c', `set -eu
    ${transport}
    sleep() { :; }
    curl() {
      local output=""; while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; output="$1"; fi; shift; done
      if [ ! -f "$output" ]; then printf 'partial' > "$output"; return 18; fi
      printf '%s' "$(wc -c < "$output" | tr -d ' ')" > "$TEMP/offset"
      printf 'rest' >> "$output"
    }
    retry_download "$TEMP/archive" https://fixture.invalid/archive
  `], {encoding:'utf8', env:{...process.env, TEMP:dir}});
  assert.equal(r.status,0,r.stderr);
  assert.equal(readFileSync(join(dir,'offset'),'utf8'),'7');
  assert.equal(readFileSync(join(dir,'archive'),'utf8'),'partialrest');
  assert.match(transport, /-C - .*--max-time 3600 .*--speed-limit 1024 --speed-time 60/);
  assert.doesNotMatch(transport, /--retry/);
  assert.match(install, /retry_download "\$ZIP" "\$ZIP_URL"/);
  assert.match(install, /retry_download "\$output" "\$url"/);
});

test('W26 install-ready requires one matching candidate hash; legacy name-only marker binds via .sha256 instead', () => {
  const dir = mkdtempSync(join(tmpdir(),'w26-ready-')), hash = 'a'.repeat(64);
  for (const [content, ok] of [[`${hash}  file.zip\n`, true], ['ready', true], [`${'b'.repeat(64)}  file.zip`, false], [`${hash}  file.zip\n${hash}  file.zip`, false]]) {
    writeFileSync(join(dir,'install-ready'),content);
    const legacy = /^[0-9a-f]{64}  /m.test(content) ? '0' : '1';
    const r=spawnSync('bash',['-c',`${transport}\nLEGACY_READY=${legacy}\nready_matches file.zip ${hash}`],{env:{...process.env,TEMP:dir}});
    assert.equal(r.status,ok?0:1);
  }
});

test('W26 persisted transactions restore interrupted rename and leave live/committed runs alone', () => {
  const functions=install.split('# TRANSACTION-BEGIN\n')[1].split('# TRANSACTION-END')[0];
  for(const [phase,owner,restore] of [['replacing','99999999',true],['prepared','99999999',true],['committed','99999999',false],['replacing',String(process.pid),false]]) {
    const dir=mkdtempSync(join(tmpdir(),'w26-reconcile-')), dest=join(dir,'TATWO OS.app'), stage=join(dir,'.tatwo-update.fixture.noindex');
    mkdirSync(stage); mkdirSync(dest+'.old'); writeFileSync(join(dest+'.old','intact'),'old');
    writeFileSync(join(stage,'transaction.json'), JSON.stringify({phase,owner,backup:dest+'.old'}));
    const r=spawnSync('bash',['-c',`set -eu\n${functions}\nreconcile_transactions`],{encoding:'utf8',env:{...process.env,DEST:dest}});
    assert.equal(r.status,0,r.stderr); assert.equal(existsSync(dest),restore);
    if(restore) {
      assert.equal(readFileSync(join(dest,'intact'),'utf8'),'old');
      assert.equal(JSON.parse(readFileSync(join(stage,'transaction.json'))).phase,'recovered');
      assert.equal(JSON.parse(readFileSync(join(stage,'result.json'))).message,'interrupted_restored');
    }
  }
  assert.match(install,/mv "\$STAGE\/TATWO OS.app" "\$DEST.new"/);
  assert.match(install,/mv "\$DEST" "\$DEST.old"; fi\nmv "\$DEST.new" "\$DEST"/);
  assert.ok(install.indexOf('write_transaction replacing') < install.indexOf('mv "$DEST" "$DEST.old"'));
});

test('W25 production version binding: equality mandatory, downgrade opt-in never bypasses binding', () => {
  const functions = install.split('# VERSION-BINDING-BEGIN\n')[1].split('# VERSION-BINDING-END')[0];
  const dir = mkdtempSync(join(tmpdir(), 'w25-binding-'));
  const app = (name, version) => {
    const path = join(dir,name); mkdirSync(join(path,'Contents'),{recursive:true});
    writeFileSync(join(path,'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`);
    return path;
  };
  for(const [old,next,tag,override,ok] of [
    ['2.0.5','2.0.5.001','v2.0.5.001','',true],
    ['2.0.5.001','2.0.5.002','v2.0.5.002','',true],
    ['2.0.5.999','2.0.6','v2.0.6','',true],
    ['2.0.5.010','2.0.5.002','v2.0.5.002','',false],
    ['2.0.6','2.0.5.999','v2.0.5.999','',false],
    ['2.0.6','2.0.5.999','v2.0.5.999','1',true],
    ['2.0.5','2.0.5.001','v2.0.6','1',false],
    ['invalid','2.0.6','v2.0.6','',false],
    ['2.0','2.0.0','v2.0.0','',true],
  ]) {
    const result=spawnSync('bash',['-c',`set -euo pipefail\nfail() { echo "$1" >&2; exit 1; }\n${functions}\nverify_version_binding "$CANDIDATE"`],{
      encoding:'utf8',env:{...process.env,DEST:app('old',old),CANDIDATE:app('new',next),TAG:tag,TATWO_OS_ALLOW_DOWNGRADE:override}
    });
    assert.equal(result.status,ok?0:1,`${old} -> ${next}: ${result.stderr}`);
  }
  assert.match(install,/verify_version_binding "\$SOURCE"/);
  assert.match(install,/verify_version_binding "\$STAGE\/TATWO OS.app"/);
  assert.match(readFileSync(new URL('../scripts/install-private.sh',import.meta.url),'utf8'),/source "\$PRIVATE_WORK\/install.sh"/);
});

test('W26 SIGKILL inside production rename window is recovered by the next installer', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-kill-')), dest=join(dir,'TATWO OS.app'), stage=join(dir,'.tatwo-update.fixture.noindex');
  mkdirSync(stage); mkdirSync(dest); writeFileSync(join(dest,'intact'),'old');
  const candidate=join(stage,'TATWO OS.app'); mkdirSync(candidate); writeFileSync(join(candidate,'intact'),'new');
  writeFileSync(join(dir,'install-ready'),'a'.repeat(64)+'  TATWO-OS.zip\n');
  const functions=install.split('# TRANSACTION-BEGIN\n')[1].split('# TRANSACTION-END')[0];
  const replace=install.slice(install.indexOf('# Staging and destination'), install.indexOf('verify_signed_app "$DEST"'));
  const env={...process.env,DEST:dest,STAGE:stage,TEMP:dir,TAG:'v2.0.6',REPO:'fixture/repo'};
  let r=spawnSync('bash',['-c',`set -eu
    ${functions}
    fail() { echo "$1" >&2; exit 1; }
    mv() { command mv "$@"; if [[ "$1" == "$DEST" && "$2" == "$DEST.old" ]]; then kill -KILL $$; fi; }
    ${replace}`],{encoding:'utf8',env});
  assert.equal(r.signal,'SIGKILL',r.stderr);
  assert.ok(!existsSync(dest)); assert.ok(existsSync(dest+'.old')); assert.ok(existsSync(dest+'.new'));
  assert.equal(JSON.parse(readFileSync(join(stage,'transaction.json'))).phase,'replacing');
  r=spawnSync('bash',['-c',`set -eu\n${functions}\nreconcile_transactions`],{encoding:'utf8',env});
  assert.equal(r.status,0,r.stderr); assert.equal(readFileSync(join(dest,'intact'),'utf8'),'old');
  assert.ok(!existsSync(dest+'.new')); assert.ok(existsSync(join(stage,'interrupted-new.app.disabled')));
});

test('W26 24-hour cleanup trashes only stale owned temp directories and writes restore manifest', () => {
  const dir=mkdtempSync(join(tmpdir(),'w26-retention-'));
  for(const name of ['tatwo-install.old','tatwo-install.active','tatwo-install.fresh','keep-other']) mkdirSync(join(dir,name));
  writeFileSync(join(dir,'tatwo-install.active/owner'),String(process.pid));
  for(const name of ['tatwo-install.old','tatwo-install.active','keep-other']) {
    assert.equal(spawnSync('touch',['-t','202001010000',join(dir,name)]).status,0);
  }
  const code=install.split('# TEMP-RETENTION-BEGIN\n')[1].split('# TEMP-RETENTION-END')[0];
  const r=spawnSync('bash',['-c',`set -eu
    trash() { command mv "$1" "$TMPDIR/retained-trash"; }
    ${code}
    archive_old_downloads`],{encoding:'utf8',env:{...process.env,TMPDIR:dir}});
  assert.equal(r.status,0,r.stderr); assert.ok(existsSync(join(dir,'retained-trash')));
  for(const name of ['tatwo-install.active','tatwo-install.fresh','keep-other']) assert.ok(existsSync(join(dir,name)));
  const manifest=readdirSync(dir).find(n=>n.endsWith('.md'));
  assert.match(readFileSync(join(dir,manifest),'utf8'),/Restore from macOS Trash/);
});
