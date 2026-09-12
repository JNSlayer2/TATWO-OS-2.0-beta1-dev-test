// 反例跑器：自建 mkdtemp fixture（絕不接受外部路徑做刪除），每案兩個獨立 worker 程序，raw stdout/stderr 落檔。
// 用法：node first-init-probe.mjs <codex> <outDir> [N]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { LOCK_DIR, MARKER_FILE, OWNER_FILE } from './first-init.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const [codex, outDir, nArg] = process.argv.slice(2); const N = Number(nArg || 6);
fs.mkdirSync(outDir, { recursive: true });
const STRIP = /^(OPENAI_|ANTHROPIC_|CLAUDE_|CODEX_|XAI_|GROK_|GITHUB_|GH_|TATWO2_(OS|BROWSER)_SOCKET|SSH_AUTH_SOCK)/;
const baseEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !STRIP.test(k)));
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo2-first-init-sandbox-'));   // 自建 HOME／TMPDIR／cwd；不複製任何登入
fs.mkdirSync(path.join(sandbox, 'home')); fs.mkdirSync(path.join(sandbox, 'tmp')); fs.mkdirSync(path.join(sandbox, 'cwd'));
const runWorker = (home, tag, env = {}, waitMs = 60000, extraArgs = []) => new Promise((resolve) => {
  const child = spawn(process.execPath, [path.join(here, 'first-init-worker.mjs'), codex, home, String(waitMs), ...extraArgs], { cwd: path.join(sandbox, 'cwd'), env: { ...baseEnv, HOME: path.join(sandbox, 'home'), TMPDIR: path.join(sandbox, 'tmp'), ...env }, stdio: ['ignore', 'pipe', 'pipe'] });
  let so = '', se = '';
  child.stdout.on('data', (d) => so += d); child.stderr.on('data', (d) => se += d);
  child.on('exit', (code) => { fs.writeFileSync(path.join(outDir, `${tag}.stdout.log`), so); fs.writeFileSync(path.join(outDir, `${tag}.stderr.log`), se);
    let parsed = null; try { parsed = JSON.parse(so.trim().split('\n').pop()); } catch {}
    resolve({ code, parsed }); });
});
const fresh = () => fs.mkdtempSync(path.join(sandbox, 'tmp', 'home-'));
/** 等到鎖裡出現 owner.json（pid 相符或任一）→ 代表 worker 已持鎖；逾時回 false。 */
const waitForOwner = async (home, pid, ms) => { const f = path.join(home, LOCK_DIR, OWNER_FILE); const t0 = Date.now(); while (Date.now() - t0 < ms) { try { const o = JSON.parse(fs.readFileSync(f, 'utf8')); if (pid === null || o.pid === pid) return true; } catch {} await new Promise((r) => setTimeout(r, 25)); } return false; };
const results = {};
// 1. cold 兩 worker（有協調）：兩個都 initialize、0 sqlite、鎖不存在、marker 在
let pass = 0;
for (let i = 1; i <= N; i++) {
  const home = fresh(); const [a, b] = await Promise.all([runWorker(home, `cold-${i}-a`), runWorker(home, `cold-${i}-b`)]);
  const good = (r) => r.code === 0 && r.parsed?.initialized === true && !r.parsed?.sqliteError && !r.parsed?.error;
  const ok = good(a) && good(b) && !fs.existsSync(path.join(home, LOCK_DIR)) && fs.existsSync(path.join(home, MARKER_FILE));
  if (ok) pass++; results[`cold-${i}`] = { ok, a: a.parsed, b: b.parsed };
}
results.cold_pass = `${pass}/${N}`;
// 2. 對照：無協調，只記統計
let fails = 0;
for (let i = 1; i <= N; i++) { const home = fresh(); const [a, b] = await Promise.all([runWorker(home, `nolock-${i}-a`, { TATWO2_FIRST_INIT_LOCK: '0' }), runWorker(home, `nolock-${i}-b`, { TATWO2_FIRST_INIT_LOCK: '0' })]); if (a.parsed?.sqliteError || b.parsed?.sqliteError || !a.parsed?.initialized || !b.parsed?.initialized) fails++; }
results.nolock_failures = `${fails}/${N}（統計，不判 PASS/FAIL）`;
// 3. 缺 owner 鎖 → fail-closed（縮短等待 2s）
{ const home = fresh(); fs.mkdirSync(path.join(home, LOCK_DIR)); const r = await runWorker(home, 'invalid-owner', {}, 2000); results.invalid_owner_failclosed = r.code === 2 && /lock-invalid/.test(r.parsed?.error || ''); }
// 4. 活 owner 持鎖 → 逾時 fail-closed，且不刪別人的鎖
{ const home = fresh(); const lock = path.join(home, LOCK_DIR); fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, OWNER_FILE), JSON.stringify({ pid: process.pid, token: 'foreign' })); const r = await runWorker(home, 'alive-owner', {}, 2000); results.alive_owner_timeout_failclosed = r.code === 2 && /lock-timeout/.test(r.parsed?.error || '') && fs.existsSync(path.join(lock, OWNER_FILE)); }
// 5. dead owner（pid 已結束）→ 也 fail-closed（不接管、不刪）
{ const home = fresh(); const lock = path.join(home, LOCK_DIR); fs.mkdirSync(lock); fs.writeFileSync(path.join(lock, OWNER_FILE), JSON.stringify({ pid: 999999, token: 'dead' })); const [a, b] = await Promise.all([runWorker(home, 'dead-owner-a', {}, 2000), runWorker(home, 'dead-owner-b', {}, 2000)]); results.dead_owner_two_waiters_failclosed = a.code === 2 && b.code === 2 && fs.existsSync(path.join(lock, OWNER_FILE)); }
// 6. marker 在但 state 缺 → 走鎖（不 bypass）：cold 跑完後刪 state 檔再跑單 worker，應為 owner
{ const home = fresh(); await runWorker(home, 'marker-prep'); for (const f of fs.readdirSync(home)) if (/^state_\d+\.sqlite/.test(f)) fs.rmSync(path.join(home, f), { force: true }); const r = await runWorker(home, 'marker-no-state'); results.marker_without_state_not_warm = r.parsed?.role === 'owner'; /* 只驗 not-warm（走鎖），不宣稱成功初始化 */ }
// 7. 暖家正例：marker＋state 都在 → role warm
{ const home = fresh(); await runWorker(home, 'warm-prep'); const [a, b] = await Promise.all([runWorker(home, 'warm-a'), runWorker(home, 'warm-b')]); results.warm_bypass = a.parsed?.role === 'warm' && b.parsed?.role === 'warm' && a.code === 0 && b.code === 0 && !a.parsed?.error && !b.parsed?.error; }
// 8. 版本不符 → 走鎖
{ const home = fresh(); await runWorker(home, 'ver-prep'); const m = JSON.parse(fs.readFileSync(path.join(home, MARKER_FILE), 'utf8')); m.version = 'other'; fs.writeFileSync(path.join(home, MARKER_FILE), JSON.stringify(m)); const r = await runWorker(home, 'ver-mismatch'); results.version_mismatch_not_warm = r.parsed?.role === 'owner'; /* 只驗 not-warm（走鎖），不宣稱成功初始化 */ }
// 10. 缺 owner 的短發佈窗口：lock 先無 owner，600ms 後才出現活 owner → waiter 不得立刻判 invalid；最後因活 owner 逾時 fail-closed，鎖原樣
{ const home = fresh(); const lock = path.join(home, LOCK_DIR); fs.mkdirSync(lock); setTimeout(() => fs.writeFileSync(path.join(lock, OWNER_FILE), JSON.stringify({ pid: process.pid, token: 'late' })), 600); const r = await runWorker(home, 'late-owner', {}, 2500); results.late_owner_publish_window = r.code === 2 && /lock-timeout/.test(r.parsed?.error || '') && fs.existsSync(path.join(lock, OWNER_FILE)); }
// 11. marker 在但 state 是零位元／無 header → 不 warm（走鎖成 owner）
{ const home = fresh(); await runWorker(home, 'zero-prep'); for (const f of fs.readdirSync(home)) if (/^state_\d+\.sqlite$/.test(f)) fs.writeFileSync(path.join(home, f), ''); const r = await runWorker(home, 'zero-state'); results.zero_byte_state_not_warm = r.parsed?.role === 'owner'; /* 只驗 not-warm（走鎖），不宣稱成功初始化 */ }
// 12. EOF 路徑：owner 起後 stdin 立即 EOF → 不得留下自己的鎖；錯誤原樣（不判 PASS）
{ const home = fresh(); const r = await runWorker(home, 'eof', { TATWO2_FIRST_INIT_WORKER_EOF: '1' }, 5000); results.eof_releases_own_lock = !fs.existsSync(path.join(home, LOCK_DIR)); }
// 13. 取消：worker 起 300ms 後 SIGTERM → 釋放自己的鎖
{ const home = fresh(); const r = await new Promise((resolve) => { const c = spawn(process.execPath, [path.join(here, 'first-init-worker.mjs'), codex, home, '5000'], { cwd: path.join(sandbox, 'cwd'), env: { ...baseEnv, HOME: path.join(sandbox, 'home'), TMPDIR: path.join(sandbox, 'tmp') }, stdio: ['ignore', 'pipe', 'pipe'] }); let so=''; c.stdout.on('data', d => so += d); c.on('exit', (code) => resolve({ code, so })); waitForOwner(home, c.pid, 4000).then(() => c.kill('SIGTERM')); }); results.cancel_releases_own_lock = !fs.existsSync(path.join(home, LOCK_DIR)) && /cancelled/.test(r.so); }
// 14. owner 替換保護：owner 持鎖期間鎖被換成別人的 owner.json → release 不得刪別人的
{ const home = fresh(); const lock = path.join(home, LOCK_DIR); const p = runWorker(home, 'replaced-owner', {}, 5000); const seen = await waitForOwner(home, null, 4000); if (seen) fs.writeFileSync(path.join(lock, OWNER_FILE), JSON.stringify({ pid: 4242, token: 'someone-else' })); const r = await p; let still = false; try { still = JSON.parse(fs.readFileSync(path.join(lock, OWNER_FILE), 'utf8')).token === 'someone-else'; } catch {} results.replaced_owner_not_deleted = still && r.parsed?.released === false; }
// 15. marker 寫失敗（決定性：先把 marker 路徑佔成目錄，rename 必失敗）→ worker 明確 error、exit 非 0、自己的鎖已釋放
{ const home = fresh(); fs.mkdirSync(path.join(home, MARKER_FILE)); const r = await runWorker(home, 'marker-fail', {}, 5000); results.marker_write_failure_explicit = r.code !== 0 && /marker-write-failed/.test(r.parsed?.error || '') && !fs.existsSync(path.join(home, LOCK_DIR)); }
// 16. 初始化 error：用假 codex（回 error 物件）→ worker 記 initialize-error、exit 非 0、鎖釋放
{ const home = fresh(); const fake = path.join(sandbox, 'fake-codex-error.sh'); fs.writeFileSync(fake, '#!/bin/sh\nread line; printf \'%s\\n\' \'{"id":1,"error":{"code":-1,"message":"init refused"}}\'; sleep 1\n', { mode: 0o755 }); const r = await new Promise((resolve) => { const c = spawn(process.execPath, [path.join(here, 'first-init-worker.mjs'), fake, home, '5000'], { cwd: path.join(sandbox, 'cwd'), env: { ...baseEnv, HOME: path.join(sandbox, 'home'), TMPDIR: path.join(sandbox, 'tmp') }, stdio: ['ignore', 'pipe', 'pipe'] }); let so=''; c.stdout.on('data', d => so += d); c.on('exit', (code) => { let parsed=null; try { parsed=JSON.parse(so.trim().split('\n').pop()); } catch {} resolve({ code, parsed }); }); }); results.init_error_explicit = r.code !== 0 && /initialize-error/.test(r.parsed?.error || '') && !fs.existsSync(path.join(home, LOCK_DIR)); }
// 9. spawn ENOENT → 清自己的鎖
{ const home = fresh(); const r = await new Promise((resolve) => { const c = spawn(process.execPath, [path.join(here, 'first-init-worker.mjs'), '/nonexistent/codex', home, '2000'], { stdio: ['ignore', 'pipe', 'pipe'] }); let so=''; c.stdout.on('data', d => so += d); c.on('exit', (code) => resolve({ code, so })); }); results.spawn_enoent_releases_own_lock = !fs.existsSync(path.join(home, LOCK_DIR)) && /spawn/.test(r.so); }
results.sandbox = sandbox;
fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(results, null, 1));
const allOK = pass === N && results.eof_releases_own_lock && results.cancel_releases_own_lock && results.replaced_owner_not_deleted && results.marker_write_failure_explicit && results.init_error_explicit && results.late_owner_publish_window && results.zero_byte_state_not_warm && results.invalid_owner_failclosed && results.alive_owner_timeout_failclosed && results.dead_owner_two_waiters_failclosed && results.marker_without_state_not_warm && results.warm_bypass && results.version_mismatch_not_warm && results.spawn_enoent_releases_own_lock;
console.log(JSON.stringify(results)); console.log(allOK ? 'FIRST-INIT-PROBE PASS' : 'FIRST-INIT-PROBE FAIL'); process.exit(allOK ? 0 : 1);
