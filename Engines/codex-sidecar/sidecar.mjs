import os from 'node:os';
import fs from 'node:fs';
// tatwo2 Codex sidecar：把 codex app-server JSON-RPC 翻成 Engines/PROTOCOL.md 的共用事件。
// 只使用 Node 內建模組；stdin/stdout 都是一行一個 JSON。
import { spawn } from 'node:child_process';
import readline from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { acquireFirstInit, codexIdentity, writeMarker, FirstInitError } from './first-init.mjs';

const argv = process.argv.slice(2);
const flag = (name, fallback) => {
  const index = argv.indexOf(name);
  return index >= 0 ? argv[index + 1] : fallback;
};

const cwd = flag('--cwd', process.cwd());
const resumeThreadID = flag('--resume', undefined);
let selectedModel = flag('--model', undefined);
const permissionMode = flag('--permission-mode', 'default');
const systemPrompt = flag('--system-prompt', undefined);
const browserMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../browser-mcp/server.mjs');
const osMCPServer = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../os-mcp/server.mjs');
const validPermissionModes = new Set(['default', 'acceptEdits', 'bypassPermissions']);

const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const errorText = (error) => String(error?.stack || error);
const codexHome = process.env.CODEX_HOME;
if (codexHome) {
  try {
    fs.mkdirSync(codexHome, { recursive: true, mode: 0o700 });
    fs.chmodSync(codexHome, 0o700);
    const destination = path.join(codexHome, 'auth.json');
    const source = path.join(os.homedir(), '.codex', 'auth.json');
    if (destination !== source && !fs.existsSync(destination) && fs.existsSync(source)) {
      fs.copyFileSync(source, destination, fs.constants.COPYFILE_EXCL);
      fs.chmodSync(destination, 0o600);
    }
  } catch (error) {
    emit({ ev: 'stderr', line: `準備 Codex 獨立登入資料夾失敗：${errorText(error)}` });
  }
}
// 獨立資料夾第一次用：把使用者原本 Codex 家的 MCP 定義（[mcp_servers.*]）搬進獨立 config.toml，
// 不然資訊卡上的 MCP 名單在這裡不存在，-c enabled=false 會讓 app-server 直接退出（invalid transport）。
const codexSourceHome = process.env.TATWO2_CODEX_SOURCE_HOME
  || (fs.existsSync(path.join(os.homedir(), "Library/Application Support/tatwo2/CliHome/config.toml")) ? path.join(os.homedir(), "Library/Application Support/tatwo2/CliHome") : path.join(os.homedir(), '.codex'));
if (codexHome && codexHome !== codexSourceHome) {
  try {
    const dest = path.join(codexHome, 'config.toml');
    const src = path.join(codexSourceHome, 'config.toml');
    const destText = fs.existsSync(dest) ? fs.readFileSync(dest, 'utf8') : '';
    if (!/^\[mcp_servers\./m.test(destText) && fs.existsSync(src)) {
      // Node 實跑證實：JS regex 沒有 \Z（會當成字面 "Z"），最後一段 MCP 若沒有後續非 MCP 標頭就抓不到、遇到 Z 字還會截斷。
      // 加一個 sentinel 標頭在結尾，讓每一段都有明確終點。
      const srcText = fs.readFileSync(src, 'utf8') + '\n[__tatwo2_end__]\n';
      const sections = [];
      const re = /^\[mcp_servers\.[^\]]+\][\s\S]*?(?=^\[(?!mcp_servers\.))/gm;
      let m; while ((m = re.exec(srcText))) sections.push(m[0].trimEnd());
      if (sections.length) {
        // 防護（非根因）：第一次搬入改成寫暫存檔再 rename，讀者不會讀到半截檔；保留原檔權限（0600 不變 0644）。
        // 這不是鎖：兩個實例同時第一次啟動仍可能各寫一次，但內容相同、且任一時刻都是完整檔。
        const tmp = `${dest}.tmp-${process.pid}-${Date.now()}`;
        fs.writeFileSync(tmp, `${destText.trimEnd()}\n\n# 由 TATWO OS 從 ${src} 搬入的 MCP 定義\n${sections.join('\n\n')}\n`, { mode: fs.existsSync(dest) ? (fs.statSync(dest).mode & 0o777) : 0o600 });
        const latest = fs.existsSync(dest) ? fs.readFileSync(dest, 'utf8') : '';
        if (/^\[mcp_servers\./m.test(latest)) fs.unlinkSync(tmp);   // 別人已經搬好了，用他的
        else fs.renameSync(tmp, dest);
      }
    }
  } catch (error) {
    emit({ ev: 'stderr', line: `搬 MCP 定義進獨立 Codex 資料夾失敗：${errorText(error)}` });
  }
}
const isolatedConfigText = (() => { try { return codexHome ? fs.readFileSync(path.join(codexHome, 'config.toml'), 'utf8') : ''; } catch { return ''; } })();
const isolatedHasServer = (name) => new RegExp(`^\\[mcp_servers\\.${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(\\.|\\])`, 'm').test(isolatedConfigText);
const mcpConfigText = flag('--mcp-config', undefined);
let mcpConfig;
try {
  mcpConfig = mcpConfigText ? JSON.parse(mcpConfigText) : undefined;
} catch (error) {
  emit({ ev: 'error', message: `bad --mcp-config json: ${errorText(error)}` });
  process.exit(1);
}

if (!validPermissionModes.has(permissionMode)) {
  emit({ ev: 'error', message: `unknown permission mode ${permissionMode}` });
  process.exit(1);
}

const approvalPolicy = permissionMode === 'default'
  ? 'untrusted'
  : permissionMode === 'bypassPermissions'
    ? 'never'
    : 'on-request';
const sandbox = permissionMode === 'bypassPermissions' ? 'danger-full-access' : 'workspace-write';
const disabledMCPNames = new Set(mcpConfig?.engine === 'codex'
  ? (mcpConfig.configured ?? [])
      .filter((name) => !(mcpConfig.enabled ?? []).includes(name))
      .filter((name) => isolatedHasServer(name))   // 獨立 config 沒定義的不能下 enabled=false（會 invalid transport）
  : []);
const disabledMCPArgs = [...disabledMCPNames].flatMap((name) => ['-c', `mcp_servers.${name}.enabled=false`]);
// OS 內建瀏覽器橋永遠掛上；討論串沒勾的 MCP 用 -c 關掉
// 代我核准（App 傳非 default 的 permission mode）時，MCP 工具直接放行：
// Codex 0.153 把 MCP 工具核准包成表單（elicitation），而它自己解析表單 schema 會失敗（unknown field `title`），
// 走問答流程必卡死；所以改用官方設定 default_tools_approval_mode=approve 直接不問。
const autoApproveMCP = permissionMode !== 'default';
const threadMCPNames = mcpConfig?.engine === 'codex' ? (mcpConfig.enabled?.length ? mcpConfig.enabled : mcpConfig.configured ?? []) : [];
const mcpNamesForApproval = new Set(['tatwo2_browser', 'tatwo2_os', ...(threadMCPNames.length ? threadMCPNames : configuredMCPNamesFromToml())]);
const approveMCPArgs = autoApproveMCP
  ? [...mcpNamesForApproval].flatMap((name) => ['-c', `mcp_servers.${name}.default_tools_approval_mode="approve"`])
  : [];
// GitHub 帳號 MCP 是 App 依 Keychain 即時組出的 OS 內建條目。token 先換成 sidecar 子行程環境別名，
// Codex 再用 env_vars 的 source→name 映射交給各自的 github-mcp-server，避免 token 出現在 codex 的 -c argv。
const shellQuote = (v) => `'${String(v).replace(/'/g, `'\\''`)}'`;
const githubMCPArgs = [];
const githubMCPEnvironment = {};
if (mcpConfig?.engine === 'codex' && mcpConfig.servers && typeof mcpConfig.servers === 'object') {
  let index = 0;
  for (const [name, server] of Object.entries(mcpConfig.servers)) {
    if (!/^github-[A-Za-z0-9-]+$/.test(name) || !server || typeof server.command !== 'string') continue;
    const args = Array.isArray(server.args) ? server.args.map(String) : [];
    const token = (mcpConfig.enabled ?? []).includes(name) ? server.env?.GITHUB_PERSONAL_ACCESS_TOKEN : undefined;
    if (typeof token === 'string' && token.length) {
      // Codex 的 env_vars 只會「同名轉發」父行程的環境變數；兩個帳號都要 GITHUB_PERSONAL_ACCESS_TOKEN 會撞名。
      // 所以每個帳號給一個別名變數，用 /bin/sh 在啟動 github-mcp-server 前改名；token 不進 argv。
      const source = `TATWO2_GITHUB_MCP_TOKEN_${index++}`;
      githubMCPEnvironment[source] = token;
      const shell = `GITHUB_PERSONAL_ACCESS_TOKEN="$${source}" exec ${shellQuote(server.command)} ${args.map(shellQuote).join(' ')}`;
      githubMCPArgs.push(
        '-c', `mcp_servers.${name}.command="/bin/sh"`,
        '-c', `mcp_servers.${name}.args=${JSON.stringify(['-c', shell])}`,
        '-c', `mcp_servers.${name}.env_vars=${JSON.stringify([source])}`,
      );
    } else {
      githubMCPArgs.push(
        '-c', `mcp_servers.${name}.command=${JSON.stringify(server.command)}`,
        '-c', `mcp_servers.${name}.args=${JSON.stringify(args)}`,
      );
    }
  }
}
// OS 上游宣告：走 Codex 的 developer_instructions（TOML 基本字串與 JSON 字串跳脫相容）
const upstreamArgs = systemPrompt ? ['-c', `developer_instructions=${JSON.stringify(systemPrompt)}`] : [];
// ── 冷 CODEX_HOME 第一次初始化協調（v3）──────────────────────────────────────────
// 同一個家一次只讓一個 sidecar 起 app-server。拿不到協調權（活鎖逾時／鎖無 owner／發佈失敗／等待中被取消）＝fail-closed：
// 發 error、退出，不盲目起第二個。等待期間就監聽 stdin EOF／訊號取消；等待結束後同樣訊號＝正常 close。
function resolveCodexBinary() {
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    const candidate = path.join(dir, 'codex');
    try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch {}
  }
  return null;
}
const firstInitAbort = new AbortController();
let firstInitWaiting = true;
const pendingLines = [];   // 等待協調期間 App 送來的命令先排隊，app-server 起來後再處理
const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => pendingLines.push(line));
rl.on('close', () => firstInitAbort.abort());               // 等待中 EOF＝取消；等待後會換成正式 close
for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => { if (firstInitWaiting) firstInitAbort.abort(); else close(); });
const firstInitIdentity = codexIdentity(resolveCodexBinary());
let firstInit = { role: 'off', release: () => false };
try {
  firstInit = await acquireFirstInit(codexHome, firstInitIdentity, { waitMs: Number(process.env.TATWO2_FIRST_INIT_WAIT_MS || 60000), signal: firstInitAbort.signal });
} catch (error) {
  const message = error instanceof FirstInitError ? `codex 家初始化協調失敗（${error.code}）：${error.message}` : `codex 家初始化協調失敗：${error?.message || error}`;
  emit({ ev: 'error', message });
  emit({ ev: 'closed' });
  process.exit(error?.code === 'cancelled' ? 0 : 3);
}
firstInitWaiting = false;
// owner 的鎖只在 initialize 真成功、或自己的 child 已確認退出（exit）、或根本沒 child（ENOENT）時釋放；close() 不提前釋放。
const releaseFirstInit = (why) => { if (firstInit.role === 'owner') { firstInit.release(); firstInit = { role: 'released', release: () => false, why }; } };
const appServer = spawn('codex', [
  ...upstreamArgs,
  '-c', 'mcp_servers.tatwo2_browser.command="node"',
  '-c', `mcp_servers.tatwo2_browser.args=${JSON.stringify([browserMCPServer])}`,
  '-c', 'mcp_servers.tatwo2_os.command="node"',
  '-c', `mcp_servers.tatwo2_os.args=${JSON.stringify([osMCPServer])}`,
  // Bound every OS/browser tool call: if the helper dies mid-call the turn must fail visibly, not hang
  // (CU10 helper-disconnect). 120 s covers a 25 s consent sheet plus observe retries and one action.
  '-c', 'mcp_servers.tatwo2_os.tool_timeout_sec=120',
  '-c', 'mcp_servers.tatwo2_browser.tool_timeout_sec=120',
  // app-server 會濾掉子程序環境：兩個 built-in MCP 的橋位址要用 env 明確傳，才不會退回正式 App 的預設路徑（review 2026-09-06）
  ...(process.env.TATWO2_OS_SOCKET ? ['-c', `mcp_servers.tatwo2_os.env.TATWO2_OS_SOCKET=${JSON.stringify(process.env.TATWO2_OS_SOCKET)}`] : []),
  ...(process.env.TATWO2_BROWSER_SOCKET ? ['-c', `mcp_servers.tatwo2_browser.env.TATWO2_BROWSER_SOCKET=${JSON.stringify(process.env.TATWO2_BROWSER_SOCKET)}`] : []),
  ...githubMCPArgs, ...disabledMCPArgs, ...approveMCPArgs,
  // 防禦性縮窄（2026-09-06；根因未收斂）：App 層同一顆 bundled codex 上，舊做法（對 toml 裡所有 server 加 env.TATWO2_THREAD_ID）
  // 會 `invalid transport in mcp_servers.blender`，只改成不加就回合完成；但 Codex 用最小 fixture 反證「toml server 加 env」本身不會壞，
  // 我的最小重現又顯示 enabled 的 `uvx` server 會讓 initialize 無回應——哪個旗標組合觸發尚未分離。
  // 所以 thread id 只給我們自己用 -c 定義的 server（tatwo2_os／tatwo2_browser／github-*）；toml 裡的其他 MCP 拿不到 thread id，是否需要本輪未證實。
  ...(mcpConfig?.threadID ? ['tatwo2_os', 'tatwo2_browser', ...Object.keys(mcpConfig.servers ?? {}).filter((n) => /^github-[A-Za-z0-9-]+$/.test(n))]
      .flatMap((name) => ['-c', `mcp_servers.${name}.env.TATWO2_THREAD_ID=${JSON.stringify(mcpConfig.threadID)}`]) : []),
  'app-server',
], {
  cwd,
  env: { ...process.env, ...githubMCPEnvironment },
  stdio: ['pipe', 'pipe', 'pipe'],
});

let nextRequestID = 1;
const requests = new Map();
const approvals = new Map();
const sendQueue = [];
const tools = new Map();
let stdoutBuffer = '';
let initialized = false;
let threadID = resumeThreadID ?? null;
let threadModel = selectedModel;
// One in-flight turn, including its start RPC and cancellation. Keep the same
// object until both the terminal notification and start RPC have settled.
let currentTurn = null;
let lastCompletedTurnID = null;
let nativeGoal = null;
let goalKnown = false;
let goalReadPromise = null;
let goalRevision = 0;
let goalCommand = null;
let goalStopPending = false;
let pauseGoalAfterBoot = false;
let activeTurnText = '';
let activeTurnAgentText = '';
let closing = false;
let closedEmitted = false;
let appServerExited = false;

const writeJSON = (value) => {
  if (process.env.TATWO2_SIDECAR_DEBUG) process.stderr.write('>> ' + JSON.stringify(value).slice(0, 600) + '\n');
  if (!appServer.stdin.destroyed) appServer.stdin.write(`${JSON.stringify(value)}\n`);
};

const notify = (method, params = {}) => writeJSON({ method, params });

const request = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextRequestID++;
  requests.set(String(id), { method, resolve, reject });
  writeJSON({ id, method, params });
});

const sdk = (msg) => emit({ ev: 'sdk', msg: {
  ...(msg.type !== 'system' && currentTurn?.uuid ? { client_turn_id: currentTurn.uuid } : {}),
  ...msg,
} });

const emitInit = () => sdk({
  type: 'system',
  subtype: 'init',
  session_id: threadID,
  model: threadModel || 'default',
});

const emitTextDelta = (text) => {
  if (!text) return;
  activeTurnText += text;
  sdk({
    type: 'stream_event',
    event: {
      type: 'content_block_delta',
      delta: { type: 'text_delta', text },
    },
  });
};

const emitToolUse = (id, name, input) => sdk({
  type: 'assistant',
  message: {
    role: 'assistant',
    content: [{ type: 'tool_use', id, name, input }],
  },
});

const emitToolResult = (id, content, isError = false) => sdk({
  type: 'user',
  message: {
    role: 'user',
    content: [{
      type: 'tool_result',
      tool_use_id: id,
      content: content ?? '',
      ...(isError ? { is_error: true } : {}),
    }],
  },
});

const commandInput = (item) => ({ command: item.command ?? '' });
const fileInput = (item) => ({
  file_path: item.changes?.[0]?.path
    ?? item.changes?.[0]?.filePath
    ?? item.changes?.[0]?.file_path
    ?? '',
});

function startTool(item) {
  if (!item?.id || tools.has(item.id)) return;
  if (item.type === 'commandExecution') {
    tools.set(item.id, { name: 'Bash', input: commandInput(item), output: '' });
    emitToolUse(item.id, 'Bash', commandInput(item));
  } else if (item.type === 'fileChange') {
    tools.set(item.id, { name: 'Edit', input: fileInput(item), output: '' });
    emitToolUse(item.id, 'Edit', fileInput(item));
  } else if (item.type === 'mcpToolCall') {
    // MCP 工具（Blender、瀏覽器橋、gbrain…）也要有工具列，不然使用者只看到 sol 在沉默（測試 1 教訓）
    const name = `${item.server ?? 'mcp'}.${item.tool ?? 'tool'}`;
    tools.set(item.id, { name, input: item.arguments ?? {}, output: '' });
    emitToolUse(item.id, name, item.arguments ?? {});
  } else if (item.type === 'webSearch') {
    tools.set(item.id, { name: 'WebSearch', input: { query: item.query ?? '' }, output: '' });
    emitToolUse(item.id, 'WebSearch', { query: item.query ?? '' });
  } else if (item.type === 'imageView') {
    tools.set(item.id, { name: 'Read', input: { file_path: item.path ?? '' }, output: '' });
    emitToolUse(item.id, 'Read', { file_path: item.path ?? '' });
  } else if (item.type === 'dynamicToolCall' || item.type === 'collabAgentToolCall') {
    const name = item.type === 'collabAgentToolCall' ? `Agent.${item.tool ?? ''}` : (item.tool ?? 'tool');
    const input = item.type === 'collabAgentToolCall' ? { prompt: item.prompt ?? '', model: item.model ?? '' } : (item.arguments ?? {});
    tools.set(item.id, { name, input, output: '' });
    emitToolUse(item.id, name, input);
  }
}

function summarizeMCPResult(result) {
  if (result == null) return '';
  if (typeof result === 'string') return result.slice(0, 4000);
  const parts = Array.isArray(result?.content) ? result.content : (Array.isArray(result) ? result : null);
  if (parts) {
    return parts.map((c) => (c?.type === 'text' ? c.text : c?.type === 'image' ? '[圖片]' : JSON.stringify(c))).join('\n').slice(0, 4000);
  }
  return JSON.stringify(result).slice(0, 4000);
}

function completeTool(item) {
  if (!item?.id || !['commandExecution', 'fileChange', 'mcpToolCall', 'webSearch', 'imageView', 'dynamicToolCall', 'collabAgentToolCall'].includes(item.type)) return;
  startTool(item);
  const tool = tools.get(item.id);
  if (!tool || tool.completed) return;
  tool.completed = true;
  const failed = item.status === 'failed'
    || item.status === 'declined'
    || (typeof item.exitCode === 'number' && item.exitCode !== 0);
  const content = item.type === 'commandExecution'
    ? (item.aggregatedOutput ?? tool.output ?? '')
    : item.type === 'fileChange'
      ? (tool.output || JSON.stringify(item.changes ?? []))
      : item.type === 'mcpToolCall'
        ? (item.error ? `錯誤：${typeof item.error === 'string' ? item.error : JSON.stringify(item.error)}` : summarizeMCPResult(item.result))
        : item.type === 'webSearch'
          ? JSON.stringify(item.results ?? item.action ?? '')
          : (item.type === 'dynamicToolCall' ? JSON.stringify(item.contentItems ?? '') : (item.status ?? 'done'));
  emitToolResult(item.id, content, failed);
}

function approvalTitle(method) {
  return method === 'item/fileChange/requestApproval' ? '允許修改檔案？' : '允許執行指令？';
}

function handleApproval(message) {
  const params = message.params ?? {};
  const protocolID = String(message.id);
  const isFile = message.method === 'item/fileChange/requestApproval';
  const input = isFile
    ? { file_path: params.grantRoot ?? '', changes: params.changes ?? [] }
    : { command: params.command ?? '' };
  approvals.set(protocolID, { rpcID: message.id, method: message.method });
  emit({
    ev: 'permission_request',
    id: protocolID,
    tool: isFile ? 'Edit' : 'Bash',
    input,
    title: approvalTitle(message.method),
    description: params.reason ?? undefined,
  });
}

// app-server 還會發這些「要人回答」的請求；不回答會整輪卡死（2026-09-03 測試 1 抓到）。
// 代我核准模式下：權限提升＝照要求給、工具問問題＝選第一個選項、MCP 表單＝取消；其餘未知請求回錯誤讓它不要空等。
// 依表單 schema 組出「同意」的內容：布林＝true、選項＝偏好 allow/approve/yes 否則第一個、文字＝空字串。
function elicitationAcceptContent(params) {
  const schema = params.requestedSchema;
  if (!schema || typeof schema !== 'object' || !schema.properties) return {};
  const content = {};
  for (const [key, prop] of Object.entries(schema.properties)) {
    const choices = prop.enum ?? prop.oneOf?.map((o) => o.const) ?? prop.anyOf?.map((o) => o.const);
    if (Array.isArray(choices) && choices.length) {
      content[key] = choices.find((c) => /allow|approve|accept|yes|always|ok/i.test(String(c))) ?? choices[0];
    } else if (prop.type === 'boolean') content[key] = true;
    else if (prop.type === 'integer' || prop.type === 'number') content[key] = 0;
    else content[key] = '';
  }
  return content;
}

function configuredMCPNamesFromToml() {
  try {
    const home = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
    const text = fs.readFileSync(path.join(home, 'config.toml'), 'utf8');
    return [...text.matchAll(/^\[mcp_servers\.([A-Za-z0-9_-]+)\]/gm)].map((m) => m[1]);
  } catch { return []; }
}

function handleOtherServerRequest(message) {
  const { method, params = {} } = message;
  if (method === 'item/permissions/requestApproval') {
    emit({ ev: 'error', message: `sol 要求額外權限（${JSON.stringify(params.permissions ?? {})}）${params.reason ? '：' + params.reason : ''}，已依「代我核准」放行（本輪）` });
    writeJSON({ id: message.id, result: { permissions: params.permissions ?? {}, scope: 'turn' } });
    return true;
  }
  if (method === 'item/tool/requestUserInput') {
    const answers = {};
    const lines = [];
    for (const q of params.questions ?? []) {
      const pick = q.options?.[0]?.label ?? '請依你的專業判斷直接繼續，不用再問我';
      answers[q.id] = { answers: [pick] };
      lines.push(`${q.header ?? q.id}：${q.question} → ${pick}`);
    }
    emit({ ev: 'error', message: `sol 問了問題，已代答：\n${lines.join('\n')}` });
    writeJSON({ id: message.id, result: { answers } });
    return true;
  }
  if (method === 'mcpServer/elicitation/request') {
    // Codex 把「允許 MCP 工具執行嗎？」包成表單（form）送來；走 App 的權限流程（代我核准＝允許）。
    const protocolID = String(message.id);
    const server = params.serverName ?? params.server_name ?? params._meta?.serverName ?? 'MCP';
    approvals.set(protocolID, { rpcID: message.id, method, content: elicitationAcceptContent(params) });
    emit({
      ev: 'permission_request',
      id: protocolID,
      tool: 'MCP',
      input: { server, mode: params.mode ?? '', schema: params.requestedSchema ?? null },
      title: params.message ?? `允許 ${server} 執行工具？`,
      description: params.mode === 'url' ? params.url : undefined,
    });
    return true;
  }
  emit({ ev: 'error', message: `app-server 發了未支援的請求 ${method}，已回絕以免卡死` });
  writeJSON({ id: message.id, error: { code: -32601, message: `tatwo2 sidecar does not support ${method}` } });
  return true;
}

function handleNotification(message) {
  const { method, params = {} } = message;
  if (params.threadId && params.threadId !== threadID) return;
  if (method === 'thread/goal/updated' && params.threadId === threadID) {
    publishGoal(params.goal);
    return;
  }
  if (method === 'thread/goal/cleared' && params.threadId === threadID) {
    publishGoal(null);
    return;
  }
  if (method === 'thread/settings/updated' && params.threadId === threadID) {
    const settings = params.threadSettings;
    if (typeof settings?.model === 'string' && settings.model) {
      threadModel = settings.model;
      sdk({ type: 'system', subtype: 'model', model: threadModel,
        effort: settings.effort ?? null, serviceTier: settings.serviceTier ?? null });
    }
    return;
  }
  if (method === 'turn/started' && params.threadId === threadID &&
      params.turn?.id && params.turn.id !== lastCompletedTurnID &&
      (!currentTurn || currentTurn.completed)) {
    // Native Goal may start its own turn. Observe it, never synthesize a send.
    currentTurn = { id: params.turn.id, uuid: `native:${params.turn.id}`, starting: false,
      completed: false, cancelled: goalStopPending, interruptSent: false, autonomous: true };
    sdk({ type: 'system', subtype: 'native_turn_started', session_id: threadID,
      client_turn_id: currentTurn.uuid, stopping: currentTurn.cancelled });
  }
  if (method.startsWith('item/') || method.startsWith('turn/')) {
    const id = params.turnId ?? params.turn?.id;
    if (!currentTurn || currentTurn.completed || id === lastCompletedTurnID) return;
    if (id && currentTurn.id && id !== currentTurn.id) return;
  }
  if (method === 'item/agentMessage/delta') {
    emitTextDelta(params.delta ?? '');
    return;
  }
  if (method === 'item/started') {
    startTool(params.item);
    return;
  }
  if (method === 'item/commandExecution/outputDelta' || method === 'item/fileChange/outputDelta') {
    const tool = tools.get(params.itemId);
    if (tool) tool.output += params.delta ?? '';
    return;
  }
  if (method === 'item/completed') {
    if (params.item?.type === 'agentMessage') activeTurnAgentText = params.item.text ?? '';
    completeTool(params.item);
    return;
  }
  if (method === 'turn/started') {
    currentTurn.id = params.turn?.id ?? currentTurn.id;
    interruptTurn(currentTurn);
    drainSteer(currentTurn);
    return;
  }
  if (method === 'turn/completed') {
    const turn = params.turn ?? {};
    const result = activeTurnAgentText || activeTurnText;
    const cancelled = turn.status === 'interrupted' && !turn.error;
    const failed = !cancelled && (turn.status !== 'completed' || Boolean(turn.error));
    currentTurn.id = turn.id ?? currentTurn.id;
    finishTurn(currentTurn, {
      type: 'result',
      subtype: cancelled ? 'cancelled' : failed ? 'error' : 'success',
      is_error: failed,
      result,
      session_id: threadID,
    });
    return;
  }
  if (method === 'error') {
    emit({ ev: 'error', message: params.message ?? JSON.stringify(params) });
  }
}

function handleMessage(message) {
  if (message.id !== undefined && message.method) {
    const requestedTurn = message.params?.turnId;
    if (currentTurn?.cancelled
      || (requestedTurn && requestedTurn === lastCompletedTurnID)
      || (requestedTurn && currentTurn?.id && requestedTurn !== currentTurn.id)) {
      declineServerRequest(message.method, message.id);
      return;
    }
    if (message.method === 'item/commandExecution/requestApproval'
      || message.method === 'item/fileChange/requestApproval') {
      handleApproval(message);
      return;
    }
    if (handleOtherServerRequest(message)) return;
  }

  if (message.id !== undefined && !message.method) {
    const pending = requests.get(String(message.id));
    if (!pending) return;
    requests.delete(String(message.id));
    if (message.error) pending.reject(new Error(`${pending.method}: ${message.error.message ?? JSON.stringify(message.error)}`));
    else pending.resolve(message.result);
    return;
  }

  if (message.method) handleNotification(message);
}

function userInput(command) {
  const input = [];
  if (command.text) input.push({ type: 'text', text: command.text, text_elements: [] });
  for (const attachment of new Set(Array.isArray(command.attachments) ? command.attachments : [])) {
    if (typeof attachment !== 'string' || !path.isAbsolute(attachment)) continue;
    if (/\.(png|jpe?g|gif|webp|heic|heif|tiff?|bmp)$/i.test(attachment)) {
      // Native app-server UserInput, not a filename disguised as image input.
      input.push({ type: 'localImage', path: attachment });
    } else {
      input.push({ type: 'text', text: `附件檔案：${JSON.stringify(attachment)}`, text_elements: [] });
    }
  }
  return input;
}

function validGoal(goal) {
  return goal && goal.threadId === threadID && typeof goal.objective === 'string' && goal.objective.trim() &&
    typeof goal.status === 'string' && goal.status &&
    ['tokensUsed', 'timeUsedSeconds', 'createdAt', 'updatedAt'].every(key => Number.isSafeInteger(goal[key]) && goal[key] >= 0) &&
    (goal.tokenBudget == null || (Number.isSafeInteger(goal.tokenBudget) && goal.tokenBudget >= 0));
}

function publishGoal(goal, advanceRevision = true) {
  if (goal !== null && !validGoal(goal)) return false;
  nativeGoal = goal;
  goalKnown = true;
  if (advanceRevision) goalRevision += 1;
  sdk({ type: 'system', subtype: 'goal', session_id: threadID, goal });
  return true;
}

function readGoal() {
  if (!initialized) return Promise.resolve();
  if (goalReadPromise) return goalReadPromise;
  const revision = goalRevision;
  const operation = request('thread/goal/get', { threadId: threadID }).then(result => {
    if (goalRevision === revision && !publishGoal(result?.goal, false)) throw new Error('invalid native Goal snapshot');
  }).catch(error => {
    if (goalRevision === revision) {
      goalKnown = false;
      sdk({ type: 'system', subtype: 'goal_unavailable', session_id: threadID, message: errorText(error) });
    }
  });
  goalReadPromise = operation;
  void operation.finally(() => { if (goalReadPromise === operation) goalReadPromise = null; });
  return operation;
}

function goalResult(command, accepted, message) {
  sdk({ type: 'system', subtype: 'goal_result', session_id: threadID,
    request_id: command.uuid, accepted, ...(message ? { message } : {}) });
}

function drainGoalCommand() {
  const pending = goalCommand;
  if (!initialized || goalStopPending || !pending || pending.submitted) return;
  pending.submitted = true;
  const command = pending.command;
  let revision;
  const clear = command.op === 'goal_clear';
  const params = { threadId: threadID, ...(!clear ? { status: command.status,
    ...(command.objective !== undefined ? { objective: command.objective } : {}) } : {}) };
  const settings = Object.fromEntries(['model', 'effort', 'serviceTier']
    .filter(key => command[key] !== undefined).map(key => [key, command[key]]));
  pending.promise = (async () => {
    if (!clear && command.status === 'active' && Object.keys(settings).length) {
      await request('thread/settings/update', { threadId: threadID, ...settings });
    }
    if (pending.cancelled) return;
    // A query started before this mutation cannot replace its newer result.
    revision = ++goalRevision;
    pending.mutationSubmitted = true;
    return await request(clear ? 'thread/goal/clear' : 'thread/goal/set', params);
  })()
    .then(result => {
      if (pending.cancelled) return;
      if (!clear && (!validGoal(result?.goal) || result.goal.status !== command.status)) {
        throw new Error('native Goal update returned an invalid snapshot');
      }
      if (clear && typeof result?.cleared !== 'boolean') throw new Error('native Goal clear returned an invalid result');
      if (goalRevision === revision) publishGoal(clear ? null : result.goal);
      goalResult(command, true);
    })
    .catch(error => { if (!pending.cancelled) goalResult(command, false, errorText(error)); })
    .finally(() => { if (goalCommand === pending) goalCommand = null; });
}

function turnParams(command) {
  return {
    threadId: threadID,
    input: userInput(command),
    cwd,
    approvalPolicy,
    sandboxPolicy: null,
    model: command.model ?? selectedModel ?? null,
    ...(command.effort != null ? { effort: command.effort } : {}),
    ...(command.serviceTier != null ? { serviceTier: command.serviceTier } : {}),
    clientUserMessageId: command.uuid ?? null,
  };
}

function finishSteer(turn, accepted, message, unknown = false) {
  const pending = turn.steer;
  if (!pending) return;
  turn.steer = null;
  sdk({ type: 'system', subtype: 'steer_result', request_id: pending.command.uuid,
    target_turn_id: turn.uuid, accepted, unknown, ...(message ? { message } : {}) });
}

function drainSteer(turn) {
  const pending = turn.steer;
  if (!pending || pending.submitted || !turn.id) return;
  if (turn.cancelled || turn.completed) {
    finishSteer(turn, false, '原回合已停止或結束，插話未送出');
    return;
  }
  pending.submitted = true;
  request('turn/steer', { threadId: threadID, expectedTurnId: turn.id,
    clientUserMessageId: pending.command.uuid, input: userInput(pending.command) })
    .then(result => {
      if (result?.turnId !== turn.id) {
        finishSteer(turn, false, '引擎回報了不同回合，請先確認插話是否送達', true);
      } else {
        finishSteer(turn, true);
      }
    })
    .catch(error => finishSteer(turn, false, errorText(error)));
}

function drainSendQueue() {
  if (!initialized || !threadID || currentTurn || sendQueue.length === 0 || closing) return;
  const command = sendQueue.shift();
  const turn = { id: null, uuid: command.uuid, starting: true, completed: false,
    cancelled: false, interruptSent: false };
  currentTurn = turn;
  if (command.model && command.model !== threadModel) {
    threadModel = null;
    sdk({ type: 'system', subtype: 'model', model: null });
  }
  request('turn/start', turnParams(command))
    .then((result) => {
      turn.starting = false;
      if (turn.completed) { releaseTurn(turn); return; }
      const id = result?.turn?.id ?? turn.id;
      if (!id || (turn.id && turn.id !== id)) throw new Error('turn/start returned a missing or mismatched turn id');
      turn.id = id;
      interruptTurn(turn);
      drainSteer(turn);
    })
    .catch((error) => {
      turn.starting = false;
      if (!turn.completed) finishTurn(turn, { type: 'result', subtype: 'error', is_error: true,
        result: errorText(error), session_id: threadID });
      else releaseTurn(turn);
    });
}

function releaseTurn(turn) {
  if (currentTurn !== turn || !turn.completed || turn.starting) return;
  currentTurn = null;
  drainSendQueue();
}

function finishTurn(turn, message) {
  if (currentTurn !== turn || turn.completed) return;
  if (turn.steer && !turn.steer.submitted) finishSteer(turn, false, '原回合已結束，插話未送出');
  sdk(message);
  turn.completed = true;
  lastCompletedTurnID = turn.id;
  activeTurnText = '';
  activeTurnAgentText = '';
  tools.clear();
  approvals.clear();
  releaseTurn(turn);
}

function declineServerRequest(method, id) {
  if (method === 'mcpServer/elicitation/request') {
    writeJSON({ id, result: { action: 'cancel', content: null } });
  } else if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') {
    writeJSON({ id, result: { decision: 'decline' } });
  } else if (method === 'item/permissions/requestApproval') {
    writeJSON({ id, result: { permissions: {}, scope: 'turn' } });
  } else {
    writeJSON({ id, error: { code: -32800, message: 'turn cancelled' } });
  }
}

function interruptTurn(turn, explicitRetry = false) {
  if (!turn || !turn.cancelled || !turn.id || turn.completed || turn.interruptSent || (goalStopPending && !explicitRetry)) return;
  turn.interruptSent = true;
  request('turn/interrupt', { threadId: threadID, turnId: turn.id }).catch(error => {
    // No retry loop and no false terminal result. An explicit subsequent stop
    // may retry a rejected interrupt while this same native turn is still live.
    turn.interruptSent = false;
    emit({ ev: 'error', message: errorText(error), client_turn_id: turn.uuid, terminal: false });
  });
}

async function boot() {
  await request('initialize', {
    clientInfo: {
      name: 'tatwo2-codex-sidecar',
      title: 'Tatwo2 Codex Sidecar',
      version: '1.0.0',
    },
    capabilities: {
      experimentalApi: true,
      requestAttestation: false,
      optOutNotificationMethods: [],
    },
  });
  notify('initialized', {});
  if (firstInit.role === 'owner') {
    try {
      writeMarker(codexHome, firstInitIdentity);
    } catch (error) {
      // fail-closed：不開 thread、不送 turn；鎖等 child 退出確認後由 exit handler 釋放；錯誤原文往上
      throw new Error(`codex 家初始化標記寫入失敗（${error?.code || 'marker'}）：${error?.message || error}`);
    }
    releaseFirstInit('initialized');
  }

  const params = {
    cwd,
    approvalPolicy,
    sandbox,
    model: selectedModel ?? null,
    modelProvider: null,
  };
  const result = resumeThreadID
    ? await request('thread/resume', { ...params, threadId: resumeThreadID })
    : await request('thread/start', params);
  threadID = result?.thread?.id ?? resumeThreadID;
  threadModel = result?.model ?? result?.thread?.model ?? 'default';
  if (!threadID) throw new Error('app-server did not return a thread id');
  initialized = true;
  emitInit();
  void readGoal();
  if (pauseGoalAfterBoot) {
    pauseGoalAfterBoot = false;
    goalStopPending = false;
    await handleCommand({ op: 'interrupt', pauseGoal: true, keepLaterSends: true });
  }
  drainGoalCommand();
  drainSendQueue();
}

function replyPermission(command) {
  const pending = approvals.get(String(command.id));
  if (!pending) {
    emit({ ev: 'stderr', line: `忽略已結束或未知的權限回覆 ${command.id}` });
    return;
  }
  approvals.delete(String(command.id));
  if (pending.cancelled) return;
  if (pending.method === 'mcpServer/elicitation/request') {
    writeJSON({ id: pending.rpcID, result: command.allow
      ? { action: 'accept', content: pending.content ?? {} }
      : { action: 'decline', content: null } });
    return;
  }
  const decision = command.allow ? 'accept' : 'decline';
  writeJSON({ id: pending.rpcID, result: { decision } });
}

async function handleCommand(command) {
  switch (command.op) {
    case 'goal_set':
    case 'goal_clear': {
      if (goalCommand || typeof command.uuid !== 'string' || !command.uuid ||
          ['model', 'effort', 'serviceTier'].some(key =>
            command[key] !== undefined && (typeof command[key] !== 'string' || !command[key].trim())) ||
          (command.op === 'goal_set' && (!['active', 'paused'].includes(command.status) ||
            (command.objective !== undefined && (typeof command.objective !== 'string' || !command.objective.trim()))))) {
        goalResult(command, false, '目標操作尚未完成或參數無效');
        break;
      }
      goalCommand = { command, submitted: false };
      drainGoalCommand();
      break;
    }
    case 'goal_get':
      if (initialized) void readGoal();
      break;
    case 'steer': {
      const turn = currentTurn;
      if (!turn || turn.completed || turn.cancelled || turn.steer ||
          command.targetTurnUUID !== turn.uuid || typeof command.uuid !== 'string' ||
          !command.uuid || userInput(command).length === 0) {
        sdk({ type: 'system', subtype: 'steer_result', request_id: command.uuid,
          target_turn_id: command.targetTurnUUID, accepted: false, unknown: false,
          message: '目前回合無法接收這次插話，內容未送出' });
        break;
      }
      turn.steer = { command, submitted: false };
      drainSteer(turn);
      break;
    }
    case 'send':
      if (['model', 'effort', 'serviceTier'].some(key =>
        command[key] != null && (typeof command[key] !== 'string' || !command[key].trim()))) {
        emit({ ev: 'error', message: 'turn model, effort and serviceTier must be non-empty strings' });
        break;
      }
      sendQueue.push({ ...command, model: command.model ?? selectedModel });
      drainSendQueue();
      break;
    case 'permission':
      replyPermission(command);
      break;
    case 'interrupt': {
      for (const discarded of command.keepLaterSends === true ? [] : sendQueue.splice(0)) {
        sdk({ type: 'result', subtype: 'cancelled', is_error: false, result: '',
          session_id: threadID, client_turn_id: discarded.uuid });
      }
      const turn = currentTurn;
      if (command.keepLaterSends !== true && goalCommand?.command.status === 'active' && !goalCommand.mutationSubmitted) {
        goalCommand.cancelled = true;
        goalResult(goalCommand.command, false, '工作已要求停止，目標未啟動');
        goalCommand = null;
      }
      if (turn) {
        turn.cancelled = true;
        if (turn.steer && !turn.steer.submitted) {
          finishSteer(turn, false, '工作已要求停止，插話未送出');
        }
        for (const pending of approvals.values()) {
          if (pending.cancelled) continue;
          declineServerRequest(pending.method, pending.rpcID);
          pending.cancelled = true;
        }
      }
      if (!initialized) {
        if (command.pauseGoal !== false) {
          pauseGoalAfterBoot = true;
          goalStopPending = true;
        }
        break;
      }
        // Pausing a Goal prevents future native continuations; interrupting
        // only stops one turn. Do not claim either action from the other.
        const checkGoal = command.pauseGoal !== false && (command.pauseGoal === true ||
          !goalKnown || nativeGoal?.status === 'active' || turn?.autonomous || goalCommand?.command.status === 'active');
        if (checkGoal && !goalStopPending) {
          goalStopPending = true;
          try {
            if (goalCommand?.promise) await goalCommand.promise;
            if (!goalKnown || (turn?.autonomous && nativeGoal === null)) await (goalReadPromise ?? readGoal());
            if (nativeGoal?.status === 'active') {
              const revision = goalRevision;
              const result = await request('thread/goal/set', { threadId: threadID, status: 'paused' });
              if (!validGoal(result?.goal) || result.goal.status !== 'paused') throw new Error('native Goal pause was not confirmed');
              if (goalRevision === revision) publishGoal(result.goal);
            }
          } catch (error) {
            sdk({ type: 'system', subtype: 'goal_unavailable', session_id: threadID,
              message: `目標暫停失敗：${errorText(error)}` });
          } finally {
            goalStopPending = false;
            interruptTurn(turn);
            if (currentTurn?.autonomous) interruptTurn(currentTurn);
            drainGoalCommand();
          }
        } else if (goalStopPending && command.keepLaterSends !== true) {
          // An explicit second Stop must still stop the current turn when
          // Goal get/pause is slow. Do not pretend the Goal itself is paused.
          interruptTurn(turn, true);
        } else if (!goalStopPending) {
          interruptTurn(turn);
        }
      break;
    }
    case 'model':
      if (typeof command.model !== 'string' || !command.model.trim()) {
        emit({ ev: 'error', message: 'model must be a non-empty string' });
      } else if (currentTurn) {
        emit({ ev: 'error', message: 'cannot change model during an active turn' });
      } else {
        selectedModel = command.model;
        threadModel = command.model;
      }
      break;
    case 'mcp_status':
      emit({
        ev: 'mcp_status',
        servers: (mcpConfig?.configured ?? []).map((name) => ({
          name,
          status: (mcpConfig?.enabled ?? []).includes(name) ? 'configured' : 'disabled',
        })),
      });
      break;
    case 'close':
      close();
      break;
    default:
      emit({ ev: 'error', message: `unknown op ${command.op}` });
  }
}

function finishClosed() {
  if (closedEmitted) return;
  closedEmitted = true;
  emit({ ev: 'closed' });
}

function close() {
  if (closing) return;
  closing = true;
  if (!appServer.stdin.destroyed) appServer.stdin.end();
  const killTimer = setTimeout(() => {
    if (!appServerExited) appServer.kill('SIGTERM');
  }, 500);
  killTimer.unref();
  const exitTimer = setTimeout(() => {
    if (firstInit.role === 'owner') emit({ ev: 'error', message: `codex app-server 未在時限內確認退出，初始化鎖保留待人工回復：${path.join(codexHome || '', '.tatwo2-first-init.lock')}` });   // fail-closed：不為了不留鎖而提早解鎖
    finishClosed();
    process.exit(0);
  }, 2000);
  exitTimer.unref();
}

rl.removeAllListeners('line'); rl.removeAllListeners('close');
const handleLine = (line) => {
  let command;
  try {
    command = JSON.parse(line);
  } catch {
    emit({ ev: 'error', message: `bad json: ${line}` });
    return;
  }
  Promise.resolve(handleCommand(command)).catch((error) => emit({ ev: 'error', message: errorText(error) }));
};
rl.on('line', handleLine);
rl.on('close', close);
for (const line of pendingLines.splice(0)) handleLine(line);

appServer.stdout.setEncoding('utf8');
appServer.stdout.on('data', (chunk) => {
  stdoutBuffer += chunk;
  let newline;
  while ((newline = stdoutBuffer.indexOf('\n')) >= 0) {
    const line = stdoutBuffer.slice(0, newline).trim();
    stdoutBuffer = stdoutBuffer.slice(newline + 1);
    if (!line) continue;
    try {
      handleMessage(JSON.parse(line));
    } catch (error) {
      emit({ ev: 'error', message: `bad app-server json: ${errorText(error)}` });
    }
  }
});
appServer.stderr.setEncoding('utf8');
const lastStderr = [];
appServer.stderr.on('data', (chunk) => {
  for (const line of chunk.split(/\r?\n/)) if (line) {
    lastStderr.push(line); if (lastStderr.length > 4) lastStderr.shift();
    // MCP 遠端連線失敗（rmcp）與 app-server 的 WARN/INFO 追蹤是雜訊，不進對話畫面；只轉真正的 ERROR
    if (/rmcp::transport|app_server\.request|\bWARN\b|\bINFO\b|\bDEBUG\b/.test(line)) continue;
    emit({ ev: 'stderr', line });
  }
});
appServer.on('error', (error) => {
  const message = error?.code === 'ENOENT'
    ? `找不到 codex：PATH=${process.env.PATH ?? ''}`
    : `failed to start codex app-server: ${errorText(error)}`;
  process.stderr.write(`${message}\n`);
  emit({ ev: 'error', message });
  if (error?.code === 'ENOENT') {
    // 沒有 child 在跑：安全釋放自己的鎖，並自行 fail-closed 退出（不等別人來殺）
    releaseFirstInit('spawn-enoent');
    finishClosed();
    process.stdout.write('', () => process.exit(4));
  }
});
appServer.on('exit', (code, signal) => {
  appServerExited = true;
  releaseFirstInit('child-exited');   // child 已確認退出才釋放
  if (!closing && code !== 0) emit({ ev: 'error', message: `codex app-server exited code=${code} signal=${signal}` + (lastStderr.length ? `\n${lastStderr.join('\n')}` : '') });
  finishClosed();
  process.exit(closing || code === 0 ? 0 : 1);
});

boot().catch((error) => {
  emit({ ev: 'error', message: errorText(error) });
  close();
});
