import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const app = 'App/Sources/Tatwo2/';
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
const section = (s, a, b) => s.slice(s.indexOf(a), s.indexOf(b, s.indexOf(a)));

test('swiftc: human/agent matrix, private navigation, permissions, settings persistence and W44 alias', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/w45/actor-fixture');
  fs.mkdirSync(dir, {recursive: true});
  const security = read(app + 'Browser/EmbeddedBrowserSecurity.swift');
  const source = ['Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift', 'Browser/Diagnostics/BrowserPolicyLog.swift',
    'Chat/TatwoCodexSandboxMode.swift', 'Chat/TatwoPermissionPreset.swift',
    'New/ComputerUseConsentPolicy.swift', 'Browser/BrowserActor.swift'].map(p => read(app + p)).join('\n');
  const code = `import Foundation\nimport AppKit\nimport WebKit\nimport Darwin\n${source}
  enum NativeStagingIsolation { static func isEnabled(_ environment: [String:String]) -> Bool { false } }
  ${section(security, 'enum EmbeddedBrowserNavigationBlockReason', 'enum EmbeddedBrowserVisibleError')}
  ${section(security, 'enum EmbeddedBrowserSensitivePermission:', 'enum EmbeddedBrowserSecurityStatusPresentation')}
  ${section(security, 'enum EmbeddedBrowserSensitivePermissionDecision', 'enum EmbeddedBrowserResponsePolicy')}
  let presets: [TatwoPermissionPreset?] = [nil, .askFirst, .approveForMe, .fullAccess, .configFile]
  for preset in presets { for cookies in [false,true] { for ads in [false,true] {
    let settings = BrowserSecuritySettings(blocksThirdPartyCookies: cookies, adBlock: ads)
    let human = BrowserActorPolicy.resolve(actor: .human, settings: settings)
    precondition(human == BrowserActorPolicy(allowsDownloads: true, popupBehavior: .openAsTab,
      sensitivePermissions: .askViaIsland, privateNetwork: .askOncePerHost, passwordManager: true,
      autofill: true, blocksThirdPartyCookies: cookies, adBlock: ads))
    let actor = BrowserActor.agent(callerID: UUID(), preset: preset)
    let agent = BrowserActorPolicy.resolve(actor: actor, settings: settings)
    precondition(agent == BrowserActorPolicy(allowsDownloads: false, popupBehavior: .block,
      sensitivePermissions: .deny, privateNetwork: .block, passwordManager: false,
      autofill: false, blocksThirdPartyCookies: true, adBlock: ads))
    for host in [[192, 168, 1, 1].map(String.init).joined(separator: "."), "127.0.0.1", "10.0.0.1", "localhost", "nas.local", "[::1]"] {
      let url = URL(string: "http://" + host)!
      precondition(EmbeddedBrowserNavigationPolicy.decision(for: url, actor: .human) == .askOncePerHost(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))))
      if case .block = EmbeddedBrowserNavigationPolicy.decision(for: url, actor: actor) {} else { fatalError("agent private network") }
    }
    for permission: EmbeddedBrowserSensitivePermission in [.camera,.microphone,.cameraAndMicrophone,.geolocation,.deviceOrientationAndMotion] {
      precondition(EmbeddedBrowserSensitivePermissionPolicy.decision(for: permission, actor: .human) == .ask)
      precondition(EmbeddedBrowserSensitivePermissionPolicy.decision(for: permission, actor: actor) == .deny)
    }
    for actor in [BrowserActor.human, actor] {
      precondition(EmbeddedBrowserNavigationPolicy.decision(for: URL(string: "https://example.com"), actor: actor) == .allow)
      precondition(EmbeddedBrowserNavigationPolicy.decision(for: URL(string: "file:///tmp/test"), actor: actor) == .block(.unsupportedScheme))
    }
  } } }
  let url = URL(fileURLWithPath: CommandLine.arguments[1])
  let custom = BrowserSecuritySettings(blocksThirdPartyCookies: false, adBlock: false)
  try custom.save(to: url)
  precondition(BrowserSecuritySettings.load(from: url) == custom)
  try Data("invalid".utf8).write(to: url)
  precondition(BrowserSecuritySettings.load(from: url) == BrowserSecuritySettings())
  precondition(BrowserSecuritySettings().adBlock && BrowserSecuritySettings().blocksThirdPartyCookies)
  for user in presets { for bot in presets { for readOnly in [false,true] {
    precondition(TatwoAgentConsentPolicy.resolve(user: user, bot: bot, readOnly: readOnly) == ComputerUseConsentPolicy.resolve(user: user, bot: bot, readOnly: readOnly))
  } } }
  print("W45 actor matrix and W44 alias PASS")
  `;
  fs.writeFileSync(path.join(dir, 'main.swift'), code);
  const build = spawnSync('swiftc', [path.join(dir, 'main.swift'), '-o', path.join(dir, 'fixture')], {encoding:'utf8', timeout:60000});
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(path.join(dir, 'fixture'), [path.join(dir, 'security.json')], {encoding:'utf8', timeout:10000});
  assert.equal(run.status, 0, run.stderr);
});

test('bridge actors gate downloads, permissions, all resource entry points and context sharing', () => {
  assert.match(section(bridge,'  bool CanDownload(', '  bool OnBeforeBrowse('), /ActorRequestPolicy\(owner_\)\.human/);
  assert.match(section(bridge,'  bool OnBeforeDownload(', '  void OnDownloadUpdated('), /NSDownloadsDirectory/);
  assert.match(section(bridge,'  bool OnBeforeDownload(', '  void OnDownloadUpdated('), /O_EXCL \| O_NOFOLLOW/);
  assert.match(section(bridge,'  void OnDownloadUpdated(', '  bool OnBeforeBrowse('), /onDownloadProgress/);
  for (const [start,end] of [['  bool OnShowPermissionPrompt(', '  void OnLoadingStateChange('],['  bool OnRequestMediaAccessPermission(', '  bool OnShowPermissionPrompt(']]) {
    const body = section(bridge,start,end);
    assert.match(body, /if \(ActorRequestPolicy\(owner_\)\.human && owner_\.onPermissionRequested\)/);
    assert.match(body, /decision && IsPermissionReplyLive\(owner, mount, generation\)/);
  }
  assert.match(bridge, /if \(is_download && !ActorRequestPolicy\(owner_\).human\)/);
  assert.match(bridge, /source.browserActor != actor \|\| \(source.agentControlled && actor == TatwoCEFBrowserActorHuman\)/);
  assert.match(bridge, /if \(!policy.human\) return IsAllowedURLString\(url\)/);
  assert.match(bridge, /policy.blocks_third_party_cookies = !policy.human \|\| owner.blocksThirdPartyCookies/);
  assert.match(bridge, /CompletePendingResourceDecision\(decision_id, allowed && current\)/);
  assert.match(bridge, /onPopupRequested\(url\)/);
  assert.match(bridge, /SetBool\(actor == TatwoCEFBrowserActorHuman && !preference.required_for_privacy_strict\)/);
  const swift = read(app + 'Facade/BrowserAgentBridge.swift');
  assert.match(swift, /TatwoAgentConsentPolicy.resolve\(user: model.permissionPreset/);
  assert.match(swift, /bot: thread.botPermissionPreset, readOnly: thread.roomReadOnly == true/);
  assert.match(swift, /beginAgentInteraction\(\)/);
});

test('human callbacks use bounded Island copy and process-local coalesced host consent', () => {
  const human = read(app + 'Browser/BrowserHumanInteraction.swift');
  assert.match(human, /decisions\[host\]/);
  assert.match(human, /pending\[host\]/);
  assert.match(human, /clean.count <= 14/);
  assert.match(human, /components\(separatedBy: .controlCharacters\)/);
  assert.match(human, /timeout: 20/);
  assert.match(read(app + 'Browser/ChromiumCEFBackend.swift'), /initialURL: startupURL, actor: .human/);
  const store = read(app + 'Browser/BrowserDownloadStore.swift');
  assert.match(store, /QLPreviewPanel.shared\(\)/);
  assert.match(store, /activateFileViewerSelecting/);
  assert.doesNotMatch(store, /removeItem\(|trashItem\(/);
});

test('swiftc: real host consent coalescing, bounded copy and download lifecycle without app UI', {skip: process.platform !== 'darwin'}, () => {
  const dir = path.join(root, '.build/w45/interaction-fixture');
  fs.mkdirSync(dir, {recursive:true});
  const sources = ['Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift','Browser/Diagnostics/BrowserPolicyLog.swift',
    'Chat/TatwoCodexSandboxMode.swift','Chat/TatwoPermissionPreset.swift','Browser/BrowserActor.swift',
    'Browser/BrowserHumanInteraction.swift','Browser/BrowserDownloadStore.swift']
    .map(p => read(app+p).replace('import TatwoCEFBridge','')).join('\n');
  const stubs = `
  @MainActor final class TatwoCEFBrowserView {
    var blocksThirdPartyCookies = true
    var adBlock = true
    var onPrivateNetworkRequested: ((String, @escaping (Bool)->Void)->Void)?
    var onPermissionRequested: ((String,String,@escaping (Bool)->Void)->Void)?
    var onPopupRequested: ((String)->Void)?
    var onDownloadProgress: ((String,String,Int64,Int64,Bool)->Void)?
  }
  @MainActor final class IslandNotice {
    static let shared = IslandNotice()
    enum Decision { case allow, cancel, timeout }
    var continuation: CheckedContinuation<Decision,Never>?
    var asks = 0
    var infos = 0
    func ask(title: String, detail: String, allowLabel: String, timeout: Double) async -> Decision {
      precondition(title.count <= 14 && !detail.contains("\\n") && !detail.contains("\\r"))
      asks += 1
      return await withCheckedContinuation { continuation = $0 }
    }
    func info(title: String, detail: String) {
      precondition(title.count <= 14 && !detail.contains("\\n")); infos += 1
    }
    func answer(_ decision: Decision) { let c = continuation; continuation = nil; c?.resume(returning: decision) }
  }
  @main struct Fixture {
    @MainActor static func main() async {
      let notice = IslandNotice.shared
      let consent = BrowserHumanInteraction.shared
      let first = Task { await consent.allowPrivateHost("NAS.LOCAL.") }
      let second = Task { await consent.allowPrivateHost("nas.local") }
      while notice.continuation == nil { await Task.yield() }
      precondition(notice.asks == 1)
      notice.answer(.allow)
      let firstValue = await first.value
      let secondValue = await second.value
      precondition(firstValue && secondValue)
      let cached = await consent.allowPrivateHost("nas.local")
      precondition(cached && notice.asks == 1)
      let denied = Task { await consent.allowPrivateHost([192, 168, 1, 1].map(String.init).joined(separator: ".")) }
      while notice.continuation == nil { await Task.yield() }
      notice.answer(.cancel)
      let deniedValue = await denied.value
      let cachedDeny = await consent.allowPrivateHost([192, 168, 1, 1].map(String.init).joined(separator: "."))
      precondition(!deniedValue && !cachedDeny && notice.asks == 2)
      precondition(BrowserHumanInteraction.title(String(repeating: "x", count: 100)).count == 14)
      precondition(!BrowserHumanInteraction.oneLine("a\\r\\nb").contains("\\n"))
      let downloads = BrowserDownloadStore.shared
      downloads.update(id: "first", filename: "report.pdf", received: 50, total: 100, done: false)
      precondition(downloads.downloads.count == 1 && !downloads.downloads[0].done)
      downloads.clearDownloads()
      precondition(downloads.downloads.count == 1)
      downloads.update(id: "first", filename: "report.pdf", received: 100, total: 100, done: true)
      downloads.update(id: "first", filename: "report.pdf", received: 100, total: 100, done: true)
      precondition(notice.infos == 1)
      precondition(downloads.downloads[0].fileURL.lastPathComponent == "report.pdf")
      downloads.update(id: "bad", filename: "../unsafe", received: 0, total: 0, done: true)
      precondition(downloads.downloads.count == 1)
      downloads.clearDownloads()
      downloads.update(id: "first", filename: "report.pdf", received: 100, total: 100, done: true)
      precondition(downloads.downloads.isEmpty && notice.infos == 1)
      print("W45 real consent and download lifecycle PASS")
    }
  }
  `;
  fs.writeFileSync(path.join(dir,'fixture.swift'), sources+'\n'+stubs);
  const build=spawnSync('swiftc',['-parse-as-library',path.join(dir,'fixture.swift'),'-o',path.join(dir,'fixture')],{encoding:'utf8',timeout:60000});
  assert.equal(build.status,0,build.stderr);
  const run=spawnSync(path.join(dir,'fixture'),[],{encoding:'utf8',timeout:10000});
  assert.equal(run.status,0,run.stderr);
});

test('W45-fix: popups inherit the opener actor/ad-block flags and late permission replies stop at close_requested', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const popup = bridge.slice(bridge.indexOf('initForPopupWithFrame:(NSRect)frame'), bridge.indexOf('- (BOOL)windowShouldClose:'));
  assert.match(popup, /_browserActor = opener\.browserActor;/);
  assert.match(popup, /_adBlock = opener\.adBlock;/);
  assert.match(popup, /_blocksThirdPartyCookies = opener\.blocksThirdPartyCookies;/);
  const live = bridge.slice(bridge.indexOf('bool IsPermissionReplyLive(TatwoCEFBrowserView *view,\n'), bridge.lastIndexOf('bool IsActiveMountCallback(TatwoCEFBrowserView *view,'));
  assert.match(live, /state->close_requested\) return false;/);
  assert.equal((bridge.match(/decision && IsPermissionReplyLive\(owner, mount, generation\)/g) || []).length, 2);
});

test('W56-fix: host load path treats the exact inert about:blank as allowed (new tabs start there)', () => {
  const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');
  const body = bridge.slice(bridge.indexOf('- (void)queueOrDispatchURLString:(NSString *)urlString'), bridge.indexOf('@"host_navigation_blocked", ERR_BLOCKED_BY_CLIENT, false);'));
  assert.match(body, /const bool inert_blank = \[urlString isEqualToString:@"about:blank"\];/);
  assert.match(body, /if \(!inert_blank &&\s*\(URLHasCredentials\(urlString\) \|\|\s*!IsActorURLAllowed\(policy, urlString\) \|\|\s*local_deny\)\)/);
});
