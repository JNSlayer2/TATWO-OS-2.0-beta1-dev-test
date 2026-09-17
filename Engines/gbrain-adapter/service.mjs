// App-owned single supervisor. Never invoked by an engine / MCP adapter.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { HTTPTransport, StdioTransport, sshArguments, sshCommand, shellQuote } from './server.mjs';

const execute = promisify(execFile);

// Atomic cross-process exclusion. A lock whose owner process is gone (crash, power loss)
// is archived (renamed, never deleted) so the primary can restart; a live owner still blocks.
export function acquireServiceLock(lock, { alive = pidAlive, now = () => Date.now() } = {}) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      fs.mkdirSync(lock, { mode: 0o700 });
      fs.writeFileSync(path.join(lock, 'owner'), String(process.pid), { mode: 0o600 });
      return;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let owner = NaN;
      try { owner = Number.parseInt(fs.readFileSync(path.join(lock, 'owner'), 'utf8'), 10); } catch {}
      if (Number.isInteger(owner) && owner > 0 && alive(owner)) throw new Error('service_already_running');
      if (attempt > 0) throw new Error('service_lock_unrecoverable');
      fs.renameSync(lock, `${lock}.stale-${now()}`);
    }
  }
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

export const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
export async function freePort() {
  const socket = net.createServer();
  await new Promise((resolve, reject) => { socket.once('error', reject); socket.listen(0, '127.0.0.1', resolve); });
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  return port;
}
export function redact(text, secrets = []) {
  for (const s of secrets.filter(Boolean)) text = text.split(s).join('[redacted]');
  return text.replace(/\b(?:sk-[A-Za-z0-9_-]+|gbrain_[A-Za-z0-9_-]+)\b/g, '[redacted]')
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/postgres(?:ql)?:\/\/[^\s"']+/gi, '[redacted]');
}
export function scanSecrets(root, secrets = []) {
  for (const item of fs.readdirSync(root, { withFileTypes: true })) {
    const file = path.join(root, item.name);
    if (item.isSymbolicLink()) throw new Error('unsafe_symlink');
    if (item.isDirectory()) scanSecrets(file, secrets);
    else if (item.isFile()) {
      const fd = fs.openSync(file, 'r'); const buffer = Buffer.alloc(1024 * 1024); let overlap = '';
      try {
        for (;;) {
          const count = fs.readSync(fd, buffer, 0, buffer.length, null);
          if (!count) break;
          const text = overlap + buffer.subarray(0, count).toString('latin1');
          if (secrets.filter(Boolean).some(s => text.includes(s)) || /\bsk-[A-Za-z0-9_-]{8,}/.test(text)) throw new Error('secret_on_disk');
          overlap = text.slice(-8192);
        }
      } finally { fs.closeSync(fd); }
    }
  }
}
export function cleanEnvironment(home, source = process.env) {
  const env = { HOME: home, GBRAIN_HOME: home, PATH: source.PATH ?? '/usr/bin:/bin', LANG: 'en_US.UTF-8', GBRAIN_SWEEP: '0', GBRAIN_TELEMETRY: '0' };
  if (source.TMPDIR) env.TMPDIR = source.TMPDIR;
  return env;
}
function unpack(response) {
  if (response?.error || response?.result?.isError) throw new Error('health_failed');
  const result = response?.result;
  if (result?.structuredContent) return result.structuredContent;
  const text = result?.content?.find(c => c.type === 'text')?.text;
  if (!text) throw new Error('health_missing');
  return JSON.parse(text);
}
export async function health(transport) {
  const clientName = 'tatwo-health';
  const call = async (id, tool, args = {}) => unpack(await transport.request({
    jsonrpc: '2.0', id, method: 'tools/call', params: { name: tool, arguments: args },
  }));
  await transport.request({ jsonrpc: '2.0', id: 70001, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: clientName, version: '1' } } });
  await transport.request({ jsonrpc: '2.0', method: 'notifications/initialized' });
  const stats = await call(70002, 'get_stats');
  const list = await call(70003, 'list_pages', { limit: 1, sort: 'updated_desc' });
  const latest = (Array.isArray(list) ? list : list.pages ?? list.results ?? [])[0];
  let device = latest?.frontmatter?.device ?? null;
  if (latest?.slug) {
    const page = await call(70004, 'get_page', { slug: latest.slug });
    device = page.frontmatter?.device ?? page.metadata?.device ?? page.tags?.find(t => t.startsWith('device:'))?.slice(7) ?? device;
  }
  let lastWriteAt = latest?.updated_at ?? null;
  try {
    const log = await call(70005, 'get_ingest_log', { limit: 1 });
    const last = (Array.isArray(log) ? log : log.entries ?? [])[0];
    if (last?.source_type === 'tatwo-device' && (!lastWriteAt || Date.parse(last.created_at) >= Date.parse(lastWriteAt))) {
      const metadata = JSON.parse(last.summary);
      if (typeof metadata.device === 'string') { device = metadata.device; lastWriteAt = last.created_at; }
    }
  } catch { /* Old wrappers may not expose ingest log; page timestamps remain factual. */ }
  return { pageCount: stats.pages ?? stats.total_pages ?? stats.page_count ?? null, lastWriteAt, lastWriteDevice: device };
}
async function exited(child, timeout = 10000) {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  await new Promise(resolve => {
    const timer = setTimeout(() => { if (child.exitCode === null) child.kill('SIGKILL'); }, timeout);
    child.once('exit', () => { clearTimeout(timer); resolve(); });
  });
}
/// Which connection modes this device may use. A primary normally owns a local brain;
/// the one exception is a completed transfer that explicitly kept GBrain on the former
/// primary (transfer.brain === "retained"), where the new primary connects back to it.
export function brainModePolicy(identity) {
  const transfer = identity?.transfer;
  const retainedOnPrevious = identity?.role === 'primary' && transfer?.brain === 'retained'
    && typeof transfer?.to === 'string' && typeof identity?.deviceID === 'string'
    && transfer.to.toLowerCase() === identity.deviceID.toLowerCase();
  if (identity?.role === 'secondary') return { remote: true, ownsLocal: false, retainedOnPrevious: false };
  if (retainedOnPrevious) return { remote: true, ownsLocal: false, retainedOnPrevious: true };
  return { remote: false, ownsLocal: true, retainedOnPrevious: false };
}

export async function supervise({ root, helper, token = '', adminToken = randomBytes(32).toString('hex'), onToken = async () => {}, onState = () => {}, signal }) {
  const directory = path.join(root, 'gbrain');
  const identity = JSON.parse(fs.readFileSync(path.join(root, 'device.json'), 'utf8'));
  if (!['primary', 'secondary'].includes(identity.role)) throw new Error('invalid_identity');
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const configPath = path.join(directory, 'connection.json');
  let config;
  if (fs.existsSync(configPath)) config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  else {
    if (identity.role !== 'primary') throw new Error('primary_not_configured');
    if (brainModePolicy(identity).retainedOnPrevious) throw new Error('retained_brain_requires_remote_config');
    // Never silently open an old Postgres installation with a new binary.
    if (fs.existsSync(path.join(process.env.HOME ?? '', '.gbrain', 'config.json'))) throw new Error('legacy_wrapper_required');
    config = { mode: 'pglite' };
    fs.writeFileSync(configPath, JSON.stringify(config), { mode: 0o600, flag: 'wx' });
  }
  const policy = brainModePolicy(identity);
  if (policy.remote && (config.mode === 'remote' || config.discover === true)) {
    // Reuse paired SSH trust; discover the primary's random loopback port, not a public listener.
    const ssh = sshArguments(config);
    const remote = await execute('/usr/bin/ssh', [...ssh, config.host, 'cat "$HOME/AI/TATWO OS/gbrain/state.json"'], { timeout: 10000, maxBuffer: 65536 });
    const state = JSON.parse(remote.stdout);
    if (config.primaryID && state.deviceID?.toLowerCase() !== config.primaryID.toLowerCase()) throw new Error('primary_identity_mismatch');
    if (state.mode === 'legacy' && state.legacy?.command) {
      config = { ...config, mode: 'ssh-stdio', discover: true, command: state.legacy.command, args: state.legacy.args ?? [] };
      sshCommand(config); // Validate before persisting non-secret remote wrapper metadata.
    } else if (state.mode === 'pglite') {
      const endpoint = new URL(state.endpoint);
      const acquired = Date.parse(state.acquiredAt);
      if (endpoint.protocol !== 'http:' || endpoint.hostname !== '127.0.0.1' || endpoint.username || endpoint.password ||
          !state.healthy || !Number.isFinite(acquired) || Math.abs(Date.now() - acquired) > 60000) throw new Error('primary_unavailable');
      config = { ...config, mode: 'ssh-http', discover: true, port: Number(endpoint.port) };
      if (!token) {
        if (typeof state.entryRoot !== 'string' || !path.isAbsolute(state.entryRoot)) throw new Error('primary_entry_missing');
        const account = shellQuote(`bearer:${state.entryRoot}`);
        const credential = await execute('/usr/bin/ssh', [...ssh, config.host,
          `/usr/bin/security find-generic-password -s TATWO.GBrain -a ${account} -w`], { timeout: 10000, maxBuffer: 8192 });
        token = credential.stdout.trim();
        if (!token) throw new Error('primary_credential_missing');
        await onToken(token);
      }
    } else { throw new Error('primary_not_configured'); }
    const next = path.join(directory, `connection.${process.pid}.tmp`);
    fs.writeFileSync(next, JSON.stringify(config), { mode: 0o600 });
    fs.renameSync(next, configPath);
  }
  if (identity.role === 'secondary' && !['ssh-stdio', 'ssh-http'].includes(config.mode)) throw new Error('secondary_no_database');
  if (identity.role === 'primary' && policy.ownsLocal && !['legacy', 'pglite'].includes(config.mode)) throw new Error('invalid_primary_mode');
  if (policy.retainedOnPrevious && !['ssh-stdio', 'ssh-http'].includes(config.mode)) throw new Error('retained_brain_must_be_remote');
  const lock = path.join(directory, 'service.lock');
  acquireServiceLock(lock);
  let child, tunnel, endpoint;
  let semanticEnabled = false;
  let failure = null;
  const abortChildren = () => { for (const p of [child, tunnel].filter(Boolean)) if (p.exitCode === null) p.kill('SIGTERM'); };
  signal?.addEventListener('abort', abortChildren, { once: true });
  const secrets = [process.env.OPENAI_API_KEY, process.env.ANTHROPIC_API_KEY, token, adminToken].filter(Boolean);
  const log = event => {
    const logs = path.join(directory, 'logs'); fs.mkdirSync(logs, { recursive: true, mode: 0o700 });
    fs.appendFileSync(path.join(logs, 'service.log'), `${new Date().toISOString()} ${redact(event, secrets)}\n`, { mode: 0o600 });
  };
  const state = (healthy, detail = {}, reason = null) => {
    const value = { mode: config.mode, primary: config.primary ?? (identity.role === 'primary' ? identity.name : null), deviceID: identity.deviceID, endpoint, entryRoot: root,
      ...(config.mode === 'legacy' ? { legacy: { command: config.command, args: config.args ?? [] } } : {}),
      healthy, semanticEnabled, acquiredAt: new Date().toISOString(), reason, ...detail };
    const tmp = path.join(directory, `state.${process.pid}.tmp`);
    fs.writeFileSync(tmp, redact(JSON.stringify(value), secrets), { mode: 0o600 });
    fs.renameSync(tmp, path.join(directory, 'state.json')); onState(value);
  };
  const transport = () => {
    if (endpoint) return new HTTPTransport(endpoint, token);
    if (config.mode === 'legacy' || config.wrapper === true) {
      if (!path.isAbsolute(config.command) || !Array.isArray(config.args ?? []) || (config.args ?? []).some(a => typeof a !== 'string')) throw new Error('invalid_wrapper');
      const env = { ...process.env };
      for (const key of ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'TATWO_GBRAIN_TOKEN', 'GBRAIN_ADMIN_BOOTSTRAP_TOKEN']) delete env[key];
      return new StdioTransport(config.command, config.args ?? [], env);
    }
    return new StdioTransport('/usr/bin/ssh', [...sshArguments(config), config.host, sshCommand(config)]);
  };
  try {
    state(false, {}, 'starting');
    if (config.mode === 'pglite') {
      const home = path.join(directory, 'home');
      fs.mkdirSync(home, { recursive: true, mode: 0o700 });
      const env = cleanEnvironment(home);
      const configure = async args => {
        if (signal?.aborted) throw new Error('cancelled');
        child = spawn(helper, args, { env, cwd: home, stdio: 'ignore' });
        const deadline = setTimeout(() => child.kill('SIGTERM'), 60000);
        const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); }).finally(() => clearTimeout(deadline));
        if (code !== 0) throw new Error('init_failed');
      };
      if (!fs.existsSync(path.join(home, '.gbrain', 'config.json'))) {
        await configure(['init', '--pglite', '--path', path.join(directory, 'brain'), '--no-embedding']);
      }
      let local = JSON.parse(fs.readFileSync(path.join(home, '.gbrain', 'config.json'), 'utf8'));
      if (local.engine !== 'pglite' || path.resolve(local.database_path) !== path.join(directory, 'brain')) throw new Error('unexpected_database');
      let preferences = {};
      if (fs.existsSync(path.join(directory, 'preferences.json'))) preferences = JSON.parse(fs.readFileSync(path.join(directory, 'preferences.json'), 'utf8'));
      const requested = preferences.semanticEnabled === true && Boolean(process.env.OPENAI_API_KEY);
      if (requested && local.embedding_disabled === true) {
        // v0.50.5.0 keyless fresh brains have 1024-wide columns. OpenAI supports
        // reduced dimensions; the upstream init guard refuses any width mismatch.
        // No migration, reindex, or vector clearing command is ever issued here.
        env.OPENAI_API_KEY = process.env.OPENAI_API_KEY;
        await configure(['init', '--pglite', '--path', path.join(directory, 'brain'), '--force',
          '--embedding-model', 'openai:text-embedding-3-small', '--embedding-dimensions', '1024']);
      } else if (!requested && local.embedding_disabled !== true) {
        await configure(['init', '--pglite', '--path', path.join(directory, 'brain'), '--force', '--no-embedding']);
      }
      local = JSON.parse(fs.readFileSync(path.join(home, '.gbrain', 'config.json'), 'utf8'));
      semanticEnabled = requested && local.embedding_disabled !== true;
      scanSecrets(directory, secrets);
      if (signal?.aborted) throw new Error('cancelled');
      const port = await freePort(); endpoint = `http://127.0.0.1:${port}/mcp`;
      env.GBRAIN_ADMIN_BOOTSTRAP_TOKEN = adminToken;
      // Keys enter child environments only; no --key or persisted credential setting.
      for (const name of ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY']) if (process.env[name]) env[name] = process.env[name];
      child = spawn(helper, ['serve', '--http', '--bind', '127.0.0.1', '--port', String(port)], { env, cwd: home, stdio: 'ignore' });
      let childError = false; child.once('error', () => { childError = true; });
      let ready = false;
      const base = `http://127.0.0.1:${port}`;
      for (let attempt = 0; attempt < 120 && !signal?.aborted; attempt++) {
        if (childError || child.exitCode !== null) throw new Error('service_exited');
        try { ready = (await fetch(`${base}/health`, { signal: AbortSignal.timeout(1000) })).ok; } catch {}
        if (ready) break;
        await delay(500);
      }
      if (!ready) throw new Error('service_start_timeout');
      if (!token) {
        const r = await fetch(`${base}/admin/api/issue-magic-link`, { method: 'POST', headers: { Authorization: `Bearer ${adminToken}`, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(5000) });
        if (!r.ok) throw new Error('token_bootstrap_failed');
        const magic = new URL((await r.json()).url);
        const login = await fetch(`${base}${magic.pathname}`, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
        const cookie = login.headers.get('set-cookie')?.split(';')[0];
        if (!cookie) throw new Error('token_bootstrap_failed');
        const minted = await fetch(`${base}/admin/api/api-keys`, { method: 'POST', headers: { Cookie: cookie, 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'TATWO OS' }), signal: AbortSignal.timeout(5000) });
        token = (await minted.json()).token;
        if (!token || !minted.ok) throw new Error('token_bootstrap_failed');
        secrets.push(token);
        await onToken(token); // parent persists directly in Keychain; never stdout logs.
      }
    } else if (config.mode === 'ssh-http') {
      if (!token || !Number.isInteger(config.port) || config.port < 1 || config.port > 65535) throw new Error('invalid_forward');
      const port = await freePort();
      tunnel = spawn('/usr/bin/ssh', [...sshArguments(config), '-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2', '-L', `127.0.0.1:${port}:127.0.0.1:${config.port}`, config.host], { stdio: 'ignore' });
      tunnel.on('error', () => {});
      endpoint = `http://127.0.0.1:${port}/mcp`;
      await delay(500);
    }
    scanSecrets(directory, secrets);
    const refresh = async () => {
      const client = transport();
      try { state(true, await health(client)); }
      catch { state(false, {}, 'health_unavailable'); }
      finally { await client.close(); }
    };
    log('service_started');
    while (!signal?.aborted) {
      await refresh();
      await new Promise(resolve => {
        let timer;
        const done = () => { clearTimeout(timer); signal?.removeEventListener('abort', done); resolve(); };
        timer = setTimeout(done, 15000);
        if (signal?.aborted) done(); else signal?.addEventListener('abort', done, { once: true });
      });
      if (child && (child.exitCode !== null || child.signalCode !== null)) throw new Error('service_exited');
      if (tunnel && (tunnel.exitCode !== null || tunnel.signalCode !== null)) throw new Error('forward_exited');
    }
  } catch (error) {
    const codes = new Set(['init_failed', 'unexpected_database', 'service_exited', 'service_start_timeout',
      'token_bootstrap_failed', 'secret_on_disk', 'unsafe_symlink', 'invalid_forward', 'forward_exited',
      'keychain_timeout', 'keychain_failed', 'cancelled']);
    failure = codes.has(error?.message) ? error.message : 'service_unavailable';
    log(failure);
    throw new Error(failure);
  } finally {
    signal?.removeEventListener('abort', abortChildren);
    for (const process of [child, tunnel].filter(Boolean)) { if (process.exitCode === null) process.kill('SIGTERM'); await exited(process); }
    state(false, {}, failure ?? 'stopped');
    log('service_stopped');
    fs.rmSync(lock, { recursive: true });
    try { scanSecrets(directory, secrets); }
    catch { state(false, {}, 'secret_on_disk'); throw new Error('secret_on_disk'); }
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  process.stdin.resume(); process.stdin.on('end', () => controller.abort());
  for (const event of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(event, () => controller.abort());
  supervise({ root: process.argv[2], helper: process.argv[3], token: process.env.TATWO_GBRAIN_TOKEN,
    onToken: token => new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('keychain_timeout')), 5000);
      process.stdin.once('data', data => { clearTimeout(timeout); data.toString().trim() === 'stored' ? resolve() : reject(new Error('keychain_failed')); });
      process.stdout.write(JSON.stringify({ token }) + '\n');
    }),
    signal: controller.signal
  }).catch(() => { process.stderr.write('GBrain service unavailable\n'); process.exitCode = 1; });
}
