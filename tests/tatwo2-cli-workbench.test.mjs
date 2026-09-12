import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
const files = [
  'App/Sources/Tatwo2/CLI/CLIWorkbenchLayout.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchPresentation.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchTheme.swift',
  'App/Sources/Tatwo2/CLI/CLIWorkbenchSurface.swift',
  'App/Sources/Tatwo2/Fixture/CLIWorkbenchFixture.swift',
];
const read = name => fs.readFileSync(path.join(repo, name), 'utf8');

test('CLI workbench presentation has one action seam and no runtime or store dependency', () => {
  for (const name of files) {
    assert.doesNotMatch(read(name), /import SwiftTerm|Process\(|FileManager|UserDefaults|URLSession|forkpty|ProcessInfo|cliSessionsStore/,
      name);
  }
  const view = read(files[3]);
  assert.match(view, /let send: \(CLIWorkbenchAction\) -> Void/);
  assert.match(view, /@ViewBuilder let terminal:/);
  assert.doesNotMatch(view, /frame\(maxWidth: 700\)|height: (300|600)|CLISolidCard/);
  assert.match(view, /allowsHitTesting\(placement.isVisible\)/);
  assert.match(view, /accessibilityHidden\(!placement.isVisible\)/);
  assert.match(view, /CLIWorkbenchMetrics.dividerHit|CLIWorkbenchDividerHandle/);
  assert.match(read(files[1]), /deleteToLineStart = false/);
  assert.match(read(files[1]), /deletePreviousWord = false/);
  const rail = view.slice(view.indexOf('struct CLIWorkbenchSessionRows'));
  assert.match(rail, /ForEach\(tabs\)/);
  assert.match(rail, /send\(\.selectTab\(tab.id\)\)/);
  assert.match(rail, /historyExpanded = false/);
  assert.match(rail, /if historyExpanded/);
  assert.doesNotMatch(rail, /Text\(pane.statusLabel\)|工作台窗格/);
});

test('CLI workbench native fixture: layout, actions and fixed visual set', { timeout: 180_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('native fixture requires macOS');
  if (process.env.TATWO_CLI_UI_RENDER !== '1') return t.skip('opt-in native UI compile; run with TATWO_CLI_UI_RENDER=1');
  const pressure = spawnSync('/usr/sbin/sysctl', ['-n', 'kern.memorystatus_vm_pressure_level'], { encoding: 'utf8' });
  assert.equal(pressure.stdout.trim(), '1', 'RESOURCE_PAUSE: no fixture compile under RAM warning');
  const scratch = path.join(repo, 'output/seedmux-cli/native-fixture');
  fs.mkdirSync(scratch, { recursive: true }); // ONE reusable slot, no mkdtemp or extra App bundle.
  const inputs = [
    'App/Sources/Tatwo2/Visual/TatwoTheme.swift',
    'App/Sources/Tatwo2/Visual/LiquidGlassTokens.swift',
    ...files,
    'tests/fixtures/cli-workbench-checks.swift',
  ];
  const source = inputs.map(read).join('\n');
  fs.writeFileSync(path.join(scratch, 'main.swift'), source);
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
[[ "$(sysctl -n kern.memorystatus_vm_pressure_level)" == 1 ]] || exit 75
[[ "$(df -k / | tail -1 | awk '{print $4}')" -ge 10485760 ]] || exit 75
[[ "$(df -k . | tail -1 | awk '{print $4}')" -ge 20971520 ]] || exit 75
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 30 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun swiftc -j 2 -module-cache-path .build-sol/apple/ModuleCache.noindex "$1" -o "$2"
`, 'cli-workbench-fixture', path.join(scratch, 'main.swift'), path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 110_000,
    env: { ...process.env, TMPDIR: scratch },
  });
  fs.writeFileSync(path.join(scratch, 'build.log'), build.stdout + build.stderr);
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'checks'), [scratch], {
    cwd: scratch, encoding: 'utf8', timeout: 45_000,
    env: { HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin' },
  });
  fs.writeFileSync(path.join(scratch, 'run.log'), run.stdout + run.stderr);
  process.stdout.write(run.stdout);
  const hash = name => createHash('sha256').update(fs.readFileSync(path.join(scratch, name))).digest('hex');
  fs.writeFileSync(path.join(scratch, 'metadata.json'), JSON.stringify({
    surface: 'CLI workbench, native pure UI fixture; no production terminal',
    reference: 'Seedmux 0.1.41 (build 42), frozen at Goal start',
    timestamp: new Date().toISOString(),
    sourceSHA256: createHash('sha256').update(source).digest('hex'),
    files: Object.fromEntries(inputs.map(name => [name, createHash('sha256').update(read(name)).digest('hex')])),
    images: Object.fromEntries(fs.readdirSync(scratch).filter(name => name.endsWith('.png')).map(name => [name, hash(name)])),
    productionWiring: false, humanApproval: false, terminalAcceptance: false,
  }, null, 2));
  process.stdout.write(`CLI_WORKBENCH_PREVIEW ${scratch}\n`);
  assert.equal(run.status, 0, run.stdout + run.stderr);
});
