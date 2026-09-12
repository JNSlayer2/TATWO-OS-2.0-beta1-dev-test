#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const args = process.argv.slice(2);
const commandMode = args.includes("--preflight") || args[0] === "preflight" ? "preflight" : "run";
const json = args.includes("--json") || true;
const objective = opt("--objective") || "Tatwo Colima sandbox verification";
const mode = opt("--mode") || "L";
const scenario = opt("--scenario") || "coding";
const profile = opt("--profile") || "tatwo-ultrawork-sandbox";
const workDir = path.resolve(opt("--work-dir") || repoRoot);
const image = opt("--image") || "swift:6.2";
const requestedCommands = opts("--command").length ? opts("--command") : ["swift test --package-path ."];
const allowExecute = args.includes("--allow-execute");
const dryRun = args.includes("--dry-run") || !allowExecute;

const allowedPrefixes = [
  "swift test",
  "swift build",
  "node scripts/tatwo-ultrawork-mcp-smoke.mjs",
  "node scripts/tatwo-ultrawork-mcp-adversarial-smoke.mjs",
  "node scripts/tatwo-codex-disconnect-guard.mjs",
  "bash scripts/tatwo-ultrawork-sandbox-check.sh",
  "true"
];

const deniedMounts = ["$HOME", "/Users", "whole /Volumes", "~/.codex", "~/.ssh", "browser profiles", "Docker socket from host"];
const deniedEnvironment = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GROK_API_KEY", "MINIMAX_API_KEY", "Authorization", "access_token", "refresh_token", "SSH_AUTH_SOCK"];

const preflight = buildPreflight();
if (commandMode === "preflight") {
  print(preflight);
  process.exit(0);
}

const receipt = buildRunReceipt();
print(receipt);
process.exit(receipt.status === "blocked" ? 3 : 0);

function buildPreflight() {
  const colimaPath = which("colima");
  const dockerPath = which("docker");
  const limaPath = which("lima");
  const dockerServer = dockerPath ? run("docker", ["version", "--format", "{{.Server.Version}}"], { timeout: 5000 }) : null;
  const colimaStatus = colimaPath ? run("colima", ["status", "--profile", profile], { timeout: 5000 }) : null;
  const dockerDaemonAvailable = Boolean(dockerServer && dockerServer.status === 0 && dockerServer.stdout.trim());
  const available = Boolean(colimaPath && dockerPath);
  return {
    schema: "TatwoColimaRunnerPreflightV1",
    adapterID: "colima-sandbox-runner",
    generatedAt: new Date().toISOString(),
    profile,
    available,
    dockerDaemonAvailable,
    hostMutationAllowed: false,
    autoInstallAllowed: false,
    autoStartAllowed: false,
    commands: [
      commandCheck("colima", colimaPath, true),
      commandCheck("docker", dockerPath, true),
      commandCheck("lima", limaPath, false)
    ],
    colimaStatus: summarizeResult(colimaStatus),
    dockerServer: summarizeResult(dockerServer),
    safetyRules: [
      "Colima is optional L2 runtime verification, not a model lane.",
      "Missing Colima/Docker is degraded, not a Tatwo core failure.",
      "This runner never auto-installs or auto-starts Colima.",
      "Execution requires --allow-execute and never mounts HOME, /Users, whole /Volumes, auth, SSH agent, or browser profiles.",
      "Docker image must already exist locally; the runner will not pull images automatically."
    ],
    installHint: "Optional only: brew install colima docker; start a Tatwo-specific profile manually if you want real container execution.",
    plainSummary: available
      ? "Colima/Docker commands are visible; real execution still needs explicit approval and a running Docker daemon."
      : "Colima/Docker missing; keep using existing Tatwo sandbox checks."
  };
}

function buildRunReceipt() {
  const unsafeCommands = requestedCommands.filter(command => !isAllowedCommand(command));
  const blockReasons = [];
  if (!preflight.available) blockReasons.push("colima_or_docker_missing");
  if (dryRun) blockReasons.push("dry_run_only");
  if (!allowExecute) blockReasons.push("execution_not_explicitly_allowed");
  if (unsafeCommands.length) blockReasons.push("command_not_allowlisted");

  const base = {
    schema: "TatwoColimaRunnerReceiptV1",
    receiptID: stableID({ objective, mode, scenario, dryRun, available: preflight.available }),
    generatedAt: new Date().toISOString(),
    adapterID: "colima-sandbox-runner",
    objective: redact(objective),
    mode,
    scenario,
    profile,
    image,
    dryRun,
    executed: false,
    hostMutationAllowed: false,
    preflight,
    requestedCommands: requestedCommands.map(redact),
    allowedCommandPrefixes: allowedPrefixes,
    deniedMounts,
    deniedEnvironment,
    workspacePolicy: [
      "Copy work-dir to a temporary workspace before container execution.",
      "Do not mount HOME, /Users, whole /Volumes, auth/session, SSH agent, or browser profile.",
      "Do not pull images automatically; pre-pull only after human approval.",
      "Remove the temporary workspace after the receipt is written."
    ],
    blockReasons,
    commandResults: [],
    cleanupPerformed: false
  };

  if (blockReasons.length > 0) {
    return {
      ...base,
      status: preflight.available ? "planned" : "degraded",
      plainSummary: preflight.available
        ? "Colima run is planned only; resolve dry-run/approval/allowlist blockers before execution."
        : "Colima run degraded because Colima or Docker is missing; this is not a Tatwo core failure."
    };
  }

  if (!preflight.dockerDaemonAvailable) {
    return { ...base, status: "blocked", blockReasons: ["docker_daemon_not_available"], plainSummary: "Docker daemon is not available. The runner will not start Colima automatically." };
  }

  const imageCheck = run("docker", ["image", "inspect", image], { timeout: 10000 });
  if (imageCheck.status !== 0) {
    return { ...base, status: "blocked", blockReasons: ["image_not_present_locally"], plainSummary: "Docker image is not present locally. The runner refuses to pull images automatically." };
  }

  if (!fs.existsSync(workDir) || !fs.statSync(workDir).isDirectory()) {
    return { ...base, status: "blocked", blockReasons: ["work_dir_missing"], plainSummary: "Work directory is missing; no container execution attempted." };
  }

  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-colima-work-"));
  const workspaceCopy = path.join(tmpRoot, "workspace");
  const commandResults = [];
  let cleanupPerformed = false;
  try {
    copyWorkspace(workDir, workspaceCopy);
    for (const command of requestedCommands) {
      const result = run("docker", [
        "run",
        "--rm",
        "--pull=never",
        "--network=none",
        "--volume", `${workspaceCopy}:/workspace:rw`,
        "--workdir", "/workspace",
        image,
        "sh",
        "-lc",
        command
      ], { timeout: Number(process.env.TATWO_COLIMA_COMMAND_TIMEOUT_MS || 600000) });
      commandResults.push({
        command: redact(command),
        status: result.status,
        signal: result.signal || null,
        stdoutTail: redact(tail(result.stdout, 12000)),
        stderrTail: redact(tail(result.stderr, 12000))
      });
      if (result.status !== 0) break;
    }
  } finally {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
    cleanupPerformed = true;
  }

  const passed = commandResults.length === requestedCommands.length && commandResults.every(r => r.status === 0);
  return {
    ...base,
    status: passed ? "passed" : "blocked",
    executed: true,
    workspaceCopy: "<temporary-workspace-redacted>",
    commandResults,
    cleanupPerformed,
    plainSummary: passed
      ? "Colima/Docker execution completed in a temporary workspace with no host config mutation."
      : "At least one allowlisted command failed inside the temporary container workspace."
  };
}

function commandCheck(command, foundPath, requiredForExecution) {
  return {
    command,
    status: foundPath ? "installed" : "missing",
    path: foundPath ? redact(foundPath) : null,
    requiredForExecution,
    plainStatus: foundPath ? `${command} found on PATH` : `${command} not found on PATH`
  };
}

function which(command) {
  const result = spawnSync("/usr/bin/env", ["sh", "-c", `command -v ${shellQuote(command)}`], { encoding: "utf8", timeout: 3000 });
  if (result.status !== 0) return null;
  const out = (result.stdout || "").trim();
  return out || null;
}

function run(command, runArgs, options = {}) {
  const result = spawnSync(command, runArgs, {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
    timeout: options.timeout || 30000,
    env: filteredEnv()
  });
  return {
    status: result.status ?? (result.error ? 1 : 0),
    signal: result.signal || null,
    stdout: result.stdout || "",
    stderr: result.stderr || (result.error ? String(result.error.message || result.error) : "")
  };
}

function filteredEnv() {
  const env = { PATH: process.env.PATH || "/usr/bin:/bin:/usr/sbin:/sbin" };
  if (process.env.HOME) env.HOME = process.env.HOME;
  return env;
}

function summarizeResult(result) {
  if (!result) return null;
  return {
    status: result.status,
    signal: result.signal || null,
    stdoutTail: redact(tail(result.stdout, 4000)),
    stderrTail: redact(tail(result.stderr, 4000))
  };
}

function copyWorkspace(source, destination) {
  const exclude = new Set([".git", ".build", ".swiftpm", "node_modules", ".tatwo-ultrawork"]);
  fs.mkdirSync(destination, { recursive: true });
  fs.cpSync(source, destination, {
    recursive: true,
    force: true,
    dereference: false,
    filter: src => !exclude.has(path.basename(src))
  });
}

function isAllowedCommand(command) {
  const trimmed = String(command || "").trim();
  if (!trimmed) return false;
  return allowedPrefixes.some(prefix => trimmed === prefix || trimmed.startsWith(prefix + " "));
}

function opt(name) {
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value.startsWith(`${name}=`)) return value.slice(name.length + 1);
    if (value === name && index + 1 < args.length) return args[index + 1];
  }
  return null;
}

function opts(name) {
  const values = [];
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value.startsWith(`${name}=`)) values.push(value.slice(name.length + 1));
    else if (value === name && index + 1 < args.length) values.push(args[index + 1]);
  }
  return values;
}

function stableID(payload) {
  const digest = crypto.createHash("sha256").update(JSON.stringify(payload)).digest("hex").slice(0, 12);
  return `colima-runner-${digest}`;
}

function tail(value, max) {
  const text = String(value || "");
  return text.length <= max ? text : text.slice(text.length - max);
}

function redact(value) {
  return String(value || "")
    .replace(/\/Users\/[^\s"']+/g, "<local-path>")
    .replace(/\/Volumes\/[^\s"']+/g, "<local-path>")
    .replace(/sk-[A-Za-z0-9_-]{10,}/g, "<token>")
    .replace(/Bearer\s+[A-Za-z0-9._-]{10,}/g, "Bearer <token>")
    .replace(/(access_token|refresh_token|api_key)[=:][^\s"']+/gi, "$1=<token>");
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function print(value) {
  const safe = JSON.parse(redact(JSON.stringify(value)));
  process.stdout.write(JSON.stringify(safe, null, 2));
  process.stdout.write("\n");
}
