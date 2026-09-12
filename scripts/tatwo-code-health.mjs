#!/usr/bin/env node

/**
 * Tatwo code-health scanner (zero-dependency Node).
 *
 * Mechanical subset of docs/protocol/CODE_HEALTH_RUBRIC_V2.md
 * (rubricVersion 2.2-ch02-final; source v1 missing).
 *
 * Usage:
 *   node scripts/tatwo-code-health.mjs scan [--root <path>] [--json]
 *     [--line-threshold 3000] [--line-threshold-critical 8000]
 *     [--authority-name-regex <re>]
 *     [--validation-name-regex <re>]
 *   node scripts/tatwo-code-health.mjs --selftest
 *
 * Findings are JSONL rows compatible with TatwoSecurityFindingV1
 * (see docs/protocol/SECURITY_SCAN_HARNESS.md §3) plus ruleId/rubricVersion.
 */

import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const RUBRIC_VERSION = "2.2-ch02-final";
const SCHEMA = "TatwoSecurityFindingV1";
const VERIFIED_BY = `tatwo-code-health@${RUBRIC_VERSION}`;
const SCRIPT_PATH = resolve(fileURLToPath(import.meta.url));

const DEFAULT_LINE_THRESHOLD = 3000;
const DEFAULT_LINE_THRESHOLD_CRITICAL = 8000;
const DEFAULT_AUTHORITY_NAME_RE =
  "Authority|Proof|Record|Authorization|Stamp|ValidationResult|PairingSession|JournalRecord|Receipt|Lease|Permit";
const DEFAULT_VALIDATION_NAME_RE =
  "authority|validation|validator|trust|proof|permit|gate|credential|signature|approval";
const DEFAULT_VALIDATION_TOKENS = new Set([
  "authority",
  "validation",
  "validator",
  "validators",
  "trust",
  "proof",
  "permit",
  "permits",
  "gate",
  "gates",
  "credential",
  "credentials",
  "signature",
  "signatures",
  "approval",
  "approvals",
]);

const SKIP_DIR_NAMES = new Set([
  ".git",
  ".build",
  "build",
  "DerivedData",
  "node_modules",
  ".swiftpm",
  "output",
  ".tatwo-security",
  ".tatwo-ultrawork",
  "xcuserdata",
  "Pods",
]);

const MANUAL_REVIEW_ITEMS = [
  "CH-07 revision-binding (stamp / bindingClass / artifacts semantics)",
  "CH-08 claimed-fix-noop (e.g. realpath empty loop — needs behavioral proof)",
  "CH-02/03 full observation integrity for a real test log (use tatwo-test-run.sh)",
  "CH-04 exploitability of public init / nil authority (semantic review)",
  "CH-06 delete/archive adjudication (trash + dual approval; never auto-delete)",
];

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(`Usage:
  node scripts/tatwo-code-health.mjs scan [--root <path>] [--json]
    [--line-threshold ${DEFAULT_LINE_THRESHOLD}]
    [--line-threshold-critical ${DEFAULT_LINE_THRESHOLD_CRITICAL}]
    [--authority-name-regex <re>]
    [--validation-name-regex <re>]
  node scripts/tatwo-code-health.mjs --selftest

Findings: TatwoSecurityFindingV1-compatible JSONL (rubric ${RUBRIC_VERSION}).
Source v1 baseline is missing; this implements reconstructed v2 mechanical subset.`);
}

function gitHead(cwd) {
  try {
    const r = spawnSync("git", ["rev-parse", "HEAD"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    const out = (r.stdout || "").trim();
    return out || "unknown";
  } catch {
    return "unknown";
  }
}

function gitTopLevel(cwd) {
  try {
    const r = spawnSync("git", ["rev-parse", "--show-toplevel"], {
      cwd,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return (r.stdout || "").trim() || null;
  } catch {
    return null;
  }
}

function sha256Short(text) {
  return createHash("sha256").update(String(text), "utf8").digest("hex").slice(0, 16);
}

function utcStamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function parseArgs(argv) {
  const options = {
    command: null,
    root: null,
    json: false,
    selftest: false,
    lineThreshold: DEFAULT_LINE_THRESHOLD,
    lineThresholdCritical: DEFAULT_LINE_THRESHOLD_CRITICAL,
    authorityNameRegex: DEFAULT_AUTHORITY_NAME_RE,
    validationNameRegex: DEFAULT_VALIDATION_NAME_RE,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      options.help = true;
      return options;
    }
    if (arg === "--selftest") {
      options.selftest = true;
      continue;
    }
    if (arg === "scan") {
      options.command = "scan";
      continue;
    }
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    const take = (label) => {
      if (i + 1 >= argv.length || String(argv[i + 1]).startsWith("--")) {
        throw new Error(`${label} requires a value`);
      }
      i += 1;
      return argv[i];
    };
    if (arg === "--root") {
      options.root = take(arg);
      continue;
    }
    if (arg === "--line-threshold") {
      options.lineThreshold = Number(take(arg));
      continue;
    }
    if (arg === "--line-threshold-critical") {
      options.lineThresholdCritical = Number(take(arg));
      continue;
    }
    if (arg === "--authority-name-regex") {
      options.authorityNameRegex = take(arg);
      continue;
    }
    if (arg === "--validation-name-regex") {
      options.validationNameRegex = take(arg);
      continue;
    }
    if (arg.startsWith("--root=")) {
      options.root = arg.slice("--root=".length);
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  if (
    !Number.isFinite(options.lineThreshold) ||
    options.lineThreshold < 1
  ) {
    throw new Error("--line-threshold must be a positive number");
  }
  if (
    !Number.isFinite(options.lineThresholdCritical) ||
    options.lineThresholdCritical < options.lineThreshold
  ) {
    throw new Error(
      "--line-threshold-critical must be >= --line-threshold",
    );
  }
  return options;
}

function shouldSkipDir(name) {
  return SKIP_DIR_NAMES.has(name) || name.startsWith(".");
}

function walkFiles(root, { extensions = null } = {}) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of entries) {
      const name = ent.name;
      const full = join(dir, name);
      if (ent.isDirectory()) {
        if (shouldSkipDir(name)) continue;
        stack.push(full);
        continue;
      }
      if (!ent.isFile()) continue;
      if (extensions) {
        const lower = name.toLowerCase();
        if (!extensions.some((ext) => lower.endsWith(ext))) continue;
      }
      out.push(full);
    }
  }
  return out.sort();
}

function isUnderSources(relPosix) {
  return /(?:^|\/)Sources\//.test(relPosix);
}

function isTestPath(relPosix) {
  return (
    /(?:^|\/)Tests\//.test(relPosix) ||
    /(?:^|\/)tests\//.test(relPosix) ||
    /\.test\.(mjs|js|sh|py)$/.test(relPosix) ||
    /Tests\.swift$/.test(relPosix)
  );
}

function toPosix(p) {
  return p.split(sep).join("/");
}

function countLines(text) {
  if (text.length === 0) return 0;
  let n = 1;
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) n += 1;
  }
  if (text.endsWith("\n")) n -= 1;
  return Math.max(n, 1);
}

function makeFinding({
  scanID,
  revision,
  ruleId,
  surface,
  severity,
  title,
  detail,
  needsHumanReview = false,
}) {
  const id = `ch-${ruleId.toLowerCase()}-${sha256Short(`${ruleId}|${surface}|${title}|${detail}`)}`;
  const finding = {
    schema: SCHEMA,
    id,
    scanID,
    revision,
    surface,
    severity,
    title,
    detail,
    status: "open",
    verifiedBy: VERIFIED_BY,
    firstSeenScan: scanID,
    lastSeenScan: scanID,
    ruleId,
    rubricVersion: RUBRIC_VERSION,
  };
  if (needsHumanReview) finding.needsHumanReview = true;
  return finding;
}

/** CH-01 god-file */
function scanGodFiles(root, relFiles, texts, opts, ctx) {
  const findings = [];
  for (const rel of relFiles) {
    if (!isUnderSources(rel)) continue;
    if (!rel.endsWith(".swift") && !rel.endsWith(".mjs")) continue;
    if (isTestPath(rel)) continue;
    const text = texts.get(rel);
    if (text == null) continue;
    const lines = countLines(text);
    if (lines < opts.lineThreshold) continue;
    const severity =
      lines >= opts.lineThresholdCritical ? "critical" : "high";
    findings.push(
      makeFinding({
        ...ctx,
        ruleId: "CH-01",
        surface: rel,
        severity,
        title: "god-file over line threshold",
        detail: `${rel} has ${lines} lines (threshold=${opts.lineThreshold}, critical=${opts.lineThresholdCritical}). Evidence class: ChatPage once ~13220 lines before split; large files remain review/diff hazards.`,
      }),
    );
  }
  return findings;
}

/**
 * Heuristic: path-like /Users/name or /Volumes/Name — not redaction regex char classes.
 */
function privatePathHits(line) {
  const hits = [];
  // Skip lines that look like redaction regex definitions
  if (
    /#\/Users\/|\/Users\/\[\^|replacingOccurrences\(of:\s*#"\/Users/.test(
      line,
    ) ||
    /#\/Volumes\/|\/Volumes\/\[\^/.test(line)
  ) {
    return hits;
  }
  const userRe = /\/Users\/[A-Za-z0-9._-]+(?:\/[^\s"'`\\]*)?/g;
  const volRe = /\/Volumes\/[A-Za-z0-9._-]+(?:[^\s"'`]*)?/g;
  for (const re of [userRe, volRe]) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(line)) !== null) {
      const frag = m[0];
      // Ignore pure placeholders
      if (/\/Users\/(?:example|user|name|xxx|private)\b/i.test(frag)) continue;
      hits.push(frag.slice(0, 120));
    }
  }
  return hits;
}

/** CH-05 private absolute paths in production Sources (+ script string defaults) */
function scanPrivatePaths(root, relFiles, texts, ctx) {
  const findings = [];
  for (const rel of relFiles) {
    const inSources = isUnderSources(rel);
    const inScripts = rel.startsWith("scripts/");
    if (!inSources && !inScripts) continue;
    if (isTestPath(rel)) continue;
    if (rel.endsWith(".md")) continue;
    // Avoid self-noise from this scanner's path regex literals / fixtures docs.
    if (rel.endsWith("tatwo-code-health.mjs")) continue;
    const text = texts.get(rel);
    if (text == null) continue;
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      const hits = privatePathHits(line);
      if (!hits.length) continue;
      findings.push(
        makeFinding({
          ...ctx,
          ruleId: "CH-05",
          surface: `${rel}:${i + 1}`,
          severity: inSources ? "high" : "medium",
          title: "private absolute path in production source",
          detail: `${rel}:${i + 1} contains private-looking path fragment(s): ${hits.join(", ")}. F10/SOL-3 class issue; prefer env/App Support injection.`,
        }),
      );
    }
  }
  return findings;
}

/** CH-04 public init on authority/proof/record-named types */
function swiftParameterClauses(text) {
  const clauses = [];
  const declarationRe =
    /\b(?:func\s+[A-Za-z_][A-Za-z0-9_]*|init|subscript)\s*(?:<[^>{}]*>\s*)?\(/g;
  let declaration;
  while ((declaration = declarationRe.exec(text)) !== null) {
    const openIndex = declarationRe.lastIndex - 1;
    let depth = 0;
    let closeIndex = -1;
    let quote = null;
    let escaped = false;
    for (let i = openIndex; i < text.length; i += 1) {
      const ch = text[i];
      if (quote) {
        if (escaped) {
          escaped = false;
        } else if (ch === "\\") {
          escaped = true;
        } else if (ch === quote) {
          quote = null;
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        continue;
      }
      if (ch === "(") depth += 1;
      if (ch === ")") {
        depth -= 1;
        if (depth === 0) {
          closeIndex = i;
          break;
        }
      }
    }
    if (closeIndex < 0) continue;
    clauses.push({
      text: text.slice(openIndex + 1, closeIndex),
      absoluteStart: openIndex + 1,
    });
    declarationRe.lastIndex = closeIndex + 1;
  }
  return clauses;
}

function splitTopLevelSwiftParameters(clauseText) {
  const parts = [];
  let start = 0;
  let paren = 0;
  let angle = 0;
  let bracket = 0;
  let brace = 0;
  let quote = null;
  let escaped = false;
  for (let i = 0; i < clauseText.length; i += 1) {
    const ch = clauseText[i];
    if (quote) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === quote) {
        quote = null;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "(") paren += 1;
    if (ch === ")") paren = Math.max(0, paren - 1);
    if (ch === "<") angle += 1;
    if (ch === ">") angle = Math.max(0, angle - 1);
    if (ch === "[") bracket += 1;
    if (ch === "]") bracket = Math.max(0, bracket - 1);
    if (ch === "{") brace += 1;
    if (ch === "}") brace = Math.max(0, brace - 1);
    if (
      ch === "," &&
      paren === 0 &&
      angle === 0 &&
      bracket === 0 &&
      brace === 0
    ) {
      parts.push({ text: clauseText.slice(start, i), offset: start });
      start = i + 1;
    }
  }
  parts.push({ text: clauseText.slice(start), offset: start });
  return parts;
}

function hasValidationSemantics(text, configuredPattern, configuredRegex) {
  if (configuredPattern !== DEFAULT_VALIDATION_NAME_RE) {
    configuredRegex.lastIndex = 0;
    return configuredRegex.test(text);
  }
  const tokens = String(text)
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .split(/[^A-Za-z0-9]+/)
    .map((token) => token.toLowerCase())
    .filter(Boolean);
  return tokens.some((token) => DEFAULT_VALIDATION_TOKENS.has(token));
}

function scanPublicAuthorityInits(relFiles, texts, opts, ctx) {
  const findings = [];
  let nameRe;
  let validationNameRe;
  try {
    nameRe = new RegExp(opts.authorityNameRegex);
    validationNameRe = new RegExp(
      opts.validationNameRegex || DEFAULT_VALIDATION_NAME_RE,
      "i",
    );
  } catch (error) {
    throw new Error(`invalid CH-04 name regex: ${error.message}`);
  }

  for (const rel of relFiles) {
    if (!isUnderSources(rel) || !rel.endsWith(".swift")) continue;
    if (isTestPath(rel)) continue;
    const text = texts.get(rel);
    if (text == null) continue;

    // Track recent type declarations (rough)
    const lines = text.split(/\r?\n/);
    let currentType = null;
    let braceDepth = 0;
    let typeDepth = null;

    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      const typeMatch = line.match(
        /\b(?:public\s+)?(?:struct|class|enum|actor)\s+([A-Za-z_][A-Za-z0-9_]*)/,
      );
      if (typeMatch) {
        currentType = typeMatch[1];
        typeDepth = braceDepth;
      }

      const opens = (line.match(/\{/g) || []).length;
      const closes = (line.match(/\}/g) || []).length;

      if (
        currentType &&
        nameRe.test(currentType) &&
        /\bpublic\s+init\s*\(/.test(line)
      ) {
        findings.push(
          makeFinding({
            ...ctx,
            ruleId: "CH-04",
            surface: `${rel}:${i + 1}`,
            severity: "low",
            title: "authority-named public init needs human review",
            detail: `${rel}:${i + 1} type ${currentType} exposes public init. Name/body heuristics cannot prove that this is a forgeable trusted aggregate without Swift AST and call-path analysis; needs-human-review.`,
            needsHumanReview: true,
          }),
        );
      }

      braceDepth += opens - closes;
      if (typeDepth != null && braceDepth <= typeDepth && closes > 0) {
        // left type body
        if (braceDepth <= typeDepth) {
          currentType = null;
          typeDepth = null;
        }
      }
    }

    // Extract only declaration parameter parentheses, so same-line body
    // properties such as `func f() { var validation = nil }` cannot match.
    // Clauses are accumulated across lines to preserve multiline parameters.
    for (const clause of swiftParameterClauses(text)) {
      for (const part of splitTopLevelSwiftParameters(clause.text)) {
        const nilParamMatch = part.text.match(
          /^\s*(?:(_|[A-Za-z_][A-Za-z0-9_]*)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([\s\S]*?)\s*=\s*nil\s*$/,
        );
        if (!nilParamMatch) continue;
        const externalLabel = nilParamMatch[1] || "";
        const parameterName = nilParamMatch[2];
        const parameterType = nilParamMatch[3].trim().replace(/\s+/g, " ");
        const semanticExternalLabel =
          externalLabel !== "_" &&
          hasValidationSemantics(
            externalLabel,
            opts.validationNameRegex || DEFAULT_VALIDATION_NAME_RE,
            validationNameRe,
          );
        const semanticName = hasValidationSemantics(
          parameterName,
          opts.validationNameRegex || DEFAULT_VALIDATION_NAME_RE,
          validationNameRe,
        );
        const semanticType = hasValidationSemantics(
          parameterType,
          opts.validationNameRegex || DEFAULT_VALIDATION_NAME_RE,
          validationNameRe,
        );
        if (!semanticExternalLabel && !semanticName && !semanticType) continue;
        const absoluteIndex =
          clause.absoluteStart + part.offset + part.text.indexOf(parameterName);
        const lineNumber =
          text.slice(0, absoluteIndex).split(/\r?\n/).length;
        findings.push(
          makeFinding({
            ...ctx,
            ruleId: "CH-04",
            surface: `${rel}:${lineNumber}`,
            severity: "medium",
            title: "optional authority/validation parameter defaults to nil",
            detail: `${rel}:${lineNumber} parameter ${externalLabel && externalLabel !== "_" ? `${externalLabel} ` : ""}${parameterName}: ${parameterType} has authorization/validation semantics and defaults to nil (SOL-13 originAuthorityProvider=nil class). Review fail-closed requirements.`,
          }),
        );
      }
    }
  }
  return findings;
}

function containsTailHeadCommand(line) {
  return (
    /\|[ \t]*(?:command[ \t]+)?(?:tail|head)\b/.test(line) ||
    /(?:^|[;(&`])[ \t]*(?:command[ \t]+)?(?:tail|head)\b/.test(line)
  );
}

/**
 * Wrong redirect order §9.8 / TEST_OBSERVATION_DISCIPLINE:
 *   - `> log 2>&1`          correct (do not report)
 *   - `2>&1 > log`          true antipattern (report critical)
 *   - `2>&1 >/dev/null`     legal: keep stderr, discard stdout (do not report)
 *   - `2>&1 >&-`            legal: keep stderr, close stdout (do not report)
 */
function hasWrongRedirectOrder(line) {
  // Strip legal "stderr-only capture / discard-or-close stdout" forms first.
  const stripped = line
    .replace(/2>&1\s*>\s*(['"]?)\/dev\/null\1/g, "")
    .replace(/2>&1\s*>&-/g, "");
  return /2>&1\s*>/.test(stripped) || /2>&1>/.test(stripped);
}

/**
 * Assignment + field pluck (sed/awk/cut/grep|head|tail) is value extraction,
 * not pass/fail observation truncation. Do not report.
 * Bare `var="$(tail …)"` later compared is uncertain → handled separately.
 */
function isValueExtractionCapture(line) {
  if (!containsTailHeadCommand(line)) return false;
  const assigned =
    capturedTailHeadVariable(line) != null ||
    /\b[A-Za-z_][A-Za-z0-9_]*\s*=\s*["']?\$\(/.test(line) ||
    /\b[A-Za-z_][A-Za-z0-9_]*\s*=\s*`/.test(line);
  if (!assigned) return false;
  // Field extractors or labeled-line pluck before/with head|tail.
  if (/\b(?:sed|awk|cut)\b/.test(line)) return true;
  if (/\bgrep\b/.test(line)) return true;
  return false;
}

function directTailHeadVerdict(line) {
  if (!containsTailHeadCommand(line)) return false;
  // Value-extraction assignment never counts as a direct verdict, even when
  // the same line also has test-like tokens in a later clause.
  if (isValueExtractionCapture(line)) return false;
  const commandIndex = line.search(/(?:tail|head)\b/);
  const before = line.slice(0, commandIndex);
  const after = line.slice(commandIndex);
  const conditionalMatch = before.match(/\b(?:if|elif|while)\b/g);
  const conditionalStartsBeforeCommand = Boolean(conditionalMatch);
  const thenIndex = before.lastIndexOf("then");
  const conditionalIndex = Math.max(
    before.lastIndexOf("if"),
    before.lastIndexOf("elif"),
    before.lastIndexOf("while"),
  );
  const commandIsInCondition =
    conditionalStartsBeforeCommand &&
    (thenIndex < 0 || thenIndex < conditionalIndex);
  const commandSubstitutionCompared =
    /\$\([^)]*$/.test(before) &&
    /(?:==|!=|=~|(?:^|[ \t])=(?:[ \t]|["']))/.test(after);
  const shellTestConsumesCommand =
    /(?:^|[;|&])\s*test[ \t]+[^;\n]*$/.test(before) ||
    /\b(?:if|elif|while)\s+test[ \t]+[^;\n]*$/.test(before) ||
    /(?:^|[;|&])\s*\[\[?[^\]\n]*$/.test(before) ||
    /\b(?:if|elif|while)\s+\[\[?[^\]\n]*$/.test(before);
  // Quiet grep after head|tail consumes truncated stream as a boolean verdict.
  const quietGrepVerdict = /\|[ \t]*grep[ \t]+(?:-[A-Za-z]*q|-q)/.test(after);
  return (
    commandIsInCondition ||
    commandSubstitutionCompared ||
    shellTestConsumesCommand ||
    quietGrepVerdict ||
    /(?:&&|\|\|)[ \t]*(?:exit|return)\b/.test(after)
  );
}

function capturedTailHeadVariable(line) {
  if (!containsTailHeadCommand(line)) return null;
  const match = line.match(
    /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*["']?(?:\$\([^)]*(?:tail|head)\b[^)]*\)|`[^`]*(?:tail|head)\b[^`]*`)/,
  );
  return match ? match[1] : null;
}

function escapedGeneratedTailHeadVariable(line) {
  if (!containsTailHeadCommand(line)) return null;
  const match = line.match(
    /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\\\$\([^)]*(?:tail|head)\b[^)]*\)/,
  );
  return match ? match[1] : null;
}

function lineReferencesVariableInVerdict(line, variable) {
  const escaped = variable.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const reference = new RegExp(`\\$(?:${escaped}\\b|\\{${escaped}\\})`);
  if (!reference.test(line)) return false;
  return (
    /\b(?:if|elif|while|test|grep)\b/.test(line) ||
    /(?:\[\[|(?:^|[;&|(\s])\[)/.test(line) ||
    /(?:==|!=|=~|-[a-z]{1,2}\b)/.test(line)
  );
}

function lineReferencesEscapedVariableInVerdict(line, variable) {
  const escaped = variable.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const reference = new RegExp(
    `\\\\\\$(?:${escaped}\\b|\\{${escaped}\\})`,
  );
  if (!reference.test(line)) return false;
  return (
    /\b(?:if|elif|while|test|grep)\b/.test(line) ||
    /(?:\[\[|(?:^|[;&|(\s])\[)/.test(line) ||
    /(?:==|!=|=~|-[a-z]{1,2}\b)/.test(line)
  );
}

function isNonObservationDataGeneration(line) {
  return (
    /\bhead[ \t]+(?:-[A-Za-z]*c\b|--bytes(?:=|[ \t]))[^|;\n]*\/dev\/(?:u?random)\b/.test(
      line,
    ) ||
    /(?:\/dev\/(?:u?random)\b|openssl[ \t]+rand\b|uuidgen\b)[^;\n]*\|[ \t]*head\b/.test(
      line,
    )
  );
}

function ambiguousMultilineTailHeadVerdict(lines, index) {
  const before = lines
    .slice(Math.max(0, index - 3), index + 1)
    .join("\n");
  const assignment = before.match(
    /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*["']?\$\(\s*\n[\s\S]*?(?:tail|head)\b/,
  );
  if (!assignment) return false;
  return lines
    .slice(index + 1, Math.min(lines.length, index + 5))
    .some((candidate) =>
      lineReferencesVariableInVerdict(candidate, assignment[1]),
    );
}

function tailHeadPipelineStatusUsed(lines, index) {
  const after = lines
    .slice(index + 1, Math.min(lines.length, index + 5))
    .find((candidate) => {
      const trimmed = candidate.trim();
      return trimmed !== "" && !trimmed.startsWith("#");
    });
  if (!after) return false;
  return (
    /\b(?:if|elif|while|test)\b[^\n]*(?:\$\?|PIPESTATUS)/.test(after) ||
    /(?:\[\[|(?:^|\s)\[)[^\n]*(?:\$\?|PIPESTATUS)/.test(after)
  );
}

function isIntentionalTailHeadTestFixture(rel, lines, index) {
  const window = lines
    .slice(Math.max(0, index - 3), Math.min(lines.length, index + 4))
    .join("\n");
  const marked =
    /\b(?:negative|anti[- ]?pattern|fixture|intentional|false[- ]?positive|should\s+(?:not|miss)|selftest|stub|sample|broken)\b/i.test(
      window,
    );

  const line = lines[index];
  const testContext = isTestPath(rel) || /selftest/i.test(rel);
  const commentLine =
    /^\s*(?:#|\/\/|\/\*|\*)/.test(line);
  if (/\.(?:mjs|js|swift)$/.test(rel)) {
    const patternIndexes = [
      line.search(/(?:tail|head)\b/),
      line.search(/2>&1\s*>/),
      line.search(/passed\\?\|failed/),
    ].filter((value) => value >= 0);
    const commandIndex =
      patternIndexes.length > 0 ? Math.min(...patternIndexes) : -1;
    const quoteIndex = line.search(/["'`]/);
    if (commandIndex >= 0 && quoteIndex >= 0 && quoteIndex < commandIndex) {
      if (testContext || marked) return true;
    }
  }
  if (testContext && marked) return true;
  return marked && commentLine;
}

function ch02FindingForContext({
  rel,
  lines,
  index,
  ctx,
  severity,
  title,
  detail,
}) {
  if (isIntentionalTailHeadTestFixture(rel, lines, index)) return null;
  return makeFinding({
    ...ctx,
    ruleId: "CH-02",
    surface: `${rel}:${index + 1}`,
    severity,
    title,
    detail,
  });
}

/** CH-02 observation anti-patterns + CH-03 shard parser shape */
function scanObservationAndShard(relFiles, texts, ctx) {
  const findings = [];
  for (const rel of relFiles) {
    if (
      !(
        rel.startsWith("scripts/") ||
        rel.startsWith("tests/") ||
        rel.startsWith("Tests/") ||
        rel.endsWith(".sh") ||
        rel.endsWith(".mjs") ||
        rel.endsWith(".bash")
      )
    ) {
      continue;
    }
    // Do not flag this scanner or the rubric doc examples via scripts path only
    if (rel.endsWith("tatwo-code-health.mjs")) continue;

    const text = texts.get(rel);
    if (text == null) continue;
    const lines = text.split(/\r?\n/);

    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      const trimmed = line.trim();
      if (trimmed.startsWith("#") && !rel.endsWith(".mjs")) {
        // still scan comments in shell — they document bad patterns people copy
      }

      // CH-02: wrong redirect order (file target only; not /dev/null or >&-)
      if (hasWrongRedirectOrder(line)) {
        const finding = ch02FindingForContext({
          rel,
          lines,
          index: i,
          ctx,
          severity: "critical",
          title: "wrong shell redirect order (2>&1 >)",
          detail: `${rel}:${i + 1}: pattern '2>&1 > file' loses stderr from log (TEST_OBSERVATION_DISCIPLINE §9.8). Use '> \"$LOG\" 2>&1'. Note: '2>&1 >/dev/null' and '2>&1 >&-' are legal stderr-only capture and must not match.`,
        });
        if (finding) findings.push(finding);
      }

      // CH-02: tail/head only when its truncated output participates in a
      // verdict. Pure display/logging and value extraction are not findings.
      if (containsTailHeadCommand(line)) {
        const capturedVariable = capturedTailHeadVariable(line);
        const escapedGeneratedVariable =
          escapedGeneratedTailHeadVariable(line);
        const captureUsedForVerdict =
          capturedVariable != null &&
          lines
            .slice(i + 1, Math.min(lines.length, i + 4))
            .some((candidate) =>
              lineReferencesVariableInVerdict(candidate, capturedVariable),
            );
        const escapedGeneratedUsedForVerdict =
          escapedGeneratedVariable != null &&
          lines
            .slice(i + 1, Math.min(lines.length, i + 5))
            .some((candidate) =>
              lineReferencesEscapedVariableInVerdict(
                candidate,
                escapedGeneratedVariable,
              ),
            );
        const directVerdict = directTailHeadVerdict(line);
        const pipelineStatusVerdict = tailHeadPipelineStatusUsed(lines, i);
        const ambiguousMultilineVerdict =
          ambiguousMultilineTailHeadVerdict(lines, i);
        const valueExtraction = isValueExtractionCapture(line);
        if (isNonObservationDataGeneration(line)) {
          // Entropy/identifier generation is data shaping, not test/log
          // observation. This is source semantics, not a head -c exemption:
          // `swift test | head -c ... | grep -q` remains a true positive.
        } else if (valueExtraction) {
          // Assignment + sed/awk/cut/grep field pluck is value extraction,
          // not pass/fail observation truncation. Do not report.
        } else if (directVerdict || pipelineStatusVerdict) {
          const finding = ch02FindingForContext({
            rel,
            lines,
            index: i,
            ctx,
            severity: "critical",
            title: "tail/head output used for pass/fail judgment",
            detail: `${rel}:${i + 1}: tail/head output directly feeds a condition, comparison, quiet grep, or pipeline status verdict. Truncation can hide failures.`,
          });
          if (finding) findings.push(finding);
        } else if (
          captureUsedForVerdict &&
          !isIntentionalTailHeadTestFixture(rel, lines, i)
        ) {
          // Bare assignment of tail/head later referenced by condition syntax:
          // cannot prove value-extract vs truncated observation without deeper
          // analysis — keep visible as low + needs-human-review (never silent).
          findings.push(
            makeFinding({
              ...ctx,
              ruleId: "CH-02",
              surface: `${rel}:${i + 1}`,
              severity: "low",
              title: "captured tail/head later used in condition needs human review",
              detail: `${rel}:${i + 1}: head/tail output is assigned then later referenced by condition syntax. Not a proven direct verdict (would be critical) and not a clear field-extraction capture (would be suppressed). needs-human-review.`,
              needsHumanReview: true,
            }),
          );
        } else if (
          escapedGeneratedUsedForVerdict &&
          !isIntentionalTailHeadTestFixture(rel, lines, i)
        ) {
          findings.push(
            makeFinding({
              ...ctx,
              ruleId: "CH-02",
              surface: `${rel}:${i + 1}`,
              severity: "low",
              title: "generated shell tail/head verdict needs human review",
              detail: `${rel}:${i + 1}: escaped command substitution captures tail/head output and the generated variable is later used by verdict syntax. The scanner cannot prove heredoc/template execution semantics; needs-human-review.`,
              needsHumanReview: true,
            }),
          );
        } else if (
          ambiguousMultilineVerdict &&
          !isIntentionalTailHeadTestFixture(rel, lines, i)
        ) {
          findings.push(
            makeFinding({
              ...ctx,
              ruleId: "CH-02",
              surface: `${rel}:${i + 1}`,
              severity: "low",
              title: "multiline tail/head verdict needs human review",
              detail: `${rel}:${i + 1}: tail/head appears inside a multiline capture later referenced by verdict syntax, but line-based analysis cannot prove the data flow. needs-human-review; use AST/control-flow review before adjudication.`,
              needsHumanReview: true,
            }),
          );
        }
      }

      // CH-02: unanchored passed|failed suite counter. One source line emits
      // one finding; the old implementation double-counted the same pattern.
      const unanchoredSuitePattern =
        /Test Suite \.\* passed\\?\|failed/.test(line) ||
        /passed\\\|failed/.test(line) ||
        (/passed\\?\|failed/.test(line) &&
          /Test Suite|suite/i.test(line) &&
          !/started\|passed\|failed/.test(line));
      if (unanchoredSuitePattern) {
        const finding = ch02FindingForContext({
          rel,
          lines,
          index: i,
          ctx,
          severity: "critical",
          title: "unanchored passed|failed suite grep",
          detail: `${rel}:${i + 1}: combined passed|failed suite pattern inflates counts (185→233 case). Use anchored passed at / failed at separately.`,
        });
        if (finding) findings.push(finding);
      }

      // CH-03: parser accepts started|passed but not failed
      if (
        /\(started\|passed\)/.test(line) &&
        !/\(started\|passed\|failed\)/.test(line) &&
        !/started\|passed\|failed/.test(line)
      ) {
        findings.push(
          makeFinding({
            ...ctx,
            ruleId: "CH-03",
            surface: `${rel}:${i + 1}`,
            severity: "critical",
            title: "log parser omits failed suite terminal",
            detail: `${rel}:${i + 1}: pattern (started|passed) without failed — SOL-10 false-green class (shard universe drops failed leaves).`,
          }),
        );
      }
    }
  }
  return findings;
}

/** CH-06 unreferenced Sources candidates (filename stem) */
function scanOrphanSources(relFiles, texts, ctx) {
  const findings = [];
  const sourceSwift = relFiles.filter(
    (rel) =>
      isUnderSources(rel) &&
      rel.endsWith(".swift") &&
      !isTestPath(rel),
  );

  // Build corpus of all Sources + Tests text for reference search
  const searchRels = relFiles.filter(
    (rel) =>
      (isUnderSources(rel) || isTestPath(rel)) &&
      (rel.endsWith(".swift") || rel.endsWith(".mjs")),
  );

  for (const rel of sourceSwift) {
    const base = rel.split("/").pop();
    const stem = base.replace(/\.swift$/, "");
    if (!stem || stem === "Package" || stem.endsWith("+")) continue;
    // skip obvious entry / generated names
    if (/^main$/i.test(stem)) continue;

    let refs = 0;
    const re = new RegExp(`\\b${stem.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`);
    for (const other of searchRels) {
      if (other === rel) continue;
      const text = texts.get(other);
      if (text == null) continue;
      if (re.test(text)) refs += 1;
    }

    if (refs === 0) {
      findings.push(
        makeFinding({
          ...ctx,
          ruleId: "CH-06",
          surface: rel,
          severity: "medium",
          title: "unreferenced Sources file candidate",
          detail: `${rel} stem '${stem}' has 0 textual references in other Sources/Tests files (D5 deadcode class). Candidate only — do not delete without trash+manifest+approval.`,
        }),
      );
    }
  }

  // archive markers
  for (const rel of relFiles) {
    if (
      /\/_archived\//.test(rel) ||
      rel.endsWith(".swift.txt") ||
      rel.endsWith(".disabled")
    ) {
      findings.push(
        makeFinding({
          ...ctx,
          ruleId: "CH-06",
          surface: rel,
          severity: "low",
          title: "archived or disabled source artifact",
          detail: `${rel} looks archived/disabled (D5 class). Keep inventory; deletion is a separate gated workflow.`,
        }),
      );
    }
  }
  return findings;
}

function loadTextMap(root, absFiles) {
  const texts = new Map();
  const relFiles = [];
  for (const abs of absFiles) {
    const rel = toPosix(relative(root, abs));
    if (rel.startsWith("..")) continue;
    relFiles.push(rel);
    try {
      const st = statSync(abs);
      // skip huge binaries (> 8 MiB)
      if (st.size > 8 * 1024 * 1024) continue;
      texts.set(rel, readFileSync(abs, "utf8"));
    } catch {
      // ignore unreadable
    }
  }
  relFiles.sort();
  return { relFiles, texts };
}

function summarize(findings) {
  const byRule = {};
  const bySev = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const f of findings) {
    byRule[f.ruleId] = (byRule[f.ruleId] || 0) + 1;
    if (bySev[f.severity] != null) bySev[f.severity] += 1;
  }
  return {
    total: findings.length,
    byRule,
    bySeverity: bySev,
  };
}

function runScan(root, opts) {
  const scanID = `codehealth-${utcStamp()}`;
  const revision = gitHead(root);
  const ctx = { scanID, revision };

  const absFiles = walkFiles(root, {
    extensions: [
      ".swift",
      ".mjs",
      ".js",
      ".sh",
      ".bash",
      ".py",
      ".txt",
      ".disabled",
    ],
  });
  const { relFiles, texts } = loadTextMap(root, absFiles);

  let findings = [];
  findings = findings.concat(scanGodFiles(root, relFiles, texts, opts, ctx));
  findings = findings.concat(scanPrivatePaths(root, relFiles, texts, ctx));
  findings = findings.concat(
    scanPublicAuthorityInits(relFiles, texts, opts, ctx),
  );
  findings = findings.concat(scanObservationAndShard(relFiles, texts, ctx));
  findings = findings.concat(scanOrphanSources(relFiles, texts, ctx));

  // stable sort
  findings.sort((a, b) => {
    const ra = a.ruleId.localeCompare(b.ruleId);
    if (ra !== 0) return ra;
    return a.surface.localeCompare(b.surface);
  });

  return { scanID, revision, findings, summary: summarize(findings) };
}

function printScanResult(result, { json }) {
  for (const f of result.findings) {
    console.log(JSON.stringify(f));
  }
  if (json) {
    // still emit summary on stderr so pipelines keep stdout pure JSONL
    console.error(
      JSON.stringify({
        schema: "TatwoCodeHealthScanSummaryV1",
        rubricVersion: RUBRIC_VERSION,
        scanID: result.scanID,
        revision: result.revision,
        summary: result.summary,
        manual_review_required: MANUAL_REVIEW_ITEMS,
      }),
    );
    return;
  }
  console.error("");
  console.error(`code-health scan ${result.scanID}`);
  console.error(`rubricVersion: ${RUBRIC_VERSION}`);
  console.error(`revision: ${result.revision}`);
  console.error(`findings: ${result.summary.total}`);
  console.error("byRule:");
  for (const [k, v] of Object.entries(result.summary.byRule).sort()) {
    console.error(`  ${k}: ${v}`);
  }
  console.error("bySeverity:");
  for (const [k, v] of Object.entries(result.summary.bySeverity)) {
    console.error(`  ${k}: ${v}`);
  }
  console.error("");
  console.error("manual_review_required:");
  for (const item of MANUAL_REVIEW_ITEMS) {
    console.error(`  - ${item}`);
  }
  console.error(
    "note: source v1 baseline missing; thresholds not tuned for cosmetics.",
  );
}

// --- selftest ---

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function writeTree(base, tree) {
  for (const [rel, content] of Object.entries(tree)) {
    const abs = join(base, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content, "utf8");
  }
}

function selftest() {
  const checks = [];
  const track = (id, fn) => {
    try {
      fn();
      checks.push({ id, passed: true });
    } catch (error) {
      checks.push({ id, passed: false, error: String(error.message || error) });
    }
  };

  const tmp = mkdtempSync(join(tmpdir(), "tatwo-code-health-"));
  try {
    // Fixture layout under Sources / scripts
    writeTree(tmp, {
      "Packages/Demo/Sources/Demo/SmallOK.swift":
        "public struct SmallOK { public init() {} }\n",
      "Packages/Demo/Sources/Demo/GodFileBig.swift": `${"// line\n".repeat(12)}public struct GodFileBig {}\n`,
      "Packages/Demo/Sources/Demo/PathLeak.swift":
        'let p = "/Users/alice/secret/config.toml"\n',
      "Packages/Demo/Sources/Demo/PathClean.swift":
        'let p = "relative/config.toml"\n',
      "Packages/Demo/Sources/Demo/TrustAuthority.swift": `
public struct TrustAuthority {
  public var x: Int
  public init(x: Int) { self.x = x }
}
`,
      "Packages/Demo/Sources/Demo/TrustAuthoritySealed.swift": `
public struct TrustAuthoritySealed {
  var x: Int
  init(x: Int) { self.x = x }
}
`,
      "Packages/Demo/Sources/Demo/NilProvider.swift": `
public func dispatch(originAuthorityProvider: Foo? = nil) {}
`,
      "Packages/Demo/Sources/Demo/NilValidatorType.swift": `
public func dispatch(check: RequestValidator? = nil) {}
`,
      "Packages/Demo/Sources/Demo/NilExistentialValidator.swift": `
public func dispatch(originAuthorityProvider: (any RequestValidator)? = nil) {}
`,
      "Packages/Demo/Sources/Demo/NilClosureValidation.swift": `
public func dispatch(check: ((Request) -> ValidationProof)? = nil) {}
`,
      "Packages/Demo/Sources/Demo/NilMultilineValidator.swift": `
public func dispatch(
  check:
    (any RequestValidator)? = nil
) {}
`,
      "Packages/Demo/Sources/Demo/NilExternalAuthorityLabel.swift": `
public func dispatch(
  note: String = ")",
  authority provider: Provider? = nil
) {}
`,
      "Packages/Demo/Sources/Demo/GeneralOptional.swift": `
public func writeLog(
  logFileURL: URL? = nil,
  provider: Provider? = nil,
  aggregate: Aggregate? = nil
) {}
`,
      "Packages/Demo/Sources/Demo/OptionalValidationProperty.swift": `
public struct Cache {
  public var validation: ValidationProof? = nil
}
public func bodyLocal() { var approval: ApprovalProof? = nil }
`,
      "Packages/Demo/Sources/Demo/OrphanOnly.swift":
        "public struct OrphanOnlyTokenXYZ {}\n",
      "Packages/Demo/Sources/Demo/UsedType.swift":
        "public struct UsedType {}\n",
      "Packages/Demo/Sources/Demo/UsesUsedType.swift":
        "func f() { _ = UsedType.self }\n",
      "Packages/Demo/Tests/DemoTests/Ref.swift":
        "// no orphan refs\n",
      "scripts/bad-observe.sh": `#!/bin/bash
swift test 2>&1 > /tmp/x.log
if swift test 2>&1 | tail -5 | grep -q "failed"; then echo FAIL; fi
`,
      "scripts/direct-cmdsubst-tail-verdict.sh": `#!/bin/bash
if [ "$(tail -1 "$LOG")" = ok ]; then exit 0; fi
`,
      "scripts/captured-tail-verdict.sh": `#!/bin/bash
verdict="$(tail -n 1 "$LOG")"
if [ "$verdict" = "PASS" ]; then exit 0; fi
`,
      "scripts/field-extract-head.sh": `#!/bin/bash
token="$(printf '%s\n' "$acq_out" | sed -n 's/^token=//p' | head -n1)"
if [[ -z "$token" ]]; then die "no token"; fi
seed="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/^PAIRING_SEED=//p' | tail -1)"
[ -n "$seed" ] || die "no seed"
`,
      "scripts/stderr-only-capture.sh": `#!/bin/bash
verify_out="$(node helper --verify 2>&1 >/dev/null)"
verify_closed="$(node helper --verify 2>&1 >&-)"
if [[ -n "$verify_out" ]]; then printf '%s\n' "$verify_out"; fi
`,
      "scripts/display-tail.sh": `#!/bin/bash
echo "last diagnostic lines:"
tail -n 5 "$LOG"
`,
      "scripts/conditional-display-tail.sh": `#!/bin/bash
if debug_enabled; then tail -n 5 "$LOG"; fi
grep -q feature config.ini; tail -n 5 "$LOG"
`,
      "scripts/version-display.mjs": `
const version = found
  ? spawnSync("sh", ["-lc", \`tool --version 2>/dev/null | head -1\`])
  : null;
`,
      "scripts/head-bytes-verdict.sh": `#!/bin/bash
if swift test | head -c 100 | grep -q failed; then exit 1; fi
`,
      "scripts/entropy-token.sh": `#!/bin/bash
if raw="$(head -c 16 /dev/urandom | od -An -tx1)"; then
  if is_valid_token "$raw"; then echo ready; fi
fi
`,
      "scripts/tail-variable.sh": `#!/bin/bash
if [ "$tail" = "ready" ]; then echo ready; fi
`,
      "scripts/tail-status-verdict.sh": `#!/bin/bash
tail -n 1 "$LOG"
if [ "$?" -eq 0 ]; then exit 0; fi
`,
      "scripts/tail-status-overwritten.sh": `#!/bin/bash
tail -n 1 "$LOG"
echo "display complete"
if [ "$?" -eq 0 ]; then exit 0; fi
`,
      "scripts/good-observe.sh": `#!/bin/bash
swift test -j 2 > "$LOG" 2>&1
`,
      "tests/fixtures/intentional-tail-antipattern.test.mjs": `
// negative fixture: this string is an intentional anti-pattern sample
const bad = "if swift test | tail -5 | grep -q failed; then exit 1; fi";
`,
      "tests/fixtures/intentional-redirect-antipattern.test.mjs": `
// negative fixture: redirect anti-pattern must remain test data
const bad = "swift test 2>&1 > test.log";
`,
      "tests/fixtures/intentional-suite-antipattern.test.mjs": `
// negative fixture: suite grep anti-pattern must remain test data
const bad = "grep -c 'Test Suite .* passed\\\\|failed' log";
`,
      "tests/string-antipattern-samples.test.mjs": `
const redirectSample = "swift test 2>&1 > test.log";
const suiteSample = "grep -c 'Test Suite .* passed\\\\|failed' log";
`,
      "tests/uncertain-tail-judgment.sh": `#!/bin/bash
verdict="$(
  swift test | tail -5
)"
if [ "$verdict" = PASS ]; then exit 0; fi
`,
      "tests/real-tail-verdict.sh": `#!/bin/bash
if swift test | tail -5 | grep -q failed; then exit 1; fi
`,
      "tests/generated-remote-shell.test.sh": `#!/bin/bash
remote_cmd="$(cat <<REMOTE
TOKEN=\\$(printf '%s\\n' "\\$ACQ" | sed -n 's/^token=//p' | head -n1)
if [[ -z "\\$TOKEN" ]]; then exit 1; fi
REMOTE
)"
`,
      "scripts/bad-shard-parse.mjs":
        "const re = /(started|passed)/;\n",
      "scripts/good-shard-parse.mjs":
        "const re = /(started|passed|failed)/;\n",
      "scripts/bad-suite-grep.sh":
        "grep -c 'Test Suite .* passed\\|failed' log\n",
    });

    const optsHit = {
      lineThreshold: 10,
      lineThresholdCritical: 100,
      authorityNameRegex: DEFAULT_AUTHORITY_NAME_RE,
      validationNameRegex: DEFAULT_VALIDATION_NAME_RE,
    };
    const hit = runScan(tmp, optsHit);
    const rules = (id) => hit.findings.filter((f) => f.ruleId === id);

    track("CH-01-hit-god-file", () => {
      assert(
        rules("CH-01").some((f) => f.surface.includes("GodFileBig.swift")),
        "expected god-file hit",
      );
    });
    track("CH-01-miss-small", () => {
      assert(
        !rules("CH-01").some((f) => f.surface.includes("SmallOK.swift")),
        "small file should not hit CH-01",
      );
    });
    track("CH-05-hit-path", () => {
      assert(
        rules("CH-05").some((f) => f.surface.includes("PathLeak.swift")),
        "expected private path hit",
      );
    });
    track("CH-05-miss-clean", () => {
      assert(
        !rules("CH-05").some((f) => f.surface.includes("PathClean.swift")),
        "clean path should not hit",
      );
    });
    track("CH-04-hit-public-init", () => {
      const publicInit = rules("CH-04").find((f) =>
        f.surface.includes("TrustAuthority.swift"),
      );
      assert(publicInit, "expected public init on Authority type");
      assert(publicInit.severity === "low", "public-init heuristic must be low");
      assert(
        publicInit.needsHumanReview === true,
        "public-init heuristic must require human review",
      );
    });
    track("CH-04-miss-internal-init", () => {
      assert(
        !rules("CH-04").some((f) =>
          f.surface.includes("TrustAuthoritySealed.swift"),
        ),
        "internal init should not hit public-init rule",
      );
    });
    track("CH-04-hit-nil-provider", () => {
      assert(
        rules("CH-04").some((f) => f.surface.includes("NilProvider.swift")),
        "expected nil provider hit",
      );
    });
    track("CH-04-hit-nil-semantic-type", () => {
      assert(
        rules("CH-04").some((f) =>
          f.surface.includes("NilValidatorType.swift"),
        ),
        "expected validation-semantic type hit",
      );
      assert(
        rules("CH-04").some((f) =>
          f.surface.includes("NilExistentialValidator.swift"),
        ),
        "expected existential validation-semantic type hit",
      );
      assert(
        rules("CH-04").some((f) =>
          f.surface.includes("NilClosureValidation.swift"),
        ),
        "expected closure validation-semantic type hit",
      );
      assert(
        rules("CH-04").some((f) =>
          f.surface.includes("NilMultilineValidator.swift"),
        ),
        "expected multiline validation-semantic parameter hit",
      );
      assert(
        rules("CH-04").some((f) =>
          f.surface.includes("NilExternalAuthorityLabel.swift"),
        ),
        "expected semantic external label after quoted close-paren default to hit",
      );
    });
    track("CH-04-miss-general-optionals", () => {
      assert(
        !rules("CH-04").some((f) =>
          f.surface.includes("GeneralOptional.swift"),
        ),
        "general optional parameters must not hit CH-04",
      );
      assert(
        !rules("CH-04").some((f) =>
          f.surface.includes("OptionalValidationProperty.swift"),
        ),
        "optional validation property is not a parameter and must not hit CH-04",
      );
    });
    track("CH-02-hit-redirect", () => {
      const redirect = rules("CH-02").find(
        (f) =>
          f.surface.includes("bad-observe.sh") &&
          (/2>&1/.test(f.detail) || /redirect/.test(f.title)),
      );
      assert(redirect, "expected 2>&1 > log redirect anti-pattern");
      assert(
        redirect.severity === "critical",
        "wrong redirect to a file must stay critical",
      );
    });
    track("CH-02-hit-tail", () => {
      assert(
        rules("CH-02").some(
          (f) =>
            f.surface.includes("bad-observe.sh") &&
            f.severity === "critical" &&
            (/tail/.test(f.title) || /tail/.test(f.detail)),
        ),
        "expected direct tail-to-verdict anti-pattern",
      );
    });
    track("CH-02-hit-direct-cmdsubst-tail", () => {
      const direct = rules("CH-02").find((f) =>
        f.surface.includes("direct-cmdsubst-tail-verdict.sh"),
      );
      assert(
        direct,
        "if [ \"$(tail -1 x)\" = ok ] must hit as true positive",
      );
      assert(
        direct.severity === "critical",
        "direct cmdsubst tail comparison must stay critical",
      );
    });
    track("CH-02-hit-adjacent-pipeline-status", () => {
      assert(
        rules("CH-02").some((f) =>
          f.surface.includes("tail-status-verdict.sh"),
        ),
        "adjacent pipeline status verdict must hit",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("tail-status-overwritten.sh"),
        ),
        "intervening command overwrites pipeline status and must not be attributed",
      );
    });
    track("CH-02-hit-proven-test-path-verdict", () => {
      const proven = rules("CH-02").find((f) =>
        f.surface.includes("real-tail-verdict.sh"),
      );
      assert(proven, "proven verdict in tests path must hit");
      assert(
        proven.severity === "critical",
        "proven verdict in tests path must retain severity",
      );
      assert(
        rules("CH-02").some((f) =>
          f.surface.includes("head-bytes-verdict.sh"),
        ),
        "head byte truncation that feeds a verdict must hit",
      );
    });
    track("CH-02-miss-display-tail", () => {
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("display-tail.sh"),
        ),
        "tail used only for display must not hit CH-02",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("conditional-display-tail.sh"),
        ),
        "conditional or grep-adjacent display tail must not hit CH-02",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("version-display.mjs"),
        ),
        `version display truncated for presentation must not hit CH-02: ${JSON.stringify(rules("CH-02").filter((f) => f.surface.includes("version-display.mjs")))}`,
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("tail-variable.sh"),
        ),
        "$tail/$head variables are not commands",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("entropy-token.sh"),
        ),
        "entropy token generation is not test/log observation",
      );
    });
    track("CH-02-miss-stderr-only-redirect", () => {
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("stderr-only-capture.sh"),
        ),
        "2>&1 >/dev/null and 2>&1 >&- are legal stderr-only capture",
      );
    });
    track("CH-02-miss-field-extract-head", () => {
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("field-extract-head.sh"),
        ),
        "sed/awk field extraction assigned via head|tail is value capture, not verdict",
      );
    });
    track("CH-02-miss-intentional-test-fixture", () => {
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("intentional-tail-antipattern.test.mjs"),
        ),
        "marked/string-literal anti-pattern test fixture must not hit CH-02",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("intentional-redirect-antipattern.test.mjs"),
        ),
        "marked/string-literal redirect fixture must not hit CH-02",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("intentional-suite-antipattern.test.mjs"),
        ),
        "marked/string-literal suite-grep fixture must not hit CH-02",
      );
      assert(
        !rules("CH-02").some((f) =>
          f.surface.includes("string-antipattern-samples.test.mjs"),
        ),
        "unmarked string-literal redirect/suite fixtures must not hit CH-02",
      );
    });
    track("CH-02-low-uncertain-test-fixture", () => {
      const uncertain = rules("CH-02").find((f) =>
        f.surface.includes("uncertain-tail-judgment.sh"),
      );
      assert(
        uncertain,
        `uncertain test fixture must remain visible: ${JSON.stringify(rules("CH-02"))}`,
      );
      assert(
        uncertain.severity === "low",
        `uncertain fixture must be low: ${JSON.stringify(uncertain)}`,
      );
      assert(
        uncertain.needsHumanReview === true,
        "uncertain fixture must be marked needs-human-review",
      );
      const generated = rules("CH-02").find((f) =>
        f.surface.includes("generated-remote-shell.test.sh"),
      );
      assert(generated, "escaped generated shell verdict must remain visible");
      assert(
        generated.severity === "low",
        "escaped generated shell verdict must be low",
      );
      assert(
        generated.needsHumanReview === true,
        "escaped generated shell verdict must require human review",
      );
      const captured = rules("CH-02").find((f) =>
        f.surface.includes("captured-tail-verdict.sh"),
      );
      assert(
        captured,
        "bare captured tail later used in a condition must remain visible",
      );
      assert(
        captured.severity === "low",
        "bare captured tail is not a proven direct verdict; must be low",
      );
      assert(
        captured.needsHumanReview === true,
        "bare captured tail must be needs-human-review, never silent",
      );
    });
    track("CH-02-miss-good-observe", () => {
      assert(
        !hit.findings.some(
          (f) =>
            f.surface.includes("good-observe.sh") && f.ruleId === "CH-02",
        ),
        "good observe script should be clean for CH-02",
      );
    });
    track("CH-03-hit-parser", () => {
      assert(
        rules("CH-03").some((f) =>
          f.surface.includes("bad-shard-parse.mjs"),
        ),
        "expected CH-03 parser hit",
      );
    });
    track("CH-03-miss-good-parser", () => {
      assert(
        !rules("CH-03").some((f) =>
          f.surface.includes("good-shard-parse.mjs"),
        ),
        "good parser should not hit CH-03",
      );
    });
    track("CH-06-hit-orphan", () => {
      assert(
        rules("CH-06").some((f) => f.surface.includes("OrphanOnly.swift")),
        "expected orphan candidate",
      );
    });
    track("CH-06-miss-used", () => {
      assert(
        !rules("CH-06").some(
          (f) =>
            f.surface === "Packages/Demo/Sources/Demo/UsedType.swift" ||
            f.surface.endsWith("/UsedType.swift"),
        ),
        "referenced type file should not be orphan",
      );
    });
    track("finding-shape", () => {
      const f = hit.findings[0];
      assert(f, "need at least one finding");
      for (const key of [
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
      ]) {
        assert(f[key] != null && f[key] !== "", `missing ${key}`);
      }
      assert(f.schema === SCHEMA, "schema");
      assert(f.rubricVersion === RUBRIC_VERSION, "rubricVersion");
    });
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  const failed = checks.filter((c) => !c.passed);
  const payload = {
    schema: "TatwoCodeHealthSelftestV1",
    rubricVersion: RUBRIC_VERSION,
    passed: failed.length === 0,
    checks,
  };
  console.log(JSON.stringify(payload, null, 2));
  if (failed.length) {
    console.error("SELFTEST FAIL");
    process.exitCode = 1;
    return;
  }
  console.error("SELFTEST PASS");
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    usage(error.message);
    process.exitCode = 2;
    return;
  }

  if (options.help) {
    usage();
    return;
  }

  if (options.selftest) {
    selftest();
    return;
  }

  if (options.command !== "scan") {
    usage("expected command 'scan' or --selftest");
    process.exitCode = 2;
    return;
  }

  const root = resolve(
    options.root || gitTopLevel(process.cwd()) || process.cwd(),
  );
  if (!existsSync(root)) {
    usage(`root does not exist: ${root}`);
    process.exitCode = 2;
    return;
  }

  const result = runScan(root, {
    lineThreshold: options.lineThreshold,
    lineThresholdCritical: options.lineThresholdCritical,
    authorityNameRegex: options.authorityNameRegex,
    validationNameRegex: options.validationNameRegex,
  });
  printScanResult(result, { json: options.json });
  // exit 0 even with findings — this is a reporter, not a CI gate by default
}

main();
