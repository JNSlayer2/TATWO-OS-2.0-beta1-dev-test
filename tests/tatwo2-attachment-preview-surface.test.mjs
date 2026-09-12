import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const repo = fileURLToPath(new URL('..', import.meta.url));

test('image preview presentation renders thumbnail, overlay and failure states without I/O wiring', { timeout: 120_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires AppKit');
  const sourcePath = 'App/Sources/Tatwo2/Chat/ChatAttachmentPreviewSurface.swift';
  const source = fs.readFileSync(path.join(repo, sourcePath), 'utf8');
  assert.doesNotMatch(source, /FileManager|contentsOfFile|URLSession|Process\(|Task\.detached/);
  const output = path.join(repo, 'output/lightweight-repair');
  fs.mkdirSync(output, { recursive: true });
  const scratch = fs.mkdtempSync(path.join(output, 'attachment-preview-ui.'));
  fs.writeFileSync(path.join(scratch, 'main.swift'), source + '\n' +
    fs.readFileSync(path.join(repo, 'tests/fixtures/attachment-preview-surface-checks.swift'), 'utf8'));
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
[[ "$(sysctl -n kern.memorystatus_vm_pressure_level)" == 1 ]] || exit 75
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 90 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun swiftc "$1" -o "$2"
`, 'attachment-preview-ui', path.join(scratch, 'main.swift'), path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 100_000, env: { ...process.env, TMPDIR: scratch },
  });
  fs.writeFileSync(path.join(scratch, 'build.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'checks'), [scratch], {
    cwd: scratch, encoding: 'utf8', timeout: 15_000,
    env: { HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin' },
  });
  fs.writeFileSync(path.join(scratch, 'run.log'), run.stdout + run.stderr);
  process.stdout.write(run.stdout);
  const hash = name => createHash('sha256').update(fs.readFileSync(path.join(scratch, name))).digest('hex');
  fs.writeFileSync(path.join(scratch, 'metadata.json'), JSON.stringify({
    surface: 'attachment thumbnail and image overlay (presentation only)',
    reference: ['截圖 2026-09-07 晚上11.17.02.png', '截圖 2026-09-07 晚上11.17.07.png'],
    referenceScope: 'User confirmed thumbnail and expanded presentation only; image content is irrelevant.',
    timestamp: new Date().toISOString(), sourcePath,
    sourceSHA256: createHash('sha256').update(source).digest('hex'),
    images: Object.fromEntries(fs.readdirSync(scratch).filter(name => name.endsWith('.png')).map(name => [name, hash(name)])),
    productionWiring: false,
  }, null, 2));
  process.stdout.write(`PREVIEW_DIRECTORY ${scratch}\n`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
