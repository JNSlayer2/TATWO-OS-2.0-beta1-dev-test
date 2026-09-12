#!/usr/bin/env node
// tatwo2 Grok sidecar：每一輪呼叫隔離的 grok-isolated，並翻成 Engines/PROTOCOL.md 的 Claude SDK 形狀。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const ORIGINAL_HOME = os.homedir();
const GROK = process.env.TATWO2_GROK_BIN || path.join(os.homedir(), ".codex/bin/grok-isolated");
const GROK_HOME = process.env.TATWO2_GROK_HOME || process.env.HOME || ORIGINAL_HOME;
const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(name);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
};

const cwd = flag('--cwd', process.cwd());
// 2026-09-11: Grok gets TATWO's built-in tools too (Computer Use + built-in browser), like the Claude sidecar.
const HERE = path.dirname(fileURLToPath(import.meta.url));
const OS_MCP = path.resolve(HERE, '../os-mcp/server.mjs');
const BROWSER_MCP = path.resolve(HERE, '../browser-mcp/server.mjs');
let mcpConfig;
try { const text = flag('--mcp-config', undefined); mcpConfig = text ? JSON.parse(text) : undefined; } catch { mcpConfig = undefined; }
let resume = flag('--resume', undefined);
let model = flag('--model', undefined);
const permissionMode = flag('--permission-mode', 'default');
const systemPrompt = flag('--system-prompt', undefined);

const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const sdk = (msg) => emit({ ev: 'sdk', msg });

function prepareGrokHome() {
  for (const dir of [
    GROK_HOME,
    path.join(GROK_HOME, '.grok'),
    path.join(GROK_HOME, '.config'),
    path.join(GROK_HOME, '.cache'),
  ]) {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dir, 0o700);
  }
  writeBuiltInMCP();
  const destination = path.join(GROK_HOME, '.grok', 'auth.json');
  const source = path.join(ORIGINAL_HOME, '.grok', 'auth.json');
  if (destination !== source && !fs.existsSync(destination) && fs.existsSync(source)) {
    fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(destination, 0o600);
  }
}
/// Register tatwo2_os / tatwo2_browser in the isolated Grok home's config.toml (never the user's own
/// ~/.grok: only when TATWO2_GROK_HOME is set). Replaces our two blocks, keeps everything else.
function writeBuiltInMCP() {
  if (!process.env.TATWO2_GROK_HOME) return;
  const file = path.join(GROK_HOME, '.grok', 'config.toml');
  const q = (value) => JSON.stringify(String(value));
  const block = (name, script, socketKey) => {
    const env = {};
    if (process.env[socketKey]) env[socketKey] = process.env[socketKey];
    if (mcpConfig?.threadID) env.TATWO2_THREAD_ID = mcpConfig.threadID;
    const envText = Object.entries(env).map(([k, v]) => `${k} = ${q(v)}`).join(', ');
    return `[mcp_servers.${name}]\ncommand = "node"\nargs = [${q(script)}]\n${envText ? `env = { ${envText} }\n` : ''}`;
  };
  let existing = '';
  try { existing = fs.readFileSync(file, 'utf8'); } catch {}
  const kept = existing.split(/(?=^\[)/m).filter((section) => !/^\[mcp_servers\.tatwo2_(os|browser)\]/.test(section)).join('').trimEnd();
  const next = `${kept ? kept + '\n\n' : ''}${block('tatwo2_os', OS_MCP, 'TATWO2_OS_SOCKET')}\n${block('tatwo2_browser', BROWSER_MCP, 'TATWO2_BROWSER_SOCKET')}`;
  fs.writeFileSync(file, next, { mode: 0o600 });
}

try {
  prepareGrokHome();
} catch (error) {
  emit({ ev: 'stderr', line: `準備 Grok 獨立登入資料夾失敗：${String(error?.stack || error)}` });
}

let active = null;
let closing = false;
let closedEmitted = false;
let initialized = false;
let turnCount = 0;
const queue = [];
const announcedTools = new Set();

function emitClosedAndExit(code = 0) {
  if (closedEmitted) return;
  closedEmitted = true;
  emit({ ev: 'closed' });
  process.exitCode = code;
  setImmediate(() => process.exit(code));
}

function textDelta(text, output) {
  if (typeof text !== 'string' || text.length === 0) return;
  output({
    ev: 'sdk',
    msg: {
      type: 'stream_event',
      event: {
        type: 'content_block_delta',
        delta: { type: 'text_delta', text },
      },
    },
  });
}

function toolUse(event, output) {
  const data = event?.data && typeof event.data === 'object' ? event.data : event;
  const id = data.id ?? data.tool_use_id ?? data.toolUseId ?? data.toolCallId ?? data.callId;
  const name = data.name ?? data.tool ?? data.toolName ?? data.command?.name ?? 'unknown_tool';
  const input = data.input ?? data.arguments ?? data.args ?? data.command ?? {};
  const toolID = String(id ?? `grok-tool-${Date.now()}`);
  if (announcedTools.has(toolID)) return toolID;
  announcedTools.add(toolID);
  output({
    ev: 'sdk',
    msg: {
      type: 'assistant',
      message: { content: [{ type: 'tool_use', id: toolID, name: String(name), input }] },
    },
  });
  return toolID;
}

function toolResult(event, output) {
  const data = event?.data && typeof event.data === 'object' ? event.data : event;
  const id = data.tool_use_id ?? data.toolUseId ?? data.toolCallId ?? data.callId ?? data.id;
  const toolID = String(id ?? 'grok-tool-unknown');
  if (!announcedTools.has(toolID)) toolUse({ ...event, data: { ...data, id: toolID } }, output);
  const content = data.content ?? data.output ?? data.result ?? data.rawOutput ?? data.data ?? '';
  output({
    ev: 'sdk',
    msg: {
      type: 'user',
      message: {
        content: [{
          type: 'tool_result',
          tool_use_id: toolID,
          content: typeof content === 'string' ? content : JSON.stringify(content),
          ...(data.is_error || data.isError || data.error ? { is_error: true } : {}),
        }],
      },
    },
  });
}

function permissionRequest(event, output) {
  const data = event?.data && typeof event.data === 'object' ? event.data : event;
  output({
    ev: 'permission_request',
    id: String(data.id ?? data.requestId ?? `grok-permission-${Date.now()}`),
    tool: String(data.tool ?? data.name ?? data.toolName ?? 'unknown_tool'),
    input: data.input ?? data.arguments ?? data.args ?? {},
    ...(data.title ? { title: String(data.title) } : {}),
    ...(data.description ? { description: String(data.description) } : {}),
  });
}

const toolUseTypes = new Set(['tool_use', 'tool-use', 'tool_call', 'tool-call', 'tool_start', 'tool-start']);
const toolResultTypes = new Set(['tool_result', 'tool-result', 'tool_response', 'tool-response', 'tool_end', 'tool-end']);
const permissionTypes = new Set(['permission_request', 'permission-request', 'request_permission', 'request-permission']);

function preparePrompt(command) {
  const text = String(command.text ?? '');
  const attachments = command.attachments ?? [];
  if (!Array.isArray(attachments)) throw new Error('附件清單格式錯誤');
  const images = [];
  const references = [];
  const imageTypes = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' };
  for (const attachment of new Set(attachments)) {
    if (typeof attachment !== 'string' || !attachment.trim()) throw new Error('附件路徑無效');
    const file = path.resolve(cwd, attachment);
    const extension = path.extname(file).toLowerCase();
    // Reject unreadable attachments before launching a turn; never silently send text instead.
    if (!fs.statSync(file).isFile()) throw new Error('附件不是一般檔案');
    fs.accessSync(file, fs.constants.R_OK);
    if (imageTypes[extension]) {
      const bytes = fs.readFileSync(file);
      if (!bytes.length) throw new Error('圖片內容為空');
      images.push({ type: 'image', data: bytes.toString('base64'), mimeType: imageTypes[extension] });
    } else if (['.heic', '.heif', '.avif', '.bmp', '.tif', '.tiff', '.svg', '.ico', '.psd'].includes(extension)) {
      throw new Error('Grok 圖片請使用 PNG、JPEG、GIF 或 WebP');
    } else {
      references.push(`附件檔案：${JSON.stringify(file)}`);
    }
  }
  const promptText = [text, ...references].filter(Boolean).join('\n');
  if (!images.length) return { args: ['-p', promptText], dispose() {} };

  // The bundled native CLI parses ACP JSON from --prompt-file. Base64 in argv
  // exceeds ARG_MAX for ordinary screenshots; keep it in one private, turn-owned file.
  const blocks = [...(promptText ? [{ type: 'text', text: promptText }] : []), ...images];
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tatwo2-grok-prompt-'));
  const file = path.join(directory, 'prompt.json');
  const dispose = () => {
    try {
      if (fs.existsSync(file)) fs.unlinkSync(file); // Only our ephemeral transport, never an attachment.
      fs.rmdirSync(directory);
    } catch {
      emit({ ev: 'stderr', line: 'Grok 附件暫存清理失敗' });
    }
  };
  try {
    fs.chmodSync(directory, 0o700);
    fs.writeFileSync(file, JSON.stringify(blocks), { flag: 'wx', mode: 0o600 });
    return { args: ['--prompt-file', file], dispose };
  } catch (error) {
    dispose();
    throw error;
  }
}

async function runTurn(command) {
  let prompt;
  try { prompt = preparePrompt(command); }
  catch {
    const message = '附件無法讀取或圖片格式不支援；請重新選擇檔案（圖片支援 PNG、JPEG、GIF、WebP）';
    emit({ ev: 'error', message, ...(command.uuid ? { client_turn_id: command.uuid } : {}) });
    sdk({ type: 'result', subtype: 'error', is_error: true, result: message, session_id: resume ?? '' });
    return;
  }
  try {
  turnCount += 1;
  const args = [...prompt.args, '--output-format', 'streaming-json', '--cwd', cwd, '--always-approve', ...(systemPrompt ? ['--rules', systemPrompt] : [])];
  if (model) args.push('-m', model);
  // 模型 attestation：這一輪真的用 -m 傳給 grok 的模型（grok 會拒絕未知 id，所以能成功就是這個）；沒指定就不冒充
  if (model) sdk({ type: 'system', subtype: 'model', model });
  if (resume) args.push('--resume', resume);
  else if (turnCount > 1) args.push('-c');

  const childEnvironment = {
    ...process.env,
    HOME: GROK_HOME,
    GROK_HOME: path.join(GROK_HOME, '.grok'),
    XDG_CONFIG_HOME: path.join(GROK_HOME, '.config'),
    XDG_CACHE_HOME: path.join(GROK_HOME, '.cache'),
  };
  for (const key of [
    'CLAUDE_CONFIG_DIR',
    'CLAUDE_HOME',
    'CLAUDE_PLUGIN_ROOT',
    'CLAUDE_PLUGIN_DATA',
    'CLAUDE_PROJECT_DIR',
    'ANTHROPIC_API_KEY',
  ]) delete childEnvironment[key];
  const child = spawn(GROK, args, {
    cwd,
    env: childEnvironment,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  active = child;

  let fullText = '';
  let endEvent = null;
  let stdoutBuffer = '';
  let stderrBuffer = '';
  const held = [];
  const output = initialized ? emit : (value) => held.push(value);

  const translate = (event) => {
    const type = typeof event?.type === 'string' ? event.type : '';
    if (type === 'text') {
      const text = typeof event.data === 'string' ? event.data : event.data?.text ?? event.text;
      if (typeof text === 'string') fullText += text;
      textDelta(text, output);
      return;
    }
    if (type === 'tool_call' || type === 'tool-call') {
      const status = event.data?.status ?? event.status;
      if (['completed', 'failed', 'error', 'cancelled'].includes(status)) toolResult(event, output);
      else toolUse(event, output);
      return;
    }
    if (toolUseTypes.has(type)) { toolUse(event, output); return; }
    if (toolResultTypes.has(type)) { toolResult(event, output); return; }
    if (permissionTypes.has(type)) { permissionRequest(event, output); return; }
    if (type === 'tool' && event.data?.status === 'completed') { toolResult(event, output); return; }
    if (type === 'tool') { toolUse(event, output); return; }
    if (type === 'end') endEvent = event;
  };

  const parseLine = (line) => {
    if (!line.trim()) return;
    try { translate(JSON.parse(line)); }
    catch { emit({ ev: 'stderr', line: `grok non-JSON stdout: ${line}` }); }
  };

  child.stdout.on('data', (chunk) => {
    stdoutBuffer += chunk.toString();
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() ?? '';
    for (const line of lines) parseLine(line);
  });
  child.stderr.on('data', (chunk) => {
    stderrBuffer += chunk.toString();
    const lines = stderrBuffer.split(/\r?\n/);
    stderrBuffer = lines.pop() ?? '';
    for (const line of lines) if (line) emit({ ev: 'stderr', line });
  });

  const exit = await new Promise((resolve) => {
    child.once('error', (error) => resolve({ code: 1, error }));
    child.once('close', (code, signal) => resolve({ code: code ?? 1, signal }));
  });
  active = null;
  if (stdoutBuffer.trim()) parseLine(stdoutBuffer);
  if (stderrBuffer.trim()) emit({ ev: 'stderr', line: stderrBuffer });

  const sessionID = endEvent?.sessionId ?? endEvent?.session_id ?? resume;
  if (sessionID) resume = String(sessionID);
  if (!initialized && sessionID) {
    initialized = true;
    sdk({ type: 'system', subtype: 'init', session_id: String(sessionID), model: model ?? null });   // 沒指定模型就不回報（'grok' 只是佔位，不是 attestation）
    for (const value of held) emit(value);
  } else if (!initialized) {
    emit({ ev: 'error', message: 'grok turn ended without a session id; init could not be emitted' });
    for (const value of held) emit(value);
  }

  const failed = Boolean(exit.error) || exit.code !== 0 || !endEvent;
  sdk({
    type: 'result',
    subtype: failed ? 'error' : 'success',
    is_error: failed,
    result: fullText,
    session_id: sessionID ? String(sessionID) : '',
  });
  if (exit.error) emit({ ev: 'error', message: String(exit.error.stack || exit.error) });
  else if (exit.code !== 0 && !closing) emit({ ev: 'error', message: `grok exited with code ${exit.code}${exit.signal ? ` (${exit.signal})` : ''}` });
  } finally {
    prompt.dispose();
  }
}

async function drain() {
  if (active || closing) return;
  const next = queue.shift();
  if (!next) return;
  try { await runTurn(next); }
  catch (error) { emit({ ev: 'error', message: String(error?.stack || error) }); }
  if (closing) emitClosedAndExit();
  else void drain();
}

function interruptActive() {
  if (!active) return;
  active.kill('SIGINT');
  const child = active;
  setTimeout(() => { if (active === child) child.kill('SIGKILL'); }, 1500).unref();
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let command;
  try { command = JSON.parse(line); }
  catch { emit({ ev: 'error', message: `bad json: ${line}` }); return; }

  switch (command.op) {
    case 'send':
      if (closing) emit({ ev: 'error', message: 'sidecar is closing' });
      else { queue.push(command); void drain(); }
      break;
    case 'interrupt':
      queue.length = 0;
      interruptActive();
      break;
    case 'model':
      if (active) emit({ ev: 'error', message: 'cannot change model during an active turn' });
      else model = command.model ? String(command.model) : undefined;
      break;
    case 'permission':
      emit({ ev: 'error', message: `unknown permission id ${command.id ?? ''}; Grok runs with --always-approve` });
      break;
    case 'close':
      closing = true;
      queue.length = 0;
      if (active) interruptActive();
      else emitClosedAndExit();
      break;
    default:
      emit({ ev: 'error', message: `unknown op ${command.op}` });
  }
});
rl.on('close', () => {
  closing = true;
  queue.length = 0;
  if (active) interruptActive();
  else emitClosedAndExit();
});

process.on('SIGTERM', () => { closing = true; interruptActive(); if (!active) emitClosedAndExit(); });
process.on('SIGINT', () => { closing = true; interruptActive(); if (!active) emitClosedAndExit(); });

// permissionMode is accepted for protocol compatibility; this room explicitly requires --always-approve.
void permissionMode;
