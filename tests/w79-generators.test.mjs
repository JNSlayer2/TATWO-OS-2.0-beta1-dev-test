import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { testScratch } from './helpers/test-scratch.mjs';

test('W79 production app: generation, two devices, ownership, binding readback and exact removal', { timeout: 120_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY, 'build Tatwo2 and set TATWO2_TEST_BINARY (no skipped acceptance)');
  const root = testScratch('w79-app-');
  const home = join(root, 'home'); mkdirSync(home);
  const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
    encoding: 'utf8', timeout: 100_000,
    env: {
      PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home,
      CFFIXED_USER_HOME: home, TATWO2_LIVE_ROOT: join(root, 'live'),
      TATWO2_RULEGENERATORTEST: '1', TATWO2_OS_ROOT: root,
      TATWO2_OS_UPSTREAM_PATH: join(root, 'unused-runtime.md'),
    },
  });
  assert.match(output, /W79TEST ALL PASS/);
  assert.doesNotMatch(output, /W79TEST FAILED/);
  for (const label of ['exact constitution hash', 'exact identity hash', 'two local identities',
    'runtime edit not overwritten', 'block marked edited with diff', 'remove restores exact original bytes']) {
    assert.ok(output.includes('W79TEST PASS ' + label), label);
  }
  console.log(output.trim());
});

test('W79 retains the real BINDTEST and OSUPSTREAMREFRESHTEST contracts in isolated storage', { timeout: 180_000 }, () => {
  assert.ok(process.env.TATWO2_TEST_BINARY);
  const root = testScratch('w79-legacy-');
  const home = join(root, 'home'); mkdirSync(home);
  const source = join(root, 'temporary.c');
  const library = join(root, 'temporary.dylib');
  // Darwin Foundation ignores TMPDIR for FileManager.temporaryDirectory. Redirect
  // only that OS query in this child process; do not change any production rule API.
  writeFileSync(source, `
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
static size_t isolated_confstr(int name, char *buffer, size_t length) {
  const char *root = getenv("TMPDIR");
  if (name == _CS_DARWIN_USER_TEMP_DIR && root && root[0]) {
    size_t needed = strlen(root) + 1;
    if (buffer && length) {
      size_t copied = needed < length ? needed : length;
      memcpy(buffer, root, copied);
      buffer[copied - 1] = 0;
    }
    return needed;
  }
  return confstr(name, buffer, length);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose __attribute__((section("__DATA,__interpose"))) =
  { (const void *)isolated_confstr, (const void *)confstr };
`);
  execFileSync('clang', ['-dynamiclib', source, '-o', library], { encoding: 'utf8', timeout: 60_000 });
  const legacy = join(root, 'legacy.json');
  writeFileSync(legacy, JSON.stringify({ projects: [], threads: [] }));
  for (const flag of ['TATWO2_BINDTEST', 'TATWO2_OSUPSTREAMREFRESHTEST']) {
    const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
      encoding: 'utf8', timeout: 90_000,
      env: {
        PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, HOME: home,
        CFFIXED_USER_HOME: home, DYLD_INSERT_LIBRARIES: library,
        TATWO2_LIVE_ROOT: join(root, 'live'), TATWO2_OS_ROOT: join(root, 'entry'),
        TATWO2_ENGINES_ROOT: join(root, 'engines'), TATWO2_AUTHORIZED_KEYS: join(root, 'authorized_keys'),
        TATWO2_OS_SOCKET: join(root, 'live', 'os.sock'),
        TATWO2_OS_UPSTREAM_PATH: join(root, 'unused-runtime.md'),
        TATWO2_BIND_LEGACY_DOCUMENT: legacy, [flag]: '1',
      },
    });
    writeFileSync(join(root, flag + '.log'), output);
    assert.match(output, /ALL PASS/);
    assert.doesNotMatch(output, /(?:BINDTEST|OSUPSTREAMREFRESHTEST) FAIL|未跑/);
    if (flag === 'TATWO2_BINDTEST') {
      assert.ok(output.includes('BINDTEST fixtures retained: ' + process.env.TMPDIR), 'Foundation fixture must remain in TMPDIR');
    }
    console.log(output.trim());
  }
});

test('W79 three native injection points consume the composed runtime without changing vendor ownership', () => {
  const read = file => readFileSync(new URL('../' + file, import.meta.url), 'utf8');
  assert.match(read('Engines/claude-sidecar/sidecar.mjs'), /append: systemPrompt/);
  assert.match(read('Engines/codex-sidecar/sidecar.mjs'), /developer_instructions=\$\{JSON\.stringify\(systemPrompt\)\}/);
  assert.match(read('Engines/grok-sidecar/sidecar.mjs'), /\['--rules', systemPrompt\]/);
  assert.match(read('App/Sources/Tatwo2/Facade/RuleGenerator.swift'), /static let sections = \["0", "1", "2.1", "2.2", "2.3", "2.4", "4", "5", "8"\]/);
});
