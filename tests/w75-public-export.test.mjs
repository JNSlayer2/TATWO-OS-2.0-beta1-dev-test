import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
test('W75 whitelist export and explicit public safety scan pass on a fresh TMPDIR fixture',
  { timeout: 240_000 }, () => {
    // Deliberately leave the export for inspection; never delete work products.
    const root = testScratch('w75-public-export-');
    const output = join(root, 'export');
    const exported = spawnSync('bash', ['scripts/public-export.sh', output], {
      cwd: repo, encoding: 'utf8', timeout: 180_000, maxBuffer: 16 * 1024 * 1024,
    });
    // Run the requested standalone scan even if export's own scan fails.
    const scanned = spawnSync(process.execPath, ['scripts/public-safety-scan.mjs', output], {
      cwd: repo, encoding: 'utf8', timeout: 60_000, maxBuffer: 16 * 1024 * 1024,
    });
    const summary = result => [result.stdout, result.stderr].filter(Boolean).join('\n')
      .split('\n').filter(line => /^(?:EXPORTED FILES|PACKAGE TARGET|PUBLIC SAFETY|FAIL:)/.test(line)).join('\n');
    assert.deepEqual([exported.status, scanned.status], [0, 0],
      `Export:\n${summary(exported)}\nExplicit scan:\n${summary(scanned)}`);
    assert.match(exported.stdout, /PUBLIC SAFETY SCAN PASS/);
    assert.match(exported.stdout, /PACKAGE TARGET PATHS PASS/);
    assert.match(scanned.stdout, /PUBLIC SAFETY SCAN PASS/);
    for (const excluded of ['archive', 'docs', 'AGENTS.md', 'CLAUDE.md',
      'App/Sources/Tatwo2/Resources/os-architecture-standard.md']) {
      assert.equal(existsSync(join(output, excluded)), false, excluded);
    }
    const template = 'App/Sources/Tatwo2/Resources/os.md';
    assert.equal(readFileSync(join(output, template), 'utf8'), readFileSync(join(repo, template), 'utf8'));
    console.log('W75 export: PACKAGE TARGET PATHS PASS; PUBLIC SAFETY SCAN PASS (export + explicit scan)');
  });
