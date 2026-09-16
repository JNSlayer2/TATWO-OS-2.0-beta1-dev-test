// W29a isolated regression gates. Never runs the whole installer or touches host apps.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const read = p => readFileSync(new URL('../' + p, import.meta.url), 'utf8');
const install = read('install.sh');
const hygiene = install.split('# UPDATE-ARCHIVE-HYGIENE-BEGIN\n')[1].split('# UPDATE-ARCHIVE-HYGIENE-END')[0];
const transaction = install.split('# TRANSACTION-BEGIN\n')[1].split('# TRANSACTION-END')[0];
const root = () => mkdtempSync(join(tmpdir(), 'w29a-'));
const shell = (code, env = {}) => spawnSync('/bin/bash', ['-c', `set -eu\n${code}`], {encoding:'utf8', env:{...process.env,...env}});
function bundle(path, version) {
  mkdirSync(join(path,'Contents/Resources'),{recursive:true});
  writeFileSync(join(path,'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.tatwo.tatwo2</string><key>CFBundleShortVersionString</key><string>${version}</string></dict></plist>`);
  writeFileSync(join(path,'Contents/Resources/version'),version);
}
test('D1 post-rename SIGKILL keeps verified new destination; launch failures do not roll back', () => {
  for (const mode of ['kill','open','register']) {
    const dir=root(), dest=join(dir,'App.app'), stage=join(dir,'.tatwo-update.fixture.noindex'); mkdirSync(stage);
    bundle(dest,'2.0.5'); bundle(join(stage,'TATWO OS.app'),'2.0.6');
    writeFileSync(join(dir,'install-ready'),'a'.repeat(64)+'  TATWO-OS.zip\n');
    const env={DEST:dest,STAGE:stage,TEMP:dir,TAG:'v2.0.6',REPO:'sample/project',MODE:mode,HOME:dir};
    const replace=install.slice(install.indexOf('# Staging and destination'),install.indexOf('[[ ! -e "$DEST.old" ]] || mv'));
    const code=`${transaction}
codesign() { return 0; }
fail() { echo "$1" >&2; exit 1; }
mv() { command mv "$@"; if [[ "$MODE" == kill && "$1" == "$DEST.new" && "$2" == "$DEST" ]]; then kill -KILL $$; fi; }
open() { [[ "$MODE" != open ]]; }
INSTALL_STARTED_AT=$(date +%s)
${replace.replace('"$LSREGISTER" -f "$DEST"','[[ "$MODE" != register ]]')}`;
    const r=shell(code,env);
    if(mode==='kill') {
      assert.equal(r.signal,'SIGKILL',r.stderr);
      const recover=shell(`${transaction}\ncodesign() { return 0; }\nreconcile_transactions`,env);
      assert.equal(recover.status,0,recover.stderr);
    } else {
      assert.equal(r.status,0,r.stderr);
      assert.equal(JSON.parse(readFileSync(join(stage,'result.json'))).message,mode==='open'?'open_failed':'registration_failed');
    }
    assert.equal(readFileSync(join(dest,'Contents/Resources/version'),'utf8'),'2.0.6', mode);
    assert.equal(JSON.parse(readFileSync(join(stage,'transaction.json'))).phase,'committed');
  }
});
test('D6 owner publication interruption and orphan guard takeover are recoverable; PID reuse is not live', () => {
  for (const mode of ['publish','orphan','reused']) {
    const dir=root(), path=join(dir,'.tatwo-update.lock');
    if(mode!=='publish') {
      mkdirSync(path); writeFileSync(join(path,'owner'),`${process.pid}\nnot-this-start\n`);
      if(mode==='orphan') { mkdirSync(join(path,'reconcile')); writeFileSync(join(path,'reconcile/owner'),'99999999\nold\n'); spawnSync('touch',['-t','202001010000',join(path,'reconcile')]); }
    }
    const r=shell(`${transaction}\nfail() { echo "$1" >&2; exit 42; }\nacquire_update_lock\n[[ -s "$LOCK/owner" ]]`,{DEST:join(dir,'App.app')});
    assert.equal(r.status,0,`${mode}: ${r.stdout} ${r.stderr}`);
    assert.ok(existsSync(join(path,'owner')));
  }
});
function compile(source) {
  const dir=root(); writeFileSync(join(dir,'main.swift'),source);
  const r=spawnSync('swiftc',['-parse-as-library',join(dir,'main.swift'),'-o',join(dir,'fixture')],{encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); return join(dir,'fixture');
}
function runAsync(command,args) { return new Promise((resolve,reject)=> { const p=spawn(command,args); let out='',err=''; p.stdout.on('data',b=>out+=b); p.stderr.on('data',b=>err+=b); p.on('error',reject); p.on('close',code=>resolve({code,out,err})); }); }
async function serve(handler) { const s=createServer(handler); await new Promise(r=>s.listen(0,r)); return s; }
const shared=()=>{ const s=read('App/Sources/Tatwo2/Facade/GitHubReleaseUpdateChecker.swift'); assert.ok(s.includes('// UPDATE-TRANSPORT-BEGIN'),'production shared transport missing'); return s.split('// UPDATE-TRANSPORT-BEGIN\n')[1].split('// UPDATE-TRANSPORT-END')[0]; };
test('D3 production URLSession delegate strips Authorization over two-host 302 chain', async () => {
  const source=shared(), seen=[];
  const server=await serve((req,res)=> { seen.push([req.url,req.headers.authorization ?? '']);
    if(req.url==='/one') {res.writeHead(302,{Location:`http://localhost:${server.address().port}/two`});}
    else if(req.url==='/two') {res.writeHead(302,{Location:`http://127.0.0.1:${server.address().port}/three`});}
    res.end('ok'); });
  try {
    const bin=compile(`import Foundation\nimport CryptoKit\n${source}\n@main struct Main { static func main() async throws {
      var r=URLRequest(url:URL(string:CommandLine.arguments[1])!, timeoutInterval:5); r.setValue("Bearer synthetic",forHTTPHeaderField:"Authorization")
      let s=URLSession(configuration:.ephemeral,delegate:UpdateRedirectDelegate.shared,delegateQueue:nil)
      _ = try await s.data(for:r,delegate:UpdateRedirectDelegate.shared)
    }}`);
    const r=await runAsync(bin,[`http://127.0.0.1:${server.address().port}/one`]); assert.equal(r.code,0,r.err);
    assert.deepEqual(seen,[['/one','Bearer synthetic'],['/two',''],['/three','']]);
  } finally {server.close();}
});
test('D2 production online revalidation accepts unchanged marker and rejects withdrawn/unreachable candidates', async () => {
  const source=shared();
  const server=await serve((req,res)=> {
    const mode=req.url.split('/')[1];
    if(mode==='404') {res.writeHead(404);res.end();return;}
    if(req.url.endsWith('/marker')) {res.end(mode==='changed'?'changed':'cached');return;}
    res.setHeader('Content-Type','application/json');
    res.end(JSON.stringify({tag_name:'v2.0.6',draft:mode==='draft',prerelease:mode==='prerelease',assets:mode==='missing'?[]:[{id:1,name:'TATWO-OS.install-ready',browser_download_url:`http://127.0.0.1:${server.address().port}/${mode}/marker`}]}));
  });
  try {
    const bin=compile(`import Foundation\nimport CryptoKit\n${source}\n@main struct Main { static func main() async {
      do { _ = try await UpdateReleaseRevalidation.verify(session:URLSession(configuration:.ephemeral), request:URLRequest(url:URL(string:CommandLine.arguments[1])!), tag:"v2.0.6", cachedMarker:Data("cached".utf8), markerRequest:{ asset in URLRequest(url:URL(string:asset.browser_download_url)!) }); print("accepted") }
      catch { print("rejected") }
    }}`);
    for(const mode of ['ok','404','draft','prerelease','missing','changed']) {const r=await runAsync(bin,[`http://127.0.0.1:${server.address().port}/${mode}/release`]); assert.equal(r.code,0,r.err); assert.equal(r.out.trim(),mode==='ok'?'accepted':'rejected',mode);}
    const port=server.address().port; await new Promise(r=>server.close(r));
    const r=await runAsync(bin,[`http://127.0.0.1:${port}/offline/release`]); assert.equal(r.out.trim(),'rejected');
    const updater=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
    const update=updater.slice(updater.indexOf('    func update(to'),updater.indexOf('    private let fileManager'));
    assert.ok(update.indexOf('revalidate')<update.indexOf('handOff('));
    assert.match(update,/removeItem[\s\S]*release.json/); assert.match(update,/版本已撤回或無法確認/);
  } finally {server.close();}
});
test('D4 peer only pulls repository-scoped cached archives; corrupt downloads are cleaned', () => {
  const peer=read('App/Sources/Tatwo2/Facade/PeerUpdateSource.swift');
  const pull=peer.slice(peer.indexOf('static func pull'),peer.indexOf('static func read'));
  assert.doesNotMatch(pull,/else if runtime|\/usr\/bin\/ditto/);
  const updater=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
  assert.match(updater,/defer \{[\s\S]*removeInvalidDownloads\(in: folder\)/);
});

test('D6 SIGKILL after atomic mkdir and owner write leaves a reclaimable dead lock', () => {
  const dir=root(), env={DEST:join(dir,'App.app')};
  const r=shell(`${transaction}\nfail() { exit 42; }\nwrite_owner() { printf '%s\\nold\\n' "$$" > "$1/owner"; kill -KILL $$; }\nacquire_update_lock`,env);
  assert.equal(r.signal,'SIGKILL'); assert.ok(existsSync(join(dir,'.tatwo-update.lock/owner'))); assert.ok(!readdirSync(dir).some(n=>n.includes('.tmp.')));
  const next=shell(`${transaction}\nfail() { exit 42; }\nacquire_update_lock`,env); assert.equal(next.status,0,next.stderr);
});
test('D7 failed pre-transaction stage is archived; age sweep excludes transaction stages', () => {
  const dir=root(), stage=join(dir,'.tatwo-update.failure.noindex'); mkdirSync(stage);
  const cleanup=install.slice(install.indexOf('cleanup() {'),install.indexOf('trap cleanup EXIT'));
  const r=shell(`${transaction}\n${hygiene}\n${cleanup}\nCOMMITTED=0; REPLACED=0; LOCK=""; PREVIOUS=""; cleanup`,{HOME:dir,STAGE:stage,DEST:join(dir,'App.app')});
  assert.equal(r.status,0,r.stderr); assert.ok(!existsSync(stage));
  assert.ok(existsSync(join(dir,'Library/Application Support/TATWO OS/UpdateArchives/failed-.tatwo-update.failure.noindex')));
  for(const [name,tx] of [['orphan',false],['transaction',true]]) {
    const p=join(dir,`.tatwo-update.${name}.noindex`); mkdirSync(p);
    if(tx) writeFileSync(join(p,'transaction.json'),'{}');
    spawnSync('touch',['-t','202001010000',p]);
  }
  const retention=install.split('# TEMP-RETENTION-BEGIN\n')[1].split('# TEMP-RETENTION-END')[0];
  const sweep=shell(`trash() { exit 90; }\n${transaction}\n${hygiene}\n${retention}\narchive_old_downloads`,{HOME:dir,TMPDIR:dir,DEST:join(dir,'App.app')});
  assert.equal(sweep.status,0,sweep.stderr);
  assert.ok(existsSync(join(dir,'.tatwo-update.orphan.noindex')));
  assert.ok(existsSync(join(dir,'.tatwo-update.transaction.noindex/transaction.json')));
});
test('D12 withdrawal gates reject missing authorization and non-TTY without invoking gh', () => {
  const dir=root(); writeFileSync(join(dir,'gh'),'#!/bin/bash\necho called >> "$CAPTURE"\nexit 0\n',{mode:0o755});
  const env={...process.env,PATH:dir+':'+process.env.PATH,CAPTURE:join(dir,'called'),TMPDIR:dir};
  for(const args of [[],['tatwo214/TATWO-OS-2.0-private','v2.0.6'],['tatwo214/TATWO-OS-2.0-beta1-dev-test','v2.0.6','--yes'],['tatwo214/TATWO-OS-2.0-beta1-dev-test','v2.0.6','--i-authorize']]) {
    const r=spawnSync('bash',['scripts/withdraw-release.sh',...args],{env,encoding:'utf8'}); assert.notEqual(r.status,0); assert.ok(!existsSync(env.CAPTURE));
  }
  const r=spawnSync('bash',['scripts/withdraw-release.sh','tatwo214/TATWO-OS-2.0-private','v2.0.6','--yes'],{env,encoding:'utf8'});
  assert.equal(r.status,0,r.stderr); assert.equal(readFileSync(env.CAPTURE,'utf8').trim().split('\n').length,3);
});
function signedBundle(path, version='2.0.5') {
  bundle(path,version); mkdirSync(join(path,'Contents/MacOS'));
  const info=join(path,'Contents/Info.plist');writeFileSync(info,readFileSync(info,'utf8').replace('</dict>','<key>CFBundleExecutable</key><string>fixture</string></dict>'));
  assert.equal(spawnSync('cp',['/usr/bin/true',join(path,'Contents/MacOS/fixture')]).status,0);
  const r=spawnSync('codesign',['--force','--sign','-',path],{encoding:'utf8'}); assert.equal(r.status,0,r.stderr);
}
test('D13 shell restore requires real strict signature and identity; malformed transactions do not block others', () => {
  for(const kind of ['signed','unsigned','wrong-id']) {
    const dir=root(), dest=join(dir,'App.app'), stage=join(dir,'.tatwo-update.test.noindex');mkdirSync(stage);
    if(kind==='unsigned') bundle(dest+'.old','2.0.5'); else signedBundle(dest+'.old');
    if(kind==='wrong-id') {const info=join(dest+'.old','Contents/Info.plist');writeFileSync(info,readFileSync(info,'utf8').replace('ai.tatwo.tatwo2','example.fixture'));spawnSync('codesign',['--force','--sign','-',dest+'.old']);}
    const bad=join(dir,'.tatwo-update.bad.noindex');mkdirSync(bad);writeFileSync(join(bad,'transaction.json'),'{broken');
    writeFileSync(join(stage,'transaction.json'),JSON.stringify({owner:'99999999',ownerStart:'old',phase:'replacing',backup:dest+'.old'}));
    const r=shell(`${transaction}\nreconcile_transactions`,{DEST:dest});assert.equal(r.status,0,r.stderr);
    assert.equal(existsSync(dest),kind==='signed');assert.equal(existsSync(dest+'.old'),kind!=='signed');
    assert.equal(JSON.parse(readFileSync(join(stage,'result.json'))).message,kind==='signed'?'interrupted_restored':'restore_refused');
    assert.equal(JSON.parse(readFileSync(join(bad,'result.json'))).message,'invalid_transaction');
  }
});
test('D1 D6 D13 production Swift launch recovery preserves post-rename candidate and refuses invalid backups', () => {
  const src=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
  const method=src.slice(src.indexOf('    static func reconcileOnLaunch('),src.indexOf('    private func records('));
  const bin=compile(`import Foundation\nimport Darwin\nstruct Probe { static let destinationApp="/unused"\n${method}\n}\n@main struct Main { static func main() { Probe.reconcileOnLaunch(destination:CommandLine.arguments[1]) } }`);
  for(const mode of ['post-rename','unsigned','wrong-id','signed']) {
    const dir=root(), dest=join(dir,'App.app'), stage=join(dir,'.tatwo-update.fixture.noindex');mkdirSync(stage);
    if(mode==='unsigned') bundle(dest+'.old','2.0.5');else signedBundle(dest+'.old');
    if(mode==='post-rename') signedBundle(dest,'2.0.6');
    if(mode==='wrong-id') {const info=join(dest+'.old','Contents/Info.plist');writeFileSync(info,readFileSync(info,'utf8').replace('ai.tatwo.tatwo2','example.fixture'));spawnSync('codesign',['--force','--sign','-',dest+'.old']);}
    const bad=join(dir,'.tatwo-update.bad.noindex');mkdirSync(bad);writeFileSync(join(bad,'transaction.json'),'bad');
    writeFileSync(join(stage,'transaction.json'),JSON.stringify({owner:'99999999',ownerStart:'old',phase:'replacing',backup:dest+'.old',nextVersion:'2.0.6'}));
    const r=spawnSync(bin,[dest],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
    const message=JSON.parse(readFileSync(join(stage,'result.json'))).message;
    assert.equal(message,mode==='post-rename'?'interrupted_commit_completed':mode==='signed'?'interrupted_restored_on_launch':'restore_refused');
    assert.ok(!existsSync(join(dir,'.tatwo-update.lock')));
    assert.equal(JSON.parse(readFileSync(join(bad,'result.json'))).message,'invalid_transaction');
    if(mode==='post-rename') assert.equal(readFileSync(join(dest,'Contents/Resources/version'),'utf8'),'2.0.6');
  }
});
test('D14 legacy marker allows only full ZIP on a no-manifest release', () => {
  const dir=root();writeFileSync(join(dir,'install-ready'),'ready\n');
  const functions=install.split('# DOWNLOAD-RETRY-BEGIN\n')[1].split('# DOWNLOAD-RETRY-END')[0];
  for(const manifest of [0,1]) for(const name of ['TATWO-OS.zip','TATWO-OS-app.zip','TATWO-OS.manifest.json']) {
    const r=shell(`${functions}\nLEGACY_READY=1\nready_matches '${name}' '${'a'.repeat(64)}'`,{TEMP:dir,RELEASE_HAS_MANIFEST:String(manifest)});
    assert.equal(r.status,manifest===0&&name==='TATWO-OS.zip'?0:1,`${manifest}/${name}`);
  }
});
test('D15 private GH_TOKEN reaches gh only, not the shared installer or its child environment', () => {
  const dir=root(), bin=join(dir,'bin');mkdirSync(bin);
  writeFileSync(join(bin,'gh'),`#!/bin/bash\n[[ "$GH_TOKEN" == fixture-secret ]] || exit 41\ncat <<'SCRIPT'\n#!/bin/bash\n[[ -z "\${GH_TOKEN+x}" ]] || exit 42\n/bin/bash -c '[[ -z "\${GH_TOKEN+x}" && -z "\${PRIVATE_TOKEN+x}" ]]' || exit 43\nSCRIPT\n`,{mode:0o755});
  // The installer prepends system tool paths: use a sourced gh shell double so no real gh is reached.
  const code=read('scripts/install-private.sh');
  const result=shell(`gh() { '${join(bin,'gh')}' "$@"; }\n${code}`,{GH_TOKEN:'fixture-secret',TATWO_OS_VERSION:'v2.0.6',TMPDIR:dir});
  assert.equal(result.status,0,result.stderr);
});

test('D17 runtime archive pins compression and refuses ad-hoc valid vendor bundles', () => {
  const dir=root(), app=join(dir,'TATWO OS.app');
  const vendor=join(app,'Contents/Resources/runtime/Vendor.app'); signedBundle(vendor);
  const r=spawnSync('python3',['scripts/runtime-sign.py',app,'-'],{encoding:'utf8',env:{...process.env,TATWO2_RELEASE_BASELINE:'',PYTHONDONTWRITEBYTECODE:'1'}});
  assert.notEqual(r.status,0);assert.match(r.stderr,/vendor bundle requires a persistent signing identity/);
  const layer=read('scripts/runtime-layer.py');assert.match(layer,/entry\._compresslevel = 9/);
  const r2=spawnSync('python3',['-c',`
import importlib.util, pathlib, sys, zipfile
spec=importlib.util.spec_from_file_location('layer',sys.argv[1]); layer=importlib.util.module_from_spec(spec); spec.loader.exec_module(layer)
seen=[]; original=zipfile.ZipFile.open
def capture(self, info, mode='r', *args, **kwargs):
    if mode=='w': seen.append(info._compresslevel)
    return original(self, info, mode, *args, **kwargs)
zipfile.ZipFile.open=capture
root=pathlib.Path(sys.argv[2]); tree=root/'tree';tree.mkdir();(tree/'f').write_bytes(b'abcd'*10000)
layer.archive(tree,root/'runtime.zip');assert seen and all(x==9 for x in seen),seen
`,new URL('../scripts/runtime-layer.py',import.meta.url).pathname,dir],{encoding:'utf8',env:{...process.env,PYTHONDONTWRITEBYTECODE:'1'}});
  assert.equal(r2.status,0,r2.stderr);
});
test('D17 shell version patterns agree; soft assembly failures and reused-parent symlinks fail closed', () => {
  const version=install.match(/"\$TATWO_OS_VERSION" =~ (\S+)/)[1], tag=install.match(/"\$TAG" =~ (\S+)/)[1];assert.equal(version,tag);
  const soft=install.slice(install.indexOf('soft_fail()'),install.indexOf('assemble_delta()'));
  const r=shell(`${soft}\nfail() { soft_fail "$@"; }\nfail fixture`,{STAGE:root()});assert.equal(r.status,1);assert.doesNotMatch(r.stderr,/安裝失敗/);
  const start=install.lastIndexOf('      parent="$DEST/Contents/$path"');
  const reuse=install.slice(start,install.indexOf('    else',start));assert.ok(reuse.includes('! -L'));
  const dir=root();mkdirSync(join(dir,'old/Contents'),{recursive:true});mkdirSync(join(dir,'outside'));mkdirSync(join(dir,'new/Contents/Resources'),{recursive:true});
  writeFileSync(join(dir,'outside/runtime'),'fixture');spawnSync('ln',['-s',join(dir,'outside'),join(dir,'old/Contents/Resources')]);
  const refused=shell(`${soft}\nclone_copy() { cp "$1" "$2"; }\npath=Resources/runtime\n${reuse}`,{DEST:join(dir,'old'),SOURCE:join(dir,'new'),STAGE:dir});
  assert.equal(refused.status,1);assert.ok(!existsSync(join(dir,'new/Contents/Resources/runtime')));
});

test('D6 concurrent stale guard claimants admit exactly one updater', async () => {
  const dir=root(), lock=join(dir,'.tatwo-update.lock');mkdirSync(lock);writeFileSync(join(lock,'owner'),'99999999\nold\n');
  mkdirSync(join(lock,'reconcile'));spawnSync('touch',['-t','202001010000',join(lock,'reconcile')]);
  const code=`set -eu\nDEST='${join(dir,'App.app')}'\n${transaction}\nfail() { exit 42; }\nacquire_update_lock\nprintf acquired\nsleep 2`;
  const results=await Promise.all(Array.from({length:4},()=>runAsync('/bin/bash',['-c',code])));
  assert.equal(results.filter(r=>r.code===0&&r.out==='acquired').length,1,JSON.stringify(results));
  assert.equal(results.filter(r=>r.code===42).length,3);
});

test('NEW-1 production Swift launch recovery leaves a live shell owner lock alone (owner file has trailing newline)', () => {
  const src=read('App/Sources/Tatwo2/Facade/InAppUpdater.swift');
  const method=src.slice(src.indexOf('    static func reconcileOnLaunch('),src.indexOf('    private func records('));
  const bin=compile(`import Foundation\nimport Darwin\nstruct Probe { static let destinationApp="/unused"\n${method}\n}\n@main struct Main { static func main() { Probe.reconcileOnLaunch(destination:CommandLine.arguments[1]) } }`);
  const dir=root(), dest=join(dir,'App.app'), lock=join(dir,'.tatwo-update.lock'), stage=join(dir,'.tatwo-update.live.noindex');
  mkdirSync(stage); signedBundle(dest+'.old');
  const start=spawnSync('/bin/ps',['-p',String(process.pid),'-o','lstart='],{encoding:'utf8',env:{...process.env,LC_ALL:'C'}}).stdout.trim();
  mkdirSync(lock); writeFileSync(join(lock,'owner'),`${process.pid}\n${start}\n`);
  writeFileSync(join(stage,'transaction.json'),JSON.stringify({owner:String(process.pid),ownerStart:start,phase:'replacing',backup:dest+'.old'}));
  const r=spawnSync(bin,[dest],{encoding:'utf8'});assert.equal(r.status,0,r.stderr);
  assert.ok(existsSync(join(lock,'owner')),'live lock must stay in place');
  assert.ok(!readdirSync(dir).some(n=>n.startsWith('.tatwo-lock-retained.')),'live lock must not be retained/taken over');
  assert.ok(!existsSync(join(stage,'result.json')),'live transaction must not be reconciled');
  assert.ok(existsSync(dest+'.old'));
});
