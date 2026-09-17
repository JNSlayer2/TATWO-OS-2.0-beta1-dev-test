import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root = fileURLToPath(new URL('../', import.meta.url));
const app = 'App/Sources/Tatwo2/';
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
function run(cmd, args, options = {}) {
  const r = spawnSync(cmd, args, {cwd:root, encoding:'utf8', timeout:120000, maxBuffer:16*1024*1024, ...options});
  assert.equal(r.status, 0, `${cmd}: ${r.error ?? ''}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
}

test('MCP cards bind only liveness, removal confirms via Island, builtins precede external MCP', () => {
  const card = read(app+'Pages/PluginConnectionCard.swift');
  assert.match(card, /PluginLivenessStatusPill\(state: entry\.liveness\)/);
  const pill = card.slice(0,card.indexOf('struct PluginConnectionCard'));
  assert.doesNotMatch(pill, /InstallState|installState/);
  for (const label of ['內建','誰能用：','工具數：','最近呼叫：','移除登記']) assert.ok(card.includes(label), label);
  assert.match(card, /entry\.kind == \.mcp && entry\.liveness\.state == \.unreachable/);
  const page = read(app+'Pages/PluginsPage.swift');
  assert.match(page, /IslandNotice\.shared\.confirm/);
  assert.match(page, /guard await IslandNotice[\s\S]*remove\(entry\)/);
  assert.match(page, /重新探活/);
  assert.match(page, /refreshMCP\(force: true\)/);
  assert.match(page, /builtins \+ fresh\.filter/);
  assert.doesNotMatch(read(app+'Facade/PluginsSource.swift'), /已設定・常駐|probeClaudeStatuses/);
});

test('Skillet and Pocket sources and protected PluginsPage regions are unchanged', () => {
  const result=spawnSync('git',['rev-parse','--is-inside-work-tree'],{cwd:root,encoding:'utf8'});
  if(result.status!==0) return; // Public export intentionally contains no git metadata.
  const names=run('git',['diff','--name-only','HEAD','--','*Skillet*','*skillet*','*Pocket*','*pocket*']);
  assert.equal(names.trim(),'');
  const baseline=run('git',['show','HEAD:'+app+'Pages/PluginsPage.swift']);
  const current=read(app+'Pages/PluginsPage.swift');
  for (const [start,end] of [
    ['    private var skillsSection:', '    private func sectionEmptyHint('],
    ['    private func registryRow(', '    private func register('],
    ['        .confirmationDialog(', '    @ViewBuilder'],
    ['            if selectedTab == "pocket" {', '            } else {'],
  ]) {
    assert.equal(current.slice(current.indexOf(start),current.indexOf(end,current.indexOf(start))),
      baseline.slice(baseline.indexOf(start),baseline.indexOf(end,baseline.indexOf(start))),start);
  }
  assert.equal(run('git',['diff','HEAD','--',app+'Shell/SharedComponents.swift']).trim(),'');
});

// Each test creates these immutable declarations; no prior test output is required.
function writeFixtureStubs(dir) {
  const registry=read(app+'Facade/OS1Stubs.swift');
  const declarations=registry.slice(registry.indexOf('enum RegistryKind: String'),registry.indexOf('// TatwoWorkOSContractV1：已由照搬檔提供',registry.indexOf('enum RegistryKind: String')));
  fs.writeFileSync(path.join(dir,'stubs.swift'),`import Foundation
extension Bundle { static var module: Bundle { .main } }
enum InstallState: String, Sendable { case installed, missing, skipped, unknown }
enum PluginSafetyLevel: String, Sendable { case low, medium, high }
${declarations}
enum PluginsFixture { static let entries: [PluginRegistryEntry] = [] }
struct GitHubAccountRecord { var username: String; var mcpAlwaysOn = false }
struct GitHubAccountsStore {
 init(environment: [String:String]) {}
 func loadAccounts() throws -> [GitHubAccountRecord] { [] }
 func mcpToken(username: String) throws -> String? { nil }
}
enum ClaudeSidecar { enum Kind { case claude }; static func scriptPath(for: Kind) -> String { "/unavailable/sidecar.mjs" } }
@MainActor enum ComputerUseSettings { struct Value { let enabled = true }; static let shared = Value() }
@MainActor enum TatwoWebMCPRuntime {
 struct Value { let registeredToolCount = 0 }; static let shared = Value()
 nonisolated static let auditURL = URL(fileURLWithPath:"/unavailable/audit.log")
}
enum OSAgentBridge { struct Value { let isListening = false }; static let shared = Value() }
enum BrowserAgentBridge { struct Value { let isListening = false }; static let shared = Value() }
`);
}

test('swiftc production liveness, real fake configs, timeout, cache, builtins, audit and safe removal', {skip:process.platform!=='darwin'}, () => {
  const dir=testScratch('plugins-liveness-'); fs.mkdirSync(dir,{recursive:true});
  writeFixtureStubs(dir);
  fs.writeFileSync(path.join(dir,'main.swift'),String.raw`import Foundation
import Darwin
let root = URL(fileURLWithPath:CommandLine.arguments[1])
let repo = URL(fileURLWithPath:CommandLine.arguments[2])
let fm = FileManager.default
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); checks += 1 }
func write(_ text: String, _ url: URL) throws {
 try fm.createDirectory(at:url.deletingLastPathComponent(), withIntermediateDirectories:true)
 try text.write(to:url,atomically:true,encoding:.utf8)
}
let labels = ["已接","探測中","連不上","已停用","未探測"]
let colors = ["green","yellow","red","gray","gray"]
for (i,state) in PluginLiveness.allCases.enumerated() {
 check(state.pillText == labels[i] && state.pillColor == colors[i], "pill")
 let encoded = try JSONEncoder().encode(PluginLivenessResult(state:state))
 check(try! JSONDecoder().decode(PluginLivenessResult.self,from:encoded).state == state,"codable")
}
let epoch = Date(timeIntervalSince1970:1000), cache = PluginLivenessCache()
var calls = 0
func probe() -> [String:PluginLivenessResult] { calls += 1; return ["example":.init(state:.ready)] }
_ = cache.resolve(key:"a",force:false,now:epoch,probe:probe)
_ = cache.resolve(key:"a",force:false,now:epoch.addingTimeInterval(59.99),probe:probe)
check(calls == 1,"60 second cache")
_ = cache.resolve(key:"a",force:false,now:epoch.addingTimeInterval(60),probe:probe)
check(calls == 2,"cache expires at 60")
_ = cache.resolve(key:"a",force:true,now:epoch.addingTimeInterval(61),probe:probe)
check(calls == 3,"force bypass")
check(cache.value(for:"other",now:epoch) == nil,"scope isolation")
_ = cache.resolve(key:"a",force:true,now:epoch.addingTimeInterval(62)) { [:] }
check(cache.value(for:"a",now:epoch.addingTimeInterval(63))?.isEmpty == true,"omitted status replaces green")
check(PluginProbe.reported(nil).state == .unknown,"missing status never green")
check(PluginProbe.reported("configured").state == .unknown,"configured is not connected")
check(PluginProbe.reported("failed").state == .unreachable,"SDK failure")
let home = root.appendingPathComponent("home"), engines = root.appendingPathComponent("engines")
let resources = root.appendingPathComponent("resources")
var env = ["HOME":home.path,"CFFIXED_USER_HOME":home.path,"TATWO_STAGING_SCRATCH_HOME":home.path,
 "TATWO_STAGING_ROOT":root.path,"TATWO2_ENGINES_ROOT":engines.path,"TATWO2_LIVE_ROOT":root.appendingPathComponent("live").path,
 "CODEX_HOME":engines.appendingPathComponent("codex").path,"TATWO2_CODEX_SOURCE_HOME":engines.appendingPathComponent("codex").path,
 "CLAUDE_CONFIG_DIR":engines.appendingPathComponent("claude").path,"CLAUDE_SECURESTORAGE_CONFIG_DIR":engines.appendingPathComponent("claude").path,
 "TATWO2_RESOURCES_ROOT":resources.path,"PATH":"/usr/bin:/bin"]
for (key,leaf) in [("TATWO2_OS_SOCKET","os.sock"),("TATWO2_BROWSER_SOCKET","browser.sock"),("TATWO2_OS_ROOT","os"),
 ("TATWO2_DOCS_ROOT","docs"),("TATWO2_OS_UPSTREAM_PATH","upstream"),("TATWO2_SKILLET_PATH","skillet")] { env[key] = root.appendingPathComponent(leaf).path }
try fm.createDirectory(at:home,withIntermediateDirectories:true)
check(NativeStagingIsolation.validationError(env) == nil,"isolated fixture roots")
for engine in PluginsSource.MCPEngine.allCases {
 let config=PluginsSource.configurationURLs(engine:engine,environment:env).first!
 let bad="w62-definitely-not-installed"
 try write(engine == .claude ? "{\"mcpServers\":{\"fixture\":{\"command\":\"\(bad)\",\"args\":[]}}}" : "[mcp_servers.fixture]\ncommand = '\(bad)'\nargs = []\n",config)
 let result=PluginsSource.probeStatuses(engine:engine,environment:env,force:true)["fixture"]!
 check(result.state == .unreachable && result.detail == "執行檔不在 PATH","missing command \(engine)")
}
let exec=PluginProbe.executableCheck(command:"/bin/sh",args:["-c","never execute"],path:"/missing",cwd:home)
check(exec.state == .unknown && exec.detail!.contains("未驗證連線"),"lightweight never green")
check(PluginProbe.executableCheck(command:"/missing",args:[],path:"",cwd:home,enabled:false).state == .disabled,"disabled")
let toml = #"""
[mcp_servers."custom.name"]
command = 'worker'
args = [
  '--flag', "a#b",
]
[mcp_servers."custom.name".env]
PATH = '/custom/bin'
[mcp_servers.inline]
command = 'worker'
env = { PATH = '/inline/bin', OTHER = 'ignore' }
enabled = false
[other]
keep = true
"""#
let parsed=PluginServerConfiguration.parseTOML(toml)
check(parsed["custom.name"]?.command == "worker" && parsed["custom.name"]?.args == ["--flag","a#b"],"TOML fields")
check(parsed["custom.name"]?.path == "/custom/bin" && parsed["inline"]?.path == "/inline/bin","TOML PATH")
check(parsed["inline"]?.enabled == false,"TOML disabled")
let removed=try PluginServerConfiguration.removingTOMLServer("custom.name",from:toml)
check(!removed.contains("custom.name") && removed.contains("[other]") && removed.contains("[mcp_servers.inline]"),"remove whole table only")
let process=Process(); process.executableURL=URL(fileURLWithPath:"/bin/sleep"); process.arguments=["5"]
let started=Date(), timeout=PluginProbe.sidecar(process,timeout:0.12)
check(timeout.failure == "探測逾時" && Date().timeIntervalSince(started)<1,"bounded timeout")
check(PluginProbe.timeout == 8,"production 8s")
let nonzero=Process(); nonzero.executableURL=URL(fileURLWithPath:"/bin/sh"); nonzero.arguments=["-c","read line; exit 9"]
check(PluginProbe.sidecar(nonzero).failure == "回 non-zero","exit status")
let poll=Process(); poll.executableURL=URL(fileURLWithPath:"/bin/sh")
poll.arguments=["-c", #"read a; printf '%s\n' '{"ev":"mcp_status","servers":[{"name":"example","status":"pending"}]}'; read b; printf '%s\n' '{"ev":"mcp_status","servers":[{"name":"example","status":"connected"}]}'; read c"#]
check(PluginProbe.sidecar(poll,timeout:1).servers.first?["status"] as? String == "connected","pending re-probed")
let mixed=PluginProbe.Reply(servers:[["name":"example","status":"connected"],["name":"demo","status":"pending"]],failure:"探測逾時")
check(PluginProbe.result(named:"example",in:mixed).state == .ready,"mixed ready survives")
check(PluginProbe.result(named:"demo",in:mixed).detail == "探測逾時","mixed pending timeout")
let resistant=Process(); resistant.executableURL=URL(fileURLWithPath:"/bin/sh")
resistant.arguments=["-c","trap '' TERM; /bin/sleep 20 & wait"]
check(PluginProbe.sidecar(resistant,timeout:0.12).failure == "探測逾時","owned child timeout")
let ownedGroup=resistant.processIdentifier
let malformed=Process(); malformed.executableURL=URL(fileURLWithPath:"/bin/sh"); malformed.arguments=["-c","read a; echo invalid; read b; exit 0"]
check(PluginProbe.sidecar(malformed,timeout:1).failure != nil,"malformed no green")
// Copy only the two public tool declarations, not runtime state or private resources.
for name in ["os-mcp","browser-mcp"] {
 let source=try String(contentsOf:repo.appendingPathComponent("Engines/\(name)/server.mjs"),encoding:.utf8)
 try write(source,resources.appendingPathComponent("\(name)/server.mjs"))
}
let runtime=BuiltinPluginRuntimeSnapshot(accessibility:true,screenRecording:true,computerEnabled:true,webToolCount:3,osListening:true,browserListening:true)
let builtins=PluginsSource.builtinEntries(environment:env,runtime:runtime)
check(builtins.count == 4 && builtins.allSatisfy {$0.kind == .builtin && $0.availableTo == ["Codex","Claude","Grok"]},"builtin sources")
for name in ["os-mcp","browser-mcp"] {
 let entry=builtins.first {$0.name == name}!
 let source=try String(contentsOf:repo.appendingPathComponent("Engines/\(name)/server.mjs"),encoding:.utf8)
 check(entry.toolCount == PluginProbe.toolNames(in:source).count && entry.toolCount! > 0,"dynamic tool count")
 print("TOOL_COUNT \(name)=\(entry.toolCount!)")
}
check(builtins.allSatisfy {$0.liveness.state == .ready},"observed builtin ready")
check(builtins.first {$0.name == "os-mcp"}!.lastCalledAt == nil,"no invented audit")
let unavailable=PluginsSource.builtinEntries(environment:env,runtime:.init())
check(unavailable[2].liveness.detail == "需要輔助使用權限","TCC accessibility")
check(unavailable[3].liveness.state == .unknown && unavailable[3].liveness.detail == "目前沒有網頁登記工具","no WebMCP")
check(PluginsSource.builtinEntries(environment:env,runtime:.init(accessibility:true))[2].liveness.detail == "需要螢幕錄製權限","TCC recording")
let audit=root.appendingPathComponent("audit.log")
try write("{\"time\":\"2026-09-15T00:00:00Z\",\"event\":\"ai_login\",\"arguments\":\"never copy\"}\n",audit)
let snapshot=BrowserDiagnosticsAudit.readTail(at:audit)
check(snapshot.lastCalledAt != nil && !snapshot.lines.joined().contains("never copy"),"audit uses time only")
for engine in PluginsSource.MCPEngine.allCases {
 let config=PluginsSource.configurationURLs(engine:engine,environment:env).first!
 let before=try Data(contentsOf:config)
 let id=PluginsSource.pluginID(engine:engine,name:"fixture")
 _ = try PluginsSource.removeRegistration(id:id,environment:env)
 check(PluginsSource.configuredServers(engine:engine,environment:env)["fixture"] == nil,"real removal")
 let backups=try fm.contentsOfDirectory(at:config.deletingLastPathComponent(),includingPropertiesForKeys:nil).filter {$0.pathExtension == "bak"}
 check(try! backups.contains {try Data(contentsOf:$0) == before},"backup exact")
 check(try! backups.allSatisfy { (try fm.attributesOfItem(atPath:$0.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600 },"backup private")
 check(!PluginsSource.scanNow(environment:env).contains {$0.id == id},"removed card stays removed")
}
// Non-staging source selection never unions another home into a card.
var normal = ["HOME":home.path,"TATWO2_ENGINES_ROOT":engines.path,"TATWO2_LIVE_ROOT":root.appendingPathComponent("live").path]
let selectedSource=root.appendingPathComponent("selected-engine")
normal["CODEX_HOME"] = selectedSource.path
// Isolated config from removal is managed even when empty, so no fallback resurrection.
check(PluginsSource.configurationURLs(engine:.codex,environment:normal).first!.path == engines.appendingPathComponent("codex/config.toml").path,"managed empty authoritative")
let otherEngines=root.appendingPathComponent("other-engines")
normal["TATWO2_ENGINES_ROOT"] = otherEngines.path
check(PluginsSource.configurationURLs(engine:.codex,environment:normal).first!.path == selectedSource.appendingPathComponent("config.toml").path,"original CODEX_HOME")
let dangerous = "[mcp_servers.fixture]\ncommand = 'missing'\nargs = [" + String(repeating:"\"",count:3) + "\n[looks_like_table]\n" + String(repeating:"\"",count:3) + "]\n"
let codexConfig=PluginsSource.configurationURLs(engine:.codex,environment:env).first!
try write(dangerous,codexConfig)
do { _ = try PluginsSource.removeRegistration(id:"mcp:codex:fixture",environment:env); preconditionFailure("unsupported TOML edited") } catch {}
check(try! String(contentsOf:codexConfig,encoding:.utf8) == dangerous,"unsupported TOML untouched")
Thread.sleep(forTimeInterval:1)
check(!process.isRunning,"owned timed out process cleaned")
check(!resistant.isRunning && kill(-ownedGroup,0) != 0,"TERM-resistant owned group cleaned")
print("W62 \(checks) production checks PASS")
`);
  const files=['Facade/PluginLiveness.swift','Facade/PluginServerConfiguration.swift','Facade/PluginsSource.swift',
    // W80b: compile the real managed-service dependency closure; do not stub its availability.
    'Facade/GBrainService.swift','Facade/GBrainKeychain.swift','Facade/TatwoEntry.swift',
    'Facade/DeviceIdentity.swift','Facade/DeviceStatus.swift','Facade/DeviceRegistry.swift',
    'Facade/OSUpstream.swift','Facade/OSUpstreamRefresh.swift','Facade/TatwoResources.swift',
    'Facade/PluginsBuiltinSource.swift','Facade/PluginsRemoval.swift','Facade/EnginePaths.swift','Engine/NativeStagingIsolation.swift',
    'Browser/Diagnostics/BrowserDiagnosticsAudit.swift','Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift'].map(p=>path.join(root,app+p));
  run('swiftc',['-num-threads','2',...files,path.join(dir,'stubs.swift'),path.join(dir,'main.swift'),'-o',path.join(dir,'fixture')]);
  // Keep sockets below sockaddr_un's bound by using an owned short temporary fixture root.
  const scratch=testScratch('plugins-data-');
  const output=run(path.join(dir,'fixture'),[scratch,root]);
  fs.writeFileSync(path.join(dir,'result.txt'),output);
  for(const server of ['os-mcp','browser-mcp']) {
    const source=read(`Engines/${server}/server.mjs`);
    const declaration=source.slice(source.indexOf('const tools = ['),source.indexOf('].map('));
    const grep=run('/usr/bin/grep',['-cE',"^[[:space:]]*\\['[A-Za-z0-9_]+',[[:space:]]",path.join(root,`Engines/${server}/server.mjs`)]).trim();
    assert.equal(Number(grep),[...declaration.matchAll(/^\s*\['([A-Za-z0-9_]+)'\s*,/gm)].length);
    assert.match(output,new RegExp(`TOOL_COUNT ${server}=${grep}\\b`));
  }
  assert.match(output,/production checks PASS/);
});

test('Codex explicitly managed empty registry cannot be reseeded from another home',()=>{
  const source=read('Engines/codex-sidecar/sidecar.mjs');
  assert.match(source,/!\/\^# tatwo2-mcp-registry-managed\$\/m\.test\(destText\)/);
  assert.match(source,/\/\^# tatwo2-mcp-registry-managed\$\/m\.test\(latest\)/);
});

test('native synthetic MCP card layout and all five liveness pills', {skip:process.platform!=='darwin'}, () => {
  const dir=testScratch('plugins-visual-');
  writeFixtureStubs(dir);
  const shared=read(app+'Shell/SharedComponents.swift');
  const badge=shared.slice(shared.indexOf('struct Badge:'),shared.indexOf('// B2:'));
  const glass=shared.slice(shared.indexOf('struct GlassCard<'),shared.indexOf('struct IdentitySlotRow:'));
  fs.writeFileSync(path.join(dir,'visual.swift'),`import SwiftUI
import AppKit
// Synthetic material backing only; card content, badges, dimensions and pill are production source.
final class TatwoThemeStore: ObservableObject { static let shared = TatwoThemeStore() }
enum TatwoActivePalette { struct Palette { let usesGlass = false; let surfaceFill = Color.gray.opacity(0.12) }; static let current = Palette() }
enum LiquidGlassTokens { static let radiusCard: CGFloat = 22 }
extension View {
 func liquidGlassSurface(cornerRadius: CGFloat) -> some View { background(Color.white,in:RoundedRectangle(cornerRadius:cornerRadius)) }
 func tatwoAdaptiveMaterial(cornerRadius: CGFloat) -> some View { background(Color.gray.opacity(0.1),in:RoundedRectangle(cornerRadius:cornerRadius)) }
}
${badge}
${glass}
@main struct Visual {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let builtinName = "os-mcp"
  let rows: [PluginRegistryEntry] = [
   .init(id:"builtin:os",name:builtinName,kind:.builtin,purpose:"CLI 分頁、背景工作、派工房間、Bot 記憶、iPad、裝置",path:nil,trigger:"由 OS 提供；個別操作仍依權限與分頁狀態。",safetyLevel:.medium,installState:.installed,smokeCommand:nil,publicInstallHint:"隨 OS 提供",liveness:.init(state:.ready,detail:"本機橋接已啟動"),toolCount:38,availableTo:["Codex","Claude","Grok"]),
   .init(id:"builtin:web",name:"WebMCP 頁面工具",kind:.builtin,purpose:"網頁登記給 AI 的工具",path:nil,trigger:"由 OS 提供；個別操作仍依權限與分頁狀態。",safetyLevel:.medium,installState:.installed,smokeCommand:nil,publicInstallHint:"隨 OS 提供",liveness:.init(state:.unknown,detail:"目前沒有網頁登記工具"),toolCount:0,availableTo:["Codex","Claude","Grok"]),
   .init(id:"mcp:claude:example",name:"example",kind:.mcp,purpose:"Claude・外部 MCP",path:nil,trigger:"由 claude sidecar 啟動時載入。",safetyLevel:.medium,installState:.installed,smokeCommand:nil,publicInstallHint:"從本機設定唯讀載入",liveness:.init(state:.unreachable,detail:"執行檔不在 PATH"),availableTo:["Claude"]),
   .init(id:"mcp:codex:example",name:"example",kind:.mcp,purpose:"Codex・外部 MCP",path:nil,trigger:"由 codex sidecar 啟動時載入。",safetyLevel:.medium,installState:.installed,smokeCommand:nil,publicInstallHint:"從本機設定唯讀載入",liveness:.init(state:.unknown,detail:"輕量檢查：執行檔可用，未驗證連線"),availableTo:["Codex"]),
  ]
  let content=VStack(alignment:.leading,spacing:12) {
   HStack { ForEach(PluginLiveness.allCases,id:\\.rawValue) { PluginLivenessStatusPill(state:.init(state:$0)) } }
   ForEach(rows) { entry in PluginConnectionCard(entry:entry,requestRemoval:{}) }
  }.padding(20).frame(width:900).background(Color(red:0.94,green:0.94,blue:0.95)).environment(\\.colorScheme,.light)
  let renderer=ImageRenderer(content:content); renderer.scale=1
  guard let image=renderer.cgImage, let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { fatalError("render failed") }
  try png.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  print("W62 visual \\(image.width)x\\(image.height)")
 }
}
`);
  const binary=path.join(dir,'visual');
  run('swiftc',['-parse-as-library','-num-threads','2',path.join(root,app+'Facade/PluginLiveness.swift'),
    path.join(root,app+'Pages/PluginConnectionCard.swift'),path.join(dir,'stubs.swift'),path.join(dir,'visual.swift'),'-o',binary]);
  const image=path.join(dir,'plugins-card.png');
  const output=run(binary,[image]);
  assert.match(output,/W62 visual 900x/);
  fs.writeFileSync(path.join(dir,'visual-result.txt'),output);
});
