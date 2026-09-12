#!/usr/bin/env node
/**
 * Tatwo Plugin/MCP controller CLI — S2 plan + S3 apply (injected target only).
 *
 *   node scripts/tatwo-plugin-controller.mjs plan --registry <path> --readback <path> [--brand codex|claude]
 *   node scripts/tatwo-plugin-controller.mjs apply --plan <staged.json> --target <path> --authorization <file> [--i-understand-user-config] [--json]
 *   node scripts/tatwo-plugin-controller.mjs --selftest
 *
 * Readback JSON shape (fixture / injected only — never defaults to ~/.codex|~/.claude):
 * {
 *   "codexPath": optional string,
 *   "claudePath": optional string,
 *   "codexServers": [{ "serverID", "command?", "args?", "url?", "transport?" }],
 *   "claudeServers": [...],
 *   "ownershipRecords": [{
 *     "serverID": "beta",
 *     "brand": "codex",
 *     "targetPath": "~/.codex/config.toml#mcp_servers.beta",
 *     "appliedFragmentSHA256": "<sha256>",
 *     "appliedAtRevision": "s2-revision",
 *     "appliedAt": "2026-07-30T00:00:00Z"
 *   }]
 * }
 *
 * Authorization JSON (human gate token):
 * {
 *   "schema": "TatwoPluginApplyAuthorizationV1",
 *   "approvedPlanDigest": "<sha256>",
 *   "approvedTargetPath": "/absolute/canonical/fixture/config.toml",
 *   "approvedBrand": "codex",
 *   "approver": "human@example",
 *   "approvedAt": "2026-07-30T12:00:00Z"
 * }
 *
 * --i-understand-user-config: required when --target is under ~/.codex or ~/.claude.
 * Must be added by the human; CLI never defaults home paths.
 */

import { createHash, randomUUID } from "node:crypto";
import {
  readFileSync,
  writeFileSync,
  existsSync,
  copyFileSync,
  lstatSync,
  readlinkSync,
  symlinkSync,
  mkdirSync,
  renameSync,
  unlinkSync,
  mkdtempSync,
  rmSync,
  constants as fsConstants,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const REPO_ROOT = resolve(dirname(SCRIPT_PATH), "..");
const RENDERER_VERSION = "s2-projection-v1";
const KNOWN_TEMPLATES = {
  codex: new Set(["codex.mcp-server.v1"]),
  claude: new Set(["claude.mcp-server.v1"]),
};

function usage(message) {
  if (message) console.error(`Error: ${message}`);
  console.error(`Usage:
  node scripts/tatwo-plugin-controller.mjs plan --registry <path> --readback <path> [--brand codex|claude] [--json]
  node scripts/tatwo-plugin-controller.mjs apply --plan <staged.json> --target <path> --authorization <file> [--i-understand-user-config] [--json]
  node scripts/tatwo-plugin-controller.mjs --selftest

Notes:
  - apply requires injected --target; there is NO default to ~/.codex or ~/.claude.
  - --target may be supplied once only; multi-target apply is rejected fail-closed.
  - If --target is under user home agent config, human must pass --i-understand-user-config.
  - requiresHumanGate is always true on plan output.`);
}

function die(message, code = 1) {
  console.error(message);
  process.exit(code);
}

function parseArgs(argv) {
  const options = {
    command: null,
    registry: null,
    readback: null,
    brand: null,
    plan: null,
    target: null,
    authorization: null,
    iUnderstandUserConfig: false,
    json: false,
    selftest: false,
  };
  const rest = [...argv];
  let targetSeen = false;
  if (rest.includes("--selftest")) {
    options.selftest = true;
  }
  if (rest[0] === "plan" || rest[0] === "apply") {
    options.command = rest.shift();
  } else if (!options.selftest && rest[0] && !rest[0].startsWith("-")) {
    options.command = rest.shift();
  }
  for (let i = 0; i < rest.length; i += 1) {
    const arg = rest[i];
    if (arg === "--registry") {
      options.registry = rest[++i];
    } else if (arg === "--readback") {
      options.readback = rest[++i];
    } else if (arg === "--brand") {
      options.brand = rest[++i];
    } else if (arg === "--plan") {
      options.plan = rest[++i];
    } else if (arg === "--target") {
      if (targetSeen) die("--target may be supplied exactly once; multi-target apply is rejected");
      targetSeen = true;
      options.target = rest[++i];
    } else if (arg === "--authorization") {
      options.authorization = rest[++i];
    } else if (arg === "--i-understand-user-config") {
      options.iUnderstandUserConfig = true;
    } else if (arg === "--json") {
      options.json = true;
    } else if (arg === "--selftest") {
      options.selftest = true;
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else if (arg.startsWith("-")) {
      die(`Unknown flag: ${arg}`);
    }
  }
  return options;
}

function loadJSON(path, { allowHomeConfig = false } = {}) {
  const abs = resolve(path);
  assertTargetPathPolicy(abs, { allowHomeConfig, label: "path" });
  return JSON.parse(readFileSync(abs, "utf8"));
}

function assertNotDefaultHomePath(path) {
  assertTargetPathPolicy(path, { allowHomeConfig: false, label: "path" });
}

/** Home agent config trees require explicit human flag; never a silent default. */
function assertTargetPathPolicy(path, { allowHomeConfig = false, label = "target" } = {}) {
  const home = process.env.HOME || homedir() || "";
  if (!home) return;
  const forbidden = [join(home, ".codex"), join(home, ".claude")];
  const normalized = canonicalTargetPath(path);
  for (const root of forbidden) {
    const canonicalRoot = canonicalTargetPath(root);
    if (normalized === canonicalRoot || normalized.startsWith(canonicalRoot + "/")) {
      if (allowHomeConfig) return;
      throw new Error(
        `${label} is under user home agent config (${path}). Human must pass --i-understand-user-config; CLI never defaults home paths.`,
      );
    }
  }
}

/**
 * Resolve the leaf when it exists, otherwise resolve the nearest existing
 * ancestor and append the missing components.  This preserves symlink
 * containment for a not-yet-created target such as
 * `/tmp/codex-alias/new-config.toml`.
 */
function canonicalTargetPath(path) {
  const trimmed = String(path || "").trim();
  if (!trimmed) return "";
  const expanded = trimmed.replace(/^~(?=\/|$)/, process.env.HOME || homedir() || "~");
  let pending = resolve(expanded);
  // Resolve each component, including broken/non-existent-leaf symlink
  // parents.  The bound prevents symlink cycles from hanging policy checks.
  for (let attempt = 0; attempt < 64; attempt += 1) {
    const components = pending.split("/").filter(Boolean);
    let resolved = "/";
    let changed = false;
    for (let index = 0; index < components.length; index += 1) {
      const candidate = join(resolved, components[index]);
      let linkTarget;
      try {
        if (lstatSync(candidate).isSymbolicLink()) {
          linkTarget = readlinkSync(candidate);
        }
      } catch {
        // Missing components are appended lexically; later existing
        // components cannot be traversed without a real parent.
      }
      if (linkTarget !== undefined) {
        let next = linkTarget.startsWith("/")
          ? linkTarget
          : join(dirname(candidate), linkTarget);
        for (const remainder of components.slice(index + 1)) {
          next = join(next, remainder);
        }
        pending = resolve(next);
        changed = true;
        break;
      }
      resolved = candidate;
    }
    if (!changed) return resolved;
  }
  return resolve(pending);
}

function validateRegistry(doc) {
  if (doc.schema !== "TatwoPluginControllerRegistryV1") {
    throw new Error(`unsupported schema: ${doc.schema}`);
  }
  if (doc.source !== "os_registry") {
    throw new Error("source must be os_registry");
  }
  if (!Array.isArray(doc.entries) || doc.entries.length === 0) {
    throw new Error("entries empty");
  }
  return doc;
}

function managedFromCanonical(entryID, canonical) {
  const transport = canonical.transport;
  if (transport === "stdio") {
    const command = (canonical.command || "").trim();
    if (!command) throw new Error(`${entryID}: stdio requires command`);
    return {
      serverID: entryID,
      transport: "stdio",
      command,
      args: Array.isArray(canonical.args) ? canonical.args : [],
      url: null,
    };
  }
  if (transport === "http" || transport === "sse") {
    const url = (canonical.url || "").trim();
    if (!url) throw new Error(`${entryID}: ${transport} requires url`);
    return {
      serverID: entryID,
      transport,
      command: null,
      args: [],
      url,
    };
  }
  throw new Error(`${entryID}: unknown transport ${transport}`);
}

function managedFromObserved(server) {
  return {
    serverID: server.serverID,
    transport: server.transport || null,
    command: server.command || null,
    args: Array.isArray(server.args) ? server.args : [],
    url: server.url || null,
  };
}

function normalizeTransport(raw) {
  if (raw == null || raw === "") return null;
  return String(raw).trim().toLowerCase() || null;
}

function managedEquals(a, b) {
  return (
    a.serverID === b.serverID
    && normalizeTransport(a.transport) === normalizeTransport(b.transport)
    && (a.command || "") === (b.command || "")
    && JSON.stringify(a.args || []) === JSON.stringify(b.args || [])
    && (a.url || "") === (b.url || "")
  );
}

function quote(value) {
  let escaped = "";
  for (const character of String(value)) {
    const codePoint = character.codePointAt(0);
    switch (codePoint) {
      case 0x08: escaped += "\\b"; break;
      case 0x09: escaped += "\\t"; break;
      case 0x0a: escaped += "\\n"; break;
      case 0x0c: escaped += "\\f"; break;
      case 0x0d: escaped += "\\r"; break;
      case 0x22: escaped += '\\"'; break;
      case 0x5c: escaped += "\\\\"; break;
      default:
        if ((codePoint >= 0 && codePoint <= 0x1f) || (codePoint >= 0x7f && codePoint <= 0x9f)) {
          escaped += codePoint <= 0xffff
            ? `\\u${codePoint.toString(16).padStart(4, "0")}`
            : `\\U${codePoint.toString(16).padStart(8, "0")}`;
        } else {
          escaped += character;
        }
    }
  }
  return `"${escaped}"`;
}

function sanitizedIdentifier(value) {
  let output = "";
  for (const character of String(value)) {
    const codePoint = character.codePointAt(0);
    const allowed =
      (codePoint >= 0x41 && codePoint <= 0x5a)
      || (codePoint >= 0x61 && codePoint <= 0x7a)
      || (codePoint >= 0x30 && codePoint <= 0x39)
      || character === "_" || character === "-" || character === ".";
    if (allowed) output += character;
    else output += `_${codePoint.toString(16).toUpperCase().padStart(codePoint <= 0xffff ? 4 : 8, "0")}_`;
  }
  return output || "_empty_";
}

function fragmentBody(managed, brand) {
  return brand === "codex" ? renderCodexTOML(managed) : renderClaudeJSON(managed);
}

function fragmentSHA256(managed, brand) {
  return createHash("sha256").update(fragmentBody(managed, brand), "utf8").digest("hex");
}

function validateOwnershipRecords(raw) {
  if (raw == null) return [];
  if (!Array.isArray(raw)) throw new Error("ownershipRecords must be an array");
  return raw.map((record, index) => {
    if (!record || typeof record !== "object") {
      throw new Error(`ownershipRecords[${index}] must be an object`);
    }
    const required = [
      "serverID", "brand", "targetPath", "appliedFragmentSHA256",
      "appliedAtRevision", "appliedAt",
    ];
    for (const key of required) {
      if (typeof record[key] !== "string" || record[key].length === 0) {
        throw new Error(`ownershipRecords[${index}].${key} is required`);
      }
    }
    if (record.brand !== "codex" && record.brand !== "claude") {
      throw new Error(`ownershipRecords[${index}].brand must be codex|claude`);
    }
    if (!/^[0-9a-fA-F]{64}$/.test(record.appliedFragmentSHA256)) {
      throw new Error(`ownershipRecords[${index}].appliedFragmentSHA256 must be sha256`);
    }
    const state = record.state || "active";
    if (state !== "active" && state !== "rolled_back") {
      throw new Error(`ownershipRecords[${index}].state must be active|rolled_back`);
    }
    return {
      ...record,
      state,
      appliedFragmentSHA256: record.appliedFragmentSHA256.toLowerCase(),
    };
  });
}

function stableManagedText(managed) {
  const lines = [`serverID=${managed.serverID}`];
  const transport = normalizeTransport(managed.transport);
  if (transport) lines.push(`transport=${transport}`);
  if (managed.command) lines.push(`command=${managed.command}`);
  if (managed.args && managed.args.length) {
    lines.push(`args=[${managed.args.map(quote).join(", ")}]`);
  }
  if (managed.url) lines.push(`url=${managed.url}`);
  return `${lines.join("\n")}\n`;
}

function codexTableHeader(serverID) {
  if (/^[A-Za-z0-9_]+$/.test(serverID)) return `[mcp_servers.${serverID}]`;
  return `[mcp_servers.${quote(serverID)}]`;
}

function renderCodexTOML(managed) {
  const lines = [codexTableHeader(managed.serverID)];
  if (managed.command) lines.push(`command = ${quote(managed.command)}`);
  if (managed.args?.length) {
    lines.push(`args = [${managed.args.map(quote).join(", ")}]`);
  }
  if (managed.url) lines.push(`url = ${quote(managed.url)}`);
  if (managed.transport) lines.push(`transport = ${quote(managed.transport)}`);
  return `${lines.join("\n")}\n`;
}

function decodeTOMLBasicString(raw) {
  if (!raw.startsWith('"') || !raw.endsWith('"')) throw new Error("invalid TOML basic string");
  let value = "";
  for (let i = 1; i < raw.length - 1; i += 1) {
    const character = raw[i];
    if (character !== "\\") {
      value += character;
      continue;
    }
    const escaped = raw[++i];
    if (escaped === "b") value += "\b";
    else if (escaped === "t") value += "\t";
    else if (escaped === "n") value += "\n";
    else if (escaped === "f") value += "\f";
    else if (escaped === "r") value += "\r";
    else if (escaped === '"') value += '"';
    else if (escaped === "\\") value += "\\";
    else if (escaped === "u" || escaped === "U") {
      const width = escaped === "u" ? 4 : 8;
      const codePoint = Number.parseInt(raw.slice(i + 1, i + 1 + width), 16);
      if (!Number.isInteger(codePoint)) throw new Error("invalid TOML unicode escape");
      value += String.fromCodePoint(codePoint);
      i += width;
    } else {
      throw new Error(`unknown TOML escape: ${escaped}`);
    }
  }
  return value;
}

function parseRenderedCodexTOML(text) {
  const lines = text.trimEnd().split("\n");
  if (lines.length < 2 || !lines[0].startsWith("[mcp_servers.")) {
    throw new Error("invalid rendered Codex TOML");
  }
  const headerBody = lines[0].slice("[mcp_servers.".length, -1);
  const serverID = headerBody.startsWith('"')
    ? decodeTOMLBasicString(headerBody)
    : headerBody;
  const fields = {};
  for (const line of lines.slice(1)) {
    const separator = line.indexOf(" = ");
    if (separator < 0) throw new Error("invalid rendered Codex TOML field");
    const key = line.slice(0, separator);
    const value = line.slice(separator + 3);
    if (key === "args") {
      const args = [];
      const matcher = /"(?:\\.|[^"\\])*"/g;
      let match;
      while ((match = matcher.exec(value)) !== null) args.push(decodeTOMLBasicString(match[0]));
      fields.args = args;
    } else {
      fields[key] = decodeTOMLBasicString(value);
    }
  }
  return { serverID, fields };
}

function renderClaudeJSON(managed) {
  const object = {};
  if (managed.transport) object.type = managed.transport;
  if (managed.command) object.command = managed.command;
  if (managed.args?.length) object.args = managed.args;
  if (managed.url) object.url = managed.url;
  return `${JSON.stringify(object, null, 2)}\n`;
}

function project(entry, brand) {
  if (entry.type === "vendor_native") {
    return {
      kind: "notProjectable",
      reason:
        "vendor_native does not project MCP config fragments; route via D12 capability lane (S2 fail-closed)",
    };
  }
  if (entry.type === "app_native") {
    return {
      kind: "notProjectable",
      reason: "app_native has externalProjection=none; no external MCP fragment",
    };
  }
  if (entry.type !== "portable_mcp") {
    return { kind: "notProjectable", reason: `unknown type ${entry.type}` };
  }
  if (!entry.canonicalDefinition) {
    throw new Error(`portable_mcp missing canonicalDefinition: ${entry.id}`);
  }
  const templates = entry.projectionTemplates || {};
  const ref = templates[brand];
  if (!ref?.templateID) {
    throw new Error(
      `Projection template missing for entry ${entry.id} brand ${brand} (fail-closed)`,
    );
  }
  if (!KNOWN_TEMPLATES[brand]?.has(ref.templateID)) {
    throw new Error(
      `Unknown projection templateID ${ref.templateID} for ${entry.id}/${brand} (fail-closed)`,
    );
  }
  const managed = managedFromCanonical(entry.id, entry.canonicalDefinition);
  const body =
    brand === "codex" ? renderCodexTOML(managed) : renderClaudeJSON(managed);
  const logicalPath =
    brand === "codex"
      ? `~/.codex/config.toml#mcp_servers.${sanitizedIdentifier(entry.id)}`
      : `~/.claude/.mcp.json#mcpServers.${sanitizedIdentifier(entry.id)}`;
  return {
    kind: "projected",
    fragment: {
      entryID: entry.id,
      brand,
      templateID: ref.templateID,
      logicalPath,
      body,
      managed,
      writesNativeConfig: false,
    },
  };
}

function splitLines(text) {
  if (!text) return [];
  const lines = text.split("\n");
  if (text.endsWith("\n") && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function unifiedDiff(path, oldText, newText) {
  const oldLines = splitLines(oldText);
  const newLines = splitLines(newText);
  if (JSON.stringify(oldLines) === JSON.stringify(newLines)) return "";
  const oldCount = oldLines.length;
  const newCount = newLines.length;
  const oldStart = oldCount === 0 ? 0 : 1;
  const newStart = newCount === 0 ? 0 : 1;
  const out = [
    `--- a/${path}`,
    `+++ b/${path}`,
    `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`,
  ];
  for (const line of oldLines) out.push(`-${line}`);
  for (const line of newLines) out.push(`+${line}`);
  return `${out.join("\n")}\n`;
}

function buildPlan(registry, readback, brands) {
  if (Object.prototype.hasOwnProperty.call(readback, "controllerOwnedServerIDs")) {
    throw new Error("controllerOwnedServerIDs is legacy; ownershipRecords are required (fail-closed)");
  }
  const ownershipRecords = validateOwnershipRecords(readback.ownershipRecords);
  const codexByID = Object.fromEntries(
    (readback.codexServers || []).map((s) => [s.serverID, s]),
  );
  const claudeByID = Object.fromEntries(
    (readback.claudeServers || []).map((s) => [s.serverID, s]),
  );

  const items = [];
  const sorted = [...registry.entries].sort((a, b) => a.id.localeCompare(b.id));

  for (const entry of sorted) {
    for (const brand of brands) {
      const outcome = project(entry, brand);
      if (outcome.kind === "notProjectable") {
        if (brand === brands[0]) {
          items.push({
            entryID: entry.id,
            entryType: entry.type,
            brand,
            action: "not_projectable",
            logicalPath: null,
            templateID: null,
            projectedBody: null,
            observedManagedText: null,
            desiredManagedText: null,
            unifiedDiff: "",
            requiresHumanGate: true,
            reason: outcome.reason,
          });
        }
        continue;
      }

      const fragment = outcome.fragment;
      if (entry.desiredState === "disabled") {
        items.push({
          entryID: entry.id,
          entryType: entry.type,
          brand,
          action: "unchanged",
          logicalPath: fragment.logicalPath,
          templateID: fragment.templateID,
          projectedBody: fragment.body,
          observedManagedText: null,
          desiredManagedText: stableManagedText(fragment.managed),
          unifiedDiff: "",
          requiresHumanGate: true,
          reason: "desiredState=disabled; S2 does not stage native disable apply",
        });
        continue;
      }

      const observedServer =
        brand === "codex" ? codexByID[entry.id] : claudeByID[entry.id];
      const desiredText = stableManagedText(fragment.managed);
      const observedManaged = observedServer
        ? managedFromObserved(observedServer)
        : null;
      const observedText = observedManaged
        ? stableManagedText(observedManaged)
        : null;

      let action;
      let reason;
      if (!observedServer) {
        action = "create";
        reason = `registry portable_mcp missing from ${brand} readback`;
      } else if (managedEquals(fragment.managed, observedManaged)) {
        action = "unchanged";
        reason = "managed fields match projected desired";
      } else {
        const matchingOwnership = ownershipRecords.filter(
          (record) =>
            record.serverID === entry.id
            && record.brand === brand
            && record.targetPath === fragment.logicalPath,
        );
        const ownership = matchingOwnership.find((record) => record.state === "active");
        const currentHash = observedManaged ? fragmentSHA256(observedManaged, brand) : null;
        if (matchingOwnership.some((record) => record.state === "rolled_back")) {
          action = "conflict";
          reason =
            "managed fields are associated with rolled-back provenance; re-approval required (fail-closed)";
        } else if (ownership?.state === "active" && currentHash === ownership.appliedFragmentSHA256) {
          action = "update";
          reason =
            `managed fields differ; current fragment matches last-applied hash ${ownership.appliedAtRevision}`;
        } else if (!ownership) {
          action = "conflict";
          reason =
            "managed fields differ and no matching brand/target ownership record exists (fail-closed; human gate)";
        } else {
          action = "conflict";
          reason =
            "managed fields differ; current fragment hash does not match last-applied ownership (user edit; fail-closed)";
        }
      }

      let diff = "";
      if (action === "create") {
        diff = unifiedDiff(fragment.logicalPath, "", desiredText);
      } else if (action === "update" || action === "conflict") {
        diff = unifiedDiff(fragment.logicalPath, observedText || "", desiredText);
      }

      items.push({
        entryID: entry.id,
        entryType: entry.type,
        brand,
        action,
        logicalPath: fragment.logicalPath,
        templateID: fragment.templateID,
        projectedBody: fragment.body,
        observedManagedText: observedText,
        desiredManagedText: desiredText,
        unifiedDiff: diff,
        requiresHumanGate: true,
        reason,
      });
    }
  }

  return {
    schema: "TatwoPluginStagedPlanV1",
    registryRevision: registry.registryRevision,
    rendererVersion: RENDERER_VERSION,
    brands,
    items,
    requiresHumanGate: true,
    writesNativeConfig: false,
    notes: [
      "S2 staged projection + diff only; no native apply",
      "requiresHumanGate is always true; S3 owns per-apply human gate",
      "conflict = observed differs from registry and server is not proven controller-owned",
      "Paths are logical (~/.codex|~/.claude); real IO uses injected fixture paths only",
    ],
  };
}

function loadServersFromPath(path, brand) {
  if (!path) return [];
  assertNotDefaultHomePath(path);
  const abs = resolve(path);
  if (!existsSync(abs)) throw new Error(`readback path not found: ${abs}`);
  const text = readFileSync(abs, "utf8");
  if (brand === "codex") return parseCodexTOML(text);
  return parseClaudeJSON(text);
}

function parseCodexTOML(text) {
  const servers = {};
  const order = [];
  let current = null;
  for (const rawLine of text.split("\n")) {
    const line = rawLine.replace(/#.*$/, "").trim();
    if (!line) continue;
    if (line.startsWith("[") && line.endsWith("]")) {
      current = null;
      const body = line.slice(1, -1).trim();
      if (!body.startsWith("mcp_servers.")) continue;
      let id = body.slice("mcp_servers.".length);
      if (id.startsWith('"') && id.endsWith('"')) id = id.slice(1, -1);
      if (id.includes(".")) continue;
      current = id;
      if (!servers[id]) {
        servers[id] = {};
        order.push(id);
      }
      continue;
    }
    if (!current) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (key === "args") {
      const inner = value.replace(/^\[/, "").replace(/\]$/, "");
      servers[current].args = inner
        .split(",")
        .map((s) => s.trim().replace(/^"/, "").replace(/"$/, ""))
        .filter(Boolean);
    } else {
      if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
      servers[current][key] = value;
    }
  }
  return order.map((serverID) => ({
    serverID,
    source: "codex_config_toml",
    transport: servers[serverID].transport || servers[serverID].type || null,
    command: servers[serverID].command || null,
    args: servers[serverID].args || [],
    url: servers[serverID].url || null,
  }));
}

function parseClaudeJSON(text) {
  const root = JSON.parse(text);
  const serversObject = root.mcpServers || {};
  return Object.keys(serversObject)
    .sort()
    .map((serverID) => {
      const object = serversObject[serverID] || {};
      return {
        serverID,
        source: "claude_mcp_json",
        transport: object.type || object.transport || null,
        command: object.command || null,
        args: Array.isArray(object.args) ? object.args : [],
        url: object.url || null,
      };
    });
}

function normalizeReadback(raw) {
  if (Object.prototype.hasOwnProperty.call(raw, "controllerOwnedServerIDs")) {
    throw new Error("controllerOwnedServerIDs is legacy; ownershipRecords are required (fail-closed)");
  }
  let codexServers = raw.codexServers || [];
  let claudeServers = raw.claudeServers || [];
  if (raw.codexPath) {
    codexServers = loadServersFromPath(raw.codexPath, "codex");
  }
  if (raw.claudePath) {
    claudeServers = loadServersFromPath(raw.claudePath, "claude");
  }
  return {
    codexServers,
    claudeServers,
    ownershipRecords: validateOwnershipRecords(raw.ownershipRecords),
    codexPath: raw.codexPath || null,
    claudePath: raw.claudePath || null,
  };
}


// ---------------------------------------------------------------------------
// S3 apply engine (JS mirror of TatwoPluginApplyEngineV1; fixture targets only)
// ---------------------------------------------------------------------------

function sha256Hex(data) {
  return createHash("sha256").update(data).digest("hex");
}

function planDigest(plan) {
  const lines = [];
  lines.push(`schema=${plan.schema}`);
  lines.push(`registryRevision=${plan.registryRevision}`);
  lines.push(`rendererVersion=${plan.rendererVersion}`);
  const brands = [...(plan.brands || [])].map(String).sort();
  lines.push(`brands=${brands.join(",")}`);
  const items = [...(plan.items || [])].sort((a, b) => {
    const aid = `${a.brand}:${a.entryID}`;
    const bid = `${b.brand}:${b.entryID}`;
    return aid < bid ? -1 : aid > bid ? 1 : 0;
  });
  for (const item of items) {
    lines.push(
      [
        `id=${item.brand}:${item.entryID}`,
        `action=${item.action}`,
        `entryType=${item.entryType}`,
        `logicalPath=${item.logicalPath || ""}`,
        `templateID=${item.templateID || ""}`,
        `projectedBody=${item.projectedBody || ""}`,
        `desiredManagedText=${item.desiredManagedText || ""}`,
        `observedManagedText=${item.observedManagedText || ""}`,
        `unifiedDiff=${item.unifiedDiff || ""}`,
        `reason=${item.reason || ""}`,
      ].join("|"),
    );
  }
  return sha256Hex(lines.join("\n"));
}

function backupTimestamp(date = new Date()) {
  const iso = date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  // Date has millisecond precision; include a monotonic nanosecond token and
  // still retain bounded sequence retries for equal/colliding values.
  const nanos = process.hrtime.bigint().toString().slice(-9).padStart(9, "0");
  return `${iso}-${nanos}`;
}

function writeAtomically(filePath, content) {
  const dir = dirname(filePath);
  mkdirSync(dir, { recursive: true });
  const tmp = join(dir, `.${PathBase(filePath)}.tatwo-apply.${randomUUID()}.tmp`);
  writeFileSync(tmp, content, "utf8");
  renameSync(tmp, filePath);
}

function PathBase(p) {
  return p.split(/[/\\]/).pop();
}

function mergeCodexTOML(existingText, items) {
  const preamble = [];
  const tables = new Map();
  const order = [];
  let currentID = null;
  for (const line of (existingText || "").split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
      const body = trimmed.slice(1, -1).trim();
      if (body.startsWith("mcp_servers.")) {
        let rest = body.slice("mcp_servers.".length);
        let id = rest;
        if (rest.startsWith('"') && rest.endsWith('"') && rest.length >= 2) {
          id = rest.slice(1, -1);
        }
        currentID = id;
        if (!tables.has(id)) {
          tables.set(id, []);
          order.push(id);
        }
        tables.get(id).push(line);
        continue;
      }
      currentID = null;
      preamble.push(line);
      continue;
    }
    if (currentID != null) {
      tables.get(currentID).push(line);
    } else {
      preamble.push(line);
    }
  }
  for (const item of items) {
    const body = item.projectedBody || "";
    let bodyLines = body.split("\n");
    if (body.endsWith("\n") && bodyLines[bodyLines.length - 1] === "") {
      bodyLines = bodyLines.slice(0, -1);
    }
    if (!tables.has(item.entryID)) order.push(item.entryID);
    tables.set(item.entryID, bodyLines);
  }
  while (preamble.length && preamble[preamble.length - 1].trim() === "") preamble.pop();
  const out = [...preamble];
  if (out.length && out[out.length - 1] !== "") out.push("");
  for (const id of order) {
    const lines = tables.get(id) || [];
    out.push(...lines);
    if (out.length && out[out.length - 1] !== "") out.push("");
  }
  let text = out.join("\n");
  if (!text.endsWith("\n")) text += "\n";
  return text;
}

function mergeClaudeJSON(existingText, items) {
  let root;
  if (!existingText || !existingText.trim()) {
    root = { mcpServers: {} };
  } else {
    root = JSON.parse(existingText);
    if (!root || typeof root !== "object" || Array.isArray(root)) {
      throw new Error("existing Claude JSON root must be object");
    }
  }
  const servers = root.mcpServers && typeof root.mcpServers === "object" ? { ...root.mcpServers } : {};
  for (const item of items) {
    servers[item.entryID] = JSON.parse(item.projectedBody);
  }
  root.mcpServers = servers;
  let text = JSON.stringify(root, Object.keys(root).sort(), 2);
  // stable-ish pretty: sortedKeys at top only; good enough for selftest
  text = JSON.stringify(root, null, 2);
  if (!text.endsWith("\n")) text += "\n";
  return text;
}

function parseCodexServers(text) {
  // reuse existing lightweight parser if available via parseRenderedCodexTOML style
  const servers = [];
  let current = null;
  let fields = null;
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[") && line.endsWith("]")) {
      if (current && fields) {
        servers.push(serverFromFields(current, fields));
      }
      current = null;
      fields = null;
      const body = line.slice(1, -1).trim();
      if (!body.startsWith("mcp_servers.")) continue;
      let rest = body.slice("mcp_servers.".length);
      if (rest.startsWith('"') && rest.endsWith('"')) rest = rest.slice(1, -1);
      current = rest;
      fields = {};
      continue;
    }
    if (!current) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (key === "args") {
      fields.args = JSON.parse(value.replace(/'/g, '"'));
    } else {
      if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
      fields[key] = value;
    }
  }
  if (current && fields) servers.push(serverFromFields(current, fields));
  return servers;
}

function serverFromFields(id, fields) {
  return {
    serverID: id,
    transport: fields.transport || fields.type || null,
    command: fields.command || null,
    args: Array.isArray(fields.args) ? fields.args : [],
    url: fields.url || null,
  };
}

function renderCodexBody(managed) {
  const lines = [];
  const id = managed.serverID;
  const bare = /^[A-Za-z0-9_]+$/.test(id);
  lines.push(bare ? `[mcp_servers.${id}]` : `[mcp_servers.${JSON.stringify(id)}]`);
  if (managed.command) lines.push(`command = ${JSON.stringify(managed.command)}`);
  if (managed.args && managed.args.length) {
    lines.push(`args = [${managed.args.map((a) => JSON.stringify(a)).join(", ")}]`);
  }
  if (managed.url) lines.push(`url = ${JSON.stringify(managed.url)}`);
  if (managed.transport) lines.push(`transport = ${JSON.stringify(managed.transport)}`);
  return lines.join("\n") + "\n";
}

function fragmentHashFromManaged(managed, brand) {
  if (brand === "codex") return sha256Hex(renderCodexBody(managed));
  // claude: pretty JSON object
  const obj = {};
  if (managed.transport) obj.type = managed.transport;
  if (managed.command) obj.command = managed.command;
  if (managed.args && managed.args.length) obj.args = managed.args;
  if (managed.url) obj.url = managed.url;
  let text = JSON.stringify(obj, null, 2);
  if (!text.endsWith("\n")) text += "\n";
  return sha256Hex(text);
}

function reserveBackup(sourcePath, stamp, maxAttempts = 64) {
  for (let sequence = 0; sequence < maxAttempts; sequence += 1) {
    const suffix = sequence === 0 ? stamp : `${stamp}-${sequence}`;
    const candidate = `${sourcePath}.tatwo-backup-${suffix}`;
    try {
      // COPYFILE_EXCL maps to an exclusive create (O_CREAT|O_EXCL) in Node's
      // fs implementation; no check-then-copy race is used.
      copyFileSync(sourcePath, candidate, fsConstants.COPYFILE_EXCL);
      return candidate;
    } catch (error) {
      if (error?.code === "EEXIST" || existsSync(candidate)) continue;
      throw new Error(`backup copy failed: ${error.message || error}`);
    }
  }
  throw new Error(
    `Apply rejected: could not reserve a unique backup path after bounded retries: ${sourcePath}.tatwo-backup-${stamp}`,
  );
}

function applyPlan({ plan, targetPath, authorization, acknowledgeUserConfig = false, now = new Date() }) {
  if (!targetPath || !String(targetPath).trim()) {
    throw new Error("Apply rejected: target path is empty (must inject fixture/target; no default home)");
  }
  const target = canonicalTargetPath(targetPath);
  assertTargetPathPolicy(target, { allowHomeConfig: acknowledgeUserConfig, label: "target" });

  const conflicts = (plan.items || []).filter((i) => i.action === "conflict").map((i) => i.entryID).sort();
  if (conflicts.length) {
    throw new Error(
      `Apply rejected: plan contains conflict item(s) ${conflicts.join(", ")}; whole batch refused (no partial apply)`,
    );
  }

  const digest = planDigest(plan);
  if (!authorization || !authorization.approver || !String(authorization.approver).trim()) {
    throw new Error("Apply rejected: humanGateToken.approver is empty");
  }
  const approved = String(authorization.approvedPlanDigest || "").toLowerCase();
  if (approved !== digest.toLowerCase()) {
    throw new Error(
      `Apply rejected: humanGateToken.approvedPlanDigest ${approved} does not match plan digest ${digest}`,
    );
  }

  const applyable = (plan.items || []).filter((i) => i.action === "create" || i.action === "update");
  const brands = [...new Set(
    applyable.length
      ? applyable.map((i) => i.brand)
      : (plan.brands || []),
  )];
  if (brands.length !== 1) {
    throw new Error(`Apply rejected: mixed brands ${brands.sort().join(",")}`);
  }
  const expectedBrand = brands[0];

  const skipped = (plan.items || [])
    .filter((i) => i.action === "unchanged" || i.action === "not_projectable")
    .map((i) => i.entryID)
    .sort();

  const recordedAt = now.toISOString();
  const approvedTarget = canonicalTargetPath(authorization.approvedTargetPath || "");
  if (approvedTarget !== target) {
    throw new Error(
      `Apply rejected: humanGateToken.approvedTargetPath ${authorization.approvedTargetPath || ""} does not match canonical target ${target}`,
    );
  }
  if (authorization.approvedBrand !== expectedBrand) {
    throw new Error(
      `Apply rejected: humanGateToken.approvedBrand ${authorization.approvedBrand || ""} does not match apply brand ${expectedBrand}`,
    );
  }
  if (!applyable.length) {
    return {
      schema: "TatwoPluginApplyReceiptV1",
      status: "noop",
      registryRevision: plan.registryRevision,
      planDigest: digest,
      targetPath: target,
      backupPath: null,
      ownershipRecords: [],
      appliedEntryIDs: [],
      skippedEntryIDs: skipped,
      approver: authorization.approver,
      approvedAt: authorization.approvedAt,
      recordedAt,
      notes: ["single-target apply enforced; multi-target atomic transaction is rejected (not implemented)"],
    };
  }
  const brand = expectedBrand;
  for (const item of applyable) {
    if (!item.projectedBody) throw new Error(`Apply rejected: item ${item.entryID} missing projectedBody`);
  }

  const existed = existsSync(target);
  const beforeText = existed ? readFileSync(target, "utf8") : "";
  const beforeSHA = existed ? sha256Hex(beforeText) : null;

  let backupPath = null;
  if (existed) {
    backupPath = reserveBackup(target, backupTimestamp(now));
  }

  let merged;
  try {
    merged = brand === "codex"
      ? mergeCodexTOML(beforeText, applyable)
      : mergeClaudeJSON(beforeText, applyable);
  } catch (error) {
    throw new Error(`Apply write failed: ${error.message || error}`);
  }

  try {
    writeAtomically(target, merged);
  } catch (error) {
    if (backupPath && existsSync(backupPath)) {
      writeAtomically(target, readFileSync(backupPath, "utf8"));
    }
    throw new Error(`Apply write failed: ${error.message || error}`);
  }

  try {
    const afterText = readFileSync(target, "utf8");
    // verify
    if (brand === "codex") {
      const observed = parseCodexServers(afterText);
      const byID = Object.fromEntries(observed.map((s) => [s.serverID, s]));
      for (const item of applyable) {
        const expected = sha256Hex(item.projectedBody);
        const server = byID[item.entryID];
        if (!server) throw new Error(`server ${item.entryID} missing after apply`);
        const actual = fragmentHashFromManaged(server, "codex");
        if (actual !== expected) {
          throw new Error(
            `fragment hash mismatch for ${item.entryID}: expected ${expected} got ${actual}`,
          );
        }
      }
    } else {
      const root = JSON.parse(afterText);
      for (const item of applyable) {
        const expected = sha256Hex(item.projectedBody);
        const obj = root.mcpServers?.[item.entryID];
        if (!obj) throw new Error(`server ${item.entryID} missing after apply`);
        const managed = {
          serverID: item.entryID,
          transport: obj.type || obj.transport || null,
          command: obj.command || null,
          args: Array.isArray(obj.args) ? obj.args : [],
          url: obj.url || null,
        };
        const actual = fragmentHashFromManaged(managed, "claude");
        if (actual !== expected) {
          throw new Error(
            `fragment hash mismatch for ${item.entryID}: expected ${expected} got ${actual}`,
          );
        }
      }
    }

    const ownershipRecords = applyable.map((item) => ({
      serverID: item.entryID,
      brand,
      targetPath: item.logicalPath
        || (brand === "codex"
          ? `~/.codex/config.toml#mcp_servers.${item.entryID}`
          : `~/.claude/.mcp.json#mcpServers.${item.entryID}`),
      appliedFragmentSHA256: sha256Hex(item.projectedBody),
      appliedAtRevision: plan.registryRevision,
      appliedAt: recordedAt,
      state: "active",
    })).sort((a, b) => (a.serverID < b.serverID ? -1 : 1));

    return {
      schema: "TatwoPluginApplyReceiptV1",
      status: "applied",
      registryRevision: plan.registryRevision,
      planDigest: digest,
      targetPath: target,
      backupPath,
      beforeSHA256: beforeSHA,
      afterSHA256: sha256Hex(afterText),
      ownershipRecords,
      appliedEntryIDs: applyable.map((i) => i.entryID).sort(),
      skippedEntryIDs: skipped,
      approver: authorization.approver,
      approvedAt: authorization.approvedAt,
      recordedAt,
    };
  } catch (error) {
    if (backupPath && existsSync(backupPath)) {
      writeAtomically(target, readFileSync(backupPath, "utf8"));
      throw new Error(
        `Apply read-back mismatch: ${error.message || error}; target restored from backup ${backupPath}`,
      );
    }
    if (existsSync(target) && !existed) {
      try { unlinkSync(target); } catch { /* ignore */ }
    }
    throw new Error(`Apply read-back mismatch: ${error.message || error}`);
  }
}

function rollbackFromReceipt(receipt) {
  const recordedAt = new Date().toISOString();
  const before = validateOwnershipRecords(receipt.ownershipRecords || []);
  const after = before.map((record) => ({ ...record, state: "rolled_back" }));
  if (!receipt.backupPath) {
    return {
      schema: "TatwoPluginRollbackReceiptV1",
      status: "rollback_failed",
      targetPath: receipt.targetPath,
      backupPath: null,
      originalApplyPlanDigest: receipt.planDigest,
      originalApplyStatus: receipt.status,
      ownershipRecordsBefore: before,
      ownershipRecordsAfter: after,
      provenanceNote: "rollback failed; ownership remains rolled_back to prevent false unchanged",
      recordedAt,
      error: "Rollback fail-closed: backup missing at (receipt.backupPath is nil)",
    };
  }
  if (!existsSync(receipt.backupPath)) {
    return {
      schema: "TatwoPluginRollbackReceiptV1",
      status: "rollback_failed",
      targetPath: receipt.targetPath,
      backupPath: receipt.backupPath,
      originalApplyPlanDigest: receipt.planDigest,
      originalApplyStatus: receipt.status,
      ownershipRecordsBefore: before,
      ownershipRecordsAfter: after,
      provenanceNote: "rollback failed; ownership remains rolled_back to prevent false unchanged",
      recordedAt,
      error: `Rollback fail-closed: backup missing at ${receipt.backupPath}`,
    };
  }
  const data = readFileSync(receipt.backupPath, "utf8");
  writeAtomically(receipt.targetPath, data);
  return {
    schema: "TatwoPluginRollbackReceiptV1",
    status: "rollback_passed",
    targetPath: receipt.targetPath,
    backupPath: receipt.backupPath,
    restoredSHA256: sha256Hex(data),
    originalApplyPlanDigest: receipt.planDigest,
    originalApplyStatus: receipt.status,
    ownershipRecordsBefore: before,
    ownershipRecordsAfter: after,
    provenanceNote: "ownership records marked rolledBack; feed ownershipRecordsAfter into next plan",
    recordedAt,
  };
}


function printPlan(plan, asJson) {
  if (asJson) {
    console.log(JSON.stringify(plan, null, 2));
    return;
  }
  console.log(`schema: ${plan.schema}`);
  console.log(`registryRevision: ${plan.registryRevision}`);
  console.log(`rendererVersion: ${plan.rendererVersion}`);
  console.log(`requiresHumanGate: ${plan.requiresHumanGate}`);
  console.log(`writesNativeConfig: ${plan.writesNativeConfig}`);
  console.log(`brands: ${plan.brands.join(", ")}`);
  console.log(`items: ${plan.items.length}`);
  console.log("");
  for (const item of plan.items) {
    console.log(
      `## ${item.action}  ${item.entryID}  (${item.brand})  type=${item.entryType}`,
    );
    if (item.logicalPath) console.log(`logicalPath: ${item.logicalPath}`);
    if (item.reason) console.log(`reason: ${item.reason}`);
    console.log(`requiresHumanGate: ${item.requiresHumanGate}`);
    if (item.unifiedDiff) {
      console.log("diff:");
      console.log(item.unifiedDiff.replace(/\n$/, ""));
    } else if (item.action !== "not_projectable" && item.action !== "unchanged") {
      console.log("diff: (empty)");
    }
    console.log("");
  }
  console.log("S3 apply: use apply --plan <staged.json> --target <path> --authorization <file>");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runSelftest() {
  const registry = {
    schema: "TatwoPluginControllerRegistryV1",
    registryRevision: "s2-selftest",
    source: "os_registry",
    entries: [
      {
        id: "alpha",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: {
          protocol: "mcp",
          transport: "stdio",
          command: "alpha",
          args: ["a"],
        },
        projectionTemplates: {
          codex: { templateID: "codex.mcp-server.v1" },
          claude: { templateID: "claude.mcp-server.v1" },
        },
      },
      {
        id: "beta",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: {
          protocol: "mcp",
          transport: "stdio",
          command: "beta-new",
          args: ["b2"],
        },
        projectionTemplates: {
          codex: { templateID: "codex.mcp-server.v1" },
          claude: { templateID: "claude.mcp-server.v1" },
        },
      },
      {
        id: "gamma",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: {
          protocol: "mcp",
          transport: "stdio",
          command: "gamma",
          args: ["g"],
        },
        projectionTemplates: {
          codex: { templateID: "codex.mcp-server.v1" },
          claude: { templateID: "claude.mcp-server.v1" },
        },
      },
      {
        id: "delta",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: {
          protocol: "mcp",
          transport: "stdio",
          command: "delta-registry",
          args: ["d1"],
        },
        projectionTemplates: {
          codex: { templateID: "codex.mcp-server.v1" },
          claude: { templateID: "claude.mcp-server.v1" },
        },
      },
      {
        id: "computer-use",
        type: "vendor_native",
        desiredState: "enabled",
        implementations: [
          {
            implementationID: "codex-computer-use",
            provider: "codex",
            capabilityID: "computer-use",
            entrypoint: "codex.native.computer_use",
            priority: 10,
          },
        ],
        routing: {
          laneRef: "d12-capability-lane:computer-use",
          selection: "capability_then_priority",
          fallback: "declared_only",
        },
      },
      {
        id: "tatwo-right-panel",
        type: "app_native",
        desiredState: "enabled",
        appFeature: {
          moduleID: "TatwoUltraworkMac.right_panel",
          builtIn: true,
          externalProjection: "none",
        },
      },
    ],
  };

  const readback = {
    codexServers: [
      {
        serverID: "beta",
        command: "beta-old",
        args: ["b1"],
        transport: "stdio",
      },
      {
        serverID: "gamma",
        command: "gamma",
        args: ["g"],
        transport: "stdio",
      },
      {
        serverID: "delta",
        command: "delta-hand",
        args: ["hand"],
        transport: "stdio",
      },
    ],
    claudeServers: [],
    ownershipRecords: [
      {
        serverID: "beta",
        brand: "codex",
        targetPath: "~/.codex/config.toml#mcp_servers.beta",
        appliedFragmentSHA256: fragmentSHA256(
          managedFromObserved({
            serverID: "beta",
            command: "beta-old",
            args: ["b1"],
            transport: "stdio",
          }),
          "codex",
        ),
        appliedAtRevision: "s2-selftest",
        appliedAt: "2026-07-30T00:00:00Z",
      },
    ],
  };

  const plan = buildPlan(registry, readback, ["codex"]);
  const byID = Object.fromEntries(plan.items.map((i) => [i.entryID, i]));

  assert(plan.requiresHumanGate === true, "plan requiresHumanGate");
  assert(plan.writesNativeConfig === false, "plan writesNativeConfig false");
  assert(byID.alpha.action === "create", "alpha create");
  assert(byID.beta.action === "update", "beta update");
  assert(byID.gamma.action === "unchanged", "gamma unchanged");
  assert(byID.delta.action === "conflict", "delta conflict");
  assert(byID["computer-use"].action === "not_projectable", "vendor not projectable");
  assert(
    byID["tatwo-right-panel"].action === "not_projectable",
    "app not projectable",
  );

  const betaObserved = readback.codexServers[0];
  const betaDesiredRegistry = registry.entries.find((entry) => entry.id === "beta");
  const betaOnlyRegistry = { ...registry, entries: [betaDesiredRegistry] };
  const noOwnershipPlan = buildPlan(
    betaOnlyRegistry,
    { codexServers: [betaObserved], claudeServers: [], ownershipRecords: [] },
    ["codex"],
  );
  assert(noOwnershipPlan.items[0].action === "conflict", "missing ownership is conflict");
  const betaHash = fragmentSHA256(managedFromObserved(betaObserved), "codex");
  const staleOwnershipPlan = buildPlan(
    betaOnlyRegistry,
    {
      codexServers: [betaObserved],
      claudeServers: [],
      ownershipRecords: [{
        serverID: "beta",
        brand: "codex",
        targetPath: "~/.codex/config.toml#mcp_servers.beta",
        appliedFragmentSHA256: "0".repeat(64),
        appliedAtRevision: "s2-selftest",
        appliedAt: "2026-07-30T00:00:00Z",
      }],
    },
    ["codex"],
  );
  assert(staleOwnershipPlan.items[0].action === "conflict", "stale ownership is conflict");
  const crossBrandOwnershipPlan = buildPlan(
    betaOnlyRegistry,
    {
      codexServers: [betaObserved],
      claudeServers: [],
      ownershipRecords: [{
        serverID: "beta",
        brand: "claude",
        targetPath: "~/.claude/.mcp.json#mcpServers.beta",
        appliedFragmentSHA256: betaHash,
        appliedAtRevision: "s2-selftest",
        appliedAt: "2026-07-30T00:00:00Z",
      }],
    },
    ["codex"],
  );
  assert(crossBrandOwnershipPlan.items[0].action === "conflict", "cross-brand ownership is conflict");
  const matchingOwnershipPlan = buildPlan(
    betaOnlyRegistry,
    {
      codexServers: [betaObserved],
      claudeServers: [],
      ownershipRecords: [{
        serverID: "beta",
        brand: "codex",
        targetPath: "~/.codex/config.toml#mcp_servers.beta",
        appliedFragmentSHA256: betaHash,
        appliedAtRevision: "s2-selftest",
        appliedAt: "2026-07-30T00:00:00Z",
      }],
    },
    ["codex"],
  );
  assert(matchingOwnershipPlan.items[0].action === "update", "matching ownership permits update");

  // Adversarial TOML corpus: escaping must preserve parseable basic strings
  // and raw IDs must never enter paths or diff headers.
  const hostile = {
    id: 'bad"]\n[evil',
    type: "portable_mcp",
    desiredState: "enabled",
    canonicalDefinition: {
      protocol: "mcp",
      transport: "stdio",
      command: 'runner\nmalicious = "yes"',
      args: ["ok", "line1\nline2", "]\u0001"],
    },
    projectionTemplates: {
      codex: { templateID: "codex.mcp-server.v1" },
      claude: { templateID: "claude.mcp-server.v1" },
    },
  };
  const hostileFragment = project(hostile, "codex").fragment;
  assert(!hostileFragment.logicalPath.includes("\n"), "hostile path newline");
  assert(!hostileFragment.logicalPath.includes("\r"), "hostile path carriage return");
  assert(!hostileFragment.logicalPath.includes(hostile.id), "raw hostile id in path");
  assert(hostileFragment.body.includes("\\n"), "hostile newline not escaped");
  assert(hostileFragment.body.includes("\\\""), "hostile quote not escaped");
  assert(hostileFragment.body.includes("\\u0001"), "hostile control not escaped");
  const hostileRoundTrip = parseRenderedCodexTOML(hostileFragment.body);
  assert(hostileRoundTrip.serverID === hostile.id, "hostile TOML ID round-trip");
  assert(
    hostileRoundTrip.fields.command === hostile.canonicalDefinition.command,
    "hostile TOML command round-trip",
  );
  assert(
    JSON.stringify(hostileRoundTrip.fields.args) === JSON.stringify(hostile.canonicalDefinition.args),
    "hostile TOML args round-trip",
  );
  assert(
    !unifiedDiff(hostileFragment.logicalPath, "", hostileFragment.body).includes(hostile.id),
    "raw hostile id in diff header",
  );

  // template missing fail-closed
  let threw = false;
  try {
    project(
      {
        id: "x",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: {
          protocol: "mcp",
          transport: "stdio",
          command: "x",
        },
        projectionTemplates: { codex: { templateID: "codex.mcp-server.v1" } },
      },
      "claude",
    );
  } catch {
    threw = true;
  }
  assert(threw, "missing brand template must fail-closed");

  // stable diff
  const d1 = unifiedDiff("p", "command=old\n", "command=new\n");
  const d2 = unifiedDiff("p", "command=old\n", "command=new\n");
  assert(d1 === d2, "diff stable");
  assert(d1.includes("-command=old"), "diff old");
  assert(d1.includes("+command=new"), "diff new");

  // ---- S3 apply selftest (fixture target only; never ~/.codex|~/.claude) ----
  const fixtureRoot = mkdtempSync(join(tmpdir(), "tatwo-plugin-s3-"));
  try {
    const target = join(fixtureRoot, "config.toml");
    writeFileSync(target, "model = \"keep\"\n", "utf8");
    const body = project(
      {
        id: "alpha",
        type: "portable_mcp",
        desiredState: "enabled",
        canonicalDefinition: { protocol: "mcp", transport: "stdio", command: "alpha", args: [] },
        projectionTemplates: { codex: { templateID: "codex.mcp-server.v1" } },
      },
      "codex",
    ).fragment.body;

    const goodPlan = {
      schema: "TatwoPluginStagedPlanV1",
      registryRevision: "s3-selftest",
      rendererVersion: RENDERER_VERSION,
      brands: ["codex"],
      items: [{
        entryID: "alpha",
        entryType: "portable_mcp",
        brand: "codex",
        action: "create",
        logicalPath: "~/.codex/config.toml#mcp_servers.alpha",
        templateID: "codex.mcp-server.v1",
        projectedBody: body,
        desiredManagedText: "serverID=alpha\ntransport=stdio\ncommand=alpha\nargs=[]\n",
        observedManagedText: null,
        unifiedDiff: "diff",
        requiresHumanGate: true,
        reason: "create",
      }],
      requiresHumanGate: true,
      writesNativeConfig: false,
      notes: [],
    };
    const authFor = (approvedPlan, approvedTarget = target, approvedBrand = "codex") => ({
      approvedPlanDigest: planDigest(approvedPlan),
      approvedTargetPath: canonicalTargetPath(approvedTarget),
      approvedBrand,
      approver: "human@test",
      approvedAt: "2026-07-30T00:00:00Z",
    });

    // conflict whole-batch reject
    const conflictPlan = {
      ...goodPlan,
      registryRevision: "s3-conflict",
      items: [
        goodPlan.items[0],
        { ...goodPlan.items[0], entryID: "delta", action: "conflict", projectedBody: body },
      ],
    };
    let threw = false;
    try {
      applyPlan({
        plan: conflictPlan,
        targetPath: target,
        authorization: authFor(conflictPlan),
      });
    } catch (e) {
      threw = /conflict/i.test(String(e.message || e));
    }
    assert(threw, "conflict must reject whole batch");
    assert(readFileSync(target, "utf8") === "model = \"keep\"\n", "conflict must not mutate target");

    // digest mismatch
    threw = false;
    try {
      applyPlan({
        plan: goodPlan,
        targetPath: target,
        authorization: {
          approvedPlanDigest: "ab".repeat(32),
          approvedTargetPath: canonicalTargetPath(target),
          approvedBrand: "codex",
          approver: "t",
          approvedAt: "2026-07-30T00:00:00Z",
        },
      });
    } catch (e) {
      threw = /digest/i.test(String(e.message || e));
    }
    assert(threw, "digest mismatch must reject");

    // Authorization is bound to the canonical target and brand, not merely
    // to the plan digest.
    const alternateTarget = join(fixtureRoot, "alternate.toml");
    writeFileSync(alternateTarget, "model = \"alternate\"\n", "utf8");
    threw = false;
    try {
      applyPlan({
        plan: goodPlan,
        targetPath: alternateTarget,
        authorization: authFor(goodPlan, target, "codex"),
      });
    } catch (e) {
      threw = /approvedTargetPath|canonical target/i.test(String(e.message || e));
    }
    assert(threw, "authorization target binding");
    threw = false;
    try {
      applyPlan({
        plan: goodPlan,
        targetPath: target,
        authorization: authFor(goodPlan, target, "claude"),
      });
    } catch (e) {
      threw = /approvedBrand|apply brand/i.test(String(e.message || e));
    }
    assert(threw, "authorization brand binding");

    // happy path + backup no-overwrite + rollback
    const receipt = applyPlan({
      plan: goodPlan,
      targetPath: target,
      authorization: authFor(goodPlan),
      now: new Date("2026-07-30T12:00:00.000Z"),
    });
    assert(receipt.status === "applied", "apply status");
    assert(existsSync(receipt.backupPath), "backup created");
    assert(readFileSync(target, "utf8").includes("mcp_servers.alpha"), "target written");
    assert(receipt.ownershipRecords.length === 1, "ownership record");
    assert(receipt.ownershipRecords[0].appliedFragmentSHA256, "ownership hash");

    // Same-second apply must reserve a second exclusive backup, not overwrite
    // the first one or reject a legitimate retry.
    const secondPlan = { ...goodPlan, registryRevision: "s3-backup2" };
    const secondReceipt = applyPlan({
      plan: secondPlan,
      targetPath: target,
      authorization: authFor(secondPlan),
      now: new Date("2026-07-30T12:00:00.000Z"),
    });
    assert(secondReceipt.status === "applied", "same-second retry applies");
    assert(secondReceipt.backupPath !== receipt.backupPath, "backups are unique");
    assert(existsSync(receipt.backupPath), "first backup remains");
    assert(existsSync(secondReceipt.backupPath), "second backup exists");
    assert(
      readFileSync(receipt.backupPath, "utf8") === "model = \"keep\"\n",
      "first backup is not overwritten",
    );

    const rb = rollbackFromReceipt(receipt);
    assert(rb.status === "rollback_passed", "rollback passed");
    assert(readFileSync(target, "utf8") === "model = \"keep\"\n", "rollback restores");
    assert(rb.ownershipRecordsBefore.length === 1, "rollback provenance before");
    assert(rb.ownershipRecordsAfter[0].state === "rolled_back", "rollback provenance after");

    // missing backup fail-closed
    const missing = rollbackFromReceipt({
      ...receipt,
      backupPath: join(fixtureRoot, "missing.tatwo-backup-X"),
    });
    assert(missing.status === "rollback_failed", "missing backup fail-closed");
    assert(/missing/i.test(missing.error || ""), "missing backup error");

    // home config requires flag
    const homeTarget = join(homedir(), ".codex", "config.toml");
    threw = false;
    try {
      applyPlan({
        plan: goodPlan,
        targetPath: homeTarget,
        authorization: {
          approvedPlanDigest: planDigest(goodPlan),
          approver: "t",
          approvedAt: "2026-07-30T00:00:00Z",
        },
        acknowledgeUserConfig: false,
      });
    } catch (e) {
      threw = /i-understand-user-config|home agent config/i.test(String(e.message || e));
    }
    assert(threw, "home target requires human flag");

    // A symlink parent into ~/.codex must still be gated even when the leaf
    // does not exist.  The symlink is fixture-only; no home config is written.
    const alias = join(fixtureRoot, "codex-alias");
    symlinkSync(join(homedir(), ".codex"), alias);
    threw = false;
    try {
      applyPlan({
        plan: goodPlan,
        targetPath: join(alias, "new-config.toml"),
        authorization: authFor(goodPlan, join(alias, "new-config.toml")),
        acknowledgeUserConfig: false,
      });
    } catch (e) {
      threw = /home agent config|i-understand-user-config/i.test(String(e.message || e));
    }
    assert(threw, "symlink parent home target requires human flag");
  } finally {
    rmSync(fixtureRoot, { recursive: true, force: true });
  }

  // seed registry load (if present)
  const seedPath = join(REPO_ROOT, "registry", "plugins.v1.json");
  if (existsSync(seedPath)) {
    const seed = validateRegistry(loadJSON(seedPath));
    const seedPlan = buildPlan(
      seed,
      { codexServers: [], claudeServers: [], ownershipRecords: [] },
      ["codex", "claude"],
    );
    assert(seedPlan.items.some((i) => i.action === "create"), "seed creates");
    assert(
      seedPlan.items.some((i) => i.entryID === "computer-use" && i.action === "not_projectable"),
      "seed vendor",
    );
  }

  console.log("tatwo-plugin-controller selftest: PASS");
  console.log(
    JSON.stringify(
      {
        fourStates: {
          create: byID.alpha.action,
          update: byID.beta.action,
          unchanged: byID.gamma.action,
          conflict: byID.delta.action,
        },
        requiresHumanGate: plan.requiresHumanGate,
        writesNativeConfig: plan.writesNativeConfig,
        sampleCreateDiff: byID.alpha.unifiedDiff,
        sampleUpdateDiff: byID.beta.unifiedDiff,
        sampleConflictDiff: byID.delta.unifiedDiff,
      },
      null,
      2,
    ),
  );
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.selftest) {
    try {
      runSelftest();
      process.exit(0);
    } catch (error) {
      console.error(`selftest FAIL: ${error.message || error}`);
      process.exit(1);
    }
  }

  if (options.command === "apply") {
    if (!options.plan || !options.target || !options.authorization) {
      usage("apply requires --plan, --target, and --authorization");
      process.exit(1);
    }
    try {
      const plan = loadJSON(options.plan, { allowHomeConfig: false });
      const authorization = loadJSON(options.authorization, { allowHomeConfig: false });
      const receipt = applyPlan({
        plan,
        targetPath: options.target,
        authorization,
        acknowledgeUserConfig: options.iUnderstandUserConfig,
      });
      if (options.json) {
        console.log(JSON.stringify(receipt, null, 2));
      } else {
        console.log(`status: ${receipt.status}`);
        console.log(`targetPath: ${receipt.targetPath}`);
        console.log(`backupPath: ${receipt.backupPath || "(none)"}`);
        console.log(`planDigest: ${receipt.planDigest}`);
        console.log(`appliedEntryIDs: ${(receipt.appliedEntryIDs || []).join(", ")}`);
        console.log(`ownershipRecords: ${(receipt.ownershipRecords || []).length}`);
      }
      process.exit(0);
    } catch (error) {
      die(error.message || String(error));
    }
  }

  if (options.command !== "plan") {
    usage(options.command ? `Unknown command: ${options.command}` : "Missing command");
    process.exit(1);
  }
  if (!options.registry || !options.readback) {
    usage("--registry and --readback are required for plan");
    process.exit(1);
  }

  try {
    const registry = validateRegistry(loadJSON(options.registry));
    const readback = normalizeReadback(loadJSON(options.readback));
    let brands = ["codex", "claude"];
    if (options.brand) {
      if (options.brand !== "codex" && options.brand !== "claude") {
        die(`--brand must be codex|claude, got ${options.brand}`);
      }
      brands = [options.brand];
    }
    const plan = buildPlan(registry, readback, brands);
    printPlan(plan, options.json);
  } catch (error) {
    die(error.message || String(error));
  }
}

main();
