// Isolated production fragments: never install or touch /Applications.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, readdirSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
const installer=read('install.sh'), swift=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
const block=name=>installer.split(`# ${name}-BEGIN\n`)[1].split(`# ${name}-END`)[0];
const root=()=>mkdtempSync(join(tmpdir(),'w31-'));
const sh=(code,env={})=>spawnSync('/bin/bash',['-c',`set -eu\n${code}`],{encoding:'utf8',env:{...process.env,...env}});
test('W31 offline delta-only wins economy; app-only and online reusable runtime select layered; prepared route wins',()=>{
 const dir=root(); writeFileSync(join(dir,'delta.zip'),'fixture');writeFileSync(join(dir,'manifest'),'fixture');
 const select=installer.slice(installer.indexOf('SOURCE="$STAGE/split/TATWO OS.app"\nif'),installer.indexOf('# Do not silently move'));
 for(const [offline,delta,route,expected] of [['yes',true,'','delta'],['yes',false,'','layered'],['',true,'','layered'],['',true,'delta','delta'],['yes',true,'layered','layered']]) {
  const r=sh(`${block('DELTA-SELECTION')}
osascript() { return 1; }
assemble_delta() { echo delta; }
assemble_runtime() { echo layered; }
download_full() { echo full; }
verify_signed_app() { :; }
${select}`,{DEST:dir,STAGE:dir,TEMP:dir,APP_URL:'fixture',TATWO_OS_OFFLINE_RELEASE:offline?dir:'',TATWO_OS_PREFETCHED_DELTA_ZIP:delta?join(dir,'delta.zip'):'',TATWO_OS_PREFETCHED_MANIFEST:join(dir,'manifest'),TATWO_OS_PREFETCHED_ROUTE:route});
  assert.equal(r.status,0,r.stderr);assert.equal(r.stdout.split('\n')[0],expected,JSON.stringify({offline,delta,route}));
 }
});
test('NEW-2 competing lock is untouched without nested temporary directories',()=>{
 const dir=root(),lock=join(dir,'lock');mkdirSync(lock);writeFileSync(join(lock,'owner'),'opponent');
 const r=sh(`${block('TRANSACTION')}\nclaim_directory "$DEST"`,{DEST:lock});assert.notEqual(r.status,0);assert.deepEqual(readdirSync(lock),['owner']);assert.deepEqual(readdirSync(dir),['lock']);
});
test('NEW-4 permission guard precedes admission redirect; NEW-3 localized contention',()=>{
 const acquire=block('TRANSACTION').split('acquire_update_lock()')[1];assert.ok(acquire.indexOf('[[ -w ')>=0&&acquire.indexOf('[[ -w ')<acquire.indexOf('exec 9>>'));
 assert.match(acquire,/lockf -s -t 0 9 \|\| fail "另一個更新正在取得鎖，請稍後再試"/);
});
test('NEW-5 soft failures preserve diagnostics without fatal-install banner',()=>{
 const dir=root(),soft=installer.slice(installer.indexOf('soft_fail()'),installer.indexOf('assemble_delta()'));
 const r=sh(`${soft}\nsoft_fail 'fixture reason'`,{STAGE:dir});assert.equal(r.status,1);assert.doesNotMatch(r.stderr,/安裝失敗/);assert.match(readFileSync(join(dir,'fallback.log'),'utf8'),/fixture reason/);
 assert.match(installer,/差異／層級路徑失敗原因見/);
});
test('NEW-6 dead prepared stages archive immediately; live prepared stays; NEW-8 only aged retained locks archive',()=>{
 const dir=root(),home=join(dir,'home');mkdirSync(home);
 for(const [name,owner] of [['dead','99999999'],['live',String(process.pid)]]) {const stage=join(dir,`.tatwo-update.${name}.noindex`);mkdirSync(stage);writeFileSync(join(stage,'transaction.json'),JSON.stringify({phase:'prepared',owner}));}
 for(const name of ['.tatwo-lock-retained.old','.tatwo-lock-retained.fresh','reconcile-orphan.old']) {mkdirSync(join(dir,name));if(name.endsWith('old'))spawnSync('touch',['-t','202001010000',join(dir,name)]);}
 const r=sh(`${block('TRANSACTION')}\n${block('UPDATE-ARCHIVE-HYGIENE')}\n${block('TEMP-RETENTION')}\narchive_old_downloads`,{DEST:join(dir,'App.app'),HOME:home,TMPDIR:dir});assert.equal(r.status,0,r.stderr);
 assert.ok(!existsSync(join(dir,'.tatwo-update.dead.noindex')));assert.ok(existsSync(join(dir,'.tatwo-update.live.noindex')));
 assert.ok(!existsSync(join(dir,'.tatwo-lock-retained.old')));assert.ok(!existsSync(join(dir,'reconcile-orphan.old')));assert.ok(existsSync(join(dir,'.tatwo-lock-retained.fresh')));
 const archives=join(home,'Library/Application Support/TATWO OS/UpdateArchives');assert.ok(readdirSync(archives).some(n=>n.includes('dead')));assert.equal(readdirSync(join(archives,'retained-locks')).length,2);
});
test('W31 prepared archives carry selection into helper environment; NEW-7 CI explicitly includes regression suites',()=>{
 assert.match(swift,/var route: String/);assert.match(swift,/result.route = useDelta \? "delta" : "layered"/);assert.match(swift,/prefetchedRoute: zip.route/);assert.match(swift,/export TATWO_OS_PREFETCHED_ROUTE=/);
 const ci=read('.github/workflows/update-policy.yml');for(const name of ['w29a-update-fixes','w29b-ux-fixes','w31-r2-tail','runtime-determinism'])assert.ok(ci.includes(`tests/${name}.test.mjs`));
});
test('W31 offline delta-only executes production delta assembly and verifies the final real code seal',()=>{
 const dir=root(),old=join(dir,'old.app'),fresh=join(dir,'new.app'),base=join(dir,'base'),assets=join(dir,'assets'),stage=join(dir,'stage');mkdirSync(stage);
 const run=(cmd,args)=>{const r=spawnSync(cmd,args,{encoding:'utf8'});assert.equal(r.status,0,r.stderr);};
 for(const [path,version] of [[old,'2.0.5'],[fresh,'2.0.6']]) {
  mkdirSync(join(path,'Contents/MacOS'),{recursive:true});mkdirSync(join(path,'Contents/Resources'));
  run('cp',['/usr/bin/true',join(path,'Contents/MacOS/fixture')]);
  writeFileSync(join(path,'Contents/Resources/payload'),version);
  writeFileSync(join(path,'Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string><key>CFBundleExecutable</key><string>fixture</string><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`);
  run('codesign',['--force','--sign','-',path]);
 }
 run('python3',['scripts/per-file-delta.py',old,base,'v2.0.5']);run('python3',['scripts/per-file-delta.py',fresh,assets,'v2.0.6',join(base,'TATWO-OS.manifest.json')]);
 writeFileSync(join(dir,'release.json'),JSON.stringify({tag_name:'v2.0.6'}));
 const assembly=installer.slice(installer.indexOf('soft_fail()'),installer.indexOf('assemble_runtime()'));
 const r=sh(`${block('INVISIBLE-PRIMITIVES')}\n${block('DELTA-TREE')}\n${block('DELTA-SELECTION')}\n${assembly}
 layer_download() { test -f "$2" && cp "$2" "$3"; }
 verify_signed_app() { /usr/bin/codesign --verify --strict "$1"; }
 delta_preferred && assemble_delta`,{DEST:old,TEMP:dir,STAGE:stage,TATWO_OS_OFFLINE_RELEASE:assets,TATWO_OS_PREFETCHED_DELTA_ZIP:join(assets,'TATWO-OS-delta-v2.0.5-v2.0.6.zip'),TATWO_OS_PREFETCHED_MANIFEST:join(assets,'TATWO-OS.manifest.json'),TATWO_OS_PREFETCHED_ROUTE:''});
 assert.equal(r.status,0,r.stderr);assert.equal(readFileSync(join(stage,'delta.app.disabled/Contents/Resources/payload'),'utf8'),'2.0.6');assert.ok(!existsSync(join(assets,'TATWO-OS-app.zip')));
});
test('NEW-6 cleanup archives its own prepared stage and startup sweep archives recovered dead prepared transaction',()=>{
 const dir=root(),stage=join(dir,'.tatwo-update.prepared.noindex'),dest=join(dir,'App.app');mkdirSync(stage);mkdirSync(dest);
 writeFileSync(join(stage,'transaction.json'),JSON.stringify({phase:'prepared',owner:'99999999',backup:dest+'.old'}));
 const orphan=join(stage,'lock.finished/reconcile-orphan.old');mkdirSync(orphan,{recursive:true});spawnSync('touch',['-t','202001010000',orphan]);
 const r=sh(`${block('TRANSACTION')}\n${block('UPDATE-ARCHIVE-HYGIENE')}\n${block('TEMP-RETENTION')}\nreconcile_transactions\narchive_old_downloads`,{DEST:dest,HOME:dir,TMPDIR:dir});assert.equal(r.status,0,r.stderr);assert.ok(!existsSync(stage));assert.ok(readdirSync(join(dir,'Library/Application Support/TATWO OS/UpdateArchives/retained-locks')).some(n=>n.startsWith('reconcile-orphan.old')));
 const own=join(dir,'.tatwo-update.own.noindex');mkdirSync(own);writeFileSync(join(own,'transaction.json'),JSON.stringify({phase:'prepared',owner:String(process.pid)}));
 const cleanup=installer.slice(installer.indexOf('cleanup()'),installer.indexOf('trap cleanup EXIT'));
 const c=sh(`${block('TRANSACTION')}\n${block('UPDATE-ARCHIVE-HYGIENE')}\n${cleanup}\nCOMMITTED=0; REPLACED=0; LOCK=''; PREVIOUS=''; cleanup`,{STAGE:own,DEST:dest,HOME:dir});assert.equal(c.status,0,c.stderr);assert.ok(!existsSync(own));
});
test('NEW-3 compiled production reconcile verifies seals outside admission and restores under lock',()=>{
 const dir=root(),dest=join(dir,'App.app'),old=dest+'.old',stage=join(dir,'.tatwo-update.fixture.noindex');mkdirSync(stage);
 mkdirSync(join(old,'Contents/MacOS'),{recursive:true});
 assert.equal(spawnSync('cp',['/usr/bin/true',join(old,'Contents/MacOS/fixture')]).status,0);
 writeFileSync(join(old,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string><key>CFBundleExecutable</key><string>fixture</string></dict></plist>');
 assert.equal(spawnSync('codesign',['--force','--sign','-',old]).status,0);
 writeFileSync(join(stage,'transaction.json'),JSON.stringify({phase:'replacing',owner:'99999999',backup:old}));
 const verifier=join(dir,'codesign-probe');
 writeFileSync(verifier,`#!/bin/bash\nexec 9>>'${dir}/.tatwo-update.admission'\n/usr/bin/lockf -s -t 0 9 || exit 42\necho unlocked >> '${dir}/verified'\nexec 9>&-\n/usr/bin/codesign "$@"\n`,{mode:0o755});
 const method=swift.slice(swift.indexOf('    static func reconcileOnLaunch('),swift.indexOf('    private func records(')).replace('"/usr/bin/codesign"',JSON.stringify(verifier));
 writeFileSync(join(dir,'main.swift'),`import Foundation\nimport Darwin\nstruct Probe { static let destinationApp="/unused"\n${method}\n}\nProbe.reconcileOnLaunch(destination:CommandLine.arguments[1])\n`);
 const compile=spawnSync('swiftc',[join(dir,'main.swift'),'-o',join(dir,'probe')],{encoding:'utf8'});assert.equal(compile.status,0,compile.stderr);
 const result=spawnSync(join(dir,'probe'),[dest],{encoding:'utf8'});assert.equal(result.status,0,result.stderr);
 assert.equal(readFileSync(join(dir,'verified'),'utf8').trim(),'unlocked');assert.ok(existsSync(dest));assert.ok(!existsSync(old));assert.ok(!existsSync(join(dir,'.tatwo-update.lock')));
});
test('NEW-6/8 archive destination failure is best-effort and preserves the original artifacts',()=>{
 const dir=root(),stage=join(dir,'.tatwo-update.dead.noindex'),retained=join(dir,'.tatwo-lock-retained.old');mkdirSync(stage);mkdirSync(retained);
 writeFileSync(join(stage,'transaction.json'),JSON.stringify({phase:'prepared',owner:'99999999'}));spawnSync('touch',['-t','202001010000',retained]);
 writeFileSync(join(dir,'not-directory'),'fixture');
 const r=sh(`${block('TRANSACTION')}\n${block('UPDATE-ARCHIVE-HYGIENE')}\n${block('TEMP-RETENTION')}\narchive_old_downloads\necho continued`,{DEST:join(dir,'App.app'),HOME:join(dir,'not-directory'),TMPDIR:dir});assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/continued/);assert.ok(existsSync(stage));assert.ok(existsSync(retained));assert.match(r.stderr,/保留原位置/);
});
test('W31 native installer economy keeps online runtime reuse layered, but accepts offline delta-only',()=>{
 const dir=root(),dest=join(dir,'App.app'),contents=join(dest,'Contents'),sha='a'.repeat(64);
 mkdirSync(join(contents,'Resources/runtime'),{recursive:true});
 writeFileSync(join(contents,'Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>2.0.5</string></dict></plist>');
 writeFileSync(join(contents,'Resources/runtime-layer.json'),JSON.stringify({sha,paths:['Resources/runtime']}));
 const delta='TATWO-OS-delta-v2.0.5-v2.0.6.zip',manifest='TATWO-OS.manifest.json';
 writeFileSync(join(dir,'release.json'),JSON.stringify({tag_name:'v2.0.6',assets:[['TATWO-OS-app.zip',10000],[delta,1],[delta+'.sha256',64],[manifest,100],[manifest+'.sha256',64],['TATWO-OS-runtime-'+sha.slice(0,12)+'.zip',10000]].map(([name,size])=>({name,size}))}));
 writeFileSync(join(dir,delta),'fixture');writeFileSync(join(dir,manifest),'fixture');
 for(const offline of ['',dir]) {const r=sh(`${block('DELTA-SELECTION')}\ndelta_preferred`,{DEST:dest,TEMP:dir,TATWO_OS_OFFLINE_RELEASE:offline,TATWO_OS_PREFETCHED_DELTA_ZIP:join(dir,delta),TATWO_OS_PREFETCHED_MANIFEST:join(dir,manifest),TATWO_OS_PREFETCHED_ROUTE:''});assert.equal(r.status,offline?0:1,r.stderr);}
});
