// OS-owned MCP boundary. No database driver: every adapter shares one HTTP owner.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const reads = new Set(['search', 'get_page', 'list_pages', 'get_timeline', 'get_raw_data',
  'get_tags', 'list_tags', 'get_links', 'get_stats', 'get_ingest_log', 'get_backlinks',
  'get_chunks', 'get_health', 'get_versions', 'file_list', 'file_url', 'resolve_slugs', 'traverse_graph']);
export const writes = new Set(['put_page', 'add_timeline_entry', 'put_raw_data', 'log_ingest']);
export function stamp(name, args, device) {
  if (!reads.has(name) && !writes.has(name)) throw new Error('tool_not_allowed');
  if (reads.has(name)) return args;
  if (typeof device !== 'string' || !device.trim() || /[\r\n\0]/.test(device)) throw new Error('invalid_device');
  const a = structuredClone(args);
  const tags = ['device', `device:${device}`];
  if (name === 'put_page') {
    if (typeof a.content !== 'string') throw new Error('invalid_content');
    let body = a.content, header = [];
    if (/^---\r?\n/.test(body)) {
      const match = body.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
      if (!match) throw new Error('unsupported_frontmatter');
      header = match[1].split(/\r?\n/);
      body = body.slice(match[0].length);
    }
    for (const key of ['tags', 'device', 'device_written_at']) {
      const candidates = header.filter(line => new RegExp(`^["']?${key}["']?\\s*:`).test(line));
      if (candidates.length > 1 || candidates.some(line => !line.startsWith(`${key}:`))) throw new Error('unsupported_frontmatter');
    }
    // Preserve simple YAML metadata, fail closed rather than corrupt complex tags.
    const at = header.findIndex(l => /^tags:/.test(l));
    let previous = [];
    if (at >= 0) {
      const raw = header[at].slice(5).trim();
      let count = 1;
      if (!raw) {
        while (/^\s+- /.test(header[at + count] ?? '')) {
          let value = header[at + count++].trim().slice(2);
          if (value.startsWith('"')) { try { value = JSON.parse(value); } catch { throw new Error('unsupported_tags'); } }
          else if (value.startsWith("'") && value.endsWith("'")) value = value.slice(1, -1).replaceAll("''", "'");
          else if (!/^[\w :./-]+$/.test(value)) throw new Error('unsupported_tags');
          previous.push(value);
        }
      } else {
        try { previous = JSON.parse(raw); }
        catch {
          if (!/^\[[\w :.,/-]*\]$/.test(raw)) throw new Error('unsupported_tags');
          previous = raw.slice(1, -1).split(',').map(v => v.trim()).filter(Boolean);
        }
      }
      if (!Array.isArray(previous) || previous.some(t => typeof t !== 'string')) throw new Error('invalid_tags');
      header.splice(at, count);
    }
    if (header.some(l => /^(?:device|device_written_at):\s*[>|&*]/.test(l))) throw new Error('unsupported_device_metadata');
    header = header.filter(l => !/^(device|device_written_at):/.test(l));
    header.push(`device: ${JSON.stringify(device)}`, `device_written_at: ${JSON.stringify(new Date().toISOString())}`,
      `tags: ${JSON.stringify([...new Set([...previous.filter(t => t !== 'device' && !t.startsWith('device:')), ...tags])])}`);
    a.content = `---\n${header.join('\n')}\n---\n${body}`;
  } else if (name === 'put_raw_data') {
    a.data = { ...a.data, device, device_written_at: new Date().toISOString(), tags: [...new Set([
      ...(Array.isArray(a.data?.tags) ? a.data.tags.filter(t => typeof t === 'string' && t !== 'device' && !t.startsWith('device:')) : []), ...tags])] };
  } else if (name === 'add_timeline_entry') {
    a.source = a.source || `device:${device}`;
    a.detail = `${a.detail ?? ''}\n${JSON.stringify({ device, tags, device_written_at: new Date().toISOString() })}`;
  } else {
    a.source_ref = a.source_ref || `device:${device}`;
    a.summary = `${a.summary ?? ''} ${JSON.stringify({ device, tags })}`;
  }
  return a;
}

export class HTTPTransport {
  constructor(url, token) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'http:' || parsed.hostname !== '127.0.0.1' || parsed.username || parsed.password) throw new Error('loopback_required');
    this.url = url; this.token = token; this.session = null;
  }
  async request(message) {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', Authorization: `Bearer ${this.token}` };
    if (this.session) headers['Mcp-Session-Id'] = this.session;
    const r = await fetch(this.url, { method: 'POST', headers, body: JSON.stringify(message), signal: AbortSignal.timeout(15000), redirect: 'error' });
    if (!r.ok) throw new Error(`upstream_http_${r.status}`);
    this.session = r.headers.get('mcp-session-id') ?? this.session;
    if (r.status === 202 || r.status === 204) return null;
    if (r.headers.get('content-type')?.includes('text/event-stream')) {
      const reader = r.body.getReader(); const decoder = new TextDecoder(); let buffer = '';
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          buffer = (buffer + decoder.decode(value, { stream: true })).replace(/\r\n/g, '\n');
          let end;
          while ((end = buffer.indexOf('\n\n')) >= 0) {
            const event = buffer.slice(0, end); buffer = buffer.slice(end + 2);
            const data = event.split('\n').filter(l => l.startsWith('data:')).map(l => l.slice(5).trimStart()).join('\n');
            if (data) { const result = JSON.parse(data); if (result.id === message.id) return result; }
          }
        }
      } finally { await reader.cancel(); }
      throw new Error('upstream_missing_response');
    }
    const text = await r.text();
    return text ? JSON.parse(text) : null;
  }
  async close() {
    if (this.session) await fetch(this.url, { method: 'DELETE', headers: { Authorization: `Bearer ${this.token}`, 'Mcp-Session-Id': this.session }, signal: AbortSignal.timeout(2000) }).catch(() => {});
  }
}

export class StdioTransport {
  constructor(command, args, env = process.env) {
    this.pending = new Map();
    this.child = spawn(command, args, { env, stdio: ['pipe', 'pipe', 'ignore'] });
    readline.createInterface({ input: this.child.stdout }).on('line', line => {
      try { const r = JSON.parse(line); const p = this.pending.get(r.id); if (p) { clearTimeout(p.timer); this.pending.delete(r.id); p.resolve(r); } } catch {}
    });
    const fail = () => { for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error('upstream_closed')); } this.pending.clear(); };
    this.child.on('error', fail); this.child.on('exit', fail);
  }
  request(message) {
    if (message.id === undefined) { this.child.stdin.write(JSON.stringify(message) + '\n'); return Promise.resolve(null); }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(message.id); reject(new Error('upstream_timeout')); }, 15000);
      this.pending.set(message.id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify(message) + '\n', e => { if (e) { clearTimeout(timer); this.pending.delete(message.id); reject(new Error('upstream_closed')); } });
    });
  }
  close() { this.child.stdin.end(); this.child.kill('SIGTERM'); }
}

export function keychainToken(root) {
  return execFileSync('/usr/bin/security', ['find-generic-password', '-s', 'TATWO.GBrain', '-a', `bearer:${root}`, '-w'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
}
export function sshArguments(config) {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(config.host)) throw new Error('invalid_ssh_target');
  const args = ['-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5'];
  if (config.user) {
    if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]*$/.test(config.user)) throw new Error('invalid_ssh_user');
    args.push('-l', config.user);
  }
  if (config.sshPort !== undefined) {
    if (!Number.isInteger(config.sshPort) || config.sshPort < 1 || config.sshPort > 65535) throw new Error('invalid_ssh_port');
    args.push('-p', String(config.sshPort));
  }
  return args;
}
export const shellQuote = value => "'" + String(value).replaceAll("'", "'\\''") + "'";
export function sshCommand(config) {
  if (!path.isAbsolute(config.command) || (config.args ?? []).some(a => typeof a !== 'string')) throw new Error('invalid_remote_wrapper');
  return [config.command, ...(config.args ?? [])].map(shellQuote).join(' ');
}
export function connection(root) {
  const config = JSON.parse(fs.readFileSync(path.join(root, 'gbrain', 'connection.json'), 'utf8'));
  if (config.mode === 'legacy' || config.mode === 'ssh-stdio') {
    // Configuration contains only a wrapper path / trusted SSH alias, never DB credentials.
    if (config.mode === 'legacy' || config.wrapper === true) {
      if (!path.isAbsolute(config.command) || config.args?.some(a => typeof a !== 'string')) throw new Error('invalid_legacy_wrapper');
      return new StdioTransport(config.command, config.args ?? []);
    }
    return new StdioTransport('/usr/bin/ssh', [...sshArguments(config), config.host, sshCommand(config)]);
  }
  const state = JSON.parse(fs.readFileSync(path.join(root, 'gbrain', 'state.json'), 'utf8'));
  if (!state.endpoint || Date.now() - Date.parse(state.acquiredAt) > 60000) throw new Error('service_unavailable');
  return new HTTPTransport(state.endpoint, process.env.TATWO_GBRAIN_TOKEN || keychainToken(root));
}
export async function runAdapter(root) {
  let identity = JSON.parse(fs.readFileSync(path.join(root, 'device.json'), 'utf8'));
  const transport = connection(root);
  const input = readline.createInterface({ input: process.stdin });
  const send = value => { if (value) process.stdout.write(JSON.stringify(value) + '\n'); };
  try {
    for await (const line of input) {
      let request;
      try {
        if (line.length > 4 * 1024 * 1024) throw new Error('request_too_large');
        request = JSON.parse(line);
        if (request.method === 'tools/call') {
          if (writes.has(request.params.name)) identity = JSON.parse(fs.readFileSync(path.join(root, 'device.json'), 'utf8'));
          request.params.arguments = stamp(request.params.name, request.params.arguments ?? {}, identity.name);
        }
        else if (!['initialize', 'notifications/initialized', 'ping', 'tools/list'].includes(request.method)) throw new Error('method_not_allowed');
        const response = await transport.request(request);
        if (request.method === 'tools/call' && writes.has(request.params.name) && response?.result && !response.result.isError) {
          // Use the existing ingest log so health includes timeline/raw writes too,
          // without rewriting a page or racing another client's read-modify-write.
          try {
            const name = 'log_ingest';
            const audit = await transport.request({ jsonrpc: '2.0', id: `tatwo-write-${request.id}`, method: 'tools/call', params: {
              name, arguments: { source_type: 'tatwo-device', source_ref: `device:${identity.name}`,
                pages_updated: request.params.arguments.slug ? [request.params.arguments.slug] : request.params.arguments.pages_updated ?? [],
                summary: JSON.stringify({ device: identity.name, tags: ['device', `device:${identity.name}`], tool: request.params.name }) }
            } });
            if (audit?.error || audit?.result?.isError) throw new Error('write_log_unavailable');
          } catch {
            response.result._meta = { ...response.result._meta, 'tatwo/writeLog': 'write succeeded; last-write health metadata unavailable' };
          }
        }
        if (request.method === 'tools/list' && response?.result?.tools) response.result.tools = response.result.tools.filter(t => reads.has(t.name) || writes.has(t.name));
        send(response);
      } catch {
        if (request?.id !== undefined) send({ jsonrpc: '2.0', id: request.id, error: { code: -32000, message: 'GBrain request rejected or service unavailable' } });
        else if (request === undefined) send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Invalid JSON' } });
      }
    }
  } finally { await transport.close(); }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = process.argv[2] ?? process.env.TATWO_OS_ROOT ?? path.join(os.homedir(), 'AI/TATWO OS');
  runAdapter(root).catch(() => { process.stderr.write('GBrain unavailable\n'); process.exitCode = 1; });
}
