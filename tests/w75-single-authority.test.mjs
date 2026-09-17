import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, lstatSync, readFileSync, readlinkSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
// Split literals so the regression detector does not report its own vocabulary.
const claims = [
  ['以本檔', '為準'], ['以這一頁', '為準'], ['canonical', ' authority'],
  ['complete', ' authority'], ['唯一', '真相源'],
].map(parts => parts.join(''));
const excludedDirectories = new Set(['archive', 'evidence', 'receipts', 'harness-exam']);
// 1.0 is frozen and only a source pool (constitution v4); its code/data and July planning
// records are historical, not current governance. Paths are repo-relative prefixes.
const excludedPrefixes = ['Apps/TatwoUltraworkMac/', 'Packages/TatwoUltraworkCore/', '.tatwo-ultrawork/', 'docs/protocol/', 'docs/superpowers/'];
function excluded(file) {
  return excludedPrefixes.some(prefix => file.startsWith(prefix)) || file.split('/').some(part => excludedDirectories.has(part))
    || file.startsWith('docs/reviews/') || file.startsWith('docs/plans/');
}
function findings(file, text) {
  if (excluded(file)) return [];
  return text.split(/\r?\n/).flatMap((line, index) =>
    claims.filter(claim => line.toLowerCase().includes(claim.toLowerCase()))
      .map(claim => `${file}:${index + 1}: ${claim}`));
}

test('W75 authority detector covers case variants, nested archives and unapproved paths', () => {
  for (const claim of claims) {
    assert.equal(findings('docs/current.md', claim).length, 1);
    assert.equal(findings('config/current.json', claim.toUpperCase()).length, 1);
    for (const dir of ['archive', 'evidence', 'receipts', 'harness-exam', 'docs/reviews', 'docs/plans']) {
      assert.deepEqual(findings(`${dir}/old.md`, claim), []);
    }
    assert.deepEqual(findings('docs/receipts/run/old.md', claim), []);
    assert.equal(findings('docs/current/protocol.md', claim).length, 1);
    for (const prefix of excludedPrefixes) assert.deepEqual(findings(`${prefix}old.md`, claim), []);
  }
  assert.deepEqual(findings('os.md', '衝突時以入口憲法為準。'), []);
});

test('W75 repository has no competing authority claims outside the requested historical exclusions', () => {
  const files = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
    cwd: repo, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  }).split('\0').filter(Boolean);
  const violations = [];
  for (const file of new Set(files)) {
    if (excluded(file)) continue;
    const absolute = join(repo, file);
    // A tracked deletion is absent; links are inspected without following them outside the checkout.
    if (!existsSync(absolute)) continue;
    const stat = lstatSync(absolute);
    if (!stat.isFile() && !stat.isSymbolicLink()) continue;
    const bytes = stat.isSymbolicLink() ? Buffer.from(readlinkSync(absolute)) : readFileSync(absolute);
    if (bytes.includes(0)) continue;
    violations.push(...findings(file, bytes.toString('utf8')));
  }
  assert.deepEqual(violations, [], `Remaining claims (no per-file grandfathering):\n${violations.join('\n')}`);
});

test('W75 root pointers stay short, use the entrance and retire 1.0 role contracts', () => {
  for (const file of ['AGENTS.md', 'CLAUDE.md']) {
    const text = readFileSync(join(repo, file), 'utf8');
    assert.ok(text.trimEnd().split('\n').length <= 25, file);
    assert.ok(text.includes('~/AI/TATWO OS/os.md'), file);
    assert.match(text, /憲法 §4/);
    for (const reference of ['docs/plans/', 'docs/todo.md', '$tatwo-os-update', '$tatwo-ultrawork']) {
      assert.ok(text.includes(reference), `${file}: ${reference}`);
    }
    assert.doesNotMatch(text, /host_delegate|sandbox_builder|reviewer|blocker_class|receipt|S\/M\/L\/XL/i);
  }
  const docsPointer = readFileSync(join(repo, 'docs/os.md'), 'utf8');
  assert.equal(docsPointer.trimEnd().split('\n').length, 1);
  assert.ok(docsPointer.includes('~/AI/TATWO OS/os.md'));
});
