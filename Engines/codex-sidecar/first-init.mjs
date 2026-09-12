// codex 冷家第一次初始化協調（v2，依 Codex 2026-09-06 10:43 review 收窄）。
// 只做一件事：同一個 CODEX_HOME 還沒有「真 initialize 成功」的證據時，讓 sidecar 一次只有一個去起 app-server。
// 原則：不用 state 檔存在當 ready；不以 age／pid 偷取別人的鎖；所有異常一律 fail-closed（由呼叫端發 error 並退出）；
// release 只刪自己 token 的 owner 檔＋rmdir 空目錄；等待 async 有界。
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const LOCK_DIR = '.tatwo2-first-init.lock';
export const OWNER_FILE = 'owner.json';
export const MARKER_FILE = '.tatwo2-initialized.json';

export class FirstInitError extends Error { constructor(code, message) { super(message); this.code = code; } }

/** codex 執行檔身分：路徑＋sha256 前 16＋`--version` 輸出（找不到就 null，呼叫端視為冷家走鎖）。 */
export function codexIdentity(codexBin) {
  try {
    const real = fs.realpathSync(codexBin);
    const sha = crypto.createHash('sha256').update(fs.readFileSync(real)).digest('hex').slice(0, 16);
    let version = '';
    try { version = execFileSync(real, ['--version'], { encoding: 'utf8', timeout: 10000 }).trim(); } catch { version = ''; }
    return { path: real, sha256_16: sha, version };
  } catch { return null; }
}

const SQLITE_HEADER = Buffer.from('SQLite format 3\0', 'latin1');
/** native state 證據：至少一個 state_*.sqlite 是 regular 檔、≥100 bytes、帶 SQLite header。只看 header，不做修復或深層掃描。 */
export function hasNativeState(home) {
  try {
    return fs.readdirSync(home).some((f) => {
      if (!/^state_\d+\.sqlite$/.test(f)) return false;
      const full = path.join(home, f);
      const st = fs.lstatSync(full);                 // lstat：symlink 不算 regular state
      if (!st.isFile() || st.size < 100) return false;
      const fd = fs.openSync(full, 'r');
      try { const b = Buffer.alloc(16); fs.readSync(fd, b, 0, 16, 0); return b.equals(SQLITE_HEADER); } finally { fs.closeSync(fd); }
    });
  } catch { return false; }
}

/** 暖家證據：marker 存在＋身分相符＋native state 在；三者缺一都不算暖。 */
export function isWarm(home, identity) {
  if (!identity) return false;
  try {
    const m = JSON.parse(fs.readFileSync(path.join(home, MARKER_FILE), 'utf8'));
    return m?.sha256_16 === identity.sha256_16 && m?.version === identity.version && hasNativeState(home);
  } catch { return false; }
}

/** marker 原子寫：temp＋rename；只在真 initialize result 後由 owner 呼叫。 */
export function writeMarker(home, identity) {
  const tmp = path.join(home, `${MARKER_FILE}.${process.pid}.tmp`);
  try {
    fs.writeFileSync(tmp, JSON.stringify({ ...identity, at: new Date().toISOString(), pid: process.pid }), { mode: 0o600 });
    fs.renameSync(tmp, path.join(home, MARKER_FILE));
  } catch (error) {
    try { fs.unlinkSync(tmp); } catch {}
    throw new FirstInitError('marker-write-failed', `first-init marker write failed: ${error?.code || error}`);
  }
}

function readOwner(lockPath) {
  try { return JSON.parse(fs.readFileSync(path.join(lockPath, OWNER_FILE), 'utf8')); } catch { return null; }
}

/**
 * 取協調權。回傳 { role: 'warm' | 'owner', release }。
 * 拿不到（別人持鎖超過 waitMs、鎖無 owner／非法／權限不明）→ throw FirstInitError（呼叫端 fail-closed）。
 * signal（AbortSignal）可取消等待：取消時不留任何自己的東西。
 */
export async function acquireFirstInit(home, identity, { waitMs = 60000, pollMs = 200, publishWindowMs = 2000, signal } = {}) {
  if (!home) return { role: 'warm', release: () => {} };
  if (isWarm(home, identity)) return { role: 'warm', release: () => {} };
  const lockPath = path.join(home, LOCK_DIR);
  const token = crypto.randomUUID();
  const started = Date.now();
  let missingOwnerSince = null;
  while (true) {
    if (signal?.aborted) throw new FirstInitError('cancelled', 'first-init wait cancelled');
    try {
      fs.mkdirSync(lockPath);                       // 原子取得
      const ownerPath = path.join(lockPath, OWNER_FILE);
      try {
        fs.writeFileSync(ownerPath, JSON.stringify({ pid: process.pid, token, startedAt: new Date().toISOString() }), { mode: 0o600 });
      } catch (writeError) {
        // 發佈 owner 失敗：收掉自己剛建的空鎖（rmdir 只對空目錄生效），明確報錯，不留無聲半成品
        try { fs.rmdirSync(lockPath); } catch {}
        throw new FirstInitError('owner-publish-failed', `first-init owner publish failed: ${writeError?.code || writeError}`);
      }
      const release = () => {
        // 只刪自己 token 的 owner 檔；目錄非空或 owner 不是自己就不動（別人的鎖）
        try {
          const cur = JSON.parse(fs.readFileSync(ownerPath, 'utf8'));
          if (cur?.token !== token) return false;
          fs.unlinkSync(ownerPath);
          fs.rmdirSync(lockPath);                   // 非空會 ENOTEMPTY → 不動
          return true;
        } catch { return false; }
      };
      return { role: 'owner', release, token };
    } catch (error) {
      if (error instanceof FirstInitError) throw error;   // 保留 owner-publish-failed 等原始碼
      if (error?.code !== 'EEXIST') throw new FirstInitError('lock-error', `first-init lock error: ${error?.code || error}`);
    }
    // 別人持鎖：只驗證鎖看起來合法，不偷取。mkdir→owner.json 不是原子：缺 owner 先給一個短發佈窗口（publishWindowMs），窗口後仍缺才 fail-closed。
    const owner = readOwner(lockPath);
    if (!owner || !Number.isInteger(owner.pid) || owner.pid <= 0 || typeof owner.token !== 'string') {
      if (missingOwnerSince === null) missingOwnerSince = Date.now();
      if (Date.now() - missingOwnerSince > publishWindowMs) {
        throw new FirstInitError('lock-invalid', `first-init lock at ${lockPath} has missing/invalid owner after ${publishWindowMs}ms; needs manual recovery`);
      }
      if (Date.now() - started > waitMs) throw new FirstInitError('lock-timeout', `first-init lock at ${lockPath} unresolved after ${waitMs}ms; needs manual recovery`);
      await new Promise((r) => setTimeout(r, pollMs));
      continue;
    }
    missingOwnerSince = null;
    if (isWarm(home, identity)) return { role: 'warm', release: () => {} };   // owner 已完成並寫 marker 但鎖尚未消失的極短窗口
    if (Date.now() - started > waitMs) {
      throw new FirstInitError('lock-timeout', `first-init lock at ${lockPath} still held by pid ${owner.pid} after ${waitMs}ms; needs manual recovery`);
    }
    await new Promise((r) => setTimeout(r, pollMs));
  }
}
