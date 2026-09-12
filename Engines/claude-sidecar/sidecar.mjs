// tatwo2 Claude sidecar：一個常駐 Agent SDK session。
// stdin 每行一個 JSON 指令，stdout 每行一個 JSON 事件。SDK 訊息原樣轉發（ev:"sdk"），不重造。
//   in : {op:"send", text, uuid?} | {op:"permission", id, allow, message?} | {op:"interrupt"} | {op:"model", model} | {op:"close"}
//   out: {ev:"sdk", msg} | {ev:"permission_request", id, tool, input, title?, description?} | {ev:"error", message} | {ev:"closed"}
import { query } from '@anthropic-ai/claude-agent-sdk';
import readline from 'node:readline';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const cwd = flag('--cwd', process.cwd());
const resume = flag('--resume', undefined);
const model = flag('--model', undefined);
const permissionMode = flag('--permission-mode', 'default');
const systemPrompt = flag('--system-prompt', undefined);
const browserMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../browser-mcp/server.mjs');
const osMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../os-mcp/server.mjs');
const mcpConfigText = flag('--mcp-config', undefined);
let mcpConfig;
try {
  mcpConfig = mcpConfigText ? JSON.parse(mcpConfigText) : undefined;
} catch (error) {
  process.stdout.write(JSON.stringify({ ev: 'error', message: `bad --mcp-config json: ${String(error)}` }) + '\n');
  process.exit(1);
}

const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const validPermissionModes = new Set(['default', 'acceptEdits', 'bypassPermissions', 'readOnly']);
if (!validPermissionModes.has(permissionMode)) {
  emit({ ev: 'error', message: `unknown permission mode ${permissionMode}` });
  process.exit(1);
}
const readOnly = permissionMode === 'readOnly';
const readOnlyTools = ['Read', 'Grep', 'Glob'];

const inbox = [];
let wake = null;
let closed = false;
async function* prompts() {
  for (;;) {
    if (inbox.length) { const m = inbox.shift(); if (m === null) return; yield m; continue; }
    if (closed) return;
    await new Promise((r) => { wake = r; });
  }
}
const push = (m) => { inbox.push(m); const w = wake; wake = null; w?.(); };

const pending = new Map();
const canUseTool = readOnly ? async (tool, input) => (
  readOnlyTools.includes(tool)
    ? { behavior: 'allow', updatedInput: input }
    : { behavior: 'deny', message: '唯讀工作只允許 Read、Grep、Glob；不能提升權限。' }
) : (tool, input, o) => new Promise((resolve) => {
  pending.set(o.requestId, { resolve, input });
  emit({ ev: 'permission_request', id: o.requestId, tool, input, title: o.title, description: o.description, toolUseID: o.toolUseID, suggestions: o.suggestions });
  o.signal.addEventListener('abort', () => { if (pending.delete(o.requestId)) resolve({ behavior: 'deny', message: 'aborted' }); });
});

const q = query({
  prompt: prompts(),
  options: {
    cwd, resume, model, permissionMode: readOnly ? 'dontAsk' : permissionMode,
    includePartialMessages: true,
    settingSources: readOnly ? [] : ['user', 'project'],
    canUseTool,
    // Normal sessions retain selected MCPs and built-in bridges; read-only never mounts them.
    mcpServers: readOnly ? {} : Object.fromEntries(Object.entries({ ...(mcpConfig?.servers ?? {}), tatwo2_browser: { command: 'node', args: [browserMCPServer], env: { ...(process.env.TATWO2_BROWSER_SOCKET ? { TATWO2_BROWSER_SOCKET: process.env.TATWO2_BROWSER_SOCKET } : {}) } }, tatwo2_os: { command: 'node', args: [osMCPServer], env: { ...(process.env.TATWO2_OS_SOCKET ? { TATWO2_OS_SOCKET: process.env.TATWO2_OS_SOCKET } : {}) } } }).map(([name, server]) => [name, { ...server, ...(mcpConfig?.threadID ? { env: { ...server.env, TATWO2_THREAD_ID: mcpConfig.threadID } } : {}) }])),
    ...(mcpConfig?.servers || readOnly ? { strictMcpConfig: true } : {}),
    // Apply on new and resumed queries alike. `allowedTools` only auto-approves;
    // `tools` is the native built-in tool surface restriction.
    ...(readOnly ? {
      tools: readOnlyTools,
      hooks: {},
      plugins: [],
      skills: [],
      agents: {},
      settings: {
        disableAllHooks: true,
        disableBundledSkills: true,
        disableSkillShellExecution: true,
        disableClaudeAiConnectors: true,
      },
    } : {}),
    ...(systemPrompt ? { systemPrompt: { type: 'preset', preset: 'claude_code', append: systemPrompt } } : {}),
    stderr: (line) => emit({ ev: 'stderr', line }),
  },
});

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let cmd; try { cmd = JSON.parse(line); } catch { return emit({ ev: 'error', message: 'bad json: ' + line }); }
  try {
    switch (cmd.op) {
      case 'send': {
        const atts = Array.isArray(cmd.attachments) ? cmd.attachments : [];
        if (atts.length === 0) {
          push({ type: 'user', message: { role: 'user', content: cmd.text }, parent_tool_use_id: null, uuid: cmd.uuid });
          break;
        }
        const blocks = [];
        const notes = [];
        for (const p of atts) {
          const ext = path.extname(p).toLowerCase();
          const mime = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' }[ext];
          try {
            if (mime) {
              blocks.push({ type: 'image', source: { type: 'base64', media_type: mime, data: fs.readFileSync(p).toString('base64') } });
            } else {
              notes.push(`附件檔案：${p}`);
            }
          } catch (e) { notes.push(`附件讀取失敗：${p}`); }
        }
        const text = [cmd.text, ...notes].filter(Boolean).join('\n');
        if (text) blocks.push({ type: 'text', text });
        push({ type: 'user', message: { role: 'user', content: blocks }, parent_tool_use_id: null, uuid: cmd.uuid });
        break;
      }
      case 'permission': {
        const p = pending.get(cmd.id); if (!p) return emit({ ev: 'error', message: 'unknown permission id ' + cmd.id });
        pending.delete(cmd.id);
        p.resolve(cmd.allow ? { behavior: 'allow', updatedInput: cmd.updatedInput ?? p.input } : { behavior: 'deny', message: cmd.message ?? '使用者拒絕' });
        break;
      }
      case 'interrupt': await q.interrupt(); break;
      case 'model': await q.setModel(cmd.model); break;
      case 'mcp_status': {
        const servers = await q.mcpServerStatus();
        emit({ ev: 'mcp_status', servers });
        break;
      }
      case 'close': closed = true; push(null); break;
      default: emit({ ev: 'error', message: 'unknown op ' + cmd.op });
    }
  } catch (e) { emit({ ev: 'error', message: String(e?.stack || e) }); }
});
rl.on('close', () => { closed = true; push(null); });

(async () => {
  for await (const msg of q) emit({ ev: 'sdk', msg });
  emit({ ev: 'closed' });
  process.exit(0);
})().catch((e) => { emit({ ev: 'error', message: String(e?.stack || e) }); process.exit(1); });
