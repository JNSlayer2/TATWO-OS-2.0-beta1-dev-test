import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('browser bridge recovers dead endpoints while preserving active listeners', {
  skip: process.platform !== 'darwin', timeout: 60000,
}, () => {
  const source = fs.readFileSync(path.join(repo, 'App/Sources/Tatwo2/Facade/BrowserAgentBridge.swift'), 'utf8');
  const start = source.indexOf('    enum SocketProbe');
  const end = source.indexOf('    private func listen()', start);
  assert.ok(start >= 0 && end > start);
  const out = path.resolve(process.env.TATWO_BROWSER_RESOURCE_EVIDENCE ?? os.tmpdir());
  fs.mkdirSync(out, { recursive: true });
  const run = fs.mkdtempSync(path.join(out, 'socket-test-'));
  // A short disposable path is required by sockaddr_un's 104-byte limit.
  const socketRoot = fs.mkdtempSync('/tmp/t2sock-');
  fs.writeFileSync(path.join(run, 'cleanup.json'), JSON.stringify({ disposableSocketRoot: socketRoot }));
  const fixture = fs.readFileSync(path.join(repo, 'tests/fixtures/browser-socket-recovery.swift.in'), 'utf8')
    .replace('// INSERT production', source.slice(start, end));
  const file = path.join(run, 'fixture.swift');
  fs.writeFileSync(file, fixture);
  const result = spawnSync('swift', [file, socketRoot], { encoding: 'utf8', timeout: 45000 });
  fs.writeFileSync(path.join(run, 'result.log'), result.stdout + result.stderr + `\nexit=${result.status}\n`);
  process.stdout.write(result.stdout);
  assert.equal(result.status, 0, result.stderr || String(result.error));
  assert.match(result.stdout, /RESULT checks=20 failures=0/);
  assert.match(source, /listenerLeaseFD = lease/);
  assert.match(source, /guard path == Self.leasedSocketPath, Self.archiveStaleSocket/);
  assert.ok(source.indexOf('let lease = Self.acquireSocketLease') < source.indexOf('switch Self.probeSocket(at: path)'));
});
