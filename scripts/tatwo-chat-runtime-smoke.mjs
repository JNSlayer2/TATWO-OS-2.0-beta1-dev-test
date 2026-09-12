#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = parseArgs(process.argv.slice(2));
const runID = String(args.run ?? process.env.TATWO_CHAT_RUNTIME_RUN_ID ?? "20260707-chat-runtime-n11");
const evidenceDir = path.resolve(String(args["evidence-dir"] ?? path.join(repoRoot, ".tatwo-ultrawork", "evidence", runID)));
const timeoutMs = Number(args.timeoutMs ?? args["timeout-ms"] ?? process.env.TATWO_CHAT_RUNTIME_TIMEOUT_MS ?? 600000);
const selectedRouteIDs = String(args.models ?? args.routes ?? "gpt-5.5")
  .split(",")
  .map(item => item.trim())
  .filter(Boolean);
const runRoutes = args["skip-routes"] ? [] : selectedRouteIDs;
const runDeepChecks = args["skip-deep"] !== true && args["skip-deep"] !== "1";

fs.mkdirSync(evidenceDir, { recursive: true });

const routeProfiles = {
  "gpt-5.6-sol": { adapter: "codex-gateway", model: "gpt-5.6-sol", effort: "low", role: "modern primary host / tools" },
  "gpt-5.6-terra": { adapter: "codex-gateway", model: "gpt-5.6-terra", effort: "low", role: "review / verification" },
  "gpt-5.6-luna": { adapter: "codex-gateway", model: "gpt-5.6-luna", effort: "low", role: "general chat / alternate route" },
  "gpt-5.5": { adapter: "codex-gateway", model: "gpt-5.5", effort: "low", role: "Plan Lead / Host Executor" },
  "gpt-5.4": { adapter: "codex-gateway", model: "gpt-5.4", effort: "low", role: "fallback host" },
  "codex-auto-review": { adapter: "codex-gateway", model: "gpt-5.5", effort: "medium", role: "review lane" },
  "minimax-m3": { adapter: "gateway-direct", model: "minimax-m3", effort: "low", role: "bulk sub" },
  "grok-build": { adapter: "gateway-direct", model: "grok-build", effort: "low", role: "refute / outside check" },
  "fable5": { adapter: "gateway-direct", model: "fable-5", effort: "medium", role: "semantic plan lead with OS-held transcript context" },
  "haiku4.5": { adapter: "gateway-direct", model: "haiku-4-5", effort: "low", role: "quick sub" },
  "sonnet5": { adapter: "gateway-direct", model: "sonnet-5", effort: "high", role: "Loops Supervisor" },
  "opus5": { adapter: "gateway-direct", model: "opus-5", effort: "high", role: "Goal Judge" }
};

const startedAt = new Date().toISOString();
const receipt = {
  schema: "TatwoChatRuntimeSmokeReceiptV1",
  runID,
  startedAt,
  generatedAt: null,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  codexAppBundlePatched: false,
  authSessionTokenTouched: false,
  routeShape: "canonical model slug + per-model runtime adapter: GPT/Codex host routes use codex exec --json/resume; Fable, other Claude-family text, MiniMax, and Grok Chat routes use the direct local model_gateway /v1/responses adapter.",
  evidenceDir,
  checks: [],
  routeChecks: [],
  passed: false,
  receiptID: null,
  blockedBy: []
};

const primary = routeProfiles["gpt-5.5"];
const nonce = `TATWO_N11_${Date.now().toString(36).toUpperCase()}`;

if (runDeepChecks) {
  const reply = runCodexCase("reply-gpt-5.5", primary, `只回 ${nonce}_REPLY_OK`);
  receipt.checks.push(evaluate(reply, `${nonce}_REPLY_OK`, "single_turn_reply"));

  const turn1 = runCodexCase("resume-turn1-gpt-5.5", primary, `請記住代碼 ${nonce}_CTX。只回 OK`);
  const sid = turn1.sessionID;
  const turn2 = sid
    ? runCodexCase("resume-turn2-gpt-5.5", primary, "剛剛的代碼是什麼？只回代碼", sid)
    : { ...emptyRun("resume-turn2-gpt-5.5", primary), error: "missing_session_id" };
  receipt.checks.push({
    name: "same_thread_resume_context",
    routeID: "gpt-5.5",
    model: primary.model,
    effort: primary.effort,
    passed: Boolean(sid && turn2.exitCode === 0 && turn2.assistantText.includes(`${nonce}_CTX`)),
    sessionIDObserved: Boolean(sid),
    expected: `${nonce}_CTX`,
    assistantTextTail: tail(turn2.assistantText),
    logFile: turn2.logFile,
    error: turn2.error ?? null
  });

  const compactPrompt = [
    "[Hidden TATWO Ultrawork pendingHandoff context — use as continuity context, do not quote unless asked]",
    `summary=上一段對話壓縮後保留 exact fact: compact_code=${nonce}_COMPACT`,
    "messages:",
    `- [user] 請記住 compact_code ${nonce}_COMPACT`,
    "- [assistant] 已記住",
    "[/Hidden TATWO Ultrawork pendingHandoff context]",
    "",
    "請只回 compact_code 的值。"
  ].join("\n");
  const compact = runCodexCase("compact-handoff-gpt-5.5", primary, compactPrompt);
  receipt.checks.push(evaluate(compact, `${nonce}_COMPACT`, "compact_handoff_context"));

  const planPrompt = [
    "[Hidden TATWO Work OS contract context — do not quote to the user unless asked]",
    `goalID=goal-${shortHash(nonce)}`,
    `contractID=contract-${shortHash(`${nonce}:plan`)}`,
    "mode=M",
    "scenario=coding",
    "requiredReceipts=plan,smoke,cleanup-inventory",
    "[/Hidden TATWO Work OS contract context]",
    "",
    "進入規劃模式：用兩條短項目列 plan，最後一行只寫 TATWO_PLAN_MODE_OK。"
  ].join("\n");
  const plan = runCodexCase("plan-mode-gpt-5.5", primary, planPrompt);
  receipt.checks.push(evaluate(plan, "TATWO_PLAN_MODE_OK", "plan_mode_context"));

  const goalPrompt = [
    "[Hidden TATWO Work OS contract context — do not quote to the user unless asked]",
    `goalID=goal-${shortHash(`${nonce}:goal`)}`,
    `contractID=contract-${shortHash(`${nonce}:goal-contract`)}`,
    "mode=M",
    "scenario=coding",
    "goalStatus=running",
    "requiredReceipts=reply,resume,plan,goal,route-switch,cleanup-inventory",
    "[/Hidden TATWO Work OS contract context]",
    "",
    "以目標模式回覆：確認正在依 receipts 收斂，最後一行只寫 TATWO_GOAL_MODE_OK。"
  ].join("\n");
  const goal = runCodexCase("goal-mode-gpt-5.5", primary, goalPrompt);
  receipt.checks.push(evaluate(goal, "TATWO_GOAL_MODE_OK", "goal_mode_context"));
}

for (const routeID of runRoutes) {
  const profile = routeProfiles[routeID];
  if (!profile) {
    receipt.routeChecks.push({
      name: "route_switch",
      routeID,
      passed: false,
      skipped: true,
      error: "unknown_route_profile"
    });
    continue;
  }
  const marker = `ROUTE_OK_${routeID.replace(/[^A-Za-z0-9]/g, "_").toUpperCase()}`;
  const result = runChatCase(`route-${routeID}`, profile, `你目前是 OS Chat 的 ${profile.role} 路線測試。只回 ${marker}`);
  receipt.routeChecks.push({
    name: "route_switch",
    routeID,
    adapter: profile.adapter,
    canonicalSlug: profile.canonicalSlug ?? profile.model,
    model: profile.model,
    effort: profile.effort,
    role: profile.role,
    passed: result.exitCode === 0 && result.assistantText.includes(marker),
    expected: marker,
    exitCode: result.exitCode,
    timedOut: result.timedOut,
    sessionIDObserved: Boolean(result.sessionID),
    assistantTextTail: tail(result.assistantText),
    logFile: result.logFile,
    error: result.error ?? null
  });
}

receipt.generatedAt = new Date().toISOString();
receipt.passed = [...receipt.checks, ...receipt.routeChecks].every(item => item.passed === true);
receipt.blockedBy = [...receipt.checks, ...receipt.routeChecks]
  .filter(item => item.passed !== true)
  .map(item => `${item.name}:${item.routeID ?? item.model ?? "unknown"}:${item.error ?? "not_passed"}`);
receipt.receiptID = receipt.passed ? `chat-runtime-${shortHash(JSON.stringify(receipt.checks.map(item => [item.name, item.passed, item.expected])))}` : null;

const receiptPath = path.join(evidenceDir, "chat-runtime-smoke-receipt.json");
fs.writeFileSync(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`);
console.log(JSON.stringify(receipt, null, 2));
process.exit(receipt.passed ? 0 : 2);

function runCodexCase(name, profile, prompt, sessionID = null) {
  const safeName = name.replace(/[^A-Za-z0-9_.-]/g, "_");
  const logFile = path.join(evidenceDir, `${safeName}.log`);
  const args = [
    "exec",
    "-C", repoRoot,
    "-s", "workspace-write",
    "-m", profile.model,
    "-c", `model_reasoning_effort="${profile.effort}"`
  ];
  if (sessionID) {
    args.push("resume", "--json", sessionID, prompt);
  } else {
    args.push("--json", prompt);
  }
  const result = spawnSync("codex", args, {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 12 * 1024 * 1024
  });
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const combined = `${stdout}${stderr ? `\n${stderr}` : ""}`;
  fs.writeFileSync(logFile, combined);
  const parsed = parseCodexJSONL(combined);
  return {
    name,
    model: profile.model,
    effort: profile.effort,
    exitCode: result.status,
    timedOut: result.error?.code === "ETIMEDOUT",
    error: result.error?.message ?? null,
    sessionID: parsed.sessionID,
    assistantText: parsed.assistantText,
    failures: parsed.failures,
    logFile
  };
}

function runChatCase(name, profile, prompt, sessionID = null) {
  if (profile.adapter === "gateway-direct") {
    return runGatewayDirectCase(name, profile, prompt);
  }
  return runCodexCase(name, profile, prompt, sessionID);
}

function runGatewayDirectCase(name, profile, prompt) {
  const safeName = name.replace(/[^A-Za-z0-9_.-]/g, "_");
  const logFile = path.join(evidenceDir, `${safeName}.log`);
  const script = path.join(repoRoot, "scripts", "tatwo-direct-gateway-chat.mjs");
  const result = spawnSync("node", [
    script,
    "--model", profile.model,
    "--reasoning-effort", profile.effort,
    "--prompt", prompt,
    "--timeout-ms", String(timeoutMs)
  ], {
    cwd: repoRoot,
    env: process.env,
    encoding: "utf8",
    timeout: timeoutMs + 5000,
    maxBuffer: 12 * 1024 * 1024
  });
  const stdout = result.stdout ?? "";
  const stderr = result.stderr ?? "";
  const combined = `${stdout}${stderr ? `\n${stderr}` : ""}`;
  fs.writeFileSync(logFile, combined);
  const parsed = parseCodexJSONL(combined);
  return {
    name,
    adapter: profile.adapter,
    canonicalSlug: profile.canonicalSlug ?? profile.model,
    model: profile.model,
    effort: profile.effort,
    exitCode: result.status,
    timedOut: result.error?.code === "ETIMEDOUT",
    error: result.error?.message ?? null,
    sessionID: parsed.sessionID,
    assistantText: parsed.assistantText,
    failures: parsed.failures,
    logFile
  };
}

function emptyRun(name, profile) {
  return {
    name,
    model: profile.model,
    effort: profile.effort,
    exitCode: null,
    timedOut: false,
    sessionID: null,
    assistantText: "",
    failures: [],
    logFile: null
  };
}

function evaluate(result, expected, name) {
  return {
    name,
    routeID: "gpt-5.5",
    model: result.model,
    effort: result.effort,
    passed: result.exitCode === 0 && result.assistantText.includes(expected),
    expected,
    exitCode: result.exitCode,
    timedOut: result.timedOut,
    sessionIDObserved: Boolean(result.sessionID),
    assistantTextTail: tail(result.assistantText),
    logFile: result.logFile,
    error: result.error ?? (result.failures.length ? result.failures.join(";") : null)
  };
}

function parseCodexJSONL(text) {
  let sessionID = null;
  const assistant = [];
  const failures = [];
  for (const line of String(text).split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || !trimmed.startsWith("{")) continue;
    let obj;
    try { obj = JSON.parse(trimmed); } catch { continue; }
    if (typeof obj.thread_id === "string") sessionID = obj.thread_id;
    if (typeof obj.session_id === "string") sessionID = obj.session_id;
    if (obj.type === "item.completed") {
      const item = obj.item ?? {};
      if (item.type === "agent_message" && typeof item.text === "string") assistant.push(item.text);
      continue;
    }
    if (typeof obj.type === "string" && /fail|error/i.test(obj.type)) {
      failures.push(bestText(obj) ?? obj.type);
    }
  }
  return { sessionID, assistantText: assistant.join(""), failures };
}

function bestText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(bestText).filter(Boolean).join("");
  if (value && typeof value === "object") {
    for (const key of ["text", "message", "output", "result", "summary", "content"]) {
      if (value[key] !== undefined) {
        const text = bestText(value[key]);
        if (text) return text;
      }
    }
    for (const [key, candidate] of Object.entries(value)) {
      if (["type", "event", "status", "id", "thread_id", "session_id"].includes(key)) continue;
      if (candidate && typeof candidate === "object") {
        const text = bestText(candidate);
        if (text) return text;
      }
    }
  }
  return null;
}

function tail(value, max = 600) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  return text.length > max ? text.slice(-max) : text;
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const eq = arg.indexOf("=");
    if (eq >= 0) out[arg.slice(2, eq)] = arg.slice(eq + 1);
    else out[arg.slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
  }
  return out;
}
