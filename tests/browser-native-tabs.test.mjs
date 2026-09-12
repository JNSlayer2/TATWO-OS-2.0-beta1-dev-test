import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const repo = fileURLToPath(new URL('../', import.meta.url));
const files = {
  backend: 'App/Sources/Tatwo2/Browser/ChromiumCEFBackend.swift',
  view: 'App/Sources/Tatwo2/Browser/EmbeddedBrowserView.swift',
  bridge: 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm',
  header: 'Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/include/TatwoCEFBridge.h',
};
const sources = Object.fromEntries(Object.entries(files).map(([k,v]) => [k, readFileSync(path.join(repo,v),'utf8')]));
const sha = s => createHash('sha256').update(s).digest('hex');
const part = (s,a,b) => { const x=s.indexOf(a), y=s.indexOf(b,x+a.length); assert.ok(x>=0&&y>x);return s.slice(x,y); };

test('normal CEF tab initialization reuses a secured context without popup flags or policy bypass', () => {
  const shared = part(sources.bridge, '- (BOOL)canShareRequestContext', '- (void)dealloc');
  for (const policy of ['request_context_security_ready', 'request_context_security_blocked', 'close_requested',
    'g_shutdown_requested', 'URLHasCredentials', 'IsAllowedURLString', 'IsDeniedByLocalHostList']) assert.ok(shared.includes(policy));
  assert.match(shared, /state->request_context = State\(source\)->request_context/);
  assert.doesNotMatch(shared, /CreateContext\(|creation_attempted = true|creation_pending = true|popup_id =/);
  assert.match(shared, /CreateBrowserState\(self\)/);
  assert.match(sources.header, /sharingContextWith:\(TatwoCEFBrowserView \*\)source/);
});

test('SwiftUI keeps the host mounted and keys background states before applying active navigation', () => {
  assert.match(sources.view, /if browserEngine == \.chromiumCEF \{\s*\/\/[\s\S]*?ZStack \{\s*browserSurface/);
  assert.match(sources.view, /initialURL: isBrowserRuntimeVisible \? selectedLaneURL : nil/);
  assert.match(sources.view, /laneURLs\[laneID\] = url/);
  assert.match(sources.view, /guard laneState.selectedLaneID == laneID,\s*isBrowserRuntimeVisible else \{ return \}\s*applyNavigationState\(state\)/);
  assert.match(sources.view, /refreshedProfileAccessRevision == profileAccessRevision/);
  const select = part(sources.view, 'private func selectLane(', 'private func togglePinned(');
  const cefBranches = [...select.matchAll(/if browserEngine == \.chromiumCEF \{([\s\S]*?)\} else if/g)];
  assert.equal(cefBranches.length,2);
  for (const match of cefBranches) assert.doesNotMatch(match[1], /issue\(\.load/);
});

test('actual tab host and close aggregation with controlled native callbacks', {
  skip: process.env.TATWO_BROWSER_TABS_NATIVE !== '1' ? 'Lead compiler approval required' : false,
}, () => {
  const run = (cmd,args) => { const r=spawnSync(cmd,args,{cwd:repo,encoding:'utf8',timeout:90000,maxBuffer:3*1024*1024}); assert.equal(r.status,0,`${r.error??''}\n${r.stdout}\n${r.stderr}`);return r.stdout; };
  assert.equal(run('/usr/sbin/sysctl',['-n','kern.memorystatus_vm_pressure_level']).trim(),'1');
  const lock=path.join(repo,'scripts/tatwo-build-lock.sh');
  const acquired=run('/bin/bash',[lock,'acquire','--pid',String(process.pid),'--timeout','1']);
  const token=acquired.match(/^token=([0-9a-f]+)$/m)?.[1];assert.ok(token);
  const output=path.join(repo,'output/lightweight-repair');mkdirSync(output,{recursive:true});
  const root=mkdtempSync(path.join(output,'browser-native-tabs.'));
  try {
    const container=part(sources.backend,'@MainActor\nfinal class TatwoCEFContainerView','\nstruct EmbeddedChromiumBrowserMountIdentity');
    const host=part(sources.backend,'@MainActor\nfinal class TatwoCEFTabHostView','\nprivate extension EmbeddedBrowserLoadPhase');
    const modelStubs=String.raw`
import AppKit
import SwiftUI
struct EmbeddedBrowserRuntimeProfile: Hashable { let registryKey = UUID() }
struct EmbeddedChromiumBrowserMountIdentity: Equatable {
    let profile: EmbeddedBrowserRuntimeProfile
    var profilePolicyTag: Int { 1 }
}
struct EmbeddedBrowserCommand { enum Action { case load(URL), goBack, goForward, reload }; let id=UUID();let action:Action }
struct VisibleError { let message:String; static func runtimeMessage(_ s:String)->Self { .init(message:s) } }
struct EmbeddedBrowserNavigationState {
    var urlString:String?; var canGoBack:Bool; var canGoForward:Bool; var visibleError:VisibleError?
    static var blank:Self { .init(urlString:nil,canGoBack:false,canGoForward:false,visibleError:nil) }
}
struct EmbeddedChromiumNavigationStateProjector {
    mutating func project(committedMainFrameURLString:String?,navigationGeneration:UInt64,canGoBack:Bool,canGoForward:Bool,isLoading:Bool,phase:TatwoCEFBrowserPhase,httpStatusCode:Int,errorKind:TatwoCEFBrowserErrorKind,errorCode:Int,visibleError:String?) -> EmbeddedBrowserNavigationState {
        .init(urlString:committedMainFrameURLString,canGoBack:canGoBack,canGoForward:canGoForward,visibleError:visibleError.map{.runtimeMessage($0)})
    }
}
struct Location { let profilePolicyTag=1; let rootCachePath="";let helperExecutablePath="";let logFilePath="";let persistentProfilePath:String?=nil }
@MainActor enum TatwoCEFProfileLocationResolver {
    static func resolve(profile:EmbeddedBrowserRuntimeProfile)throws->Location? { Location() }
    static func prepareForRuntime(_ location:Location)throws->TatwoCEFProfileLeaseRegistry.Lease? { TatwoCEFProfileLeaseRegistry.shared.acquire() }
}
@MainActor final class TatwoCEFProfileLeaseRegistry {
    struct Lease { let token=UUID() }
    static let shared=TatwoCEFProfileLeaseRegistry(); var active:Set<UUID>=[]; var released=0
    func acquire()->Lease { let lease=Lease();active.insert(lease.token);return lease }
    func release(_ lease:Lease) { precondition(active.remove(lease.token) != nil);released += 1 }
}
enum BrowserBundledHostDenyList { static func verifiedResourceURL()throws->URL { URL(fileURLWithPath:"/fixture/denylist") } }
enum TatwoCEFGeometrySyncThrottlePolicy { static func delay(lastSyncUptime:TimeInterval,now:TimeInterval)->TimeInterval { 0.03 } }
@MainActor enum TatwoCEFContainerTeardownContract { static func detachFromHostWindow(_ view:NSView) { view.removeFromSuperview() } }
@MainActor final class TatwoWebMCPRuntime {
    static let shared=TatwoWebMCPRuntime();var active:String?;var attached:Set<String>=[]
    func activate(tabID:String) { active=tabID }
    func update(tabID:String,snapshotJSONString:String) {}
    func attach(tabID:String,invoke:@escaping(String,String,UInt64,@escaping(String?,String?)->Void)->Void) { attached.insert(tabID) }
    func detach(tabID:String) { attached.remove(tabID);if active==tabID {active=nil} }
}
`;
    const nativeStubs=String.raw`
enum TatwoCEFBrowserPhase { case creating,finished }
enum TatwoCEFBrowserErrorKind { case none }
@MainActor enum TatwoCEFRuntime { static func initialize(withRootCachePath:String,helperExecutablePath:String,logFilePath:String,bundledDenyListPath:String)throws {} }
@MainActor final class TatwoCEFBrowserView:NSView {
    static var created:[TatwoCEFBrowserView]=[]
    var contextID=UUID(); var canShareRequestContext=false
    var stateHandler:((String?,UInt64,Bool,Bool,Bool,TatwoCEFBrowserPhase,Int,TatwoCEFBrowserErrorKind,Int,String?)->Void)?
    var webMCPToolsHandler:((String)->Void)?
    var history:[String]=[];var historyIndex=0;var loads=0;var dom="";var closeRequested=false
    private var completion:(()->Void)?
    var current:String { history[historyIndex] }
    init(frame:NSRect,persistentProfile:String?,initialURL:String)throws { super.init(frame:frame);history=[initialURL];Self.created.append(self) }
    init(frame:NSRect,sharingContextWith source:TatwoCEFBrowserView,initialURL:String)throws { super.init(frame:frame);precondition(source.canShareRequestContext);contextID=source.contextID;canShareRequestContext=true;history=[initialURL];Self.created.append(self) }
    required init?(coder:NSCoder) { return nil }
    func publish() { stateHandler?(current,1,historyIndex>0,historyIndex<history.count-1,false,.finished,200,.none,0,nil) }
    func becomeReady() { canShareRequestContext=true;publish() }
    func loadURLString(_ url:String) { loads += 1;history=Array(history.prefix(historyIndex+1))+[url];historyIndex += 1;publish() }
    func goBack() { historyIndex=max(0,historyIndex-1);publish() }
    func goForward() { historyIndex=min(history.count-1,historyIndex+1);publish() }
    func reload() { loads += 1;publish() }
    func closeBrowser(completion:@escaping()->Void) { closeRequested=true;self.completion=completion }
    func finishClose() { let callback=completion;completion=nil;callback?() }
    func invokeWebMCPToolNamed(_ name:String,argumentsJSON:String,navigationGeneration:UInt64,completion:@escaping(String?,String?)->Void) { completion("{}",nil) }
}
`;
    const checks=String.raw`
@MainActor func verify() {
    var checks=0
    func check(_ ok:Bool,_ message:String) { precondition(ok,message);checks += 1 }
    func drain() { RunLoop.main.run(until:Date().addingTimeInterval(0.025)) }
    let _=NSApplication.shared
    var events:[(String,String?)]=[]
    let host=TatwoCEFTabHostView(mountIdentity:.init(profile:.init())) { events.append(($0,$1.urlString)) }
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:480),styleMask:[.titled],backing:.buffered,defer:false)
    window.contentView=host
    let a=URL(string:"https://example.test/a")!,b=URL(string:"https://example.test/b")!
    func update(_ id:String?,_ url:URL?,_ ids:Set<String>=["A","B","C","blank"],_ action:EmbeddedBrowserCommand.Action?=nil) {
        host.update(tabID:id,initialURL:url,openTabIDs:ids,command:action.map{EmbeddedBrowserCommand(action:$0)},isGeometryDragInProgress:false)
    }
    update("blank",nil)
    check(TatwoCEFBrowserView.created.isEmpty,"blank creates no browser")
    check(TatwoCEFProfileLeaseRegistry.shared.active.isEmpty,"blank acquires no lease")
    update("A",a)
    let first=TatwoCEFBrowserView.created[0]
    first.dom="unsent form"
    check(TatwoCEFProfileLeaseRegistry.shared.active.count==1,"root acquires one lease")
    update("B",b)
    check(TatwoCEFBrowserView.created.count==1,"second tab waits for context readiness")
    first.becomeReady();drain()
    check(TatwoCEFBrowserView.created.count==2,"native readiness opens selected pending tab")
    let second=TatwoCEFBrowserView.created[1]
    check(first.contextID==second.contextID,"tabs share the actual context")
    check(TatwoCEFProfileLeaseRegistry.shared.active.count==1,"second tab does not acquire another lease")
    check(first.isHiddenOrHasHiddenAncestor && !second.isHiddenOrHasHiddenAncestor,"only selected native browser visible")
    events.removeAll()
    first.loadURLString("https://example.test/background");drain()
    check(events.contains{$0.0=="A" && $0.1==first.current},"background callback retains original tab")
    check(!events.contains{$0.0=="B"},"background callback not relabelled active tab")
    let count=first.loads
    update("A",a);drain()
    check(TatwoCEFBrowserView.created.count==2 && first.loads==count,"select does not recreate or load")
    check(first.dom=="unsent form" && first.history.count==2,"select retains DOM and history")
    check(!first.isHiddenOrHasHiddenAncestor && second.isHiddenOrHasHiddenAncestor,"native visibility swaps")
    update("A",a,["A","B","C","blank"],.goBack)
    check(first.current==a.absoluteString,"back operates same browser history")
    update("A",a,["A","B","C","blank"],.goForward)
    check(first.current.hasSuffix("background"),"forward operates same browser history")
    update("blank",nil)
    check(first.isHiddenOrHasHiddenAncestor && second.isHiddenOrHasHiddenAncestor,"blank hides all native browsers")
    check(TatwoCEFBrowserView.created.count==2,"blank and saved lanes do not preload renderers")
    update("B",b,["B","C","blank"])
    check(first.closeRequested && !second.closeRequested,"close only requested tab")
    check(!TatwoWebMCPRuntime.shared.attached.contains("A"),"closed tab MCP detached")
    check(TatwoCEFProfileLeaseRegistry.shared.active.count==1,"pending native close retains lease")
    update("C",a,["C","blank"])
    check(second.closeRequested,"closing final old tab requests native close")
    check(TatwoCEFBrowserView.created.count==2,"no replacement root before close completion")
    first.finishClose();drain()
    check(TatwoCEFBrowserView.created.count==2 && TatwoCEFProfileLeaseRegistry.shared.released==0,"one completion not enough")
    second.finishClose();drain()
    check(TatwoCEFProfileLeaseRegistry.shared.released==1,"last completion releases old lease")
    check(TatwoCEFBrowserView.created.count==3,"native final completion resumes pending root")
    let third=TatwoCEFBrowserView.created[2]
    check(third.contextID != first.contextID,"new root context after old context closes")
    check(TatwoCEFProfileLeaseRegistry.shared.active.count==1,"replacement root gets single lease")
    host.close()
    check(TatwoCEFProfileLeaseRegistry.shared.active.count==1,"dismantle retains lease until callback")
    third.finishClose();drain()
    check(TatwoCEFProfileLeaseRegistry.shared.active.isEmpty,"dismantle completion releases lease")
    check(TatwoWebMCPRuntime.shared.attached.isEmpty,"all native tools detached")
    host.close()
    check(TatwoCEFProfileLeaseRegistry.shared.released==2,"idempotent teardown")
    window.contentView=nil
    print("BROWSERTABS RESULT checks=\(checks) failures=0")
}
MainActor.assumeIsolated { verify() }
`;
    const main=path.join(root,'main.swift');const binary=path.join(root,'tab-fixture');
    const swift=modelStubs+nativeStubs+container+host+checks;writeFileSync(main,swift);
    run('/usr/bin/xcrun',['swiftc','-swift-version','5','-j','1',main,'-o',binary]);
    const result=run(binary,[]);assert.match(result,/BROWSERTABS RESULT checks=31 failures=0/);
    // Check the exact production host against the actual Objective-C interface,
    // not just a fake Swift spelling of the initializer.
    const moduleDir=path.join(root,'bridge-module');mkdirSync(moduleDir);
    writeFileSync(path.join(moduleDir,'module.modulemap'),`module TatwoCEFBridge { header "${path.join(repo,files.header)}" export * }`);
    const typecheck=path.join(root,'native-interface.swift');
    writeFileSync(typecheck,'import TatwoCEFBridge\n'+modelStubs+container+host);
    run('/usr/bin/xcrun',['swiftc','-swift-version','5','-j','1','-typecheck','-I',moduleDir,typecheck]);
    for (const [name,file] of Object.entries(files)) assert.equal(sha(readFileSync(path.join(repo,file),'utf8')),sha(sources[name]),`${name} drifted`);
    writeFileSync(path.join(root,'receipt.json'),JSON.stringify({at:new Date().toISOString(),sourceHashes:Object.fromEntries(Object.entries(sources).map(([k,v])=>[k,sha(v)])),result,scope:'Actual Swift host/container with fake CEF callbacks plus actual Objective-C header typecheck. Not real CEF DOM/auth or formal App acceptance.'},null,2));
    console.log(result.trim());console.log('Evidence:',root);
  } finally { run('/bin/bash',[lock,'release','--pid',String(process.pid),'--token',token]); }
});
