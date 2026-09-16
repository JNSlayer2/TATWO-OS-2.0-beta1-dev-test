import { testScratch } from './helpers/test-scratch.mjs';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('..', import.meta.url));
test('legacy loading predicate remains bounded but W60 never arms a loading timer', { timeout: 90_000 }, t => {
  if (process.platform !== 'darwin') return t.skip('requires macOS C++ compiler');
  const bridge = fs.readFileSync(path.join(repo,
    'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
  const start = bridge.indexOf('bool HasActiveBrowserPumpWork(bool');
  const end = bridge.indexOf('std::atomic<uint64_t> g_message_pump_schedule_count');
  assert.ok(start >= 0 && end > start);
  // W60 removes the timer itself, not its lifecycle/close guard contract.
  assert.doesNotMatch(bridge, /ArmLoadingActiveMessagePumpTimer|phase=message_pump_loading_fallback/);
  assert.match(bridge, /phase=message_pump_overdue/);
  const scratch = testScratch('startup-pump.');
  fs.writeFileSync(path.join(scratch, 'checks.cpp'), `
#include <cassert>
#include <cstdint>
#include <iostream>
${bridge.slice(start, end)}
int main() {
  LoadingActiveMessagePumpGate gate;
  const auto generation = gate.Start();
  // Readiness arrives after the three vendor/host kicks observed in the failure.
  int ticks = 0;
  for (int iteration = 0; iteration < 8; ++iteration) {
    const bool ready = iteration >= 6;
    if (gate.CanTick(generation,
        HasActiveBrowserPumpWork(false, true, ready, false, false),
        false, true, false)) ++ticks;
  }
  assert(ticks == 6);
  assert(!HasActiveBrowserPumpWork(false, true, true, false, false)); // ready, no host window
  assert(HasActiveBrowserPumpWork(false, true, true, false, true)); // native creation pending
  assert(HasActiveBrowserPumpWork(true, false, true, false, false)); // ordinary navigation
  assert(!HasActiveBrowserPumpWork(false, false, true, false, false)); // finished
  assert(!HasActiveBrowserPumpWork(false, true, false, true, false)); // rejected context
  assert(!HasActiveBrowserPumpWork(false, false, false, false, true)); // startup timeout
  assert(!gate.CanTick(generation, true, true, true, false)); // close
  assert(!gate.CanTick(generation, true, false, true, true)); // shutdown
  gate.Stop();
  assert(!gate.CanTick(generation, true, false, true, false));
  const auto next = gate.Start();
  assert(!gate.CanTick(generation, true, false, true, false)); // stale tick
  assert(gate.CanTick(next, true, false, true, false));
  // Reentrant CEF work completed one navigation and started another.
  gate.Stop();
  const auto restarted = gate.Start();
  assert(!gate.CanTick(next, true, false, true, false));
  if (gate.generation() == next) gate.Stop();
  assert(gate.CanTick(restarted, true, false, true, false));
  std::cout << "STARTUPPUMP RESULT passed=14 failed=0 skipped=0\\n";
}
`);
  const build = spawnSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 60 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
nice -n 10 xcrun clang++ -std=c++20 "$1" -o "$2"
`, 'startup-pump', path.join(scratch, 'checks.cpp'), path.join(scratch, 'checks')], {
    cwd: repo, encoding: 'utf8', timeout: 75_000, env: { ...process.env, TMPDIR: scratch },
  });
  assert.equal(build.status, 0, build.stderr || String(build.error));
  const run = spawnSync(path.join(scratch, 'checks'), [], { encoding: 'utf8', timeout: 5000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  process.stdout.write(run.stdout);
});
