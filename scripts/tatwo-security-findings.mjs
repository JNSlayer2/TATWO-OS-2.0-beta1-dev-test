#!/usr/bin/env node

/**
 * Tatwo security findings harness (zero-dependency).
 * Append-only findings.jsonl under TATWO_SECURITY_STATE_DIR (default: <repo>/.tatwo-security).
 *
 * Concurrency:
 *   - Exclusive create (open wx) for findings.jsonl — never truncate on init race.
 *   - add/mark serialize via stateDir/findings.lock (mkdir spin + timeout + stale PID).
 *   - mark records carry previousRecordHash (SHA-256 of prior line for that id); readers
 *     flag forked when the hash does not match the actual previous line.
 *   - Incomplete trailing JSON line is ignored with a warning (crash partial tail).
 *
 * Usage:
 *   node scripts/tatwo-security-findings.mjs add [--json <json>]
 *   node scripts/tatwo-security-findings.mjs list [--status s] [--severity s] [--revision rev]
 *   node scripts/tatwo-security-findings.mjs mark <id> <status> [--scan <scanID>] [--verified-by <who>]
 *   node scripts/tatwo-security-findings.mjs --selftest
 */

import { createHash, randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  rmdirSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA = "TatwoSecurityFindingV1";
const SEVERITIES = new Set(["low", "medium", "high", "critical"]);
const STATUSES = new Set(["open", "fixed", "accepted", "superseded", "false_positive"]);
const REQUIRED_FIELDS = [
  "id",
  "scanID",
  "revision",
  "surface",
  "severity",
  "title",
  "detail",
  "status",
  "verifiedBy",
  "firstSeenScan",
  "lastSeenScan",
];
const SCRIPT_PATH = resolve(fileURLToPath(import.meta.url));
const LOCK_DIR_NAME = "findings.lock";
const LOCK_TIMEOUT_MS = 30_000;
const LOCK_SPIN_MS = 20;
const HASH_HEX_RE = /^[a-f0-9]{64}$/i;

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(`Usage:
  node scripts/tatwo-security-findings.mjs add [--json <json>]
  node scripts/tatwo-security-findings.mjs list [--status <status>] [--severity <sev>] [--revision <rev>]
  node scripts/tatwo-security-findings.mjs mark <id> <status> [--scan <scanID>] [--verified-by <who>]
  node scripts/tatwo-security-findings.mjs --selftest

Env:
  TATWO_SECURITY_STATE_DIR   State root (default: <repo>/.tatwo-security)`);
}

function gitShowTopLevel(cwd) {
  try {
    return spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).stdout.trim() || null;
  } catch {
    return null;
  }
}

function resolveStateDir() {
  const fromEnv = String(process.env.TATWO_SECURITY_STATE_DIR || "").trim();
  if (fromEnv) return resolve(fromEnv);
  const root = gitShowTopLevel(process.cwd()) || process.cwd();
  return join(root, ".tatwo-security");
}

function sleepSync(ms) {
  const sab = new SharedArrayBuffer(4);
  const ia = new Int32Array(sab);
  Atomics.wait(ia, 0, 0, ms);
}

function sha256Hex(text) {
  return createHash("sha256").update(String(text), "utf8").digest("hex");
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function readLockPid(lockDir) {
  try {
    const raw = readFileSync(join(lockDir, "owner.pid"), "utf8").trim();
    if (!/^\d+$/.test(raw)) return null;
    return Number(raw);
  } catch {
    return null;
  }
}

function isLockStale(lockDir) {
  if (!existsSync(lockDir)) return false;
  const pid = readLockPid(lockDir);
  // Missing/invalid pid: treat as stale only after a short grace so we do not
  // steal a peer mid-publication. Atomic rename publication normally makes this rare.
  if (pid === null) {
    try {
      const st = readdirSync(lockDir);
      // empty or metadata incomplete — grace via mtime is heavy; prefer dead-only.
      // If directory exists with no owner.pid after rename protocol, it is abandoned.
      return st.length === 0 || !st.includes("owner.pid");
    } catch {
      return true;
    }
  }
  return !isPidAlive(pid);
}

function tryTakeoverStaleLock(lockDir) {
  if (!isLockStale(lockDir)) return false;
  const stalePath = `${lockDir}.stale.${Date.now()}.${process.pid}`;
  try {
    renameSync(lockDir, stalePath);
    return true;
  } catch {
    return false;
  }
}

function releaseWriteLock(lockDir) {
  if (!lockDir) return;
  try {
    const pid = readLockPid(lockDir);
    if (pid !== null && pid !== process.pid) {
      // Do not clear another live holder's lock.
      if (isPidAlive(pid)) return;
    }
  } catch {
    // continue best-effort release of our claim
  }
  for (const name of ["owner.pid", "hostname", "acquired_at"]) {
    try {
      unlinkSync(join(lockDir, name));
    } catch {
      // ignore
    }
  }
  try {
    rmdirSync(lockDir);
  } catch {
    // ignore if already gone or not empty
  }
}

/**
 * Cross-process writer lock on stateDir/findings.lock.
 * Claim is published atomically: write owner metadata in a private dir, then rename
 * into findings.lock (no empty-lock observation window). Spins + timeout + stale PID takeover.
 */
function acquireWriteLock(stateDir, timeoutMs = LOCK_TIMEOUT_MS) {
  mkdirSync(stateDir, { recursive: true });
  const lockDir = join(stateDir, LOCK_DIR_NAME);
  const started = Date.now();
  while (true) {
    const claimDir = join(
      stateDir,
      `${LOCK_DIR_NAME}.claim.${process.pid}.${Date.now()}.${randomBytes(4).toString("hex")}`,
    );
    try {
      mkdirSync(claimDir);
      writeFileSync(join(claimDir, "owner.pid"), `${process.pid}\n`, "utf8");
      writeFileSync(join(claimDir, "acquired_at"), `${new Date().toISOString()}\n`, "utf8");
      try {
        renameSync(claimDir, lockDir);
        return lockDir;
      } catch (renameErr) {
        // Lost race or lock held — remove private claim and retry/spin.
        try {
          unlinkSync(join(claimDir, "owner.pid"));
        } catch {
          // ignore
        }
        try {
          unlinkSync(join(claimDir, "acquired_at"));
        } catch {
          // ignore
        }
        try {
          rmdirSync(claimDir);
        } catch {
          // ignore
        }
        if (renameErr && (renameErr.code === "ENOTEMPTY" || renameErr.code === "EEXIST" || renameErr.code === "EPERM")) {
          // fall through to stale/timeout handling
        } else if (existsSync(lockDir)) {
          // destination exists
        } else {
          // unexpected — still spin rather than hard-fail on flaky FS
        }
      }
    } catch (error) {
      // claim mkdir failed
      try {
        rmSync(claimDir, { recursive: true, force: true });
      } catch {
        // ignore
      }
      if (!(error && error.code === "EEXIST")) {
        // continue toward timeout path for lock contention only when lock held
      }
    }

    if (existsSync(lockDir) && tryTakeoverStaleLock(lockDir)) continue;

    if (Date.now() - started >= timeoutMs) {
      const holder = existsSync(lockDir) ? readLockPid(lockDir) : null;
      throw new Error(
        `findings write lock timeout after ${timeoutMs}ms; holder pid=${holder ?? "?"} lock=${lockDir}`,
      );
    }
    sleepSync(LOCK_SPIN_MS);
  }
}

function withWriteLock(stateDir, fn) {
  const lockDir = acquireWriteLock(stateDir);
  try {
    return fn();
  } finally {
    releaseWriteLock(lockDir);
  }
}

/**
 * Ensure scans/ exists and findings.jsonl exists via exclusive create (wx).
 * Never truncates an existing file (EEXIST → use current file).
 */
function ensureStateLayout(stateDir) {
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(join(stateDir, "scans"), { recursive: true });
  const findingsPath = join(stateDir, "findings.jsonl");
  try {
    const fd = openSync(findingsPath, "wx");
    closeSync(fd);
  } catch (error) {
    if (!error || error.code !== "EEXIST") throw error;
    // Existing file: never truncate.
  }
  return findingsPath;
}

function assertNonEmptyString(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`invalid finding: ${field} must be non-empty string`);
  }
}

function validateFinding(raw) {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("invalid finding: must be a JSON object");
  }
  for (const field of REQUIRED_FIELDS) {
    if (!(field in raw)) throw new Error(`invalid finding: missing field ${field}`);
  }
  for (const field of REQUIRED_FIELDS) {
    assertNonEmptyString(raw[field], field);
  }
  if (!SEVERITIES.has(raw.severity)) {
    throw new Error(`invalid finding: severity must be one of ${[...SEVERITIES].join("|")}`);
  }
  if (!STATUSES.has(raw.status)) {
    throw new Error(`invalid finding: status must be one of ${[...STATUSES].join("|")}`);
  }
  const out = {
    schema: typeof raw.schema === "string" && raw.schema.trim() ? raw.schema : SCHEMA,
    id: raw.id.trim(),
    scanID: raw.scanID.trim(),
    revision: raw.revision.trim(),
    surface: raw.surface.trim(),
    severity: raw.severity,
    title: raw.title.trim(),
    detail: raw.detail.trim(),
    status: raw.status,
    verifiedBy: raw.verifiedBy.trim(),
    firstSeenScan: raw.firstSeenScan.trim(),
    lastSeenScan: raw.lastSeenScan.trim(),
  };
  if (typeof raw.recordedAt === "string" && raw.recordedAt.trim()) {
    out.recordedAt = raw.recordedAt.trim();
  }
  if (typeof raw.previousRecordHash === "string" && raw.previousRecordHash.trim()) {
    const h = raw.previousRecordHash.trim();
    if (!HASH_HEX_RE.test(h)) {
      throw new Error("invalid finding: previousRecordHash must be 64-char hex SHA-256");
    }
    out.previousRecordHash = h.toLowerCase();
  }
  return out;
}

/**
 * Read findings.jsonl.
 * Incomplete trailing JSON (crash mid-append) → ignore last line + warning.
 * Mid-file bad JSON still throws.
 */
function readAllEntries(findingsPath) {
  if (!existsSync(findingsPath)) return { entries: [], warnings: [] };
  const text = readFileSync(findingsPath, "utf8");
  if (!text) return { entries: [], warnings: [] };

  const lines = text.split(/\r?\n/);
  if (lines.length > 0 && lines[lines.length - 1] === "") {
    lines.pop();
  }

  const entries = [];
  const warnings = [];
  for (let i = 0; i < lines.length; i += 1) {
    const raw = lines[i];
    if (raw.trim() === "") continue;
    const isLast = i === lines.length - 1;
    try {
      const obj = JSON.parse(raw);
      entries.push({ obj, raw, lineNo: i + 1 });
    } catch (error) {
      if (isLast) {
        warnings.push(
          `findings.jsonl: ignoring incomplete trailing line (${raw.length} bytes): ${error.message}`,
        );
        continue;
      }
      throw new Error(`findings.jsonl line ${i + 1}: not JSON (${error.message})`);
    }
  }
  return { entries, warnings };
}

function emitReadWarnings(warnings) {
  for (const w of warnings) {
    console.error(`warning: ${w}`);
  }
}

/**
 * Detect mark forks: previousRecordHash must equal SHA-256 of the actual previous
 * raw line for the same id in journal order. Mismatch → id is forked (human adjudicate).
 */
function detectForkedIds(entries) {
  const prevRawById = new Map();
  const forkedIds = new Set();
  for (const { obj, raw } of entries) {
    if (!obj || typeof obj !== "object") continue;
    const id = typeof obj.id === "string" ? obj.id.trim() : "";
    if (!id) continue;
    const expected = typeof obj.previousRecordHash === "string" ? obj.previousRecordHash.trim().toLowerCase() : "";
    if (expected) {
      const prevRaw = prevRawById.get(id);
      if (prevRaw !== undefined) {
        const actual = sha256Hex(prevRaw);
        if (actual !== expected) forkedIds.add(id);
      } else {
        // Mark claims a previous hash but no prior line for id → forked / inconsistent.
        forkedIds.add(id);
      }
    }
    prevRawById.set(id, raw);
  }
  return forkedIds;
}

function latestById(entries) {
  const map = new Map();
  for (const entry of entries) {
    const rec = entry.obj;
    if (rec && typeof rec.id === "string" && rec.id.trim()) {
      map.set(rec.id.trim(), entry);
    }
  }
  return map;
}

function appendFinding(findingsPath, finding) {
  const line = JSON.stringify(finding);
  appendFileSync(findingsPath, `${line}\n`, "utf8");
}

function readStdinSync() {
  try {
    return readFileSync(0, "utf8");
  } catch {
    return "";
  }
}

function parseJsonInput(text, label) {
  const trimmed = String(text || "").trim();
  if (!trimmed) throw new Error(`${label}: empty JSON`);
  try {
    return JSON.parse(trimmed);
  } catch (error) {
    throw new Error(`${label}: ${error.message}`);
  }
}

function parseArgs(argv) {
  if (argv.includes("--selftest")) {
    if (argv.length !== 1) throw new Error("--selftest accepts no other arguments");
    return { command: "selftest" };
  }

  const command = argv[0];
  if (!command || command.startsWith("-")) {
    throw new Error("missing command (add|list|mark) or --selftest");
  }

  const rest = argv.slice(1);
  const flags = {};
  const positionals = [];

  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (
      arg === "--json" ||
      arg === "--status" ||
      arg === "--severity" ||
      arg === "--revision" ||
      arg === "--scan" ||
      arg === "--verified-by"
    ) {
      const value = rest[i + 1];
      if (value === undefined || value.startsWith("--")) throw new Error(`${arg} requires a value`);
      flags[arg.slice(2)] = value;
      i += 1;
      continue;
    }
    if (arg.startsWith("--json=")) {
      flags.json = arg.slice("--json=".length);
      continue;
    }
    if (arg.startsWith("--status=")) {
      flags.status = arg.slice("--status=".length);
      continue;
    }
    if (arg.startsWith("--severity=")) {
      flags.severity = arg.slice("--severity=".length);
      continue;
    }
    if (arg.startsWith("--revision=")) {
      flags.revision = arg.slice("--revision=".length);
      continue;
    }
    if (arg.startsWith("--scan=")) {
      flags.scan = arg.slice("--scan=".length);
      continue;
    }
    if (arg.startsWith("--verified-by=")) {
      flags["verified-by"] = arg.slice("--verified-by=".length);
      continue;
    }
    if (arg.startsWith("--")) throw new Error(`unknown argument: ${arg}`);
    positionals.push(arg);
  }

  return { command, flags, positionals };
}

function cmdAdd(stateDir, flags) {
  let raw;
  if (flags.json !== undefined) {
    raw = parseJsonInput(flags.json, "--json");
  } else {
    const stdin = readStdinSync();
    raw = parseJsonInput(stdin, "stdin");
  }
  const finding = validateFinding(raw);
  if (!finding.recordedAt) finding.recordedAt = new Date().toISOString();

  const findingsPath = withWriteLock(stateDir, () => {
    const path = ensureStateLayout(stateDir);
    appendFinding(path, finding);
    return path;
  });
  console.log(JSON.stringify({ ok: true, action: "add", id: finding.id, path: findingsPath }));
}

function cmdList(stateDir, flags) {
  // list is read-only; ensure layout without holding write lock for the whole read.
  const findingsPath = ensureStateLayout(stateDir);
  const { entries, warnings } = readAllEntries(findingsPath);
  emitReadWarnings(warnings);
  const forkedIds = detectForkedIds(entries);
  const latest = latestById(entries);
  let items = [...latest.values()].map((e) => {
    const f = { ...e.obj };
    if (forkedIds.has(f.id)) f.forked = true;
    return f;
  });

  if (flags.status) {
    if (!STATUSES.has(flags.status)) throw new Error(`invalid --status: ${flags.status}`);
    items = items.filter((f) => f.status === flags.status);
  }
  if (flags.severity) {
    if (!SEVERITIES.has(flags.severity)) throw new Error(`invalid --severity: ${flags.severity}`);
    items = items.filter((f) => f.severity === flags.severity);
  }
  if (flags.revision) {
    items = items.filter((f) => f.revision === flags.revision);
  }

  items.sort((a, b) => String(a.id).localeCompare(String(b.id)));
  console.log(
    JSON.stringify(
      {
        ok: true,
        count: items.length,
        findings: items,
        forkedIds: [...forkedIds].sort(),
        incompleteTrailingLineIgnored: warnings.some((w) => w.includes("incomplete trailing")),
      },
      null,
      2,
    ),
  );
}

function cmdMark(stateDir, flags, positionals) {
  const id = positionals[0];
  const status = positionals[1];
  if (!id || !status) throw new Error("mark requires <id> <status>");
  if (!STATUSES.has(status)) {
    throw new Error(`invalid status: must be one of ${[...STATUSES].join("|")}`);
  }

  const result = withWriteLock(stateDir, () => {
    const findingsPath = ensureStateLayout(stateDir);
    const { entries, warnings } = readAllEntries(findingsPath);
    // Surface partial-tail warnings even under lock (do not fail mark).
    for (const w of warnings) console.error(`warning: ${w}`);

    const latest = latestById(entries);
    const prevEntry = latest.get(id);
    if (!prevEntry) throw new Error(`unknown finding id: ${id}`);
    const prev = prevEntry.obj;
    const previousRecordHash = sha256Hex(prevEntry.raw);

    const next = validateFinding({
      ...prev,
      status,
      lastSeenScan: (flags.scan && String(flags.scan).trim()) || prev.lastSeenScan || prev.scanID,
      verifiedBy: (flags["verified-by"] && String(flags["verified-by"]).trim()) || prev.verifiedBy,
      firstSeenScan: prev.firstSeenScan,
      recordedAt: new Date().toISOString(),
      previousRecordHash,
    });
    // Preserve firstSeenScan even if caller somehow overwrote via spread of bad data.
    next.firstSeenScan = prev.firstSeenScan;
    next.previousRecordHash = previousRecordHash;
    appendFinding(findingsPath, next);
    return {
      findingsPath,
      next,
      previousStatus: prev.status,
    };
  });

  console.log(
    JSON.stringify({
      ok: true,
      action: "mark",
      id: result.next.id,
      status: result.next.status,
      previousStatus: result.previousStatus,
      previousRecordHash: result.next.previousRecordHash,
      path: result.findingsPath,
    }),
  );
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sampleFinding(overrides = {}) {
  return {
    id: "finding-selftest-1",
    scanID: "scan-selftest-1",
    revision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    surface: "auth",
    severity: "high",
    title: "selftest finding",
    detail: "created by --selftest",
    status: "open",
    verifiedBy: "selftest",
    firstSeenScan: "scan-selftest-1",
    lastSeenScan: "scan-selftest-1",
    ...overrides,
  };
}

function spawnWorker(args, env, options = {}) {
  return new Promise((resolvePromise) => {
    const child = spawn(process.execPath, [SCRIPT_PATH, ...args], {
      env,
      cwd: process.cwd(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    if (options.input != null) {
      child.stdin.write(options.input);
    }
    child.stdin.end();
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      resolvePromise({ status: 1, stdout, stderr: `${stderr}\n${error.message}`, pid: child.pid });
    });
    child.on("close", (code) => {
      resolvePromise({ status: code ?? 1, stdout, stderr, pid: child.pid });
    });
  });
}

function countJsonlLines(path) {
  if (!existsSync(path)) return 0;
  const text = readFileSync(path, "utf8");
  if (!text.trim()) return 0;
  return text
    .split(/\r?\n/)
    .filter((line) => {
      if (!line.trim()) return false;
      try {
        JSON.parse(line);
        return true;
      } catch {
        return false;
      }
    }).length;
}

async function runSelftest() {
  const tempRoot = mkdtempSync(join(tmpdir(), "tatwo-security-selftest-"));
  const stateDir = join(tempRoot, "state");
  const env = {
    ...process.env,
    TATWO_SECURITY_STATE_DIR: stateDir,
  };

  const run = (args, options = {}) => {
    const result = spawnSync(process.execPath, [SCRIPT_PATH, ...args], {
      env,
      encoding: "utf8",
      input: options.input,
      cwd: process.cwd(),
    });
    return result;
  };

  try {
    // --- Serial baseline (original cases) ---
    const sample = sampleFinding();

    const add = run(["add", "--json", JSON.stringify(sample)]);
    assert(add.status === 0, `add failed: ${add.stderr || add.stdout}`);
    const addOut = JSON.parse(add.stdout.trim());
    assert(addOut.ok === true && addOut.id === sample.id, "add response invalid");

    const listOpen = run(["list", "--status", "open", "--severity", "high"]);
    assert(listOpen.status === 0, `list failed: ${listOpen.stderr || listOpen.stdout}`);
    const listBody = JSON.parse(listOpen.stdout);
    assert(listBody.count === 1, `expected 1 open finding, got ${listBody.count}`);
    assert(listBody.findings[0].id === sample.id, "list id mismatch");
    assert(listBody.findings[0].status === "open", "list status mismatch");

    const mark = run([
      "mark",
      sample.id,
      "fixed",
      "--scan",
      "scan-selftest-2",
      "--verified-by",
      "selftest-marker",
    ]);
    assert(mark.status === 0, `mark failed: ${mark.stderr || mark.stdout}`);
    const markOut = JSON.parse(mark.stdout.trim());
    assert(markOut.status === "fixed", "mark status not fixed");
    assert(
      typeof markOut.previousRecordHash === "string" && HASH_HEX_RE.test(markOut.previousRecordHash),
      "mark must emit previousRecordHash",
    );

    const listFixed = run(["list", "--status", "fixed"]);
    assert(listFixed.status === 0, `list fixed failed: ${listFixed.stderr}`);
    const fixedBody = JSON.parse(listFixed.stdout);
    assert(fixedBody.count === 1, "expected 1 fixed finding after mark");
    assert(fixedBody.findings[0].status === "fixed", "latest status not fixed");
    assert(fixedBody.findings[0].firstSeenScan === "scan-selftest-1", "firstSeenScan rewritten");
    assert(fixedBody.findings[0].lastSeenScan === "scan-selftest-2", "lastSeenScan not updated");
    assert(fixedBody.findings[0].verifiedBy === "selftest-marker", "verifiedBy not updated");
    assert(
      fixedBody.findings[0].previousRecordHash === markOut.previousRecordHash,
      "listed previousRecordHash mismatch",
    );
    assert(Array.isArray(fixedBody.forkedIds) && fixedBody.forkedIds.length === 0, "unexpected fork");

    const listOpenAfter = run(["list", "--status", "open"]);
    assert(listOpenAfter.status === 0, "list open after mark failed");
    const openAfter = JSON.parse(listOpenAfter.stdout);
    assert(openAfter.count === 0, "open set should be empty after mark fixed");

    const rawPath = join(stateDir, "findings.jsonl");
    const rawLines = readFileSync(rawPath, "utf8").trim().split(/\r?\n/);
    assert(rawLines.length === 2, `expected 2 append lines, got ${rawLines.length}`);
    const firstHash = sha256Hex(rawLines[0]);
    const second = JSON.parse(rawLines[1]);
    assert(second.previousRecordHash === firstHash, "previousRecordHash must hash prior raw line");

    const bad = run(["add", "--json", JSON.stringify({ id: "x", status: "open" })]);
    assert(bad.status !== 0, "bad schema should be rejected");
    assert(
      /invalid finding|missing field/i.test(`${bad.stderr}\n${bad.stdout}`),
      "bad schema error message missing",
    );

    const listByRev = run(["list", "--revision", sample.revision]);
    assert(listByRev.status === 0, "list by revision failed");
    const revBody = JSON.parse(listByRev.stdout);
    assert(revBody.count === 1, "revision filter failed");

    assert(String(env.TATWO_SECURITY_STATE_DIR).startsWith(tempRoot), "selftest must use temp state dir");

    // --- ① fresh-file create race: two processes concurrent init+add ---
    const raceDir = join(tempRoot, "race-create");
    const raceEnv = { ...process.env, TATWO_SECURITY_STATE_DIR: raceDir };
    const raceA = sampleFinding({
      id: "finding-race-a",
      title: "race A",
      detail: "create race worker A",
    });
    const raceB = sampleFinding({
      id: "finding-race-b",
      title: "race B",
      detail: "create race worker B",
    });
    const [raceResA, raceResB] = await Promise.all([
      spawnWorker(["add", "--json", JSON.stringify(raceA)], raceEnv),
      spawnWorker(["add", "--json", JSON.stringify(raceB)], raceEnv),
    ]);
    assert(raceResA.status === 0, `race A add failed: ${raceResA.stderr || raceResA.stdout}`);
    assert(raceResB.status === 0, `race B add failed: ${raceResB.stderr || raceResB.stdout}`);
    const racePath = join(raceDir, "findings.jsonl");
    const raceLineCount = countJsonlLines(racePath);
    assert(
      raceLineCount === 2,
      `fresh-file create race: expected 2 complete lines (sum of both writers), got ${raceLineCount}`,
    );
    const raceText = readFileSync(racePath, "utf8");
    assert(raceText.includes("finding-race-a"), "race missing A");
    assert(raceText.includes("finding-race-b"), "race missing B");
    // File must not have been truncated to empty after writes.
    assert(raceText.length > 0, "race truncated file to empty");

    // --- ② same id concurrent add ---
    const sameIdDir = join(tempRoot, "same-id");
    const sameIdEnv = { ...process.env, TATWO_SECURITY_STATE_DIR: sameIdDir };
    const sameBase = sampleFinding({ id: "finding-same-id", title: "same-id base" });
    const sameA = { ...sameBase, detail: "worker-A-detail", scanID: "scan-same-a", lastSeenScan: "scan-same-a" };
    const sameB = { ...sameBase, detail: "worker-B-detail", scanID: "scan-same-b", lastSeenScan: "scan-same-b" };
    const [sameResA, sameResB] = await Promise.all([
      spawnWorker(["add", "--json", JSON.stringify(sameA)], sameIdEnv),
      spawnWorker(["add", "--json", JSON.stringify(sameB)], sameIdEnv),
    ]);
    assert(sameResA.status === 0, `same-id A failed: ${sameResA.stderr || sameResA.stdout}`);
    assert(sameResB.status === 0, `same-id B failed: ${sameResB.stderr || sameResB.stdout}`);
    const samePath = join(sameIdDir, "findings.jsonl");
    const sameCount = countJsonlLines(samePath);
    assert(sameCount === 2, `same-id concurrent add: expected 2 lines, got ${sameCount}`);
    const sameBody = JSON.parse(
      (
        await spawnWorker(["list"], sameIdEnv)
      ).stdout,
    );
    assert(sameBody.count === 1, "same-id latest view should collapse to 1");
    assert(sameBody.findings[0].id === "finding-same-id", "same-id list id");

    // --- ③ opposite status concurrent mark ---
    const markDir = join(tempRoot, "concurrent-mark");
    const markEnv = { ...process.env, TATWO_SECURITY_STATE_DIR: markDir };
    const markBase = sampleFinding({ id: "finding-mark-race", status: "open" });
    const markAdd = await spawnWorker(["add", "--json", JSON.stringify(markBase)], markEnv);
    assert(markAdd.status === 0, `mark-race add failed: ${markAdd.stderr || markAdd.stdout}`);
    const [markFixed, markAccepted] = await Promise.all([
      spawnWorker(
        ["mark", "finding-mark-race", "fixed", "--scan", "scan-mark-fixed", "--verified-by", "marker-fixed"],
        markEnv,
      ),
      spawnWorker(
        [
          "mark",
          "finding-mark-race",
          "accepted",
          "--scan",
          "scan-mark-accepted",
          "--verified-by",
          "marker-accepted",
        ],
        markEnv,
      ),
    ]);
    assert(markFixed.status === 0, `concurrent mark fixed failed: ${markFixed.stderr || markFixed.stdout}`);
    assert(
      markAccepted.status === 0,
      `concurrent mark accepted failed: ${markAccepted.stderr || markAccepted.stdout}`,
    );
    const markPath = join(markDir, "findings.jsonl");
    const markLines = readFileSync(markPath, "utf8")
      .trim()
      .split(/\r?\n/)
      .filter((l) => l.trim());
    assert(markLines.length === 3, `concurrent mark: expected 3 linearized lines (1 add + 2 marks), got ${markLines.length}`);
    const markParsed = markLines.map((l) => JSON.parse(l));
    assert(markParsed[0].status === "open", "first line should be open add");
    const markStatuses = new Set(markParsed.slice(1).map((r) => r.status));
    assert(markStatuses.has("fixed") && markStatuses.has("accepted"), "both mark statuses must be present (no loss)");
    // CAS chain: each mark's previousRecordHash must match actual previous raw line for id.
    for (let i = 1; i < markLines.length; i += 1) {
      const rec = markParsed[i];
      assert(typeof rec.previousRecordHash === "string", `mark line ${i} missing previousRecordHash`);
      // Find previous line for same id (immediately prior occurrence).
      let prevRaw = null;
      for (let j = i - 1; j >= 0; j -= 1) {
        if (markParsed[j].id === rec.id) {
          prevRaw = markLines[j];
          break;
        }
      }
      assert(prevRaw !== null, `no previous line for mark at ${i}`);
      assert(
        sha256Hex(prevRaw) === rec.previousRecordHash,
        `mark line ${i} previousRecordHash does not match prior raw line (linearization/CAS broken)`,
      );
    }
    const markList = JSON.parse((await spawnWorker(["list"], markEnv)).stdout);
    assert(markList.count === 1, "mark-race latest count");
    assert(["fixed", "accepted"].includes(markList.findings[0].status), "final status one of the two marks");
    assert(markList.forkedIds.length === 0, "lock-serialized marks must not report forked");

    // --- ④ reader-during-append ---
    const readerDir = join(tempRoot, "reader-append");
    const readerEnv = { ...process.env, TATWO_SECURITY_STATE_DIR: readerDir };
    const writerJobs = [];
    for (let i = 0; i < 12; i += 1) {
      writerJobs.push(
        spawnWorker(
          [
            "add",
            "--json",
            JSON.stringify(
              sampleFinding({
                id: `finding-reader-${i}`,
                title: `reader-append-${i}`,
                detail: `row ${i}`,
              }),
            ),
          ],
          readerEnv,
        ),
      );
    }
    // Interleave readers while writers run.
    const readerJobs = [];
    for (let i = 0; i < 8; i += 1) {
      readerJobs.push(spawnWorker(["list"], readerEnv));
    }
    const writerResults = await Promise.all(writerJobs);
    const readerResults = await Promise.all(readerJobs);
    for (const wr of writerResults) {
      assert(wr.status === 0, `reader-during-append writer failed: ${wr.stderr || wr.stdout}`);
    }
    for (const rr of readerResults) {
      assert(rr.status === 0, `reader-during-append list failed: ${rr.stderr || rr.stdout}`);
      const body = JSON.parse(rr.stdout);
      assert(body.ok === true, "reader list ok");
      assert(typeof body.count === "number", "reader count");
    }
    const finalReader = JSON.parse((await spawnWorker(["list"], readerEnv)).stdout);
    assert(finalReader.count === 12, `reader-during-append final count expected 12, got ${finalReader.count}`);

    // --- ⑤ crash partial tail (hand-written incomplete line) ---
    const partialDir = join(tempRoot, "partial-tail");
    const partialEnv = { ...process.env, TATWO_SECURITY_STATE_DIR: partialDir };
    const partialAdd = await spawnWorker(
      ["add", "--json", JSON.stringify(sampleFinding({ id: "finding-partial", title: "partial-ok" }))],
      partialEnv,
    );
    assert(partialAdd.status === 0, `partial setup add failed: ${partialAdd.stderr || partialAdd.stdout}`);
    const partialPath = join(partialDir, "findings.jsonl");
    // Incomplete JSON tail (no closing brace / no newline) simulating crash mid-write.
    appendFileSync(partialPath, '{"id":"finding-partial","status":"fixed","title":"CRASHED', "utf8");
    const partialList = await spawnWorker(["list"], partialEnv);
    assert(partialList.status === 0, `partial tail list should not crash: ${partialList.stderr || partialList.stdout}`);
    assert(
      /incomplete trailing line/i.test(partialList.stderr),
      `expected incomplete trailing warning, stderr=${partialList.stderr}`,
    );
    const partialBody = JSON.parse(partialList.stdout);
    assert(partialBody.count === 1, "partial tail should keep prior complete records");
    assert(partialBody.findings[0].status === "open", "latest complete status still open");
    assert(partialBody.incompleteTrailingLineIgnored === true, "flag incompleteTrailingLineIgnored");

    // Ensure real default dir was not required / selftest isolated.
    assert(String(env.TATWO_SECURITY_STATE_DIR).startsWith(tempRoot), "selftest must use temp state dir");

    console.log("SELFTEST PASS");
  } finally {
    try {
      rmSync(tempRoot, { recursive: true, force: true });
    } catch {
      // best-effort cleanup of temp selftest dir only
    }
  }
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.command === "selftest") {
    await runSelftest();
    return;
  }

  const stateDir = resolveStateDir();
  const flags = parsed.flags || {};
  const positionals = parsed.positionals || [];

  if (parsed.command === "add") {
    cmdAdd(stateDir, flags);
    return;
  }
  if (parsed.command === "list") {
    cmdList(stateDir, flags);
    return;
  }
  if (parsed.command === "mark") {
    cmdMark(stateDir, flags, positionals);
    return;
  }
  throw new Error(`unknown command: ${parsed.command}`);
}

try {
  await main();
} catch (error) {
  usage(error.message);
  process.exitCode = 1;
}
