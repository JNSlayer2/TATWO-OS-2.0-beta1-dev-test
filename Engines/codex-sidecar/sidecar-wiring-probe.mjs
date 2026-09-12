// 真 sidecar 接線反例（0 LLM）：用 dry-run 套好 wiring 的 sidecar.mjs＋假 codex（PATH 上），自建 sandbox HOME／CODEX_HOME，驗每條退出路徑只收自己的鎖。
// 用法：node sidecar-wiring-probe.mjs <sidecar.mjs 路徑> <outDir>
import fs from 'node:fs'; import os from 'node:os'; import path from 'node:path'; import { spawn } from 'node:child_process';
const [sidecar, outDir] = process.argv.slice(2); fs.mkdirSync(outDir, { recursive: true });
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo2-sidecar-wiring-')); fs.mkdirSync(path.join(sandbox, 'home')); fs.mkdirSync(path.join(sandbox, 'bin')); fs.mkdirSync(path.join(sandbox, 'empty-source-home'));   // 自建空 source home：不讓 sidecar 從 /tmp/tatwo2-fixture 或 ~/.codex 複製 config
const fakeCodex = path.join(sandbox, 'bin', 'codex');
fs.writeFileSync(fakeCodex, `#!${process.execPath}
const fs=require('fs');const path=require('path');
const mode=process.env.FAKE_MODE||'ok';
const isVersion=process.argv.includes('--version');const stamp=(n)=>{ if(isVersion) return; try{fs.writeFileSync(path.join(process.env.CODEX_HOME,n+'-'+process.pid+'.json'),JSON.stringify({t:Date.now(),mode,kind:'app-server'}))}catch{}};
stamp('started');process.on('exit',()=>stamp('exited'));
if(mode==='hang-ignore-term'){process.on('SIGTERM',()=>{});setTimeout(()=>process.exit(0),1500);}
if(mode==='hang-ignore-forever'){process.on('SIGTERM',()=>{});setTimeout(()=>process.exit(0),8000);}
if(process.argv.includes('--version')){console.log('codex-cli fake 0.0.1');process.exit(0);}
if(mode==='exit7'){process.exit(7);}
let buf='';process.stdin.setEncoding('utf8');
process.stdin.on('data',d=>{buf+=d;let i;while((i=buf.indexOf('\\n'))>=0){const line=buf.slice(0,i);buf=buf.slice(i+1);if(!line.trim())continue;let m;try{m=JSON.parse(line)}catch{continue}
 if(mode.startsWith('hang'))continue;
 if(m.method==='initialize'){ if(mode==='initerr'){console.log(JSON.stringify({id:m.id,error:{code:-1,message:'init refused'}}));} else {console.log(JSON.stringify({id:m.id,result:{}}));} }
 else if(m.method==='thread/start'||m.method==='thread/resume'){ const marker=path.join(process.env.CODEX_HOME,'.tatwo2-initialized.json'); const lock=path.join(process.env.CODEX_HOME,'.tatwo2-first-init.lock'); fs.writeFileSync(path.join(process.env.CODEX_HOME,'at-thread-start.json'),JSON.stringify({markerExists:fs.existsSync(marker),lockExists:fs.existsSync(lock)})); console.log(JSON.stringify({id:m.id,result:{thread:{id:'t-fake',model:'fake'}}})); }
 else if(m.id!==undefined){console.log(JSON.stringify({id:m.id,result:{}}));}
}});
process.stdin.on('end',()=>{ if(!mode.startsWith('hang-ignore')) process.exit(0); });   // hang-ignore-*：stdin EOF 也不退，只靠計時器
`, { mode: 0o755 });
const LOCK='.tatwo2-first-init.lock', MARKER='.tatwo2-initialized.json';
const run = (tag, { mode='ok', pathHasCodex=true, preLock=null, eofAfterMs=null, closeAfterInitMs=null, closeAfterMs=null, markerIsDir=false, waitMs=2000, sigtermAfterMs=null, home=null, startDelayMs=0 } = {}) => new Promise(async (resolve) => {
  if (startDelayMs) await new Promise((r) => setTimeout(r, startDelayMs));
  home = home || fs.mkdtempSync(path.join(sandbox, 'codex-home-'));
  if (preLock) { fs.mkdirSync(path.join(home, LOCK)); if (preLock.owner) fs.writeFileSync(path.join(home, LOCK, 'owner.json'), JSON.stringify(preLock.owner)); }
  if (markerIsDir) fs.mkdirSync(path.join(home, MARKER));
  const env = { TATWO2_CODEX_SOURCE_HOME: path.join(sandbox, 'empty-source-home'), PATH: (pathHasCodex ? path.join(sandbox, 'bin') + ':' : '') + path.dirname(process.execPath), HOME: path.join(sandbox, 'home'), TMPDIR: sandbox, CODEX_HOME: home, FAKE_MODE: mode, TATWO2_FIRST_INIT_WAIT_MS: String(waitMs) };
  const c = spawn(process.execPath, [sidecar, '--cwd', sandbox], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const events = []; let so = '', se = ''; let sawInit = false;
  c.stdout.on('data', (d) => { so += d; for (const line of String(d).split('\n')) { if (!line.trim()) continue; try { const e = JSON.parse(line); events.push(e); if (e.ev === 'sdk' && e.msg?.subtype === 'init' && !sawInit) { sawInit = true; if (closeAfterInitMs !== null) setTimeout(() => c.stdin.write('{"op":"close"}\n'), closeAfterInitMs); } } catch {} } });
  c.stderr.on('data', (d) => se += d);
  if (eofAfterMs !== null) setTimeout(() => c.stdin.end(), eofAfterMs);
  if (closeAfterMs !== null) setTimeout(() => { try { c.stdin.write('{"op":"close"}\n'); } catch {} }, closeAfterMs);
  if (sigtermAfterMs !== null) setTimeout(() => c.kill('SIGTERM'), sigtermAfterMs);
  let killedByProbe = false;
  const killer = setTimeout(() => { killedByProbe = true; c.kill('SIGKILL'); }, 15000);
  c.on('exit', (code, signal) => { clearTimeout(killer);
    let atThreadStart = null; try { atThreadStart = JSON.parse(fs.readFileSync(path.join(home, 'at-thread-start.json'), 'utf8')); } catch {}
    const stamps = fs.readdirSync(home).filter(f => /^(started|exited)-\d+\.json$/.test(f)).map(f => ({ f, ...JSON.parse(fs.readFileSync(path.join(home, f), 'utf8')) }));
    const r = { tag, code, signal, killedByProbe, home, stamps, lockExists: fs.existsSync(path.join(home, LOCK)), markerExists: fs.existsSync(path.join(home, MARKER)) && fs.statSync(path.join(home, MARKER)).isFile(), atThreadStart, sawInit, errors: events.filter(e => e.ev === 'error').map(e => String(e.message).slice(0, 120)), closed: events.some(e => e.ev === 'closed') };
    fs.writeFileSync(path.join(outDir, `${tag}.stdout.log`), so); fs.writeFileSync(path.join(outDir, `${tag}.stderr.log`), se); resolve(r); });
});
const R = {};
R.ok = await run('ok', { closeAfterInitMs: 100 });
R.ok_pass = R.ok.code === 0 && R.ok.sawInit && !R.ok.lockExists && R.ok.markerExists && R.ok.atThreadStart?.markerExists === true && R.ok.atThreadStart?.lockExists === false;   // marker＋釋放在 thread/start 之前
R.exit7 = await run('exit7', { mode: 'exit7' });
R.exit7_pass = R.exit7.code !== 0 && !R.exit7.lockExists && !R.exit7.markerExists && R.exit7.errors.length > 0;
R.enoent = await run('enoent', { pathHasCodex: false });
R.enoent_pass = typeof R.enoent.code === 'number' && R.enoent.code !== 0 && R.enoent.signal === null && !R.enoent.killedByProbe && R.enoent.closed && !R.enoent.lockExists && R.enoent.errors.some(m => /找不到 codex|ENOENT/.test(m));   // 側車自行 fail-closed 退出，不是被 killer 殺
R.initerr = await run('initerr', { mode: 'initerr', closeAfterMs: 1500 });
R.initerr_pass = !R.initerr.lockExists && !R.initerr.markerExists && R.initerr.atThreadStart === null && R.initerr.errors.length > 0;   // 沒開 thread
R.foreign = await run('foreign-alive-lock', { preLock: { owner: { pid: process.pid, token: 'foreign' } } });
R.foreign_pass = R.foreign.code === 3 && R.foreign.errors.some(m => /lock-timeout/.test(m)) && R.foreign.lockExists;
R.eofwait = await run('eof-during-wait', { preLock: { owner: { pid: process.pid, token: 'foreign' } }, eofAfterMs: 300, waitMs: 5000 });
R.eofwait_pass = R.eofwait.code === 0 && R.eofwait.errors.some(m => /cancelled/.test(m)) && R.eofwait.lockExists && R.eofwait.closed;
R.markerfail = await run('marker-fail', { markerIsDir: true, closeAfterMs: 1500 });
R.markerfail_pass = !R.markerfail.lockExists && R.markerfail.atThreadStart === null && R.markerfail.errors.some(m => /標記寫入失敗/.test(m));
R.hang = await run('hang', { mode: 'hang', closeAfterMs: 800 });
R.hang_pass = !R.hang.lockExists && R.hang.atThreadStart === null;
// SIGTERM after spawn（initialize 掛住中收到 SIGTERM）：要走 close，child 退出後才釋放鎖
R.sigterm = await run('sigterm-after-spawn', { mode: 'hang', sigtermAfterMs: 300 });
R.sigterm_pass = !R.sigterm.lockExists && R.sigterm.closed && R.sigterm.stamps.some(x => x.f.startsWith('exited')) && R.sigterm.atThreadStart === null;
// slow-exit＋第二個 waiter：A 的 child 忽略 SIGTERM 1.5 秒才退；B 在 A close 後 100ms 進場 → B 的 child 必須在 A 的 child 退出之後才啟動（無重疊初始化）
{ const home = fs.mkdtempSync(path.join(sandbox, 'codex-home-')); const pa = run('slow-exit-A', { mode: 'hang-ignore-term', closeAfterMs: 300, home }); const pb = run('slow-exit-B', { mode: 'ok', closeAfterInitMs: 100, home, waitMs: 6000, startDelayMs: 400 }); const [a, b] = await Promise.all([pa, pb]);
  const appOnly = (r) => r.stamps.filter(x => x.kind === 'app-server');
  const aExit = appOnly(a).filter(x => x.f.startsWith('exited')).map(x => x.t).sort().pop(); const bStart = appOnly(b).filter(x => x.f.startsWith('started')).map(x => x.t).sort().pop();
  R.slow = { a, b, aExit, bStart }; R.slow_pass = !!aExit && !!bStart && bStart >= aExit && b.code === 0 && b.sawInit && !b.lockExists && b.markerExists; }
// close 逾時 child 仍未退出 → 鎖保留（fail-closed）＋明講需人工
R.retain = await run('close-timeout-retains-lock', { mode: 'hang-ignore-forever', closeAfterMs: 300 });
R.retain_pass = R.retain.lockExists && R.retain.errors.some(m => /鎖保留待人工/.test(m));
R.sandbox = sandbox;
const noKiller = ['ok','exit7','enoent','initerr','foreign','eofwait','markerfail','hang','sigterm','retain'].every(k => !R[k].killedByProbe) && !R.slow.a.killedByProbe && !R.slow.b.killedByProbe;
R.no_probe_killer = noKiller;
const all = noKiller && ['ok','exit7','enoent','initerr','foreign','eofwait','markerfail','hang','sigterm','slow','retain'].every(k => R[`${k}_pass`]);
fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(R, null, 1));
console.log(JSON.stringify(Object.fromEntries(Object.entries(R).filter(([k]) => k.endsWith('_pass')))));
console.log(all ? 'SIDECAR-WIRING-PROBE PASS' : 'SIDECAR-WIRING-PROBE FAIL'); process.exit(all ? 0 : 1);
