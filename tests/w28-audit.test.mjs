// W28 characterization retained where out of scope; W29a repair assertions replace repaired defects.
// All writes stay in fresh fixture directories; retain them for inspection.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const installer = read('install.sh');
const transaction = installer.split('# TRANSACTION-BEGIN\n')[1].split('# TRANSACTION-END')[0];
function lockFixture(kind) {
  const root = mkdtempSync(join(tmpdir(), 'w28-lock-'));
  const lock = join(root, '.tatwo-update.lock'); mkdirSync(lock);
  if (kind !== 'ownerless') writeFileSync(join(lock, 'owner'), `${process.pid}\nnot-this-start\n`);
  if (kind === 'reconcile') { mkdirSync(join(lock, 'reconcile')); spawnSync('touch', ['-t', '202001010000', join(lock, 'reconcile')]); }
  if (kind === 'ownerless') spawnSync('touch', ['-t', '202001010000', lock]);
  const result = spawnSync('/bin/bash', ['-c', `set -eu
DEST="$FIXTURE_ROOT/App.app"
fail() { printf '%s\\n' "$1"; exit 42; }
kill() { return ${kind === 'reused' ? '0' : '1'}; }
${transaction}
acquire_update_lock
`], { encoding: 'utf8', env: { ...process.env, FIXTURE_ROOT: root } });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.ok(existsSync(lock));
  return result.stdout;
}
test('GPT-01 aged ownerless mkdir interruption is recoverable', () => {
  lockFixture('ownerless');
});
test('GPT-01 aged interrupted reconciliation guard permits later takeover', () => {
  lockFixture('reconcile');
});
test('GPT-02 PID plus start time rejects reused owner (liveness double)', () => {
  lockFixture('reused');
});
function swift(source) {
  const root = mkdtempSync(join(tmpdir(), 'w28-swift-'));
  writeFileSync(join(root, 'main.swift'), source);
  const build = spawnSync('swiftc', [join(root, 'main.swift'), '-o', join(root, 'fixture')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(root, 'fixture'), [], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  return run.stdout;
}
test('GPT-03 / OPUS-04 production peer cache validator accepts repository-scoped writer path', () => {
  const peer = read('App/Sources/Tatwo2/Facade/PeerUpdateSource.swift');
  const method = peer.slice(peer.indexOf('    static func cachePath('), peer.indexOf('    // Candidate bytes'));
  const result = swift(`import Foundation
struct Peer {
static let relativeRoot = "Library/Application Support/TATWO OS/Updater"
${method}
}
let base = "/Users/fixture/Library/Application Support/TATWO OS/Updater/download/"
print(Peer.cachePath(base + "v2.0.6/TATWO-OS-app.zip", tag: "v2.0.6", name: "TATWO-OS-app.zip"))
print(Peer.cachePath(base + "sample/project/v2.0.6/TATWO-OS-app.zip", tag: "v2.0.6", name: "TATWO-OS-app.zip"))
`);
  assert.equal(result.trim(), 'false\ntrue');
});
test('plan production parser handles complete/incomplete/multiple and nested fences', () => {
  const src = read('App/Sources/Tatwo2/Chat/TatwoPlanArtifact.swift');
  const methods = src.slice(src.indexOf('  public static func parseSections('), src.indexOf('  /// Converts one completed model response'));
  const cases = [
    ['```tatwo-plan\n## 做什麼\na\n```', 'a'],
    ['```tatwo-plan\n## 做什麼\na', nilValue()],
    ['````text\n```tatwo-plan\n## 做什麼\na\n```\n````', nilValue()],
    ['```tatwo-plan\n## 做什麼\na\n```\n```tatwo-plan\n## 做什麼\nb\n```', 'b'],
    ['```tatwo-plan\n## 做什麼\na\n~~~swift\n## not heading\n~~~\n```', 'a\n~~~swift\n## not heading\n~~~']
  ];
  function nilValue() { return '<nil>'; }
  const checks = cases.map(([text, expected]) => `precondition((Plan.parseSections(fromReply: ${JSON.stringify(text)})?.first?.body ?? "<nil>") == ${JSON.stringify(expected)})`).join('\n');
  assert.match(swift(`import Foundation
public struct Plan {
public struct Section { public var title: String; public var body: String }
${methods}
}
${checks}
print("5 parser cases passed")`), /5 parser cases passed/);
});
test('legacy v2.0.1 through v2.0.5 metadata exercises actual size/marker branches (not full install)', () => {
  const sizing = installer.slice(installer.indexOf('if [[ "$RELEASE_HAS_MANIFEST" == 1 ]]'), installer.indexOf('check_space "$(dirname "$DEST")" "$CANDIDATE_BYTES"'));
  const marker = installer.slice(installer.indexOf('LEGACY_READY=0'), installer.indexOf('curl --proto', installer.indexOf('LEGACY_READY=0')));
  for (const tag of ['v2.0.1', 'v2.0.2', 'v2.0.3', 'v2.0.4', 'v2.0.5']) {
    const root = mkdtempSync(join(tmpdir(), 'w28-legacy-'));
    writeFileSync(join(root, 'install-ready'), 'ready\n');
    const run = spawnSync('bash', ['-c', `set -eu
TEMP="$FIXTURE_ROOT"; TAG="$FIXTURE_TAG"; RELEASE_HAS_MANIFEST=0; ZIP_SIZE=1024
fail() { exit 42; }
${marker}
${sizing}
printf '%s:%s:%s' "$TAG" "$LEGACY_READY" "$CANDIDATE_BYTES"
`], { encoding: 'utf8', env: { ...process.env, FIXTURE_ROOT: root, FIXTURE_TAG: tag } });
    assert.equal(run.status, 0, run.stderr);
    assert.equal(run.stdout, `${tag}:1:4096`);
  }
});

test('OPUS-07/08 actual Swift preset: Grok arguments coincide; bot configFile inherits user (W29b regression)', () => {
  const source = read('App/Sources/Tatwo2/Chat/TatwoPermissionPreset.swift');
  assert.equal(swift(`${source}
public enum TatwoCodexSandboxMode {
  case readOnly, workspaceWrite, dangerFullAccess
  public var codexArguments: [String] { [] } // Not exercised.
}
precondition(TatwoPermissionPreset.approveForMe.grokArguments == TatwoPermissionPreset.fullAccess.grokArguments)
for legacy in [false, true] {
  precondition(TatwoPermissionPreset.resolvedSidecarMode(user: .fullAccess, bot: .configFile, readOnly: false, legacyCodexAutoApprove: legacy) == "bypassPermissions")
}
precondition(TatwoPermissionPreset.resolvedSidecarMode(user: .fullAccess, bot: nil, readOnly: false, legacyCodexAutoApprove: false) == "bypassPermissions")
precondition(TatwoPermissionPreset.resolvedSidecarMode(user: .fullAccess, bot: .configFile, readOnly: true, legacyCodexAutoApprove: true) == "readOnly")
print("same Grok argv; user fullAccess for both legacy values; user-only and readOnly controls passed")
`).trim(), 'same Grok argv; user fullAccess for both legacy values; user-only and readOnly controls passed');
});

test('OPUS-03 actual publisher archive differs from ditto for this ordinary local tree', () => {
  const root = mkdtempSync(join(tmpdir(), 'w28-archive-'));
  const run = spawnSync('python3', ['-c', `
import importlib.util, pathlib, subprocess, sys, zipfile
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("layer", sys.argv[2])
layer = importlib.util.module_from_spec(spec); spec.loader.exec_module(layer)
tree = root / "runtime"; tree.mkdir()
(tree / "fixture.txt").write_text("runtime fixture\\n" * 100)
layer.archive(tree, root / "publisher.zip")
subprocess.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", str(tree), str(root / "peer.zip")], check=True)
assert (root / "publisher.zip").read_bytes() != (root / "peer.zip").read_bytes()
with zipfile.ZipFile(root / "publisher.zip") as a, zipfile.ZipFile(root / "peer.zip") as b:
    assert a.read("fixture.txt") == b.read("fixture.txt")
    assert a.getinfo("fixture.txt").date_time == (1980,1,1,0,0,0)
print("same payload, different archive bytes (fixture only)")
`, root, new URL('../scripts/runtime-layer.py', import.meta.url).pathname],
  { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }, timeout: 30000 });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /same payload, different archive bytes/);
});

test('OPUS-26 CPython ZipInfo open/writestr inherit no archive-level compression setting', () => {
  const run = spawnSync('python3', ['-c', `
import io, json, random, sys, zipfile
rng = random.Random(28)
data = b"".join(bytes([rng.randrange(32,127)]) * rng.randrange(1,150) for _ in range(10000))
def archive(method, level, explicit=None):
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=level) as z:
        info = zipfile.ZipInfo("fixture.txt")
        info.compress_type = zipfile.ZIP_DEFLATED
        if explicit is not None: info._compresslevel = explicit
        if method == "open":
            with z.open(info, "w") as f: f.write(data)
        else: z.writestr(info, data)
    return out.getvalue()
assert archive("open",1) == archive("open",9) == archive("open",6,6)
assert archive("open",9) != archive("open",9,9)
assert archive("writestr",1) == archive("writestr",9) == archive("open",9)
assert archive("writestr",9,9) == archive("open",9,9)
assert archive("open",9) == archive("open",9)
print(json.dumps({"python":sys.version.split()[0], "implicitBytes":len(archive("open",9)), "explicit9Bytes":len(archive("open",9,9)), "writestrZipInfoAlsoIgnoresLevel":True}))
`], { encoding: 'utf8', timeout: 30000 });
  assert.equal(run.status, 0, run.stderr);
  const evidence = JSON.parse(run.stdout);
  assert.notEqual(evidence.implicitBytes, evidence.explicit9Bytes);
  assert.equal(evidence.writestrZipInfoAlsoIgnoresLevel, true);
});

test('OPUS-35 actual receipt writer normalizes nonnumeric installSeconds to zero', () => {
  const source = read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
  const start = source.indexOf('        write_result() {');
  const writer = source.slice(start, source.indexOf('        abnormal_exit()', start)).replaceAll('\\\\', '\\');
  assert.ok(writer.includes('cat "$TATWO_OS_TIMING_FILE"'));
  for (const [value, valid] of [['not-a-number', true], ['null', true], ['12', true], ['00012', true]]) {
    const root = mkdtempSync(join(tmpdir(), 'w28-receipt-'));
    writeFileSync(join(root, 'seconds'), value);
    const run = spawnSync('/bin/bash', ['-c', `set -eu
RESULT="$FIXTURE_ROOT/result.json"
TATWO_OS_TIMING_FILE="$FIXTURE_ROOT/seconds"
TAG=v2.0.6; RUN_ID=00000000-0000-4000-8000-000000000028; START_SECONDS=0
${writer}
write_result true installed
`], { encoding: 'utf8', env: { ...process.env, FIXTURE_ROOT: root } });
    assert.equal(run.status, 0, run.stderr);
    const json = readFileSync(join(root, 'result.json'), 'utf8');
    assert.equal(JSON.parse(json).installSeconds, /^[0-9]+$/.test(value) ? Number(value) : 0);
    assert.equal(swift(`import Foundation
let parsed = try? JSONSerialization.jsonObject(with: Data(${JSON.stringify(json)}.utf8))
print(parsed != nil)
`).trim(), String(valid));
  }
  // Static consumer linkage only; not a whole-app ACK/lifecycle reproduction.
  assert.match(source, /for result in records\("results"\)\.prefix\(1\)/);
  assert.match(source, /object\["runID"\] as\? String == id else \{ continue \}/);
});

// W29a repair gates run with the requested W28 suite.
import "./w29a-update-fixes.test.mjs";
