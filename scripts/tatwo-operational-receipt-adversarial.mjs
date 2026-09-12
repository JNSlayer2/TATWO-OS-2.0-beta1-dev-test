#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");

const cases = [
  {
    name: "host-live-good",
    shouldPass: true,
    requires: ["TatwoOperationalGateReportV1"],
    description: "Real host-live same-thread receipt with response.completed can pass."
  },
  {
    name: "host-mcp-good",
    shouldPass: true,
    requires: ["mcp-host-registration"],
    description: "Host MCP registration must be observed from host config, not just stdio."
  },
  {
    name: "partial-stream",
    shouldPass: false,
    requires: ["partial_stream_cannot_pass", "terminal_event_not_completed"],
    description: "Deltas or in-progress stream without response.completed cannot pass."
  },
  {
    name: "stdio-fake-host",
    shouldPass: false,
    requires: ["mcp_stdio_not_host_registration", "mcp_server_self_report_cannot_prove_host_state"],
    description: "MCP stdio/self-report cannot be promoted to host registration."
  },
  {
    name: "dry-run-host-live",
    shouldPass: false,
    requires: ["dry_run_cannot_satisfy_host_live", "host_live_required"],
    description: "Dry-run evidence cannot satisfy host-live smoke."
  },
  {
    name: "disconnected",
    shouldPass: false,
    requires: ["disconnect_cannot_pass"],
    description: "Disconnected reviewer/backend is reviewer_unavailable, not pass."
  },
  {
    name: "retry-storm",
    shouldPass: false,
    requires: ["retry_storm_or_circuit_open"],
    description: "Retry storms and circuit-open states block install evidence."
  },
  {
    name: "old-approval-epoch",
    shouldPass: false,
    requires: ["approval_epoch_stale_after_model_switch", "approval_epoch_mismatch"],
    description: "Model switch resets approval; old approval cannot install."
  },
  {
    name: "model-text-approval",
    shouldPass: false,
    requires: ["model_text_cannot_approve_install"],
    description: "Model text cannot approve host install."
  }
];

const checks = cases.map(runCase);
checks.push(runFileValidationCase());
const failed = checks.filter(item => !item.passed).map(item => item.id);
const report = {
  schema: "TatwoOperationalReceiptAdversarialV1",
  passed: failed.length === 0,
  hostMutationAllowed: false,
  hostMutationPerformed: false,
  checks,
  failedCheckIDs: failed,
  plainSummary: failed.length === 0
    ? "Operational receipt adversarial checks passed: dry-run, stdio-only, partial stream, disconnect, retry storm, model text approval, and old approval epoch all fail closed."
    : "Operational receipt adversarial checks failed; do not proceed toward host install.",
  generatedAt: new Date().toISOString()
};

console.log(JSON.stringify(report, null, 2));
process.exit(failed.length === 0 ? 0 : 1);

function runCase(item) {
  const result = spawnSync("swift", ["run", "--package-path", repoRoot, "tatwo-ultrawork", "validate", "sample-operational", "--case", item.name, "--json"], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  const text = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const parsed = parseJSON(text);
  const ok = parsed?.ok === true;
  const failedAsExpected = parsed?.ok === false || result.status !== 0;
  const requiredFound = item.requires.every(needle => text.includes(needle));
  const passStateMatches = item.shouldPass ? (ok && result.status === 0) : failedAsExpected;
  return {
    id: `operational-${item.name}`,
    passed: Boolean(passStateMatches && requiredFound),
    expectedPass: item.shouldPass,
    exitStatus: result.status,
    observedOK: ok,
    observedReasons: parsed?.data?.report?.reasons ?? [],
    description: item.description
  };
}

function runFileValidationCase() {
  const sample = spawnSync("swift", ["run", "--package-path", repoRoot, "tatwo-ultrawork", "validate", "sample-operational", "--case", "host-live-good", "--json"], {
    cwd: repoRoot,
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 10 * 1024 * 1024
  });
  const parsed = parseJSON(`${sample.stdout ?? ""}\n${sample.stderr ?? ""}`);
  const receipt = parsed?.data?.receipt;
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-operational-receipt-"));
  try {
    const file = path.join(tmp, "host-live-good.json");
    fs.writeFileSync(file, JSON.stringify(receipt, null, 2), "utf8");
    const validate = spawnSync("swift", ["run", "--package-path", repoRoot, "tatwo-ultrawork", "validate", "operational-receipt", "--file", file, "--require", "host-live-same-thread", "--json"], {
      cwd: repoRoot,
      encoding: "utf8",
      timeout: 120000,
      maxBuffer: 10 * 1024 * 1024
    });
    const text = `${validate.stdout ?? ""}\n${validate.stderr ?? ""}`;
    return {
      id: "operational-file-validate",
      passed: validate.status === 0 && text.includes("TatwoOperationalGateReportV1") && text.includes("\"hostInstallEvidenceAllowed\" : true"),
      expectedPass: true,
      exitStatus: validate.status,
      observedOK: parseJSON(text)?.ok === true,
      observedReasons: parseJSON(text)?.data?.report?.reasons ?? [],
      description: "CLI validates a real operational receipt JSON file with an explicit requirement."
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

function parseJSON(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i += 1) {
    const ch = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === "\"") inString = false;
      continue;
    }
    if (ch === "\"") { inString = true; continue; }
    if (ch === "{") depth += 1;
    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        try { return JSON.parse(text.slice(start, i + 1)); }
        catch { return null; }
      }
    }
  }
  return null;
}
