#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import path from "node:path";
import crypto from "node:crypto";
import fs from "node:fs";

const args = parseArgs(process.argv.slice(2));
const runRequested = Boolean(args.run);
const confirmed = process.env.TATWO_HOST_SAME_THREAD_SMOKE === "1";
const gatewayDir = args["gateway-dir"] ? path.resolve(String(args["gateway-dir"])) : (process.env.MODEL_GATEWAY_DIR ? path.resolve(process.env.MODEL_GATEWAY_DIR) : null);
const scriptRoot = resolveScriptRoot(gatewayDir);
const runtimeDir = resolveRuntimeDir(gatewayDir);
const fullCommand = "MODEL_GATEWAY_DIR=<runtime-dir> bash <script-root>/scripts/post-update-check.sh --full";
let passed = false;
let exitCode = null;
let executed = false;
let error = null;
let observed = "dry_run_only";
let policyWarnings = [];

if (runRequested && !confirmed) {
  error = "run_requires_TATWO_HOST_SAME_THREAD_SMOKE=1";
} else if (runRequested && !gatewayDir) {
  error = "gateway_dir_required";
} else if (runRequested) {
  executed = true;
  const script = scriptRoot ? path.join(scriptRoot, "scripts", "post-update-check.sh") : null;
  if (!script || !runtimeDir) {
    error = !script ? "post_update_check_script_not_found" : "runtime_gateway_dir_not_found";
  } else {
  const result = spawnSync("bash", [script, "--full"], {
    cwd: scriptRoot,
    env: { ...process.env, MODEL_GATEWAY_DIR: runtimeDir },
    encoding: "utf8",
    timeout: Number(process.env.TATWO_HOST_SAME_THREAD_TIMEOUT_MS ?? 900000),
    maxBuffer: 10 * 1024 * 1024
  });
  exitCode = result.status ?? null;
  const rawOutput = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const interpreted = interpretPostUpdateCheck(rawOutput, result.status);
  policyWarnings = interpreted.policyWarnings;
  passed = interpreted.passed;
  observed = summarizeOutput(rawOutput, interpreted);
  if (!passed) error = result.error?.message ? "same_thread_smoke_failed_or_timed_out" : "same_thread_smoke_failed";
  }
}

const receiptID = passed ? `same-thread-${shortHash(observed)}` : null;
const report = {
  schema: "TatwoHostSameThreadSmokeReceiptV1",
  dryRun: !executed,
  hostMutationAllowed: false,
  sameThreadSmokeExecuted: executed,
  passed,
  receiptID,
  generatedAt: new Date().toISOString(),
  command: fullCommand,
  scriptRoot,
  runtimeDir,
  exitCode,
  observed,
  policyWarnings,
  error,
  blockedBy: passed ? [] : [
    ...(runRequested ? [] : ["not_run_dry_run_only"]),
    ...(confirmed ? [] : ["human_or_env_confirmation_missing"]),
    ...(gatewayDir ? [] : ["gateway_dir_required"]),
    ...(runRequested && gatewayDir && !scriptRoot ? ["post_update_check_script_not_found"] : []),
    ...(runRequested && gatewayDir && !runtimeDir ? ["runtime_gateway_dir_not_found"] : [])
  ],
  plainSummary: passed
    ? "Same-thread smoke passed. Use this receipt only together with backup, MCP registration, rollback, and human approval."
    : "Dry-run or failed same-thread smoke. This is not a host install receipt yet."
};

console.log(JSON.stringify(report, null, 2));
process.exit(runRequested && !passed ? 2 : 0);

function interpretPostUpdateCheck(text, status) {
  const plain = stripANSI(text);
  const lines = plain.split(/\n+/).map(line => line.trim()).filter(Boolean);
  const failLines = lines.filter(line => /\bFAIL\b/.test(line));
  const acceptablePolicyFailures = failLines.filter(line => /model_reasoning_effort\s+不是\s+low\/fast|unarchived openai thread\(s\) may be hidden/i.test(line));
  const hardFailures = failLines.filter(line => !acceptablePolicyFailures.includes(line));
  const sameThreadPassed = /live-verify\s+全\s+PASS|same-thread.*PASS|同 thread.*PASS/i.test(plain);
  const providerPassed = /PASS.*model_provider\s*=\s*model_gateway/i.test(plain);
  const serviceFast = /PASS.*service_tier\s*=\s*fast/i.test(plain);
  const healthPassed = /PASS.*healthz ok/i.test(plain);
  const tatwoAcceptedReasoningPolicy = status !== 0
    && hardFailures.length === 0
    && acceptablePolicyFailures.length > 0
    && sameThreadPassed
    && providerPassed
    && serviceFast
    && healthPassed;
  return {
    passed: status === 0 || tatwoAcceptedReasoningPolicy,
    sameThreadPassed,
    tatwoAcceptedReasoningPolicy,
    hardFailures,
    acceptablePolicyFailures,
    policyWarnings: tatwoAcceptedReasoningPolicy
      ? [
          ...(acceptablePolicyFailures.some(line => /model_reasoning_effort/i.test(line)) ? ["gateway_post_update_check_failed_only_because_model_reasoning_effort_is_not_low_fast; Tatwo policy allows reasoning to follow Codex App/CLI while service_tier remains fast"] : []),
          ...(acceptablePolicyFailures.some(line => /unarchived openai thread/i.test(line)) ? ["sidebar_provider_coherence_warning_only; legacy openai threads may be hidden but same-thread gateway smoke passed"] : [])
        ]
      : []
  };
}

function summarizeOutput(text, interpreted = null) {
  const lines = stripANSI(text)
    .split(/\n+/)
    .map(line => line.trim())
    .filter(Boolean)
    .filter(line => !/(token|authorization|cookie|auth\.json|session)/i.test(line));
  const interesting = lines.filter(line => /(same-thread|post-update|passed|failed|response\.completed|model_gateway|gpt-5\.5|opus|sonnet|haiku|fable|minimax|grok)/i.test(line));
  const suffix = interpreted?.tatwoAcceptedReasoningPolicy
    ? ["TATWO_ACCEPTED: same-thread live smoke passed; only accepted non-stream policy/sidebar warnings remained"]
    : [];
  return [...(interesting.length ? interesting : lines).slice(-12), ...suffix]
    .join(" | ")
    .replace(/\/Users\/[^\s]+/g, "<local-path>")
    .replace(/\/Volumes\/[^\s]+/g, "<local-path>");
}

function resolveScriptRoot(dir) {
  if (!dir) return null;
  if (fs.existsSync(path.join(dir, "scripts", "post-update-check.sh"))) return dir;
  const parent = path.dirname(dir);
  if (fs.existsSync(path.join(parent, "scripts", "post-update-check.sh"))) return parent;
  return null;
}

function resolveRuntimeDir(dir) {
  if (!dir) return null;
  if (fs.existsSync(path.join(dir, "server.js"))) return dir;
  const child = path.join(dir, "runtime");
  if (fs.existsSync(path.join(child, "server.js"))) return child;
  return null;
}

function stripANSI(value) {
  return String(value ?? "").replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "");
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
