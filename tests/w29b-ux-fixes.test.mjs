import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
const read = p => fs.readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const app = p => read('App/Sources/Tatwo2/' + p);
function swift(source, args = []) {
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-swift-'));
  fs.writeFileSync(join(root, 'fixture.swift'), source);
  const build = spawnSync('swiftc', ['-parse-as-library', join(root, 'fixture.swift'), '-o', join(root, 'fixture')], { encoding: 'utf8' });
  assert.equal(build.status, 0, build.stderr);
  const run = spawnSync(join(root, 'fixture'), args, { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  return run.stdout;
}

test('D5 real preset honors readOnly, bot override, user fallback, legacy and disclosed Grok equivalence', () => {
  swift(`${app('Chat/TatwoPermissionPreset.swift')}
public enum TatwoCodexSandboxMode { case readOnly, workspaceWrite, dangerFullAccess; public var codexArguments: [String] { [] } }
@main struct Main { static func main() {
  typealias P = TatwoPermissionPreset
  for legacy in [false, true] {
    precondition(P.resolvedSidecarMode(user: .fullAccess, bot: .configFile, readOnly: false, legacyCodexAutoApprove: legacy) == "bypassPermissions")
    for user in P.allCases { for bot in P.allCases {
      precondition(P.resolvedSidecarMode(user: user, bot: bot, readOnly: true, legacyCodexAutoApprove: legacy) == "readOnly")
    } }
  }
  precondition(P.resolvedSidecarMode(user: .fullAccess, bot: .askFirst, readOnly: false, legacyCodexAutoApprove: false) == "default")
  precondition(P.resolvedSidecarMode(user: nil, bot: .configFile, readOnly: false, legacyCodexAutoApprove: true) == "acceptEdits")
  precondition(P.resolvedSidecarMode(user: .configFile, bot: nil, readOnly: false, legacyCodexAutoApprove: true) == nil)
  precondition(P.approveForMe.grokArguments == P.fullAccess.grokArguments)
  for p in [P.approveForMe, .fullAccess] { precondition(p.subtitle.contains("Grok CLI 不區分") && !p.displayName.contains("Grok")) }
} }`);
});

test('D5 docs and bundled rules agree after path redaction; skill root is portable', () => {
  const docs = read('docs/os-upstream.md');
  const resource = app('Resources/os-upstream.md');
  const redact = s => s.replace(/`\/Volumes\/[^`]+`/g, '`<your-volume>/`');
  assert.equal(redact(docs), resource);
  for (const s of [docs, resource]) {
    assert.match(s, /^9\. 發行通道/m);
    assert.match(s, /^10\. 授權跟隨設置/m);
    assert.match(s, /此條對 Claude、Codex、Grok 一體適用/);
    assert.match(s, /\$skillet`（技能根由設定提供）/);
  }
  assert.doesNotMatch(resource, /\/Users\/|\/Volumes\//);
});

test('D5 production refresh accepts only an exact marker; legacy journals remain untrusted', () => {
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-refresh-'));
  swift(`${app('Facade/TatwoResources.swift')}
${app('Facade/OSUpstreamRefresh.swift')}
enum OSUpstream { static let overridePath = "unused" }
@main struct Main { static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let bundle = root.appendingPathComponent("bundle.md")
  let runtime = root.appendingPathComponent("os-upstream.md")
  let marker = root.appendingPathComponent("os-upstream.installed.sha256")
  func write(_ s: String, _ url: URL) throws { try Data(s.utf8).write(to: url, options: .atomic) }
  func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
  func apply(_ stamp: Double = 0) -> OSUpstreamRefresh.Outcome { OSUpstreamRefresh.applyOnLaunch(runtimePath: runtime.path, bundled: bundle, now: Date(timeIntervalSince1970: stamp)) }
  try write("one", bundle)
  precondition(apply() == .installed)
  precondition(apply() == .unchanged)
  try write("two", bundle)
  // W68: a legacy multi-hash journal is not the exact last-installed marker.
  try write(hash("one") + "\\n" + hash("two") + "\\n", marker)
  precondition(apply() == .keptUserEdited)
  precondition(try String(contentsOf: runtime, encoding: .utf8) == "one")
  try write(hash("one") + "\\n", marker)
  guard case .updated(let backup) = apply() else { fatalError("exact marker update") }
  precondition(try String(contentsOfFile: backup, encoding: .utf8) == "one")
  // Equal contents are not permission to adopt/rewrite an untrusted marker.
  try write(hash("one") + "\\n" + hash("two") + "\\n", marker)
  precondition(apply() == .unchanged)
  precondition(try String(contentsOf: marker, encoding: .utf8) == hash("one") + "\\n" + hash("two") + "\\n")
  try write("user edited", runtime)
  try write("three", bundle)
  precondition(apply() == .keptUserEdited)
  precondition(try String(contentsOf: runtime, encoding: .utf8) == "user edited")
  precondition(OSUpstreamRefresh.applyOnLaunch(runtimePath: runtime.path, bundled: nil) == .failed("bundle_missing"))
  // Failed marker write must not change content (marker is a directory).
  let blocked = root.appendingPathComponent("blocked")
  try FileManager.default.createDirectory(at: blocked.appendingPathComponent("os-upstream.installed.sha256"), withIntermediateDirectories: true)
  let missing = blocked.appendingPathComponent("os-upstream.md")
  guard case .failed = OSUpstreamRefresh.applyOnLaunch(runtimePath: missing.path, bundled: bundle) else { fatalError("marker failure") }
  precondition(!FileManager.default.fileExists(atPath: missing.path))
} }`.replaceAll('precondition(try String', 'precondition(try! String'), [root]);
});

test('D10 production plan recovery preserves content and requires new human confirmation', () => {
  swift(`${app('Chat/DistillSubmission.swift')}
${app('Chat/TatwoPlanArtifact.swift')}
struct PRPlanReview: Codable, Equatable, Sendable {}
@main struct Main { static func main() throws {
  var plan = TatwoPlanArtifactV1(threadID: UUID(), objective: "fixture", sections: [.init(title: "做什麼", body: "test")], state: .confirmed, kind: "pr")
  plan.executionTurnID = "fixture-turn"
  let saved = try plan.canonicalJSONData()
  var restored = try JSONDecoder.tatwoPlanArtifact.decode(TatwoPlanArtifactV1.self, from: saved)
  precondition(!restored.recoverInterruptedPR(hasActiveTurn: true))
  precondition(restored.recoverInterruptedPR(hasActiveTurn: false))
  precondition(restored.state == .discussing && restored.executionTurnID == nil)
  precondition(restored.prMessage == "上次實作中斷" && restored.prImplementationInterrupted == true)
  precondition(restored.sections == plan.sections && restored.planID == plan.planID)
  precondition(!restored.recoverInterruptedPR(hasActiveTurn: false))
  let recovered = try JSONDecoder.tatwoPlanArtifact.decode(TatwoPlanArtifactV1.self, from: restored.canonicalJSONData())
  precondition(recovered == restored)
  restored.confirm()
  precondition(restored.state == .confirmed && restored.prImplementationInterrupted == nil)
  for state in [TatwoPlanArtifactV1.State.ready, .discussing] { plan.state = state; precondition(!plan.recoverInterruptedPR(hasActiveTurn: false)) }
  plan.state = .confirmed; plan.prMessage = TatwoPlanArtifactV1.prMovedMessage
  precondition(!plan.recoverInterruptedPR(hasActiveTurn: false))
  plan.prMessage = nil; plan.prContinuationThreadID = UUID()
  precondition(!plan.recoverInterruptedPR(hasActiveTurn: false))
} }`);
  const engine = app('Facade/ChatLiveEngine+Plan.swift');
  assert.match(engine, /recoverInterrupted: Bool = false/);
  const load = engine.slice(engine.indexOf('func loadPlanArtifact'), engine.indexOf('func savePlanArtifact'));
  assert.doesNotMatch(load, /engine\.send|submit|startPRContribution/);
  assert.match(app('Chat/PRPlanActions.swift'), /重試實作/);
  assert.match(app('Chat/PRPlanActions.swift'), /Button\("回到討論", action: onReturnToDiscussion\)/);
});

test('D16 production probe replaces connected status with unknown on nil, empty or omitted server', () => {
  const src = app('Facade/PluginsSource.swift');
  assert.match(src, /PluginProbe\.result\(named: name, in: reply\)/);
  assert.match(src, /livenessCache\.resolve/);
  swift(`${app('Facade/PluginLiveness.swift')}
@main struct Main { static func main() {
 let cache = PluginLivenessCache()
 for probe: [String: PluginLivenessResult]? in [nil, [:], ["two": .init(state: .ready)]] {
   _ = cache.resolve(key: "engine", force: true) { ["one": .init(state: .ready)] }
   _ = cache.resolve(key: "engine", force: true) { probe ?? [:] }
   precondition(cache.value(for: "engine")?["one"] == nil)
   precondition(cache.value(for: "engine") == (probe ?? [:]))
 }
 precondition(PluginProbe.reported(nil).state == .unknown)
} }`);
});

test('D9/D11/D18 wiring and private skill export boundaries', () => {
  const ci = read('.github/workflows/update-policy.yml');
  assert.ok(ci.includes("'beta1/**'"));
  for (const name of ['per-file-delta', 'runtime-determinism', 'invisible-update', 'w28-audit']) assert.ok(ci.includes(`tests/${name}.test.mjs`));
  const card = app('New/UpdateAvailableCard.swift');
  assert.doesNotMatch(card, /executeInCLI|openCLITab|sendLine|在 CLI 分頁執行/);
  assert.ok(card.includes('複製指令') && card.includes('退出 TATWO OS 後在終端機貼上'));
  assert.doesNotMatch(read('skills/tatwo-ultrawork/SKILL.md'), /references\/legacy-20260912/);
  const skill = read('skills/tatwo-os-update/SKILL.md');
  for (const text of ['基本附件十個', 'results/<uuid>.json', '重新啟動以更新', 'keptUserEdited']) assert.ok(skill.includes(text));
});

test('D23 all 333 reviewed allowances constrain every detected value; unknown values fail closed', () => {
  const policy = read('scripts/public-safety-allow.txt').split('\n').filter(s => s && !s.startsWith('#'));
  // v2.0.8 has 324 entries; W71–W83 appended 9 reviewed fixture allowances.
  // W84 adds none and restores the immutable W61 prefix (public-privacy.test).
  // Retain an exact count and check EVERY entry, including those additions.
  assert.equal(policy.length, 333);
  for (const line of policy) {
    const regex = line.split('|').slice(3).join('|').trim();
    assert.ok(regex.startsWith('^') && regex.endsWith('$'));
    assert.equal(new RegExp(regex).test('unreviewed-value'), false);
  }
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-scan-'));
  const rel = 'App/Sources/Tatwo2/Facade/BrowserRuntimeAcceptance.swift';
  fs.mkdirSync(join(root, 'App/Sources/Tatwo2/Facade'), { recursive: true });
  fs.writeFileSync(join(root, rel), read(rel));
  const scan = () => spawnSync('node', ['scripts/public-safety-scan.mjs', root], { encoding: 'utf8' });
  assert.equal(scan().status, 0);
  // A second, unreviewed mailbox cannot inherit a known fixture's allowance.
  fs.appendFileSync(join(root, rel), '\n"unreviewed' + String.fromCharCode(64) + 'example.invalid"\n');
  assert.equal(scan().status, 1);
  const known = read(rel).split('\n').find(s => s.includes('@'));
  fs.writeFileSync(join(root, rel), known + ' "unreviewed' + String.fromCharCode(64) + 'example.invalid"');
  assert.equal(scan().status, 1);
});

test('D16 actual async registry scan records completion time, not its supplied entry clock', () => {
  const src = app('Facade/ChatPageModel.swift');
  const method = src.slice(src.indexOf('    func reloadPluginRegistry('), src.indexOf('    func isThreadPluginEnabled('));
  swift(`import Foundation
enum PluginsSource {
 static func scanNow(environment: [String: String]) -> [Int] { [1] }
 static func refreshNow(environment: [String: String]) -> [Int] { Thread.sleep(forTimeInterval: 0.03); return [2] }
}
@MainActor final class Model {
 var isLive = true, pluginRefreshTask: Task<Void, Never>?
 var lastPluginScanAt = Date.distantPast
 var runtimeEnvironment: [String: String] = [:], pluginEntries: [Int] = [], skillSuggestionSelectedIndex: Int?
 ${method}
}
@main struct Main { @MainActor static func main() async {
 let model = Model(), entered = Date()
 let first = model.reloadPluginRegistry(now: Date(timeIntervalSince1970: 0))!
 await first.value
 precondition(model.pluginEntries == [2] && model.lastPluginScanAt >= entered)
 precondition(model.pluginRefreshTask == nil)
 precondition(model.reloadPluginRegistry(ifOlderThan: 60) == nil)
} }`);
});

test('D23 key-header allowance preserves exact indentation in all regex alternatives', () => {
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-key-pattern-'));
  const rel = 'Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoSkilletRepositoryStore.swift';
  fs.mkdirSync(join(root, 'Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore'), { recursive: true });
  fs.writeFileSync(join(root, rel), read(rel));
  const scan = spawnSync('node', ['scripts/public-safety-scan.mjs', root], { encoding: 'utf8' });
  assert.equal(scan.status, 0, scan.stderr);
});

test('D8 build input mode is read-only and missing iPad source is rejected before output', () => {
  const check = spawnSync('bash', ['scripts/build-app.sh', '--check-inputs'], { encoding: 'utf8' });
  assert.equal(check.status, 0, check.stderr);
  assert.match(check.stdout, /BUILD APP INPUTS PASS/);
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-ipad-inputs-'));
  const source = join(root, 'device');
  fs.cpSync('Device/iPadUseDevice', source, { recursive: true });
  fs.renameSync(join(source, 'project.yml'), join(source, 'project.yml.saved'));
  const missing = spawnSync('bash', ['scripts/stage-ipad-use-device.sh', source, '--check-inputs'], { encoding: 'utf8' });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /missing device source: project.yml/);
  assert.equal(fs.existsSync(join(root, '--check-inputs')), false);
});

test('D10 actual live/plans loader recovers only on canvas load with no active turn or completion', () => {
  const src = app('Facade/ChatLiveEngine+Plan.swift');
  const methods = src.slice(src.indexOf('    private func planURL('), src.indexOf('    /// Appends'));
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-plan-load-'));
  swift(`${app('Chat/DistillSubmission.swift')}
${app('Chat/TatwoPlanArtifact.swift')}
struct PRPlanReview: Codable, Equatable, Sendable {}
final class ChatLiveEngine {
 struct Store { let url: URL }
 let store: Store
 var running = false
 var onTurnComplete: [UUID: () -> Void] = [:]
 var onPlanChange: ((TatwoPlanArtifactV1) -> Void)?
 init(_ url: URL) { store = Store(url: url) }
 func isRunning(_ id: UUID) -> Bool { running }
 ${methods}
}
@main struct Main { static func main() throws {
 let engine = ChatLiveEngine(URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("store.json"))
 let plan = TatwoPlanArtifactV1(threadID: UUID(), objective: "fixture", state: .confirmed, kind: "pr")
 try engine.savePlanArtifact(plan)
 precondition(try! engine.loadPlanArtifact(plan.threadID)?.state == .confirmed)
 engine.running = true
 precondition(try! engine.loadPlanArtifact(plan.threadID, recoverInterrupted: true)?.state == .confirmed)
 engine.running = false; engine.onTurnComplete[plan.threadID] = {}
 precondition(try! engine.loadPlanArtifact(plan.threadID, recoverInterrupted: true)?.state == .confirmed)
 engine.onTurnComplete[plan.threadID] = nil
 let recovered = try engine.loadPlanArtifact(plan.threadID, recoverInterrupted: true)!
 precondition(recovered.state == .discussing && recovered.prImplementationInterrupted == true)
 precondition(try! engine.loadPlanArtifact(plan.threadID) == recovered)
} }`, [root]);
});

test('D23 outer anchors constrain every policy alternative, not only first and last', () => {
  const root = fs.mkdtempSync(join(tmpdir(), 'w29b-policy-'));
  const tree = join(root, 'tree'); fs.mkdirSync(tree);
  fs.writeFileSync(join(root, 'scanner.mjs'), read('scripts/public-safety-scan.mjs'));
  const policy = join(root, 'public-safety-allow.txt');
  fs.writeFileSync(join(tree, 'fixture.txt'), 'unreviewed' + String.fromCharCode(64) + 'example.invalid');
  fs.writeFileSync(policy, 'fixture.txt | email address | negative fixture | ^never|invalid$\n');
  const scan = () => spawnSync('node', [join(root, 'scanner.mjs'), tree], { encoding: 'utf8' });
  assert.equal(scan().status, 1);
  fs.writeFileSync(policy, 'fixture.txt | email address | exact fixture | ^unreviewed\\x40example\\.invalid$\n');
  assert.equal(scan().status, 0);
  fs.writeFileSync(policy, 'fixture.txt | email address | invalid regex | ^[$\n');
  assert.equal(scan().status, 1);
});

test('D10 successful completion persists ready and review together, never confirmed with a review', () => {
  const model = app('Facade/ChatPageModel.swift');
  const complete = model.slice(model.indexOf('plan.sections = sections; plan.state = .ready'), model.indexOf('guard engine.send(threadID: id'));
  assert.ok(complete.indexOf('plan.state = .ready') < complete.indexOf('plan.prReview = PRPlanReview('));
  assert.ok(complete.indexOf('plan.prReview = PRPlanReview(') < complete.indexOf('try engine.savePlanArtifact(plan)'));
  assert.doesNotMatch(complete, /await/);
});
