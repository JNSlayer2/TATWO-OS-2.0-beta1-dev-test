import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const read = file => readFileSync(join(repo, 'App/Sources/Tatwo2', file), 'utf8');

test('native Island hover exit collapses synchronously with no click or grace period', {
  skip: process.platform !== 'darwin', timeout: 120_000,
}, () => {
  const root = testScratch('island-hover-');
  const shell = read('Shell/TatwoIslandShell.swift');
  const state = shell.slice(shell.indexOf('@MainActor\nfinal class TatwoIslandShellState'),
    shell.indexOf('@MainActor\nfinal class TatwoIslandShellController'));
  const fixture = join(root, 'main.swift');
  writeFileSync(fixture, `import SwiftUI
import AppKit
enum TatwoIslandShellMetrics {
  static let collapseDelay = IslandCollapsePolicy.delay
  static func transitionAnimation(expanding: Bool) -> Animation { .linear(duration: 0) }
}
${read('New/IslandCollapsePolicy.swift')}
${state}
@main struct Checks {
  @MainActor static func pause(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
  }
  @MainActor static func main() {
    let state = TatwoIslandShellState()
    for _ in 0..<3 {
      state.setPointerInside(true)
      precondition(state.isExpanded, "hover alone expands")
      state.setPointerInside(false)
      precondition(!state.isExpanded && state.expansionProgress == 0,
        "hover exit must start collapse synchronously, with no click, sleep or queued timer")
    }
    state.setPointerInside(true)
    state.handleCollapseEvent(.itemTapped)
    state.setPointerInside(false)
    precondition(!state.isExpanded, "a click cannot add an exit delay")
    state.setPointerInside(true)
    pause(0.05)
    precondition(state.isExpanded, "re-entry stays expanded without a stale timer")
    state.holdOpen(true)
    state.setPointerInside(false)
    precondition(state.isExpanded, "consent must not auto-dismiss")
    state.holdOpen(false)
    precondition(!state.isExpanded, "release outside collapses immediately")
    state.expandForNavigation()
    precondition(state.isExpanded, "programmatic navigation remains visible until its preview deadline")
    state.setPointerInside(true)
    state.setPointerInside(false)
    precondition(!state.isExpanded, "pointer exit cancels even a programmatic preview immediately")
    print("ISLAND HOVER PASS")
  }
}`);
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', fixture, '-o', binary],
    { encoding: 'utf8', timeout: 60_000 });
  const env = { ...process.env };
  delete env.TATWO_ISLAND_PIN_EXPANDED;
  const result = spawnSync(binary, [], { encoding: 'utf8', env, timeout: 30_000 });
  assert.equal(result.status, 0, `${result.signal}\n${result.stderr}`);
  assert.match(result.stdout, /ISLAND HOVER PASS/);
});

test('native Island controller recovers missing exit and programmatic expansion', {
  skip: process.platform !== 'darwin', timeout: 120_000,
}, () => {
  const root = testScratch('island-controller-');
  const binary = join(root, 'checks');
  execFileSync('swiftc', ['-j', '2', '-swift-version', '5', '-parse-as-library',
    join(repo, 'App/Sources/Tatwo2/Shell/TatwoIslandShell.swift'),
    join(repo, 'App/Sources/Tatwo2/New/IslandCollapsePolicy.swift'),
    join(repo, 'tests/helpers/island-controller-fixture.swift'), '-o', binary],
    { encoding: 'utf8', timeout: 60_000 });
  const env = { ...process.env };
  delete env.TATWO_ISLAND_PIN_EXPANDED;
  const result = spawnSync(binary, [], { encoding: 'utf8', env, timeout: 55_000 });
  assert.equal(result.status, 0, `${result.signal}\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /ISLAND CONTROLLER PASS/);
});
