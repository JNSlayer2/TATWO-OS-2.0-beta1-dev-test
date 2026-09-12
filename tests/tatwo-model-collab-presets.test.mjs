import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const engine = path.join(repositoryRoot, "scripts/tatwo-model-collab-presets.mjs");
const wrapper = path.join(repositoryRoot, "scripts/tatwo-model-collab-presets.sh");

function fixtureServer(overrides = {}) {
  return [
    "const gptRoutes = {",
    '  "gpt-5.6-sol": { display_name: "GPT-5.6 Sol", priority: 104 },',
    '  "gpt-5.5": { display_name: "GPT-5.5", priority: 100 },',
    "};",
    "const gptAliases = {",
    '  "chatgpt-pro": "chatgpt-pro-consult",',
    "};",
    "const visibleGptCatalogSlugs = new Set([",
    '  "gpt-5.6-sol",',
    '  "gpt-5.5",',
    "]);",
    "const claudeRoutes = {",
    '  "opus-5": { display_name: "opus5", candidates: ["claude-opus-5", "opus-5"] },',
    '  "sonnet-5": { display_name: "sonnet5", candidates: ["claude-sonnet-5"] },',
    "};",
    "const claudeAliases = {",
    '  opus: "opus-5",',
    '  sonnet5: "sonnet-5",',
    "};",
    "const grokRoutes = {",
    `  "grok-build": { display_name: ${JSON.stringify(overrides.grokName || "Grok 4.6")}, candidates: ["grok-4.6", "grok-build"] },`,
    "};",
    "const minimaxRoutes = {",
    '  "minimax-m3": { display_name: "MiniMax M3", candidates: ["MiniMax-M3"] },',
    "};",
    'const KEEP_LOCAL = "machine-local-must-survive";',
    'const MINIMAX_API_KEY_FILE = "/secret/should-not-publish";',
  ].join("\n");
}

function writeJSON(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`);
}

function runEngine(args, extra = {}) {
  return spawnSync(process.execPath, [engine, ...args], {
    encoding: "utf8",
    ...extra,
  });
}

test("selftest extracts, merges, and refuses secrets", () => {
  const result = runEngine(["selftest"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /selftest=passed/);
});

test("wrapper selftest is executable through bash", () => {
  const result = spawnSync("bash", [wrapper, "selftest"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /selftest=passed/);
});

test("publish refuses credential-looking roster keys", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-model-collab-secret-"));
  const server = path.join(work, "server.js");
  fs.writeFileSync(
    server,
    fixtureServer().replace(
      '"gpt-5.5": { display_name: "GPT-5.5", priority: 100 }',
      '"gpt-5.5": { display_name: "GPT-5.5", api_key: "sk-leaked-credential-value" }',
    ),
  );
  const result = runEngine([
    "publish",
    "--role",
    "primary",
    "--server",
    server,
    "--channel",
    path.join(work, "channel"),
    "--agent-presets",
    path.join(repositoryRoot, "registry/agent-presets.v1.json"),
    "--identity-registry",
    path.join(
      repositoryRoot,
      "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoModelIdentityRegistryV1.json",
    ),
    "--device",
    "mini",
  ]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /credential-looking keys refused/);
  assert.equal(
    fs.existsSync(path.join(work, "channel/registries/models/model-collab-presets.v1.json")),
    false,
  );
});

test("owner-initiated cycle publishes roster and applies without touching credentials or identity overlay", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-model-collab-cycle-"));
  const channel = path.join(work, "channel");
  const miniServer = path.join(work, "mini", "server.js");
  const bookServer = path.join(work, "book", "server.js");
  const presets = path.join(work, "registry", "agent-presets.v1.json");
  const identity = path.join(
    repositoryRoot,
    "Packages/TatwoUltraworkCore/Sources/TatwoUltraworkCore/TatwoModelIdentityRegistryV1.json",
  );
  fs.mkdirSync(path.dirname(miniServer), { recursive: true });
  fs.mkdirSync(path.dirname(bookServer), { recursive: true });
  fs.writeFileSync(miniServer, fixtureServer({ grokName: "Grok 4.6" }));
  fs.writeFileSync(bookServer, fixtureServer({ grokName: "Grok" }));
  writeJSON(presets, {
    schema: "TatwoAgentPresetRegistryV1",
    source: "os_registry",
    registryRevision: "test-r1",
    allowedGPTModels: ["gpt-5.5"],
    agentPresets: [],
  });

  const published = runEngine([
    "cycle",
    "--role",
    "primary",
    "--server",
    miniServer,
    "--channel",
    channel,
    "--agent-presets",
    presets,
    "--identity-registry",
    identity,
    "--device",
    "mini",
  ], {
    env: { ...process.env, TATWO_GATEWAY_RELOAD: "0", TATWO_APP_SUPPORT: path.join(work, "mini-support") },
  });
  assert.equal(published.status, 0, published.stderr + published.stdout);
  const payload = JSON.parse(
    fs.readFileSync(path.join(channel, "registries/models/model-collab-presets.v1.json"), "utf8"),
  );
  assert.equal(payload.schema, "TatwoModelCollabPresetsV1");
  assert.equal(payload.ownerInitiated, true);
  assert.equal(payload.identityRegistry.ridesAppVersion, true);
  assert.equal(payload.gatewayRoster.grokRoutes["grok-build"].display_name, "Grok 4.6");
  assert.ok(!JSON.stringify(payload).includes("MINIMAX_API_KEY_FILE"));
  assert.ok(!JSON.stringify(payload).includes("/secret/should-not-publish"));
  assert.ok(
    fs.existsSync(path.join(channel, "profiles/shared/model-collab-presets.json")),
  );

  const bookSupport = path.join(work, "book-support");
  const applied = runEngine([
    "cycle",
    "--role",
    "secondary",
    "--server",
    bookServer,
    "--channel",
    channel,
    "--agent-presets-dest",
    path.join(bookSupport, "registries/agent-presets.v1.json"),
    "--device",
    "macbook",
  ], {
    env: { ...process.env, TATWO_GATEWAY_RELOAD: "0", TATWO_APP_SUPPORT: bookSupport },
  });
  assert.equal(applied.status, 0, applied.stderr + applied.stdout);
  const receipt = JSON.parse(applied.stdout).receipt;
  assert.equal(receipt.applied.gatewayRoster, true);
  assert.equal(receipt.applied.agentPresets, true);
  assert.equal(receipt.applied.identityOverlay, false);
  assert.equal(receipt.reload.reloaded, false);
  assert.equal(receipt.reload.reason, "reload-disabled");
  const merged = fs.readFileSync(bookServer, "utf8");
  assert.match(merged, /display_name: "Grok 4\.6"/);
  assert.match(merged, /machine-local-must-survive/);
  assert.match(merged, /MINIMAX_API_KEY_FILE = "\/secret\/should-not-publish"/);
  assert.equal(
    JSON.parse(fs.readFileSync(path.join(bookSupport, "registries/agent-presets.v1.json"), "utf8"))
      .registryRevision,
    "test-r1",
  );
  assert.equal(fs.existsSync(path.join(bookSupport, "registries/TatwoModelIdentityRegistryV1.json")), false);
});

test("non-owner payload is refused and same-hash apply does not rewrite server", () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "tatwo-model-collab-law-"));
  const server = path.join(work, "server.js");
  fs.writeFileSync(server, fixtureServer());
  const extract = runEngine(["extract", "--server", server]);
  assert.equal(extract.status, 0, extract.stderr);
  const roster = JSON.parse(extract.stdout).roster;
  const unsigned = {
    schema: "TatwoModelCollabPresetsV1",
    ownerInitiated: false,
    gatewayRoster: roster,
    hashes: { roster: JSON.parse(extract.stdout).rosterHash },
  };
  const unsignedPath = path.join(work, "unsigned.json");
  writeJSON(unsignedPath, unsigned);
  const refused = runEngine([
    "apply",
    "--role",
    "secondary",
    "--payload",
    unsignedPath,
    "--server",
    server,
  ], {
    env: { ...process.env, TATWO_GATEWAY_RELOAD: "0", TATWO_APP_SUPPORT: work },
  });
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /non-owner-initiated/);

  const owned = {
    ...unsigned,
    ownerInitiated: true,
    identityRegistry: { ridesAppVersion: true },
  };
  const ownedPath = path.join(work, "owned.json");
  writeJSON(ownedPath, owned);
  const before = fs.readFileSync(server, "utf8");
  const same = runEngine([
    "apply",
    "--role",
    "secondary",
    "--payload",
    ownedPath,
    "--server",
    server,
  ], {
    env: { ...process.env, TATWO_GATEWAY_RELOAD: "0", TATWO_APP_SUPPORT: work },
  });
  assert.equal(same.status, 0, same.stderr + same.stdout);
  const receipt = JSON.parse(same.stdout);
  assert.equal(receipt.applied.gatewayRoster, false);
  assert.equal(receipt.reload.reason, "reload-disabled");
  assert.equal(fs.readFileSync(server, "utf8"), before);
});
