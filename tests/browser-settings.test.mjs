import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const app = path.join(root, 'App/Sources/Tatwo2');
const read = p => fs.readFileSync(path.join(app, p), 'utf8');
const settings = read('Shell/ChatPageSettings.swift');
const section = (a, b) => settings.slice(settings.indexOf(a), settings.indexOf(b, settings.indexOf(a)));

test('W57e seven ordered sections replace the open-session card; W50 stays embedded', () => {
  const body = section('private var browserSettingsContent:', 'private func browserSettingsCard');
  let last = -1;
  for (const title of ['Browser work space', '快捷鍵', 'Session 瀏覽器', '密碼', '擴充功能', '引擎與安全', '診斷']) {
    const index = body.indexOf(title);
    assert.ok(index > last, `${title} order`);
    last = index;
  }
  assert.match(body, /BrowserPasswordsSettingsView\(\)/);
  const sources = fs.readdirSync(app, {recursive:true}).filter(p => p.endsWith('.swift'));
  for (const p of sources) assert.doesNotMatch(read(p).split("\n").filter(line => !line.trim().startsWith("//")).join("\n"), /OpenBrowsersCard/);
  assert.match(settings, /spaces\.filter \{ !\$0\.isSessionSpace \}/);
  assert.match(settings, /openSessions\.count/);
  assert.match(settings, /tatwo\.browser\.openSessionSpace/);
  assert.match(settings, /tatwo\.browser\.openImport/);
  assert.match(settings, /registry: model\.browserTabRegistry/);
  assert.match(read('Browser/BrowserManagementView.swift'), /Text\("工作階段資料"\)/);
});

test('W51 honest extension copy, immutable AI column and W55 diagnostics', () => {
  const extensions = section('browserSettingsCard("擴充功能")', 'browserSettingsCard("引擎與安全")');
  assert.match(extensions, /2\.0\.7 尚未支援 Chrome 擴充功能/);
  assert.match(extensions, /導入時只會列出你原本的擴充功能，不會安裝/);
  assert.doesNotMatch(extensions, /Toggle|Picker|Button|TextField/);
  const ai = section('private var browserAISecurityColumn:', 'private var browserDiagnosticsSettings:');
  assert.doesNotMatch(ai, /Toggle|Picker|Button|TextField|Binding|Slider|Stepper/);
  assert.match(ai, /foregroundStyle\(LiquidGlassTokens.browserMutedInk\)/);
  assert.match(ai, /唯讀（跟隨共用設定）/);
  const human = section('private var browserHumanSecurityColumn:', 'private var browserAISecurityColumn:');
  assert.equal((human.match(/Toggle\(/g) ?? []).length, 2);
  assert.match(settings, /變更在下一個新分頁生效/);
  assert.match(settings, /Button\("打開診斷頁"\) \{ browserDiagnosticsPresented = true \}/);
  assert.match(settings, /BrowserDiagnosticsView\(registry: model.browserTabRegistry\)/);
});

test('swiftc: settings round-trip, engine URLs, policy reload, metadata and Netscape export', {
  skip: process.platform !== 'darwin', timeout: 90000,
}, () => {
  const dir = testScratch('browser-settings-');
  fs.mkdirSync(dir, {recursive:true});
  const registryTypes = read('Browser/BrowserTabRegistry.swift').split('struct BrowserLaneSnapshot:')[0];
  const fixture = `import Foundation
  ${read('Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift')}
  ${read('Browser/Diagnostics/BrowserPolicyLog.swift')}
  ${read('Chat/TatwoCodexSandboxMode.swift')}
  ${read('Chat/TatwoPermissionPreset.swift')}
  ${read('Browser/BrowserActor.swift')}
  ${read('Browser/BrowserShortcuts.swift')}
  ${read('Browser/BrowserGeneralSettings.swift')}
  ${registryTypes}
  @MainActor final class BrowserTabRegistry { var spaces: [BrowserSpace] = [] }
  ${read('Browser/BrowserBookmarkExport.swift')}
  @main struct Fixture {
    @MainActor static func main() throws {
      let dir = URL(fileURLWithPath: CommandLine.arguments[1])
      let url = dir.appendingPathComponent("settings.json")
      try? FileManager.default.removeItem(at: url)  // fixed fixture dir: drop the previous run's file
      let defaults = BrowserGeneralSettings()
      precondition(defaults.defaultSpaceID == nil && defaults.searchEngine == .google && defaults.sessionRetention == .keep)
      for engine in BrowserSearchEngine.allCases {
        for retention in BrowserGeneralSettings.SessionRetention.allCases {
          for id in [nil, UUID()] {
            let value = BrowserGeneralSettings(defaultSpaceID: id, searchEngine: engine, sessionRetention: retention)
            try value.save(to: url)
            precondition(BrowserGeneralSettings.load(from: url) == value)
          }
        }
        for query in ["繁體中文 & ?#=+ /", "", "a b"] {
          let components = URLComponents(url: engine.queryURL(query), resolvingAgainstBaseURL: false)!
          precondition(components.scheme == "https" && components.queryItems == [URLQueryItem(name: "q", value: query)])
          precondition(!engine.queryURL(query).absoluteString.contains("+"))
          switch engine {
          case .google: precondition(components.host == "www.google.com" && components.path == "/search")
          case .duckduckgo: precondition(components.host == "duckduckgo.com" && components.path == "/")
          case .bing: precondition(components.host == "www.bing.com" && components.path == "/search")
          }
        }
      }
      for cookies in [true, false] { for ads in [true, false] {
        let security = BrowserSecuritySettings(blocksThirdPartyCookies: cookies, adBlock: ads)
        let securityURL = dir.appendingPathComponent("security.json")
        try security.save(to: securityURL)
        let loaded = BrowserSecuritySettings.load(from: securityURL)
        precondition(loaded == security)
        let policy = BrowserActorPolicy.resolve(actor: .human, settings: loaded)
        precondition(policy.blocksThirdPartyCookies == cookies && policy.adBlock == ads && policy.allowsDownloads)
        let ai = BrowserActorPolicy.resolve(actor: .strict, settings: loaded)
        precondition(ai.blocksThirdPartyCookies && !ai.allowsDownloads && ai.adBlock == ads)
      } }
      try Data("broken".utf8).write(to: url)
      precondition(BrowserGeneralSettings.load(from: url) == defaults)
      precondition(BrowserRuntimeVersion.load(from: [url]) == "未知")
      let metadata = URL(fileURLWithPath: CommandLine.arguments[2])
      precondition(BrowserRuntimeVersion.load(from: [url, metadata]) == "CEF 151.3.24 / Chromium 151.0.7922.174")
      let registry = BrowserTabRegistry()
      let bookmark = BrowserBookmark(id: UUID(), url: URL(string: "https://example.com/?a=1&b=2")!, title: "<Title> & Test")
      let folder = BrowserFolder(id: UUID(), name: "Folder", bookmarks: [bookmark])
      registry.spaces = [BrowserSpace(id: UUID(), name: "Work & Space", folders: [folder], isSessionSpace: false),
        BrowserSpace(id: UUID(), name: "SESSION_MUST_NOT_EXPORT", folders: [folder], isSessionSpace: true)]
      let html = BrowserBookmarkExport.html(registry: registry)
      precondition(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
      precondition(html.contains("Work &amp; Space") && html.contains("&lt;Title&gt; &amp; Test"))
      precondition(html.contains("?a=1&amp;b=2") && !html.contains("SESSION_MUST_NOT_EXPORT"))
      precondition(html.components(separatedBy: "<DL><p>").count == html.components(separatedBy: "</DL><p>").count)
      print("W52 fixtures PASS")
    }
  }`;
  const source = path.join(dir, 'fixture.swift'), bin = path.join(dir, 'fixture');
  fs.writeFileSync(source, fixture);
  const build = spawnSync('swiftc', ['-parse-as-library', source, '-o', bin], {encoding:'utf8', timeout:60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(bin, [dir, path.join(root, 'Apps/TatwoUltraworkMac/CEF/cef-runtime-arm64.json')], {encoding:'utf8', timeout:10000});
  assert.equal(run.status, 0, run.stderr);
});

test('W52-fix: BrowserGeneralSettings tolerates a W47-only settings.json and merge-saves without resetting searchEngine', () => {
  const settings = fs.readFileSync(new URL('../App/Sources/Tatwo2/Browser/BrowserGeneralSettings.swift', import.meta.url), 'utf8');
  assert.match(settings, /decodeIfPresent\(BrowserSearchEngine\.self, forKey: \.searchEngine\) \?\? \.google/);
  assert.match(settings, /decodeIfPresent\(SessionRetention\.self, forKey: \.sessionRetention\) \?\? \.keep/);
  assert.match(settings, /JSONSerialization\.jsonObject\(with: data\)/);
  assert.doesNotMatch(settings, /JSONEncoder\(\)\.encode\(self\)\.write/);
});
