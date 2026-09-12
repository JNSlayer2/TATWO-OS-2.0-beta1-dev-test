#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const home = os.homedir();
const args = parseArgs(process.argv.slice(2));
const now = new Date();
const stamp = now.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
const backupRoot = args["backup-dir"]
  ? path.resolve(String(args["backup-dir"]))
  : path.join(home, ".codex", "backups", `tatwo-ultrawork-${stamp}`);
const confirm = Boolean(args.confirm) && process.env.TATWO_HOST_BACKUP_CONFIRM === "1";

const targets = [
  target("codex-config", "Codex config", path.join(home, ".codex", "config.toml"), true),
  target("codex-state-db", "Codex state database", path.join(home, ".codex", "state_5.sqlite"), true),
  target("codex-models-cache", "Codex models cache", path.join(home, ".codex", "models_cache.json"), false),
  target("codex-global-state", "Codex global state", path.join(home, ".codex-global-state.json"), false),
  target("gateway-launchagent-plist", "model gateway LaunchAgent plist", path.join(home, "Library", "LaunchAgents", `com.${os.userInfo().username}.codex-model-gateway.plist`), false),
  target("tatwo-app-data", "Tatwo Ultrawork app data", path.join(home, "Library", "Application Support", "Tatwo Ultrawork"), false, "directory")
];

const deniedContent = [
  "auth.json",
  "refresh/access tokens",
  "API keys",
  "raw logs",
  "browser profiles/cookies/localStorage",
  "full rollout files or private thread ids"
];

let executedCopies = [];
let executionError = null;
if (args.confirm && process.env.TATWO_HOST_BACKUP_CONFIRM !== "1") {
  executionError = "confirm_requires_TATWO_HOST_BACKUP_CONFIRM=1";
} else if (confirm) {
  try {
    fs.mkdirSync(backupRoot, { recursive: true, mode: 0o700 });
    for (const item of targets) {
      if (!item.exists || item.kind === "directory") continue;
      const dest = path.join(backupRoot, item.backupFileName);
      fs.copyFileSync(item.sourcePath, dest);
      executedCopies.push({ id: item.id, dest: sanitizePath(dest) });
    }
  } catch (error) {
    executionError = "backup_copy_failed";
  }
}

const report = {
  schema: "TatwoHostBackupPlanV1",
  dryRun: !confirm,
  hostMutationAllowed: false,
  backupExecuted: confirm && !executionError,
  receiptID: confirm && !executionError ? `backup-${shortHash(JSON.stringify(executedCopies.map(item => item.id).sort()))}` : null,
  humanApprovalRequiredForConfirm: true,
  generatedAt: now.toISOString(),
  backupRootHint: sanitizePath(backupRoot),
  targets: targets.map(({ sourcePath, backupFileName, ...rest }) => ({
    ...rest,
    sourceHint: sanitizePath(sourcePath),
    backupFileName
  })),
  copyCommands: [
    "TATWO_HOST_BACKUP_CONFIRM=1 node scripts/tatwo-host-backup-plan.mjs --confirm --json",
    "cp \"$HOME/.codex/config.toml\" \"<backup>/config.toml\"",
    "cp \"$HOME/.codex/state_5.sqlite\" \"<backup>/state_5.sqlite\"",
    "cp \"$HOME/.codex/models_cache.json\" \"<backup>/models_cache.json\" 2>/dev/null || true",
    "cp \"$HOME/.codex-global-state.json\" \"<backup>/codex-global-state.json\" 2>/dev/null || true",
    "cp \"$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist\" \"<backup>/codex-model-gateway.plist\" 2>/dev/null || true"
  ],
  restoreCommands: [
    "cp \"<backup>/config.toml\" \"$HOME/.codex/config.toml\"",
    "cp \"<backup>/state_5.sqlite\" \"$HOME/.codex/state_5.sqlite\"",
    "cp \"<backup>/models_cache.json\" \"$HOME/.codex/models_cache.json\" 2>/dev/null || true",
    "cp \"<backup>/codex-global-state.json\" \"$HOME/.codex-global-state.json\" 2>/dev/null || true",
    "cp \"<backup>/codex-model-gateway.plist\" \"$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist\" 2>/dev/null || true"
  ],
  deniedContent,
  executedCopies,
  error: executionError,
  plainSummary: confirm
    ? "Backup confirm path only copied allowlisted config/state/cache files; auth/session material remains excluded."
    : "Dry-run only: no host files were copied. Use --confirm plus TATWO_HOST_BACKUP_CONFIRM=1 only after human approval."
};

console.log(JSON.stringify(report, null, 2));
process.exit(executionError ? 2 : 0);

function target(id, label, sourcePath, required, kind = "file") {
  const exists = fs.existsSync(sourcePath);
  const stat = exists ? fs.statSync(sourcePath) : null;
  const backupFileName = backupNameFor(id);
  return {
    id,
    label,
    sourcePath,
    required,
    kind,
    exists,
    sizeBytes: stat?.isFile() ? stat.size : null,
    includeContent: true,
    backupFileName,
    plainSafetyRule: "Local-only backup target; never commit backup content or auth/session material."
  };
}

function backupNameFor(id) {
  switch (id) {
    case "codex-config": return "config.toml";
    case "codex-state-db": return "state_5.sqlite";
    case "codex-models-cache": return "models_cache.json";
    case "codex-global-state": return "codex-global-state.json";
    case "gateway-launchagent-plist": return "codex-model-gateway.plist";
    case "tatwo-app-data": return "TatwoUltrawork-app-data";
    default: return `${id}.bak`;
  }
}

function sanitizePath(value) {
  return String(value)
    .replaceAll(home, "$HOME")
    .replaceAll(os.userInfo().username, "$USER");
}

function shortHash(value) {
  return crypto.createHash("sha256").update(String(value)).digest("hex").slice(0, 12);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    if (key.includes("=")) {
      const [k, ...rest] = key.split("=");
      out[k] = rest.join("=");
    } else if (argv[i + 1] && !argv[i + 1].startsWith("--")) {
      out[key] = argv[++i];
    } else {
      out[key] = true;
    }
  }
  return out;
}
