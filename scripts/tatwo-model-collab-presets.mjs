#!/usr/bin/env node
/**
 * Model-collab-presets engine.
 *
 * Syncs gateway roster/route tables + agent-presets over device-sync-channel.
 * Never publishes credentials/tokens. TatwoModelIdentityRegistry rides the
 * app version and is hashed for comparison only — never applied as an overlay.
 */
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "..");
const SCHEMA = "TatwoModelCollabPresetsV1";
const IDENTITY_SCHEMA = "TatwoModelIdentityRegistryV1";
const PRESET_SCHEMA = "TatwoAgentPresetRegistryV1";
const ROUTE_CONSTS = [
  "gptRoutes",
  "gptAliases",
  "claudeRoutes",
  "claudeAliases",
  "grokRoutes",
  "minimaxRoutes",
];
const SET_CONSTS = ["visibleGptCatalogSlugs"];
const FORBIDDEN_KEY =
  /^(?:.*(?:api[_-]?key|private[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|authorization|password|passwd|cookie|credential|bearer).*|secret|token|apikey)$/i;
const FORBIDDEN_VALUE =
  /^(?:sk-[A-Za-z0-9_-]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|xai-[A-Za-z0-9_-]{16,}|gsk_[A-Za-z0-9_-]{16,}|xox[a-zA-Z]-[A-Za-z0-9-]{16,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9._-]+)$/;

function die(message, code = 2) {
  process.stderr.write(`error=${message}\n`);
  process.exit(code);
}

function sha256Bytes(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

function sha256Text(text) {
  return sha256Bytes(Buffer.from(String(text), "utf8"));
}

function stableStringify(value) {
  return `${JSON.stringify(value, (_, item) => {
    if (item && typeof item === "object" && !Array.isArray(item)) {
      return Object.fromEntries(
        Object.keys(item)
          .sort()
          .map((key) => [key, item[key]]),
      );
    }
    return item;
  })}\n`;
}

function readText(path) {
  return readFileSync(path, "utf8");
}

function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

function parseArgs(argv) {
  const out = { cmd: "status", flags: {} };
  const rest = [...argv];
  if (rest[0] && !rest[0].startsWith("--")) out.cmd = rest.shift();
  while (rest.length) {
    const token = rest.shift();
    if (!token.startsWith("--")) die(`unknown argument: ${token}`);
    const key = token.slice(2);
    const next = rest[0] && !rest[0].startsWith("--") ? rest.shift() : "1";
    out.flags[key] = next;
  }
  return out;
}

function extractBalanced(source, startIdx, openChar, closeChar) {
  let depth = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let inLineComment = false;
  let inBlockComment = false;
  let escaped = false;
  for (let i = startIdx; i < source.length; i += 1) {
    const ch = source[i];
    const next = source[i + 1];
    if (inLineComment) {
      if (ch === "\n") inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        i += 1;
      }
      continue;
    }
    if (inSingle) {
      if (!escaped && ch === "'") inSingle = false;
      escaped = !escaped && ch === "\\";
      if (ch !== "\\") escaped = false;
      continue;
    }
    if (inDouble) {
      if (!escaped && ch === '"') inDouble = false;
      escaped = !escaped && ch === "\\";
      if (ch !== "\\") escaped = false;
      continue;
    }
    if (inTemplate) {
      if (!escaped && ch === "`") inTemplate = false;
      escaped = !escaped && ch === "\\";
      if (ch !== "\\") escaped = false;
      continue;
    }
    if (ch === "/" && next === "/") {
      inLineComment = true;
      i += 1;
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      i += 1;
      continue;
    }
    if (ch === "'") {
      inSingle = true;
      continue;
    }
    if (ch === '"') {
      inDouble = true;
      continue;
    }
    if (ch === "`") {
      inTemplate = true;
      continue;
    }
    if (ch === openChar) depth += 1;
    if (ch === closeChar) {
      depth -= 1;
      if (depth === 0) return source.slice(startIdx, i + 1);
    }
  }
  throw new Error("unbalanced block");
}

function extractConstAssignment(source, name) {
  const re = new RegExp(`const\\s+${name}\\s*=`);
  const match = re.exec(source);
  if (!match) throw new Error(`missing const ${name}`);
  const start = match.index;
  let cursor = start + match[0].length;
  while (/\s/.test(source[cursor] || "")) cursor += 1;
  const ch = source[cursor];
  let end;
  if (ch === "{") {
    const literal = extractBalanced(source, cursor, "{", "}");
    end = cursor + literal.length;
  } else if (source.startsWith("new Set(", cursor)) {
    const setStart = source.indexOf("[", cursor);
    if (setStart < 0) throw new Error(`Set ${name} missing array`);
    const literal = extractBalanced(source, setStart, "[", "]");
    end = source.indexOf(")", setStart + literal.length);
    if (end < 0) throw new Error(`Set ${name} missing close`);
    end += 1;
  } else {
    throw new Error(`const ${name} is not an object or Set`);
  }
  while (source[end] === ";") end += 1;
  return { start, end, text: source.slice(start, end) };
}

function evalConstValue(assignmentText, name) {
  const rewritten = assignmentText
    .replace(new RegExp(`^const\\s+${name}\\s*=`), "value =")
    .replace(/;$/, "");
  const sandbox = { value: undefined };
  vm.createContext(sandbox);
  vm.runInContext(`${rewritten};`, sandbox, { timeout: 500 });
  const value = sandbox.value;
  if (value && typeof value === "object" && typeof value.size === "number" && typeof value[Symbol.iterator] === "function") {
    return [...value];
  }
  return value;
}

export function extractGatewayRoster(serverSource) {
  const roster = {};
  for (const name of ROUTE_CONSTS) {
    const block = extractConstAssignment(serverSource, name);
    roster[name] = evalConstValue(block.text, name);
  }
  for (const name of SET_CONSTS) {
    const block = extractConstAssignment(serverSource, name);
    roster[name] = evalConstValue(block.text, name);
  }
  return roster;
}

function walkSecrets(value, path = "$") {
  if (value == null) return [];
  if (typeof value === "string") {
    if (FORBIDDEN_VALUE.test(value.trim())) {
      return [`${path}=credential-looking-value`];
    }
    return [];
  }
  if (typeof value !== "object") return [];
  const hits = [];
  if (Array.isArray(value)) {
    value.forEach((item, index) => {
      hits.push(...walkSecrets(item, `${path}[${index}]`));
    });
    return hits;
  }
  for (const [key, item] of Object.entries(value)) {
    if (FORBIDDEN_KEY.test(key)) hits.push(`${path}.${key}`);
    hits.push(...walkSecrets(item, `${path}.${key}`));
  }
  return hits;
}

export function assertNoSecrets(payload) {
  const hits = walkSecrets(payload);
  if (hits.length) {
    const error = new Error(`credential-looking keys refused: ${hits.join(",")}`);
    error.hits = hits;
    throw error;
  }
  return true;
}

function jsLiteral(value, indent = 0) {
  const pad = "  ".repeat(indent);
  const inner = "  ".repeat(indent + 1);
  if (value === null) return "null";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (!value.length) return "[]";
    if (value.every((item) => typeof item !== "object" || item === null)) {
      return `[${value.map((item) => jsLiteral(item, 0)).join(", ")}]`;
    }
    const body = value.map((item) => `${inner}${jsLiteral(item, indent + 1)}`).join(",\n");
    return `[\n${body}\n${pad}]`;
  }
  const keys = Object.keys(value);
  if (!keys.length) return "{}";
  const body = keys
    .map((key) => {
      const printed = /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? key : JSON.stringify(key);
      return `${inner}${printed}: ${jsLiteral(value[key], indent + 1)}`;
    })
    .join(",\n");
  return `{\n${body}\n${pad}}`;
}

function renderConst(name, value) {
  if (SET_CONSTS.includes(name)) {
    const items = (value || []).map((item) => `  ${JSON.stringify(item)},`).join("\n");
    return `const ${name} = new Set([\n${items}\n])`;
  }
  return `const ${name} = ${jsLiteral(value, 0)}`;
}

export function mergeRosterIntoServer(serverSource, roster) {
  let next = serverSource;
  const names = [...ROUTE_CONSTS, ...SET_CONSTS];
  for (const name of names) {
    if (!(name in roster)) throw new Error(`roster missing ${name}`);
    const block = extractConstAssignment(next, name);
    next = `${next.slice(0, block.start)}${renderConst(name, roster[name])}${next.slice(block.end)}`;
  }
  return next;
}

function loadJsonIfExists(path) {
  if (!path || !existsSync(path)) return null;
  return JSON.parse(readText(path));
}

function identityRegistryPath(flags) {
  return (
    flags["identity-registry"] ||
    process.env.TATWO_MODEL_IDENTITY_REGISTRY ||
    join(
      REPO_ROOT,
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoModelIdentityRegistryV1.json",
    )
  );
}

function agentPresetsPath(flags) {
  return (
    flags["agent-presets"] ||
    process.env.TATWO_AGENT_PRESETS ||
    join(REPO_ROOT, "registry/agent-presets.v1.json")
  );
}

function defaultGatewayServer() {
  if (process.env.TATWO_GATEWAY_SERVER) return process.env.TATWO_GATEWAY_SERVER;
  const printed = spawnSync("launchctl", ["print", `gui/${process.getuid()}`], {
    encoding: "utf8",
  });
  const match = /codex-model-gateway[\s\S]*?\/[^\n]*server\.js/.exec(printed.stdout || "");
  if (match) {
    const pathMatch = /\/[^\n]*server\.js/.exec(match[0]);
    if (pathMatch) return pathMatch[0];
  }
  const fallbacks = [
    join(homedir(), "Library/Application Support/tatwo2/skills/codex-app-model-gateway/runtime/server.js"),
    join(homedir(), "AI/codex/home/skills/codex-app-model-gateway/runtime/server.js"),
  ];
  return fallbacks.find((path) => existsSync(path)) || "";
}

function detectGatewayLabel() {
  if (process.env.TATWO_GATEWAY_LAUNCH_AGENT) return process.env.TATWO_GATEWAY_LAUNCH_AGENT;
  const printed = spawnSync(
    "launchctl",
    ["print", `gui/${process.getuid()}`],
    { encoding: "utf8" },
  );
  const match = /([A-Za-z0-9._-]*codex-model-gateway)/.exec(printed.stdout || "");
  return match ? match[1] : "";
}

function detectGatewayPlist(label) {
  if (process.env.TATWO_GATEWAY_PLIST) return process.env.TATWO_GATEWAY_PLIST;
  if (!label) return "";
  const candidate = join(homedir(), "Library/LaunchAgents", `${label}.plist`);
  return existsSync(candidate) ? candidate : "";
}

export function rosterHash(roster) {
  return sha256Text(stableStringify(roster));
}

function buildPayload({ roster, identity, presets, device, ownerInitiated }) {
  const identityHash = identity ? sha256Text(stableStringify(identity)) : "";
  const presetsHash = presets ? sha256Text(stableStringify(presets)) : "";
  const payload = {
    schema: SCHEMA,
    publishedAt: new Date().toISOString(),
    sourceDevice: device,
    ownerInitiated: Boolean(ownerInitiated),
    identityRegistry: identity
      ? {
          ridesAppVersion: true,
          schema: identity.schema || IDENTITY_SCHEMA,
          canonicalAsOf: identity.canonicalAsOf || "",
          sha256: identityHash,
          recordCount: Array.isArray(identity.records) ? identity.records.length : 0,
          note: "TatwoModelIdentityRegistry already rides app version; not applied as a live overlay.",
        }
      : {
          ridesAppVersion: true,
          schema: IDENTITY_SCHEMA,
          note: "identity registry unavailable; app-bundled copy remains authority",
        },
    agentPresets: presets,
    gatewayRoster: roster,
    hashes: {
      roster: rosterHash(roster),
      agentPresets: presetsHash,
      identityRegistry: identityHash,
    },
  };
  assertNoSecrets(payload);
  return payload;
}

function channelPaths(channelDir) {
  return {
    profile: join(channelDir, "profiles/shared/model-collab-presets.json"),
    catalog: join(channelDir, "registries/models/model-collab-presets.v1.json"),
  };
}

function readChannelPayload(channelDir) {
  const paths = channelPaths(channelDir);
  const file = [paths.catalog, paths.profile].find((path) => existsSync(path));
  if (!file) return null;
  const payload = JSON.parse(readText(file));
  if (payload.schema !== SCHEMA) die(`unsupported payload schema: ${payload.schema || "missing"}`);
  assertNoSecrets(payload);
  return payload;
}

function publishPayload(channelDir, payload) {
  const text = `${JSON.stringify(payload, null, 2)}\n`;
  const paths = channelPaths(channelDir);
  writeAtomic(paths.profile, text);
  writeAtomic(paths.catalog, text);
  return paths;
}

function currentRosterHashFromServer(serverPath) {
  if (!serverPath || !existsSync(serverPath)) return "";
  return rosterHash(extractGatewayRoster(readText(serverPath)));
}

function reloadGatewayIfNeeded({ previousHash, nextHash, label }) {
  if (process.env.TATWO_GATEWAY_RELOAD === "0") {
    return { reloaded: false, reason: "reload-disabled" };
  }
  if (!nextHash || previousHash === nextHash) {
    return { reloaded: false, reason: "roster-hash-unchanged" };
  }
  if (!label) return { reloaded: false, reason: "missing-launch-agent-label" };
  const uid = process.getuid();
  const domain = `gui/${uid}`;
  const target = `${domain}/${label}`;
  const plist = detectGatewayPlist(label);
  const bootout = spawnSync("launchctl", ["bootout", target], { encoding: "utf8" });
  if (plist) {
    const bootstrap = spawnSync("launchctl", ["bootstrap", domain, plist], {
      encoding: "utf8",
    });
    if (bootstrap.status !== 0) {
      return {
        reloaded: false,
        reason: `bootstrap-failed:${(bootstrap.stderr || bootstrap.stdout || "").trim()}`,
        bootoutStatus: bootout.status,
      };
    }
  } else {
    const kickstart = spawnSync("launchctl", ["kickstart", "-k", target], {
      encoding: "utf8",
    });
    if (kickstart.status !== 0) {
      return {
        reloaded: false,
        reason: `kickstart-failed:${(kickstart.stderr || kickstart.stdout || "").trim()}`,
      };
    }
  }
  return { reloaded: true, reason: "roster-hash-changed", label };
}

function applyPayload({ payload, flags, role }) {
  if (!payload.ownerInitiated) {
    die("refusing non-owner-initiated model-collab payload (proposal-box only)");
  }
  if (role === "unassigned") die("role=unassigned; fail-closed, no apply");
  const serverPath = flags.server || defaultGatewayServer();
  const support = flags.support || process.env.TATWO_APP_SUPPORT ||
    join(homedir(), "Library/Application Support/Tatwo Ultrawork");
  const incomingDir = join(support, "model-collab-presets");
  mkdirSync(incomingDir, { recursive: true });
  writeAtomic(join(incomingDir, "last-incoming.json"), `${JSON.stringify(payload, null, 2)}\n`);

  const applied = { agentPresets: false, gatewayRoster: false, identityOverlay: false };
  if (payload.agentPresets) {
    if (payload.agentPresets.schema !== PRESET_SCHEMA) {
      die(`agent-presets schema refused: ${payload.agentPresets.schema || "missing"}`);
    }
    assertNoSecrets(payload.agentPresets);
    const dest = flags["agent-presets-dest"] ||
      process.env.TATWO_AGENT_PRESETS_DEST ||
      join(support, "registries/agent-presets.v1.json");
    writeAtomic(dest, `${JSON.stringify(payload.agentPresets, null, 2)}\n`);
    const repoDest = flags["agent-presets"] || process.env.TATWO_AGENT_PRESETS || "";
    if (repoDest && existsSync(dirname(repoDest))) {
      writeAtomic(repoDest, `${JSON.stringify(payload.agentPresets, null, 2)}\n`);
    }
    applied.agentPresets = true;
  }

  let reload = { reloaded: false, reason: "roster-absent" };
  if (payload.gatewayRoster) {
    assertNoSecrets(payload.gatewayRoster);
    if (!serverPath || !existsSync(serverPath)) {
      die("gateway server.js missing; refuse roster apply");
    }
    const previousHash = currentRosterHashFromServer(serverPath);
    const nextHash = payload.hashes?.roster || rosterHash(payload.gatewayRoster);
    if (previousHash !== nextHash) {
      const original = readText(serverPath);
      const merged = mergeRosterIntoServer(original, payload.gatewayRoster);
      const stamp = new Date().toISOString().replace(/[:.]/g, "");
      writeAtomic(`${serverPath}.bak-model-collab-${stamp}`, original);
      writeAtomic(serverPath, merged);
      applied.gatewayRoster = true;
    }
    reload = reloadGatewayIfNeeded({
      previousHash,
      nextHash,
      label: flags["launch-agent"] || detectGatewayLabel(),
    });
  }

  const receipt = {
    schema: "TatwoModelCollabPresetsApplyReceiptV1",
    appliedAt: new Date().toISOString(),
    ownerInitiated: true,
    identityRidesAppVersion: true,
    applied,
    reload,
    hashes: payload.hashes,
  };
  writeAtomic(join(incomingDir, "last-apply.json"), `${JSON.stringify(receipt, null, 2)}\n`);
  return receipt;
}

function resolveRole(flags) {
  if (flags.role) return flags.role;
  if (process.env.TATWO_DEVICE_ROLE) return process.env.TATWO_DEVICE_ROLE;
  if (process.env.TATWO_DATA_SYNC_ROLE === "host") return "primary";
  return "secondary";
}

function collectSources(flags) {
  const serverPath = flags.server || defaultGatewayServer();
  if (!serverPath || !existsSync(serverPath)) die(`gateway server.js not found: ${serverPath || "unset"}`);
  const roster = extractGatewayRoster(readText(serverPath));
  const identity = loadJsonIfExists(identityRegistryPath(flags));
  const presets = loadJsonIfExists(agentPresetsPath(flags));
  if (presets && presets.schema !== PRESET_SCHEMA) {
    die(`agent-presets schema refused: ${presets.schema || "missing"}`);
  }
  return { serverPath, roster, identity, presets };
}

function printJSON(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

function selftest() {
  const fixture = [
    "const gptRoutes = {",
    '  "gpt-5.6-sol": { display_name: "GPT-5.6 Sol", priority: 104 },',
    "};",
    "const gptAliases = {",
    '  "chatgpt-pro": "chatgpt-pro-consult",',
    "};",
    "const visibleGptCatalogSlugs = new Set([",
    '  "gpt-5.6-sol",',
    "]);",
    "const claudeRoutes = {",
    '  "opus-5": { display_name: "opus5", candidates: ["claude-opus-5"] },',
    "};",
    "const claudeAliases = { opus: \"opus-5\" };",
    "const grokRoutes = {",
    '  "grok-build": { display_name: "Grok 4.6", candidates: ["grok-4.6", "grok-build"] },',
    "};",
    "const minimaxRoutes = {",
    '  "minimax-m3": { display_name: "MiniMax M3", candidates: ["MiniMax-M3"] },',
    "};",
    'const KEEP = "do-not-touch";',
  ].join("\n");
  const roster = extractGatewayRoster(fixture);
  if (roster.grokRoutes["grok-build"].display_name !== "Grok 4.6") {
    throw new Error("selftest extract failed");
  }
  const dirty = { ...roster, gptRoutes: { ...roster.gptRoutes, leaked: { api_key: "sk-secret" } } };
  let refused = false;
  try {
    assertNoSecrets({ gatewayRoster: dirty });
  } catch {
    refused = true;
  }
  if (!refused) throw new Error("selftest secrets guard failed");
  const merged = mergeRosterIntoServer(fixture, {
    ...roster,
    grokRoutes: {
      "grok-build": { display_name: "Grok 4.6", candidates: ["grok-4.6", "grok-build"] },
    },
  });
  if (!merged.includes('display_name: "Grok 4.6"') || !merged.includes('const KEEP = "do-not-touch"')) {
    throw new Error("selftest merge failed");
  }
  process.stdout.write("selftest=passed\n");
}

function main() {
  const { cmd, flags } = parseArgs(process.argv.slice(2));
  const device =
    flags.device ||
    process.env.TATWO_DEVICE_NAME ||
    (spawnSync("hostname", ["-s"], { encoding: "utf8" }).stdout || "device").trim();
  const role = resolveRole(flags);
  const channelDir =
    flags.channel ||
    process.env.TATWO_CHANNEL_DIR ||
    join(
      process.env.TATWO_APP_SUPPORT ||
        join(homedir(), "Library/Application Support/Tatwo Ultrawork"),
      "device-sync-channel",
    );

  switch (cmd) {
    case "selftest":
      selftest();
      return;
    case "extract": {
      const { serverPath, roster } = collectSources(flags);
      printJSON({
        schema: "TatwoGatewayRosterExtractV1",
        serverPath,
        rosterHash: rosterHash(roster),
        roster,
      });
      return;
    }
    case "guard": {
      const payload = flags.payload
        ? JSON.parse(readText(flags.payload))
        : collectSources(flags).roster;
      assertNoSecrets(payload);
      process.stdout.write("guard=ok\n");
      return;
    }
    case "publish": {
      if (role !== "primary" && flags["allow-non-primary"] !== "1") {
        die("publish requires primary/owner role");
      }
      const { roster, identity, presets } = collectSources(flags);
      const payload = buildPayload({
        roster,
        identity,
        presets,
        device,
        ownerInitiated: flags["owner-initiated"] !== "0",
      });
      const paths = publishPayload(channelDir, payload);
      printJSON({
        ok: true,
        action: "publish",
        ownerInitiated: payload.ownerInitiated,
        hashes: payload.hashes,
        paths,
      });
      return;
    }
    case "apply": {
      const payload = flags.payload
        ? JSON.parse(readText(flags.payload))
        : readChannelPayload(channelDir);
      if (!payload) die("no model-collab payload on channel");
      const receipt = applyPayload({ payload, flags, role });
      printJSON(receipt);
      return;
    }
    case "cycle": {
      if (process.env.TATWO_MODEL_COLLAB_SYNC === "0") {
        printJSON({ ok: true, skipped: true, reason: "TATWO_MODEL_COLLAB_SYNC=0" });
        return;
      }
      if (role === "primary") {
        const { roster, identity, presets } = collectSources(flags);
        const payload = buildPayload({
          roster,
          identity,
          presets,
          device,
          ownerInitiated: true,
        });
        const existing = readChannelPayload(channelDir);
        const same =
          existing &&
          existing.hashes?.roster === payload.hashes.roster &&
          existing.hashes?.agentPresets === payload.hashes.agentPresets;
        if (!same) publishPayload(channelDir, payload);
        printJSON({
          ok: true,
          action: same ? "publish-unchanged" : "publish",
          ownerInitiated: true,
          hashes: payload.hashes,
        });
        return;
      }
      const payload = readChannelPayload(channelDir);
      if (!payload) {
        printJSON({ ok: true, action: "apply-skip", reason: "no-payload" });
        return;
      }
      const receipt = applyPayload({ payload, flags, role });
      printJSON({ ok: true, action: "apply", receipt });
      return;
    }
    case "status": {
      const serverPath = flags.server || defaultGatewayServer();
      const payload = existsSync(channelDir) ? readChannelPayload(channelDir) : null;
      let localHash = "";
      if (serverPath && existsSync(serverPath)) {
        localHash = currentRosterHashFromServer(serverPath);
      }
      printJSON({
        schema: "TatwoModelCollabPresetsStatusV1",
        role,
        device,
        serverPath: serverPath || null,
        launchAgent: detectGatewayLabel() || null,
        localRosterHash: localHash || null,
        channelRosterHash: payload?.hashes?.roster || null,
        identityRidesAppVersion: true,
        ownerInitiated: payload?.ownerInitiated ?? null,
      });
      return;
    }
    default:
      die(`unknown command: ${cmd}`);
  }
}

const invokedDirectly = process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  try {
    main();
  } catch (error) {
    die(error.message || String(error));
  }
}
