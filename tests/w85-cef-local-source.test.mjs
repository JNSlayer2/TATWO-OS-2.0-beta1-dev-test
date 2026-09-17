import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const bundle = path.join(root, 'scripts/tatwo-cef-bundle.sh');
const builder = path.join(root, 'scripts/build-cef-proprietary.sh');
const pinPath = path.join(root, 'Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json');
const pin = JSON.parse(fs.readFileSync(pinPath, 'utf8'));
const mac = { skip: process.platform !== 'darwin' };
const sha = data => createHash('sha256').update(data).digest('hex');
const env = extra => ({
  ...process.env, TATWO2_CEF_LOCAL_ARCHIVE: '', TATWO2_CEF_LOCAL_SHA256: '', ...extra,
});

function fixture() {
  const dir = testScratch('w85-cef-');
  const archive = path.join(dir, 'synthetic local archive.tar.bz2');
  const bytes = Buffer.from('synthetic fixture, not a CEF binary\n');
  fs.writeFileSync(archive, bytes);
  return { dir, archive, digest: sha(bytes) };
}

function shell(f, command, extra = {}) {
  return spawnSync('bash', ['-c', `
    set -euo pipefail
    source "$1"
    STAMP=fixture; SHORT_TOKEN=synthetic
    tatwo_cef_initialize_runtime_configuration "$2/cache" "$3" true
    ${command}
  `, 'fixture', bundle, f.dir, pinPath], {
    cwd: root, encoding: 'utf8', timeout: 15000, env: env(extra),
  });
}

function success(result) {
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout.trim();
}

test('no local options preserves official source, SHA, cache and index receipt', mac, () => {
  const f = fixture();
  const output = success(shell(f, `
    validate_cef_distribution_pin
    printf '%s\\n' "$CEF_LOCAL_ARCHIVE" "$CEF_ARCHIVE_SHA256" "$CEF_ARCHIVE_PATH" "$CEF_INDEX_RECEIPT"
  `)).split('\n');
  assert.deepEqual(output, [
    pin.sha256, `${f.dir}/cache/vendor/cef/${pin.archive}`,
    `${f.dir}/cache/vendor/cef/index-verified-${pin.officialIndexSHA1}.receipt`,
  ]);
});

test('missing, malformed or mismatched local inputs retain official verification', mac, () => {
  const f = fixture();
  for (const extra of [
    { TATWO2_CEF_LOCAL_ARCHIVE: f.archive },
    { TATWO2_CEF_LOCAL_SHA256: f.digest },
    { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: 'not-a-hash' },
    { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: '0'.repeat(64) },
    { TATWO2_CEF_LOCAL_ARCHIVE: `${f.dir}/missing`, TATWO2_CEF_LOCAL_SHA256: f.digest },
  ]) {
    const result = shell(f, `
      validate_cef_distribution_pin
      test -z "$CEF_LOCAL_ARCHIVE"
      printf '%s' "$CEF_ARCHIVE_SHA256"
    `, extra);
    assert.equal(success(result), pin.sha256);
    assert.match(result.stderr, /using verified official source/);
  }
});

test('verified local copy is hash-isolated and receipt records real source', mac, () => {
  const f = fixture();
  const result = shell(f, `
    validate_cef_distribution_pin
    prepare_cef_local_archive
    write_cef_local_receipt
    test -z "$CEF_DOWNLOAD_TEMP"
    printf '%s\\n' "$CEF_ARCHIVE_PATH" "$CEF_INDEX_RECEIPT"
  `, { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: f.digest.toUpperCase() });
  const [cached, receiptPath] = success(result).split('\n');
  assert.equal(cached, `${f.dir}/cache/vendor/cef/local-${f.digest}/${pin.archive}`);
  assert.equal(sha(fs.readFileSync(cached)), f.digest);
  assert.equal(fs.existsSync(`${f.dir}/cache/vendor/cef/${pin.archive}`), false);
  const receipt = JSON.parse(fs.readFileSync(receiptPath, 'utf8'));
  assert.equal(receipt.sourceKind, 'local');
  assert.equal(receipt.sourcePath, fs.realpathSync(f.archive));
  assert.equal(receipt.archiveSHA256, f.digest);
  assert.equal(receipt.cefVersion, pin.cefVersion);
  assert.equal(receipt.officialIndexSHA1, undefined);
  // The local receipt can never masquerade as Spotify index verification.
  const checked = shell(f, 'cef_index_receipt_matches_pin "$CEF_INDEX_RECEIPT"', {
    TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: f.digest,
  });
  assert.notEqual(checked.status, 0);
});

test('source changed after validation is not promoted into the cache', mac, () => {
  const f = fixture();
  const result = shell(f, `
    printf 'changed synthetic fixture' > "$CEF_LOCAL_ARCHIVE"
    prepare_cef_local_archive
  `, { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: f.digest });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /changed while copying/);
  assert.equal(fs.existsSync(`${f.dir}/cache/vendor/cef/local-${f.digest}/${pin.archive}`), false);
});

test('local archives still pass through archive traversal/layout validation', mac, () => {
  const f = fixture();
  success(spawnSync('python3', ['-c', `
import sys, tarfile
with tarfile.open(sys.argv[1], "w:bz2") as archive:
    archive.addfile(tarfile.TarInfo("../escape"))
`, f.archive], { encoding: 'utf8' }));
  f.digest = sha(fs.readFileSync(f.archive));
  const result = shell(f, `
    prepare_cef_local_archive
    mkdir -p "$CEF_CACHE_ROOT/tmp/cef"
    validate_cef_archive_entries
  `, { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: f.digest });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unsafe traversal|escapes expected root/);
});

test('local cache rejects symlink directories, archives and preexisting temporary copies', mac, () => {
  for (const kind of ['directory', 'archive', 'temporary']) {
    const f = fixture();
    const result = shell(f, `
      mkdir -p "$2/outside" "$(dirname "$CEF_ARCHIVE_PATH")"
      printf 'untouched' > "$2/outside/sentinel"
      case "${kind}" in
        directory)
          rmdir "$(dirname "$CEF_ARCHIVE_PATH")"
          ln -s "$2/outside" "$(dirname "$CEF_ARCHIVE_PATH")" ;;
        archive)
          ln -s "$2/outside/sentinel" "$CEF_ARCHIVE_PATH" ;;
        temporary)
          ln -s "$2/outside/sentinel" "$CEF_ARCHIVE_PATH.part-$STAMP-$SHORT_TOKEN" ;;
      esac
      prepare_cef_local_archive
    `, { TATWO2_CEF_LOCAL_ARCHIVE: f.archive, TATWO2_CEF_LOCAL_SHA256: f.digest });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /symbolic link|temporary copy already exists/);
    assert.equal(fs.readFileSync(path.join(f.dir, 'outside/sentinel'), 'utf8'), 'untouched');
  }
});

test('self-build defaults to a pin-exact plan, without creating files or calling network/build tools', () => {
  const f = fixture();
  const bin = path.join(f.dir, 'bin');
  fs.mkdirSync(bin);
  for (const tool of ['curl', 'git', 'xcodebuild', 'ninja', 'tar']) {
    fs.writeFileSync(path.join(bin, tool), '#!/bin/sh\necho FORBIDDEN_SIDE_EFFECT >&2\nexit 99\n', { mode: 0o755 });
  }
  const result = spawnSync('bash', [builder, '/Volumes/Synthetic External/w85-output'], {
    cwd: root, encoding: 'utf8', timeout: 15000, env: env({ PATH: `${bin}:${process.env.PATH}` }),
  });
  const output = success(result);
  assert.match(output, /PLAN_ONLY/);
  assert.match(output, /120 GB/);
  assert.match(output, /6–12/);
  assert.ok(output.includes(`CEF=${pin.cefVersion}`));
  assert.ok(output.includes(pin.archive));
  assert.match(output, /--arm64-build/);
  assert.match(output, /--minimal-distrib-only/);
  assert.match(output, /--checkout=2384915/);
  assert.match(output, /proprietary_codecs=true ffmpeg_branding=Chrome is_official_build=true/);
  assert.doesNotMatch(result.stderr, /FORBIDDEN_SIDE_EFFECT/);
  assert.equal(fs.existsSync('/Volumes/Synthetic External/w85-output'), false);
});

test('builder refuses a system-disk output even in plan mode', () => {
  const result = spawnSync('bash', [builder, '/tmp/synthetic-cef-output'], {
    cwd: root, encoding: 'utf8', timeout: 15000, env: env(),
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /external volume/);
});

test('both scripts parse; diagnostics name common affected sites', () => {
  success(spawnSync('bash', ['-n', builder], { encoding: 'utf8' }));
  success(spawnSync('bash', ['-n', bundle], { encoding: 'utf8' }));
  assert.match(fs.readFileSync(path.join(root,
    'App/Sources/Tatwo2/Browser/Diagnostics/BrowserDiagnosticsReport.swift'), 'utf8'),
  /常見：X／Twitter、部分新聞站影片/);
});
