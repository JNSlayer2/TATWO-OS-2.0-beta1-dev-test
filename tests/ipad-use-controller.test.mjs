import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

const longSession = process.env.TATWO_IPAD_LONG_SESSION_TEST === '1';
test('native iPad USE validation and consent checks', { timeout: longSession ? 450_000 : 120_000 }, context => {
  if (process.platform !== 'darwin') {
    context.skip('macOS AppKit runtime required');
    return;
  }
  const output = path.join(root, 'output', 'ipad-use-tests');
  mkdirSync(output, { recursive: true });
  const scratch = mkdtempSync(path.join(output, 'native-'));
  try {
    const binary = path.join(scratch, 'checks');
    const source = path.join(scratch, 'checks.swift');
    writeFileSync(source, [
      'App/Sources/Tatwo2/New/IPadUseController.swift',
      'tests/fixtures/ipad-use-controller-checks.swift',
    ].map(file => readFileSync(path.join(root, file), 'utf8')).join('\n'));
    const build = spawnSync('bash', ['-c', `
set -e
test "$(sysctl -n kern.memorystatus_vm_pressure_level)" = 1
lock=$(bash scripts/tatwo-build-lock.sh acquire --timeout 45 --pid $$)
token=$(printf '%s\\n' "$lock" | sed -n 's/^token=//p')
trap 'TATWO_BUILD_LOCK_TOKEN="$token" bash scripts/tatwo-build-lock.sh release --pid $$ >/dev/null' EXIT
nice -n 10 swiftc -swift-version 5 -parse-as-library -num-threads 2 "$1" -o "$2"
`, 'bash', source, binary],
    { cwd: root, env: { ...process.env, TMPDIR: scratch }, encoding: 'utf8', timeout: 90_000 });
    assert.equal(build.status, 0, build.stderr || String(build.error));
    const run = spawnSync(binary, [], { encoding: 'utf8', timeout: longSession ? 330_000 : 15_000 });
    process.stdout.write(run.stdout);
    assert.equal(run.status, 0, run.stderr || String(run.error));
    assert.match(run.stdout, /RESULT tests=71 failed=0 skipped=0/);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
});
