#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

const args = parseArgs(process.argv.slice(2));
const backupDir = args["backup-dir"] ? path.resolve(String(args["backup-dir"])) : null;
const requiredFiles = ["config.toml", "state_5.sqlite"];
const optionalFiles = ["models_cache.json", "codex-global-state.json", "codex-model-gateway.plist"];
const observedRequiredFiles = backupDir ? requiredFiles.map(name => fileStatus(backupDir, name)) : [];
const observedOptionalFiles = backupDir ? optionalFiles.map(name => fileStatus(backupDir, name)) : [];
const rollbackPlanValidated = observedRequiredFiles.length > 0 && observedRequiredFiles.every(item => item.exists && item.sizeBytes !== null);
const receiptID = rollbackPlanValidated
  ? `rollback-${shortHash(JSON.stringify(observedRequiredFiles))}`
  : null;

const report = {
  schema: "TatwoHostRollbackPlanV1",
  dryRun: true,
  hostMutationAllowed: false,
  rollbackMutationPerformed: false,
  rollbackPlanValidated,
  receiptID,
  generatedAt: new Date().toISOString(),
  backupDirHint: backupDir ? sanitizePath(backupDir) : "<backup-dir-required-for-validation>",
  requiredBackupFiles: requiredFiles,
  optionalBackupFiles: optionalFiles,
  observedRequiredFiles,
  observedOptionalFiles,
  restoreCommands: [
    "cp \"<backup>/config.toml\" \"$HOME/.codex/config.toml\"",
    "cp \"<backup>/state_5.sqlite\" \"$HOME/.codex/state_5.sqlite\"",
    "cp \"<backup>/models_cache.json\" \"$HOME/.codex/models_cache.json\" 2>/dev/null || true",
    "cp \"<backup>/codex-global-state.json\" \"$HOME/.codex-global-state.json\" 2>/dev/null || true",
    "cp \"<backup>/codex-model-gateway.plist\" \"$HOME/Library/LaunchAgents/com.$USER.codex-model-gateway.plist\" 2>/dev/null || true"
  ],
  deniedActions: [
    "does not restore files in this script",
    "does not load or unload LaunchAgents",
    "does not patch signed Codex App bundle",
    "does not read auth/session/token material"
  ],
  plainSummary: rollbackPlanValidated
    ? "Rollback plan validated against the local backup directory. This script still did not mutate host files."
    : "Dry-run rollback plan only. Provide --backup-dir after a confirmed backup to produce a rollback receipt."
};

console.log(JSON.stringify(report, null, 2));

function fileStatus(root, name) {
  const file = path.join(root, name);
  try {
    const stat = fs.statSync(file);
    return { name, exists: stat.isFile(), sizeBytes: stat.isFile() ? stat.size : null };
  } catch {
    return { name, exists: false, sizeBytes: null };
  }
}

function shortHash(value) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 12);
}

function sanitizePath(value) {
  const home = os.homedir();
  return String(value)
    .replaceAll(home, "$HOME")
    .replace(/^\/Volumes\/[^/]+/g, "<volume>")
    .replaceAll(os.userInfo().username, "$USER");
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
