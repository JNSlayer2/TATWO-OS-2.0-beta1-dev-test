import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const root = fileURLToPath(new URL('../', import.meta.url));
const app = 'App/Sources/Tatwo2/';
const diagnostics = app + 'Browser/Diagnostics/';
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const hash = value => createHash('sha256').update(value).digest('hex');
const run = (command, args, options = {}) => {
  const result = spawnSync(command, args, {cwd: root, encoding:'utf8', timeout:90000, ...options});
  assert.equal(result.status, 0, `${result.error ?? ''}\n${result.stdout}\n${result.stderr}`);
  return result.stdout;
};

test('swiftc: real ring, redaction, helper roles/process sampling, audit tail, throttle and report', {
  skip: process.platform !== 'darwin', timeout: 120000,
}, () => {
  const dir = testScratch('browser-diagnostics-');
  fs.mkdirSync(dir, {recursive:true});
  const source = path.join(dir, 'main.swift');
  const binary = path.join(dir, 'fixture');
  fs.writeFileSync(source, String.raw`
import Foundation
import Darwin
if CommandLine.arguments.contains("--child") {
    FileHandle.standardOutput.write(Data([1]))
    _ = FileHandle.standardInput.readDataToEndOfFile()
    exit(0)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let log = BrowserPolicyLog()
for index in 0..<205 {
    log.record(host: "https://user:password@example.com/path?q=private", decision: "allow.\(index)", actor: "human")
}
let entries = log.recent(300)
precondition(entries.count == 200 && entries.first?.decision == "allow.5" && entries.last?.decision == "allow.204")
precondition(entries.allSatisfy { $0.host == "example.com" && !$0.host.contains("?") })
precondition(log.recent().count == 50 && log.recent(-1).isEmpty)
DispatchQueue.concurrentPerform(iterations: 1000) { index in
    log.record(host: "example.com", decision: "allow.\(index)", actor: "agent")
}
precondition(log.recent(200).count == 200 && Set(log.recent(200).map(\.id)).count == 200)
for (args, expected): ([String], BrowserHelperRole) in [
    (["--type=renderer"], .renderer), (["--type=gpu-process"], .gpu),
    (["--type=utility", "--utility-sub-type=network.mojom.NetworkService"], .network),
    (["--type=utility", "--utility-sub-type=storage.mojom.StorageService"], .utility),
    (["--type=utility"], .utility), ([], .other),
    (["--type=renderer-impostor"], .other), (["x--type=renderer"], .other),
    (["--type", "renderer"], .renderer)
] { precondition(BrowserHelperRole.classify(arguments: args) == expected) }
var throttle = BrowserMemoryWarningThrottle()
precondition(!throttle.shouldWarn(helperMB: 1200, thresholdMB: 1200, uptime: 1))
precondition(throttle.shouldWarn(helperMB: 1201, thresholdMB: 1200, uptime: 2))
precondition(!throttle.shouldWarn(helperMB: 2000, thresholdMB: 1200, uptime: 1801.999))
precondition(throttle.shouldWarn(helperMB: 2000, thresholdMB: 1200, uptime: 1802))
precondition(!throttle.shouldWarn(helperMB: .nan, thresholdMB: 1200, uptime: 4000))
precondition(!throttle.shouldWarn(helperMB: 2000, thresholdMB: 0, uptime: 4000))
precondition(BrowserDiagnosticsSettings().memoryWarningMB == 1200)
let auditURL = dir.appendingPathComponent("audit.log")
var records: [String] = []
for index in 0..<70 {
    let record = ["time":"2026-09-14T00:00:00Z", "origin":"https://user:password@example.com/p?password=bad",
        "caller":"agent", "tool":"read\(index)", "decision":"allow", "outcome":"success",
        "password":"do-not-copy", "arguments":"never-copy"]
    let data = try JSONSerialization.data(withJSONObject: record)
    records.append(String(data:data, encoding:.utf8)!)
}
try (records.joined(separator:"\n") + "\n").write(to:auditURL, atomically:true, encoding:.utf8)
var audit = BrowserDiagnosticsAudit.readTail(at:auditURL)
precondition(audit.lines.count == 50 && audit.lines.first!.contains("read20"))
precondition(!audit.lines.joined().contains("?") && !audit.lines.joined().contains("password"))
precondition(!audit.lines.joined().contains("never-copy") && !audit.lines.joined().contains("do-not-copy"))
try (String(repeating:"x", count:300000) + "\n" + records.suffix(50).joined(separator:"\n") + "\n")
    .write(to:auditURL, atomically:true, encoding:.utf8)
precondition(BrowserDiagnosticsAudit.readTail(at:auditURL).lines.count == 50)
try ("not-json password=bad\n" + records[0] + "\npartial").write(to:auditURL, atomically:true, encoding:.utf8)
audit = BrowserDiagnosticsAudit.readTail(at:auditURL)
precondition(audit.lines.count == 1 && audit.status.contains("無效"))
precondition(BrowserDiagnosticsAudit.readTail(at:dir.appendingPathComponent("missing")).lines.isEmpty)
let helperRoot = dir.appendingPathComponent("App.app/Contents/Frameworks")
let helper = helperRoot.appendingPathComponent("Tatwo Helper (Renderer).app/Contents/MacOS/Tatwo Helper (Renderer)")
try FileManager.default.createDirectory(at:helper.deletingLastPathComponent(), withIntermediateDirectories:true)
if !FileManager.default.fileExists(atPath:helper.path) {
    try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[0]), to:helper)
}
let child = Process()
child.executableURL = helper
child.arguments = ["--child", "--type=renderer"]
let ready = Pipe(), lifetime = Pipe()
child.standardOutput = ready
child.standardInput = lifetime
try child.run()
defer { lifetime.fileHandleForWriting.closeFile(); child.waitUntilExit() }
// Process.run() is not a child-startup barrier. Wait for the owned helper's
// explicit ready byte instead of assuming dyld/launch finishes within 150ms.
precondition(ready.fileHandleForReading.readData(ofLength: 1) == Data([1]))
let samples = BrowserProcessSampler.sample(helperRoot:helperRoot.path)
precondition(samples.contains { $0.pid == getpid() && $0.role == "main" && ($0.footprintBytes ?? 0) > 0 })
precondition(samples.contains { $0.pid == child.processIdentifier && $0.role == "renderer" && $0.isHelper && ($0.footprintBytes ?? 0) > 0 })
precondition(!BrowserProcessSampler.sample(helperRoot:dir.appendingPathComponent("unrelated").path).contains { $0.isHelper })
var report = BrowserDiagnosticsReport()
report.processes = samples
report.audit = audit
report.policies = log.recent()
report.tabs = [BrowserDiagnosticsTab(id:UUID(), owner:"chatSession 1", title:"password=hidden",
    host:"example.com?private=secret", sleeping:true, lastActive:Date(), tools:["read | readOnly", "bad?secret"])]
let text = report.text
precondition(!text.lowercased().contains("password") && !text.contains("?") && !text.contains("hidden"))
for section in ["【引擎】","【程序】","【分頁】","【WebMCP】","【政策】"] { precondition(text.contains(section)) }
report.tabs = [BrowserDiagnosticsTab(id:UUID(),owner:"workSpace 1",title:String(repeating:"x",count:400),
    host:"example.com",sleeping:true,lastActive:Date(),tools:[])]
precondition(report.text.contains("example.com | 是 |"))
precondition(BrowserDiagnosticsPrivacy.text("https://user:password@host/a?q=private") == "[網址]")
precondition(!BrowserDiagnosticsPrivacy.text("title%3Fsecret=value").contains("value"))
precondition(!BrowserDiagnosticsPrivacy.text("readPasswordInfo").lowercased().contains("password"))
precondition(BrowserDiagnosticsPrivacy.host("::1") != "—")
print("W55 pure diagnostics and real libproc sampling PASS")
`);
  const files = ['BrowserDiagnosticsPrivacy','BrowserPolicyLog','BrowserDiagnosticsSettings',
    'BrowserProcessSampler','BrowserDiagnosticsAudit','BrowserDiagnosticsReport'].map(name => path.join(root, diagnostics + name + '.swift'));
  run('swiftc', ['-num-threads','2', ...files, source, '-o', binary]);
  assert.match(run(binary, [dir]), /real libproc sampling PASS/);
});

test('swiftc: sleep environment override is finite/positive and keeps selected tabs awake', {
  skip: process.platform !== 'darwin',
}, () => {
  const dir = testScratch('browser-diagnostics-');
  fs.mkdirSync(dir, {recursive:true});
  fs.writeFileSync(path.join(dir,'main.swift'), `import Foundation
let expected = CommandLine.arguments[1] == "auto" ? BrowserMemoryPolicy.defaultSleepSeconds(physicalMemory: ProcessInfo.processInfo.physicalMemory) : Double(CommandLine.arguments[1])!
let interval = BrowserMemorySettings().idleInterval()
precondition(interval == expected)
let now = Date()
precondition(!BrowserTabSleepPolicy.shouldSleep(lastActiveAt:now.addingTimeInterval(-expected-1), now:now, isSelected:true, interval:interval))
precondition(BrowserTabSleepPolicy.shouldSleep(lastActiveAt:now.addingTimeInterval(-expected), now:now, isSelected:false, interval:interval))
`);
  run('swiftc',['-num-threads','2',path.join(root,app+'Browser/BrowserWorkSpacePolicies.swift'), path.join(root,app+'Browser/BrowserMemoryPolicy.swift'), path.join(root,app+'Browser/BrowserMemorySettings.swift'), path.join(root,app+'Browser/BrowserNativeMemoryBudget.swift'),
    path.join(root,app+'Browser/BrowserGeneralSettings.swift'),path.join(root,app+'Browser/BrowserShortcuts.swift'),path.join(dir,'main.swift'),'-o',path.join(dir,'fixture')]);
  for (const [value, expected] of [['2',2],['0','auto'],['-1','auto'],['nan','auto'],['inf','auto'],['oops','auto'],['','auto']]) {
    run(path.join(dir,'fixture'), [String(expected)], {env:{...process.env,TATWO_BROWSER_SLEEP_SECONDS:value}});
  }
});

test('W55 change boundaries: policies identical after removing only logging / env override', () => {
  const security = read(app+'Browser/EmbeddedBrowserSecurity.swift')
    // W57d adds command cases only; the original security-policy digest stays pinned.
    .replace('        case printPage\n        case printPDF\n        case openPDF\n', '')
    .replace('        case stopLoading\n        case find(String, forward: Bool, matchCase: Bool)\n        case stopFinding\n        case zoom(Double)\n', '')
    .replace(/^.*BrowserPolicyLog\.shared\.record.*\n/gm,'')
    .replace('        return actor == .human ? .ask : .deny','        actor == .human ? .ask : .deny');
  assert.equal(hash(security),'7c3bbc8e9eed789827213f7ad77f6c9c9574488ab14d1264a548fef97607f512');
  const actor = read(app+'Browser/BrowserActor.swift').replace(/^.*BrowserPolicyLog\.shared\.record.*\n/gm,'');
  assert.equal(hash(actor),'ac8bf66dde08c537d3e36465dd14222d15a861eddf0021fc8ff73fbf9c12bbbe');
  // W60b owns only the sleep enum; retain W47 omnibox/settings byte-for-byte.
  const sleep = read(app+'Browser/BrowserWorkSpacePolicies.swift').split('enum BrowserTabSleepPolicy {')[0]
    + `enum BrowserTabSleepPolicy {
    static let idleInterval: TimeInterval = 20 * 60
    static func shouldSleep(lastActiveAt: Date, now: Date, isSelected: Bool) -> Bool {
        !isSelected && now.timeIntervalSince(lastActiveAt) >= idleInterval
    }
}
`;
  assert.equal(hash(sleep),'200cdfd5469cdec6716e10d5532b9dc0fb5403ceaddbceff66e85eea3fdc2ba7');
});

test('swiftc: backend timestamps and actual diagnostics refresh stop when page task cancels', {
  skip: process.platform !== 'darwin', timeout:120000,
}, () => {
  const dir = testScratch('browser-diagnostics-');
  fs.mkdirSync(dir,{recursive:true});
  const fixture = path.join(dir,'Fixture.swift');
  fs.writeFileSync(fixture, `
import Foundation
import Combine
${read(app+'Browser/BrowserTabRegistry.swift').split('struct BrowserSpace:')[0]}
@MainActor final class BrowserTabRegistry {
    static let shared = BrowserTabRegistry()
    var tabs: [BrowserTab] = []
    func runtimeTabID(for id: UUID) -> String? { id.uuidString }
}
struct Tool { let name: String; let effect: String }
struct Page { var tools: [Tool] = [] }
@MainActor final class TatwoWebMCPRuntime {
    static let shared = TatwoWebMCPRuntime()
    static let auditURL = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("missing")
    func pageTools(tabID: String) -> Page? { Page(tools:[Tool(name:"read",effect:"readOnly")]) }
}
@MainActor final class IslandNotice {
    static let shared = IslandNotice()
    func info(title:String,detail:String,duration:TimeInterval) {}
}
enum BrowserRuntimeVersion { static let bundledDescription = "fixture-version" }
enum EmbeddedBrowserEnginePolicy {
    enum Engine: String { case chromiumCEF }
    static let current = Engine.chromiumCEF
}
enum TatwoCEFRuntime { static func processDiagnostics() -> [String:Any] {
    ["launchCounts":["renderer":NSNumber(value:23)], "terminationCallbackCount":NSNumber(value:0)]
} }
enum BrowserTabSleepPolicy { static let idleInterval: Double = 300 }
struct BrowserMemorySettings { func limit() -> Int? { 4 }; static func load() -> Self { Self() } }
enum BrowserWorkSpaceRuntime { static let memoryPressureText = "正常" }
@MainActor final class BrowserNativeMemoryBudget { static let shared = BrowserNativeMemoryBudget(); let count = 0 }
@main struct Fixture {
    @MainActor static func main() async throws {
        let telemetry = BrowserEngineStartupTelemetry()
        precondition(telemetry.state == .notStarted && telemetry.startupMilliseconds == nil)
        telemetry.leaseAcquired(uptime:10)
        precondition(telemetry.state == .starting)
        telemetry.initialized(uptime:10.25)
        precondition(telemetry.state == .ready && telemetry.startupMilliseconds == 250)
        telemetry.leaseAcquired(uptime:50)
        telemetry.initialized(uptime:51)
        precondition(telemetry.startupMilliseconds == 250)
        let failed = BrowserEngineStartupTelemetry()
        failed.leaseAcquired(uptime:1); failed.failed()
        precondition(failed.state == .failed && failed.startupMilliseconds == nil)
        let registry = BrowserTabRegistry()
        registry.tabs = [BrowserTab(id:UUID(),owner:.chatSession(sessionID:"private-id"),
            url:URL(string:"https://example.com/path?private=yes"),title:"Page password=hidden",
            isPinned:false,isSleeping:true,lastActiveAt:Date(),createdAt:Date())]
        let model = BrowserDiagnostics(registry:registry)
        let task = Task { await model.observe() }
        try await Task.sleep(for:.milliseconds(200))
        precondition(model.isRefreshing && model.report.tabs.count == 1)
        precondition(model.report.tabs[0].tools == ["read | readOnly"])
        precondition(!model.report.text.contains("private-id") && !model.report.text.contains("password"))
        precondition(model.report.processHealth.launchCounts["renderer"] == 23)
        precondition(model.report.processHealth.terminationCallbackCount == 0)
        let first = model.report.timestamp
        try await Task.sleep(for:.milliseconds(2100))
        precondition(model.report.timestamp > first)
        task.cancel(); await task.value
        precondition(!model.isRefreshing)
        let stopped = model.report.timestamp
        try await Task.sleep(for:.milliseconds(2100))
        precondition(model.report.timestamp == stopped)
        let reopened = Task { await model.observe() }
        try await Task.sleep(for:.milliseconds(200))
        precondition(model.isRefreshing && model.report.timestamp > stopped)
        reopened.cancel(); await reopened.value
        print("W55 actual diagnostics lifecycle PASS")
    }
}`);
  const names = ['BrowserDiagnosticsPrivacy','BrowserPolicyLog','BrowserDiagnosticsSettings','BrowserProcessSampler',
    'BrowserDiagnosticsAudit','BrowserDiagnosticsReport','BrowserEngineStartupTelemetry','BrowserDiagnostics'];
  // Only the native snapshot transport is doubled; actual refresh/lifecycle code is unchanged.
  const controller = path.join(dir,'BrowserDiagnostics.swift');
  fs.writeFileSync(controller, read(diagnostics+'BrowserDiagnostics.swift').replace('import TatwoCEFBridge', ''));
  run('swiftc',['-num-threads','2',...names.filter(name=>name!=='BrowserDiagnostics').map(name=>path.join(root,diagnostics+name+'.swift')), controller,
    fixture,'-o',path.join(dir,'fixture')]);
  assert.match(run(path.join(dir,'fixture'),[dir]),/actual diagnostics lifecycle PASS/);
});

test('both sheet entries, five metrics-based cards, task cancellation and backend-only telemetry', () => {
  const settings = read(app+'Shell/ChatPageSettings.swift');
  assert.match(settings,/Button\("打開診斷頁"\) \{ browserDiagnosticsPresented = true \}/);
  assert.doesNotMatch(settings,/Button\("打開診斷頁"\)[^\n]*disabled/);
  assert.doesNotMatch(settings,/Text\("W55"\)/);
  const sidebar = read(app+'Browser/BrowserWorkSpaceDesignView.swift');
  assert.match(sidebar,/Button\("診斷…"\)/);
  assert.match(sidebar,/sheet\(isPresented: \$diagnosticsPresented\)/);
  const view = read(diagnostics+'BrowserDiagnosticsView.swift');
  for (const title of ['引擎','程序','分頁','WebMCP','政策']) assert.match(view,new RegExp(`BrowserDiagnosticsCard\\(title: "${title}"\\)`));
  assert.match(view,/monospacedDigit/);
  assert.match(view,/BrowserSidebarMetrics/);
  assert.match(view,/\.task \{ await diagnostics.observe\(\) \}/);
  const model = read(diagnostics+'BrowserDiagnostics.swift');
  assert.match(model,/@MainActor\s+final class BrowserDiagnostics: ObservableObject/);
  assert.match(model,/Task\.sleep\(for: \.seconds\(2\)\)/);
  assert.match(model,/guard !Task.isCancelled else/);
  assert.match(model,/private static var memoryWarning/);
  assert.doesNotMatch(model,/TatwoCEFRuntime\.initialize|prepareForRuntime|Timer\.publish/);
  const backend = read(app+'Browser/ChromiumCEFBackend.swift');
  assert.match(backend,/BrowserEngineStartupTelemetry.shared.leaseAcquired\(\)/);
  assert.match(backend,/TatwoCEFRuntime.initialize\([\s\S]*?BrowserEngineStartupTelemetry.shared.initialized\(\)/);
  assert.match(backend,/catch \{\s*BrowserEngineStartupTelemetry.shared.failed\(\)/);
});

test('perf script syntax and honest D-B6 measurement surfaces', () => {
  run('bash',['-n','scripts/browser-perf.sh']);
  const script = read('scripts/browser-perf.sh');
  for (const marker of ['TATWO_BROWSER_WORKSPACE_PREVIEW=1','TATWO_BROWSER_SLEEP_SECONDS','AXConfirm',
    'set value of addressField','https://example.com','Example Domain','systemUptime','WAIT=1500',
    'startup <= 1500','mb <= 400','BrowserProcessSampler.sample','ri_phys_footprint']) assert.ok(script.includes(marker),marker);
  assert.doesNotMatch(script,/\brm -rf\b|sudo|open -a/);
  const invalid = spawnSync('bash',['scripts/browser-perf.sh','does-not-exist'],{cwd:root,encoding:'utf8'});
  assert.equal(invalid.status,2);
  assert.equal(JSON.parse(invalid.stdout).status,'FAIL');
  assert.equal(invalid.stdout.trim().split('\n').length,1);
  if (process.platform === 'darwin') {
    const dir = testScratch('browser-diagnostics-');
    fs.mkdirSync(dir,{recursive:true});
    const appleScript = script.match(/<<'APPLESCRIPT'\n([\s\S]*?)\nAPPLESCRIPT/)?.[1];
    const swift = script.match(/<<'SWIFT'\n([\s\S]*?)\nSWIFT/)?.[1];
    assert.ok(appleScript && swift);
    fs.writeFileSync(path.join(dir,'measure.applescript'),appleScript);
    fs.writeFileSync(path.join(dir,'main.swift'),swift);
    run('osacompile',['-o',path.join(dir,'measure.scpt'),path.join(dir,'measure.applescript')]);
    run('swiftc',['-num-threads','2',path.join(root,diagnostics+'BrowserProcessSampler.swift'),
      path.join(dir,'main.swift'),'-o',path.join(dir,'sample')]);
  }
});
