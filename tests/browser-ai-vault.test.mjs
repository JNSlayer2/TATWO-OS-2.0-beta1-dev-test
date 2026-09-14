import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync, spawn} from 'node:child_process';
import {once} from 'node:events';
import net from 'node:net';
import readline from 'node:readline';
import vm from 'node:vm';
const root = fileURLToPath(new URL('../',import.meta.url));
const read = p => readFileSync(join(root,p),'utf8');
const app = 'App/Sources/Tatwo2/';
const bridge = read('Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/TatwoCEFBridge.mm');

test('W58 isolated services, native actor/form gates, UI labels and no secret tool', () => {
  const vault = read(app+'Browser/BrowserAIVault.swift');
  assert.match(vault,/KeychainSecretStore\(service: "TATWO OS AI Vault"\)/);
  assert.match(vault,/Browser\/ai-passwords.json/);
  assert.doesNotMatch(vault.slice(0,vault.indexOf('enum CallerScope')),/var password|let password/);
  assert.doesNotMatch(vault,/BrowserPasswordVault.shared/);
  const native = bridge.match(/- \(BOOL\)fillCredentialForAgentUsername:[\s\S]*?#pragma mark - W58 End/)[0];
  for (const value of ['TatwoCEFBrowserActorAgent','state->ai_login_form.length','state->navigation_generation != g','state->navigation_in_flight','PID_RENDERER']) assert.ok(native.includes(value),value);
  const sections = [...bridge.matchAll(/#pragma mark - W58[^\n]*\n([\s\S]*?)#pragma mark - W58 End/g)].map(m=>m[1]).join('\n');
  assert.doesNotMatch(sections,/ExecuteJavaScript|CefWriteJSON|\b(?:NSLog|printf|LogBrowser\w*|Append\w*Telemetry\w*)\s*\(/);
  assert.match(sections,/W58LoadEnd\(owner, frame, http_status_code\)/);
  const settings = read(app+'Browser/BrowserPasswordsSettingsView.swift')+read(app+'Browser/BrowserAIVaultSettingsView.swift');
  for (const label of ['AI 帳號','填入密碼前要 Touch ID','兩步驟驗證下一輪','不會填進你的分頁']) assert.ok(settings.includes(label));
  const agent = read(app+'Facade/BrowserAgentBridge.swift');
  assert.match(agent,/case "browser_login":/);
  assert.match(agent,/guard view.browserActor == .agent else/);
  assert.match(agent,/latest\.2 === view/);
  assert.match(agent,/self.aiCaller\(request\)\) == caller/);
  assert.match(agent,/let runtimeID = tab.id.uuidString/);
  assert.match(agent,/registry.selectedTab\(ownedBy: .bot\(botID: \$0\)\)/);
  assert.doesNotMatch(agent,/revealPassword|exportCSV|passwordForApprovedFill/);
  const server = read('Engines/browser-mcp/server.mjs');
  const names = [...server.matchAll(/^  \['([^']+)'/gm)].map(m=>m[1]);
  assert.ok(names.includes('browser_login'));
  assert.ok(names.every(n=>!/(password|credential|vault|export|reveal)/i.test(n)));
});

test('W58 actor identity survives initial blank tab, mixed contexts and wake without converting human tabs', () => {
  const panel = read(app+'Browser/EmbeddedBrowserView.swift');
  assert.match(panel, /registry.tabForAgentNavigation\(ownedBy: owner\)/);
  assert.match(panel, /新增 AI 分頁/);
  assert.match(panel, /\.disabled\(tab.usesAgentContext\)/);
  assert.match(read(app+'Browser/BrowserWorkSpaceCEFSurface.swift'), /isAgentTab: selected\?\.usesAgentContext == true/);
  const backend = read(app+'Browser/ChromiumCEFBackend.swift');
  assert.match(backend, /let agentMount = selectedIsAgentTab/);
  assert.match(backend, /if !sameActorEntries.isEmpty && source == nil/);
  assert.match(backend, /if profileLease == nil/);
  assert.match(backend, /guard source != nil \|\| closingCount == 0 else/);
  assert.match(backend, /revokeRequests\(\)[\s\S]*?cancelAgentLogin\(\)[\s\S]*?guard browser.browserActor == .human/);
  assert.match(backend, /persistentProfile: nil,\s+initialURL: startupURL, actor: .agent/);
  assert.doesNotMatch(backend, /let agentMount = pendingCommand/);
  const agent = read(app+'Facade/BrowserAgentBridge.swift');
  assert.match(agent, /isSelectedAgentBrowser\(browser, request: request\)/);
  assert.match(agent, /isSelectedAgentBrowser\(browser, request: navigation.request\) else \{ return false \}/);
});

function renderer({method='post',action='https://example.com/auth',prefilled='',otp=false}={}) {
  class Input {
    constructor(type,autocomplete){this.type=type;this.autocomplete=autocomplete;this.value='';this.isConnected=true;this.disabled=false;this.readOnly=false;this.hidden=false;this.events=[];}
    getClientRects(){return [{}];}
    dispatchEvent(e){this.events.push(e.type);this.callback?.();}
  }
  Object.defineProperty(Input.prototype,'value',{get(){return this._value||'';},set(v){this._value=v;}, configurable:true});
  class Form { requestSubmit(){this.submitted=(this.submitted||0)+1;this.submittedPassword=this.elements.find(e=>e.type==='password')?.value;} checkValidity(){return this.valid!==false;} }
  const form = new Form(); Object.assign(form,{isConnected:true,method,action});
  const user = new Input('email','username'), password = new Input('password','current-password'); user.value=prefilled;
  form.elements=[user,password];user.form=password.form=form;
  const inputs = otp ? [...form.elements,new Input('text','one-time-code')] : form.elements;
  const document={forms:[form],title:'Home',baseURI:'https://example.com/login',querySelectorAll:()=>inputs};
  const context=vm.createContext({HTMLInputElement:Input,HTMLFormElement:Form,document,location:{origin:'https://example.com',protocol:'https:',pathname:'/login'},URL,Array,String,Object,Event:class{constructor(t){this.type=t;}},getComputedStyle:()=>({visibility:'visible',display:'block'})});
  const script=bridge.match(/kW58AgentLoginScript = R"W58\(([\s\S]*?)\)W58";/)[1];
  const factory=vm.runInContext(script,context), controller=factory('https://example.com');
  return {controller,user,password,form,document,context};
}
test('W58 actual renderer single-use fill, post/same-origin/form/2FA gates and next-page scan',()=>{
  const f=renderer(); const scan=f.controller.scan(false);
  assert.equal(scan.formID,'w58-login');
  assert.equal(f.controller.fill(scan.formID,'ai','fixture-secret-render'),true);
  assert.equal(f.form.submitted,1); assert.equal(f.form.submittedPassword,'fixture-secret-render');
  assert.equal(f.password.value,'');
  assert.deepEqual(f.password.events,['input','change']);
  assert.equal(f.controller.fill(scan.formID,'ai','again'),false);
  assert.equal(f.controller.scan(true).error,'ai_login_rejected');
  f.document.forms=[];
  assert.equal(f.controller.scan(true).title,'Home');
  for(const options of [{method:'get'},{action:'https://evil.example'},{otp:true}]) assert.ok(renderer(options).controller.scan(false).error);
  for(const mutate of [f=>f.form.action='https://evil.example',f=>f.form.method='get',f=>f.password.type='text',f=>f.password.isConnected=false,f=>f.user.value='human',f=>f.password.value='manual',f=>f.form.valid=false,f=>f.form.elements=[],f=>f.context.location.origin='https://other.example']){
    const f=renderer();f.controller.scan(false);mutate(f);
    assert.equal(f.controller.fill('w58-login','ai','fixture-secret-blocked'),false);assert.ok(!f.form.submitted);
  }
  const changing=renderer();changing.controller.scan(false);changing.user.callback=()=>{changing.form.action='https://evil.example';};
  assert.equal(changing.controller.fill('w58-login','ai','fixture-secret-clear'),false);assert.equal(changing.password.value,'');
  const foreign=renderer({prefilled:'someone'});foreign.controller.scan(false);assert.equal(foreign.controller.fill('w58-login','ai','secret'),false);
});

test('W58 production Swift vault, coordinator, CSV, Touch ID ordering/cache and UI compile', {skip:process.platform!=='darwin',timeout:180000},()=>{
  const dir=join(root,'.build/w58/fixture');mkdirSync(dir,{recursive:true});
  const profile=read(app+'Browser/EmbeddedBrowserProfile.swift');
  const metadata=profile.slice(profile.indexOf('struct EmbeddedBrowserPasswordFormMetadata:'),profile.indexOf('struct EmbeddedBrowserNavigationJournal:'));
  writeFileSync(join(dir,'metadata.swift'),'import Foundation\nimport WebKit\n'+metadata);
  const files=['Browser/BrowserPasswordVault.swift','Browser/BrowserPasswordAssist.swift','Browser/BrowserGeneralSettings.swift','Browser/BrowserShortcuts.swift',
    'Browser/BrowserAIVault.swift','Browser/BrowserAILogin.swift','Browser/BrowserPasswordsSettingsView.swift','Browser/BrowserAIVaultSettingsView.swift',
    'Browser/Import/BrowserPasswordCSVImport.swift','Browser/Diagnostics/BrowserDiagnosticsAudit.swift','Browser/Diagnostics/BrowserDiagnosticsPrivacy.swift',
    'Chat/TatwoPermissionPreset.swift','Chat/TatwoCodexSandboxMode.swift',
    'Browser/TatwoBrowserLaneCore.swift','Browser/BrowserTabRegistry.swift'].map(f=>app+f);
  const binary=join(dir,'fixture');
  const compile=spawnSync('swiftc',['-parse-as-library','-swift-version','6','-num-threads','2',...files,join(dir,'metadata.swift'),
    'tests/fixtures/browser-ai-vault-dependencies.swift','tests/fixtures/browser-ai-vault-checks.swift','-o',binary],{cwd:root,encoding:'utf8',timeout:150000});
  assert.equal(compile.status,0,compile.stdout+compile.stderr);
  const run=spawnSync(binary,[dir],{encoding:'utf8',timeout:20000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  assert.match(run.stdout,/W58 AI vault fixture passed: \d+ checks/);
  assert.doesNotMatch(run.stdout+run.stderr,/fixture-secret-/);
  console.log(run.stdout.trim());
  if(process.env.W58_RENDER==='1'){
    const render=spawnSync(binary,[dir,'--render'],{encoding:'utf8',timeout:20000});assert.equal(render.status,0,render.stdout+render.stderr);console.log(render.stdout.trim());
  }
});

test('W58 real MCP schema binds native caller, rejects overrides and strips extra reply fields',async()=>{
  const socketPath=join(root,'.build/w58/s-'+process.pid+'.sock');mkdirSync(join(root,'.build/w58'),{recursive:true});
  const requests=[];const server=net.createServer(socket=>{let data='';socket.on('data',b=>data+=b);socket.on('end',()=>{
    const r=JSON.parse(data);requests.push(r);socket.end(JSON.stringify({id:r.id,ok:true,result:{ok:true,finalURL:'https://example.com/home',title:'Home',password:'fixture-secret-wire',extra:'ignored'}})+'\n');
  });});
  server.listen(socketPath);await once(server,'listening');
  const child=spawn(process.execPath,[join(root,'Engines/browser-mcp/server.mjs')],{env:{...process.env,TATWO2_BROWSER_SOCKET:socketPath,TATWO2_THREAD_ID:'11111111-1111-4111-8111-111111111111'},stdio:['pipe','pipe','pipe']});
  const lines=readline.createInterface({input:child.stdout});let id=0;
  const call=async(method,params)=>{const wait=once(lines,'line');child.stdin.write(JSON.stringify({jsonrpc:'2.0',id:++id,method,params})+'\n');return JSON.parse((await wait)[0]);};
  try{
    const listed=(await call('tools/list',{})).result.tools;
    const tool=listed.find(t=>t.name==='browser_login');assert.deepEqual(tool.inputSchema.required,['origin']);
    assert.deepEqual(Object.keys(tool.inputSchema.properties).sort(),['origin','tabID','username']);
    for(const override of ['password','callerThreadID','preset','engine','botID','sessionID']){
      const r=await call('tools/call',{name:'browser_login',arguments:{origin:'https://example.com',[override]:'forged'}});assert.equal(r.result.isError,true);
    }
    assert.equal(requests.length,0);
    const r=await call('tools/call',{name:'browser_login',arguments:{origin:'https://example.com'}});
    assert.equal(requests[0].params.callerThreadID,'11111111-1111-4111-8111-111111111111');
    assert.deepEqual(JSON.parse(r.result.content[0].text),{ok:true,finalURL:'https://example.com/home',title:'Home'});
    assert.doesNotMatch(JSON.stringify(r),/fixture-secret-wire|password/);
  }finally{child.stdin.end();await once(child,'exit');lines.close();await new Promise(resolve=>server.close(resolve));}
});
