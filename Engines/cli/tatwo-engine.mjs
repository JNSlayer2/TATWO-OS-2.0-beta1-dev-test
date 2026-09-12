#!/usr/bin/env node
// TATWO OS headless 引擎入口。
//
// 用途：在沒有開 App 的情況下，把一則請求送給 OS 自己的引擎 sidecar（codex／claude／grok），
// 拿到最終文字後結束。App 的派工要 os.sock（App 開著才有）；這支不需要 App，
// 給 CLI session、codex exec、排程用。
//
// 它不是新的引擎接線，只是 Engines/PROTOCOL.md 的一個 headless 客戶端：
// spawn sidecar → {op:"send"} → 收 sdk 事件 → 等 msg.type=="result" → {op:"close"}。
//
// 取代 codex-claude-bridge 的單向（Codex→Claude）通道，三家都能當被問的一方。
//
// 用法：
//   tatwo-engine ask      --engine claude --cwd DIR [--model M] "問題"
//   tatwo-engine review   --engine codex  --cwd DIR [--model M] "審查請求"
//   tatwo-engine delegate --engine grok   --cwd DIR --yes        "任務"
//   tatwo-engine doctor
//
// 模式：
//   ask / review  要求引擎唯讀。**只有 sidecar 原生支援唯讀的引擎才放行**，
//                 否則 fail-closed 拒絕啟動（除非明確帶 --unsafe-no-readonly）。
//   delegate      允許寫入；必須加 --yes。
//
// 為什麼要 fail-closed（2026-09-09 實測）：一開始只靠攔截 permission_request 決定，
// 結果真 claude 在 default 模式下根本不問就把檔案寫出來了——攔截層是 fail-open 的。
// 現在改成優先用 sidecar 自己的唯讀模式（原生限制工具面），攔截層只當第二層。
//   claude  --permission-mode readOnly：tools 限縮成 Read/Grep/Glob、不掛 MCP、canUseTool 直接 deny。可強制。
//   codex   sidecar 只有 workspace-write / danger-full-access 兩檔，沒有唯讀。無法強制。
//   grok    每輪帶 --always-approve。無法強制。
//
// exit code 沿用 codex-claude-bridge 的慣例，稽核紀錄才能接得起來：
//   0 成功｜1 引擎回報錯誤或啟動失敗｜2 參數錯誤｜124 逾時

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import readline from "node:readline";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const ENGINES = ["codex", "claude", "grok"];
const MODES = ["ask", "review", "delegate"];

// 哪些引擎的 sidecar 能「原生強制」唯讀。依 Engines/<e>-sidecar/sidecar.mjs 的實作認定，
// 不是靠猜：claude 有 permissionMode==="readOnly" 分支（限制 tools＋canUseTool deny＋不掛 MCP）。
const READ_ONLY_ENFORCEABLE = new Set(["claude"]);

// 唯讀工具白名單。名稱對齊 Claude Agent SDK；Codex／Grok 的 sidecar 已把事件翻成同一形狀。
const READ_ONLY_TOOLS = new Set([
  "Read", "Glob", "Grep", "NotebookRead", "WebFetch", "WebSearch", "TodoWrite",
]);
const MUTATING_TOOLS = new Set(["Edit", "Write", "NotebookEdit", "MultiEdit"]);
// review 模式允許的 Bash 前綴（唯讀查詢）。比對用 argv 的第一個詞。
const READ_ONLY_BASH = new Set([
  "git", "rg", "ls", "find", "cat", "sed", "nl", "wc", "test", "head", "tail",
  "grep", "awk", "stat", "file", "du", "diff", "shasum", "date", "pwd", "which",
]);

const REPO_ROOT = path.resolve(__dirname, "..", "..");

// sidecar 要跟它的 node_modules 待在一起（claude sidecar 需要 Agent SDK）。
// 順序照 App 的 ClaudeSidecar.scriptPath：先看明示的 root，再看已安裝的 App Resources，最後才用 repo。
// repo 的 Engines/ 沒有 node_modules，只能拿來跑不需要相依套件的引擎與測試。
const SIDECAR_ROOT_CANDIDATES = [
  process.env.TATWO_ENGINE_SIDECAR_ROOT,
  process.env.TATWO2_RESOURCES_ROOT,
  path.join(os.homedir(), "Desktop", "TATWO OS.app", "Contents", "Resources"),
  "/Applications/tatwo2.app/Contents/Resources",
  "/Applications/TATWO OS.app/Contents/Resources",
  path.join(REPO_ROOT, "Engines"),
].filter(Boolean);

function resolveSidecarRoot(engine) {
  for (const root of SIDECAR_ROOT_CANDIDATES) {
    const script = path.join(root, `${engine}-sidecar`, "sidecar.mjs");
    if (fs.existsSync(script)) return { root, script };
  }
  return { root: null, script: null };
}

const DEFAULT_LOG = process.env.TATWO_ENGINE_CLI_LOG
  || path.join(os.homedir(), ".tatwo2", "log", "engine-cli.jsonl");

function usage(message) {
  if (message) process.stderr.write(`tatwo-engine: ${message}\n\n`);
  process.stderr.write(
    "用法：\n" +
    "  tatwo-engine <ask|review|delegate> --engine <codex|claude|grok> --cwd <dir> [選項] \"請求\"\n" +
    "  tatwo-engine doctor\n\n" +
    "選項：\n" +
    "  --engine <name>      codex | claude | grok（必填）\n" +
    "  --cwd <dir>          引擎的工作目錄（必填，必須已存在）\n" +
    "  --model <id>         指定模型；省略用該引擎預設\n" +
    "  --timeout <sec>      預設 1800\n" +
    "  --yes                delegate 模式必須明確帶上，才允許寫入類工具\n" +
    "  --unsafe-no-readonly ask/review 用在無法強制唯讀的引擎（codex／grok）時必須明確帶上；\n" +
    "                       這代表引擎可能真的寫入檔案，會記進稽核紀錄\n" +
    "  --json               輸出整包 JSON 而不是純文字\n" +
    "  --log <path>         稽核紀錄位置（預設 ~/.tatwo2/log/engine-cli.jsonl）\n",
  );
  process.exit(2);
}

function parseArgs(argv) {
  const mode = argv[0];
  if (mode === "doctor") return { mode: "doctor" };
  if (!MODES.includes(mode)) usage(`未知模式 ${mode ?? "(空)"}`);
  const opts = { mode, timeoutSec: 1800, log: DEFAULT_LOG, json: false, yes: false, unsafeNoReadOnly: false };
  const rest = [];
  for (let i = 1; i < argv.length; i += 1) {
    const a = argv[i];
    const need = (name) => {
      const v = argv[i + 1];
      if (v === undefined || v.startsWith("--")) usage(`${name} 缺少值`);
      i += 1;
      return v;
    };
    if (a === "--engine") opts.engine = need("--engine");
    else if (a === "--cwd") opts.cwd = need("--cwd");
    else if (a === "--model") opts.model = need("--model");
    else if (a === "--timeout") opts.timeoutSec = Number(need("--timeout"));
    else if (a === "--log") opts.log = need("--log");
    else if (a === "--yes") opts.yes = true;
    else if (a === "--unsafe-no-readonly") opts.unsafeNoReadOnly = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--") rest.push(...argv.slice(i + 1)), (i = argv.length);
    else if (a.startsWith("--")) usage(`未知選項 ${a}`);
    else rest.push(a);
  }
  opts.prompt = rest.join(" ").trim();
  if (!ENGINES.includes(opts.engine)) usage(`--engine 必須是 ${ENGINES.join(" / ")}`);
  if (!opts.cwd) usage("--cwd 必填");
  if (!opts.prompt) usage("請求內容不能是空的");
  if (!Number.isFinite(opts.timeoutSec) || opts.timeoutSec <= 0) usage("--timeout 必須是正數");
  opts.cwd = path.resolve(opts.cwd);
  if (!fs.existsSync(opts.cwd) || !fs.statSync(opts.cwd).isDirectory()) usage(`--cwd 不存在或不是目錄：${opts.cwd}`);
  if (opts.mode === "delegate" && !opts.yes) {
    usage("delegate 會讓引擎寫入檔案，必須明確加 --yes");
  }
  if (opts.mode !== "delegate" && !READ_ONLY_ENFORCEABLE.has(opts.engine) && !opts.unsafeNoReadOnly) {
    usage(
      `${opts.engine} 的 sidecar 沒有可強制的唯讀模式，${opts.mode} 無法保證它不寫入檔案。\n` +
      "  接受這個風險就加 --unsafe-no-readonly（會記進稽核紀錄），或改用 --engine claude。",
    );
  }
  return opts;
}

function sidecarPath(engine) {
  return resolveSidecarRoot(engine).script
    ?? path.join(REPO_ROOT, "Engines", `${engine}-sidecar`, "sidecar.mjs");
}

function doctor() {
  const rows = ENGINES.map((engine) => {
    const { root, script } = resolveSidecarRoot(engine);
    const resolved = script ?? path.join(REPO_ROOT, "Engines", `${engine}-sidecar`, "sidecar.mjs");
    const deps = root ? path.join(root, `${engine}-sidecar`, "node_modules") : null;
    return {
      engine,
      script: resolved,
      exists: Boolean(script),
      // claude sidecar 需要 Agent SDK；沒有 node_modules 的 root 只能跑不吃套件的引擎。
      has_node_modules: deps ? fs.existsSync(deps) : false,
    };
  });
  const logDir = path.dirname(DEFAULT_LOG);
  const report = {
    repo_root: REPO_ROOT,
    node: process.version,
    log: DEFAULT_LOG,
    log_writable: (() => {
      try {
        fs.mkdirSync(logDir, { recursive: true });
        fs.accessSync(logDir, fs.constants.W_OK);
        return true;
      } catch { return false; }
    })(),
    sidecar_root_candidates: SIDECAR_ROOT_CANDIDATES,
    sidecars: rows,
    ok: rows.every((r) => r.exists),
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  process.exit(report.ok ? 0 : 1);
}

// review 模式：只放行唯讀。無法判定的一律拒絕（fail-closed）。
function permissionDecision(mode, tool, input) {
  if (mode === "delegate") return { allow: true, why: "delegate" };
  if (mode === "ask") return { allow: false, why: "ask 模式不使用工具" };
  if (MUTATING_TOOLS.has(tool)) return { allow: false, why: `review 模式禁止 ${tool}` };
  if (READ_ONLY_TOOLS.has(tool)) return { allow: true, why: "唯讀工具" };
  if (tool === "Bash") {
    const command = String(input?.command ?? "").trim();
    const head = command.split(/\s+/)[0] ?? "";
    const base = path.basename(head);
    if (!READ_ONLY_BASH.has(base)) return { allow: false, why: `review 模式不放行的指令：${base || "(空)"}` };
    // 就算是白名單指令，帶了改寫語意就擋掉。
    if (/[>|]|&&|\brm\b|\bmv\b|\bcp\b|--write|--fix|-i\b/.test(command)) {
      return { allow: false, why: "指令含改寫或轉向語意" };
    }
    return { allow: true, why: `唯讀指令 ${base}` };
  }
  return { allow: false, why: `未知工具 ${tool}，fail-closed` };
}

function appendLog(logPath, record) {
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, `${JSON.stringify(record)}\n`);
  } catch (error) {
    process.stderr.write(`tatwo-engine: 稽核紀錄寫入失敗（不影響結果）：${error.message}\n`);
  }
}

async function run(opts) {
  const script = sidecarPath(opts.engine);
  if (!fs.existsSync(script)) {
    process.stderr.write(`tatwo-engine: 找不到 sidecar：${script}\n`);
    return { exitStatus: 1, text: "", error: "sidecar_missing" };
  }
  const args = [script, "--cwd", opts.cwd];
  if (opts.model) args.push("--model", opts.model);
  if (opts.mode === "delegate") {
    args.push("--permission-mode", "bypassPermissions");
  } else if (READ_ONLY_ENFORCEABLE.has(opts.engine)) {
    // 第一層也是真正有效的一層：sidecar 原生唯讀。
    args.push("--permission-mode", "readOnly");
  }

  const child = spawn(process.execPath, args, {
    cwd: opts.cwd,
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env },
  });

  const state = {
    text: "",
    sessionId: null,
    model: null,
    subtype: null,
    isError: false,
    resultText: null,
    usage: null,
    costUSD: null,
    durationMs: null,
    stderr: [],
    denied: [],
    finished: false,
  };

  const send = (obj) => {
    if (!child.stdin.destroyed) child.stdin.write(`${JSON.stringify(obj)}\n`);
  };

  let settle;
  const done = new Promise((resolve) => { settle = resolve; });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try { child.kill("SIGTERM"); } catch {}
    setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 2000).unref?.();
    settle("timeout");
  }, opts.timeoutSec * 1000);

  readline.createInterface({ input: child.stderr }).on("line", (line) => {
    if (state.stderr.length < 40) state.stderr.push(line);
  });

  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    if (!line.trim()) return;
    let event;
    try { event = JSON.parse(line); } catch { return; }

    if (event.ev === "permission_request") {
      const decision = permissionDecision(opts.mode, event.tool, event.input);
      if (!decision.allow) state.denied.push({ tool: event.tool, why: decision.why });
      send({ op: "permission", id: event.id, allow: decision.allow, message: decision.why });
      return;
    }
    if (event.ev === "error") {
      state.isError = true;
      state.resultText = String(event.message ?? "");
      return;
    }
    if (event.ev === "closed") { state.finished = true; settle("closed"); return; }
    if (event.ev !== "sdk") return;

    const msg = event.msg ?? {};
    if (msg.type === "system" && msg.subtype === "init") {
      state.sessionId = msg.session_id ?? null;
      if (msg.model) state.model = msg.model;
      return;
    }
    if (msg.type === "assistant" && typeof msg.message?.model === "string" && msg.message.model) {
      state.model = msg.message.model;
    }
    if (msg.type === "stream_event"
      && msg.event?.type === "content_block_delta"
      && msg.event?.delta?.type === "text_delta") {
      state.text += String(msg.event.delta.text ?? "");
      return;
    }
    if (msg.type === "result") {
      state.subtype = msg.subtype ?? null;
      state.isError = msg.is_error === true;
      if (typeof msg.result === "string" && msg.result) state.resultText = msg.result;
      if (msg.session_id) state.sessionId = msg.session_id;
      state.usage = msg.usage ?? msg.modelUsage ?? null;
      state.costUSD = msg.total_cost_usd ?? null;
      state.durationMs = msg.duration_ms ?? null;
      state.finished = true;
      settle("result");
    }
  });

  child.on("error", (error) => {
    state.isError = true;
    state.resultText = `spawn 失敗：${error.message}`;
    settle("spawn_error");
  });
  child.on("exit", () => { if (!state.finished) settle("exit"); });

  send({ op: "send", text: opts.prompt, uuid: crypto.randomUUID() });
  const reason = await done;
  clearTimeout(timer);
  send({ op: "close" });
  setTimeout(() => { try { child.kill("SIGKILL"); } catch {} }, 1500).unref?.();

  const text = (state.text || state.resultText || "").trim();
  let exitStatus = 0;
  if (timedOut || reason === "timeout") exitStatus = 124;
  else if (state.isError || reason === "spawn_error") exitStatus = 1;
  else if (!text) exitStatus = 1;

  return { exitStatus, text, state, reason };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.mode === "doctor") return doctor();

  const startedAt = new Date().toISOString();
  const t0 = Date.now();
  const outcome = await run(opts);
  const record = {
    ts: new Date().toISOString(),
    started_at: startedAt,
    command: opts.mode,
    mode: opts.mode,
    engine: opts.engine,
    read_only_enforced: opts.mode !== "delegate" && READ_ONLY_ENFORCEABLE.has(opts.engine),
    unsafe_no_readonly: opts.unsafeNoReadOnly === true,
    model_requested: opts.model ?? null,
    model_reported: outcome.state?.model ?? null,
    cwd: opts.cwd,
    exit_status: outcome.exitStatus,
    engine_session_id: outcome.state?.sessionId ?? null,
    engine_subtype: outcome.state?.subtype ?? null,
    engine_model_usage: outcome.state?.usage ?? null,
    engine_total_cost_usd: outcome.state?.costUSD ?? null,
    engine_duration_ms: outcome.state?.durationMs ?? (Date.now() - t0),
    denied_tools: outcome.state?.denied ?? [],
    prompt_preview: opts.prompt.slice(0, 200),
    result_preview: (outcome.text || "").slice(0, 400),
    stderr: (outcome.state?.stderr ?? []).slice(0, 10),
  };
  appendLog(opts.log, record);

  if (opts.json) {
    process.stdout.write(`${JSON.stringify({ ...record, result: outcome.text }, null, 2)}\n`);
  } else if (outcome.text) {
    process.stdout.write(`${outcome.text}\n`);
  }
  if (outcome.exitStatus === 124) process.stderr.write(`tatwo-engine: 逾時（>${opts.timeoutSec}s）已中止\n`);
  else if (outcome.exitStatus === 1 && !outcome.text) {
    process.stderr.write(`tatwo-engine: 引擎沒有回覆（reason=${outcome.reason}）\n`);
  }
  process.exit(outcome.exitStatus);
}

main().catch((error) => {
  process.stderr.write(`tatwo-engine: ${error?.stack || error}\n`);
  process.exit(1);
});
