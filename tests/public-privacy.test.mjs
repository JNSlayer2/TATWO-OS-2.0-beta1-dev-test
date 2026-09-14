import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test, { after } from 'node:test';

const repo = fileURLToPath(new URL('../', import.meta.url));
const scanner = join(repo, 'scripts/public-safety-scan.mjs');
const exportRoot = resolve(process.env.TATWO_PUBLIC_EXPORT_ROOT || '/tmp/pe-w61');
const scratch = mkdtempSync(join(tmpdir(), 'w61-privacy-'));
const env = { ...process.env };
delete env.TATWO_OS_IMAGE_SSH_HOST;
delete env.TATWO_PRIMARY_SSH_HOST;
delete env.MODEL_GATEWAY_LABEL;
const run = (command, args, options = {}) => spawnSync(command, args, {
  cwd: repo, encoding: 'utf8', timeout: 120_000, maxBuffer: 16 * 1024 * 1024, env, ...options,
});
const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const field = (key, value) => JSON.stringify({ [key]: value });
const ip = (...parts) => parts.join('.');

after(() => {
  writeFileSync(join(scratch, 'RESTORE.md'),
    `# W61 test fixture archive\nOriginal source: ${scratch}\nOnly generated scanner inputs and mocks; no user data. ` +
    'Safe to archive after the test run. Restore with Finder Trash Put Back. ' +
    'Permanent removal requires a different human or AI to approve.\n');
  const archived = run('trash', [scratch]);
  assert.equal(archived.status, 0, archived.stderr || archived.error?.message);
});

function scanFixture(text, { rel = 'fixture.txt', policy = '', untrustedPolicy = '' } = {}) {
  const dir = mkdtempSync(join(scratch, 'case-'));
  const tree = join(dir, 'tree');
  mkdirSync(join(tree, dirname(rel)), { recursive: true });
  writeFileSync(join(tree, rel), text);
  // Run the real scanner with a separate trusted sibling policy, not an import-only mock.
  copyFileSync(scanner, join(dir, 'public-safety-scan.mjs'));
  writeFileSync(join(dir, 'public-safety-allow.txt'), policy);
  if (untrustedPolicy) {
    mkdirSync(join(tree, 'scripts'), { recursive: true });
    writeFileSync(join(tree, 'scripts/public-safety-allow.txt'), untrustedPolicy);
  }
  return run(process.execPath, [join(dir, 'public-safety-scan.mjs'), tree]);
}

test('W61 exported tree passes safety scan and the exact personal-data grep', () => {
  // Create a missing export and refresh an existing one: a stale clean export
  // must not hide new private data in the source. The exporter preserves old output in Trash.
  const exported = run('bash', ['scripts/public-export.sh', exportRoot]);
  assert.equal(exported.status, 0, exported.stderr);
  assert.ok(existsSync(join(exportRoot, 'EXPORT-MANIFEST.txt')), 'not a public export');
  const scanned = run(process.execPath, [scanner, exportRoot]);
  assert.equal(scanned.status, 0, scanned.stderr);
  assert.match(scanned.stdout, /PUBLIC SAFETY SCAN PASS/);
  // Detector signatures are composed, so this shipped test does not reintroduce the data.
  const forbidden = [
    'chen' + 'yawei', 'layer' + '2', '192\\.' + '168\\.',
    'ssh-' + 'studio', 'JNS' + 'layer' + '2', ['m4', 'mac', 'mini', 'codex'].join('-'),
  ].join('|');
  const grep = run('grep', ['-rEl', forbidden, exportRoot]);
  assert.equal(grep.status, 1, `Expected grep exit 1 (zero hits), got ${grep.status}: ${grep.stdout}${grep.stderr}`);
  assert.equal(grep.stdout, '');
  assert.deepEqual(readFileSync(join(exportRoot, 'install.sh')), readFileSync(join(exportRoot, 'public/install.sh')));
});

test('W61 does not widen or rewrite any pre-existing allowlist entry', () => {
  const original = readFileSync(join(repo, 'scripts/public-safety-allow.txt'), 'utf8')
    .split('\n').slice(0, 62).join('\n') + '\n';
  assert.equal(createHash('sha256').update(original).digest('hex'),
    'e094ea2868a022926f82eaf1c1f9fed79a9e50548a91f8e5408678eb68874b1b');
});

test('macOS account paths and user/name fields reject non-generic names', () => {
  for (const text of [
    '/Users/' + 'fixture-person/config',
    field('user', 'fixture-person'), field('username', 'fixture-person'), field('USER', 'fixture-person'),
    field('name', 'fixture-person'), 'user: fixture-person', 'name: fixture-person',
  ]) {
    const result = scanFixture(text);
    assert.equal(result.status, 1, text);
    assert.match(result.stderr, /macos username/);
    assert.doesNotMatch(result.stderr, /fixture-person/);
  }
});

test('generic accounts and documentation/loopback addresses and example hosts pass', () => {
  const generic = ['example', 'demo', 'test', 'user', 'octocat', 'runner', 'ci', 'root', 'admin', 'fixture', 'sample'];
  const text = [
    ...generic.flatMap(value => ['/Users/' + value + '/file', field('user', value), field('name', value)]),
    '192.0.2.10', '198.51.100.10', '203.0.113.10', '127.0.0.1', '0.0.0.0', '::1',
    'example.local', 'device.example', 'localhost', 'example.' + ['tatwo214', 'com'].join('.'),
    field('host', ['m4', 'demo.example'].join('-')),
  ].join('\n');
  const result = scanFixture(text);
  assert.equal(result.status, 0, result.stderr);
});

test('private IPv4 ranges include boundaries and mapped IPv6, but not adjacent public ranges', () => {
  for (const address of [
    ip(10, 0, 0, 0), ip(10, 255, 255, 255), ip(172, 16, 0, 0), ip(172, 31, 255, 255),
    ip(192, 168, 0, 0), ip(192, 168, 255, 255),
  ]) {
    for (const text of [address, `http://[::ffff:${address}]/`]) {
      const result = scanFixture(text);
      assert.equal(result.status, 1);
      assert.match(result.stderr, /private ip/);
    }
  }
  const result = scanFixture([ip(172, 15, 0, 1), ip(172, 32, 0, 1), ip(10, 256, 0, 1)].join('\n'));
  assert.equal(result.status, 0, result.stderr);
});

test('named personal domains and SSH aliases are rejected', () => {
  for (const value of [['fixture-studio', 'local'].join('.'), ['fixture-studio', 'tatwo214', 'com'].join('.')]) {
    for (const host of [value, value + '.']) {
      const result = scanFixture(field('host', host));
      assert.equal(result.status, 1);
      assert.match(result.stderr, /personal hostname/);
    }
  }
  for (const value of [
    ['m4', 'demo', 'codex'].join('-'), ['owner', 'macbook'].join('-'),
    ['owner', 'mac', 'mini'].join('-'), ['studio', 'codex'].join('-'),
  ]) {
    for (const text of [field('host', value), `ssh ${value}`, `Host ${value}`, 'SSH_HOST="${TATWO_PRIMARY_SSH_HOST:-' + value + '}"']) {
      const result = scanFixture(text);
      assert.equal(result.status, 1, text);
      assert.match(result.stderr, /ssh host alias/);
    }
  }
});

test('all four new categories enforce exact file + regex and every value on a line', () => {
  const cases = [
    ['macos username', 'fixture-person', value => field('user', value), 'other-person'],
    ['private ip', ip(10, 23, 45, 67), value => value, ip(10, 23, 45, 68)],
    ['personal hostname', ['fixture', 'local'].join('.'), value => field('host', value), ['other', 'local'].join('.')],
    ['ssh host alias', ['m4', 'fixture', 'codex'].join('-'), value => field('host', value), ['m4', 'other', 'codex'].join('-')],
  ];
  for (const [label, value, render, other] of cases) {
    const policy = `fixture.txt | ${label} | Synthetic regression input | ^${escapeRegex(value)}$\n`;
    assert.equal(scanFixture(render(value), { policy }).status, 0, label);
    assert.equal(scanFixture(render(value), { policy, rel: 'other.txt' }).status, 1, label);
    assert.equal(scanFixture(`${render(value)} ${render(other)}`, { policy }).status, 1, label);
    assert.equal(scanFixture(render(value), { untrustedPolicy: policy }).status, 1, label);
    assert.equal(scanFixture(render(value), { policy: policy.replace('^', '') }).status, 1, label);
  }
});

test('legacy email, token and key detection remains enforced', () => {
  for (const value of ['fixture' + '@' + 'example.invalid', ['sk', 'fixturecredential'].join('-'),
    ['-----BEGIN ', 'PRIVATE KEY-----'].join('')]) {
    assert.equal(scanFixture(value).status, 1);
  }
});

test('SSH wrappers fail before any command or state write when host is unset or empty', () => {
  for (const script of ['tatwo-os-image.sh', 'tatwo-data-sync.sh', 'tatwo-skillet-md.sh']) {
    for (const values of [{}, { TATWO_PRIMARY_SSH_HOST: '', TATWO_OS_IMAGE_SSH_HOST: '' }]) {
      const result = run('bash', [join(repo, 'scripts', script), 'status'], { env: { ...env, ...values } });
      assert.equal(result.status, 2, result.stderr);
      assert.match(result.stderr, /請設定 TATWO_PRIMARY_SSH_HOST/);
    }
    const source = readFileSync(join(repo, 'scripts', script), 'utf8');
    const setup = source.slice(source.indexOf('SSH_HOST='), source.indexOf('\n', source.indexOf('exit 2; }')));
    for (const [primary, image, expected] of [
      ['primary.example', '', 'primary.example'], ['primary.example', 'image.example', 'image.example'],
    ]) {
      const result = run('bash', ['-c', `${setup}\nprintf '%s' "$SSH_HOST"`], {
        env: { ...env, TATWO_PRIMARY_SSH_HOST: primary, TATWO_OS_IMAGE_SSH_HOST: image },
      });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, expected);
    }
  }
});

test('gateway label discovery uses product default, explicit override, or unique legacy registration (read-only)', () => {
  const source = readFileSync(join(repo, 'scripts/tatwo-agent-authority-doctor.sh'), 'utf8');
  const resolver = source.slice(source.indexOf('resolve_gateway_label()'), source.indexOf('\nlabel="$(resolve_gateway_label)"'));
  for (const [registered, override, expected] of [
    ['', '', 'com.tatwo.codex-model-gateway'],
    ['com.demo.codex-model-gateway', '', 'com.demo.codex-model-gateway'],
    ['com.demo.codex-model-gateway\ncom.tatwo.codex-model-gateway', '', 'com.tatwo.codex-model-gateway'],
    ['com.demo.codex-model-gateway\ncom.fixture.codex-model-gateway', '', 'com.tatwo.codex-model-gateway'],
    ['com.demo.codex-model-gateway', 'com.example.codex-model-gateway', 'com.example.codex-model-gateway'],
  ]) {
    const result = run('bash', ['-c', `
      launchctl() { [ "$1" = list ] || exit 91; printf '%s\\n' "$REGISTERED" | awk 'NF {print "1 0 " $0}'; }
      ${resolver}
      resolve_gateway_label`], { env: { ...env, REGISTERED: registered, MODEL_GATEWAY_LABEL: override } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), expected);
  }
  const python = run('python3', ['-c', `
import os, runpy, subprocess
from unittest.mock import patch
m = runpy.run_path("scripts/tatwo-os-image.py")
resolve = m["gateway_label"]
with patch.dict(os.environ, {}, clear=True):
    for listed, expected in [
        ("", "com.tatwo.codex-model-gateway"),
        ("1 0 com.demo.codex-model-gateway", "com.demo.codex-model-gateway"),
        ("1 0 com.demo.codex-model-gateway\\n2 0 com.tatwo.codex-model-gateway", "com.tatwo.codex-model-gateway"),
    ]:
        with patch.object(subprocess, "check_output", return_value=listed):
            assert resolve() == expected
    with patch.object(subprocess, "check_output", return_value="1 0 com.demo.codex-model-gateway\\n2 0 com.fixture.codex-model-gateway"):
        try:
            resolve()
            raise AssertionError("ambiguous legacy registration accepted")
        except RuntimeError:
            pass
    with patch.dict(os.environ, {"MODEL_GATEWAY_LABEL": "com.example.codex-model-gateway"}):
        assert resolve() == "com.example.codex-model-gateway"
print("GATEWAY LABEL PASS")
`]);
  assert.equal(python.status, 0, python.stderr);
  assert.match(python.stdout, /GATEWAY LABEL PASS/);
});

test('public blocklist serialization preserves the original non-personal ad domain', () => {
  const list = JSON.parse(readFileSync(join(repo,
    'Apps/TatwoUltraworkMac/Sources/TatwoUltraworkMac/Resources/BrowserBlocklists/browser-host-deny-list.json'), 'utf8'));
  assert.ok(JSON.stringify(list).includes('go.play' + 'er2app.com'));
});

test('legacy V3 import directory discovery is local, unambiguous and prefers the new default', () => {
  const source = readFileSync(join(repo,
    'Packages/AISwitchProviders/Sources/AISwitchProviders/CodexV3ImportStore.swift'), 'utf8');
  const resolver = source.slice(source.indexOf('    static func defaultV3BaseURL('),
    source.indexOf('\n    public var importedRegistryURL'));
  assert.ok(resolver.includes('candidates.count == 1'));
  const input = join(scratch, 'V3Resolver.swift');
  const binary = join(scratch, 'v3-resolver');
  writeFileSync(input, `
import Foundation
struct Resolver {
${resolver}
}
let manager = FileManager.default
let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try manager.createDirectory(at: home, withIntermediateDirectories: true)
func makeStore(_ component: String) throws {
    let store = home.appendingPathComponent(component)
    try manager.createDirectory(at: store.appendingPathComponent("accounts"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: store.appendingPathComponent("registry.json"))
}
precondition(Resolver.defaultV3BaseURL(homeURL: home).lastPathComponent == ".codex-v3")
try makeStore(".jnsdemo")
precondition(Resolver.defaultV3BaseURL(homeURL: home).lastPathComponent == ".jnsdemo")
try makeStore(".jnsfixture")
precondition(Resolver.defaultV3BaseURL(homeURL: home).lastPathComponent == ".codex-v3")
try makeStore(".codex-v3")
precondition(Resolver.defaultV3BaseURL(homeURL: home).lastPathComponent == ".codex-v3")
print("V3 RESOLVER PASS")
`);
  const compiled = run('swiftc', [input, '-o', binary]);
  assert.equal(compiled.status, 0, compiled.stderr);
  const result = run(binary, [join(scratch, 'v3-home')]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /V3 RESOLVER PASS/);
});
