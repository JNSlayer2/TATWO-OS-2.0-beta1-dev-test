import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const checkout = fs.realpathSync(fileURLToPath(new URL('../../', import.meta.url)));

// Writable fixture state must never depend on another test creating an ignored
// checkout directory. Immutable compiled probes may be reused within one file.
// Keep artifacts for inspection; this helper never permanently deletes data.
export function testScratch(prefix) {
  const base = fs.realpathSync(os.tmpdir());
  if (base === checkout || base.startsWith(checkout + path.sep)) {
    throw new Error('test scratch must be outside the production checkout');
  }
  if (path.basename(prefix) !== prefix || prefix === '.' || prefix === '..') {
    throw new Error('scratch prefix must be a single path component');
  }
  const root = fs.mkdtempSync(path.join(base, prefix));
  // Optional private receipt for the run owner to inspect/archive completed
  // fixtures without guessing ownership from a global temporary directory.
  const log = process.env.TATWO_TEST_SCRATCH_LOG;
  if (log) {
    const parent = fs.realpathSync(path.dirname(log));
    if (parent === checkout || parent.startsWith(checkout + path.sep)) {
      throw new Error('scratch receipts must be outside the production checkout');
    }
    const fd = fs.openSync(log, fs.constants.O_WRONLY | fs.constants.O_CREAT |
      fs.constants.O_APPEND | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeSync(fd, JSON.stringify({ root, pid: process.pid }) + '\n'); }
    finally { fs.closeSync(fd); }
  }
  return root;
}

// Shell probes derive their writable .build path from their own location.
// Copy the real scripts and exact production inputs into a private miniature
// checkout rather than reimplementing them or changing production scripts.
export function stageFixtureFiles(files) {
  const root = testScratch('script-fixture-');
  for (const relative of files) {
    if (path.isAbsolute(relative) || relative.split('/').includes('..')) {
      throw new Error('fixture input must be checkout-relative');
    }
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(checkout, relative), destination);
  }
  return root;
}
