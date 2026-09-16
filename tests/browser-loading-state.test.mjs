import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const repo = process.cwd();
const source = fs.readFileSync(path.join(repo,
  'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');
const start = source.indexOf('void UpdateLoadingState(TatwoCEFBrowserView *view, bool is_loading) {');
const end = source.indexOf('\nvoid PublishMainFrameLoadStart(', start);
assert.ok(start > 0 && end > start);
const root = testScratch('loading-state.');
const program = path.join(root, 'probe');
fs.writeFileSync(path.join(root, 'probe.mm'), `
#import <Foundation/Foundation.h>
using TatwoCEFBrowserView = NSObject;
enum {
  TatwoCEFBrowserPhaseBlank, TatwoCEFBrowserPhaseCreating,
  TatwoCEFBrowserPhaseLoading, TatwoCEFBrowserPhaseCommitted,
  TatwoCEFBrowserPhaseFinished, TatwoCEFBrowserPhaseBlockedBySecurity,
  TatwoCEFBrowserPhaseNavigationFailed, TatwoCEFBrowserPhaseRendererFailed
};
struct BrowserState { bool is_loading; int phase; uint64_t mount_generation; };
BrowserState current;
int starts = 0, stops = 0;
void MutateStateOnMain(NSObject *, void (^mutate)(BrowserState *)) { mutate(&current); }
void StartLoadingActiveMessagePump(NSObject *, uint64_t, NSString *) { ++starts; }
void StopLoadingActiveMessagePump(NSObject *, uint64_t, NSString *) { ++stops; }
${source.slice(start, end)}
int main(int argc, const char **argv) {
  current = {false, atoi(argv[1]), 1};
  UpdateLoadingState(nil, true);
  int during = current.phase;
  bool loading = current.is_loading;
  UpdateLoadingState(nil, false);
  printf("%d %d %d %d %d %d", during, current.phase, loading, current.is_loading, starts, stops);
}
`);
execFileSync('/bin/bash', ['-c', `
set -euo pipefail
receipt=$(bash scripts/tatwo-build-lock.sh acquire --timeout 120 --pid $$)
token=$(printf '%s\\n' "$receipt" | sed -n 's/^token=//p')
trap 'bash scripts/tatwo-build-lock.sh release --token "$token" >/dev/null' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -framework Foundation "$1" -o "$2"
`, 'loading-state-test', path.join(root, 'probe.mm'), program],
{ cwd: repo, timeout: 150000, stdio: 'pipe' });

for (const [label, phase, expected] of [
  ['late iframe does not invalidate a finished main document', 4, 4],
  ['iframe activity preserves a committed document', 3, 3],
  ['initial navigation can still enter loading', 1, 2],
  ['main-frame loading stays loading until its own callback', 2, 2],
  ['security failure is not cleared by resource activity', 5, 5],
  ['navigation failure is not cleared by resource activity', 6, 6],
  ['renderer failure is not cleared by resource activity', 7, 7],
]) {
  test(label, () => {
    const actual = execFileSync(program, [String(phase)], { encoding: 'utf8' })
      .trim().split(' ').map(Number);
    assert.deepEqual(actual, [expected, expected, 1, 0, 1, 1]);
  });
}
