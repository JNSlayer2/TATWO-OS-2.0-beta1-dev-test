import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const app = 'App/Sources/Tatwo2/';
const read = file => readFileSync(join(repo, app, file), 'utf8');
const upstream = '# Synthetic W71 bundled upstream\n';
const constitution = Buffer.from('# Current constitution v4\r\nKeep primary-device authority.\r\n');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
let binary;

// Compile the real binding implementation. Only the command-line driver and
// bundle contents are fixtures; all reads/writes stay in testScratch/TMPDIR.
function fixture() {
  if (!binary) {
    const root = testScratch('w71-binding-compiled-');
    const driver = join(root, 'checks.swift');
    binary = join(root, 'checks');
    writeFileSync(join(root, 'os-upstream.md'), upstream);
    writeFileSync(join(root, 'os.md'), '# Obsolete bundled constitution: must never be seeded\n');
    writeFileSync(driver, String.raw`
import Foundation

@main struct W71BindingChecks {
    static func main() throws {
        let root = CommandLine.arguments[1]
        let scenario = CommandLine.arguments[2]
        let environment = [
            "TATWO2_OS_ROOT": root + "/entry",
            "TATWO2_BIND_TARGETS": "claude=" + root + "/CLAUDE.md,codex=" + root + "/AGENTS.md"
        ]
        let plan = OSUpstreamBinding.preview(environment: environment)
        if scenario == "stale" {
            try Data("externally supplied upstream\n".utf8).write(
                to: URL(fileURLWithPath: root + "/entry/os-upstream.md"), options: .withoutOverwriting)
        }
        if scenario == "constitution-edited" {
            try Data("primary-device update after preview\n".utf8).write(
                to: URL(fileURLWithPath: root + "/entry/os.md"), options: .atomic)
        }
        let report = OSUpstreamBinding.apply(plan, environment: environment)
        let fresh = OSUpstreamBinding.preview(environment: environment)
        let repeated = report.failure == nil
            ? OSUpstreamBinding.apply(fresh, environment: environment) : OSBindingWriteReport()
        let result: [String: Any] = [
            "seed": plan.seed,
            "constitutionMissing": plan.constitutionMissing,
            "notices": plan.notices,
            "paths": plan.paths,
            "previewError": plan.error ?? "",
            "failure": report.failure ?? "",
            "modified": report.modified,
            "backups": report.backups,
            "states": fresh.items.map { $0.state.rawValue },
            "repeatModified": repeated.modified,
            "repeatBackups": repeated.backups,
            "repeatFailure": repeated.failure ?? ""
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
`);
    const files = ['Facade/TatwoResources.swift', 'Facade/EnginePaths.swift', 'Facade/TatwoEntry.swift',
      'Facade/OSUpstreamBinding.swift', 'Facade/OSBindingPreview.swift'];
    execFileSync('swiftc', ['-swift-version', '5', '-parse-as-library', '-num-threads', '2',
      ...files.map(file => join(repo, app, file)), driver, '-o', binary],
    { encoding: 'utf8', timeout: 180_000 });
  }
  return binary;
}

for (const scenario of ['preserve', 'readonly', 'existing-archive', 'missing',
  'missing-with-upstream', 'existing-upstream', 'root-missing', 'constitution-edited', 'stale']) {
  test(`W71 production binding: ${scenario}`, { skip: process.platform !== 'darwin', timeout: 240_000 }, () => {
    const root = testScratch(`w71-binding-${scenario}-`);
    const entry = join(root, 'entry');
    const os = join(entry, 'os.md');
    const rules = join(entry, 'os-upstream.md');
    const archive = join(entry, 'os.1.0.md');
    const missing = ['missing', 'missing-with-upstream', 'root-missing'].includes(scenario);
    const seed = !['existing-upstream', 'missing-with-upstream'].includes(scenario);
    if (scenario !== 'root-missing') mkdirSync(entry);
    if (!missing) writeFileSync(os, constitution, { mode: scenario === 'readonly' ? 0o444 : 0o600 });
    if (!seed) writeFileSync(rules, 'existing upstream must survive\n');
    if (scenario === 'existing-archive') writeFileSync(archive, 'existing archive must survive\n');
    const original = Buffer.from('Human instructions outside the binding.\r\n');
    const claude = join(root, 'CLAUDE.md');
    const codex = join(root, 'AGENTS.md');
    writeFileSync(claude, original);
    const output = execFileSync(fixture(), [root, scenario], { encoding: 'utf8', timeout: 60_000 });
    const result = JSON.parse(output);
    assert.equal(result.previewError, '');
    assert.equal(result.seed, seed);
    assert.equal(result.constitutionMissing, missing);
    assert.equal(result.notices.includes('入口缺憲法，請先由主設備派發'), missing);
    assert.deepEqual(result.paths, [...(seed ? [rules] : []), claude, codex]);
    assert.equal(result.paths.includes(os), false);
    assert.equal(result.paths.includes(archive), false);
    if (scenario === 'stale') {
      assert.match(result.failure, /預覽已過期/);
      assert.deepEqual(result.modified, []);
      assert.deepEqual(result.backups, []);
      assert.equal(readFileSync(rules, 'utf8'), 'externally supplied upstream\n');
      assert.deepEqual(readFileSync(claude), original);
      assert.equal(existsSync(codex), false);
    } else {
      assert.equal(result.failure, '');
      assert.deepEqual(result.modified, result.paths);
      assert.deepEqual(result.states, ['bound', 'bound']);
      assert.equal(readFileSync(rules, 'utf8'), seed ? upstream : 'existing upstream must survive\n');
      assert.equal(result.backups.length, 1);
      assert.deepEqual(readFileSync(result.backups[0]), original);
      assert.equal(statSync(result.backups[0]).mode & 0o777, 0o600);
      assert.ok(readFileSync(claude, 'utf8').startsWith(original.toString()));
      for (const target of [claude, codex]) {
        assert.match(readFileSync(target, 'utf8'), /TATWO_OS_UPSTREAM_V2:BEGIN/);
        assert.ok(readFileSync(target, 'utf8').includes(hash(readFileSync(rules)).slice(0, 12)));
      }
      assert.equal(result.repeatFailure, '');
      assert.deepEqual(result.repeatModified, []);
      assert.deepEqual(result.repeatBackups, []);
    }
    assert.equal(existsSync(os), !missing);
    if (!missing) {
      const expected = scenario === 'constitution-edited'
        ? Buffer.from('primary-device update after preview\n') : constitution;
      assert.equal(hash(readFileSync(os)), hash(expected), 'constitution bytes must be untouched');
      if (scenario === 'readonly') assert.equal(statSync(os).mode & 0o777, 0o444);
    }
    assert.equal(existsSync(archive), scenario === 'existing-archive');
    if (scenario === 'existing-archive') {
      assert.equal(readFileSync(archive, 'utf8'), 'existing archive must survive\n');
    }
  });
}

test('W71 preview and confirmation share notices and never offer old constitution seeding', () => {
  const binding = read('Facade/OSBindingPreview.swift');
  const model = read('Facade/OSBindingPreviewModel.swift');
  const card = read('New/OSBindingCard.swift');
  assert.match(binding, /入口缺憲法，請先由主設備派發/);
  assert.match(card, /ForEach\(preview\.notices, id: \\\.self\)/);
  assert.match(model, /plan\.notices\.joined\(separator: "\\n"\)/);
  assert.doesNotMatch(binding, /bundled\("os"\)|os\.1\.0\.md|moveItem|originalConstitution/);
  assert.doesNotMatch(binding, /write\(plan\.root \+ "\/os\.md"/);
  for (const text of [card, model]) assert.doesNotMatch(text, /os\.md v3|os\.1\.0\.md/);
});
