import test from 'node:test';
import assert from 'node:assert/strict';
import { brainModePolicy } from '../Engines/gbrain-adapter/service.mjs';

const primary = '11111111-1111-4111-8111-111111111111';
const former = '22222222-2222-4222-8222-222222222222';

test('W83 primary owns a local brain by default and may not connect remotely', () => {
  assert.deepEqual(brainModePolicy({ role: 'primary', deviceID: primary }), { remote: false, ownsLocal: true, retainedOnPrevious: false });
  assert.equal(brainModePolicy({ role: 'primary', deviceID: primary, transfer: { brain: 'migrated', to: primary, from: former } }).remote, false);
});

test('W83 new primary connects back only when the transfer kept GBrain on the former primary', () => {
  const policy = brainModePolicy({ role: 'primary', deviceID: primary, transfer: { brain: 'retained', to: primary, from: former } });
  assert.deepEqual(policy, { remote: true, ownsLocal: false, retainedOnPrevious: true });
});

test('W83 a retained record addressed to another device grants nothing', () => {
  assert.equal(brainModePolicy({ role: 'primary', deviceID: primary, transfer: { brain: 'retained', to: former, from: primary } }).remote, false);
  assert.deepEqual(brainModePolicy({ role: 'secondary', deviceID: former }), { remote: true, ownsLocal: false, retainedOnPrevious: false });
});
