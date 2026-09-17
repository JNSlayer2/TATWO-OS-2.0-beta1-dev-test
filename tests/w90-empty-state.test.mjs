import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const source = name => fs.readFileSync(
  fileURLToPath(new URL('../App/Sources/Tatwo2/' + name, import.meta.url)), 'utf8');

// 乾淨（全新安裝）狀態是基線：生產路徑不得用 fixture 補畫面。
test('W90 production sources never seed fixture data on the clean path', () => {
  const plugins = source('Facade/PluginsSource.swift');
  const load = plugins.slice(plugins.indexOf('static func load('), plugins.indexOf('static func scanNow('));
  // 匯出（金樣截圖）旗標維持不動；只有「沒有快取」那條路不准回 fixture。
  const fixtureLines = load.split('\n')
    .filter(line => line.includes('PluginsFixture') && !line.trim().startsWith('//'));
  assert.equal(fixtureLines.length, 1, 'load() should only reach PluginsFixture through isExport');
  assert.match(fixtureLines[0], /isExport\(environment\)/);
  assert.doesNotMatch(load, /\?\?\s*\(?[^\n]*PluginsFixture/,
    'missing cache must fall back to an empty list, not fixture skills');

  const stubs = source('Facade/OS1Stubs.swift');
  const remove = stubs.slice(stubs.indexOf('func remove(id: String) throws -> PluginRegistryEntry'));
  assert.doesNotMatch(remove.slice(0, remove.indexOf('\n    }')), /PluginsFixture/,
    'remove() must throw instead of returning a fixture entry');

  const browser = source('Browser/EmbeddedBrowserRuntimePolicies.swift');
  assert.doesNotMatch(browser, /EmbeddedBrowserExtensionFixture/,
    'unreferenced browser extension fixture must be gone');

  const bot = source('Bot/BotPage.swift');
  for (const symbol of ['BotPageFixture.skilletRegistry', 'BotPageFixture.chatBuiltSkills',
    'BotPageFixture.thread(']) {
    for (const line of bot.split('\n').filter(l => l.includes(symbol))) {
      assert.match(line, /usesLiveBots/,
        `${symbol} must stay behind a usesLiveBots guard, found: ${line.trim()}`);
    }
  }
  assert.match(bot, /正在掃描技能…/, 'live Bot’s Bag needs a scanning empty state');
  assert.match(bot, /還沒有在對話中搭建的技能/, 'chat-built skills need an empty state');
  assert.match(bot, /botTranscriptForUI/, 'live DM page must read the real transcript');
});

// 空 library／空 registry／空入口下的實際渲染，由 App 內 SelfTest 跑。
test('W90 clean baseline empty state: empty library, registry and entrance render without red state',
  { timeout: 300_000 }, () => {
    assert.ok(process.env.TATWO2_TEST_BINARY, 'TATWO2_TEST_BINARY is required; never skip acceptance');
    const root = testScratch('w90-empty-state-');
    const home = path.join(root, 'isolated-process-home');
    fs.mkdirSync(home);
    const live = path.join(root, 'live');
    const output = execFileSync(process.env.TATWO2_TEST_BINARY, [], {
      encoding: 'utf8', timeout: 240_000,
      env: {
        PATH: process.env.PATH, TMPDIR: process.env.TMPDIR,
        HOME: home, CFFIXED_USER_HOME: home,
        TATWO2_EMPTYSTATETEST: '1',
        TATWO2_EMPTYSTATE_ROOT: live,
        TATWO2_LIVE_ROOT: live,
        TATWO2_OS_ROOT: path.join(root, 'unused-entry'),
        TATWO2_OS_UPSTREAM_PATH: path.join(root, 'unused-runtime.md'),
      },
    });
    console.log(output.trim());
    assert.match(output, /EMPTYSTATETEST RESULT failed=0/);
    for (const label of ['first load has zero fixture entries', 'first load has zero skills',
      'scan has zero fixture entries', 'remove of unknown id throws',
      'empty library lists no bots', 'live bot page has no principals',
      'live bot page has no thread', 'live bot page has no registered skills',
      'live model offers no thread plugins skills']) {
      assert.ok(output.includes('EMPTYSTATETEST PASS ' + label), label);
    }
    assert.doesNotMatch(output, /EMPTYSTATETEST FAIL/);
  });
