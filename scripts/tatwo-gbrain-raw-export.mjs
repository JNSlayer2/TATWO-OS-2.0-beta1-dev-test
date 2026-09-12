#!/usr/bin/env node
/**
 * GBrain S2 — OS receipt → raw sources export (filesystem lane).
 *
 * Zero dependency. Default is --dry-run (plan only). Real writes require --commit
 * and TATWO_GBRAIN_SOURCES_ROOT (never hardcode volume paths).
 *
 * Usage:
 *   TATWO_GBRAIN_SOURCES_ROOT=<_sources> node scripts/tatwo-gbrain-raw-export.mjs \
 *     --receipts-dir receipts/plg-xxl-20260730 --run-id plg-xxl-20260730
 *   … --commit
 *   node scripts/tatwo-gbrain-raw-export.mjs --selftest
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import {
  basename,
  extname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";

const SOURCES_ENV = "TATWO_GBRAIN_SOURCES_ROOT";
/** Override path for commit-root allowlist (selftest / non-home fixtures). */
const ALLOWLIST_ENV = "TATWO_GBRAIN_ALLOWLIST_FILE";
const RECEIPT_EXTS = new Set([".md", ".jsonl"]);
/** Layout sanity marker under a GBrain `_sources` root (warning only; not authority). */
const SOURCES_MARKER = ".tatwo-gbrain-sources-v1";
/** Known layout children used for sanity warning when marker is absent. */
const KNOWN_SOURCES_CHILDREN = new Set([
  "inbox",
  "raw",
  "reports",
  "pages",
  "artifacts",
  "curated",
]);
const EXPORT_NOTES_MARKER = "\n---\n\n## Tatwo OS raw export notes";

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(`Usage:
  ${SOURCES_ENV}=<_sources> node scripts/tatwo-gbrain-raw-export.mjs \\
    --receipts-dir <path> --run-id <id> [--dry-run|--commit]

  node scripts/tatwo-gbrain-raw-export.mjs --selftest

Defaults: --dry-run (no writes). --commit performs writes under $ROOT/tatwo-os/<run-id>/.
--commit requires the realpath root on the allowlist file
  (default: $HOME/.tatwo-ultrawork/gbrain-roots.allow; one absolute path per line;
   override with ${ALLOWLIST_ENV}).
`);
}

function defaultAllowlistPath() {
  const home = process.env.HOME || "";
  return join(home, ".tatwo-ultrawork", "gbrain-roots.allow");
}

function resolveAllowlistPath() {
  const override = process.env[ALLOWLIST_ENV];
  if (override && String(override).trim()) {
    return resolve(String(override).trim());
  }
  return defaultAllowlistPath();
}

/**
 * Load absolute roots from allowlist. Returns null when the file is missing.
 * Lines: absolute paths; blank and # comments ignored.
 */
function loadAllowlistRoots(filePath) {
  if (!existsSync(filePath)) return null;
  const text = readFileSync(filePath, "utf8");
  const roots = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    roots.push(resolve(line));
  }
  return roots;
}

function allowlistHowToAdd(filePath, canonicalRoot) {
  return [
    `Add this absolute path as a single line in the allowlist file:`,
    `  ${canonicalRoot}`,
    `Allowlist path: ${filePath}`,
    `Example (operator-owned; do not invent home writes from automation):`,
    `  mkdir -p "$(dirname '${filePath}')" && printf '%s\\n' '${canonicalRoot}' >> '${filePath}'`,
  ].join("\n");
}

/**
 * Commit-time authority: root must appear on the out-of-repo allowlist.
 * File missing or root absent → refuse (fail closed).
 */
function requireRootOnAllowlist(canonicalRoot) {
  const filePath = resolveAllowlistPath();
  const roots = loadAllowlistRoots(filePath);
  if (roots === null) {
    throw new Error(
      `GBrain commit refused: allowlist file missing (${filePath}).\n` +
        allowlistHowToAdd(filePath, canonicalRoot),
    );
  }
  const allowed = new Set();
  for (const entry of roots) {
    try {
      if (existsSync(entry)) {
        allowed.add(realpathSync(entry));
      } else {
        allowed.add(resolve(entry));
      }
    } catch {
      allowed.add(resolve(entry));
    }
  }
  if (!allowed.has(canonicalRoot)) {
    throw new Error(
      `GBrain commit refused: root not on allowlist (${filePath}): ${canonicalRoot}\n` +
        allowlistHowToAdd(filePath, canonicalRoot),
    );
  }
}

function parseArgs(argv) {
  const out = {
    receiptsDir: null,
    runId: null,
    dryRun: true,
    commit: false,
    selftest: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") out.help = true;
    else if (a === "--selftest") out.selftest = true;
    else if (a === "--dry-run") {
      out.dryRun = true;
      out.commit = false;
    } else if (a === "--commit") {
      out.commit = true;
      out.dryRun = false;
    } else if (a === "--receipts-dir") {
      out.receiptsDir = argv[++i];
    } else if (a === "--run-id") {
      out.runId = argv[++i];
    } else if (a.startsWith("--receipts-dir=")) {
      out.receiptsDir = a.slice("--receipts-dir=".length);
    } else if (a.startsWith("--run-id=")) {
      out.runId = a.slice("--run-id=".length);
    } else {
      throw new Error(`unknown argument: ${a}`);
    }
  }
  return out;
}

function sha256Hex(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function assertSafeRunId(runId) {
  if (!runId || typeof runId !== "string") {
    throw new Error("--run-id is required");
  }
  if (runId.includes("..") || runId.includes("/") || runId.includes("\\") || runId.includes("\0")) {
    throw new Error(`--run-id must be a single path segment (no separators): ${runId}`);
  }
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId)) {
    throw new Error(`--run-id has invalid characters: ${runId}`);
  }
}

/**
 * GBrain `_sources` root gate.
 * - must exist + be a directory
 * - realpath basename must be `_sources` (no arbitrary writable path)
 * - layout marker / known children = sanity warning only (not authority)
 * - --commit requires out-of-repo allowlist pin (see requireRootOnAllowlist)
 */
function requireSourcesRoot(envValue, { requireAllowlist = false } = {}) {
  if (!envValue || !String(envValue).trim()) {
    throw new Error(`${SOURCES_ENV} is required (GBrain _sources root; do not hardcode volume paths)`);
  }
  const resolved = resolve(String(envValue).trim());
  if (!existsSync(resolved)) {
    throw new Error(`${SOURCES_ENV} does not exist: refuse non-GBrain root`);
  }
  let st;
  try {
    st = lstatSync(resolved);
  } catch {
    throw new Error(`${SOURCES_ENV} unreadable: refuse non-GBrain root`);
  }
  if (!st.isDirectory() && !st.isSymbolicLink()) {
    throw new Error(`${SOURCES_ENV} is not a directory: refuse non-GBrain root`);
  }
  let canonical;
  try {
    canonical = realpathSync(resolved);
  } catch {
    throw new Error(`${SOURCES_ENV} cannot be realpath'd: refuse non-GBrain root`);
  }
  if (!statSync(canonical).isDirectory()) {
    throw new Error(`${SOURCES_ENV} realpath is not a directory: refuse non-GBrain root`);
  }
  if (basename(canonical) !== "_sources") {
    throw new Error(
      `${SOURCES_ENV} basename must be _sources (got ${basename(canonical)}); refuse non-GBrain root`,
    );
  }
  if (!hasSourcesLayoutSanity(canonical)) {
    console.warn(
      `Warning: ${SOURCES_ENV} missing layout marker (${SOURCES_MARKER}) or known layout children at ${canonical}; ` +
        `continuing (marker is sanity-only; --commit authority is the allowlist)`,
    );
  }
  if (requireAllowlist) {
    requireRootOnAllowlist(canonical);
  }
  return canonical;
}

function hasSourcesLayoutSanity(canonicalDir) {
  if (existsSync(join(canonicalDir, SOURCES_MARKER))) return true;
  try {
    const kids = readdirSync(canonicalDir);
    return kids.some((name) => KNOWN_SOURCES_CHILDREN.has(name));
  } catch {
    return false;
  }
}

function writeSourcesMarker(sourcesRoot) {
  writeFileSync(
    join(sourcesRoot, SOURCES_MARKER),
    "TatwoGBrainSourcesRootV1\n",
    "utf8",
  );
}

function listReceiptFiles(receiptsDir) {
  const abs = resolve(receiptsDir);
  if (!existsSync(abs) || !statSync(abs).isDirectory()) {
    throw new Error(`receipts dir not found or not a directory: ${abs}`);
  }
  const names = readdirSync(abs).filter((name) => {
    if (name.startsWith(".")) return false;
    const ext = extname(name).toLowerCase();
    if (!RECEIPT_EXTS.has(ext)) return false;
    const full = join(abs, name);
    return statSync(full).isFile();
  });
  names.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return names.map((name) => ({
    name,
    path: join(abs, name),
  }));
}

function gitNote(cwd) {
  try {
    const commit = execFileSync("git", ["rev-parse", "HEAD"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    let branch = "";
    try {
      branch = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
        cwd,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      }).trim();
    } catch {
      branch = "detached";
    }
    return { commit, branch, available: true };
  } catch {
    return { commit: null, branch: null, available: false };
  }
}

function sourcePathNote(sourcePath, cwdHint) {
  try {
    if (cwdHint) {
      const rel = relative(cwdHint, sourcePath);
      if (rel && !rel.startsWith("..") && !isAbsolute(rel)) {
        return rel.split(sep).join("/");
      }
    }
  } catch {
    // fall through
  }
  // Prefer basename-only when path looks like a private absolute home/volume path
  return basename(sourcePath);
}

function titleFromReceipt(name, body) {
  const base = name.replace(/\.(md|jsonl)$/i, "");
  if (/\.md$/i.test(name)) {
    for (const line of body.split(/\r?\n/)) {
      const m = line.match(/^#\s+(.+)\s*$/);
      if (m) return m[1].trim().slice(0, 200);
    }
  }
  return `OS receipt: ${base}`;
}

function yamlQuote(value) {
  // Safe single-line YAML double-quoted string
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function buildRawPage({
  sourceName,
  sourcePath,
  body,
  runId,
  git,
  capturedAt,
  contentHashOfBody,
  cwdHint,
}) {
  const title = titleFromReceipt(sourceName, body);
  const sourceRel = sourcePathNote(sourcePath, cwdHint);
  const tags = ["tatwo-os", "receipts", runId];
  const front = [
    "---",
    "type: report",
    `title: ${yamlQuote(title)}`,
    `tags: [${tags.map((t) => yamlQuote(t)).join(", ")}]`,
    "layer: raw",
    `topic: ${yamlQuote(`tatwo-os-receipt-${runId}`)}`,
    `source_receipt: ${yamlQuote(sourceRel)}`,
    `captured_at: ${yamlQuote(capturedAt)}`,
    `run_id: ${yamlQuote(runId)}`,
    `source_content_sha256: ${yamlQuote(contentHashOfBody)}`,
    "---",
    "",
  ].join("\n");

  const notes = [
    "",
    "---",
    "",
    "## Tatwo OS raw export notes",
    "",
    `- **source_path**: \`${sourceRel}\``,
    `- **source_basename**: \`${sourceName}\``,
    `- **run_id**: \`${runId}\``,
    `- **captured_at**: \`${capturedAt}\``,
    `- **source_content_sha256**: \`${contentHashOfBody}\``,
    git.available
      ? `- **git**: commit \`${git.commit}\` branch \`${git.branch}\``
      : "- **git**: unavailable (export without repository context)",
    "- **lane**: system delivery → GBrain `_sources` raw (immutable; hash-equal skip; conflict → `-vN`)",
    "",
  ].join("\n");

  return front + body.replace(/\s*$/, "") + notes;
}

function outputBaseName(sourceName) {
  // foo.md → foo.md; bar.jsonl → bar.jsonl.md
  if (/\.md$/i.test(sourceName)) return sourceName;
  return `${sourceName}.md`;
}

function versionedName(baseName, version) {
  if (version <= 1) return baseName;
  // foo.md → foo-v2.md; bar.jsonl.md → bar.jsonl-v2.md
  if (baseName.toLowerCase().endsWith(".md")) {
    const stem = baseName.slice(0, -3);
    return `${stem}-v${version}.md`;
  }
  return `${baseName}-v${version}`;
}

/**
 * Extract the embedded source receipt body from a previously exported raw page.
 * Does **not** trust frontmatter `source_content_sha256` self-report.
 * Returns null when the envelope cannot be parsed (caller must not skip).
 */
function extractEmbeddedSourceBody(pageText) {
  const text = String(pageText);
  if (!text.startsWith("---\n")) return null;
  const fmEnd = text.indexOf("\n---\n", 4);
  if (fmEnd < 0) return null;
  const afterFront = text.slice(fmEnd + "\n---\n".length);
  const notesIdx = afterFront.lastIndexOf(EXPORT_NOTES_MARKER);
  if (notesIdx < 0) return null;
  return afterFront.slice(0, notesIdx);
}

/**
 * Idempotency: full page hash, else recompute hash of embedded body (not frontmatter field).
 * Volatile fields (captured_at, live git tip) must not force -vN on true re-export.
 */
function existingIsSameContent(existingText, rawBody, pageHash) {
  if (sha256Hex(existingText) === pageHash) return true;
  const embedded = extractEmbeddedSourceBody(existingText);
  if (embedded === null) return false;
  const strippedNew = String(rawBody).replace(/\s*$/, "");
  // Compare both exact embedded text and content hash of stripped bodies.
  if (embedded === strippedNew) return true;
  return sha256Hex(embedded) === sha256Hex(strippedNew);
}

function planOneFile({ file, runId, sourcesRoot, git, capturedAt, cwdHint, dryRun }) {
  const rawBody = readFileSync(file.path, "utf8");
  const bodyHash = sha256Hex(rawBody);
  const page = buildRawPage({
    sourceName: file.name,
    sourcePath: file.path,
    body: rawBody,
    runId,
    git,
    capturedAt,
    contentHashOfBody: bodyHash,
    cwdHint,
  });
  const pageHash = sha256Hex(page);
  const destDir = join(sourcesRoot, "tatwo-os", runId);
  const baseName = outputBaseName(file.name);

  let version = 1;
  let action = "write";
  let destPath = join(destDir, versionedName(baseName, version));
  let note = "";

  // Walk versions until free slot or identical source content
  while (existsSync(destPath)) {
    const existing = readFileSync(destPath, "utf8");
    if (existingIsSameContent(existing, rawBody, pageHash)) {
      action = "skip";
      note = "identical source content (recomputed body hash); raw immutable skip";
      break;
    }
    version += 1;
    destPath = join(destDir, versionedName(baseName, version));
    action = version === 2 ? "write-v2" : `write-v${version}`;
    note = `existing content differs; refuse overwrite (raw immutability)`;
  }

  if (action !== "skip" && dryRun) {
    action = action === "write" ? "plan-write" : `plan-${action}`;
  }

  return {
    source: file.name,
    sourcePath: sourcePathNote(file.path, cwdHint),
    destPath,
    destRel: join("tatwo-os", runId, basename(destPath)).split(sep).join("/"),
    action,
    note,
    pageHash,
    bodyHash,
    page,
    destDir,
    rawBody,
  };
}

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
}

function applyPlan(items, dryRun) {
  const results = [];
  for (const item of items) {
    if (item.action === "skip" || item.action.startsWith("plan-")) {
      results.push({ ...item, wrote: false });
      continue;
    }
    if (dryRun) {
      results.push({ ...item, wrote: false });
      continue;
    }
    ensureDir(item.destDir);
    if (existsSync(item.destPath)) {
      // Race / double-check: never overwrite
      const existingText = readFileSync(item.destPath, "utf8");
      if (existingIsSameContent(existingText, item.rawBody, item.pageHash)) {
        results.push({ ...item, action: "skip", wrote: false, note: "identical at write time" });
        continue;
      }
      throw new Error(`refuse overwrite of existing raw page: ${item.destPath}`);
    }
    writeFileSync(item.destPath, item.page, { encoding: "utf8", flag: "wx" });
    results.push({ ...item, wrote: true });
  }
  return results;
}

function printPlan(summary) {
  const lines = [];
  lines.push(`GBrain raw export ${summary.mode}`);
  lines.push(`${SOURCES_ENV}=${summary.sourcesRootDisplay}`);
  lines.push(`run-id=${summary.runId}`);
  lines.push(`receipts-dir=${summary.receiptsDirDisplay}`);
  lines.push(`files_scanned=${summary.filesScanned}`);
  lines.push(`plan_write=${summary.counts.planWrite + summary.counts.write}`);
  lines.push(`skip_identical=${summary.counts.skip}`);
  lines.push(`versioned=${summary.counts.versioned}`);
  lines.push(`wrote=${summary.counts.wrote}`);
  lines.push("---");
  for (const item of summary.items) {
    lines.push(
      [
        item.action.padEnd(12),
        item.source,
        "→",
        item.destRel,
        item.note ? `(${item.note})` : "",
      ]
        .filter(Boolean)
        .join(" "),
    );
  }
  console.log(lines.join("\n"));
}

function runExport({ receiptsDir, runId, dryRun, sourcesRoot, cwdHint }) {
  assertSafeRunId(runId);
  // --commit authority is the allowlist; dry-run may plan without it.
  const root = requireSourcesRoot(sourcesRoot, { requireAllowlist: !dryRun });
  const files = listReceiptFiles(receiptsDir);
  const git = gitNote(cwdHint || process.cwd());
  const capturedAt = new Date().toISOString();
  const planned = files.map((file) =>
    planOneFile({
      file,
      runId,
      sourcesRoot: root,
      git,
      capturedAt,
      cwdHint: cwdHint || process.cwd(),
      dryRun,
    }),
  );
  const applied = applyPlan(planned, dryRun);
  const counts = {
    planWrite: 0,
    write: 0,
    skip: 0,
    versioned: 0,
    wrote: 0,
  };
  for (const item of applied) {
    if (item.action === "skip") counts.skip += 1;
    else if (item.action.startsWith("plan-write")) {
      counts.planWrite += 1;
      if (item.action.includes("v")) counts.versioned += 1;
    } else if (item.action.startsWith("write")) {
      counts.write += 1;
      if (item.action.includes("v")) counts.versioned += 1;
    }
    if (item.wrote) counts.wrote += 1;
  }
  return {
    mode: dryRun ? "dry-run" : "commit",
    sourcesRoot: root,
    sourcesRootDisplay: root, // caller may sanitize in receipts; script itself needs real path for writes
    receiptsDir: resolve(receiptsDir),
    receiptsDirDisplay: resolve(receiptsDir),
    runId,
    filesScanned: files.length,
    counts,
    items: applied.map(({ page, rawBody, ...rest }) => rest),
    git,
  };
}

function assert(cond, message) {
  if (!cond) throw new Error(`selftest assertion failed: ${message}`);
}

function selftest() {
  const base = mkdtempSync(join(tmpdir(), "tatwo-gbrain-raw-export-"));
  const sourcesRoot = join(base, "_sources");
  const receiptsDir = join(base, "receipts");
  const runId = "selftest-run";
  const allowlistPath = join(base, "gbrain-roots.allow");
  const previousAllowlistEnv = process.env[ALLOWLIST_ENV];
  try {
    mkdirSync(sourcesRoot, { recursive: true });
    writeSourcesMarker(sourcesRoot);
    mkdirSync(receiptsDir, { recursive: true });
    // Selftest never writes the operator home allowlist; override path only.
    process.env[ALLOWLIST_ENV] = allowlistPath;
    writeFileSync(allowlistPath, `${sourcesRoot}\n`, "utf8");
    writeFileSync(
      join(receiptsDir, "sample-receipt.md"),
      "# Sample receipt\n\nstatus: ok\n",
      "utf8",
    );
    writeFileSync(
      join(receiptsDir, "notes.jsonl"),
      '{"k":1}\n{"k":2}\n',
      "utf8",
    );

    // 1) dry-run default: no files under sources (no allowlist required)
    const dry = runExport({
      receiptsDir,
      runId,
      dryRun: true,
      sourcesRoot,
      cwdHint: base,
    });
    assert(dry.mode === "dry-run", "mode dry-run");
    assert(dry.filesScanned === 2, `filesScanned=2 got ${dry.filesScanned}`);
    assert(dry.counts.wrote === 0, "dry-run wrote=0");
    assert(
      !existsSync(join(sourcesRoot, "tatwo-os", runId, "sample-receipt.md")),
      "dry-run must not create dest",
    );
    for (const item of dry.items) {
      assert(item.action.startsWith("plan-") || item.action === "skip", `dry action ${item.action}`);
      assert(item.destRel.startsWith(`tatwo-os/${runId}/`), "dest under tatwo-os/run-id");
    }

    // 2) commit writes (root on allowlist)
    const first = runExport({
      receiptsDir,
      runId,
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    assert(first.counts.wrote === 2, `first wrote=2 got ${first.counts.wrote}`);
    const destMd = join(sourcesRoot, "tatwo-os", runId, "sample-receipt.md");
    const destJsonl = join(sourcesRoot, "tatwo-os", runId, "notes.jsonl.md");
    assert(existsSync(destMd), "sample-receipt.md written");
    assert(existsSync(destJsonl), "notes.jsonl.md written");
    const page1 = readFileSync(destMd, "utf8");
    assert(page1.startsWith("---\n"), "front-matter present");
    assert(page1.includes("type: report"), "type report");
    assert(page1.includes("tatwo-os"), "tag tatwo-os");
    assert(page1.includes("receipts"), "tag receipts");
    assert(page1.includes(runId), "tag run-id");
    assert(page1.includes("# Sample receipt"), "body preserved");
    assert(page1.includes("source_path"), "source path note");
    assert(page1.includes("layer: raw"), "layer raw");

    // 3) idempotent: second commit skips identical
    const second = runExport({
      receiptsDir,
      runId,
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    assert(second.counts.skip === 2, `second skip=2 got ${second.counts.skip}`);
    assert(second.counts.wrote === 0, "second wrote=0");

    // 4) content change → -v2 without overwrite
    writeFileSync(
      join(receiptsDir, "sample-receipt.md"),
      "# Sample receipt\n\nstatus: changed\n",
      "utf8",
    );
    const third = runExport({
      receiptsDir,
      runId,
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    const v2 = join(sourcesRoot, "tatwo-os", runId, "sample-receipt-v2.md");
    assert(existsSync(v2), "v2 written on content change");
    assert(readFileSync(destMd, "utf8") === page1, "original not overwritten");
    const v2page = readFileSync(v2, "utf8");
    assert(v2page.includes("status: changed"), "v2 has new body");
    const changedItem = third.items.find((i) => i.source === "sample-receipt.md");
    assert(changedItem && changedItem.wrote, "changed item wrote");
    assert(changedItem.action === "write-v2" || changedItem.destRel.endsWith("sample-receipt-v2.md"), "action write-v2");

    // 5) missing env fails closed
    let envFailed = false;
    try {
      runExport({
        receiptsDir,
        runId,
        dryRun: true,
        sourcesRoot: "",
        cwdHint: base,
      });
    } catch (error) {
      envFailed = /TATWO_GBRAIN_SOURCES_ROOT/.test(String(error.message));
    }
    assert(envFailed, "empty sources root fails closed");

    // 6) adversarial: wrong root (not basename _sources) refused — no write
    const wrongRoot = join(base, "not-gbrain-root");
    mkdirSync(wrongRoot, { recursive: true });
    let wrongRootFailed = false;
    try {
      runExport({
        receiptsDir,
        runId: "wrong-root-probe",
        dryRun: false,
        sourcesRoot: wrongRoot,
        cwdHint: base,
      });
    } catch (error) {
      wrongRootFailed = /refuse non-GBrain root|_sources/.test(String(error.message));
    }
    assert(wrongRootFailed, "wrong root basename must fail closed");
    assert(
      !existsSync(join(wrongRoot, "tatwo-os", "wrong-root-probe")),
      "wrong root must not receive writes",
    );

    // 7) allowlist three-state (TATWO_GBRAIN_ALLOWLIST_FILE override; no real home writes)
    // 7a) missing allowlist file → commit refuse
    const missingAllow = join(base, "missing-allowlist.allow");
    process.env[ALLOWLIST_ENV] = missingAllow;
    if (existsSync(missingAllow)) rmSync(missingAllow);
    let missingFailed = false;
    let missingMsg = "";
    try {
      runExport({
        receiptsDir,
        runId: "allow-missing-probe",
        dryRun: false,
        sourcesRoot,
        cwdHint: base,
      });
    } catch (error) {
      missingMsg = String(error.message);
      missingFailed = /allowlist file missing|commit refused/.test(missingMsg);
    }
    assert(missingFailed, "commit with missing allowlist must fail closed");
    assert(/How to|Add this absolute path|Example/i.test(missingMsg), "missing allowlist prints how-to");

    // 7b) allowlist exists but root not listed → refuse
    const otherOnly = join(base, "other-only.allow");
    writeFileSync(otherOnly, `${join(base, "other", "_sources")}\n`, "utf8");
    process.env[ALLOWLIST_ENV] = otherOnly;
    let notListedFailed = false;
    let notListedMsg = "";
    try {
      runExport({
        receiptsDir,
        runId: "allow-notlisted-probe",
        dryRun: false,
        sourcesRoot,
        cwdHint: base,
      });
    } catch (error) {
      notListedMsg = String(error.message);
      notListedFailed = /not on allowlist|commit refused/.test(notListedMsg);
    }
    assert(notListedFailed, "commit with root not on allowlist must fail closed");
    assert(/Add this absolute path/i.test(notListedMsg), "not-listed prints how-to");

    // 7c) root listed → commit allowed
    process.env[ALLOWLIST_ENV] = allowlistPath;
    writeFileSync(allowlistPath, `${sourcesRoot}\n`, "utf8");
    const allowOk = runExport({
      receiptsDir,
      runId: "allow-ok-probe",
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    assert(allowOk.counts.wrote >= 1, "allowlisted root commit writes");
    assert(
      existsSync(join(sourcesRoot, "tatwo-os", "allow-ok-probe")),
      "allowlisted commit dest exists",
    );

    // 8) bare _sources without marker: marker is warning-only; allowlist is authority.
    //    Without allowlist → refuse. With allowlist → commit may proceed.
    const bareSources = join(base, "bare-tree", "_sources");
    mkdirSync(bareSources, { recursive: true });
    process.env[ALLOWLIST_ENV] = join(base, "bare-missing.allow");
    if (existsSync(process.env[ALLOWLIST_ENV])) rmSync(process.env[ALLOWLIST_ENV]);
    let bareNoAllowFailed = false;
    try {
      runExport({
        receiptsDir,
        runId: "bare-sources-probe",
        dryRun: false,
        sourcesRoot: bareSources,
        cwdHint: base,
      });
    } catch (error) {
      bareNoAllowFailed = /allowlist|commit refused/.test(String(error.message));
    }
    assert(bareNoAllowFailed, "bare _sources commit without allowlist must fail");
    const bareAllow = join(base, "bare.allow");
    writeFileSync(bareAllow, `${bareSources}\n`, "utf8");
    process.env[ALLOWLIST_ENV] = bareAllow;
    const bareOk = runExport({
      receiptsDir,
      runId: "bare-allow-probe",
      dryRun: false,
      sourcesRoot: bareSources,
      cwdHint: base,
    });
    assert(bareOk.counts.wrote >= 1, "allowlisted bare _sources (no marker) may commit");
    // restore primary allowlist for remaining probes
    process.env[ALLOWLIST_ENV] = allowlistPath;
    writeFileSync(allowlistPath, `${sourcesRoot}\n`, "utf8");

    // 9) adversarial: tampered body with preserved frontmatter source_content_sha256
    //    must NOT skip — recomputed embedded body hash differs → write-vN
    const tamperRun = "tamper-hash-run";
    const tamperReceipts = join(base, "tamper-receipts");
    mkdirSync(tamperReceipts, { recursive: true });
    writeFileSync(join(tamperReceipts, "t.md"), "# T\n\nbody-a\n", "utf8");
    const tamperFirst = runExport({
      receiptsDir: tamperReceipts,
      runId: tamperRun,
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    assert(tamperFirst.counts.wrote === 1, "tamper first wrote=1");
    const tamperDest = join(sourcesRoot, "tatwo-os", tamperRun, "t.md");
    const originalPage = readFileSync(tamperDest, "utf8");
    // Preserve frontmatter (incl. source_content_sha256) but alter embedded body.
    const fmEnd = originalPage.indexOf("\n---\n", 4);
    assert(fmEnd > 0, "tamper fixture has frontmatter");
    const front = originalPage.slice(0, fmEnd + "\n---\n".length);
    const notesIdx = originalPage.lastIndexOf(EXPORT_NOTES_MARKER);
    assert(notesIdx > 0, "tamper fixture has notes marker");
    const notes = originalPage.slice(notesIdx);
    const forged = front + "# T\n\nbody-TAMPERED\n" + notes;
    // Ensure forged still claims the old body hash in frontmatter if present.
    assert(/source_content_sha256:/.test(forged), "frontmatter hash field present");
    writeFileSync(tamperDest, forged, "utf8");
    // Re-export same source body-a: should detect tamper via recompute, write -v2
    const tamperSecond = runExport({
      receiptsDir: tamperReceipts,
      runId: tamperRun,
      dryRun: false,
      sourcesRoot,
      cwdHint: base,
    });
    const tamperV2 = join(sourcesRoot, "tatwo-os", tamperRun, "t-v2.md");
    assert(existsSync(tamperV2), "tampered body with forged frontmatter hash must not skip");
    assert(tamperSecond.counts.skip === 0, "tamper second skip=0");
    assert(tamperSecond.counts.wrote === 1, "tamper second wrote=1 (v2)");
    assert(readFileSync(tamperDest, "utf8") === forged, "forged page not overwritten");

    // 10) adversarial: symlink to _sources not on allowlist must fail closed on commit
    //     (marker alone is not authority).
    const linkParent = join(base, "link-parent");
    mkdirSync(linkParent, { recursive: true });
    const untrustedSources = join(base, "untrusted", "_sources");
    mkdirSync(untrustedSources, { recursive: true });
    writeSourcesMarker(untrustedSources);
    const linkPath = join(linkParent, "_sources");
    try {
      symlinkSync(untrustedSources, linkPath);
    } catch (error) {
      // Some sandboxes block symlink; record as soft-skip of this probe only.
      console.log(`selftest note: symlink probe skipped (${error.message})`);
    }
    if (existsSync(linkPath)) {
      let linkFailed = false;
      try {
        runExport({
          receiptsDir,
          runId: "symlink-root-probe",
          dryRun: false,
          sourcesRoot: linkPath,
          cwdHint: base,
        });
      } catch (error) {
        linkFailed = /allowlist|commit refused|refuse non-GBrain root/.test(
          String(error.message),
        );
      }
      assert(linkFailed, "symlink to non-allowlisted _sources must fail closed");
    }

    console.log("SELFTEST PASS");
    return 0;
  } finally {
    if (previousAllowlistEnv === undefined) {
      delete process.env[ALLOWLIST_ENV];
    } else {
      process.env[ALLOWLIST_ENV] = previousAllowlistEnv;
    }
    try {
      rmSync(base, { recursive: true, force: true });
    } catch {
      // ignore cleanup errors
    }
  }
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (error) {
    usage(error.message);
    process.exit(2);
  }

  if (args.help) {
    usage();
    process.exit(0);
  }

  if (args.selftest) {
    try {
      process.exit(selftest());
    } catch (error) {
      console.error(String(error && error.stack ? error.stack : error));
      console.error("SELFTEST FAIL");
      process.exit(1);
    }
  }

  if (!args.receiptsDir || !args.runId) {
    usage("--receipts-dir and --run-id are required (or use --selftest)");
    process.exit(2);
  }

  try {
    const summary = runExport({
      receiptsDir: args.receiptsDir,
      runId: args.runId,
      dryRun: args.dryRun,
      sourcesRoot: process.env[SOURCES_ENV],
      cwdHint: process.cwd(),
    });
    printPlan(summary);
    process.exit(0);
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

main();
