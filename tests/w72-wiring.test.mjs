import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = name => readFileSync(`App/Sources/Tatwo2/Facade/${name}.swift`, 'utf8');
test('push_thread uses per-thread provenance and actual peer baseline preflight', () => {
  const model = read('ChatPageModel');
  const push = model.slice(model.indexOf('func pushThreadToDevice('), model.indexOf('func pushThreadToDevice(') + 6000);
  assert.match(push, /candidates\(\s*threadID: threadID/);
  assert.match(push, /sourceBaselines/);
  assert.match(push, /"phase": "baseline"/);
  assert.match(push, /peer\[\$0\] != original\[\$0\]/);
  assert.match(push, /NSButton\(checkboxWithTitle/);
  assert.match(push, /\.state == \.on/);
  assert.doesNotMatch(read('RemoteDeviceSession'), /"--porcelain"|--untracked-files/);
  assert.match(read('OSAgentBridge'), /case "push_thread":[\s\S]*?"baseline"[\s\S]*?transferProject/);
  assert.match(read('ChatLiveEngine'), /matches\.count == 1/);
  assert.match(read('ChatLiveEngine'), /if requiresFiles \{ throw/);
});

test('engine deployment shares tested hashing gate and rsync checksums bytes', () => {
  const sync = read('RemoteEngineSync');
  assert.match(sync, /stamps\[key\] = try deployIfNeeded/);
  assert.match(sync, /"--checksum"/);
  assert.doesNotMatch(sync, /timeIntervalSince\(last\)/);
  assert.match(sync, /read\(upToCount: 64 \* 1024\)/);
});
