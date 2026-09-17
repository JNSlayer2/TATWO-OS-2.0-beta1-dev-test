import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { testScratch } from './helpers/test-scratch.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const media = 'App/Sources/Tatwo2/Browser/BrowserMediaFallback.swift';
const source = fs.readFileSync(path.join(root, media), 'utf8');
const bridge = fs.readFileSync(path.join(root,
  'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm'), 'utf8');

test('probe returns only a boolean, without reading content or media URLs', () => {
  const expression = source.match(/static let expression = #"""([\s\S]*?)"""#/)[1];
  for (const [video, expected] of [
    [null, false],
    [{ canPlayType: () => '' }, true],
    [{ canPlayType: () => 'probably' }, false],
    [{ canPlayType: () => 'maybe' }, false],
  ]) {
    const result = vm.runInNewContext(expression, {
      document: { querySelector(selector) {
        assert.equal(selector, 'video');
        return video;
      }, createElement(tag) {
        assert.equal(tag, 'video');
        return new Proxy(video, { get(target, key) {
          assert.equal(key, 'canPlayType');
          return type => {
            assert.equal(type, 'video/mp4; codecs="avc1.42E01E"');
            return target.canPlayType(type);
          };
        } });
      } },
    });
    assert.equal(typeof result, 'boolean');
    assert.equal(result, expected);
  }
  assert.match(source, /NSWorkspace\.shared\.open\(\$0\)/);
});

test('injected media observer reports only kind + host, once per frame, via the existing callback', () => {
  const script = bridge.match(/const char kBrowserActivityScript\[\] = R"JS\(([\s\S]*?)\)JS";/)[1];
  assert.match(script, /document\.createElement\('video'\)\.canPlayType/);
  assert.doesNotMatch(script, /location\.(href|pathname)|innerHTML|textContent|currentSrc/);
  function frame({ support = '', video = true } = {}) {
    const events = new Map();
    const reports = [];
    let tick;
    let present = video;
    const factory = vm.runInNewContext(script, {
      WeakSet,
      location: new Proxy({ host: 'video.example:8443' }, {
        get(target, key) { assert.equal(key, 'host'); return target[key]; },
      }),
      document: {
        createElement(tag) {
          assert.equal(tag, 'video');
          return { canPlayType(type) {
            assert.equal(type, 'video/mp4; codecs="avc1.42E01E"');
            return support;
          } };
        },
        querySelectorAll(selector) {
          assert.equal(selector, 'audio,video');
          return present ? [{ tagName: 'VIDEO', paused: true, ended: true }] : [];
        },
        addEventListener(name, fn) { events.set(name, fn); },
      },
      setInterval(fn, delay) { assert.equal(delay, 1000); tick = fn; },
    });
    assert.equal(factory((...args) => reports.push(args)), true);
    const codecs = () => reports.filter(args => args.length === 1).map(([value]) => {
      assert.deepEqual(Object.keys(value).sort(), ['host', 'kind']);
      assert.equal(value.kind, 'tatwo.media.codec_unsupported');
      assert.equal(value.host, 'video.example:8443');
      return value;
    });
    return { tick: () => tick(), codecs, events, addVideo: () => { present = true; } };
  }
  const absent = frame({ video: false });
  absent.tick();
  assert.equal(absent.codecs().length, 0);
  absent.addVideo();
  absent.tick();
  absent.tick();
  assert.equal(absent.codecs().length, 1);
  const supported = frame({ support: 'probably' });
  supported.tick();
  assert.equal(supported.codecs().length, 0);
  for (const [tagName, code] of [['VIDEO', 2], ['AUDIO', 4], ['IMG', 4]]) {
    supported.events.get('error')({ type: 'error', target: { tagName, error: { code } } });
    assert.equal(supported.codecs().length, 0);
  }
  supported.events.get('error')({ type: 'error', target: { tagName: 'VIDEO', error: { code: 4 } } });
  supported.events.get('error')({ type: 'error', target: { tagName: 'VIDEO', error: { code: 4 } } });
  supported.tick();
  assert.equal(supported.codecs().length, 1);
  const independent = frame();
  independent.events.get('DOMContentLoaded')();
  independent.tick();
  assert.equal(independent.codecs().length, 1);
});

test('native dispatch preserves frame token and human mount guards; Swift rechecks approval identity', () => {
  assert.match(bridge, /CefProcessMessage::Create\("tatwo\.media\.codec_unsupported"\)/);
  const dispatch = bridge.slice(bridge.indexOf('bool TatwoClient::OnProcessMessageReceived('));
  const codec = dispatch.slice(0, dispatch.indexOf('message->GetName() == kBrowserActivityMessage'));
  for (const expected of ['PID_RENDERER', 'state->browser->IsSame(browser)', 'IsActiveMountCallback',
    'activity->second.token', 'frame->GetURL()', 'host != args->GetString(1)',
    'owner.agentControlled', 'owner.isHiddenOrHasHiddenAncestor', 'owner.onDailyShortcut']) {
    assert.ok(codec.includes(expected), expected);
  }
  assert.match(codec, /@"kind": @"tatwo\.media\.codec_unsupported", @"host":/);
  assert.match(source, /browser\.navigationGeneration == generation/);
  assert.match(source, /browser\.isDescendant\(of: host\)/);
  assert.match(source, /browser\.browserActor == \.human && !browser\.agentControlled/);
  assert.match(source, /BrowserWebFeatures\.openInSystemBrowser/);
  const runtime = fs.readFileSync(path.join(root,
    'App/Sources/Tatwo2/Browser/BrowserWorkSpaceCEFSurface.swift'), 'utf8');
  assert.match(runtime, /BrowserMediaFallback\.dispatch\(message: kind/);
  assert.match(runtime, /self\.host === host && self\.selectedID == uuid/);
});

test('actual Swift registry + Island: fixture detection, dedupe, persistence and user-approved open', {
  skip: process.platform !== 'darwin', timeout: 150_000,
}, () => {
  const dir = testScratch('w85-media-');
  const fixture = path.join(dir, 'Fixture.swift');
  const binary = path.join(dir, 'fixture');
  fs.writeFileSync(fixture, String.raw`
import AppKit
import Foundation
@MainActor enum IslandExceptionsNavigation {
    static var shell: Shell?
    final class Shell { func holdOpen(_ value: Bool) {} }
}
@main struct Fixture {
    @MainActor static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("tabs.json")
        let registry = BrowserTabRegistry(storageURL: file)
        let owner = BrowserTabOwner.chatSession(sessionID: "synthetic")
        let url = URL(string: "https://example.com/video")!
        var shown = 0
        var opened: [URL] = []
        var decision = IslandNotice.Decision.allow
        var current = true
        var invalidateWhileAsking = false
        var moveToBotWhileAsking: UUID?
        let notice = IslandNotice(fallback: { request, _, complete in
            shown += 1
            precondition(request.allowLabel == "用系統瀏覽器開此頁")
            precondition(request.title.contains("H.264"))
            if invalidateWhileAsking { current = false }
            if let id = moveToBotWhileAsking { registry.move(id, to: .bot(botID: "synthetic")) }
            let result = decision
            Task { @MainActor in complete(result) }
            return nil
        }, holdOpen: { _ in })
        let tab = registry.openTab(owner: owner, url: url)
        let codecMessage = #"{"kind":"tatwo.media.codec_unsupported","host":"example.com"}"#
        precondition(BrowserMediaFallback.isCodecMessage(codecMessage))
        for invalid in ["{}", "not-json",
            #"{"kind":"tatwo.media.codec_unsupported","host":false}"#,
            #"{"kind":"tatwo.media.codec_unsupported","host":""}"#,
            #"{"kind":"other","host":"example.com"}"#,
            #"{"kind":"tatwo.media.codec_unsupported","host":"example.com","url":"private"}"#] {
            await BrowserMediaFallback.receive(message: invalid, tabID: tab.id, url: url,
                registry: registry, isCurrent: { current }, notice: notice,
                open: { _ in fatalError("invalid message must not open") })
        }
        precondition(shown == 0)
        func receive(_ flag: Bool, _ id: UUID, _ page: URL = url) async {
            await BrowserMediaFallback.receive(message: flag ? codecMessage : "{}", tabID: id, url: page,
                registry: registry, isCurrent: { current }, notice: notice,
                open: { opened.append($0); return true })
        }
        await receive(false, tab.id)
        precondition(shown == 0 && opened.isEmpty)
        await receive(true, tab.id)
        await receive(true, tab.id)
        precondition(shown == 1 && opened == [url])
        // Navigation within the same tab still never repeats the notice.
        let secondSite = URL(string: "https://example.org/video")!
        registry.update(tab.id, url: secondSite, title: "Synthetic", favicon: nil)
        await receive(true, tab.id, secondSite)
        precondition(shown == 1)
        decision = .cancel
        let dismissed = registry.openTab(owner: owner, url: url)
        await receive(true, dismissed.id)
        registry.close(dismissed.id)
        let sameSite = registry.openTab(owner: owner, url: URL(string: "https://example.com/other")!)
        await receive(true, sameSite.id, sameSite.url!)
        precondition(shown == 2 && opened == [url])
        try registry.flush()
        let restored = BrowserTabRegistry(storageURL: file)
        let restoredTab = restored.openTab(owner: owner, url: url)
        precondition(!restored.reserveCodecNotice(tabID: restoredTab.id, url: url))
        precondition(!restored.reserveCodecNotice(tabID: tab.id, url: secondSite))
        // A queued approval cannot open a navigated, closed or recreated page.
        decision = .allow
        invalidateWhileAsking = true
        let stale = registry.openTab(owner: owner, url: secondSite)
        await receive(true, stale.id, secondSite)
        precondition(shown == 3 && opened == [url])
        current = true
        invalidateWhileAsking = false
        let moved = registry.openTab(owner: owner, url: secondSite)
        moveToBotWhileAsking = moved.id
        await receive(true, moved.id, secondSite)
        moveToBotWhileAsking = nil
        precondition(shown == 4 && opened == [url])
        let closed = registry.openTab(owner: owner, url: secondSite)
        registry.close(closed.id)
        await receive(true, closed.id, secondSite)
        let agent = registry.openTab(owner: .bot(botID: "synthetic"), url: secondSite)
        await receive(true, agent.id, secondSite)
        let agentChat = registry.openTab(owner: owner, url: secondSite, isAgentTab: true)
        await receive(true, agentChat.id, secondSite)
        let unsafe = URL(string: "file:///synthetic/video")!
        let local = registry.openTab(owner: owner, url: unsafe)
        await receive(true, local.id, unsafe)
        precondition(shown == 4 && opened == [url])
        // Old registry documents remain readable without the optional fields.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json.removeValue(forKey: "codecNoticeTabIDs")
        json.removeValue(forKey: "dismissedCodecHosts")
        let oldFile = file.deletingLastPathComponent().appendingPathComponent("old-tabs.json")
        try JSONSerialization.data(withJSONObject: json).write(to: oldFile)
        let old = BrowserTabRegistry(storageURL: oldFile)
        precondition(old.persistenceError == nil && !old.tabs.isEmpty)
        // Same-host events on two tabs while Island is waiting cannot queue a
        // second notice which would pop up after the user dismisses the first.
        let concurrent = BrowserTabRegistry()
        let first = concurrent.openTab(owner: owner, url: url)
        let second = concurrent.openTab(owner: owner, url: url)
        let island = IslandNotice(fallback: { _, _, _ in fatalError("unexpected fallback") },
                                  holdOpen: { _ in })
        island.hostAvailable = true
        let waiting = Task { @MainActor in
            await BrowserMediaFallback.receive(codecUnavailable: true, tabID: first.id, url: url,
                registry: concurrent, isCurrent: { true }, notice: island,
                open: { _ in fatalError("cancel must not open") })
        }
        while island.current == nil { await Task.yield() }
        await BrowserMediaFallback.receive(codecUnavailable: true, tabID: second.id, url: url,
            registry: concurrent, isCurrent: { true }, notice: island,
            open: { _ in fatalError("duplicate must not open") })
        island.resolve(.cancel, id: island.current!.id)
        await waiting.value
        precondition(island.current == nil)
        precondition(!concurrent.reserveCodecNotice(tabID: second.id, url: url))
        print("W85 media message fixture passed (codec message -> Island -> approved open)")
    }
}
`);
  const compile = spawnSync('swiftc', [
    '-parse-as-library', '-swift-version', '6', '-num-threads', '2',
    'App/Sources/Tatwo2/Browser/TatwoBrowserLaneCore.swift',
    'App/Sources/Tatwo2/Browser/BrowserTabRegistry.swift',
    'App/Sources/Tatwo2/New/IslandNotice.swift',
    media, fixture, '-o', binary,
  ], { cwd: root, encoding: 'utf8', timeout: 120_000 });
  assert.equal(compile.status, 0, `${compile.error ?? ''}\n${compile.stderr}`);
  const run = spawnSync(binary, [dir], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(run.status, 0, `${run.error ?? ''}\n${run.stdout}\n${run.stderr}`);
  assert.match(run.stdout, /W85 media message fixture passed/);
});
