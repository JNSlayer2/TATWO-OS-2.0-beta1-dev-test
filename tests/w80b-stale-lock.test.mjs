import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';
import { acquireServiceLock } from '../Engines/gbrain-adapter/service.mjs';

test('W80b stale service lock from a dead owner is archived and reacquired', () => {
  const dir = testScratch('w80b-stale-lock-');
  const lock = path.join(dir, 'service.lock');
  fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, 'owner'), '999999');
  acquireServiceLock(lock, { alive: () => false, now: () => 42 });
  assert.equal(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), String(process.pid));
  assert.ok(fs.existsSync(`${lock}.stale-42`), 'stale lock archived, not deleted');
});

test('W80b live service lock still blocks a second service', () => {
  const dir = testScratch('w80b-live-lock-');
  const lock = path.join(dir, 'service.lock');
  fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, 'owner'), '12345');
  assert.throws(() => acquireServiceLock(lock, { alive: () => true }), /service_already_running/);
  assert.equal(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), '12345');
});
