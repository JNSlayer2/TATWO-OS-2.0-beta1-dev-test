import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const refresh = read('App/Sources/Tatwo2/Facade/OSUpstreamRefresh.swift');
const shell = read('App/Sources/Tatwo2/Shell/AppShell.swift');
const selfTest = read('App/Sources/Tatwo2/SelfTest.swift');

test('refresh API uses runtime override, bundle resource, injectable time and CryptoKit', () => {
  assert.match(refresh, /enum OSUpstreamRefresh/);
  assert.match(refresh, /static func applyOnLaunch\([\s\S]*runtimePath: String = OSUpstream\.overridePath/);
  assert.match(refresh, /bundled: URL\? = OSUpstreamRefresh\.bundledURL/);
  assert.match(refresh, /TatwoResources\.url\(forResource: "os-upstream", withExtension: "md"\)/);
  const resources = read('App/Sources/Tatwo2/Facade/TatwoResources.swift');
  assert.match(resources, /TatwoUltrawork_Tatwo2\.bundle/);
  assert.match(resources, /Bundle\.main\.resourceURL/);
  assert.doesNotMatch(resources, /Bundle\.module|fatalError\(/);
  assert.match(refresh, /now: Date = Date\(\)[\s\S]*-> Outcome/);
  assert.match(refresh, /import CryptoKit/);
  assert.match(refresh, /SHA256\.hash\(data: data\)/);
});

test('four normal outcomes and a non-throwing failure outcome exist', () => {
  for (const outcome of ['installed', 'updated', 'keptUserEdited', 'unchanged', 'failed']) {
    assert.match(refresh, new RegExp(`return \\.${outcome}\\b`));
  }
  assert.match(refresh, /updated\(backup: String\)/);
  assert.match(refresh, /failed\(String\)/);
  assert.match(refresh, /catch \{[\s\S]*return \.failed/);
  assert.doesNotMatch(refresh, /try!|fatalError\(|preconditionFailure\(|Bundle\.module\.url/);
});

test('marker protects unmarked and edited content; writes are atomic', () => {
  assert.match(refresh, /os-upstream\.installed\.sha256/);
  assert.match(refresh, /guard markerText == current else/);
  assert.match(refresh, /if current == digest/);
  assert.match(refresh, /os-upstream\.update-available\.md/);
  assert.doesNotMatch(refresh, /installed\?\.contains|installed\.contains/);
  assert.match(refresh, /keptChoice\(in: directory\) == current \+ "\\n" \+ digest/);
  assert.ok((refresh.match(/options: \.atomic/g) ?? []).length >= 4);
});

test('backup uses UTC sortable filename and saves exclusive preimage bytes before replacement', () => {
  assert.match(refresh, /TimeZone\(secondsFromGMT: 0\)/);
  assert.match(refresh, /"yyyyMMdd'T'HHmmssSSS'Z'"/);
  assert.match(refresh, /"os-upstream\.md\.bak-\\\(formatter\.string\(from: now\)\)"/);
  assert.match(refresh, /Darwin\.open\(backup\.path, O_WRONLY \| O_CREAT \| O_EXCL, mode_t\(0o600\)\)/);
  assert.match(refresh, /try handle\.write\(contentsOf: preimage\)[\s\S]*try handle\.synchronize\(\)[\s\S]*try writeManaged\(content/);
});

test('App delegate refreshes once before services, logs once without a dialog', () => {
  assert.equal((shell.match(/OSUpstreamRefresh\.applyOnLaunch\(\)/g) ?? []).length, 1);
  assert.match(shell, /func applicationDidFinishLaunching[^}]*OSUpstreamRefresh\.applyOnLaunch\(\)[^}]*tatwo_os_upstream=[^}]*startLocalMCPServer\(\)/);
  assert.match(shell, /fputs\("tatwo_os_upstream=\\\(upstream\.logMessage\)\\n", stderr\)/);
  assert.doesNotMatch(refresh, /NSAlert|NSHomeDirectory|localizedDescription/);
});

test('headless checks exercise production refresh in temporary fixtures', () => {
  assert.match(selfTest, /TATWO2_OSUPSTREAMREFRESHTEST[\s\S]*exit\(runOSUpstreamRefreshTest\(\) \? 0 : 1\)/);
  const checks = selfTest.slice(selfTest.indexOf('static func runOSUpstreamRefreshTest()'), selfTest.indexOf('/// TATWO2_DOCSTEST'));
  assert.match(checks, /fm\.temporaryDirectory/);
  for (const outcome of ['installed', 'updated', 'keptUserEdited', 'unchanged', 'failed']) {
    assert.match(checks, new RegExp(`\\.${outcome}\\b`));
  }
  assert.match(checks, /os-upstream\.md\.bak-19700101T000000000Z/);
  assert.match(checks, /OSUPSTREAMREFRESHTEST ALL PASS/);
});
