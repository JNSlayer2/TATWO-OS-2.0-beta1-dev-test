// 反例用 worker（獨立程序）：協調 → 起 app-server（stdin 長開）→ 等 initialize result → 寫 marker（owner）→ 釋放 → 印 JSON 結果。
// 用法：node first-init-worker.mjs <codex> <home> [waitMs] ；env TATWO2_FIRST_INIT_LOCK=0 可關協調（對照組）
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { acquireFirstInit, codexIdentity, writeMarker, FirstInitError } from './first-init.mjs';
const [codex, home, waitArg] = process.argv.slice(2);
const waitMs = Number(waitArg || 60000);
const out = { pid: process.pid, role: null, initialized: false, sqliteError: false, exitCode: null, exitSignal: null, cleanupRequested: false, error: null, stderrTail: '' };
const identity = codexIdentity(codex);
let handle = { role: 'off', release: () => {} };
try {
  if (process.env.TATWO2_FIRST_INIT_LOCK !== '0') handle = await acquireFirstInit(home, identity, { waitMs });
  out.role = handle.role;
} catch (e) {
  out.error = e instanceof FirstInitError ? `${e.code}: ${e.message}` : String(e);
  console.log(JSON.stringify(out)); process.exit(2);   // fail-closed：不起 app-server
}
const child = spawn(codex, ['app-server'], { env: { ...process.env, CODEX_HOME: home }, stdio: ['pipe', 'pipe', 'pipe'] });
let buf = ''; let err = '';
const finish = (code, signal) => {
  out.exitCode = code; out.exitSignal = signal ?? null;
  // 只有「我們在 initialize 成功後主動清理的 SIGTERM」不算錯；其他非 0 退出（例如 initialize 後 exit 7）一律是錯誤
  if (!out.error) {
    if (code !== null && code !== 0) out.error = `app-server-exit:${code}`;
    else if (code === null && !(out.cleanupRequested && signal === 'SIGTERM')) out.error = `app-server-signal:${signal}`;
  }
  out.released = handle.release();
  console.log(JSON.stringify(out));
  process.exit(out.initialized && !out.sqliteError && !out.error ? 0 : 1);   // 成功＝initialize 且 code 0／自家清理，且無任何錯誤
};
child.stdout.on('data', (d) => {
  buf += d;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {           // 逐行 JSON，精確比對 id===1
    const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { continue; }
    if (msg?.id !== 1) continue;
    if (msg.error) { out.error = out.error || `initialize-error: ${JSON.stringify(msg.error).slice(0, 200)}`; }
    else if (msg.result !== undefined && !out.initialized) {
      out.initialized = true;
      if (handle.role === 'owner') { try { writeMarker(home, identity); } catch (e) { out.error = `${e.code || 'marker'}: ${e.message}`; } }
    }
    if (msg.error || out.initialized) setTimeout(() => { out.cleanupRequested = true; try { child.stdin.end(); child.kill(); } catch {} }, 300);
  }
});
child.stderr.on('data', (d) => { err += d; if (/initialize sqlite/.test(err)) out.sqliteError = true; });
child.on('error', (e) => { out.error = `spawn: ${e.code || e.message}`; finish(-1); });
child.on('exit', (code, signal) => { out.stderrTail = err.slice(-300); finish(code, signal); });
child.stdin.write(JSON.stringify({ id: 1, method: 'initialize', params: { clientInfo: { name: 'first-init-worker', version: '0' } } }) + '\n');   // stdin 保持開，不 EOF
setTimeout(() => { out.error = out.error || 'worker-timeout'; out.cleanupRequested = true; try { child.kill(); } catch {} }, Number(process.env.TATWO2_FIRST_INIT_WORKER_TIMEOUT_MS || 30000));
if (process.env.TATWO2_FIRST_INIT_WORKER_EOF === '1') child.stdin.end();   // 反例：EOF 路徑
process.on('SIGTERM', () => { out.error = out.error || 'cancelled'; try { child.kill(); } catch {} finish(-2); });   // 反例：取消等待／取消執行
