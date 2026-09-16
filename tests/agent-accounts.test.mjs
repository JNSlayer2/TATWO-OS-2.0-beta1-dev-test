import { testScratch } from './helpers/test-scratch.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import vm from 'node:vm';
import { writeBrowserVisualTokens } from './helpers/browser-visual-fixture.mjs';
const root=fileURLToPath(new URL('../',import.meta.url)), app='App/Sources/Tatwo2/';
const read=p=>readFileSync(join(root,p),'utf8');
const native='Apps/TatwoUltraworkMac/Sources/TatwoCEFBridge/';
const bridge=read(native+'TatwoCEFBridge.mm');

test('W59 approved settings pills, account columns, safe import and human-only password page',()=>{
  const page=read(app+'Custody/AgentAccountsSettingsView.swift'), table=read(app+'Browser/BrowserAIVaultSettingsView.swift');
  assert.match(page,/pickerStyle\(\.segmented\)/); assert.match(page,/clipShape\(Capsule\(\)\)/);
  assert.match(page,/surface == \.accounts/); assert.match(page,/Surface = \.accounts/);
  for(const label of ['網站','帳號','標籤','驗證器','最近使用','狀態','⋯','匯入 iCloud','CSV 匯入','＋ 新增帳號']) assert.ok(table.includes(label),label);
  assert.match(read(app+'Shell/ChatPageSettings.swift'),/case browserManagement\s+case agentAccounts/);
  assert.doesNotMatch(read(app+'Browser/BrowserPasswordsSettingsView.swift'),/BrowserAIVault|AI 帳號/);
  assert.match(page,/錢包第二期：EVM 熱錢包、額度、允許清單、硬體金庫/);
  assert.match(page,/Button\("＋ 建立錢包"\).*disabled\(true\)/);
  assert.match(read(app+'Custody/AIAccountEditView.swift'),/selected: Set<UUID> = \[\]/);
  assert.match(read(app+'Custody/AIAccountEditView.swift'),/CIDetectorTypeQRCode/);
});

test('W59 custody channel has no logs, secret-returning tools or HIBP identity fields',()=>{
  const scanner=read(app+'Custody/BreachDetector.swift');
  assert.match(scanner,/"true", forHTTPHeaderField: "Add-Padding"/);
  assert.match(scanner,/"TATWO-OS", forHTTPHeaderField: "User-Agent"/);
  assert.match(scanner,/URLSessionConfiguration.ephemeral/);
  assert.match(scanner,/completionHandler\(nil\)/);
  assert.match(scanner,/retryAfter = Date\(\).addingTimeInterval/);
  assert.match(scanner,/started = true\s+pendingFull = true/);
  assert.match(read(app+'Facade/BrowserAgentBridge.swift'), /let confirmed = await IslandNotice.shared.confirm[\s\S]*view.navigationGeneration == verifiedGeneration/);
  for(const file of ['Custody/BreachDetector.swift','Custody/TOTP.swift','Custody/AIPasswordChange.swift','Browser/BrowserAILogin.swift','Browser/BrowserAIVault.swift']) {
    assert.doesNotMatch(read(app+file),/\b(?:print|debugPrint|NSLog|os_log)\s*\(/,file);
  }
  assert.match(read(app+'Browser/BrowserAIVault.swift'),/accountSuffix: "\.totp"/);
  const sections=[...bridge.matchAll(/#pragma mark - W5[89][^\n]*\n([\s\S]*?)#pragma mark - W5[89] End/g)].map(m=>m[1]).join('\n');
  assert.doesNotMatch(sections,/ExecuteJavaScript|CefWriteJSON|\b(?:NSLog|printf|LogBrowser\w*)\s*\(/);
  const facade=read(app+'Facade/BrowserAgentBridge.swift');
  assert.match(facade,/guard !custodyOwnsBrowser/);
  assert.match(facade,/網站已確認新密碼生效/);
  assert.match(facade,/view\.navigationGeneration == formGeneration/);
  assert.match(facade,/passwordChangeTask\?\.cancel\(\)/);
  const pipeline=read(app+'Custody/AIPasswordChange.swift');
  assert.ok(pipeline.indexOf('try await op.authenticate()')<pipeline.indexOf('try await op.fill(proposed)'));
  assert.ok(pipeline.indexOf('try op.stageSecret(proposed)')<pipeline.indexOf('try await op.fill(proposed)'));
  assert.ok(pipeline.indexOf('try await op.verify()')<pipeline.indexOf('try op.commit(proposed)'));
});

function renderer(kind='change'){
  class Input {
    constructor(type,autocomplete,name=''){Object.assign(this,{type,autocomplete,name,id:'',placeholder:'',value:'',isConnected:true,disabled:false,readOnly:false,hidden:false});}
    getClientRects(){return [{}];}
    dispatchEvent(e){this.callback?.(e);}
  }
  Object.defineProperty(Input.prototype,'value',{get(){return this._value||'';},set(v){this._value=v;}});
  class Form {checkValidity(){return true;}requestSubmit(){this.submits=(this.submits||0)+1;this.captured=this.elements.map(e=>e.value);}}
  const form=new Form();Object.assign(form,{isConnected:true,method:'post',action:'https://example.com/settings'});
  const inputs=kind==='otp'?[new Input('text','one-time-code','code')]:[
    new Input('password','current-password','current'),new Input('password','new-password','new'),new Input('password','new-password','confirm')];
  form.elements=inputs;for(const i of inputs)i.form=form;
  const document={forms:[form],querySelectorAll:()=>inputs,title:'Example',baseURI:'https://example.com/settings',body:{innerText:''}};
  const context=vm.createContext({HTMLInputElement:Input,HTMLFormElement:Form,URL,Array,String,Object,Event:class{constructor(type){this.type=type;}},document,
    location:{origin:'https://example.com',protocol:'https:',pathname:'/settings'},getComputedStyle:()=>({visibility:'visible',display:'block'})});
  const script=bridge.match(/kW58AgentLoginScript = R"W58\(([\s\S]*?)\)W58";/)[1];
  return {controller:vm.runInContext(script,context)('https://example.com'),form,inputs,document,context};
}
test('W59 actual TOTP renderer matches autocomplete/name code, same-origin POST, clears code and is single-use',()=>{
  for(const autocomplete of ['one-time-code','']){
    const f=renderer('otp');f.inputs[0].autocomplete=autocomplete;
    assert.equal(f.controller.scan(true).formID,'w59-otp');
    assert.equal(f.controller.fill('w59-otp','','123456'),true);
    assert.equal(f.form.submits,1);assert.equal(f.inputs[0].value,'');
    assert.equal(f.controller.fill('w59-otp','','123456'),false);
  }
  for(const mutate of [f=>f.form.action='https://example.invalid',f=>f.form.method='get',f=>f.inputs[0].value='manual',f=>f.inputs[0].form=null]){
    const f=renderer('otp');f.controller.scan(false);mutate(f);
    assert.equal(f.controller.fill('w59-otp','','123456'),false);assert.ok(!f.form.submits);
  }
});
test('W59 actual change renderer separates fill/submit, rejects mutation, cancels fields, requires positive result',()=>{
  const f=renderer();assert.equal(f.controller.scanChange(false).formID,'w59-change');
  assert.equal(f.controller.fillChange('example-old','example-new'),true);assert.ok(!f.form.submits);
  assert.equal(f.controller.submitChange(),true);assert.equal(f.form.submits,1);
  assert.deepEqual(f.form.captured,['example-old','example-new','example-new']);assert.ok(f.inputs.every(e=>!e.value));
  assert.equal(f.controller.submitChange(),false);
  for(const mutate of [f=>f.form.action='https://example.invalid',f=>f.inputs[1].type='text',f=>f.inputs[1].value='changed',f=>f.inputs[0].isConnected=false]){
    const f=renderer();f.controller.scanChange(false);f.controller.fillChange('example-old','example-new');mutate(f);
    assert.equal(f.controller.submitChange(),false);assert.ok(!f.form.submits);assert.ok(f.inputs.every(e=>!e.value));
  }
  const cancel=renderer();cancel.controller.scanChange(false);cancel.controller.fillChange('example-old','example-new');cancel.controller.cancel();
  assert.ok(cancel.inputs.every(e=>!e.value));assert.equal(cancel.controller.submitChange(),false);
  const result=renderer();result.document.forms=[];
  assert.equal(result.controller.scanChange(true).error,'ai_change_unconfirmed');
  result.document.body.innerText='Password successfully changed';assert.equal(result.controller.scanChange(true).error,undefined);
  result.document.body.innerText='Unable to change password. Password successfully changed is help text.';
  assert.equal(result.controller.scanChange(true).error,'ai_change_unconfirmed');
});

test('W59 production Swift RFC6238, CSV, both-vault breach rules and every change-stage failure', {skip:process.platform!=='darwin',timeout:180000},()=>{
  const dir=testScratch('agent-accounts-');mkdirSync(dir,{recursive:true});
  const profile=read(app+'Browser/EmbeddedBrowserProfile.swift');
  const metadata=profile.slice(profile.indexOf('struct EmbeddedBrowserPasswordFormMetadata:'),profile.indexOf('struct EmbeddedBrowserNavigationJournal:'));
  writeFileSync(join(dir,'metadata.swift'),'import Foundation\nimport WebKit\n'+metadata);
  const sources=['Browser/BrowserPasswordVault.swift','Browser/BrowserPasswordsSettingsView.swift',
    // W54 讓密碼設定頁改用共用視覺 token 與元件，fixture 要一起帶進來才編得過。
    'Visual/WorkspaceSidebarMetrics.swift','Browser/BrowserSettingsComponents.swift','Browser/BrowserGeneralSettings.swift','Browser/BrowserShortcuts.swift',
    'Browser/BrowserAIVault.swift','Browser/BrowserAIVaultSettingsView.swift','Browser/BrowserAILogin.swift','Browser/Import/BrowserPasswordCSVImport.swift',
    'Chat/TatwoPermissionPreset.swift','Chat/TatwoCodexSandboxMode.swift',
    'Custody/TOTP.swift','Custody/AIICloudImport.swift','Custody/AIAccountEditView.swift','Custody/AgentAccountsSettingsView.swift','Custody/AIPasswordChange.swift','Custody/BreachDetector.swift'].map(p=>app+p);
  const binary=join(dir,'fixture');
  const compile=spawnSync('swiftc',['-parse-as-library','-swift-version','6','-num-threads','2',...sources,join(dir,'metadata.swift'),writeBrowserVisualTokens(dir),
    'tests/fixtures/browser-ai-vault-dependencies.swift','tests/fixtures/agent-accounts-checks.swift','-o',binary],{cwd:root,encoding:'utf8',timeout:150000});
  assert.equal(compile.status,0,compile.stdout+compile.stderr);
  const run=spawnSync(binary,[dir,...process.env.W59_RENDER==='1'?['--render']:[]],{encoding:'utf8',timeout:25000});
  assert.equal(run.status,0,run.stdout+run.stderr);
  assert.match(run.stdout,/W59 production Swift fixture passed: \d+ checks/);
  assert.doesNotMatch(run.stdout+run.stderr,/example-(?:old|new|candidate|password)|GEZDGNB/);
  console.log(run.stdout.trim());
});

test('W59-fix: breach-policy panel matches approved mockup v3 rows', () => {
  const view = readFileSync(new URL('../App/Sources/Tatwo2/Custody/AgentAccountsSettingsView.swift', import.meta.url), 'utf8');
  assert.match(view, /LabeledContent\("偵測到外洩時"\)/);
  assert.match(view, /你的帳號：Island 提醒＋一鍵協助換　·　AI 專屬帳號：自動換新並同步/);
  assert.match(view, /Toggle\("AI 專屬帳號自動換並同步", isOn: \$detector\.automaticallyAssistAI\)/);
  for (const label of ['登入', '簽名／付款', '外洩偵測', '偵測到外洩時', '緊急停用']) {
    assert.ok(view.includes(label), label);
  }
});
