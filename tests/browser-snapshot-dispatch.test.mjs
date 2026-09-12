import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const bridge = readFileSync(new URL('../Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm', import.meta.url), 'utf8');
function section(start, end) {
  const from = bridge.indexOf(start), to = bridge.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from);
  return bridge.slice(from, to);
}
const capture = section('void TatwoClient::CaptureVisibleSnapshot(', 'void TatwoClient::OnDevToolsMethodResult(');

test('snapshot dispatch wakes an idle CEF pump after command and timeout registration', () => {
  const execute = capture.indexOf('"DOMSnapshot.captureSnapshot"');
  const failed = capture.indexOf('if (snapshot_message_id_ == 0)');
  const timer = capture.indexOf('dispatch_after(');
  const kick = capture.indexOf('ScheduleImmediateCEFMessagePumpWork(@"browser_snapshot")');
  assert.ok(execute >= 0 && failed > execute && timer > failed && kick > timer);
  assert.equal(capture.match(/ScheduleImmediateCEFMessagePumpWork/g)?.length, 1);
  assert.match(capture, /if \(snapshot_message_id_ == 0\) \{\s*FinishVisibleSnapshot\(nil, @"snapshot_unavailable"\);\s*return;/);
  // Do not repair an idle dispatch by creating a permanent poller or navigation.
  assert.doesNotMatch(capture, /StartLoadingActiveMessagePump|repeats:YES|LoadURL|loadURLString/);
});

test('snapshot deadline and mount-bound stale-request cancellation remain unchanged', () => {
  assert.match(capture, /dispatch_time\(DISPATCH_TIME_NOW, 200 \* NSEC_PER_MSEC\)/);
  assert.match(capture, /const int pending_message_id = snapshot_message_id_/);
  assert.match(capture, /IsActiveMountCallback\(\s*owner,\s*expected_mount_generation,\s*@"snapshot_timeout"\)/);
  assert.match(capture, /SnapshotTimedOut\(pending_message_id\)/);
  const timeout = section('void TatwoClient::SnapshotTimedOut(', 'void TatwoClient::FinishVisibleSnapshot(');
  assert.match(timeout, /snapshot_completion_ != nil && snapshot_message_id_ == message_id/);
  assert.match(timeout, /FinishVisibleSnapshot\(nil, @"snapshot_timeout"\)/);
});

test('snapshot result remains tied to browser, navigation generation and committed URL', () => {
  const result = section('void TatwoClient::OnDevToolsMethodResult(', 'void TatwoClient::SnapshotTimedOut(');
  for (const check of ['message_id != snapshot_message_id_', 'state->browser->IsSame(browser)',
    'state->navigation_generation != snapshot_navigation_generation_',
    '[state->committed_url isEqualToString:snapshot_committed_url_]']) assert.ok(result.includes(check));
  assert.match(result, /BuildVisibleSnapshotJSON\(/);
  const finish = section('void TatwoClient::FinishVisibleSnapshot(', 'void TatwoClient::CancelPendingBrowserOperations(');
  assert.ok(finish.indexOf('snapshot_completion_ = nil') < finish.indexOf('completion(json, error_code)'));
  assert.match(finish, /snapshot_devtools_registration_ = nullptr/);
});

test('snapshot uses the existing host kick rather than the cancellable vendor timer', () => {
  const kick = section('void ScheduleImmediateCEFMessagePumpWork(NSString *reason)', 'constexpr size_t kWebMCPMaximumToolNameBytes');
  assert.match(kick, /DeliverImmediateMessagePumpWork\(/);
  assert.match(kick, /RunCEFMessagePumpWorkOnMainThread\(\)/);
  assert.match(kick, /QueueImmediateCEFMessagePumpWorkOnMainQueue\(\)/);
  assert.doesNotMatch(kick, /g_message_pump_schedule_generation/);
});
